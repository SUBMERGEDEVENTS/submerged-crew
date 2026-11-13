# AI Coordinator (parked)

Turned off on 2026-11-13 for every team, including SUB:MERGED. The old version
called the Anthropic API straight from the browser with no key, so it never
worked and would have exposed a key if one were added.

To bring it back, route requests through a server-side proxy (for example a
Supabase Edge Function that checks `is_tenant_admin(slug)` and holds the model
key as a secret), then restore the nav button, the markup and the script below
in `submerged_admin.html`, pointing `fetch` at the proxy instead.

Nav button (was the last item in `.nav`):

```html
<button class="nav-btn" onclick="showView('ai')">AI Coord</button>
```

Also add `'ai'` back to the list in `showView()`.

## Markup

```html
      <!-- ── AI COORDINATOR ── -->
      <div id="view-ai" class="view">
        <div class="card" style="margin-bottom:8px;">
          <div class="card-title">AI street team coordinator</div>
          <div class="section-sub">Ask anything: payout reports, rep analysis, outreach drafts, social copy</div>
        </div>
        <div class="ai-wrap">
          <div class="ai-history" id="ai-history">
            <div class="ai-msg">
              <div class="ai-av"><svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6" stroke="#0d1b2e" stroke-width="1.8"/><path d="M5 8h6M8 5v6" stroke="#0d1b2e" stroke-width="1.8" stroke-linecap="round"/></svg></div>
              <div class="ai-bubble">Admin mode activated. I have full context on your reps, events, and sales. What do you need: payout report, rep analysis, outreach copy, or something else?</div>
            </div>
          </div>
          <div class="ai-footer">
            <input class="ai-input" id="ai-input" placeholder="e.g. Who are my top 5 reps? Draft a message to idle reps..." onkeydown="if(event.key==='Enter')sendAI()" />
            <button class="ai-send" id="ai-send" onclick="sendAI()">Send</button>
          </div>
        </div>
        <div class="card">
          <div class="card-title">Quick prompts</div>
          <div style="display:flex;flex-direction:column;gap:6px;">
            <button class="act-btn act-cyan" style="text-align:left;padding:10px 14px;border-radius:8px;font-size:13px;text-transform:none;letter-spacing:0;" onclick="fillAI('Give me a full payout report for all reps on the current active event')">Run payout report for active event</button>
            <button class="act-btn act-cyan" style="text-align:left;padding:10px 14px;border-radius:8px;font-size:13px;text-transform:none;letter-spacing:0;" onclick="fillAI('Which reps have not sold any codes or posted any content in the last 7 days? Draft a motivational text message to re-engage them.')">Draft outreach to idle reps</button>
            <button class="act-btn act-cyan" style="text-align:left;padding:10px 14px;border-radius:8px;font-size:13px;text-transform:none;letter-spacing:0;" onclick="fillAI('Write 5 Instagram captions for Summer Rave at Musica in Akron OH on July 25th that street team reps can copy and post right now')">Generate social copy pack</button>
            <button class="act-btn act-cyan" style="text-align:left;padding:10px 14px;border-radius:8px;font-size:13px;text-transform:none;letter-spacing:0;" onclick="fillAI('Analyze my street team performance and tell me who my strongest reps are, who needs motivation, and what I should do this week to maximize ticket sales')">Street team performance analysis</button>
          </div>
        </div>
      </div>

```

## Script (browser call removed from the live page)

```js
// ── AI COORDINATOR ──
async function sendAI() {
  const input = document.getElementById('ai-input');
  const btn = document.getElementById('ai-send');
  const msg = input.value.trim();
  if (!msg) return;
  const history = document.getElementById('ai-history');
  history.innerHTML += `<div class="ai-msg user-row"><div class="user-bubble">${esc(msg)}</div></div>`;
  input.value = ''; btn.disabled = true;
  const tid = 't' + Date.now();
  history.innerHTML += `<div class="ai-msg" id="${tid}"><div class="ai-av"><svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6" stroke="#0d1b2e" stroke-width="1.8"/><path d="M5 8h6M8 5v6" stroke="#0d1b2e" stroke-width="1.8" stroke-linecap="round"/></svg></div><div class="ai-bubble"><div class="typing"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div></div></div>`;
  history.scrollTop = history.scrollHeight;

  const activeEvent = allEvents.find(e => e.status === 'active');
  const repSummary = allReps.slice(0, 10).map(r => `${r.name} (${r.rank}, ${r.lifetime_points}pts, code:${r.promo_code})`).join('; ');

  try {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'claude-sonnet-4-20250514',
        max_tokens: 1000,
        system: `You are the AI coordinator for the ${(window.AppTenant && AppTenant.name) || 'Woosah'} street team program. Admin context:

ACTIVE EVENT: ${activeEvent ? `${activeEvent.name} at ${activeEvent.venue}, ${activeEvent.city} on ${activeEvent.date}. ${activeEvent.tickets_sold}/${activeEvent.capacity} tickets sold.` : 'No active event'}
TOTAL REPS: ${allReps.length}
TOP REPS: ${repSummary}

POINT SYSTEM: 20pts per code, 50pts flyer share, 150pts original content, milestone bonuses at 10/25/50 codes.
PAY RATES: Recruit/Rising Star $2/code, Hotshot $2.50/code, Closer/Legend $3/code.

You help with: payout reports, rep performance analysis, motivational outreach drafts, social media copy, event strategy. Be direct, energetic, nightlife-appropriate.`,
        messages: [{ role: 'user', content: msg }]
      })
    });
    const data = await res.json();
    const reply = data.content?.[0]?.text || 'Error. Try again.';
    document.getElementById(tid).remove();
    history.innerHTML += `<div class="ai-msg"><div class="ai-av"><svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6" stroke="#0d1b2e" stroke-width="1.8"/><path d="M5 8h6M8 5v6" stroke="#0d1b2e" stroke-width="1.8" stroke-linecap="round"/></svg></div><div class="ai-bubble" style="white-space:pre-wrap;">${reply}</div></div>`;
  } catch (e) {
    document.getElementById(tid).remove();
    history.innerHTML += `<div class="ai-msg"><div class="ai-av"><svg width="14" height="14" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6" stroke="#0d1b2e" stroke-width="1.8"/><path d="M5 8h6M8 5v6" stroke="#0d1b2e" stroke-width="1.8" stroke-linecap="round"/></svg></div><div class="ai-bubble">Connection error. Try again.</div></div>`;
  }
  btn.disabled = false;
  history.scrollTop = history.scrollHeight;
}

function fillAI(txt) {
  document.getElementById('ai-input').value = txt;
  document.getElementById('ai-input').focus();
}

```
