// Headless UI smoke test for gamification (mocked Supabase, fake data).
// Usage: python3 -m http.server 8787 (repo root) & ; npm i playwright-core ; node docs/gamification-headless-check.js
// Writes screenshots to /workspace/shots — adjust paths as needed.
const { chromium } = require('playwright-core');
const SB = 'https://khisgmozkufnzapmldgc.supabase.co';
const now = Math.floor(Date.now()/1000);
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = `${b64({alg:'HS256',typ:'JWT'})}.${b64({sub:'u1',role:'authenticated',exp:now+3600,email:'demo@example.com'})}.sig`;
const user = { id:'u1', aud:'authenticated', role:'authenticated', email:'demo@example.com', user_metadata:{} };
const session = { access_token: jwt, token_type:'bearer', expires_in:3600, expires_at: now+3600, refresh_token:'r', user };
const rep = { id:'r1', user_id:'u1', name:'Jordan Rivera', email:'demo@example.com', promo_code:'JORDAN', rank:'Recruit', lifetime_points:80, status:'active', created_at:'2026-07-01T00:00:00Z' };
const events = [
  { id:'e1', name:'Deep Dive Vol. 3', date:'2026-10-18', venue:'The Warehouse', city:'Philadelphia', capacity:400, tickets_sold:120, status:'active', banner_emoji:'🌊' },
  { id:'e2', name:'Low Tide Sessions', date:'2026-11-08', venue:'Pier 9', city:'Philadelphia', capacity:250, tickets_sold:30, status:'upcoming', banner_emoji:'🎧' }];
const tiers = [['Recruit',0,'🎫','#7a8799','Sell codes to level up to Rising Star'],['Rising Star',400,'🌟','#22c55e','Keep going — Hotshot unlocks $2.50/code'],['Hotshot',1000,'⚡','#a78bfa','Reach Closer for $3/code + cash bonuses'],['Closer',2500,'🔥','#00D4C8','Almost at Legend — the top of the team'],['Legend',5000,'👑','#f0b429','Top tier — $3/code + VIP guest list']].map(([name,min_points,icon,color,perk])=>({name,min_points,icon,color,perk}));
const progress = { points:80, tickets:4, sales:2, shows_joined:3, shows_sold_at:1, max_show_tickets:4, content_points:0,
  tier: tiers[0], next_tier: { ...tiers[1], points_to_go:320 }, progress_pct:20, position:1, total_reps:11, tiers,
  rules:{points_per_ticket:20, points_per_sale:0, include_content_points:false},
  badges:[
    {code:'first_sale',icon:'🎟️',name:'First Sale',description:'Sell your first ticket',threshold:1,progress:1,earned:true},
    {code:'double_digits',icon:'🔟',name:'Double Digits',description:'Sell 10 tickets',threshold:10,progress:4,earned:false},
    {code:'packed_house',icon:'🏟️',name:'Packed House',description:'Sell 5+ tickets for a single show',threshold:5,progress:4,earned:false},
    {code:'on_tour',icon:'🚐',name:'On Tour',description:'Join 3 shows',threshold:3,progress:3,earned:true},
    {code:'road_warrior',icon:'🗺️',name:'Road Warrior',description:'Make sales at 3 different shows',threshold:3,progress:1,earned:false},
    {code:'fifty_club',icon:'💯',name:'Fifty Club',description:'Sell 50 tickets',threshold:50,progress:4,earned:false}]};
const lbRow = (pos,n,c,p,t,me)=>({pos,display_name:n,promo_code:c,tier_name:'Recruit',tier_icon:'🎫',tier_color:'#7a8799',points:p,tickets:t,is_me:!!me});
const lbOverall = [lbRow(1,'Jordan R.','JORDAN',80,4,true),lbRow(2,'Sam T.','SAMT',20,1),lbRow(3,'Casey L.','CASEY',0,0),lbRow(3,'Avery P.','AVERY',0,0)];
const lbShow = [lbRow(1,'Jordan R.','JORDAN',80,4,true),lbRow(2,'Sam T.','SAMT',20,1),lbRow(3,'Casey L.','CASEY',0,0)];
const adminReps = [
  { id:'r1', name:'Jordan Rivera', email:'jordan@example.com', promo_code:'JORDAN', rank:'Recruit', lifetime_points:80, status:'active', created_at:'2026-07-01T00:00:00Z' },
  { id:'r2', name:'Sam Taylor', email:'sam@example.com', promo_code:'SAMT', rank:'Recruit', lifetime_points:20, status:'active', created_at:'2026-09-10T00:00:00Z' },
  { id:'r3', name:'Casey Lee', email:'casey@example.com', promo_code:'CASEY', rank:'Recruit', lifetime_points:0, status:'active', created_at:'2026-09-24T00:00:00Z' }];
