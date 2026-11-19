// Supabase Edge Function: ig-comments   (NOT deployed by this pull request)
//
// Admin-only. POST JSON with an Authorization: Bearer <user JWT> header. Every action checks
// public.is_tenant_admin(tenant) as the signed-in user, so only admins of that team can call it.
//
//   { action: 'status',      tenant }
//   { action: 'connect_url', tenant }                      Business Login for Instagram link
//   { action: 'save_token',  tenant, token, api_host }     paste a token from the Meta App Dashboard
//   { action: 'comments',    tenant, post_url, include_replies? }
//   { action: 'refresh',     tenant }                      refresh the 60 day token now
//   (disconnect is the public.ig_disconnect(tenant) RPC, called by the admin page with the admin's own session)
//
// The Instagram token is stored in Supabase Vault (see supabase/migrations/20261119120000_ig_comment_picker.sql)
// and read only here, with the service role. It is never returned to the browser or logged.
// Secrets this function needs: IG_APP_ID, IG_APP_SECRET. Optional: IG_REDIRECT_URI, IG_GRAPH_VERSION,
// IG_ALLOWED_ORIGINS. See docs/IG_COMMENT_PICKER.md.
import {
  cleanTenant, corsHeaders, fetchAllComments, findMediaByShortcode, GraphError, graphGet, HOSTS, IG_APP_ID,
  IG_APP_SECRET, type IgHost, json, originAllowed, REDIRECT_URI, requireTenantAdmin, serviceClient, shortcodeFromUrl,
  signState,
} from '../_shared/ig.ts';

const SCOPES = 'instagram_business_basic,instagram_business_manage_comments';
const REFRESH_WINDOW_MS = 10 * 24 * 60 * 60 * 1000; // refresh when 10 days or less remain
const MIN_TOKEN_AGE_MS = 24 * 60 * 60 * 1000;      // Meta: token must be at least 24 hours old

type Conn = {
  token: string; api_host: IgHost; ig_user_id: string; username: string | null;
  expires_at: string | null; refreshed_at: string | null; connected_at: string | null;
};

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(origin) });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, origin);

  let body: any;
  try { body = await req.json(); } catch (_) { return json({ error: 'invalid_json' }, 400, origin); }
  const tenant = cleanTenant(body?.tenant);
  if (!tenant) return json({ error: 'invalid_tenant' }, 400, origin);

  const admin = await requireTenantAdmin(req, tenant);
  if (!admin) return json({ error: 'forbidden', message: 'Admins of this team only.' }, 403, origin);

  const sb = serviceClient();
  const action = String(body?.action || '');

  try {
    if (action === 'status') {
      const c = await loadConn(sb, tenant);
      return json({
        connected: !!c, username: c?.username ?? null, api_host: c?.api_host ?? null,
        expires_at: c?.expires_at ?? null, refreshed_at: c?.refreshed_at ?? null,
        app_configured: !!(IG_APP_ID && IG_APP_SECRET),
      }, 200, origin);
    }

    if (action === 'connect_url') {
      if (!IG_APP_ID || !IG_APP_SECRET) {
        return json({ error: 'not_configured', message: 'IG_APP_ID and IG_APP_SECRET are not set for this project yet.' }, 503, origin);
      }
      if (!originAllowed(origin)) return json({ error: 'origin_not_allowed' }, 403, origin);
      const state = await signState({ t: tenant, u: admin.userId, o: origin! });
      const u = new URL('https://www.instagram.com/oauth/authorize');
      u.searchParams.set('client_id', IG_APP_ID);
      u.searchParams.set('redirect_uri', REDIRECT_URI);
      u.searchParams.set('response_type', 'code');
      u.searchParams.set('scope', SCOPES);
      u.searchParams.set('state', state);
      return json({ url: u.toString() }, 200, origin);
    }

    if (action === 'save_token') {
      const token = String(body?.token || '').trim();
      const host = String(body?.api_host || 'graph.instagram.com') as IgHost;
      if (!HOSTS.includes(host)) return json({ error: 'invalid_host' }, 400, origin);
      if (!/^[A-Za-z0-9_|.\-]{20,4000}$/.test(token)) {
        return json({ error: 'invalid_token', message: 'That does not look like an Instagram access token.' }, 400, origin);
      }
      let igId = '', igName = '';
      if (host === 'graph.instagram.com') {
        const me = await graphGet(host, 'me', token, { fields: 'user_id,username' });
        igId = String(me.user_id || me.id || ''); igName = String(me.username || '');
      } else {
        const r = await graphGet(host, 'me/assigned_instagram_accounts', token, { fields: 'id,username' });
        const want = String(body?.ig_username || '').replace(/^@/, '').toLowerCase();
        const list: any[] = r?.data || [];
        const pick = (want && list.find((a) => String(a.username).toLowerCase() === want)) || list[0];
        igId = String(pick?.id || ''); igName = String(pick?.username || '');
      }
      if (!igId) return json({ error: 'no_instagram_account', message: 'This token did not return an Instagram account.' }, 400, origin);
      const { error } = await sb.rpc('ig_save_connection', {
        p_tenant: tenant, p_token: token, p_api_host: host, p_ig_user_id: igId, p_ig_username: igName,
        p_expires_at: null, p_connected_by: admin.userId,
      });
      if (error) return json({ error: 'save_failed' }, 500, origin);
      return json({ connected: true, username: igName, api_host: host }, 200, origin);
    }

    // Everything below needs a stored connection.
    let conn = await loadConn(sb, tenant);
    if (!conn || !conn.token) return json({ error: 'not_connected', message: 'Connect Instagram first.' }, 409, origin);

    if (action === 'refresh') {
      const r = await maybeRefresh(sb, tenant, conn, true);
      return json({ refreshed: r.refreshed, expires_at: r.expires_at, reason: r.reason }, 200, origin);
    }

    if (action === 'comments') {
      const code = shortcodeFromUrl(String(body?.post_url || ''));
      if (!code) {
        return json({ error: 'bad_post_url', message: 'Paste a link to an Instagram post or reel, like https://www.instagram.com/p/XXXX/' }, 400, origin);
      }
      // Keep the token fresh when a long lived Instagram Login token is close to expiry.
      try { conn = { ...conn, ...(await maybeRefresh(sb, tenant, conn, false)).conn }; } catch (_) { /* not fatal */ }

      const get = (path: string, params?: Record<string, string>) => graphGet(conn!.api_host, path, conn!.token, params || {});
      // On graph.instagram.com, /me is the connected account. On graph.facebook.com the account id is in the path.
      const owner = conn.api_host === 'graph.instagram.com' ? 'me' : conn.ig_user_id;
      const { media, pagesScanned } = await findMediaByShortcode(get, owner, code);
      if (!media) {
        return json({
          error: 'post_not_found',
          message: `That post was not found on @${conn.username || 'the connected account'}. It must be a feed post or reel on the connected account, among its most recent posts. Stories are not supported.`,
          pages_scanned: pagesScanned,
        }, 404, origin);
      }
      const { comments, truncated, pages } = await fetchAllComments(get, media.id, {
        includeReplies: body?.include_replies === true,
      });
      return json({
        media: { id: media.id, permalink: media.permalink, timestamp: media.timestamp },
        account: conn.username,
        comments, count: comments.length, truncated, pages,
        fetched_at: new Date().toISOString(),
      }, 200, origin);
    }

    return json({ error: 'unknown_action' }, 400, origin);
  } catch (e) {
    if (e instanceof GraphError) {
      const status = e.kind === 'token_expired' ? 401 : e.kind === 'rate_limited' ? 429 : e.kind === 'permission' ? 403 : 502;
      const message = e.kind === 'token_expired'
        ? 'The Instagram connection expired or was revoked. Connect Instagram again.'
        : e.kind === 'rate_limited' ? 'Instagram is rate limiting this account. Try again in a few minutes.'
        : e.kind === 'permission' ? 'Instagram refused access. Check that the account is Business or Creator and the comments permission was granted.'
        : e.message;
      return json({ error: e.kind, message }, status, origin);
    }
    console.error('ig-comments failed:', (e as Error)?.message || 'unknown');
    return json({ error: 'server_error' }, 500, origin);
  }
});

