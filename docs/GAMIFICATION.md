# Gamification — Phase A

Points, tiers, badges and leaderboards for the street-team portal, plus a
**Rewards store — coming soon** placeholder (Phase B will add redemption).

## Points rule

Points are **derived live from credited sales** (`public.sales`, written by the
Eventbrite `order.placed` webhook and by admin "Log a manual sale"):

```
points = SUM(ticket_quantity) × points_per_ticket   (default 20)
       + COUNT(sales rows)    × points_per_sale     (default 0)
       + approved content points, only if include_content_points (default false)
```

- 20 pts/ticket matches what the webhook already writes to `sales.points_awarded`
  and the "+20 pts" copy reps already see, so derived points reconcile with the
  legacy `reps.lifetime_points` today.
- No mutable balance is stored. Deleting / refunding a `sales` row lowers points
  on the next read (verified with a rolled-back self-test: 80 → 140 → 80).
- **Single place to change it:** `private.gamification_config` (one row per tenant).

```sql
update private.gamification_config set points_per_ticket = 1 where tenant_slug = 'default';
```

## Tiers

Stored in `private.gamification_tiers` (admin-editable later). Seeded with the
**existing** rank ladder so reps don't see two conflicting ladders (the same
names/thresholds drive `update_rep_rank()` and the cash-rate copy):

| Tier | Min points | ≈ tickets @20 |
| --- | ---: | ---: |
| 🎫 Recruit | 0 | 0 |
| 🌟 Rising Star | 400 | 20 |
| ⚡ Hotshot | 1,000 | 50 |
| 🔥 Closer | 2,500 | 125 |
| 👑 Legend | 5,000 | 250 |

To use Rookie/Bronze/Silver/Gold/Platinum instead, update the rows (note the
legacy `reps.rank` / cash-rate logic still uses the old names).

## Badges (computed, never granted manually)

`private.gamification_badges` — metric + threshold:

| Code | Badge | Rule |
| --- | --- | --- |
| first_sale | 🎟️ First Sale | total tickets ≥ 1 |
| double_digits | 🔟 Double Digits | total tickets ≥ 10 |
| packed_house | 🏟️ Packed House | ≥ 5 tickets for one show |
| on_tour | 🚐 On Tour | joined ≥ 3 shows |
| road_warrior | 🗺️ Road Warrior | sales at ≥ 3 different shows |
| fifty_club | 💯 Fifty Club | total tickets ≥ 50 |

Metrics available: `total_tickets`, `total_sales`, `max_show_tickets`,
`shows_joined`, `shows_sold_at`. (The legacy `public.badges` table is untouched.)

## RPCs (PostgREST)

| RPC | Who | Returns |
| --- | --- | --- |
| `gamification_my_progress(p_tenant)` | signed-in rep | own points, tier, next tier, progress %, board position, badges, rules |
| `gamification_leaderboard(p_event_id, p_limit, p_tenant)` | signed-in rep | `pos, display_name ("Alexa H."), promo_code, tier, points, tickets, is_me` — overall, or per show when `p_event_id` is set |
| `gamification_admin_reps(p_tenant)` | admins (`is_admin()`) | per-rep points/tier/badges/position |

Only safe aggregate fields leave the database — no emails, phones, socials or
other reps' ids.

## Security model

- Config tables + `SECURITY DEFINER` functions live in schema `private`
  (not exposed via PostgREST; no table grants to `anon`/`authenticated`;
  admin-only RLS policies for Phase B editing).
- Public RPCs are `SECURITY INVOKER` wrappers; `anon` cannot execute any of them.
- `get_advisors(security)` after migration: **no new findings** vs. baseline.

## Tenancy

All config is keyed by `tenant_slug`; lookups fall back to `'default'`. The
portal passes `?tenant=` (default `submerged`). Data tables (`reps`, `sales`)
have no tenant column yet, so a shared-backend tenant sees the same reps; a
tenant with its own Supabase project just needs these migrations applied.

## Leaderboard exclusions

House/test accounts can be hidden without touching `reps`:

```sql
insert into private.gamification_leaderboard_exclusions (rep_id, reason)
select id, 'house account' from public.reps where promo_code in ('SUB45');
```

## Files

- `supabase/migrations/20260930153729_gamification_phase_a.sql`
- `supabase/migrations/20260930153836_gamification_admin_policies.sql`
- `docs/gamification-headless-check.js` — headless smoke test (mocked Supabase)