const adminGam = [
  { rep_id:'r1', points:80, tickets:4, sales_count:2, shows_joined:3, shows_sold_at:1, tier_name:'Recruit', tier_icon:'🎫', tier_color:'#7a8799', badge_count:2, badge_icons:'🎟️🚐', overall_pos:1, excluded:false },
  { rep_id:'r2', points:20, tickets:1, sales_count:1, shows_joined:2, shows_sold_at:1, tier_name:'Recruit', tier_icon:'🎫', tier_color:'#7a8799', badge_count:1, badge_icons:'🎟️', overall_pos:2, excluded:false },
  { rep_id:'r3', points:0, tickets:0, sales_count:0, shows_joined:3, shows_sold_at:0, tier_name:'Recruit', tier_icon:'🎫', tier_color:'#7a8799', badge_count:1, badge_icons:'🚐', overall_pos:3, excluded:false }];

let adminMode = false; const rpcCalls = [];
async function mock(route) {
  const req = route.request(); const url = new URL(req.url()); const path = url.pathname;
  const single = (req.headers()['accept']||'').includes('vnd.pgrst.object');
  const json = (body, headers={}) => route.fulfill({ status:200, contentType:'application/json', headers:{'access-control-allow-origin':'*','content-range':'0-0/0',...headers}, body: JSON.stringify(body) });
  if (req.method()==='OPTIONS') return route.fulfill({status:200, headers:{'access-control-allow-origin':'*','access-control-allow-headers':'*','access-control-allow-methods':'*'}});
  if (path.startsWith('/auth/v1/user')) return json(user);
  if (path.startsWith('/auth/v1/')) return json(session);
  if (path.startsWith('/rest/v1/rpc/')) {
    const fn = path.split('/').pop(); const body = req.postDataJSON() || {}; rpcCalls.push([fn, body]);
    if (fn==='gamification_my_progress') return json(progress);
    if (fn==='gamification_leaderboard') return json(body.p_event_id ? lbShow : lbOverall);
    if (fn==='gamification_admin_reps') return json(adminGam);
    return json(null);
  }
  const t = path.replace('/rest/v1/','');
  if (t==='reps') return json(adminMode ? adminReps : (single ? rep : [rep]));
  if (t==='events') return json(events);
  if (t==='points_log') return json([{type:'sale',points:40,cash:4,description:'2 ticket(s) sold via code JORDAN',created_at:'2026-09-28T14:21:32Z'}]);
  if (t==='sales') return json([{promo_code:'JORDAN',cash_awarded:4,sold_at:'2026-09-28T14:21:32Z',reps:{name:'Jordan Rivera'},events:{name:'Deep Dive Vol. 3'}}]);
  if (t==='rep_events') return json(adminMode ? [{rep_id:'r1',event_id:'e1',events:{name:'Deep Dive Vol. 3'},codes_sold:4,points_earned:80,cash_earned:8,reps:{name:'Jordan Rivera',rank:'Recruit'}}] : [{rep_id:'r1',event_id:'e1',codes_sold:4,points_earned:80,cash_earned:8,events:{name:'Deep Dive Vol. 3',status:'active'}}]);
  return json([]);
}
(async () => {
  const browser = await chromium.launch({ executablePath:'/usr/bin/google-chrome', args:['--no-sandbox'] });
  const errors = [];
  const ctx = await browser.newContext({ viewport:{width:520,height:1100}, deviceScaleFactor:2 });
  await ctx.route(SB+'/**', mock);
  await ctx.addInitScript(([s]) => { localStorage.setItem('sb-khisgmozkufnzapmldgc-auth-token', s); }, [JSON.stringify(session)]);
  const page = await ctx.newPage();
  page.on('pageerror', e => errors.push('pageerror: '+e.message));
  page.on('console', m => { if (m.type()==='error') errors.push('console: '+m.text()); });
  await page.goto('http://localhost:8787/index.html');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 });
  await page.waitForFunction(() => document.getElementById('gam-meta').style.display === 'flex', null, { timeout: 10000 });
  await page.screenshot({ path:'/workspace/shots/portal-home.png', fullPage:true });
  await page.click('text=Rankings'); await page.waitForTimeout(500);
  const xss = await page.$$eval('#lb-list b', els => els.length);
  await page.screenshot({ path:'/workspace/shots/portal-leaderboard-overall.png', fullPage:true });
  await page.click('#lb-scope-tabs >> text=By show'); await page.waitForTimeout(500);
  await page.screenshot({ path:'/workspace/shots/portal-leaderboard-show.png', fullPage:true });
  await page.click('.nav >> text=Rewards'); await page.waitForTimeout(300);
  await page.screenshot({ path:'/workspace/shots/portal-rewards.png', fullPage:true });
  const storePts = await page.textContent('#store-pts');
  // Admin
  adminMode = true;
  await page.setViewportSize({ width:1280, height:900 });
  await page.goto('http://localhost:8787/submerged_admin.html');
  await page.waitForSelector('#screen-app.active', { timeout: 20000 });
  await page.waitForTimeout(1200);
  await page.screenshot({ path:'/workspace/shots/admin-overview.png', fullPage:true });
  await page.click('.nav >> text=Reps'); await page.waitForTimeout(400);
  await page.screenshot({ path:'/workspace/shots/admin-reps.png', fullPage:true });
  console.log(JSON.stringify({ errors, xssInjectedBoldTags: xss, storePts, rpcCalls }, null, 1));
  await browser.close();
})().catch(e => { console.error('FAIL', e); process.exit(1); });
