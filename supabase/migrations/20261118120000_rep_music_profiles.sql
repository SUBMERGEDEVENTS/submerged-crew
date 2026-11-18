-- =============================================================================
-- PREVIEW ONLY. NOT APPLIED. Do not apply without Shaun's approval.
--
-- First-party music data: rep_music_profiles + gamification points.
--
--   * public.rep_music_profiles: one row per rep. Holds ONLY aggregates the rep
--     previewed and confirmed in the browser (top artists, top tracks, rough
--     totals) plus their taste quiz answers. No raw streaming history, no IPs,
--     no device info, no timestamps.
--   * RLS: a rep reads, writes and deletes their own row. Tenant admins read and
--     delete rows for their tenant. NULL tenant_slug means submerged, same as
--     every other tenant-scoped table.
--   * Points: private.gamification_config gets music_upload_points and
--     music_quiz_points. private.gam_rep_stats adds them to content_points, so
--     the leaderboard, tiers and admin views pick them up with no other change.
--     Points are derived (like every other point source): deleting a profile
--     removes them.
--
-- Rollback: supabase/rollback/20261118_before_rep_music_profiles.sql
-- =============================================================================

-- 1. Table ---------------------------------------------------------------
create table if not exists public.rep_music_profiles (
  id               uuid primary key default gen_random_uuid(),
  rep_id           uuid not null references public.reps(id) on delete cascade,
  user_id          uuid not null references auth.users(id) on delete cascade,
  tenant_slug      text,
  source           text not null default 'quiz'
                   check (source in ('quiz', 'spotify_export', 'spotify_export+quiz')),
  top_artists      jsonb not null default '[]'::jsonb,
  top_tracks       jsonb not null default '[]'::jsonb,
  listening_totals jsonb not null default '{}'::jsonb,
  top_genres       text[] not null default '{}',
  quiz             jsonb not null default '{}'::jsonb,
  consent_at       timestamptz,
  upload_at        timestamptz,
  quiz_at          timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  constraint rep_music_profiles_rep_unique unique (rep_id),
  constraint rep_music_profiles_top_artists_shape check (jsonb_typeof(top_artists) = 'array' and jsonb_array_length(top_artists) <= 50),
  constraint rep_music_profiles_top_tracks_shape  check (jsonb_typeof(top_tracks)  = 'array' and jsonb_array_length(top_tracks)  <= 50),
  constraint rep_music_profiles_totals_shape      check (jsonb_typeof(listening_totals) = 'object'),
  constraint rep_music_profiles_quiz_shape        check (jsonb_typeof(quiz) = 'object'),
  constraint rep_music_profiles_genres_len        check (cardinality(top_genres) <= 30),
  -- A Spotify upload must carry consent.
  constraint rep_music_profiles_upload_needs_consent check (upload_at is null or consent_at is not null),
  -- Points are earned only with real content: a non-empty upload summary, a non-empty quiz.
  constraint rep_music_profiles_upload_has_data check (upload_at is null or jsonb_array_length(top_artists) > 0),
  constraint rep_music_profiles_quiz_has_data   check (quiz_at is null or quiz <> '{}'::jsonb),
  constraint rep_music_profiles_size check (pg_column_size(top_artists) + pg_column_size(top_tracks)
                                            + pg_column_size(listening_totals) + pg_column_size(quiz) < 65536)
);

comment on table public.rep_music_profiles is
  'Aggregate-only music taste shared by a rep: top artists/tracks and totals from a Spotify data export parsed in the browser, plus taste quiz answers. NULL tenant_slug means submerged.';

create index if not exists rep_music_profiles_tenant_slug_idx on public.rep_music_profiles (tenant_slug);
create index if not exists rep_music_profiles_user_idx on public.rep_music_profiles (user_id);

-- 2. Stamp tenant + updated_at --------------------------------------------
-- tenant_slug always follows the rep row, never the client.
create or replace function private.tg_stamp_music_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rep public.reps%rowtype;
begin
  select * into v_rep from public.reps r where r.id = new.rep_id;
  if not found then
    raise exception 'rep not found' using errcode = '23503';
  end if;
  new.user_id := v_rep.user_id;
  new.tenant_slug := v_rep.tenant_slug;
  new.updated_at := now();
  return new;
