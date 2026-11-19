// Supabase Edge Function: ig-oauth-callback   (NOT deployed by this pull request)
//
// Redirect target for Business Login for Instagram. Deploy with --no-verify-jwt, because Instagram
// sends the browser here without a Supabase session. It is protected by the signed `state` value that
// ig-comments hands only to a verified team admin (10 minute expiry, tenant and return origin inside).
//
// Flow (Meta docs, Business Login for Instagram):
//   1. code from the redirect            valid 1 hour, single use
//   2. POST https://api.instagram.com/oauth/access_token   -> short lived token + user_id + permissions
//   3. GET  https://graph.instagram.com/access_token?grant_type=ig_exchange_token -> 60 day token
//   4. GET  https://graph.instagram.com/<version>/me?fields=user_id,username
//   5. Store the token in Vault through public.ig_save_connection (service role only)
//   6. 302 back to <origin>/<tenant>/admin?ig=connected  (or ?ig=error&reason=...)
// No token or secret is logged or put in the redirect.
import {
  cleanTenant, GRAPH_VERSION, graphGet, IG_APP_ID, IG_APP_SECRET, REDIRECT_URI, serviceClient, verifyState,
} from '../_shared/ig.ts';

function back(origin: string, tenant: string, params: Record<string, string>): Response {
  const u = new URL(`${origin}/${tenant}/admin`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return new Response(null, { status: 302, headers: { Location: u.toString(), 'Cache-Control': 'no-store' } });
}

Deno.serve(async (req) => {
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405 });
  const url = new URL(req.url);
  const state = await verifyState(url.searchParams.get('state') || '').catch(() => null);
  if (!state) return new Response('This connection link expired. Go back to the admin page and try again.', { status: 400 });
  const tenant = cleanTenant(state.t)!;
  const fail = (reason: string) => back(state.o, tenant, { ig: 'error', reason });

  if (url.searchParams.get('error')) return fail('denied');
  const code = (url.searchParams.get('code') || '').replace(/#_$/, '');
  if (!code || !IG_APP_ID || !IG_APP_SECRET) return fail('not_configured');

  try {
    // 2. code -> short lived token
    const form = new FormData();
    form.set('client_id', IG_APP_ID);
    form.set('client_secret', IG_APP_SECRET);
    form.set('grant_type', 'authorization_code');
    form.set('redirect_uri', REDIRECT_URI);
    form.set('code', code);
    const r1 = await fetch('https://api.instagram.com/oauth/access_token', { method: 'POST', body: form });
    const j1 = await r1.json().catch(() => null);
    // Meta documents { data: [ { access_token, user_id, permissions } ] }; accept the flat shape too.
    const row = Array.isArray(j1?.data) ? j1.data[0] : j1;
    if (!r1.ok || !row?.access_token) return fail('code_exchange_failed');
    const perms = String(row.permissions || '').split(',').map((s: string) => s.trim());
    if (!perms.includes('instagram_business_manage_comments') || !perms.includes('instagram_business_basic')) {
      return fail('missing_permission');
    }

    // 3. short lived -> long lived (60 days)
    const longUrl = new URL('https://graph.instagram.com/access_token');
    longUrl.searchParams.set('grant_type', 'ig_exchange_token');
    longUrl.searchParams.set('client_secret', IG_APP_SECRET);
    longUrl.searchParams.set('access_token', String(row.access_token));
    const r2 = await fetch(longUrl.toString());
    const j2 = await r2.json().catch(() => null);
    if (!r2.ok || !j2?.access_token) return fail('long_token_failed');
    const token = String(j2.access_token);
    const expiresAt = new Date(Date.now() + Number(j2.expires_in || 0) * 1000).toISOString();

    // 4. who is this
    const me = await graphGet('graph.instagram.com', 'me', token, { fields: 'user_id,username' });
    const igId = String(me.user_id || me.id || row.user_id || '');
    if (!igId) return fail('no_account');

    // 5. store in Vault
    const sb = serviceClient();
    const { error } = await sb.rpc('ig_save_connection', {
      p_tenant: tenant, p_token: token, p_api_host: 'graph.instagram.com', p_ig_user_id: igId,
      p_ig_username: String(me.username || ''), p_expires_at: expiresAt, p_connected_by: state.u,
    });
    if (error) return fail('save_failed');
    return back(state.o, tenant, { ig: 'connected' });
  } catch (_) {
    // Error text can contain request details, so it is not logged here.
    console.error('ig-oauth-callback failed', GRAPH_VERSION);
    return fail('error');
  }
});
