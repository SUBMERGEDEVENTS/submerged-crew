-- Optional flat cash rate per event.
-- When events.flat_rate is set, every ticket sold with a rep's code for that
-- event pays that amount, whatever the rep's rank. When it is null the team's
-- rank rates apply, exactly as before. Used for SUB:ZERO, where AEG pays a
-- flat amount per ticket.
--
-- Only admins can write events (policy "Admins manage events"), so reps cannot
-- set this. Existing rows keep null, so nothing changes until an admin sets it.
alter table public.events
  add column if not exists flat_rate numeric(6,2);

alter table public.events
  drop constraint if exists events_flat_rate_range;
alter table public.events
  add constraint events_flat_rate_range
  check (flat_rate is null or (flat_rate >= 0 and flat_rate <= 100));

comment on column public.events.flat_rate is
  'Cash per ticket for this event regardless of rank. Null means use the team rank rates.';
