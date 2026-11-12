# submerged-crew

Woosah is a multi-tenant street-team portal. Reps track promo codes, events, leaderboards, and music-mix missions; coordinators use the admin dashboard.

## Phase 1 — product foundation

This branch adds Cloudflare static hosting config, tenant JSON configs, client-side tenant bootstrap (`?tenant=slug`), and lightweight product analytics.

> **Note:** An earlier Cloudflare Pages PR (#1), if still open, can be closed after this PR merges — this branch supersedes that scaffolding with the full Phase 1 foundation.

## Local run

Path routing is handled by the Worker in `src/worker.js`, so use Wrangler (a plain static server will not rewrite `/{slug}`):

```bash
npx wrangler dev
```

Open:

- Product landing: http://localhost:8787/
- SUB:MERGED portal: http://localhost:8787/submerged
- SUB:MERGED admin: http://localhost:8787/submerged/admin
- Demo tenant: http://localhost:8787/acme-demo

Optional env templates (no real secrets):

- `.env.example`
- `.dev.vars.example`

## Deploy (Cloudflare Workers static assets)

```bash
npm i -g wrangler   # if needed
wrangler deploy
```

Config lives in `wrangler.jsonc`: Worker entry `src/worker.js`, `assets.directory = "."` with the `ASSETS` binding and `run_worker_first`, observability on, `nodejs_compat`, compatibility date `2026-06-18`.

## Tenants (`/{slug}`)

https://woosahcrew.com/ is the product landing page. Each team portal lives at `/{slug}` (admin at `/{slug}/admin`). The Worker checks that `tenants/{slug}.json` exists; unknown slugs get a "team not found" page and never fall through to SUB:MERGED.

`js/tenant.js` reads the first path segment (with `?tenant=` as backward-compatible fallback), fetches `/tenants/{slug}.json`, falls back to Woosah product defaults, sets `window.AppTenant`, applies CSS variables / title / wordmarks, and dispatches `tenantready`. Pages ship with Woosah chrome in the HTML so the tab title and headers stay product-neutral until tenant config loads.

Legacy URLs still work:

- `/?tenant=slug` and `/index.html?tenant=slug` redirect to `/{slug}`
- `/submerged_admin.html` redirects to `/submerged/admin` (`?tenant=` is honored)
- `https://www.woosahcrew.com/...` redirects to the apex host
- `https://submerged-crew.shaun-6ad.workers.dev/` redirects to `https://woosahcrew.com/submerged` (other legacy paths are mapped in one hop when possible)

| Slug | File | Notes |
| --- | --- | --- |
| `submerged` | `tenants/submerged.json` | Dogfood tenant config (brand + keys) |
| `acme-demo` | `tenants/acme-demo.json` | Demo brand colors; shared demo backend for Phase 1 |

### Add a trial client

1. Copy `tenants/acme-demo.json` to `tenants/{slug}.json`
2. Set `slug`, `name`, `brand.cyan` / `brand.navy`, copy strings
3. Point `supabaseUrl` / `supabaseAnonKey` at the client project (or keep shared demo keys for a sandbox)
4. Share `https://woosahcrew.com/{slug}`

## Analytics

See `docs/EVENTS.md` and `docs/product_events.sql`. Client helper: `js/analytics.js` (`track(event, props)`).

## Deprecated

`test.html` is **deprecated** legacy scratch UI. Left in the repo for reference; do not link it from production nav.

## Stack

- Static HTML/JS UI
- Supabase Auth + data
- Cloudflare Workers static assets (`wrangler.jsonc`)

## Production
- Landing: https://woosahcrew.com
- SUB:MERGED portal: https://woosahcrew.com/submerged
- SUB:MERGED admin: https://woosahcrew.com/submerged/admin
- Demo tenant: https://woosahcrew.com/acme-demo
- Auto-deploys from `main` via Cloudflare Workers Builds

## Trial clients
See [docs/TRIAL_ONBOARDING.md](docs/TRIAL_ONBOARDING.md) for the 2–3 client trial wave checklist and pasteable invite.

Static deploys respect [.assetsignore](.assetsignore) so `.git` and other junk are not uploaded as assets.


## Gamification
Points, tiers, badges, leaderboards and the Rewards store placeholder: see [docs/GAMIFICATION.md](docs/GAMIFICATION.md).
