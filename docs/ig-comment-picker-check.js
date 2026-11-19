// Round 2 headless check: Instagram comment picker. Mocked Supabase and mocked Edge Function, no real network writes.
//
// Part A: pure logic (rules, unbiased draw, comment paging, post lookup). Needs only Node 22.18+.
// Part B: the admin page in headless Chrome at 390px with mocked data.
//
// Usage:
//   npx wrangler dev --local --port 8788 &
//   BASE=http://127.0.0.1:8788 PW=/path/to/node_modules/playwright-core CHROME=/usr/bin/google-chrome \
//     node docs/ig-comment-picker-check.js
const path = require('path');
const BASE = process.env.BASE || 'http://127.0.0.1:8788';
const SHOTS = process.env.SHOTS || '/tmp/ig-shots';
require('fs').mkdirSync(SHOTS, { recursive: true });
const IgPicker = require('../js/ig-picker.js');

const checks = []; const fail = [];
function check(name, ok, extra) { checks.push([ok ? 'PASS' : 'FAIL', name, extra || '']); if (!ok) fail.push(name); }

async function partA() {
  const L = await import(path.join(__dirname, '../supabase/functions/_shared/ig_logic.ts'));

  // shortcode parsing
  const sc = L.shortcodeFromUrl;
  check('shortcode: /p/', sc('https://www.instagram.com/p/Cx9_aB-1/') === 'Cx9_aB-1');
  check('shortcode: /reel/ with query', sc('https://www.instagram.com/reel/AbC123/?igsh=xyz') === 'AbC123');
  check('shortcode: /username/p/', sc('https://instagram.com/someone/p/ZZ99/') === 'ZZ99');
  check('shortcode: rejects other hosts', sc('https://evil.example/p/ABC/') === null);
  check('shortcode: rejects profile url', sc('https://www.instagram.com/someone/') === null);
  check('shortcode: rejects garbage', sc('not a url') === null);

  // post lookup across pages
  const media = [
    { data: [{ id: '1', shortcode: 'AAA' }, { id: '2', shortcode: 'BBB' }], paging: { cursors: { after: 'c1' }, next: 'x' } },
    { data: [{ id: '3', shortcode: 'TARGET', permalink: 'https://www.instagram.com/p/TARGET/', timestamp: 't' }], paging: { cursors: { after: 'c2' }, next: 'x' } }
  ];
  const calls = [];
  const getMedia = async (p, params) => { calls.push([p, params.after || null]); return media[params.after ? 1 : 0]; };
  const found = await L.findMediaByShortcode(getMedia, 'me', 'TARGET');
  check('media lookup: finds shortcode on page 2', found.media && found.media.id === '3' && found.pagesScanned === 2, JSON.stringify(calls));
  const missing = await L.findMediaByShortcode(async () => ({ data: [{ id: '1', shortcode: 'AAA' }] }), 'me', 'NOPE');
  check('media lookup: not found returns null', missing.media === null);

  // comments paging (3 pages of 50, 120 comments), username from `from` when `username` is absent
  const total = 120; const mk = i => (i % 2 ? { id: 'c' + i, text: 't' + i, timestamp: '2026-11-01T00:00:00+0000', username: 'u' + i } : { id: 'c' + i, text: 't' + i, from: { id: 'g' + i, username: 'u' + i } });
  const cget = async (p, params) => {
    const start = params.after ? Number(params.after) : 0; const end = Math.min(start + 50, total);
    const data = []; for (let i = start; i < end; i++) data.push(mk(i));
    return end < total ? { data, paging: { cursors: { after: String(end) }, next: 'x' } } : { data, paging: { cursors: { after: 'z' } } };
  };
  const all = await L.fetchAllComments(cget, 'm1');
  check('comments: follows paging to the end', all.comments.length === 120 && all.pages === 3 && !all.truncated, all.comments.length + ' pages ' + all.pages);
  check('comments: reads username from from{} fallback', all.comments[0].username === 'u0' && all.comments[0].user_id === 'g0');
  const capped = await L.fetchAllComments(cget, 'm1', { maxComments: 60 });
  check('comments: safety cap sets truncated', capped.comments.length === 60 && capped.truncated === true);

  // replies: expansion plus a replies edge for the overflow
  const rget = async (p, params) => {
    if (p === 'm2/comments') return { data: [
      { id: 'a', text: 'top', username: 'alice', replies: { data: [{ id: 'a1', text: 'r1', username: 'bob' }], paging: { cursors: { after: 'r1' }, next: 'x' } } },
      { id: 'b', text: 'top2', username: 'carol' }] };
    if (p === 'a/replies') return { data: [{ id: 'a2', text: 'r2', username: 'dave' }] };
    throw new Error('unexpected ' + p);
  };
  const withReplies = await L.fetchAllComments(rget, 'm2', { includeReplies: true });
  check('replies: expansion and overflow page included', withReplies.comments.map(c => c.id).join(',') === 'a,a1,a2,b' && withReplies.comments.find(c => c.id === 'a2').parent_id === 'a');
  const noReplies = await L.fetchAllComments(rget, 'm2');
  check('replies: off by default', noReplies.comments.every(c => !c.is_reply));

  // from{} refused -> retry without it
  let tries = 0;
  const flaky = async (p, params) => { tries++; if (params.fields.includes('from{')) { const e = new Error('Unsupported field from'); e.kind = 'graph_error'; throw e; } return { data: [{ id: 'x', text: 'hi', username: 'zed' }] }; };
  const retried = await L.fetchAllComments(flaky, 'm3');
  check('comments: retries once without from{}', retried.comments.length === 1 && tries === 2);

  // rules
  const c = IgPicker.sampleComments('host');
  const r1 = IgPicker.applyRules(c, { onePerUser: true });
  check('rules: one entry per username', r1.entries.length === new Set(r1.entries.map(e => e.username)).size && r1.entries.length === r1.totalUsers);
  const r2 = IgPicker.applyRules(c, { onePerUser: false });
  check('rules: off keeps every comment', r2.entries.length === c.length);
  const r3 = IgPicker.applyRules(c, { minMentions: 2 });
  check('rules: min tags counts distinct handles', r3.entries.every(e => IgPicker.countMentions(e.text, e.username) >= 2) && r3.entries.length > 0);
  check('tags: self mention and repeats do not count', IgPicker.countMentions('@me @me @a @A', 'me') === 1);
  check('tags: ignore list works', IgPicker.countMentions('@host @a', 'x', ['host']) === 1);
  const r4 = IgPicker.applyRules(c, { keyword: 'ENTER, giveaway' });
  check('rules: keyword is case insensitive any-of', r4.entries.length > 0 && r4.entries.every(e => /enter|giveaway/i.test(e.text)));
  const r5 = IgPicker.applyRules(c, { excludeUsers: '@HOST, sample_admin_helper' });
  check('rules: exclude list is case and @ insensitive', !r5.entries.some(e => ['host', 'sample_admin_helper'].includes(e.username.toLowerCase())) && r5.rejected.excluded === 2);

  // draw
  const pool = r1.entries;
  const w = IgPicker.pickWinners(pool, { winners: 5, alternates: 2 });
  check('draw: winners plus backups, all distinct people', w.length === 7 && new Set(w.map(x => x.username)).size === 7 && w.filter(x => x.alternate).length === 2);
  const dup = IgPicker.pickWinners(r2.entries, { winners: 20 });
  check('draw: a person never wins twice even with several entries', new Set(dup.map(x => x.username)).size === dup.length);
  check('draw: asking for more than the pool returns the pool', IgPicker.pickWinners(pool.slice(0, 3), { winners: 10 }).length === 3);
  const counts = new Array(6).fill(0); const N = 60000;
  for (let i = 0; i < N; i++) counts[IgPicker.randomInt(6)]++;
  const exp = N / 6; const chi = counts.reduce((a, k) => a + (k - exp) * (k - exp) / exp, 0);
  check('draw: randomInt(6) is uniform (chi square < 20.5, 5 dof, p=0.001)', chi < 20.5, 'chi=' + chi.toFixed(2));
  let sawRejection = false; const fake = { getRandomValues(buf) { if (!sawRejection) { sawRejection = true; buf[0] = 4294967295; } else buf[0] = 7; return buf; } };
  check('draw: rejection sampling discards the biased top range', IgPicker.randomInt(10, fake) === 7 && sawRejection);
}

