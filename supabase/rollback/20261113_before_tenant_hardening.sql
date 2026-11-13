-- Rollback snapshot taken 2026-11-13 before migration 20261113190000_tenant_hardening.
-- Restores the gamification, demo_requests and signup behavior as it was.
-- It does not delete rows. New tables (private.platform_owners,
-- private.tenant_settings, public.tenant_invites) and new reps columns are
-- left in place; they are inert once the trigger and policies below are restored.
begin;

-- 1. Signup gate off
drop trigger if exists trg_zz_signup_gate on public.reps;

-- 2. Policies on affected tables back to their previous form
drop policy if exists "Tenant admins manage gamification_config" on private.gamification_config;
drop policy if exists "Tenant admins manage gamification_tiers" on private.gamification_tiers;
drop policy if exists "Tenant admins manage gamification_badges" on private.gamification_badges;
drop policy if exists "Tenant admins manage gamification_leaderboard_exclusions" on private.gamification_leaderboard_exclusions;
drop policy if exists "Platform owners read demo requests" on public.demo_requests;
drop policy if exists "Platform owners update demo requests" on public.demo_requests;
CREATE POLICY "Admins manage gamification_config" ON private.gamification_config AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Admins manage gamification_tiers" ON private.gamification_tiers AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Admins manage gamification_badges" ON private.gamification_badges AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Admins manage gamification_leaderboard_exclusions" ON private.gamification_leaderboard_exclusions AS PERMISSIVE FOR ALL TO authenticated USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "Admins read demo requests" ON public.demo_requests AS PERMISSIVE FOR SELECT TO authenticated USING (( SELECT is_admin() AS is_admin));

