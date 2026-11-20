-- ════════════════════════════════════════════════════════════════════
-- Lock pay-related fields so reps cannot change them through the API.
--
-- Problem: the "Allow update own rep" policy on public.reps has no column
-- limits, and reps can insert their own rep_events and content_submissions
-- rows. A signed-in rep could therefore, with the public anon key:
--   • raise their own lifetime_points or rank (the Eventbrite webhook reads
--     reps.rank to pick the cash rate per ticket)
--   • change their promo_code to any free code, including codes already
--     used on Eventbrite by people who never signed up
--   • insert a rep_events row with cash_earned set, which "Mark all paid"
--     would then pay out
--   • insert a content submission already marked approved (bonus points)
--
-- Fix: BEFORE triggers that only act on self-service callers (role
-- authenticated, not a team admin for the row's tenant). Team admins,
-- the service role (Eventbrite webhook) and SQL run as before.
--
-- Front end: the portal's "change code" box is replaced with a note to ask
-- the team admin, so nothing a rep normally does is blocked.
-- Rollback: supabase/rollback/20261120_before_lock_rep_pay_fields.sql
-- NOT APPLIED. Apply only with the owner's explicit okay.
-- ════════════════════════════════════════════════════════════════════

create or replace function private.is_self_service_write(p_tenant text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(auth.role(), '') = 'authenticated'
     and not public.is_tenant_admin(private.norm_tenant(p_tenant));
$$;
revoke all on function private.is_self_service_write(text) from public, anon, authenticated;

-- reps: reps may edit name, phone and socials; pay fields stay as they were.
create or replace function private.tg_reps_lock_pay_fields()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_self_service_write(new.tenant_slug) then return new; end if;
  if tg_op = 'INSERT' then
    new.lifetime_points := 0;
    new.rank := 'Recruit';
    return new;
  end if;
  new.user_id         := old.user_id;
  new.promo_code      := old.promo_code;
  new.rank            := old.rank;
  new.lifetime_points := old.lifetime_points;
  new.status          := old.status;
  new.tenant_slug     := old.tenant_slug;
  return new;
end $$;

-- "zzz" so it runs after trg_stamp_tenant and trg_zz_signup_gate
-- (BEFORE triggers fire in name order).
drop trigger if exists trg_zzz_lock_pay_fields on public.reps;
create trigger trg_zzz_lock_pay_fields before insert or update on public.reps
  for each row execute function private.tg_reps_lock_pay_fields();

-- rep_events: a rep joining a show starts at zero; only the webhook or an
-- admin can add sales, points or cash.
create or replace function private.tg_rep_events_lock_totals()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_self_service_write(new.tenant_slug) then return new; end if;
  if tg_op = 'INSERT' then
    new.codes_sold    := 0;
    new.points_earned := 0;
    new.cash_earned   := 0;
  else
    new.codes_sold    := old.codes_sold;
    new.points_earned := old.points_earned;
    new.cash_earned   := old.cash_earned;
    new.rep_id        := old.rep_id;
    new.event_id      := old.event_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_zzz_lock_totals on public.rep_events;
create trigger trg_zzz_lock_totals before insert or update on public.rep_events
  for each row execute function private.tg_rep_events_lock_totals();

-- content_submissions: a rep's submission always starts as pending.
create or replace function private.tg_content_lock_status()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_self_service_write(new.tenant_slug) then return new; end if;
  if tg_op = 'INSERT' then
    new.status := 'pending';
  else
    new.status := old.status;
  end if;
  return new;
end $$;

drop trigger if exists trg_zzz_lock_status on public.content_submissions;
create trigger trg_zzz_lock_status before insert or update on public.content_submissions
  for each row execute function private.tg_content_lock_status();
