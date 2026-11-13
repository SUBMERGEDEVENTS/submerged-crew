-- Additive: record when a demo request notification was sent, if any.
-- nullable; not granted for INSERT by anon or authenticated.

alter table public.demo_requests
  add column if not exists notified_at timestamptz;

comment on column public.demo_requests.notified_at is 'When a notification was sent for this request, if any.';
