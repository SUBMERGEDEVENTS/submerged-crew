# submerged-crew

Multi-tenant street-team portal for **SUB:MERGED** (and trial clients). Reps track promo codes, events, leaderboards, and music-mix missions; coordinators use the admin dashboard.

## Phase 1 — product foundation

This branch adds Cloudflare static hosting config, tenant JSON configs, client-side tenant bootstrap (`?tenant=slug`), and lightweight product analytics.

> **Note:** An earlier Cloudflare Pages PR (#1), if still open, can be closed after this PR merges — this branch supersedes that scaffolding with the full Phase 1 foundation.

## Local run

Serve the repo root as static files (tenant JSON + JS must be same-origin):

```bash
npx --yes serve -p 8787 .
# or
python3 -m http.server 8787
```

Open:

- Portal: http://localhost:8787/index.html
- Admin: http://localhost:8787/submerged_admin.html
- Demo tenant: http://localhost:8787/index.html?tenant=acme-demo

Optional env templates (no real secrets):

- `.env.example`
- `.dev.vars.example`

## Deploy (Cloudflare Workers static assets)

```bash
npm i -g wrangler   # if needed
wrangler deploy
```

Config lives in `wrangler.jsonc` (`assets.directory = "."`, observability on, `nodejs_compat`, compatibility date `2026-06-18`).

## Tenants (`?tenant=slug`)

`js/tenant.js` reads `?tenant=`, fetches `tenants/{slug}.json`, falls back to SUB:MERGED defaults, sets `window.AppTenant`, applies CSS variables / title, and dispatches `tenantready`.

| Slug | File | Notes |
| --- | --- | --- |
| `submerged` (default) | `tenants/submerged.json` | Production brand + Supabase keys extracted from the app |
| `acme-demo` | `tenants/acme-demo.json` | Demo brand colors; shared demo backend for Phase 1 |

### Add a trial client

1. Copy `tenants/acme-demo.json` → `tenants/{slug}.json`
2. Set `slug`, `name`, `brand.cyan` / `brand.navy`, copy strings
3. Point `supabaseUrl` / `supabaseAnonKey` at the client project (or keep shared demo keys for a sandbox)
4. Share `https://<host>/index.html?tenant={slug}`

## Analytics

See `docs/EVENTS.md` and `docs/product_events.sql`. Client helper: `js/analytics.js` (`track(event, props)`).

## Deprecated

`test.html` is **deprecated** legacy scratch UI. Left in the repo for reference; do not link it from production nav.

## Stack

- Static HTML/JS UI
- Supabase Auth + data
- Cloudflare Workers static assets (`wrangler.jsonc`)
