# Rollback snapshots

`20261113_before_tenant_isolation_rls.sql` restores policies, functions,
and RLS flags as they were before the tenant-isolation migration was
applied. It does not delete rows.

Only run it if that migration needs to be undone. After a successful
roll-forward, prefer a new forward migration over this file.