async function loadConn(sb: ReturnType<typeof serviceClient>, tenant: string): Promise<Conn | null> {
  const { data, error } = await sb.rpc('ig_connection_secret', { p_tenant: tenant });
  if (error || !data) return null;
  return data as Conn;
}

// Business Login long lived tokens last 60 days and can be refreshed once they are 24 hours old
// and not yet expired (graph.instagram.com/refresh_access_token). Tokens pasted from the dashboard
// have unknown expiry (expires_at null) and are left alone.
async function maybeRefresh(sb: ReturnType<typeof serviceClient>, tenant: string, conn: Conn, force: boolean) {
  const out = { refreshed: false, expires_at: conn.expires_at, reason: '', conn: {} as Partial<Conn> };
  if (conn.api_host !== 'graph.instagram.com') { out.reason = 'not_applicable'; return out; }
  if (!conn.expires_at) { out.reason = 'expiry_unknown'; return out; }
  const left = new Date(conn.expires_at).getTime() - Date.now();
  const age = Date.now() - new Date(conn.refreshed_at || conn.connected_at || 0).getTime();
  if (left <= 0) { out.reason = 'expired'; return out; }
  if (!force && left > REFRESH_WINDOW_MS) { out.reason = 'not_due'; return out; }
  if (age < MIN_TOKEN_AGE_MS) { out.reason = 'too_new'; return out; }
  // Meta documents refresh_access_token without a version prefix.
  const res = await refreshToken(conn.token);
  if (!res?.access_token) { out.reason = 'refresh_failed'; return out; }
  const expires = new Date(Date.now() + Number(res.expires_in || 0) * 1000).toISOString();
  const { error } = await sb.rpc('ig_update_token', { p_tenant: tenant, p_token: res.access_token, p_expires_at: expires });
  if (error) { out.reason = 'save_failed'; return out; }
  out.refreshed = true; out.expires_at = expires; out.reason = 'ok';
  out.conn = { token: res.access_token, expires_at: expires, refreshed_at: new Date().toISOString() };
  return out;
}

async function refreshToken(token: string): Promise<any | null> {
  try {
    const u = new URL('https://graph.instagram.com/refresh_access_token');
    u.searchParams.set('grant_type', 'ig_refresh_token');
    u.searchParams.set('access_token', token);
    const res = await fetch(u.toString());
    return res.ok ? await res.json() : null;
  } catch (_) { return null; }
}
