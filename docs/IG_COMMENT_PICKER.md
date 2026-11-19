# Instagram comment giveaway picker

Admin tab **Giveaway** in `/submerged/admin`. Paste a link to an Instagram post or reel, load every comment, set the rules, and draw random winners. Each real draw is saved as a record.

It is behind the feature flag `igCommentPicker` in `tenants/<slug>.json`. It is `true` for `submerged` only, and `false` in `acme-demo` and `_template`. When the flag is false the tab and view are not shown and no request is made.

## What works without any setup

Open the Giveaway tab and press **Try with sample comments**. This uses 50 made up comments, clearly labeled SAMPLE DATA. You can try every rule and the draw. Nothing is loaded from Instagram and sample draws are never saved. Without the setup below, the connection card says the service is not set up yet.

## Read this first: which Meta login to use

Meta's own pages disagree right now, so check what your Meta app offers before you start.

- The Instagram Platform guide for creating an app (`create-an-instagram-app`) says adding the Instagram product gives you **API setup with Instagram login**. This is what the **Connect Instagram** button uses (Business Login for Instagram, host `graph.instagram.com`).
- Meta's migration guide says newly created apps cannot set up the Instagram API with Instagram Login, and points new apps to **Instagram API with Unified Login** (host `graph.facebook.com`, Facebook Login for Business, app owned by a business portfolio).

If your new Meta app shows **API setup with Instagram login**, use the steps below as written. If it only shows **API setup with Unified login**, use the paste-a-token path: in the Meta App Dashboard generate a test token for your Instagram account (Unified login, "Generate access tokens"), then in the admin page open **Advanced: paste an access token instead**, choose "Unified login token (graph.facebook.com)" and save it. Reading comments works the same on both hosts. A pasted token has an unknown expiry, so the app does not refresh it and you paste a new one if it stops working.

Sources: Meta developer docs, Instagram Platform: Business Login for Instagram, Comment Moderation, IG Media Comments, IG Comment, IG User Media, Refresh Access Token, Unified Login Get started, and the Instagram Login migration guide (all read for this build).

## Setup steps (you do these yourself)

Nobody else can do these, and no secret should be pasted into a chat. Do them in order.

1. **Get into the Instagram account.** You need to log in on the web once to accept the tester invite. Reset the password from the Instagram app (Settings, Accounts Center, Password and security, Change password, Forgot your password) and save the new one in a shared password manager. Turn on two factor login while you are there.
2. **Check the account type.** In Instagram, Settings, Account type and tools. It must be **Business** or **Creator**, not Personal. Meta's setup page also says the account used for testing must be public.
3. **Create the Meta app.** At developers.facebook.com, register as a developer if needed, then Create App. Pick app type **Business**, add the **Instagram** product, and open **API setup with Instagram login**. Use the contact email for this app that you want Meta to write to. This app is only for the `submerged` team account. Do not show it to other teams.
4. **Add the account as a tester.** App roles, Roles, add the Instagram account as an **Instagram Tester**. Then in Instagram on the web: Settings, Website permissions, Apps and websites, Tester Invites, and accept.
5. **Set the redirect and copy the IDs.** In **API setup with Instagram login**, step 3 "Set up Instagram business login", Business login settings:
   - Add this exact value under **OAuth redirect URIs**: `https://khisgmozkufnzapmldgc.supabase.co/functions/v1/ig-oauth-callback`
   - Copy the **Instagram App ID** and **Instagram App Secret**. These are different from the main Meta app ID and secret.
