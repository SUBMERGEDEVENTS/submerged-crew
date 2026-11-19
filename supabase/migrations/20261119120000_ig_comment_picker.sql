-- Round 2: Instagram comment giveaway picker.
-- FILE ONLY. Do not apply from a pull request. The project owner applies it by hand, see docs/IG_COMMENT_PICKER.md.
-- Rollback: supabase/rollback/20261119_before_ig_comment_picker.sql
-- Adds:
--   private.ig_connections          one Instagram connection per team (token lives in Supabase Vault)
--   public.ig_comment_draws         one immutable row per giveaway draw, admins of that team only
--   public.ig_connection_status()   admin read of the connection, never returns the token
--   public.ig_disconnect()          admin removes the connection and its Vault secret
--   public.ig_save_connection()     service role only (used by the ig-comments and ig-oauth-callback Edge Functions)
--   public.ig_update_token()        service role only (token refresh)
--   public.ig_connection_secret()   service role only (returns the token to the Edge Function)
-- No rows are deleted or changed in existing tables.

-- ───────────── connection (token in Vault) ─────────────
create table if not exists private.ig_connections (
  tenant_slug text primary key,
  api_host text not null check (api_host in ('graph.instagram.com', 'graph.facebook.com')),
  ig_user_id text not null,
  ig_username text,
  secret_id uuid not null,
  token_expires_at timestamptz,
  token_refreshed_at timestamptz,
  connected_by uuid,
  connected_at timestamptz not null default now()
);
alter table private.ig_connections enable row level security;
revoke all on private.ig_connections from anon, authenticated;

-- Admin view of the connection. Never returns the token.
create or replace function public.ig_connection_status(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); c private.ig_connections%rowtype;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  select * into c from private.ig_connections where tenant_slug = v_slug;
  if not found then return jsonb_build_object('tenant', v_slug, 'connected', false); end if;
  return jsonb_build_object(
    'tenant', v_slug,
    'connected', true,
    'username', c.ig_username,
    'api_host', c.api_host,
    'expires_at', c.token_expires_at,
    'refreshed_at', c.token_refreshed_at,
    'connected_at', c.connected_at);
end $$;

