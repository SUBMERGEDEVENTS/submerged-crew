-- Woosah landing page: "Book a demo" requests.
-- Public visitors (anon) may INSERT only. Nobody but admins can read.
-- No UPDATE or DELETE policies exist, so those are denied for anon and
-- authenticated users (service role still bypasses RLS).

create table if not exists public.demo_requests (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  name        text not null,
  email       text not null,
  org         text not null,
  team_size   text not null,
  ticketing   text not null,
  message     text,
  user_agent  text,
  status      text not null default 'new',

  constraint demo_requests_name_len    check (char_length(btrim(name)) between 1 and 120),
  constraint demo_requests_email_len   check (char_length(email) between 3 and 254),
  constraint demo_requests_email_fmt   check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint demo_requests_org_len     check (char_length(btrim(org)) between 1 and 160),
  constraint demo_requests_team_size   check (team_size in ('1-10', '11-25', '26-50', '51-100', '100+')),
  constraint demo_requests_ticketing   check (ticketing in ('eventbrite', 'other')),
  constraint demo_requests_message_len check (message is null or char_length(message) <= 2000),
  constraint demo_requests_ua_len      check (user_agent is null or char_length(user_agent) <= 512),
  constraint demo_requests_status      check (status in ('new', 'contacted', 'scheduled', 'closed', 'spam'))
);

create index if not exists demo_requests_created_at_idx
  on public.demo_requests (created_at desc);

alter table public.demo_requests enable row level security;

-- Table privileges: anon/authenticated can only INSERT (and only the
-- visitor-supplied columns). Admin reads go through the SELECT policy below.
revoke all on table public.demo_requests from anon, authenticated;
grant insert (name, email, org, team_size, ticketing, message, user_agent)
  on table public.demo_requests to anon, authenticated;
grant select on table public.demo_requests to authenticated;

drop policy if exists "Public can submit demo requests" on public.demo_requests;
create policy "Public can submit demo requests"
  on public.demo_requests
  for insert
  to anon, authenticated
  with check (status = 'new');

drop policy if exists "Admins read demo requests" on public.demo_requests;
create policy "Admins read demo requests"
  on public.demo_requests
  for select
  to authenticated
  using ((select public.is_admin()));
