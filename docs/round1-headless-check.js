// Round 1 headless check (mocked Supabase, no network writes to the real project).
// Usage: npx wrangler dev --local --port 8788 &   then:
//   BASE=http://127.0.0.1:8788 PW=/path/to/node_modules/playwright-core node docs/round1-headless-check.js
const { chromium } = require(process.env.PW || 'playwright-core');
const BASE = process.env.BASE || 'http://127.0.0.1:8788';
const SB = 'https://khisgmozkufnzapmldgc.supabase.co';
const now = Math.floor(Date.now() / 1000);
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = `${b64({ alg: 'HS256', typ: 'JWT' })}.${b64({ sub: 'u1', role: 'authenticated', exp: now + 3600, email: 'demo@example.com' })}.sig`;
const user = { id: 'u1', aud: 'authenticated', role: 'authenticated', email: 'demo@example.com', user_metadata: {} };
const session = { access_token: jwt, token_type: 'bearer', expires_in: 3600, expires_at: now + 3600, refresh_token: 'r', user };
const rep = { id: 'r1', user_id: 'u1', name: 'Jordan Rivera', email: 'demo@example.com', promo_code: 'JORDAN', rank: 'Recruit', lifetime_points: 80, status: 'active', created_at: '2026-07-01T00:00:00Z' };
const tier = { name: 'Recruit', min_points: 0, icon: '🎫', color: '#7a8799', perk: 'Sell codes to level up' };
const progress = { points: 80, tickets: 4, sales: 2, shows_joined: 3, tier, next_tier: { name: 'Rising Star', points_to_go: 320 }, progress_pct: 20, position: 1, total_reps: 3, tiers: [tier], badges: [], breakdown: { sales: 80, content: 0, milestones: 0 }, hidden_from_leaderboard: false,
  rules: { points_per_ticket: 20, points_per_sale: 0, include_content_points: true, content_flyer_points: 50, content_original_points: 150, milestones: [{ tickets: 10, points: 200 }] } };

const state = { delayRpc: 0, calls: [], demoBodies: [], signupBodies: [], rewardsFlag: false, failRpc: false };
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function mock(route) {
  const req = route.request(); const url = new URL(req.url()); const path = url.pathname;
  const single = (req.headers()['accept'] || '').includes('vnd.pgrst.object');
  const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*', 'access-control-allow-methods': '*' };
  const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', headers: { ...cors, 'content-range': '0-0/0' }, body: JSON.stringify(body) });
  if (req.method() === 'OPTIONS') return route.fulfill({ status: 200, headers: cors });
  if (path === '/rest/v1/demo_requests') { state.demoBodies.push(req.postDataJSON()); return route.fulfill({ status: 201, headers: cors, body: '' }); }
  if (path === '/auth/v1/signup') { state.signupBodies.push(req.postDataJSON()); return json({ ...session, user }); }
  if (path.startsWith('/auth/v1/user')) return json(user);
  if (path.startsWith('/auth/v1/')) return json(session);
  if (path.startsWith('/rest/v1/rpc/')) {
    const fn = path.split('/').pop(); state.calls.push(fn);
    if (state.delayRpc) await sleep(state.delayRpc);
    if (state.failRpc) return json({ message: 'down' }, 500);
    if (fn === 'gamification_my_progress') return json(progress);
    if (fn === 'tenant_pay_rates') return json({ Recruit: 2, 'Rising Star': 2.5 });
    if (fn === 'gamification_leaderboard') return json([]);
    if (fn === 'promo_code_available') return json(true);
    return json(null);
  }
  const t = path.replace('/rest/v1/', '');
  if (t === 'reps') return json(single ? rep : [rep]);
  if (t === 'rep_events') return json([{ rep_id: 'r1', event_id: 'e1', codes_sold: 4, cash_earned: 8, events: { name: 'Show', status: 'active' } }]);
  return json([]);
}

const checks = []; const fail = [];
function check(name, ok, extra) { checks.push([ok ? 'PASS' : 'FAIL', name, extra || '']); if (!ok) fail.push(name); }
const BAD = /undefined|NaN|\bnull\b|signed in as \.|signed in as\s*$|pts \+ cash|\$\s?NaN/i;
const REMOVED = /spotify|soundcloud|apple music|vol\. 12|read your music|taste data|connect (spotify|apple|youtube|soundcloud)|posh|tixr|dice|coming soon/i;

