-- Undo 20261123160000_event_flat_rate.sql. Drops the column and its check.
-- Deploy the previous front end first, since the new admin page reads flat_rate.
alter table public.events drop constraint if exists events_flat_rate_range;
alter table public.events drop column if exists flat_rate;
