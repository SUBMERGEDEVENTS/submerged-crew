# Product analytics events

Events are emitted via `track(eventName, props)` in `js/analytics.js`.

They are logged with `console.debug` and soft-inserted into the `product_events` table when `window.sb` is available (failures are ignored).

## Core events

| Event | When | Typical props |
| --- | --- | --- |
| `app_boot` | Portal or admin client finishes Supabase init | `{ page: "portal" \| "admin" }` |
| `login_start` | User starts email or social login | `{ method: "email" \| "spotify" \| ... }` |
| `login_success` | Auth session established after login | `{ method?: string }` |
| `login_error` | Login attempt failed | `{ method?: string, message?: string }` |
| `signup_start` | User submits signup form | `{}` |
| `signup_success` | Account created | `{}` |
| `join_event` | Rep joins a campaign/event | `{ event_id }` |
| `view_change` | In-app nav changes primary view | `{ view }` |
| `admin_login_start` | Admin clicks sign in | `{}` |
| `admin_login_success` | Admin session established | `{}` |

## Adding events

```js
if (typeof track === 'function') track('my_event', { foo: 'bar' });
```

Keep names snake_case. Prefer small, stable prop keys. Do not put secrets or PII (passwords, raw tokens) in props.

See `docs/product_events.sql` for the suggested table definition.
