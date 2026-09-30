-- ════════════════════════════════════════════════════════════════════
-- Gamification follow-ups (PR #4)
--  1. Hide house/test accounts (TEST, SUB45) from leaderboards.
--  2. Content + milestone bonus points — still fully derived:
--       content   : approved content_submissions × per-type value
--                   (flyer_share 50, original_content 150). Un-approve → gone.
--       milestones: per show, matching the Eventbrite webhook's existing
--                   logic (tickets for ONE show crossing 10 / 25 / 50 →
--                   +200 / +500 / +1,000). Refund a sale below a threshold → gone.
--     Values live in private.gamification_config.
--  3. promo_code_available(code) for signup / promo edits, so the portal no
--     longer needs to read other reps' rows (prep for reps RLS tightening).
-- Additive to production objects; only private.* gamification objects change.
-- ════════════════════════════════════════════════════════════════════

-- 1 ── Leaderboard exclusions (looked up by promo code, no hardcoded ids)
insert into private.gamification_leaderboard_exclusions (rep_id, reason)
select r.id, 'house/test account' from public.reps r where r.promo_code in ('TEST','SUB45')
on conflict (rep_id) do nothing;

-- 2 ── Config: content + milestone values
alter table private.gamification_config
  add column if not exists content_flyer_points    integer not null default 50  check (content_flyer_points >= 0),
  add column if not exists content_original_points integer not null default 150 check (content_original_points >= 0),
  add column if not exists milestones jsonb not null
    default '[{"tickets":10,"points":200},{"tickets":25,"points":500},{"tickets":50,"points":1000}]'::jsonb;
comment on column private.gamification_config.milestones is
  'Per-show ticket milestones: [{tickets, points}]. Cash bonuses ($10 @25, $25 @50) are paid by the eventbrite-webhook, not derived here.';
update private.gamification_config set include_content_points = true, updated_at = now()
where tenant_slug = 'default';

-- Per rep × show points breakdown (the single source of truth for points).
create or replace function private.gam_rep_event_points(p_tenant text)
returns table (rep_id uuid, event_id uuid, tickets int, sales_count int,
               sale_points int, milestone_points int, content_points int)
language sql stable set search_path = '' as $$
  with cfg as (
    select * from private.gamification_config where tenant_slug = private.gam_tenant(p_tenant)
  ),
  s as (select res.rep_id, res.event_id, res.tickets, res.sales_count from private.rep_event_sales res),
  c as (
    select cs.rep_id, cs.event_id,
           sum(case cs.content_type
                 when 'flyer_share'      then cfg.content_flyer_points
                 when 'original_content' then cfg.content_original_points
                 else 0 end)::int as pts
    from public.content_submissions cs cross join cfg
    where cs.status = 'approved' and cs.rep_id is not null and cfg.include_content_points
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
$$;

drop function if exists private.gam_rep_stats(text);
create function private.gam_rep_stats(p_tenant text)
returns table (rep_id uuid, tickets int, sales_count int, shows_joined int,
               shows_sold_at int, max_show_tickets int,
               sale_points int, content_points int, milestone_points int, points int)
language sql stable set search_path = '' as $$
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
    from (select re.rep_id, re.event_id from public.rep_events re where re.rep_id is not null
          union
          select res.rep_id, res.event_id from private.rep_event_sales res) u
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
  left join joined j on j.rep_id = r.id;
$$;

-- Leaderboard: overall = lifetime points; per show = that show's sale + milestone + content points.
create or replace function private.gam_leaderboard(p_event_id uuid, p_limit int, p_tenant text)
returns table (pos int, display_name text, promo_code text, tier_name text, tier_icon text,
               tier_color text, points int, tickets int, is_me boolean)
language plpgsql stable security definer set search_path = '' as $$
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
end $$;

create or replace function private.gam_my_progress(p_tenant text)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
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
end $$;

-- Admin RPC gains a points breakdown (return type change → drop + recreate).
drop function if exists public.gamification_admin_reps(text);
drop function if exists private.gam_admin_reps(text);
create function private.gam_admin_reps(p_tenant text)
returns table (rep_id uuid, points int, tickets int, sales_count int, shows_joined int,
               shows_sold_at int, sale_points int, content_points int, milestone_points int,
               tier_name text, tier_icon text, tier_color text,
               badge_count int, badge_icons text, overall_pos int, excluded boolean)
language plpgsql stable security definer set search_path = '' as $$
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
end $$;

create function public.gamification_admin_reps(p_tenant text default 'submerged')
returns table (rep_id uuid, points int, tickets int, sales_count int, shows_joined int,
               shows_sold_at int, sale_points int, content_points int, milestone_points int,
               tier_name text, tier_icon text, tier_color text,
               badge_count int, badge_icons text, overall_pos int, excluded boolean)
language sql stable security invoker set search_path = '' as $$
  select * from private.gam_admin_reps(p_tenant);
$$;

-- 3 ── Promo code availability (signup runs as anon; promo edits as authenticated)
create or replace function private.promo_code_available(p_code text)
returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_code text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(v_code) < 3 or length(v_code) > 16 then return false; end if;
  -- Available if nobody has it, or the only holder is the caller's own rep row.
  return not exists (
    select 1 from public.reps r
    where upper(r.promo_code) = v_code
      and (auth.uid() is null or r.user_id is distinct from auth.uid())
  );
end $$;

create or replace function public.promo_code_available(p_code text)
returns boolean language sql stable security invoker set search_path = '' as $$
  select private.promo_code_available(p_code);
$$;

-- ── Privileges ──
grant usage on schema private to anon;  -- needed only to reach promo_code_available
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.gam_leaderboard(uuid,int,text) to authenticated;
grant execute on function private.gam_my_progress(text)          to authenticated;
grant execute on function private.gam_admin_reps(text)           to authenticated;
grant execute on function private.promo_code_available(text)     to anon, authenticated;

revoke all on function public.gamification_admin_reps(text) from public, anon;
grant execute on function public.gamification_admin_reps(text) to authenticated;
revoke all on function public.promo_code_available(text) from public;
grant execute on function public.promo_code_available(text) to anon, authenticated;