// ---------- Part B: browser ----------
const SB = 'https://khisgmozkufnzapmldgc.supabase.co';
const now = Math.floor(Date.now() / 1000);
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', role: 'authenticated', exp: now + 3600, email: 'admin@example.com' })}.sig`;
const user = { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'admin@example.com', user_metadata: {} };
const session = { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: 'r', user };

const state = { fnCalls: [], draws: [], tableCalls: [], historyRows: [], igRequests: [], connected: true, mode: 'ok' };
const realComments = [];
for (let i = 1; i <= 30; i++) realComments.push({ id: 'k' + i, username: 'fan_' + i, user_id: 'g' + i, text: i % 3 ? 'enter @friend' + i + ' @buddy' + i : 'nice', timestamp: '2026-11-0' + (1 + (i % 9)) + 'T10:00:00+0000', like_count: 0, is_reply: false, parent_id: null });
realComments.push({ id: 'xss', username: 'evil_user', user_id: 'gx', text: 'enter <img src=x onerror="window.__xss=1"> @a @b', timestamp: '2026-11-01T09:00:00+0000', like_count: 0, is_reply: false, parent_id: null });

async function mock(route) {
  const req = route.request(); const url = new URL(req.url()); const p = url.pathname;
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
  const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { ...cors, 'content-range': '0-0/0' }, body: JSON.stringify(body) });
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 200, headers: cors });
  if (p.startsWith('/auth/v1/user')) return json(user);
  if (p.startsWith('/auth/v1/')) return json(session);
  if (p === '/functions/v1/ig-comments') {
    const b = req.postDataJSON(); state.fnCalls.push(b);
    if (state.mode === 'unavailable') return json({ code: 'NOT_FOUND', message: 'Requested function was not found' }, 404);
    if (b.action === 'status') return json({ connected: state.connected, username: state.connected ? 'submerged_events' : null, api_host: 'graph.instagram.com', expires_at: '2027-01-15T00:00:00Z', app_configured: true });
    if (b.action === 'connect_url') return json({ url: 'https://www.instagram.com/oauth/authorize?client_id=1&state=s' });
    if (b.action === 'comments') {
      if (/NOTFOUND/.test(b.post_url)) return json({ error: 'post_not_found', message: 'That post was not found on @submerged_events.' }, 404);
      if (/EXPIRED/.test(b.post_url)) return json({ error: 'token_expired', message: 'The Instagram connection expired or was revoked. Connect Instagram again.' }, 401);
      return json({ media: { id: 'm9', permalink: b.post_url }, account: 'submerged_events', comments: realComments, count: realComments.length, truncated: false, pages: 1 });
    }
    return json({ error: 'unknown_action' }, 400);
  }
  if (p.startsWith('/rest/v1/rpc/')) {
    const fn = p.split('/').pop();
    if (fn === 'is_tenant_admin') return json(true);
    if (fn === 'ig_disconnect') return json({ connected: false });
    if (fn === 'gamification_admin_reps') return json([]);
    return json(null);
  }
  const t = p.replace('/rest/v1/', '');
  if (t === 'ig_comment_draws') {
    if (req.method() === 'POST') { state.draws.push(req.postDataJSON()); return route.fulfill({ status: 201, headers: cors, body: '' }); }
    return json(state.historyRows);
  }
  return json([]);
}

