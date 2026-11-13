# Proposed migrations (not applied)

Files in this folder are drafts only. They have not been run against the
live Supabase project, and they are kept out of `supabase/migrations/`
on purpose so the Supabase CLI will not pick them up.

Review the SQL, then apply it manually (or move a reviewed file into
`supabase/migrations/` and migrate) before deploying any frontend that
filters on the new columns.