end $$;
revoke all on function private.tg_stamp_music_profile() from public, anon, authenticated;

drop trigger if exists trg_stamp_music_profile on public.rep_music_profiles;
create trigger trg_stamp_music_profile
  before insert or update on public.rep_music_profiles
  for each row execute function private.tg_stamp_music_profile();

-- 3. RLS ------------------------------------------------------------------
alter table public.rep_music_profiles enable row level security;

revoke all on table public.rep_music_profiles from anon, authenticated;
grant select, insert, update, delete on table public.rep_music_profiles to authenticated;

drop policy if exists "Reps read own music profile" on public.rep_music_profiles;
create policy "Reps read own music profile" on public.rep_music_profiles
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "Reps insert own music profile" on public.rep_music_profiles;
create policy "Reps insert own music profile" on public.rep_music_profiles
  for insert to authenticated
  with check (
    exists (select 1 from public.reps r where r.id = rep_id and r.user_id = auth.uid())
  );

drop policy if exists "Reps update own music profile" on public.rep_music_profiles;
create policy "Reps update own music profile" on public.rep_music_profiles
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    exists (select 1 from public.reps r where r.id = rep_id and r.user_id = auth.uid())
  );

drop policy if exists "Reps delete own music profile" on public.rep_music_profiles;
create policy "Reps delete own music profile" on public.rep_music_profiles
  for delete to authenticated
  using (user_id = auth.uid());

drop policy if exists "Tenant admins read music profiles" on public.rep_music_profiles;
create policy "Tenant admins read music profiles" on public.rep_music_profiles
  for select to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

drop policy if exists "Tenant admins delete music profiles" on public.rep_music_profiles;
create policy "Tenant admins delete music profiles" on public.rep_music_profiles
  for delete to authenticated
  using (public.is_tenant_admin(coalesce(tenant_slug, 'submerged')));

-- 4. Points config --------------------------------------------------------
alter table private.gamification_config
  add column if not exists music_upload_points integer not null default 100 check (music_upload_points >= 0),
  add column if not exists music_quiz_points   integer not null default 50  check (music_quiz_points >= 0);

comment on column private.gamification_config.music_upload_points is
  'Points for sharing a Spotify export summary (rep_music_profiles.upload_at set). Counted inside content_points.';
comment on column private.gamification_config.music_quiz_points is
  'Points for completing the taste quiz (rep_music_profiles.quiz_at set). Counted inside content_points.';

-- 5. Points derivation ----------------------------------------------------
-- Same signature and body as 20261113144700_tenant_slug_on_core_tables.sql,
-- plus a "music" CTE folded into content_points and points.
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
  ),
  music as (
    select mp.rep_id,
           ( case when mp.upload_at is not null then cfg.music_upload_points else 0 end
           + case when mp.quiz_at   is not null then cfg.music_quiz_points   else 0 end )::int as pts
    from public.rep_music_profiles mp
    join public.reps r_music on r_music.id = mp.rep_id
    join private.gamification_config cfg on cfg.tenant_slug = private.gam_tenant(p_tenant)
    where private.tenant_row_matches(r_music.tenant_slug, p_tenant)
  )
  select r.id,
         coalesce(a.tickets,0), coalesce(a.sales_count,0), coalesce(j.shows_joined,0),
         coalesce(a.shows_sold_at,0), coalesce(a.max_show_tickets,0),
         coalesce(a.sale_points,0),
         (coalesce(a.content_points,0) + coalesce(m.pts,0))::int,
         coalesce(a.milestone_points,0),
         (coalesce(a.sale_points,0) + coalesce(a.content_points,0) + coalesce(a.milestone_points,0) + coalesce(m.pts,0))::int
  from public.reps r
  left join agg    a on a.rep_id = r.id
  left join joined j on j.rep_id = r.id
  left join music  m on m.rep_id = r.id
  where private.tenant_row_matches(r.tenant_slug, p_tenant);
$$;

-- Follow-ups (not in this migration):
--   * Expose music_upload_points / music_quiz_points in public.gamification_settings
--     and gamification_update_settings so tenant admins can edit them.
--   * Include them in the "rules" object returned to reps so the portal can read
--     point values from the server instead of constants.
