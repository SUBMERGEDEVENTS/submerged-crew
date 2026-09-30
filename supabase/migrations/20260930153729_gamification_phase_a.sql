-- ════════════════════════════════════════════════════════════════════
-- Gamification — Phase A (points · tiers · badges · leaderboard)
-- Additive only: new schema `private`, new tables/views/functions.
-- Does NOT alter or drop any existing table, column, policy or trigger.
--
-- Points rule (configurable in ONE place: private.gamification_config):
--   points = SUM(sales.ticket_quantity) * points_per_ticket      (default 20)
--          + COUNT(sales rows)          * points_per_sale        (default 0)
--          + approved content points    IF include_content_points (default false)
-- Computed live from public.sales on every read → deleting/refunding a sale
-- row automatically lowers points. No mutable balance is stored.
--
-- Tenancy: every config table is keyed by tenant_slug. Lookups fall back to
-- the 'default' row when a tenant has no row of its own, so SUB:MERGED
-- (slug 'submerged') runs on 'default' today and new tenants can override.
--
-- Security: config tables + definer functions live in the non-exposed
-- `private` schema (not reachable through PostgREST). The public RPCs are
-- SECURITY INVOKER wrappers that return only safe, aggregate fields
-- (first name + last initial, promo code, points, tier) — never email,
-- phone, socials or user ids of other reps.
-- ════════════════════════════════════════════════════════════════════

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- ── Config ─────────────────────────────────────────────────────────────
create table if not exists private.gamification_config (
  tenant_slug            text primary key,
  points_per_ticket      integer not null default 20 check (points_per_ticket >= 0),
  points_per_sale        integer not null default 0  check (points_per_sale >= 0),
  include_content_points boolean not null default false,
  updated_at             timestamptz not null default now()
);

create table if not exists private.gamification_tiers (
  tenant_slug text    not null,
  name        text    not null,
  min_points  integer not null check (min_points >= 0),
  icon        text,
  color       text,
  perk        text,
  primary key (tenant_slug, name),
  unique (tenant_slug, min_points)
);

create table if not exists private.gamification_badges (
  tenant_slug text    not null,
  code        text    not null,
  name        text    not null,
  icon        text,
  description text,
  metric      text    not null check (metric in
                ('total_tickets','total_sales','max_show_tickets','shows_joined','shows_sold_at')),
  threshold   integer not null check (threshold > 0),
  sort_order  integer not null default 0,
  active      boolean not null default true,
  primary key (tenant_slug, code)
);

-- Optional: hide house/test accounts from leaderboards (empty by default).
create table if not exists private.gamification_leaderboard_exclusions (
  rep_id     uuid primary key references public.reps(id) on delete cascade,
  reason     text,
  created_at timestamptz not null default now()
);

alter table private.gamification_config                 enable row level security;
alter table private.gamification_tiers                  enable row level security;
alter table private.gamification_badges                 enable row level security;
alter table private.gamification_leaderboard_exclusions enable row level security;
revoke all on all tables in schema private from public, anon, authenticated;

-- Seed defaults. Tier ladder mirrors the existing rank ladder already used in
-- the portal/cash-rate logic (public.update_rep_rank / get_cash_rate) so reps
-- never see two conflicting ladders.
insert into private.gamification_config (tenant_slug) values ('default')
on conflict (tenant_slug) do nothing;

insert into private.gamification_tiers (tenant_slug, name, min_points, icon, color, perk) values
  ('default','Recruit',        0, '🎫', '#7a8799', 'Sell codes to level up to Rising Star'),
  ('default','Rising Star',  400, '🌟', '#22c55e', 'Keep going — Hotshot unlocks $2.50/code'),
  ('default','Hotshot',     1000, '⚡', '#a78bfa', 'Reach Closer for $3/code + cash bonuses'),
  ('default','Closer',      2500, '🔥', '#00D4C8', 'Almost at Legend — the top of the team'),
  ('default','Legend',      5000, '👑', '#f0b429', 'Top tier — $3/code + VIP guest list')
on conflict do nothing;

