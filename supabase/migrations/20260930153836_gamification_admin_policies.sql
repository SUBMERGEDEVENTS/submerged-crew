-- Gamification — explicit admin-only RLS policies on private config tables.
-- These tables are not granted to anon/authenticated (and `private` is not an
-- exposed PostgREST schema), so today they are reachable only through the
-- SECURITY DEFINER gamification functions. The policies make intent explicit
-- (clears lint 0008 rls_enabled_no_policy) and are ready for Phase B, when an
-- admin editor can be enabled by granting table privileges to `authenticated`.
create policy "Admins manage gamification_config" on private.gamification_config
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins manage gamification_tiers" on private.gamification_tiers
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins manage gamification_badges" on private.gamification_badges
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "Admins manage gamification_leaderboard_exclusions" on private.gamification_leaderboard_exclusions
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