(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--no-sandbox'] });
  const errors = [];
  async function newPage(authed, w = 390, h = 844) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 2, isMobile: true, hasTouch: true });
    await ctx.route(SB + '/**', mock);
    if (authed) await ctx.addInitScript(([s]) => { localStorage.setItem('sb-khisgmozkufnzapmldgc-auth-token', s); }, [JSON.stringify(session)]);
    const page = await ctx.newPage();
    page.on('pageerror', e => errors.push('pageerror: ' + e.message));
    return { ctx, page };
  }
  const visible = page => page.evaluate(() => document.body.innerText);

  // ---------- Portal: logged out ----------
  let { ctx, page } = await newPage(false);
  await page.goto(BASE + '/submerged');
  await page.waitForSelector('#screen-login.active');
  await page.waitForTimeout(600);
  let txt = await visible(page);
  check('login: no removed/fake strings visible', !REMOVED.test(txt), (txt.match(REMOVED) || [''])[0]);
  check('login: only the email button (no social buttons)', (await page.$$('.social-login-btn')).length === 1 && /continue with email/i.test(txt));
  check('login: consent text updated', /Woosah Terms of Use/.test(await page.textContent('[data-tenant-consent]')) && !/music/i.test(await page.textContent('[data-tenant-consent]')));
  await page.screenshot({ path: '/workspace/shots/r1-login.png' });
  await page.click('text=Continue with email');
  await page.waitForSelector('#email-login-panel', { state: 'visible' });
  await page.click('text=Create account');
  await page.waitForSelector('#email-signup-panel', { state: 'visible' });
  check('signup form renders', !!(await page.$('#signup-email')) && !!(await page.$('#signup-pass')) && !!(await page.$('#signup-code')));
  await page.screenshot({ path: '/workspace/shots/r1-signup.png', fullPage: true });
  await page.fill('#signup-first', 'Test'); await page.fill('#signup-last', 'Rep');
  await page.fill('#signup-email', 'test@example.com'); await page.fill('#signup-pass', 'secret123');
  await page.fill('#signup-code', 'TESTR1'); await page.check('#signup-tos');
  await page.click('#signup-btn'); await page.waitForTimeout(1200);
  check('email signup sends a signup request', state.signupBodies.length === 1 && state.signupBodies[0].email === 'test@example.com');
  await ctx.close();

  // ---------- Portal: logged in, slow data (loading states) ----------
  state.delayRpc = 1500;
  ({ ctx, page } = await newPage(true));
  await page.goto(BASE + '/submerged');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 });
  txt = await visible(page);
  check('loading: no empty-interpolation text before rpc data', !BAD.test(txt), (txt.match(BAD) || [''])[0]);
  check('loading: rate row shows a skeleton, no half sentence', (await page.$$('#rate-row .skel')).length > 0 && !/Each use earns/.test(await page.textContent('#rate-row')));
  check('loading: point values show a skeleton, not hardcoded numbers', (await page.$$('#point-values .skel')).length > 0 && !/\+20 pts/.test(await page.textContent('#point-values')));
  await page.screenshot({ path: '/workspace/shots/r1-home-loading.png', fullPage: true });
  const navLabels = await page.$$eval('.nav-btn', bs => bs.filter(b => getComputedStyle(b).display !== 'none').map(b => b.textContent.trim()));
  check('nav has no Mix or Rewards', JSON.stringify(navLabels) === JSON.stringify(['My Stats', 'Events', 'Rankings', 'Submit']), navLabels.join(','));
  check('no rewards/music view in DOM', !(await page.$('#view-rewards')) && !(await page.$('#view-music')));
  await page.waitForFunction(() => /Each use earns points and cash/.test(document.getElementById('rate-row').innerText), null, { timeout: 8000 });
  txt = await visible(page);
  check('loaded: rate row filled', /\$2\.00 \/ code at Recruit rank/.test(txt));
  check('loaded: no bad text', !BAD.test(txt), (txt.match(BAD) || [''])[0]);
  check('loaded: no removed strings visible', !REMOVED.test(txt), (txt.match(REMOVED) || [''])[0]);
  await page.screenshot({ path: '/workspace/shots/r1-home-loaded.png', fullPage: true });
  await page.evaluate(() => showView('rewards')); await page.evaluate(() => showView('music'));
  check('showView(rewards|music) falls back to home', await page.evaluate(() => document.getElementById('view-home').classList.contains('active')));
  await ctx.close();

  // failing rpc: skeleton must resolve to a message
  state.delayRpc = 0; state.failRpc = true;
  ({ ctx, page } = await newPage(true));
  await page.goto(BASE + '/submerged');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 }); await page.waitForTimeout(1500);
  txt = await visible(page);
  check('rpc failure: no skeletons left, no bad text', (await page.$$('#point-values .skel, #rate-row .skel')).length === 0 && !BAD.test(txt), (txt.match(BAD) || [''])[0]);
  await ctx.close(); state.failRpc = false;

  // flag honored: rewardsStore true mounts the tab
  ({ ctx, page } = await newPage(true));
  await ctx.route(BASE + '/tenants/submerged.json', async route => {
    const res = await route.fetch(); const j = await res.json(); j.featureFlags.rewardsStore = true;
    route.fulfill({ response: res, json: j });
  });
  await page.goto(BASE + '/submerged');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 }); await page.waitForTimeout(800);
  const nav2 = await page.$$eval('.nav-btn', bs => bs.filter(b => getComputedStyle(b).display !== 'none').map(b => b.textContent.trim()));
  await page.evaluate(() => showView('rewards'));
  check('flag rewardsStore=true shows Rewards tab and view', nav2.includes('Rewards') && await page.evaluate(() => document.getElementById('view-rewards').classList.contains('active')), nav2.join(','));
  await ctx.close();

  // ---------- Landing ----------
  ({ ctx, page } = await newPage(false));
  await page.goto(BASE + '/');
  await page.waitForSelector('#team_size'); await page.waitForTimeout(500);
  txt = await visible(page);
  check('landing: no removed strings visible', !REMOVED.test(txt), (txt.match(REMOVED) || [''])[0]);
  check('landing: Works with Eventbrite kept', /Works with Eventbrite/.test(txt));
  const opts = await page.$$eval('#team_size option', os => os.map(o => [o.value, o.textContent.trim()]));
  check('landing: team size labels exact', JSON.stringify(opts.slice(1).map(o => o[1])) === JSON.stringify(['1 to 10', '11 to 25', '26 to 50', '51 to 99', '100 or more']), JSON.stringify(opts));
  check('landing: rewards badge and image hidden', await page.evaluate(() => [...document.querySelectorAll('[data-feature="rewardsStore"]')].every(e => e.offsetParent === null)));
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
  check('landing: no horizontal overflow at 390px', !overflow);
  await page.screenshot({ path: '/workspace/shots/r1-landing.png', fullPage: true });
  for (const [val] of opts.slice(1)) {
    await page.evaluate(() => { const f = document.getElementById('demo-form'); f.style.display = ''; document.getElementById('demo-success').classList.remove('show'); const b = document.getElementById('demo-submit'); b.disabled = false; });
    await page.fill('#name', 'Test'); await page.fill('#email', 'a@example.com'); await page.fill('#org', 'Org');
    await page.selectOption('#team_size', val); await page.selectOption('#ticketing', 'eventbrite');
    await page.click('#demo-submit'); await page.waitForTimeout(500);
  }
  check('landing: demo insert sent for all 5 values (mocked)', JSON.stringify(state.demoBodies.map(b => b.team_size)) === JSON.stringify(['1-10', '11-25', '26-50', '51-100', '100+']), JSON.stringify(state.demoBodies.map(b => b.team_size)));
  await ctx.close();

  console.log(checks.map(c => c.join(' | ')).join('\n'));
  const realErrors = errors.filter(e => !/Failed to load resource/.test(e));
  console.log('page errors:', JSON.stringify(realErrors));
  await browser.close();
  process.exit(fail.length || realErrors.length ? 1 : 0);
})().catch(e => { console.error('FAIL', e); process.exit(1); });
