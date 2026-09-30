-- ════════════════════════════════════════════════════════════════════
-- Close privacy hole: reps SELECT was `using (true)` → any signed-in user
-- could read every rep's email/phone/socials.
-- Applied AFTER the frontend that uses promo_code_available() was live.
--   • reps: a user can select only their own row; admins (is_admin()) see all.
--   • is_admin(): no longer executable by anon (nothing anon relies on it).
-- The eventbrite-webhook edge function uses the service role (bypasses RLS).
-- Rollback: alter policy "Allow read own rep" on public.reps using (true);
-- ════════════════════════════════════════════════════════════════════
create policy "Admins read reps" on public.reps
  for select to authenticated using ((select public.is_admin()));

alter policy "Allow read own rep" on public.reps
  using ((select auth.uid()) = user_id);

revoke execute on function public.is_admin() from anon, public;
grant execute on function public.is_admin() to authenticated, service_role;
