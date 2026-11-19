// Runs the ig-comments and ig-oauth-callback Edge Functions in Deno with every network call mocked
// (Supabase REST/Auth and the Instagram hosts). Nothing is deployed and no real service is contacted.
// Usage: deno run --allow-env --allow-net=esm.sh,deno.land docs/ig-edge-function-check.ts
// (--allow-net is only for fetching the supabase-js module the functions import.)
const SUPA = 'https://test.supabase.co';
const SECRET_TOKEN = 'IGAA_LONG_LIVED_TOKEN_SHOULD_NEVER_LEAVE_THE_SERVER';
Deno.env.set('SUPABASE_URL', SUPA);
Deno.env.set('SUPABASE_ANON_KEY', 'anon');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'service');
Deno.env.set('IG_APP_ID', '555000111');
Deno.env.set('IG_APP_SECRET', 'app_secret_value_for_tests_only');

const handlers: Record<string, (r: Request) => Promise<Response>> = {};
let current = '';
(Deno as any).serve = (h: (r: Request) => Promise<Response>) => { handlers[current] = h; return { shutdown() {} }; };

const log: { url: URL; init?: RequestInit; body?: any }[] = [];
const state = { adminTokens: new Set(['admin-jwt']), connection: null as any, saved: [] as any[], updated: [] as any[], mediaPages: 0, perms: 'instagram_business_basic,instagram_business_manage_comments' };
const j = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { 'Content-Type': 'application/json' } });

globalThis.fetch = (async (input: any, init?: RequestInit) => {
  const req = input instanceof Request ? input : new Request(input, init);
  const url = new URL(req.url);
  let body: any = null;
  try { const t = await req.clone().text(); body = t && t.startsWith('{') ? JSON.parse(t) : t; } catch (_) { /* */ }
  log.push({ url, init, body });
  const auth = req.headers.get('authorization') || '';
  if (url.origin === SUPA) {
    if (url.pathname === '/auth/v1/user') return state.adminTokens.has(auth.replace(/^Bearer /, '')) || auth === 'Bearer nonadmin-jwt' ? j({ id: auth === 'Bearer nonadmin-jwt' ? 'u2' : 'u1', aud: 'authenticated' }) : j({ msg: 'bad jwt' }, 401);
    if (url.pathname === '/rest/v1/rpc/is_tenant_admin') return j(state.adminTokens.has(auth.replace(/^Bearer /, '')) && body.p_tenant === 'submerged');
    if (url.pathname === '/rest/v1/rpc/ig_connection_secret') return j(state.connection);
    if (url.pathname === '/rest/v1/rpc/ig_save_connection') { state.saved.push(body); return new Response(null, { status: 204 }); }
    if (url.pathname === '/rest/v1/rpc/ig_update_token') { state.updated.push(body); return new Response(null, { status: 204 }); }
  }
  if (url.host === 'api.instagram.com' && url.pathname === '/oauth/access_token') {
    if (!state.perms) return j({ error_message: 'bad code' }, 400);
    return j({ data: [{ access_token: 'SHORT_LIVED', user_id: '1784', permissions: state.perms }] });
  }
  if (url.host === 'graph.instagram.com') {
    const p = url.pathname.replace(/^\/v\d+\.\d+/, '');
    if (p === '/access_token') return j({ access_token: SECRET_TOKEN, token_type: 'bearer', expires_in: 5183944 });
    if (p === '/refresh_access_token') return j({ access_token: 'REFRESHED_TOKEN_VALUE_0123456789', token_type: 'bearer', expires_in: 5183944 });
    if (p === '/me') return j({ user_id: '1784', username: 'submerged_events' });
    if (p === '/me/media') {
      state.mediaPages++;
      return url.searchParams.get('after')
        ? j({ data: [{ id: 'M2', shortcode: 'TARGET1', permalink: 'https://www.instagram.com/p/TARGET1/', timestamp: 't' }] })
        : j({ data: [{ id: 'M1', shortcode: 'OTHER' }], paging: { cursors: { after: 'c1' }, next: 'https://x' } });
    }
    if (p === '/M2/comments') {
      const after = url.searchParams.get('after');
      return after
        ? j({ data: [{ id: 'k3', text: 'enter @a @b', timestamp: '2026-11-02T00:00:00+0000', username: 'carol' }] })
        : j({ data: [{ id: 'k1', text: 'hi', timestamp: '2026-11-01T00:00:00+0000', username: 'alice', from: { id: '9', username: 'alice' } }, { id: 'k2', text: 'yo', timestamp: '2026-11-01T01:00:00+0000', from: { id: '8', username: 'bob' } }], paging: { cursors: { after: 'cc1' }, next: 'https://x' } });
    }
  }
  return j({ error: { message: 'unmocked ' + url.host + url.pathname, code: 1 } }, 500);
}) as typeof fetch;

