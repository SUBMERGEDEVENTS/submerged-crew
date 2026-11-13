-- =============================================================================
-- ROLLBACK snapshot taken 2026-11-13, before tenant-isolation RLS and
-- write-stamping were applied. This file restores policies, the
-- gam_admin_reps admin gate, and RLS flags as they were. It does not
-- delete rows.
--
-- It will:
--   * drop the new triggers, is_tenant_admin(), and stamp functions
--   * drop public.admins.tenant_slug
--   * restore the previous admin/read policies (is_admin() / qual true)
--   * restore private.gam_admin_reps to require is_admin()
--   * disable RLS again on private.gamification_hidden_users and
--     private.pending_admins
--
-- Only run this if the forward migration must be undone.
-- =============================================================================

drop trigger if exists trg_stamp_tenant on public.reps;
drop trigger if exists trg_stamp_tenant on public.events;
drop trigger if exists trg_stamp_tenant on public.rep_events;
drop trigger if exists trg_stamp_tenant on public.sales;
drop trigger if exists trg_stamp_tenant on public.content_submissions;
drop trigger if exists trg_stamp_tenant on public.points_log;
drop trigger if exists trg_stamp_tenant on public.payouts;
drop trigger if exists trg_stamp_tenant on public.badges;
drop trigger if exists trg_stamp_tenant on public.weekly_mixes;
drop trigger if exists trg_stamp_tenant on public.webhook_inbox;
drop trigger if exists trg_stamp_tenant on public.product_events;

drop function if exists private.tg_stamp_rep_tenant();
drop function if exists private.tg_stamp_tenant_from_rep();
drop function if exists private.tg_stamp_tenant_standalone();
drop function if exists public.is_tenant_admin(text);

alter table public.admins drop column if exists tenant_slug;

-- Restore private.gam_admin_reps to the pre-isolation body (is_admin gate).
create or replace function private.gam_admin_reps(p_tenant text)
returns table(rep_id uuid, points integer, tickets integer, sales_count integer, shows_joined integer, shows_sold_at integer, sale_points integer, content_points integer, milestone_points integer, tier_name text, tier_icon text, tier_color text, badge_count integer, badge_icons text, overall_pos integer, excluded boolean)
language plpgsql
stable security definer
set search_path to ''
as $function$
declare v_t text := private.gam_tenant(p_tenant);
begin
  if not public.is_admin() then raise exception 'admin only' using errcode = '42501'; end if;
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

-- Restore policies captured immediately before the forward migration.

drop policy if exists "Admins manage content_submissions" on public.content_submissions;
create policy "Admins manage content_submissions" on public.content_submissions as permissive for ALL to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "Admins manage events" on public.events;
create policy "Admins manage events" on public.events as permissive for ALL to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "Reps read events" on public.events;
create policy "Reps read events" on public.events as permissive for SELECT to authenticated using (true);

drop policy if exists "Admins manage payouts" on public.payouts;
create policy "Admins manage payouts" on public.payouts as permissive for ALL to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "Admins manage points_log" on public.points_log;
create policy "Admins manage points_log" on public.points_log as permissive for ALL to authenticated using (is_admin()) with check (is_admin());

drop policy if exists product_events_select_authenticated on public.product_events;
create policy product_events_select_authenticated on public.product_events as permissive for SELECT to authenticated using (true);

drop policy if exists "Admins manage rep_events" on public.rep_events;
create policy "Admins manage rep_events" on public.rep_events as permissive for ALL to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "Admins insert reps" on public.reps;
create policy "Admins insert reps" on public.reps as permissive for INSERT to authenticated with check (is_admin());

drop policy if exists "Admins read reps" on public.reps;
create policy "Admins read reps" on public.reps as permissive for SELECT to authenticated using ((SELECT is_admin() AS is_admin));

drop policy if exists "Admins update reps" on public.reps;
create policy "Admins update reps" on public.reps as permissive for UPDATE to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "Admins manage sales" on public.sales;
create policy "Admins manage sales" on public.sales as permissive for ALL to authenticated using (is_admin()) with check (is_admin());

drop policy if exists "Admins manage badges" on public.badges;
drop policy if exists webhook_inbox_select_authenticated on public.webhook_inbox;
create policy webhook_inbox_select_authenticated on public.webhook_inbox as permissive for SELECT to authenticated using (true);

drop policy if exists "Reps read mixes" on public.weekly_mixes;
drop policy if exists "Admins manage weekly_mixes" on public.weekly_mixes;
create policy "Reps read mixes" on public.weekly_mixes as permissive for SELECT to authenticated using (true);

alter table private.gamification_hidden_users disable row level security;
alter table private.pending_admins disable row level security;