-- 3. Functions exactly as they were (full snapshot of public/private functions)
CREATE OR REPLACE FUNCTION public.gamification_my_progress(p_tenant text DEFAULT 'submerged'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select private.gam_my_progress(p_tenant);
$function$
;

CREATE OR REPLACE FUNCTION private.promo_code_available(p_code text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_code text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(v_code) < 3 or length(v_code) > 16 then return false; end if;
  return not exists (
    select 1 from public.reps r
    where upper(r.promo_code) = v_code
      and (auth.uid() is null or r.user_id is distinct from auth.uid())
  );
end $function$
;

CREATE OR REPLACE FUNCTION public.gamification_admin_reps(p_tenant text DEFAULT 'submerged'::text)
 RETURNS TABLE(rep_id uuid, points integer, tickets integer, sales_count integer, shows_joined integer, shows_sold_at integer, sale_points integer, content_points integer, milestone_points integer, tier_name text, tier_icon text, tier_color text, badge_count integer, badge_icons text, overall_pos integer, excluded boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select * from private.gam_admin_reps(p_tenant);
$function$
;

CREATE OR REPLACE FUNCTION public.promo_code_available(p_code text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select private.promo_code_available(p_code);
$function$
;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1 FROM public.admins a WHERE a.user_id = auth.uid()
  );
$function$
;

CREATE OR REPLACE FUNCTION private.gam_auto_exclude_hidden_user_rep()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if exists (select 1 from private.gamification_hidden_users h
             where h.user_id = new.user_id or h.email = lower(new.email))
     and not exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = new.id) then
    insert into private.gamification_leaderboard_exclusions (rep_id, reason) values (new.id, 'admin account');
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.update_rep_rank()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.rank := case
    when new.lifetime_points >= 5000 then 'Legend'
    when new.lifetime_points >= 2500 then 'Closer'
    when new.lifetime_points >= 1000 then 'Hotshot'
    when new.lifetime_points >= 400  then 'Rising Star'
    else 'Recruit'
  end;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_cash_rate(rep_rank text)
 RETURNS numeric
 LANGUAGE plpgsql
AS $function$
begin
  return case rep_rank
    when 'Legend' then 3.00
    when 'Closer' then 3.00
    when 'Hotshot' then 2.50
    else 2.00
  end;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.gam_tenant(p_tenant text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select coalesce(
    (select c.tenant_slug from private.gamification_config c where c.tenant_slug = p_tenant),
    'default');
$function$
;

CREATE OR REPLACE FUNCTION private.gam_leaderboard(p_event_id uuid, p_limit integer, p_tenant text)
 RETURNS TABLE(pos integer, display_name text, promo_code text, tier_name text, tier_icon text, tier_color text, points integer, tickets integer, is_me boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_t   text := private.gam_tenant(p_tenant);
  v_lim int  := least(greatest(coalesce(p_limit,25),1),100);
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '42501'; end if;

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
    and not exists (select 1 from private.gamification_leaderboard_exclusions x where x.rep_id = r.id)
  order by s.pts desc, s.tix desc, r.created_at asc
  limit v_lim;
end $function$
;

CREATE OR REPLACE FUNCTION public.gamification_leaderboard(p_event_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 25, p_tenant text DEFAULT 'submerged'::text)
 RETURNS TABLE(pos integer, display_name text, promo_code text, tier_name text, tier_icon text, tier_color text, points integer, tickets integer, is_me boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select * from private.gam_leaderboard(p_event_id, p_limit, p_tenant);
$function$
;

CREATE OR REPLACE FUNCTION private.gam_display_name(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select case
    when coalesce(trim(p_name),'') = '' then 'Rep'
    when split_part(trim(p_name),' ',2) = '' then split_part(trim(p_name),' ',1)
    else split_part(trim(p_name),' ',1) || ' ' || upper(left(split_part(trim(p_name),' ',2),1)) || '.'
  end;
$function$
;

CREATE OR REPLACE FUNCTION private.gam_rep_event_points(p_tenant text)
 RETURNS TABLE(rep_id uuid, event_id uuid, tickets integer, sales_count integer, sale_points integer, milestone_points integer, content_points integer)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with cfg as (
    select * from private.gamification_config where tenant_slug = private.gam_tenant(p_tenant)
  ),
  s as (
    select res.rep_id, res.event_id, res.tickets, res.sales_count
    from private.rep_event_sales res
    join public.reps r on r.id = res.rep_id
    where private.tenant_row_matches(r.tenant_slug, p_tenant)
  ),
  c as (
    select cs.rep_id, cs.event_id,
           sum(case cs.content_type
                 when 'flyer_share'      then cfg.content_flyer_points
                 when 'original_content' then cfg.content_original_points
                 else 0 end)::int as pts
    from public.content_submissions cs
    join public.reps r on r.id = cs.rep_id
    cross join cfg
    where cs.status = 'approved' and cs.rep_id is not null and cfg.include_content_points
      and private.tenant_row_matches(r.tenant_slug, p_tenant)
    group by cs.rep_id, cs.event_id
  ),
  k as (select s.rep_id, s.event_id from s union select c.rep_id, c.event_id from c)
  select k.rep_id, k.event_id,
         coalesce(s.tickets,0), coalesce(s.sales_count,0),
         (coalesce(s.tickets,0) * cfg.points_per_ticket + coalesce(s.sales_count,0) * cfg.points_per_sale)::int,
         coalesce((select sum((m->>'points')::int) from jsonb_array_elements(cfg.milestones) m
                   where coalesce(s.tickets,0) >= (m->>'tickets')::int), 0)::int,
         coalesce(c.pts,0)
  from k cross join cfg
  left join s on s.rep_id = k.rep_id and s.event_id is not distinct from k.event_id
  left join c on c.rep_id = k.rep_id and c.event_id is not distinct from k.event_id;
$function$
;

CREATE OR REPLACE FUNCTION private.gam_my_progress(p_tenant text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_t text := private.gam_tenant(p_tenant);
  v_rep uuid;
  s record; cur record; nxt record; cfg record;
  v_pos int; v_total int; v_pct int; v_badges jsonb; v_tiers jsonb; v_hidden boolean;
begin
  if auth.uid() is null then return null; end if;
  select r.id into v_rep from public.reps r where r.user_id = auth.uid() order by r.created_at limit 1;
  if v_rep is null then return null; end if;

  select * into cfg from private.gamification_config c where c.tenant_slug = v_t;
  select * into s from private.gam_rep_stats(p_tenant) st where st.rep_id = v_rep;
  v_hidden := exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = v_rep);

  select gt.* into cur from private.gamification_tiers gt
    where gt.tenant_slug = v_t and gt.min_points <= s.points order by gt.min_points desc limit 1;
  select gt.* into nxt from private.gamification_tiers gt
    where gt.tenant_slug = v_t and gt.min_points > s.points order by gt.min_points asc limit 1;

  v_pct := case when nxt.name is null then 100
                else floor(100.0 * (s.points - coalesce(cur.min_points,0))
                           / greatest(nxt.min_points - coalesce(cur.min_points,0),1))::int end;

  select x.pos, x.total into v_pos, v_total from (
    select st.rep_id, (rank() over (order by st.points desc, st.tickets desc))::int pos,
           (count(*) over ())::int total
    from private.gam_rep_stats(p_tenant) st
    join public.reps r on r.id = st.rep_id
    where r.status = 'active'
      and not exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = r.id)
  ) x where x.rep_id = v_rep;

  select coalesce(jsonb_agg(jsonb_build_object(
           'code', b.code, 'name', b.name, 'icon', b.icon, 'description', b.description,
           'threshold', b.threshold, 'progress', least(m.val, b.threshold), 'earned', m.val >= b.threshold)
         order by b.sort_order), '[]'::jsonb)
    into v_badges
  from private.gamification_badges b
  cross join lateral (select case b.metric
      when 'total_tickets'    then s.tickets
      when 'total_sales'      then s.sales_count
      when 'max_show_tickets' then s.max_show_tickets
      when 'shows_joined'     then s.shows_joined
      when 'shows_sold_at'    then s.shows_sold_at end as val) m
  where b.tenant_slug = v_t and b.active;

  select coalesce(jsonb_agg(jsonb_build_object('name', gt.name, 'min_points', gt.min_points,
           'icon', gt.icon, 'color', gt.color, 'perk', gt.perk) order by gt.min_points), '[]'::jsonb)
    into v_tiers
  from private.gamification_tiers gt where gt.tenant_slug = v_t;

  return jsonb_build_object(
    'points', s.points, 'tickets', s.tickets, 'sales', s.sales_count,
    'shows_joined', s.shows_joined, 'shows_sold_at', s.shows_sold_at,
    'max_show_tickets', s.max_show_tickets,
    'breakdown', jsonb_build_object('sales', s.sale_points, 'content', s.content_points,
                                    'milestones', s.milestone_points),
    'content_points', s.content_points,
    'tier', jsonb_build_object('name', cur.name, 'min_points', cur.min_points, 'icon', cur.icon,
                               'color', cur.color, 'perk', cur.perk),
    'next_tier', case when nxt.name is null then null else
                 jsonb_build_object('name', nxt.name, 'min_points', nxt.min_points, 'icon', nxt.icon,
                                    'color', nxt.color, 'points_to_go', nxt.min_points - s.points) end,
    'progress_pct', greatest(0, least(100, v_pct)),
    'position', v_pos, 'total_reps', v_total, 'hidden_from_leaderboard', v_hidden,
    'badges', v_badges, 'tiers', v_tiers,
    'rules', jsonb_build_object('points_per_ticket', cfg.points_per_ticket,
                                'points_per_sale', cfg.points_per_sale,
                                'include_content_points', cfg.include_content_points,
                                'content_flyer_points', cfg.content_flyer_points,
                                'content_original_points', cfg.content_original_points,
                                'milestones', cfg.milestones)
  );
end $function$
;

CREATE OR REPLACE FUNCTION private.promote_pending_admin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
begin
  if exists (select 1 from private.pending_admins p where lower(p.email) = lower(new.email)) then
    insert into public.admins (user_id, email) values (new.id, lower(new.email)) on conflict do nothing;
    insert into private.gamification_hidden_users (user_id, email) values (new.id, lower(new.email)) on conflict do nothing;
    delete from private.pending_admins where lower(email) = lower(new.email);
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION private.tenant_row_matches(p_row_slug text, p_tenant text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  -- NULL row slugs belong to submerged only. Other tenants do not see them.
  select case
    when p_tenant is null or btrim(p_tenant) = '' then false
    when lower(btrim(p_tenant)) = 'submerged' then
      p_row_slug is null or lower(p_row_slug) = 'submerged'
    else lower(coalesce(p_row_slug, '')) = lower(btrim(p_tenant))
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_tenant_admin(p_tenant text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private'
AS $function$
  select exists (
    select 1
    from public.admins a
    where a.user_id = auth.uid()
      and private.tenant_row_matches(a.tenant_slug, p_tenant)
  );
$function$
;

CREATE OR REPLACE FUNCTION private.tg_stamp_rep_tenant()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' then
    new.tenant_slug := old.tenant_slug;
    return new;
  end if;
  new.tenant_slug := coalesce(nullif(lower(btrim(new.tenant_slug)), ''), 'submerged');
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION private.tg_stamp_tenant_from_rep()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION private.tg_stamp_tenant_standalone()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION private.gam_rep_stats(p_tenant text)
 RETURNS TABLE(rep_id uuid, tickets integer, sales_count integer, shows_joined integer, shows_sold_at integer, max_show_tickets integer, sale_points integer, content_points integer, milestone_points integer, points integer)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with ep as (select * from private.gam_rep_event_points(p_tenant)),
  agg as (
    select ep.rep_id,
           sum(ep.tickets)::int                            as tickets,
           sum(ep.sales_count)::int                        as sales_count,
           count(*) filter (where ep.tickets > 0)::int     as shows_sold_at,
           max(ep.tickets)::int                            as max_show_tickets,
           sum(ep.sale_points)::int                        as sale_points,
           sum(ep.content_points)::int                     as content_points,
           sum(ep.milestone_points)::int                   as milestone_points
    from ep group by ep.rep_id
  ),
  joined as (
    select u.rep_id, count(distinct u.event_id)::int as shows_joined
    from (
      select re.rep_id, re.event_id
      from public.rep_events re
      join public.reps r_join on r_join.id = re.rep_id
      where re.rep_id is not null
        and private.tenant_row_matches(r_join.tenant_slug, p_tenant)
      union
      select res.rep_id, res.event_id
      from private.rep_event_sales res
      join public.reps r_sale on r_sale.id = res.rep_id
      where private.tenant_row_matches(r_sale.tenant_slug, p_tenant)
    ) u
    where u.event_id is not null
    group by u.rep_id
  )
  select r.id,
         coalesce(a.tickets,0), coalesce(a.sales_count,0), coalesce(j.shows_joined,0),
         coalesce(a.shows_sold_at,0), coalesce(a.max_show_tickets,0),
         coalesce(a.sale_points,0), coalesce(a.content_points,0), coalesce(a.milestone_points,0),
         (coalesce(a.sale_points,0) + coalesce(a.content_points,0) + coalesce(a.milestone_points,0))::int
  from public.reps r
  left join agg    a on a.rep_id = r.id
  left join joined j on j.rep_id = r.id
  where private.tenant_row_matches(r.tenant_slug, p_tenant);
$function$
;

CREATE OR REPLACE FUNCTION private.gam_admin_reps(p_tenant text)
 RETURNS TABLE(rep_id uuid, points integer, tickets integer, sales_count integer, shows_joined integer, shows_sold_at integer, sale_points integer, content_points integer, milestone_points integer, tier_name text, tier_icon text, tier_color text, badge_count integer, badge_icons text, overall_pos integer, excluded boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
;

commit;
