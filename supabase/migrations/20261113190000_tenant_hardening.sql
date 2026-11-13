-- Tenant hardening before the first outside client.
--  1. Leaderboard / progress RPCs only answer for members or admins of the team.
--  2. Gamification settings are per team and editable only by that team's admins.
--  3. demo_requests readable only by platform owners.
--  6. Invite-only signup per team, enforced in the database.
--  9. Rep profiles need terms acceptance (and an invite where required).
-- Rollback: supabase/rollback/20261113_before_tenant_hardening.sql
-- No rows are deleted.

-- ───────────── helpers ─────────────
create or replace function private.norm_tenant(p_tenant text)
returns text language sql immutable set search_path = '' as $$
  select coalesce(nullif(lower(btrim(p_tenant)), ''), 'submerged');
$$;

create or replace function private.is_tenant_member(p_tenant text)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.reps r
    where r.user_id = auth.uid()
      and private.tenant_row_matches(r.tenant_slug, p_tenant));
$$;

create or replace function private.can_view_tenant(p_tenant text)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_tenant_member(p_tenant) or public.is_tenant_admin(p_tenant);
$$;

revoke all on function private.is_tenant_member(text) from public, anon;
revoke all on function private.can_view_tenant(text) from public, anon;
grant execute on function private.is_tenant_member(text) to authenticated;
grant execute on function private.can_view_tenant(text) to authenticated;

-- ───────────── 1. leaderboard + my progress ─────────────
create or replace function private.gam_leaderboard(p_event_id uuid, p_limit integer, p_tenant text)
 returns table(pos integer, display_name text, promo_code text, tier_name text, tier_icon text, tier_color text, points integer, tickets integer, is_me boolean)
 language plpgsql stable security definer set search_path to ''
as $function$
declare
  v_t   text := private.gam_tenant(p_tenant);
  v_lim int  := least(greatest(coalesce(p_limit,25),1),100);
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if p_tenant is null or btrim(p_tenant) = '' or not private.can_view_tenant(p_tenant) then
    raise exception 'not a member of this team' using errcode = '42501';
  end if;

  return query
  with lifetime as (select * from private.gam_rep_stats(p_tenant)),
  ev as (select * from private.gam_rep_event_points(p_tenant) e where e.event_id = p_event_id),
  scoped as (
    select l.rep_id,
           case when p_event_id is null then l.points
                else coalesce(e.sale_points,0) + coalesce(e.milestone_points,0) + coalesce(e.content_points,0) end as pts,
           case when p_event_id is null then l.tickets else coalesce(e.tickets,0) end as tix,
           l.points as lifetime_points
    from lifetime l
    left join ev e on e.rep_id = l.rep_id
    where p_event_id is null
       or e.rep_id is not null
       or exists (select 1 from public.rep_events re where re.rep_id = l.rep_id and re.event_id = p_event_id)
  )
  select (rank() over (order by s.pts desc, s.tix desc))::int,
         private.gam_display_name(r.name), r.promo_code,
         t.name, t.icon, t.color, s.pts::int, s.tix::int,
         (r.user_id is not null and r.user_id = auth.uid())
  from scoped s
  join public.reps r on r.id = s.rep_id
  left join lateral (
    select gt.name, gt.icon, gt.color from private.gamification_tiers gt
    where gt.tenant_slug = v_t and gt.min_points <= s.lifetime_points
    order by gt.min_points desc limit 1) t on true
  where r.status = 'active'
    and private.tenant_row_matches(r.tenant_slug, p_tenant)
    and not exists (select 1 from private.gamification_leaderboard_exclusions x where x.rep_id = r.id)
  order by s.pts desc, s.tix desc, r.created_at asc
  limit v_lim;
end $function$;