async function partB() {
  const { chromium } = require(process.env.PW || 'playwright-core');
  const browser = await chromium.launch({ executablePath: process.env.CHROME || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const errors = [];
  async function newPage(w = 390, h = 844) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    await ctx.route(SB + '/**', mock);
    await ctx.addInitScript(([s]) => { localStorage.setItem('sb-khisgmozkufnzapmldgc-auth-token', s); }, [JSON.stringify(session)]);
    const page = await ctx.newPage();
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    page.on('request', r => { if (/instagram\.com|facebook\.com/.test(new URL(r.url()).host) && !/^https:\/\/www\.instagram\.com\/oauth/.test(r.url())) state.igRequests.push(r.url()); });
    return { ctx, page };
  }
  const visibleNav = page => page.$$eval('.nav-btn', bs => bs.filter(b => getComputedStyle(b).display !== 'none').map(b => b.textContent.trim()));
  const overflow = page => page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);

  // 1. flag off (acme-demo): nothing visible, no function calls
  let { ctx, page } = await newPage();
  await page.goto(BASE + '/acme-demo/admin');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 }); await page.waitForTimeout(600);
  let nav = await visibleNav(page);
  check('flag false: Giveaway tab hidden', !nav.includes('Giveaway'), nav.join(','));
  await page.evaluate(() => showView('giveaway'));
  check('flag false: giveaway view cannot be opened', await page.evaluate(() => !document.getElementById('view-giveaway').classList.contains('active')));
  check('flag false: no ig-comments call made', state.fnCalls.length === 0);
  await ctx.close();

  // 2. flag on (submerged): demo mode
  ({ ctx, page } = await newPage());
  await page.goto(BASE + '/submerged/admin');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 }); await page.waitForTimeout(800);
  nav = await visibleNav(page);
  check('flag true: Giveaway tab visible', nav.includes('Giveaway'), nav.join(','));
  check('flag true: six tabs fit at 390px without page overflow', !(await overflow(page)));
  await page.click('#nav-giveaway'); await page.waitForTimeout(600);
  check('connection status shows connected account', /Connected as @submerged_events/.test(await page.textContent('#ig-conn-status')), await page.textContent('#ig-conn-status'));
  check('exclude list prefilled with own account', (await page.inputValue('#ig-exclude')).includes('submerged_events'));
  check('status call uses tenant slug', state.fnCalls[0] && state.fnCalls[0].action === 'status' && state.fnCalls[0].tenant === 'submerged');
  await page.screenshot({ path: SHOTS + '/ig-1-connected.png', fullPage: true });

  await page.click('text=Try with sample comments'); await page.waitForTimeout(300);
  check('demo: banner says SAMPLE DATA', await page.isVisible('#ig-demo-banner') && /SAMPLE DATA/.test(await page.textContent('#ig-demo-banner')));
  check('demo: rules card appears', await page.isVisible('#ig-rules-card'));
  const base = IgPicker.applyRules(IgPicker.sampleComments('submerged_events'), IgPicker.cleanRules({ excludeUsers: 'submerged_events', ignoreMentions: ['submerged_events'] }));
  check('demo: eligible count matches the rules engine', (await page.textContent('#ig-eligible-stat')).includes(String(base.eligibleUsers) + ' people eligible'), await page.textContent('#ig-eligible-stat'));
  await page.fill('#ig-min-tags', '2'); await page.fill('#ig-keyword', 'enter');
  const want = IgPicker.applyRules(IgPicker.sampleComments('submerged_events'), IgPicker.cleanRules({ minMentions: 2, keyword: 'enter', excludeUsers: 'submerged_events', ignoreMentions: ['submerged_events'] }));
  check('demo: tags and keyword rules change the count', (await page.textContent('#ig-eligible-stat')).includes(String(want.eligibleUsers) + ' people eligible') && want.eligibleUsers < base.eligibleUsers, await page.textContent('#ig-eligible-stat'));
  await page.fill('#ig-winners', '3'); await page.fill('#ig-alternates', '1');
  const drawsBefore = state.draws.length;
  await page.click('#ig-draw-btn'); await page.waitForTimeout(400);
  const names = await page.$$eval('#ig-winners-list .ig-winner a', as => as.map(a => a.textContent));
  check('demo: 3 winners and 1 backup shown, all different', names.length === 4 && new Set(names).size === 4, names.join(','));
  check('demo: result card is labeled as a sample draw', /Sample draw/.test(await page.textContent('#ig-result-title')));
  check('demo: draw is not saved', state.draws.length === drawsBefore && /nothing was saved/.test(await page.textContent('#ig-save-msg')));
  check('demo: no overflow at 390px', !(await overflow(page)));
  await page.screenshot({ path: SHOTS + '/ig-2-demo-draw.png', fullPage: true });

  // 3. real (mocked function) draw is saved
  await page.fill('#ig-post-url', 'https://www.instagram.com/p/REAL123/');
  await page.fill('#ig-min-tags', '0'); await page.fill('#ig-keyword', '');
  await page.fill('#ig-winners', '2'); await page.fill('#ig-alternates', '1');
  await page.click('#ig-load-btn'); await page.waitForTimeout(500);
  const loadCall = state.fnCalls.find(c => c.action === 'comments');
  check('load: sends post url and tenant, never a token', loadCall && loadCall.post_url.includes('REAL123') && loadCall.tenant === 'submerged' && !('token' in loadCall));
  check('load: banner hidden for real data', !(await page.isVisible('#ig-demo-banner')));
  check('load: shows loaded counts', /Loaded 31 comments from 31 people on @submerged_events/.test(await page.textContent('#ig-loaded-stat')), await page.textContent('#ig-loaded-stat'));
  await page.fill('#ig-min-tags', '2'); await page.fill('#ig-keyword', 'enter');
  await page.waitForTimeout(150);
  const eligText = await page.textContent('#ig-eligible-stat');
  const realWant = IgPicker.applyRules(realComments, IgPicker.cleanRules({ minMentions: 2, keyword: 'enter', excludeUsers: 'submerged_events', ignoreMentions: ['submerged_events'] }));
  check('load: eligible count correct for real data', eligText.includes(realWant.eligibleUsers + ' people eligible'), eligText);
  await page.click('#ig-draw-btn'); await page.waitForTimeout(500);
  check('draw: record saved once', state.draws.length === 1, String(state.draws.length));
  const rec = state.draws[0] || {};
  check('draw: record has tenant, post, rules, counts, winners', rec.tenant_slug === 'submerged' && /REAL123/.test(rec.post_url) && rec.media_id === 'm9' && rec.rules && rec.rules.minMentions === 2 && rec.winners && rec.winners.length === 3 && rec.eligible_count === realWant.entries.length && rec.entrant_count === 31, JSON.stringify(rec).slice(0, 300));
  check('draw: record has no drawn_by or drawn_at from the client (server stamps them)', !('drawn_by' in rec) && !('drawn_at' in rec));
  check('draw: saved message shown', /Saved to Past draws/.test(await page.textContent('#ig-save-msg')));
  check('security: untrusted comment text is escaped (no injected element)', await page.evaluate(() => !document.querySelector('#ig-winners-list img') && !window.__xss));
  check('security: browser never calls Instagram or Facebook directly', state.igRequests.length === 0, state.igRequests.join(','));
  await page.click('text=Draw again'); await page.waitForTimeout(400);
  check('draw again: saves a second record', state.draws.length === 2);
  await page.screenshot({ path: SHOTS + '/ig-3-real-draw.png', fullPage: true });

  // 4. error messages
  await page.fill('#ig-post-url', 'https://www.instagram.com/p/NOTFOUND/'); await page.click('#ig-load-btn'); await page.waitForTimeout(400);
  check('error: post not found message shown', /not found on @submerged_events/.test(await page.textContent('#ig-load-msg')));
  await page.fill('#ig-post-url', 'https://www.instagram.com/p/EXPIRED/'); await page.click('#ig-load-btn'); await page.waitForTimeout(400);
  check('error: expired token message shown', /Connect Instagram again/.test(await page.textContent('#ig-load-msg')));
  await page.fill('#ig-post-url', ''); await page.click('#ig-load-btn'); await page.waitForTimeout(200);
  check('error: empty link asks for a link', /Paste a link/.test(await page.textContent('#ig-load-msg')));

  // 5. history
  state.historyRows = [{ id: 'd1', post_url: 'https://www.instagram.com/p/OLD1/', winners: [{ username: 'winner_one', alternate: false }, { username: 'backup_one', alternate: true }], entrant_count: 120, eligible_count: 80, drawn_at: '2026-11-10T15:00:00Z', rules: {} }];
  await page.evaluate(() => igLoadHistory()); await page.waitForTimeout(300);
  const hist = await page.textContent('#ig-history');
  check('history: lists past draws without backups', /@winner_one/.test(hist) && !/backup_one/.test(hist) && /80 of 120/.test(hist), hist.slice(0, 200));
  await ctx.close();

  // 6. return from Instagram (connect redirect), and service unavailable
  ({ ctx, page } = await newPage());
  await page.goto(BASE + '/submerged/admin?ig=connected');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 }); await page.waitForTimeout(900);
  check('return: opens Giveaway tab with connected message', await page.evaluate(() => document.getElementById('view-giveaway').classList.contains('active')) && /Instagram connected/.test(await page.textContent('#ig-conn-msg')));
  check('return: query string is cleaned up', !page.url().includes('ig=connected'));
  await ctx.close();
  state.mode = 'unavailable';
  ({ ctx, page } = await newPage());
  await page.goto(BASE + '/submerged/admin?ig=error&reason=missing_permission');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 }); await page.waitForTimeout(900);
  check('return: error reason is explained', /comments permission/.test(await page.textContent('#ig-conn-msg')));
  check('unavailable service: clear setup message, no crash', /not set up yet/.test(await page.textContent('#ig-conn-status')), await page.textContent('#ig-conn-status'));
  await page.screenshot({ path: SHOTS + '/ig-4-unavailable.png', fullPage: true });
  await ctx.close();

  const realErrors = errors.filter(e => !/Failed to load resource/.test(e));
  console.log('page errors:', JSON.stringify(realErrors));
  await browser.close();
  return realErrors.length;
}

(async () => {
  await partA();
  let errs = 0;
  if (!process.env.SKIP_BROWSER) errs = await partB();
  console.log(checks.map(c => c.join(' | ')).join('\n'));
  console.log(`\n${checks.length - fail.length}/${checks.length} checks passed`);
  process.exit(fail.length || errs ? 1 : 0);
})().catch(e => { console.error('FAIL', e); process.exit(1); });