-- Admin removes the connection and deletes the Vault secret.
create or replace function public.ig_disconnect(p_tenant text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_id uuid;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  select secret_id into v_id from private.ig_connections where tenant_slug = v_slug;
  delete from private.ig_connections where tenant_slug = v_slug;
  if v_id is not null then delete from vault.secrets where id = v_id; end if;
  return jsonb_build_object('tenant', v_slug, 'connected', false);
end $$;

-- Service role only. Stores or replaces the team's token in Vault.
create or replace function public.ig_save_connection(
  p_tenant text, p_token text, p_api_host text, p_ig_user_id text, p_ig_username text,
  p_expires_at timestamptz, p_connected_by uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_id uuid; v_tok text := btrim(coalesce(p_token, ''));
begin
  if length(v_tok) < 20 then raise exception 'token missing' using errcode = '22023'; end if;
  select secret_id into v_id from private.ig_connections where tenant_slug = v_slug;
  if v_id is not null and exists (select 1 from vault.secrets s where s.id = v_id) then
    perform vault.update_secret(v_id, v_tok);
  else
    v_id := vault.create_secret(v_tok, 'instagram_token__' || v_slug || '__' || substr(md5(random()::text), 1, 8),
                                'Instagram access token for team ' || v_slug);
  end if;
  insert into private.ig_connections
    (tenant_slug, api_host, ig_user_id, ig_username, secret_id, token_expires_at, token_refreshed_at, connected_by, connected_at)
  values (v_slug, p_api_host, p_ig_user_id, p_ig_username, v_id, p_expires_at, now(), p_connected_by, now())
  on conflict (tenant_slug) do update set
    api_host = excluded.api_host, ig_user_id = excluded.ig_user_id, ig_username = excluded.ig_username,
    secret_id = excluded.secret_id, token_expires_at = excluded.token_expires_at,
    token_refreshed_at = now(), connected_by = excluded.connected_by, connected_at = now();
end $$;

-- Service role only. Replaces the token after a refresh.
create or replace function public.ig_update_token(p_tenant text, p_token text, p_expires_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_id uuid; v_tok text := btrim(coalesce(p_token, ''));
begin
  if length(v_tok) < 20 then raise exception 'token missing' using errcode = '22023'; end if;
  select secret_id into v_id from private.ig_connections where tenant_slug = v_slug;
  if v_id is null then raise exception 'not connected' using errcode = 'P0002'; end if;
  perform vault.update_secret(v_id, v_tok);
  update private.ig_connections
     set token_expires_at = p_expires_at, token_refreshed_at = now()
   where tenant_slug = v_slug;
end $$;

-- Service role only. Returns the token to the Edge Function. Never expose to the browser.
create or replace function public.ig_connection_secret(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); c private.ig_connections%rowtype; v_tok text;
begin
  select * into c from private.ig_connections where tenant_slug = v_slug;
  if not found then return null; end if;
  select d.decrypted_secret into v_tok from vault.decrypted_secrets d where d.id = c.secret_id;
  return jsonb_build_object(
    'tenant', v_slug, 'token', v_tok, 'api_host', c.api_host, 'ig_user_id', c.ig_user_id,
    'username', c.ig_username, 'expires_at', c.token_expires_at,
    'refreshed_at', c.token_refreshed_at, 'connected_at', c.connected_at);
end $$;

revoke all on function public.ig_connection_status(text) from public, anon;
revoke all on function public.ig_disconnect(text) from public, anon;
grant execute on function public.ig_connection_status(text) to authenticated;
grant execute on function public.ig_disconnect(text) to authenticated;

revoke all on function public.ig_save_connection(text, text, text, text, text, timestamptz, uuid) from public, anon, authenticated;
revoke all on function public.ig_update_token(text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.ig_connection_secret(text) from public, anon, authenticated;
grant execute on function public.ig_save_connection(text, text, text, text, text, timestamptz, uuid) to service_role;
grant execute on function public.ig_update_token(text, text, timestamptz) to service_role;
grant execute on function public.ig_connection_secret(text) to service_role;

-- ───────────── draw records ─────────────
create table if not exists public.ig_comment_draws (
  id uuid primary key default gen_random_uuid(),
  tenant_slug text not null,
  post_url text not null,
  media_id text,
  rules jsonb not null default '{}'::jsonb,
  entrant_count integer not null check (entrant_count >= 0),
  eligible_count integer not null check (eligible_count >= 0),
  winners jsonb not null default '[]'::jsonb,
  drawn_by uuid default auth.uid(),
  drawn_at timestamptz not null default now(),
  constraint ig_comment_draws_tenant_format check (tenant_slug ~ '^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$'),
  constraint ig_comment_draws_winners_array check (jsonb_typeof(winners) = 'array'),
  constraint ig_comment_draws_rules_object check (jsonb_typeof(rules) = 'object')
);
create index if not exists ig_comment_draws_tenant_drawn_idx on public.ig_comment_draws (tenant_slug, drawn_at desc);
alter table public.ig_comment_draws enable row level security;
revoke all on public.ig_comment_draws from anon;
-- Select and insert only. A saved draw can never be edited or deleted from the app.
revoke all on public.ig_comment_draws from authenticated;
grant select, insert on public.ig_comment_draws to authenticated;

create or replace function private.tg_ig_draw_stamp()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.tenant_slug := private.norm_tenant(new.tenant_slug);
  if coalesce(auth.role(), '') in ('authenticated', 'anon') then
    new.drawn_by := auth.uid();
    new.drawn_at := now();
  end if;
  return new;
end $$;
drop trigger if exists trg_ig_draw_stamp on public.ig_comment_draws;
create trigger trg_ig_draw_stamp before insert on public.ig_comment_draws
  for each row execute function private.tg_ig_draw_stamp();

drop policy if exists "Tenant admins read ig draws" on public.ig_comment_draws;
create policy "Tenant admins read ig draws" on public.ig_comment_draws
  for select to authenticated using (public.is_tenant_admin(tenant_slug));
drop policy if exists "Tenant admins save ig draws" on public.ig_comment_draws;
create policy "Tenant admins save ig draws" on public.ig_comment_draws
  for insert to authenticated with check (public.is_tenant_admin(tenant_slug));
