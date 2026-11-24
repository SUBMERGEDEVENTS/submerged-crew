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

`20261119_before_ig_comment_picker.sql` removes the functions, policies and trigger added by
`20261119120000_ig_comment_picker.sql`. It keeps the draw history and stored connection by default; a
commented block at the bottom deletes them. Delete no rows unless you mean to.

`20261120_before_lock_rep_pay_fields.sql` removes the triggers and functions added by
`20261120120000_lock_rep_pay_fields.sql`. It deletes no rows. Restore the portal's
"change code" box with it if reps should edit their own promo code again.

`20261123_before_event_flat_rate.sql` drops `events.flat_rate` and its check,
added by `20261123160000_event_flat_rate.sql`. Any per-event flat rates are
lost; cash already credited to reps is not changed.

`20261124_before_partner_code_claims.sql` removes the partner code table, triggers and
RPCs added by `20261124120000_partner_code_claims.sql`, and restores
`promo_code_available`. Claims and approvals are lost; reps and their Woosah promo
codes are not changed. Deploy the previous front end with it.
