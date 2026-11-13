-- Phase 2: per-team Eventbrite, recorded payouts, per-team pay rates.
-- Rollback: supabase/rollback/20261113_before_team_eventbrite_payouts_rates.sql
-- No rows are deleted.

-- ───────────── C. per-team pay rates ─────────────
alter table private.tenant_settings
  add column if not exists pay_rates jsonb not null
  default '{"Recruit": 2.00, "Rising Star": 2.00, "Hotshot": 2.50, "Closer": 3.00, "Legend": 3.00}'::jsonb;

-- Seed SUB:MERGED with the exact rates it uses today.
update private.tenant_settings
   set pay_rates = '{"Recruit": 2.00, "Rising Star": 2.00, "Hotshot": 2.50, "Closer": 3.00, "Legend": 3.00}'::jsonb
 where tenant_slug = 'submerged';

create or replace function private.tenant_pay_rates(p_tenant text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.pay_rates from private.tenant_settings s where s.tenant_slug = private.norm_tenant(p_tenant)),
    '{"Recruit": 2.00, "Rising Star": 2.00, "Hotshot": 2.50, "Closer": 3.00, "Legend": 3.00}'::jsonb);
$$;

create or replace function private.tenant_pay_rate(p_tenant text, p_rank text)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((private.tenant_pay_rates(p_tenant)->>coalesce(p_rank, 'Recruit'))::numeric,
                  (private.tenant_pay_rates(p_tenant)->>'Recruit')::numeric, 0);
$$;

