-- Make lakejacksonlanding@gmail.com an admin and keep its rep row(s) hidden
-- from every rep-facing ranking (current and any created later).

-- 1) Admin (same format as existing rows: auth uid + lower-case email)
insert into public.admins (user_id, email)
select u.id, lower(u.email) from auth.users u
where lower(u.email) = 'lakejacksonlanding@gmail.com'
  and not exists (select 1 from public.admins a where a.user_id = u.id);

-- 2) Users whose rep rows must always be hidden from leaderboards
create table if not exists private.gamification_hidden_users (
  user_id uuid primary key,
  email text,
  reason text,
  created_at timestamptz not null default now()
);
revoke all on private.gamification_hidden_users from public, anon, authenticated;

insert into private.gamification_hidden_users (user_id, email, reason)
select u.id, lower(u.email), 'admin account' from auth.users u
where lower(u.email) = 'lakejacksonlanding@gmail.com'
on conflict (user_id) do nothing;

-- 3) Exclude existing rep rows for hidden users
insert into private.gamification_leaderboard_exclusions (rep_id, reason)
select r.id, 'admin account' from public.reps r
join private.gamification_hidden_users h
  on h.user_id = r.user_id or lower(r.email) = h.email
where not exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = r.id);

-- 4) Auto-exclude rep rows created/re-linked later for hidden users
create or replace function private.gam_auto_exclude_hidden_user_rep()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from private.gamification_hidden_users h
             where h.user_id = new.user_id or h.email = lower(new.email))
     and not exists (select 1 from private.gamification_leaderboard_exclusions e where e.rep_id = new.id) then
    insert into private.gamification_leaderboard_exclusions (rep_id, reason) values (new.id, 'admin account');
  end if;
  return new;
end;
$$;
revoke all on function private.gam_auto_exclude_hidden_user_rep() from public, anon, authenticated;

drop trigger if exists gam_auto_exclude_hidden_user_rep on public.reps;
create trigger gam_auto_exclude_hidden_user_rep
after insert or update of user_id, email on public.reps
for each row execute function private.gam_auto_exclude_hidden_user_rep();