insert into private.gamification_badges (tenant_slug, code, name, icon, description, metric, threshold, sort_order) values
  ('default','first_sale',    'First Sale',    '🎟️', 'Sell your first ticket',              'total_tickets',     1, 10),
  ('default','double_digits', 'Double Digits', '🔟', 'Sell 10 tickets',                      'total_tickets',    10, 20),
  ('default','packed_house',  'Packed House',  '🏟️', 'Sell 5+ tickets for a single show',    'max_show_tickets',  5, 30),
  ('default','on_tour',       'On Tour',       '🚐', 'Join 3 shows',                         'shows_joined',      3, 40),
  ('default','road_warrior',  'Road Warrior',  '🗺️', 'Make sales at 3 different shows',      'shows_sold_at',     3, 50),
  ('default','fifty_club',    'Fifty Club',    '💯', 'Sell 50 tickets',                      'total_tickets',    50, 60)
on conflict do nothing;

-- ── Core computation ───────────────────────────────────────────────────
-- Per rep × event credited sales (live view over public.sales).
create or replace view private.rep_event_sales as
  select s.rep_id, s.event_id,
         sum(s.ticket_quantity)::int as tickets,
         count(*)::int               as sales_count
  from public.sales s
  where s.rep_id is not null
  group by s.rep_id, s.event_id;
revoke all on private.rep_event_sales from public, anon, authenticated;

create or replace function private.gam_tenant(p_tenant text)
returns text language sql stable set search_path = '' as $$
  select coalesce(
    (select c.tenant_slug from private.gamification_config c where c.tenant_slug = p_tenant),
    'default');
$$;

-- All reps with derived stats + points.
create or replace function private.gam_rep_stats(p_tenant text)
returns table (rep_id uuid, tickets int, sales_count int, shows_joined int,
               shows_sold_at int, max_show_tickets int, content_points int, points int)
language sql stable set search_path = '' as $$
  with cfg as (
    select * from private.gamification_config where tenant_slug = private.gam_tenant(p_tenant)
  ),
  agg as (
    select res.rep_id,
           sum(res.tickets)::int                              as tickets,
           sum(res.sales_count)::int                          as sales_count,
           count(*) filter (where res.tickets > 0)::int       as shows_sold_at,
           max(res.tickets)::int                              as max_show_tickets
    from private.rep_event_sales res group by res.rep_id
  ),
  joined as (
    select u.rep_id, count(distinct u.event_id)::int as shows_joined
    from (select re.rep_id, re.event_id from public.rep_events re where re.rep_id is not null
          union
          select res.rep_id, res.event_id from private.rep_event_sales res) u
    where u.event_id is not null
    group by u.rep_id
  ),
  content as (
    select cs.rep_id, sum(coalesce(cs.points_awarded,0))::int as pts
    from public.content_submissions cs where cs.status = 'approved' group by cs.rep_id
  )
  select r.id,
         coalesce(a.tickets,0), coalesce(a.sales_count,0), coalesce(j.shows_joined,0),
         coalesce(a.shows_sold_at,0), coalesce(a.max_show_tickets,0),
         case when cfg.include_content_points then coalesce(c.pts,0) else 0 end,
         ( coalesce(a.tickets,0)     * cfg.points_per_ticket
         + coalesce(a.sales_count,0) * cfg.points_per_sale
         + case when cfg.include_content_points then coalesce(c.pts,0) else 0 end )::int
  from public.reps r
  cross join cfg
  left join agg     a on a.rep_id = r.id
  left join joined  j on j.rep_id = r.id
  left join content c on c.rep_id = r.id;
$$;

-- Display-safe name: first name + last initial ("Alexa H.").
create or replace function private.gam_display_name(p_name text)
returns text language sql immutable set search_path = '' as $$
  select case
    when coalesce(trim(p_name),'') = '' then 'Rep'
    when split_part(trim(p_name),' ',2) = '' then split_part(trim(p_name),' ',1)
    else split_part(trim(p_name),' ',1) || ' ' || upper(left(split_part(trim(p_name),' ',2),1)) || '.'
  end;
$$;

-- ── Entry points (definer, private schema) ─────────────────────────────
create or replace function private.gam_leaderboard(p_event_id uuid, p_limit int, p_tenant text)
returns table (pos int, display_name text, promo_code text, tier_name text, tier_icon text,
               tier_color text, points int, tickets int, is_me boolean)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_t   text := private.gam_tenant(p_tenant);
  v_lim int  := least(greatest(coalesce(p_limit,25),1),100);
  v_ppt int; v_pps int;
