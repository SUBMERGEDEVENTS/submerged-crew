-- Suggested analytics sink for Phase 1 (run in Supabase SQL editor).
-- Soft inserts from the browser use the anon key; tighten RLS before production.

create table if not exists public.product_events (
  id bigserial primary key,
  event_name text not null,
  props jsonb not null default '{}'::jsonb,
  tenant_slug text,
  path text,
  user_id uuid,
  created_at timestamptz not null default now()
);

create index if not exists product_events_created_at_idx on public.product_events (created_at desc);
create index if not exists product_events_event_name_idx on public.product_events (event_name);
create index if not exists product_events_tenant_slug_idx on public.product_events (tenant_slug);

alter table public.product_events enable row level security;

-- Allow anonymous/authenticated inserts for soft client-side tracking.
drop policy if exists "product_events_insert_anon" on public.product_events;
create policy "product_events_insert_anon"
  on public.product_events
  for insert
  to anon, authenticated
  with check (true);

-- Optional: allow authenticated reads (admins / dashboards).
drop policy if exists "product_events_select_authenticated" on public.product_events;
create policy "product_events_select_authenticated"
  on public.product_events
  for select
  to authenticated
  using (true);
