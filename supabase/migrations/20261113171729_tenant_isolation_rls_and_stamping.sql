-- =============================================================================
-- Tenant isolation: stamp tenant_slug on writes, tenant-scoped admin RLS.
-- Does not delete or backfill existing data rows (legacy NULL still means
-- submerged). Existing admins are tagged tenant_slug = 'submerged'.
-- =============================================================================

-- 1. Tenant-scoped admin mapping
alter table public.admins add column if not exists tenant_slug text;
update public.admins
   set tenant_slug = 'submerged'
 where tenant_slug is null;
comment on column public.admins.tenant_slug is
  'Tenant this admin may manage. NULL means submerged, same as the core tables.';
create index if not exists admins_tenant_slug_idx on public.admins (tenant_slug);

-- 2. Helpers
create or replace function public.is_tenant_admin(p_tenant text)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'private'
as $$
  select exists (
    select 1
    from public.admins a
    where a.user_id = auth.uid()
      and private.tenant_row_matches(a.tenant_slug, p_tenant)
  );
$$;

comment on function public.is_tenant_admin(text) is
  'True when the signed-in user is an admin for this tenant. NULL admin or row slugs mean submerged.';

revoke all on function public.is_tenant_admin(text) from public, anon;
grant execute on function public.is_tenant_admin(text) to authenticated, service_role;

-- 3. Stamp triggers: INSERT sets tenant; UPDATE preserves the existing value
--    so legacy NULL rows are not rewritten.

create or replace function private.tg_stamp_rep_tenant()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'UPDATE' then
    new.tenant_slug := old.tenant_slug;
    return new;
  end if;
  new.tenant_slug := coalesce(nullif(lower(btrim(new.tenant_slug)), ''), 'submerged');
  return new;
end;
$$;

create or replace function private.tg_stamp_tenant_from_rep()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_slug text;
begin
  if tg_op = 'UPDATE' then
    new.tenant_slug := old.tenant_slug;
    return new;
  end if;
  if new.rep_id is not null then
    select r.tenant_slug into v_slug from public.reps r where r.id = new.rep_id;
    new.tenant_slug := coalesce(nullif(lower(btrim(v_slug)), ''), 'submerged');
  else
    new.tenant_slug := coalesce(nullif(lower(btrim(new.tenant_slug)), ''), 'submerged');
  end if;
  return new;
end;
$$;

create or replace function private.tg_stamp_tenant_standalone()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_admin text;
begin
  if tg_op = 'UPDATE' then
    new.tenant_slug := old.tenant_slug;
    return new;
  end if;
  if new.tenant_slug is not null and btrim(new.tenant_slug) <> '' then
    new.tenant_slug := lower(btrim(new.tenant_slug));
  else
    new.tenant_slug := null;
  end if;
  -- Admins cannot write a tenant they do not administer. Service role
  -- (the Eventbrite webhook) has no JWT, so a provided slug is kept.
  if public.is_admin() then
    select coalesce(nullif(lower(btrim(a.tenant_slug)), ''), 'submerged')
      into v_admin
      from public.admins a
     where a.user_id = auth.uid();
    if v_admin is not null then
      new.tenant_slug := v_admin;
    end if;
  elsif new.tenant_slug is null then
    new.tenant_slug := 'submerged';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_stamp_tenant on public.reps;
create trigger trg_stamp_tenant
  before insert or update on public.reps
  for each row execute function private.tg_stamp_rep_tenant();

drop trigger if exists trg_stamp_tenant on public.rep_events;
create trigger trg_stamp_tenant
  before insert or update on public.rep_events
  for each row execute function private.tg_stamp_tenant_from_rep();

drop trigger if exists trg_stamp_tenant on public.sales;
create trigger trg_stamp_tenant
  before insert or update on public.sales
  for each row execute function private.tg_stamp_tenant_from_rep();

drop trigger if exists trg_stamp_tenant on public.content_submissions;
create trigger trg_stamp_tenant
  before insert or update on public.content_submissions
  for each row execute function private.tg_stamp_tenant_from_rep();

drop trigger if exists trg_stamp_tenant on public.points_log;
create trigger trg_stamp_tenant
  before insert or update on public.points_log
  for each row execute function private.tg_stamp_tenant_from_rep();

drop trigger if exists trg_stamp_tenant on public.payouts;
create trigger trg_stamp_tenant
  before insert or update on public.payouts
  for each row execute function private.tg_stamp_tenant_from_rep();

drop trigger if exists trg_stamp_tenant on public.badges;
create trigger trg_stamp_tenant
  before insert or update on public.badges
  for each row execute function private.tg_stamp_tenant_from_rep();

drop trigger if exists trg_stamp_tenant on public.events;
create trigger trg_stamp_tenant
  before insert or update on public.events
  for each row execute function private.tg_stamp_tenant_standalone();

drop trigger if exists trg_stamp_tenant on public.weekly_mixes;
create trigger trg_stamp_tenant
  before insert or update on public.weekly_mixes
  for each row execute function private.tg_stamp_tenant_standalone();

drop trigger if exists trg_stamp_tenant on public.webhook_inbox;
create trigger trg_stamp_tenant
  before insert or update on public.webhook_inbox
  for each row execute function private.tg_stamp_tenant_standalone();

drop trigger if exists trg_stamp_tenant on public.product_events;
create trigger trg_stamp_tenant
  before insert or update on public.product_events
  for each row execute function private.tg_stamp_tenant_standalone();