begin
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  select c.points_per_ticket, c.points_per_sale into v_ppt, v_pps
  from private.gamification_config c where c.tenant_slug = v_t;

  return query
  with lifetime as (select * from private.gam_rep_stats(p_tenant)),
  scoped as (
    select l.rep_id,
           case when p_event_id is null then l.points
                else coalesce(e.tickets,0)*v_ppt + coalesce(e.sales_count,0)*v_pps end as pts,
           case when p_event_id is null then l.tickets else coalesce(e.tickets,0) end as tix,
           l.points as lifetime_points
    from lifetime l
    left join private.rep_event_sales e on e.rep_id = l.rep_id and e.event_id = p_event_id
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
  v_pos int; v_total int; v_pct int; v_badges jsonb; v_tiers jsonb;
begin
  if auth.uid() is null then return null; end if;
  select r.id into v_rep from public.reps r where r.user_id = auth.uid() order by r.created_at limit 1;
  if v_rep is null then return null; end if;

  select * into cfg from private.gamification_config c where c.tenant_slug = v_t;
  select * into s from private.gam_rep_stats(p_tenant) st where st.rep_id = v_rep;

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
    'max_show_tickets', s.max_show_tickets, 'content_points', s.content_points,
    'tier', jsonb_build_object('name', cur.name, 'min_points', cur.min_points, 'icon', cur.icon,
                               'color', cur.color, 'perk', cur.perk),
    'next_tier', case when nxt.name is null then null else
                 jsonb_build_object('name', nxt.name, 'min_points', nxt.min_points, 'icon', nxt.icon,
                                    'color', nxt.color, 'points_to_go', nxt.min_points - s.points) end,
    'progress_pct', greatest(0, least(100, v_pct)),
    'position', v_pos, 'total_reps', v_total,
    'badges', v_badges, 'tiers', v_tiers,
    'rules', jsonb_build_object('points_per_ticket', cfg.points_per_ticket,
                                'points_per_sale', cfg.points_per_sale,
                                'include_content_points', cfg.include_content_points)
  );
end $$;

create or replace function private.gam_admin_reps(p_tenant text)
returns table (rep_id uuid, points int, tickets int, sales_count int, shows_joined int,
               shows_sold_at int, tier_name text, tier_icon text, tier_color text,
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

-- Lock down private functions: only the three entry points are callable by
-- signed-in users (and only via the public wrappers below).
revoke all on all functions in schema private from public, anon, authenticated;
grant execute on function private.gam_leaderboard(uuid,int,text) to authenticated;
grant execute on function private.gam_my_progress(text)          to authenticated;
grant execute on function private.gam_admin_reps(text)           to authenticated;

-- ── Public RPCs (SECURITY INVOKER wrappers → /rest/v1/rpc/...) ────────
create or replace function public.gamification_leaderboard(
  p_event_id uuid default null, p_limit int default 25, p_tenant text default 'submerged')
returns table (pos int, display_name text, promo_code text, tier_name text, tier_icon text,
               tier_color text, points int, tickets int, is_me boolean)
language sql stable security invoker set search_path = '' as $$
  select * from private.gam_leaderboard(p_event_id, p_limit, p_tenant);
$$;

create or replace function public.gamification_my_progress(p_tenant text default 'submerged')
returns jsonb language sql stable security invoker set search_path = '' as $$
  select private.gam_my_progress(p_tenant);
$$;

create or replace function public.gamification_admin_reps(p_tenant text default 'submerged')
returns table (rep_id uuid, points int, tickets int, sales_count int, shows_joined int,
               shows_sold_at int, tier_name text, tier_icon text, tier_color text,
               badge_count int, badge_icons text, overall_pos int, excluded boolean)
language sql stable security invoker set search_path = '' as $$
  select * from private.gam_admin_reps(p_tenant);
$$;

revoke all on function public.gamification_leaderboard(uuid,int,text) from public, anon;
revoke all on function public.gamification_my_progress(text)          from public, anon;
revoke all on function public.gamification_admin_reps(text)           from public, anon;
grant execute on function public.gamification_leaderboard(uuid,int,text) to authenticated;
grant execute on function public.gamification_my_progress(text)          to authenticated;
grant execute on function public.gamification_admin_reps(text)           to authenticated;
