-- =============================================================================
-- ROLLBACK for 20261118120000_rep_music_profiles.sql. NOT APPLIED.
--
-- Restores private.gam_rep_stats to its body from
-- 20261113144700_tenant_slug_on_core_tables.sql, drops the two config columns,
-- and drops the policies, trigger and helper function.
--
-- The table itself holds consented personal data, so the final DROP TABLE is
-- commented out. Uncomment it only when the data should be deleted too.
-- Deploy the previous front end with this rollback (the portal degrades
-- gracefully when the table is missing).
-- =============================================================================

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

alter table private.gamification_config
  drop column if exists music_upload_points,
  drop column if exists music_quiz_points;

drop policy if exists "Reps read own music profile" on public.rep_music_profiles;
drop policy if exists "Reps insert own music profile" on public.rep_music_profiles;
drop policy if exists "Reps update own music profile" on public.rep_music_profiles;
drop policy if exists "Reps delete own music profile" on public.rep_music_profiles;
drop policy if exists "Tenant admins read music profiles" on public.rep_music_profiles;
drop policy if exists "Tenant admins delete music profiles" on public.rep_music_profiles;

drop trigger if exists trg_stamp_music_profile on public.rep_music_profiles;
drop function if exists private.tg_stamp_music_profile();

-- DESTRUCTIVE: deletes all stored music profiles. Uncomment only if intended.
-- drop table if exists public.rep_music_profiles;
