# Rollback snapshots

`20261113_before_tenant_isolation_rls.sql` restores policies, functions,
and RLS flags as they were before the tenant-isolation migration was
applied. It does not delete rows.

Only run it if that migration needs to be undone. After a successful
roll-forward, prefer a new forward migration over this file.

`20261113_before_tenant_hardening.sql` restores the gamification policies,
the demo_requests read policy and every public/private function as they were
before `20261113190000_tenant_hardening.sql`, and removes the signup gate
trigger. It does not delete rows; the new tables and reps columns stay. Deploy
the previous front end with it, because the new portal sends
`terms_accepted_at` and `invite_code` on signup.

`20261113_before_team_eventbrite_payouts_rates.sql` removes the functions added
by `20261113200000_team_eventbrite_payouts_rates.sql`. It deletes no rows.
