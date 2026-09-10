# Trial client onboarding (2–3 week wave)

Production app: https://submerged-crew.shaun-6ad.workers.dev

Goal: dogfood SUB:MERGED on the default tenant, then put 2–3 outside clients on branded links without forking the app.

## What a trial gets
- Their own branded portal link (`?tenant=<slug>`)
- Crew signup / login (email confirmation off — immediate login)
- Access to the current street-team flows on the shared backend
- A short feedback channel (you pick: text / email / Slack)

What they do **not** get yet: separate databases, custom feature builds, billing, or a unique codebase.

## Add a trial client (10–15 minutes)
1. Copy `tenants/acme-demo.json` → `tenants/<slug>.json` (slug = lowercase, hyphens ok).
2. Edit at least:
   - `slug`, `name`, brand colors, optional `logoUrl` / `supportContact`
   - Keep Supabase URL/anon key the same for this trial wave (shared backend)
3. Commit to `main` (Cloudflare auto-deploys).
4. Send them:
   - Portal: `https://submerged-crew.shaun-6ad.workers.dev/?tenant=<slug>`
   - Admin (if needed): `https://submerged-crew.shaun-6ad.workers.dev/submerged_admin.html?tenant=<slug>`
5. Ask them to create one admin/test account and one crew account, then run a real week of activity.

## Message you can paste to a trial client
Subject: Street team portal trial

Hey — we’re trial-ing our street-team ops portal with a few partners.

Your link: https://submerged-crew.shaun-6ad.workers.dev/?tenant=SLUG

1. Open the link and create an account (you’ll be signed in right away).
2. Use it for real shifts / check-ins this week if you can.
3. Reply with anything confusing, missing, or “we’d pay if it did X.”

No cost for this trial. We’re learning what to productize for Q1.

## What we track
Client analytics land in Supabase `product_events` (tenant_slug, event_name, props). Review weekly:
- signups / logins
- key actions the portal already emits (see `docs/EVENTS.md`)

## Success criteria for a trial (end of week 2)
- They came back after day 1 without hand-holding
- At least one concrete “must have” or “nice” request
- Clear yes / maybe / no on paying later

## Operator checklist (you)
- [ ] SUB:MERGED dogfood on default URL (no `?tenant=`) for a few days
- [ ] Pick 2–3 trial names + slugs
- [ ] Add tenant JSON + deploy
- [ ] Send paste message
- [ ] Schedule a 15-min check-in at day 3 and day 10
- [ ] Dump notes into one place (this repo `docs/` or a doc you prefer)

## Out of scope until after trials
Stripe, custom domains per client, strict per-tenant data isolation, lawyer-grade ToS. Revisit for Q1 2027 launch.