current = 'comments'; await import('../supabase/functions/ig-comments/index.ts');
current = 'callback'; await import('../supabase/functions/ig-oauth-callback/index.ts');

const results: [string, boolean, string?][] = [];
const ok = (n: string, c: boolean, x = '') => results.push([n, !!c, x]);
const ORIGIN = 'https://woosahcrew.com';
const call = (body: unknown, token = 'admin-jwt', origin: string | null = ORIGIN) => handlers.comments(new Request(SUPA + '/functions/v1/ig-comments', {
  method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(origin ? { Origin: origin } : {}) }, body: JSON.stringify(body) }));

// auth
ok('no Authorization header is refused', (await call({ action: 'status', tenant: 'submerged' }, '')).status === 403);
ok('invalid JWT is refused', (await call({ action: 'status', tenant: 'submerged' }, 'garbage')).status === 403);
ok('signed in non-admin is refused', (await call({ action: 'status', tenant: 'submerged' }, 'nonadmin-jwt')).status === 403);
ok('admin of a different tenant is refused', (await call({ action: 'status', tenant: 'acme-demo' })).status === 403);
ok('bad tenant slug is refused', (await call({ action: 'status', tenant: '../x' })).status === 400);
ok('GET is refused', (await handlers.comments(new Request(SUPA + '/f', { method: 'GET' }))).status === 405);

// status without a connection
let r = await call({ action: 'status', tenant: 'submerged' }); let b = await r.json();
ok('status: not connected', r.status === 200 && b.connected === false && b.app_configured === true);
r = await call({ action: 'comments', tenant: 'submerged', post_url: 'https://www.instagram.com/p/TARGET1/' });
ok('comments: 409 when not connected', r.status === 409);

// connect url
r = await call({ action: 'connect_url', tenant: 'submerged' }); b = await r.json();
const cu = new URL(b.url);
ok('connect_url: Instagram authorize endpoint with app id, scopes and redirect', cu.origin + cu.pathname === 'https://www.instagram.com/oauth/authorize' && cu.searchParams.get('client_id') === '555000111' && cu.searchParams.get('scope') === 'instagram_business_basic,instagram_business_manage_comments' && cu.searchParams.get('response_type') === 'code' && cu.searchParams.get('redirect_uri') === SUPA + '/functions/v1/ig-oauth-callback', b.url);
ok('connect_url: the app secret is not in the URL', !b.url.includes('app_secret'));
ok('connect_url: refused from an unknown origin', (await call({ action: 'connect_url', tenant: 'submerged' }, 'admin-jwt', 'https://evil.example')).status === 403);
ok('connect_url: branch preview origin is allowed', (await call({ action: 'connect_url', tenant: 'submerged' }, 'admin-jwt', 'https://round2-ig-comment-picker-submerged-crew.shaun-6ad.workers.dev')).status === 200);
const state1 = cu.searchParams.get('state')!;

// callback
const cb = (qs: Record<string, string>) => handlers.callback(new Request(SUPA + '/functions/v1/ig-oauth-callback?' + new URLSearchParams(qs)));
r = await cb({ code: 'abc#_', state: state1 });
let loc = r.headers.get('Location') || '';
ok('callback: redirects to the admin page with ig=connected', r.status === 302 && loc === ORIGIN + '/submerged/admin?ig=connected', loc);
ok('callback: saved the long lived token server side with account and expiry', state.saved.length === 1 && state.saved[0].p_token === SECRET_TOKEN && state.saved[0].p_tenant === 'submerged' && state.saved[0].p_api_host === 'graph.instagram.com' && state.saved[0].p_ig_username === 'submerged_events' && state.saved[0].p_connected_by === 'u1' && !!state.saved[0].p_expires_at);
ok('callback: token is not in the redirect', !loc.includes(SECRET_TOKEN) && !loc.includes('LIVED'));
const tokenReq = log.find((l) => l.url.host === 'api.instagram.com');
ok('callback: code exchange is a POST with redirect_uri and client secret in the body, not the URL', !!tokenReq && tokenReq.init?.method === 'POST' && !tokenReq.url.search);
r = await cb({ code: 'abc', state: state1.slice(0, -3) + 'AAA' });
ok('callback: tampered state is rejected', r.status === 400 && !r.headers.get('Location'));
r = await cb({ code: 'abc' });
ok('callback: missing state is rejected', r.status === 400);
r = await cb({ error: 'access_denied', state: state1 });
ok('callback: user denied goes back with reason=denied', (r.headers.get('Location') || '').includes('ig=error') && (r.headers.get('Location') || '').includes('reason=denied'));
state.perms = 'instagram_business_basic';
r = await cb({ code: 'abc', state: state1 });
ok('callback: missing comments permission is an error and nothing more is saved', (r.headers.get('Location') || '').includes('reason=missing_permission') && state.saved.length === 1);
state.perms = 'instagram_business_basic,instagram_business_manage_comments';