-- my_progress: only the caller's rep in THIS team.
do $do$
declare v_def text;
begin
  select pg_get_functiondef('private.gam_my_progress(text)'::regprocedure) into v_def;
  v_def := replace(v_def,
    'select r.id into v_rep from public.reps r where r.user_id = auth.uid() order by r.created_at limit 1;',
    'if p_tenant is null or btrim(p_tenant) = '''' then return null; end if;
  select r.id into v_rep from public.reps r where r.user_id = auth.uid()
    and private.tenant_row_matches(r.tenant_slug, p_tenant) order by r.created_at limit 1;');
  if position('tenant_row_matches(r.tenant_slug, p_tenant) order by' in v_def) = 0 then
    raise exception 'gam_my_progress patch did not apply';
  end if;
  execute v_def;
end $do$;

-- ───────────── 2. gamification settings per team ─────────────
-- Give submerged its own copy of the shared template so edits never touch
-- other teams. Values are identical, so points do not change.
insert into private.gamification_config (tenant_slug, points_per_ticket, points_per_sale, include_content_points,
  content_flyer_points, content_original_points, milestones)
select 'submerged', points_per_ticket, points_per_sale, include_content_points,
  content_flyer_points, content_original_points, milestones
from private.gamification_config where tenant_slug = 'default'
on conflict (tenant_slug) do nothing;

insert into private.gamification_tiers (tenant_slug, name, min_points, icon, color, perk)
select 'submerged', name, min_points, icon, color, perk from private.gamification_tiers where tenant_slug = 'default'
on conflict do nothing;

insert into private.gamification_badges (tenant_slug, code, name, icon, description, metric, threshold, sort_order, active)
select 'submerged', code, name, icon, description, metric, threshold, sort_order, active
from private.gamification_badges where tenant_slug = 'default'
on conflict do nothing;

-- No em or en dashes in rep-facing perk copy.
update private.gamification_tiers
   set perk = replace(replace(replace(perk, ' — ', ': '), '—', ', '), '–', ' to ')
 where perk ~ '[—–]';
update private.gamification_tiers set perk = 'Keep going. Hotshot unlocks $2.50/code' where perk = 'Keep going: Hotshot unlocks $2.50/code';
update private.gamification_tiers set perk = 'Almost at Legend, the top of the team' where perk = 'Almost at Legend: the top of the team';

drop policy if exists "Admins manage gamification_config" on private.gamification_config;
drop policy if exists "Admins manage gamification_tiers" on private.gamification_tiers;
drop policy if exists "Admins manage gamification_badges" on private.gamification_badges;
drop policy if exists "Admins manage gamification_leaderboard_exclusions" on private.gamification_leaderboard_exclusions;

create policy "Tenant admins manage gamification_config" on private.gamification_config
  for all to authenticated using (public.is_tenant_admin(tenant_slug)) with check (public.is_tenant_admin(tenant_slug));
create policy "Tenant admins manage gamification_tiers" on private.gamification_tiers
  for all to authenticated using (public.is_tenant_admin(tenant_slug)) with check (public.is_tenant_admin(tenant_slug));
create policy "Tenant admins manage gamification_badges" on private.gamification_badges
  for all to authenticated using (public.is_tenant_admin(tenant_slug)) with check (public.is_tenant_admin(tenant_slug));
create policy "Tenant admins manage gamification_leaderboard_exclusions" on private.gamification_leaderboard_exclusions
  for all to authenticated
  using (exists (select 1 from public.reps r where r.id = rep_id and public.is_tenant_admin(coalesce(r.tenant_slug, 'submerged'))))
  with check (exists (select 1 from public.reps r where r.id = rep_id and public.is_tenant_admin(coalesce(r.tenant_slug, 'submerged'))));

-- Admin RPCs (private schema is not exposed through the Data API).
create or replace function public.gamification_settings(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_t text;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  v_t := private.gam_tenant(v_slug);
  return jsonb_build_object(
    'tenant', v_slug, 'source', v_t,
    'config', (select to_jsonb(c) - 'tenant_slug' from private.gamification_config c where c.tenant_slug = v_t),
    'tiers', coalesce((select jsonb_agg(to_jsonb(t) - 'tenant_slug' order by t.min_points) from private.gamification_tiers t where t.tenant_slug = v_t), '[]'),
    'badges', coalesce((select jsonb_agg(to_jsonb(b) - 'tenant_slug' order by b.sort_order) from private.gamification_badges b where b.tenant_slug = v_t), '[]'));
end $$;

create or replace function private.gam_ensure_tenant_rows(p_slug text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_slug = 'default' then raise exception 'cannot edit the shared template' using errcode = '42501'; end if;
  if exists (select 1 from private.gamification_config where tenant_slug = p_slug) then return; end if;
  insert into private.gamification_config (tenant_slug, points_per_ticket, points_per_sale, include_content_points,
    content_flyer_points, content_original_points, milestones)
  select p_slug, points_per_ticket, points_per_sale, include_content_points, content_flyer_points, content_original_points, milestones
  from private.gamification_config where tenant_slug = 'default';
  insert into private.gamification_tiers (tenant_slug, name, min_points, icon, color, perk)
  select p_slug, name, min_points, icon, color, perk from private.gamification_tiers where tenant_slug = 'default' on conflict do nothing;
  insert into private.gamification_badges (tenant_slug, code, name, icon, description, metric, threshold, sort_order, active)
  select p_slug, code, name, icon, description, metric, threshold, sort_order, active from private.gamification_badges where tenant_slug = 'default' on conflict do nothing;
end $$;
revoke all on function private.gam_ensure_tenant_rows(text) from public, anon, authenticated;

-- p_config: any of points_per_ticket, points_per_sale, include_content_points,
--   content_flyer_points, content_original_points, milestones.
-- p_tiers / p_badges: arrays of rows, upserted by name / code.
create or replace function public.gamification_update_settings(p_tenant text, p_config jsonb default null,
  p_tiers jsonb default null, p_badges jsonb default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); x jsonb;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'admin only' using errcode = '42501'; end if;
  perform private.gam_ensure_tenant_rows(v_slug);
  if p_config is not null then
    update private.gamification_config c set
      points_per_ticket       = coalesce((p_config->>'points_per_ticket')::int, c.points_per_ticket),
      points_per_sale         = coalesce((p_config->>'points_per_sale')::int, c.points_per_sale),
      include_content_points  = coalesce((p_config->>'include_content_points')::boolean, c.include_content_points),
      content_flyer_points    = coalesce((p_config->>'content_flyer_points')::int, c.content_flyer_points),
      content_original_points = coalesce((p_config->>'content_original_points')::int, c.content_original_points),
      milestones              = coalesce(p_config->'milestones', c.milestones),
      updated_at = now()
    where c.tenant_slug = v_slug;
  end if;
  for x in select * from jsonb_array_elements(coalesce(p_tiers, '[]')) loop
    insert into private.gamification_tiers (tenant_slug, name, min_points, icon, color, perk)
    values (v_slug, x->>'name', (x->>'min_points')::int, x->>'icon', x->>'color', x->>'perk')
    on conflict (tenant_slug, name) do update set min_points = excluded.min_points,
      icon = coalesce(excluded.icon, private.gamification_tiers.icon),
      color = coalesce(excluded.color, private.gamification_tiers.color),
      perk = coalesce(excluded.perk, private.gamification_tiers.perk);
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p_badges, '[]')) loop
    insert into private.gamification_badges (tenant_slug, code, name, icon, description, metric, threshold, sort_order, active)
    values (v_slug, x->>'code', x->>'name', x->>'icon', x->>'description', x->>'metric', (x->>'threshold')::int,
            coalesce((x->>'sort_order')::int, 0), coalesce((x->>'active')::boolean, true))
    on conflict (tenant_slug, code) do update set
      name = coalesce(excluded.name, private.gamification_badges.name),
      icon = coalesce(excluded.icon, private.gamification_badges.icon),
      description = coalesce(excluded.description, private.gamification_badges.description),
      metric = coalesce(excluded.metric, private.gamification_badges.metric),
      threshold = coalesce(excluded.threshold, private.gamification_badges.threshold),
      sort_order = coalesce((x->>'sort_order')::int, private.gamification_badges.sort_order),
      active = coalesce((x->>'active')::boolean, private.gamification_badges.active);
  end loop;
  return public.gamification_settings(v_slug);
end $$;

revoke all on function public.gamification_settings(text) from public, anon;
revoke all on function public.gamification_update_settings(text, jsonb, jsonb, jsonb) from public, anon;
grant execute on function public.gamification_settings(text) to authenticated;
grant execute on function public.gamification_update_settings(text, jsonb, jsonb, jsonb) to authenticated;

-- ───────────── 3. demo_requests: platform owners only ─────────────
create table if not exists private.platform_owners (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  created_at timestamptz not null default now()
);
alter table private.platform_owners enable row level security;
revoke all on private.platform_owners from anon, authenticated;

insert into private.platform_owners (user_id, email)
select u.id, lower(u.email) from auth.users u
where lower(u.email) in ('shaun@submerged.events', 'shaun@lakejacksonlanding.com', 'lakejacksonlanding@gmail.com')
on conflict (user_id) do nothing;

create or replace function public.is_platform_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (select 1 from private.platform_owners p where p.user_id = auth.uid());
$$;
revoke all on function public.is_platform_owner() from public, anon;
grant execute on function public.is_platform_owner() to authenticated;

drop policy if exists "Admins read demo requests" on public.demo_requests;
create policy "Platform owners read demo requests" on public.demo_requests
  for select to authenticated using ((select public.is_platform_owner()));
create policy "Platform owners update demo requests" on public.demo_requests
  for update to authenticated using ((select public.is_platform_owner())) with check ((select public.is_platform_owner()));

-- ───────────── 6. invite-only signup ─────────────
create table if not exists private.tenant_settings (
  tenant_slug text primary key,
  invite_only boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table private.tenant_settings enable row level security;
revoke all on private.tenant_settings from anon, authenticated;
insert into private.tenant_settings (tenant_slug, invite_only) values ('submerged', false), ('acme-demo', true)
on conflict (tenant_slug) do nothing;

-- Unknown teams default to invite-only. Only submerged is open by default.
create or replace function private.tenant_invite_only(p_tenant text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select s.invite_only from private.tenant_settings s where s.tenant_slug = private.norm_tenant(p_tenant)),
                  private.norm_tenant(p_tenant) <> 'submerged');
$$;

create table if not exists public.tenant_invites (
  id uuid primary key default gen_random_uuid(),
  tenant_slug text not null,
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  label text,
  max_uses integer check (max_uses is null or max_uses >= 1),
  use_count integer not null default 0,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  constraint tenant_invites_code_format check (code ~ '^[A-Z0-9]{6,32}$')
);
alter table public.tenant_invites enable row level security;
revoke all on public.tenant_invites from anon;
grant select, insert, update on public.tenant_invites to authenticated;

create or replace function private.tg_tenant_invite_norm()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.tenant_slug := private.norm_tenant(new.tenant_slug);
  new.code := upper(regexp_replace(coalesce(new.code, ''), '[^A-Za-z0-9]', '', 'g'));
  if tg_op = 'UPDATE' then
    new.tenant_slug := old.tenant_slug;
    new.code := old.code;
    new.created_by := old.created_by;
    -- Only the signup gate (which sets this txn-local flag) may move use_count.
    if coalesce(auth.role(), '') in ('authenticated', 'anon')
       and coalesce(current_setting('woosah.invite_redeem', true), '') <> '1' then
      new.use_count := old.use_count;
    end if;
  else
    if coalesce(auth.role(), '') in ('authenticated', 'anon') then
      new.use_count := 0;
      new.created_by := auth.uid();
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_tenant_invite_norm on public.tenant_invites;
create trigger trg_tenant_invite_norm before insert or update on public.tenant_invites
  for each row execute function private.tg_tenant_invite_norm();

create policy "Tenant admins read invites" on public.tenant_invites
  for select to authenticated using (public.is_tenant_admin(tenant_slug));
create policy "Tenant admins create invites" on public.tenant_invites
  for insert to authenticated with check (public.is_tenant_admin(tenant_slug));
create policy "Tenant admins update invites" on public.tenant_invites
  for update to authenticated using (public.is_tenant_admin(tenant_slug)) with check (public.is_tenant_admin(tenant_slug));

alter table public.reps add column if not exists invite_code text;
alter table public.reps add column if not exists invite_id uuid references public.tenant_invites(id);
alter table public.reps add column if not exists terms_accepted_at timestamptz;

-- Runs after trg_stamp_tenant (BEFORE triggers fire in name order).
create or replace function private.tg_reps_signup_gate()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_slug text; v_code text; v_inv public.tenant_invites%rowtype;
begin
  if tg_op = 'UPDATE' then
    new.invite_id := old.invite_id;
    new.invite_code := null;
    new.terms_accepted_at := old.terms_accepted_at;
    return new;
  end if;
  -- Server-side callers (service role, SQL, webhook) are not self-signups.
  if coalesce(auth.role(), '') not in ('authenticated', 'anon') then return new; end if;
  v_slug := private.norm_tenant(new.tenant_slug);
  -- Team admins adding reps by hand do not need an invite.
  if public.is_tenant_admin(v_slug) then new.invite_code := null; return new; end if;
  if new.terms_accepted_at is null then
    raise exception 'terms_not_accepted' using errcode = '42501', hint = 'Agree to the Terms of Use to create an account.';
  end if;
  new.terms_accepted_at := now();
  if not private.tenant_invite_only(v_slug) then new.invite_code := null; return new; end if;
  v_code := upper(regexp_replace(coalesce(new.invite_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_code = '' then
    raise exception 'invite_required' using errcode = '42501', hint = 'This team is invite-only.';
  end if;
  select * into v_inv from public.tenant_invites i
   where i.code = v_code and i.tenant_slug = v_slug for update;
  if not found or v_inv.revoked_at is not null
     or (v_inv.expires_at is not null and v_inv.expires_at <= now())
     or (v_inv.max_uses is not null and v_inv.use_count >= v_inv.max_uses) then
    raise exception 'invite_invalid' using errcode = '42501', hint = 'That invite is not valid for this team.';
  end if;
  perform set_config('woosah.invite_redeem', '1', true);
  update public.tenant_invites set use_count = use_count + 1 where id = v_inv.id;
  perform set_config('woosah.invite_redeem', '', true);
  new.invite_id := v_inv.id;
  new.invite_code := null;
  return new;
end $$;
drop trigger if exists trg_zz_signup_gate on public.reps;
create trigger trg_zz_signup_gate before insert or update on public.reps
  for each row execute function private.tg_reps_signup_gate();

-- Public signup helpers (booleans only).
create or replace function public.tenant_signup_info(p_tenant text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('invite_only', private.tenant_invite_only(p_tenant));
$$;
create or replace function public.check_invite(p_tenant text, p_code text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.tenant_invites i
    where i.tenant_slug = private.norm_tenant(p_tenant)
      and i.code = upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'))
      and i.revoked_at is null
      and (i.expires_at is null or i.expires_at > now())
      and (i.max_uses is null or i.use_count < i.max_uses));
$$;
grant execute on function public.tenant_signup_info(text) to anon, authenticated;
grant execute on function public.check_invite(text, text) to anon, authenticated;