-- 4. RLS: admins only see their tenant (NULL row slug = submerged).
--    Rep own-row policies are left in place.

drop policy if exists "Admins read reps" on public.reps;
create policy "Admins read reps" on public.reps
  as permissive for select to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins insert reps" on public.reps;
create policy "Admins insert reps" on public.reps
  as permissive for insert to authenticated
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins update reps" on public.reps;
create policy "Admins update reps" on public.reps
  as permissive for update to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins manage events" on public.events;
create policy "Admins manage events" on public.events
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Reps read events" on public.events;
create policy "Reps read events" on public.events
  as permissive for select to authenticated
  using (
    exists (
      select 1 from public.reps r
      where r.user_id = auth.uid()
        and private.tenant_row_matches(events.tenant_slug, coalesce(r.tenant_slug, 'submerged'))
    )
    -- Block dual-role leak: an admin of another tenant must not read this
    -- tenant's catalog through their leftover rep profile.
    and not (
      public.is_admin()
      and not public.is_tenant_admin(coalesce(events.tenant_slug, 'submerged'))
    )
  );

drop policy if exists "Admins manage sales" on public.sales;
create policy "Admins manage sales" on public.sales
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins manage rep_events" on public.rep_events;
create policy "Admins manage rep_events" on public.rep_events
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins manage content_submissions" on public.content_submissions;
create policy "Admins manage content_submissions" on public.content_submissions
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins manage points_log" on public.points_log;
create policy "Admins manage points_log" on public.points_log
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins manage payouts" on public.payouts;
create policy "Admins manage payouts" on public.payouts
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Admins manage badges" on public.badges;
create policy "Admins manage badges" on public.badges
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Reps read mixes" on public.weekly_mixes;
create policy "Reps read mixes" on public.weekly_mixes
  as permissive for select to authenticated
  using (
    (
      exists (
        select 1 from public.reps r
        where r.user_id = auth.uid()
          and private.tenant_row_matches(weekly_mixes.tenant_slug, coalesce(r.tenant_slug, 'submerged'))
      )
      and not (
        public.is_admin()
        and not public.is_tenant_admin(coalesce(weekly_mixes.tenant_slug, 'submerged'))
      )
    )
    or public.is_tenant_admin(coalesce(tenant_slug, 'submerged'))
  );

drop policy if exists "Admins manage weekly_mixes" on public.weekly_mixes;
create policy "Admins manage weekly_mixes" on public.weekly_mixes
  as permissive for all to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')))
  with check (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists webhook_inbox_select_authenticated on public.webhook_inbox;
create policy webhook_inbox_select_authenticated on public.webhook_inbox
  as permissive for select to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists product_events_select_authenticated on public.product_events;
create policy product_events_select_authenticated on public.product_events
  as permissive for select to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

-- 5. Admin gamification RPC must also require the requested tenant.
create or replace function private.gam_admin_reps(p_tenant text)
returns table(rep_id uuid, points integer, tickets integer, sales_count integer, shows_joined integer, shows_sold_at integer, sale_points integer, content_points integer, milestone_points integer, tier_name text, tier_icon text, tier_color text, badge_count integer, badge_icons text, overall_pos integer, excluded boolean)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare v_t text := private.gam_tenant(p_tenant);
begin
  if not public.is_tenant_admin(p_tenant) then
    raise exception 'admin only' using errcode = '42501';
  end if;
  return query
  with st as (select * from private.gam_rep_stats(p_tenant)),
  ranked as (
    select st.rep_id, (rank() over (order by st.points desc, st.tickets desc))::int pos
    from st join public.reps r on r.id = st.rep_id
    where r.status = 'active'
      and not exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = st.rep_id)
  )
  select st.rep_id, st.points, st.tickets, st.sales_count, st.shows_joined, st.shows_sold_at,
         st.sale_points, st.content_points, st.milestone_points,
         t.name, t.icon, t.color,
         coalesce(b.cnt,0)::int, coalesce(b.icons,''),
         rk.pos,
         exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = st.rep_id)
  from st
  left join ranked rk on rk.rep_id = st.rep_id
  left join lateral (
    select gt.name, gt.icon, gt.color from private.gamification_tiers gt
    where gt.tenant_slug = v_t and gt.min_points <= st.points
    order by gt.min_points desc limit 1) t on true
  left join lateral (
    select count(*) cnt, string_agg(bd.icon, '' order by bd.sort_order) icons
    from private.gamification_badges bd
    where bd.tenant_slug = v_t and bd.active and
      (case bd.metric
         when 'total_tickets'    then st.tickets
         when 'total_sales'      then st.sales_count
         when 'max_show_tickets' then st.max_show_tickets
         when 'shows_joined'     then st.shows_joined
         when 'shows_sold_at'    then st.shows_sold_at end) >= bd.threshold) b on true
  order by st.points desc, st.tickets desc;
end $function$;

-- 6. private.gamification_hidden_users and private.pending_admins:
--    The private schema grants USAGE to anon and authenticated, but these
--    tables have no table grants, and current_setting('pgrst.db_schemas')
--    is unset here (Supabase Data API typically exposes public, not
--    private). Enabling RLS with no policies is defense in depth and
--    does not change access: the client already cannot SELECT/INSERT.
--    Functions that touch these tables are SECURITY DEFINER and do not
--    use FORCE ROW LEVEL SECURITY, so they keep working.
alter table private.gamification_hidden_users enable row level security;
alter table private.pending_admins enable row level security;
