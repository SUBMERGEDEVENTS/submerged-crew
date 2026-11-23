-- Undo 20261120120000_lock_rep_pay_fields.sql. Deletes no rows.
drop trigger if exists trg_zzz_lock_pay_fields on public.reps;
drop trigger if exists trg_zzz_lock_totals on public.rep_events;
drop trigger if exists trg_zzz_lock_status on public.content_submissions;
drop function if exists private.tg_reps_lock_pay_fields();
drop function if exists private.tg_rep_events_lock_totals();
drop function if exists private.tg_content_lock_status();
drop function if exists private.is_self_service_write(text);
