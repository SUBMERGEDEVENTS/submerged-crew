-- =============================================================================
-- NOT APPLIED
--
-- Proposed migration only. This file has not been run against the live
-- Supabase project (khisgmozkufnzapmldgc). Do not apply it as part of
-- opening or merging this pull request.
--
-- Apply this manually after review, and only then merge or deploy the
-- admin frontend changes in this branch. If the frontend ships first,
-- admin queries that filter on tenant_slug will fail because the column
-- does not exist yet.
--
-- What this does, once applied:
--   1. Adds a nullable tenant_slug column to the core public tables.
--   2. Leaves existing rows NULL. The app treats NULL as the dogfood
--      tenant "submerged", which is how all of this data was treated
--      before a tenant column existed. Other tenants never match NULL.
--   3. Adds private.tenant_row_matches() for the same rule.
--   4. Scopes private.gam_rep_stats and private.gam_rep_event_points
--      so gamification RPCs follow the same tenant rule.
--
-- This does not change RLS or is_admin(). Those stay global. Frontend
-- filters alone are not real isolation: any admin can still query
-- another tenant's rows from the browser until RLS is tenant-scoped.
-- See the "Follow-up" section at the bottom (commented, not executed).
-- =============================================================================

-- 1. Columns. Nullable, no backfill, no default.
alter table public.reps add column if not exists tenant_slug text;
alter table public.events add column if not exists tenant_slug text;
alter table public.rep_events add column if not exists tenant_slug text;
alter table public.sales add column if not exists tenant_slug text;
alter table public.content_submissions add column if not exists tenant_slug text;
alter table public.points_log add column if not exists tenant_slug text;
alter table public.payouts add column if not exists tenant_slug text;
alter table public.weekly_mixes add column if not exists tenant_slug text;
alter table public.badges add column if not exists tenant_slug text;
alter table public.webhook_inbox add column if not exists tenant_slug text;

comment on column public.reps.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.events.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.rep_events.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.sales.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.content_submissions.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.points_log.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.payouts.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.weekly_mixes.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.badges.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';
comment on column public.webhook_inbox.tenant_slug is
  'Tenant path slug. NULL means the dogfood tenant submerged (legacy rows).';

create index if not exists reps_tenant_slug_idx on public.reps (tenant_slug);
create index if not exists events_tenant_slug_idx on public.events (tenant_slug);
create index if not exists rep_events_tenant_slug_idx on public.rep_events (tenant_slug);
create index if not exists sales_tenant_slug_idx on public.sales (tenant_slug);
create index if not exists content_submissions_tenant_slug_idx on public.content_submissions (tenant_slug);
create index if not exists points_log_tenant_slug_idx on public.points_log (tenant_slug);
create index if not exists payouts_tenant_slug_idx on public.payouts (tenant_slug);
create index if not exists weekly_mixes_tenant_slug_idx on public.weekly_mixes (tenant_slug);
create index if not exists badges_tenant_slug_idx on public.badges (tenant_slug);
create index if not exists webhook_inbox_tenant_slug_idx on public.webhook_inbox (tenant_slug);

-- 2. Shared match rule used by gamification functions (and later RLS).
create or replace function private.tenant_row_matches(p_row_slug text, p_tenant text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  -- NULL row slugs belong to submerged only. Other tenants do not see them.
  select case
    when p_tenant is null or btrim(p_tenant) = '' then false
    when lower(btrim(p_tenant)) = 'submerged' then
      p_row_slug is null or lower(p_row_slug) = 'submerged'
    else lower(coalesce(p_row_slug, '')) = lower(btrim(p_tenant))
  end;
$$;

-- 3. Scope points aggregation to the requested tenant via each rep's slug.
--    Bodies otherwise match the live functions as of this draft.
create or replace function private.gam_rep_event_points(p_tenant text)
returns table (rep_id uuid, event_id uuid, tickets int, sales_count int,
               sale_points int, milestone_points int, content_points int)
language sql stable set search_path = '' as $$
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
$$;

create or replace function private.gam_rep_stats(p_tenant text)
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
$$;

-- =============================================================================
-- Follow-up (not executed): real isolation still needs work before a
-- second paying tenant shares this database.
--
-- - public.is_admin() is global. Any admin can open /{other-slug}/admin
--   and, until RLS is tightened, can still query other tenants' rows
--   even after the admin UI is scoped.
-- - public.events has "Reps read events" with qual true, so the crew
--   portal also lists every show until events are tenant-scoped in
--   both queries and RLS.
-- - Signup, Eventbrite webhook inserts, and portal writes do not yet
--   stamp tenant_slug. New rows would stay NULL and show up under
--   submerged.
-- - public.admins has no tenant column. Consider an admin_tenants
--   map and is_admin(p_tenant) before a second real tenant.
-- - private.gamification_hidden_users and private.pending_admins
--   currently have RLS disabled. That is an existing issue, not
--   introduced here; confirm whether the private schema is exposed
--   via the Data API before enabling RLS.
-- =============================================================================