-- Reps and admins of the team can read their team's rates.
create or replace function public.tenant_pay_rates(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.can_view_tenant(private.norm_tenant(p_tenant)) then
    raise exception 'not a member of this team' using errcode = '42501';
  end if;
  return private.tenant_pay_rates(p_tenant);
end $$;

-- Only that team's admins can change them.
create or replace function public.set_tenant_pay_rates(p_tenant text, p_rates jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); k text; v jsonb; v_clean jsonb := '{}'::jsonb;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  if p_rates is null or jsonb_typeof(p_rates) <> 'object' then raise exception 'rates must be an object' using errcode = '22023'; end if;
  for k, v in select * from jsonb_each(p_rates) loop
    if k not in ('Recruit', 'Rising Star', 'Hotshot', 'Closer', 'Legend') then
      raise exception 'unknown rank %', k using errcode = '22023';
    end if;
    if jsonb_typeof(v) <> 'number' or (v::text)::numeric < 0 or (v::text)::numeric > 100 then
      raise exception 'rate for % must be a number from 0 to 100', k using errcode = '22023';
    end if;
    v_clean := v_clean || jsonb_build_object(k, round((v::text)::numeric, 2));
  end loop;
  insert into private.tenant_settings (tenant_slug, invite_only, pay_rates)
  values (v_slug, private.tenant_invite_only(v_slug), private.tenant_pay_rates(v_slug) || v_clean)
  on conflict (tenant_slug) do update set pay_rates = private.tenant_settings.pay_rates || v_clean, updated_at = now();
  return private.tenant_pay_rates(v_slug);
end $$;

revoke all on function private.tenant_pay_rates(text) from public, anon, authenticated;
revoke all on function private.tenant_pay_rate(text, text) from public, anon, authenticated;
revoke all on function public.tenant_pay_rates(text) from public, anon;
revoke all on function public.set_tenant_pay_rates(text, jsonb) from public, anon;
grant execute on function public.tenant_pay_rates(text) to authenticated;
grant execute on function public.set_tenant_pay_rates(text, jsonb) to authenticated;

-- Shared template tier perks no longer quote SUB:MERGED's dollar rates.
update private.gamification_tiers set perk = 'Keep going. Hotshot pays more per code'
 where tenant_slug = 'default' and name = 'Rising Star' and perk like '%$2.50%';
update private.gamification_tiers set perk = 'Reach Closer for a higher rate + cash bonuses'
 where tenant_slug = 'default' and name = 'Hotshot' and perk like '%$3/code%';
update private.gamification_tiers set perk = 'Top tier: best rate + VIP guest list'
 where tenant_slug = 'default' and name = 'Legend' and perk like '%$3/code%';

-- ───────────── B. Mark all paid records payouts ─────────────
alter table public.payouts add column if not exists paid_by uuid;

create or replace function public.mark_event_payouts_paid(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_tenant text; v_n int := 0; v_total numeric := 0; r record;
begin
  select private.norm_tenant(e.tenant_slug) into v_tenant from public.events e where e.id = p_event_id;
  if v_tenant is null then raise exception 'event not found' using errcode = 'P0002'; end if;
  if not public.is_tenant_admin(v_tenant) then raise exception 'admin only' using errcode = '42501'; end if;

  for r in
    select re.id, re.rep_id, re.cash_earned
      from public.rep_events re
      join public.reps rp on rp.id = re.rep_id
     where re.event_id = p_event_id
       and coalesce(re.cash_earned, 0) > 0
       and private.tenant_row_matches(re.tenant_slug, v_tenant)
       and private.tenant_row_matches(rp.tenant_slug, v_tenant)
     for update of re
  loop
    insert into public.payouts (rep_id, event_id, amount, status, method, notes, paid_at, paid_by, tenant_slug)
    values (r.rep_id, p_event_id, r.cash_earned, 'paid', 'mark_all_paid',
            'Marked paid from the admin Payouts tab', now(), auth.uid(), v_tenant);
    update public.rep_events set cash_earned = 0 where id = r.id;
    v_n := v_n + 1;
    v_total := v_total + r.cash_earned;
  end loop;
  return jsonb_build_object('reps_paid', v_n, 'total', v_total);
end $$;
revoke all on function public.mark_event_payouts_paid(uuid) from public, anon;
grant execute on function public.mark_event_payouts_paid(uuid) to authenticated;

-- ───────────── A. per-team Eventbrite ─────────────
create table if not exists private.tenant_integrations (
  tenant_slug text primary key,
  eventbrite_secret_id uuid,
  eventbrite_token_last4 text,
  eventbrite_token_set_at timestamptz,
  eventbrite_token_set_by uuid,
  webhook_key text not null default encode(extensions.gen_random_bytes(24), 'hex'),
  webhook_key_rotated_at timestamptz not null default now()
);
alter table private.tenant_integrations enable row level security;
revoke all on private.tenant_integrations from anon, authenticated;

create or replace function private.ensure_tenant_integration(p_slug text)
returns void language sql security definer set search_path = '' as $$
  insert into private.tenant_integrations (tenant_slug) values (p_slug) on conflict (tenant_slug) do nothing;
$$;
revoke all on function private.ensure_tenant_integration(text) from public, anon, authenticated;

-- Admin view of the connection. Never returns the Eventbrite token.
create or replace function public.eventbrite_connection(p_tenant text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); i private.tenant_integrations%rowtype;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  perform private.ensure_tenant_integration(v_slug);
  select * into i from private.tenant_integrations where tenant_slug = v_slug;
  return jsonb_build_object(
    'tenant', v_slug,
    'connected', i.eventbrite_secret_id is not null,
    'token_last4', i.eventbrite_token_last4,
    'token_set_at', i.eventbrite_token_set_at,
    'webhook_key', i.webhook_key,
    'webhook_key_rotated_at', i.webhook_key_rotated_at);
end $$;

-- Write-only: stores the token in Supabase Vault.
create or replace function public.set_eventbrite_token(p_tenant text, p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_tok text := btrim(coalesce(p_token, '')); v_id uuid;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  if v_tok !~ '^[A-Za-z0-9_-]{10,200}$' then
    raise exception 'That does not look like an Eventbrite private token' using errcode = '22023';
  end if;
  perform private.ensure_tenant_integration(v_slug);
  select eventbrite_secret_id into v_id from private.tenant_integrations where tenant_slug = v_slug;
  if v_id is not null and exists (select 1 from vault.secrets s where s.id = v_id) then
    perform vault.update_secret(v_id, v_tok);
  else
    v_id := vault.create_secret(v_tok, 'eventbrite_token__' || v_slug || '__' || substr(md5(random()::text), 1, 8),
                                'Eventbrite private token for team ' || v_slug);
  end if;
  update private.tenant_integrations
     set eventbrite_secret_id = v_id, eventbrite_token_last4 = right(v_tok, 4),
         eventbrite_token_set_at = now(), eventbrite_token_set_by = auth.uid()
   where tenant_slug = v_slug;
  return public.eventbrite_connection(v_slug);
end $$;

create or replace function public.rotate_eventbrite_webhook_key(p_tenant text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant);
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  perform private.ensure_tenant_integration(v_slug);
  update private.tenant_integrations
     set webhook_key = encode(extensions.gen_random_bytes(24), 'hex'), webhook_key_rotated_at = now()
   where tenant_slug = v_slug;
  return public.eventbrite_connection(v_slug);
end $$;

revoke all on function public.eventbrite_connection(text) from public, anon;
revoke all on function public.set_eventbrite_token(text, text) from public, anon;
revoke all on function public.rotate_eventbrite_webhook_key(text) from public, anon;
grant execute on function public.eventbrite_connection(text) to authenticated;
grant execute on function public.set_eventbrite_token(text, text) to authenticated;
grant execute on function public.rotate_eventbrite_webhook_key(text) to authenticated;

-- Service role only (used by the eventbrite-webhook Edge Function).
create or replace function public.webhook_tenant_context(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); i private.tenant_integrations%rowtype; v_tok text;
begin
  select * into i from private.tenant_integrations where tenant_slug = v_slug;
  if i.eventbrite_secret_id is not null then
    select d.decrypted_secret into v_tok from vault.decrypted_secrets d where d.id = i.eventbrite_secret_id;
  end if;
  return jsonb_build_object('tenant', v_slug, 'webhook_key', i.webhook_key, 'token', v_tok,
                            'pay_rates', private.tenant_pay_rates(v_slug));
end $$;
revoke all on function public.webhook_tenant_context(text) from public, anon, authenticated;
grant execute on function public.webhook_tenant_context(text) to service_role;

-- Keys for the teams that exist today.
insert into private.tenant_integrations (tenant_slug) values ('submerged'), ('acme-demo') on conflict do nothing;