// comments with a connection
state.connection = { tenant: 'submerged', token: SECRET_TOKEN, api_host: 'graph.instagram.com', ig_user_id: '1784', username: 'submerged_events', expires_at: new Date(Date.now() + 50 * 864e5).toISOString(), refreshed_at: new Date(Date.now() - 5 * 864e5).toISOString(), connected_at: new Date(Date.now() - 5 * 864e5).toISOString() };
r = await call({ action: 'status', tenant: 'submerged' }); const stText = await r.text();
ok('status: connected, and the response never contains the token', JSON.parse(stText).connected === true && !stText.includes('IGAA'));
r = await call({ action: 'comments', tenant: 'submerged', post_url: 'https://www.instagram.com/reel/TARGET1/?igsh=zz' }); const bodyText = await r.text(); b = JSON.parse(bodyText);
ok('comments: 200, found the media on page 2 and paged all comments', r.status === 200 && b.media.id === 'M2' && b.count === 3 && state.mediaPages === 2, bodyText.slice(0, 200));
ok('comments: username from username or from{}', b.comments.map((c: any) => c.username).join(',') === 'alice,bob,carol');
ok('comments: response never contains the token', !bodyText.includes('IGAA'));
const graphCalls = log.filter((l) => l.url.host === 'graph.instagram.com' && l.url.pathname.includes('/M2/comments'));
ok('comments: Graph call uses host graph.instagram.com, v27.0, limit 50 and username+from fields', graphCalls.length === 2 && graphCalls[0].url.pathname === '/v27.0/M2/comments' && graphCalls[0].url.searchParams.get('limit') === '50' && /username/.test(graphCalls[0].url.searchParams.get('fields')!) && /from\{id,username\}/.test(graphCalls[0].url.searchParams.get('fields')!) && graphCalls[1].url.searchParams.get('after') === 'cc1');
ok('comments: token only ever goes to graph.instagram.com or Supabase', log.filter((l) => l.url.search.includes(SECRET_TOKEN)).every((l) => l.url.host === 'graph.instagram.com'));
r = await call({ action: 'comments', tenant: 'submerged', post_url: 'https://www.instagram.com/p/NOPE/' }); b = await r.json();
ok('comments: post not on the account gives post_not_found (404)', r.status === 404 && b.error === 'post_not_found');
r = await call({ action: 'comments', tenant: 'submerged', post_url: 'https://evil.example/p/x/' });
ok('comments: non Instagram link is rejected (400)', r.status === 400);
ok('refresh: not attempted while 50 days remain', state.updated.length === 0);

// refresh
state.connection.expires_at = new Date(Date.now() + 5 * 864e5).toISOString();
r = await call({ action: 'comments', tenant: 'submerged', post_url: 'https://www.instagram.com/p/TARGET1/' });
ok('refresh: token refreshed automatically when 5 days remain', r.status === 200 && state.updated.length === 1 && state.updated[0].p_token.startsWith('REFRESHED'));
state.connection.refreshed_at = new Date().toISOString(); state.updated.length = 0;
r = await call({ action: 'refresh', tenant: 'submerged' }); b = await r.json();
ok('refresh: refused when the token is under 24 hours old (Meta rule)', b.refreshed === false && b.reason === 'too_new' && state.updated.length === 0);
state.connection.expires_at = new Date(Date.now() - 864e5).toISOString();
r = await call({ action: 'refresh', tenant: 'submerged' }); b = await r.json();
ok('refresh: expired token is not refreshed', b.refreshed === false && b.reason === 'expired');

// pasted token path
r = await call({ action: 'save_token', tenant: 'submerged', token: 'short', api_host: 'graph.instagram.com' });
ok('save_token: junk token rejected', r.status === 400);
r = await call({ action: 'save_token', tenant: 'submerged', token: SECRET_TOKEN, api_host: 'evil.example' });
ok('save_token: unknown host rejected', r.status === 400);
const before = state.saved.length;
r = await call({ action: 'save_token', tenant: 'submerged', token: SECRET_TOKEN, api_host: 'graph.instagram.com' }); b = await r.json();
ok('save_token: verified with /me then stored, token not echoed', r.status === 200 && b.username === 'submerged_events' && state.saved.length === before + 1 && !JSON.stringify(b).includes('IGAA'));

console.log(results.map(([n, c, x]) => `${c ? 'PASS' : 'FAIL'} | ${n}${c || !x ? '' : ' | ' + x}`).join('\n'));
const failed = results.filter((x) => !x[1]).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
Deno.exit(failed ? 1 : 0);
