-- Already applied to production (version 20261027012937). Recorded for history; do not re-apply.
create table if not exists private.pending_admins (email text primary key, note text, created_at timestamptz default now());
revoke all on private.pending_admins from public, anon, authenticated;
create or replace function private.promote_pending_admin() returns trigger language plpgsql security definer set search_path = public, private as $$
begin
  if exists (select 1 from private.pending_admins p where lower(p.email) = lower(new.email)) then
    insert into public.admins (user_id, email) values (new.id, lower(new.email)) on conflict do nothing;
    insert into private.gamification_hidden_users (user_id, email) values (new.id, lower(new.email)) on conflict do nothing;
    delete from private.pending_admins where lower(email) = lower(new.email);
  end if;
  return new;
end $$;
drop trigger if exists trg_promote_pending_admin on auth.users;
create trigger trg_promote_pending_admin after insert on auth.users for each row execute function private.promote_pending_admin();
-- The applied migration also seeded one pending admin row (email omitted from the repo for privacy).