6. **Put the secrets in Supabase.** In the Supabase dashboard (Edge Functions, Secrets) or with the CLI in your own terminal:
   ```
   supabase secrets set IG_APP_ID=<instagram app id> IG_APP_SECRET=<instagram app secret> --project-ref khisgmozkufnzapmldgc
   ```
   Optional secrets, only if needed: `IG_REDIRECT_URI` (if you use a different function URL), `IG_GRAPH_VERSION` (default `v27.0`), `IG_ALLOWED_ORIGINS` (comma separated extra browser origins; `woosahcrew.com` and this repo's Workers Builds previews are already allowed).
7. **Apply the migration.** Read `supabase/migrations/20261119120000_ig_comment_picker.sql` first, then run it in the Supabase SQL editor or with `supabase db push`. It adds the draw table and the connection functions. The rollback file is `supabase/rollback/20261119_before_ig_comment_picker.sql`. This pull request does not apply it.
8. **Deploy the two functions.**
   ```
   supabase functions deploy ig-comments --project-ref khisgmozkufnzapmldgc
   supabase functions deploy ig-oauth-callback --no-verify-jwt --project-ref khisgmozkufnzapmldgc
   ```
   `ig-oauth-callback` must use `--no-verify-jwt` because Instagram sends the browser back without a Supabase session. It is protected by a signed state value that only an admin can get (10 minute expiry).
9. **Merge the pull request** so the admin page ships (Cloudflare deploys from `main`). The flag is already on for `submerged`.
10. **Connect.** Admin, Giveaway, **Connect Instagram**, log in if asked, accept both permissions (`instagram_business_basic` and `instagram_business_manage_comments`). You land back on the Giveaway tab with "Instagram connected".

## How it works

- The browser calls the `ig-comments` Edge Function with the admin's own Supabase session. The function checks the JWT and `public.is_tenant_admin(tenant)`, the same check the admin page uses, so only admins of that team can use it.
- **Post link to media ID.** The function reads the shortcode from the link (`/p/`, `/reel/`, `/reels/` or `/tv/`), lists the account's media with `GET /me/media?fields=id,shortcode,permalink,timestamp&limit=100`, follows paging until the shortcode matches, and uses that media ID. Meta returns the most recent 10,000 media at most, and stories are not supported.
- **Comments.** `GET /<media id>/comments?fields=id,text,timestamp,username,like_count,from{id,username}&limit=50`, following `paging.cursors.after` until there are no more pages (50 per request is Meta's maximum). Meta's default fields are only id, text and timestamp, so `username` has to be requested. If you tick "Also count replies", the `replies` field is expanded and any overflow is read from `GET /<comment id>/replies`. The function stops at 10,000 comments and tells the page when it did.
- **Token storage.** The long lived token is in Supabase Vault, name `instagram_token__<tenant>__<random>`, one per team, read only by the Edge Functions with the service role (`public.ig_connection_secret`). The browser never receives it, and the status call returns only the account name and expiry.
- **Token refresh.** Business Login tokens last 60 days. Meta only allows a refresh when the token is at least 24 hours old and not yet expired. Every time comments are loaded, if 10 days or fewer remain, the function refreshes the token for another 60 days. There is also a **Refresh token** button. If nobody loads comments for more than 60 days the token expires and you press Connect Instagram again. Optional hardening, not set up: a daily Supabase cron that calls the `refresh` action.
- **The draw.** All rules run in the browser (`js/ig-picker.js`). The random pick uses `crypto.getRandomValues` with rejection sampling, so there is no modulo bias. A person can only win once, even when "one entry per username" is off. Backup winners are drawn the same way.
- **Rules.** One entry per username (keeps each person's earliest qualifying comment), must tag at least N distinct `@` accounts (the commenter's own handle and the connected account do not count), comment must contain any of the keywords you list, and an exclude list of usernames (your own account is pre-filled).
- **Draw record.** Each real draw inserts a row in `public.ig_comment_draws`: team, post link, media ID, rules, number of people who commented, number of eligible entries, winners (with the comment text) and who drew it. Admins of that team can read and insert. Nobody can edit or delete a record from the app. The server fills in who drew it and when.

## Standard Access and Advanced Access

- **Standard Access** (no App Review) covers Instagram accounts you own or manage and have added to the app in the Meta App Dashboard. This is what the setup above uses.
- **Advanced Access** is needed to serve Instagram accounts you do not own or manage, which means other Woosah teams. It needs Meta App Review and Business Verification, and the business has to be a real verified company. Until that is decided the picker is for the `submerged` team only, and `igCommentPicker` stays `false` for every other team.
- Even with a team's own Meta app, each team would need its own connection. The database and functions are already per team (`tenant_slug`), but the secrets `IG_APP_ID` and `IG_APP_SECRET` are one pair per project today.

## Limits to know

- Only Business or Creator accounts. Personal accounts have no comments API.
- Meta does not return comments from accounts the owner has restricted (unless unrestricted and approved), and does not return comments on age-gated media.
- Comments cannot be filtered by time. Very large posts take longer to load (50 comments per request) and Instagram rate limits apply per account.
- A comment that is deleted after loading stays in the list on screen. Load again right before the draw for the freshest list.
- Instagram has its own rules for running promotions. Check Meta's current promotion guidelines and add your own giveaway terms before you announce a winner.

## Test steps

**Now, in the branch preview (no setup needed):** open `https://round2-ig-comment-picker-submerged-crew.shaun-6ad.workers.dev/submerged/admin`, sign in, tap **Giveaway**, tap **Try with sample comments**, change the rules, and draw. The preview uses the live Supabase, so sign in with your normal admin account.

**After setup:**
1. Giveaway, **Connect Instagram**. Expect "Connected as @yourhandle".
2. Paste the link of a post on that account that has a few comments, tap **Load comments**. Expect the comment and people counts to match what Instagram shows (top level comments only unless you tick replies).
3. Turn rules on and off and watch "eligible" change. Draw. Expect the winners and "Saved to Past draws".
4. Reload the page. Expect the draw in **Past draws**.
5. Paste a link to a post from a different account. Expect "That post was not found on @yourhandle".
6. Sign in as a rep or an admin of another team (for example `acme-demo`). Expect no Giveaway tab, and a direct call to `ig-comments` returns 403.

**Automated checks in this repo** (all use mocked data, none touch the real project):
- `node docs/ig-comment-picker-check.js`, rules, draw fairness, paging, then the admin page in headless Chrome at 390px (needs `BASE`, `PW` and `CHROME`, see the file header).
- `deno run --allow-env --allow-net=esm.sh,deno.land docs/ig-edge-function-check.ts`, both Edge Functions with Instagram and Supabase mocked.
- `npm i --no-save @electric-sql/pglite && node docs/ig-comment-picker-sql-check.mjs`, the migration and rollback in an in-memory Postgres with row level security tested.

## Rollback

Set `igCommentPicker` to `false` in `tenants/submerged.json` to hide the tab immediately. To remove the database objects run `supabase/rollback/20261119_before_ig_comment_picker.sql` (keeps the draw history). To disconnect Instagram, use **Disconnect** on the Giveaway tab, which also deletes the token from Vault. You can also remove the app in Instagram, Settings, Website permissions, Apps and websites.
