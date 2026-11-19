/**
 * Instagram comment giveaway picker: rules and random draw.
 * Pure functions with no network or page access, so they run in the browser and under Node tests.
 * The draw uses crypto.getRandomValues with rejection sampling, so every eligible person has exactly
 * the same chance (no modulo bias).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.IgPicker = factory();
  }
})(typeof window !== 'undefined' ? window : globalThis, function () {
  var MENTION_RE = /@([A-Za-z0-9._]{1,30})/g;

  function normUser(u) {
    return String(u == null ? '' : u).trim().replace(/^@+/, '').toLowerCase();
  }

  // "@a, b\n@c" -> ['a','b','c']
  function parseUserList(text) {
    var seen = {}; var out = [];
    String(text || '').split(/[\s,;]+/).forEach(function (t) {
      var u = normUser(t);
      if (u && !seen[u]) { seen[u] = 1; out.push(u); }
    });
    return out;
  }

  // Distinct @handles in a comment. Ignores the commenter's own handle and any handle in `ignore`.
  function countMentions(text, selfUser, ignore) {
    var skip = {};
    skip[normUser(selfUser)] = 1;
    (ignore || []).forEach(function (u) { skip[normUser(u)] = 1; });
    var seen = {}; var n = 0; var m;
    MENTION_RE.lastIndex = 0;
    while ((m = MENTION_RE.exec(String(text || ''))) !== null) {
      var h = m[1].replace(/\.+$/, '').toLowerCase();
      if (h && !skip[h] && !seen[h]) { seen[h] = 1; n++; }
    }
    return n;
  }

  function parseKeywords(text) {
    return String(text || '').split(',').map(function (s) { return s.trim().toLowerCase(); }).filter(Boolean);
  }

  function cleanRules(r) {
    r = r || {};
    var minMentions = Math.max(0, Math.min(10, parseInt(r.minMentions, 10) || 0));
    var winners = Math.max(1, Math.min(50, parseInt(r.winners, 10) || 1));
    var alternates = Math.max(0, Math.min(20, parseInt(r.alternates, 10) || 0));
    return {
      onePerUser: r.onePerUser !== false,
      minMentions: minMentions,
      keyword: String(r.keyword || '').trim().slice(0, 200),
      excludeUsers: parseUserList(Array.isArray(r.excludeUsers) ? r.excludeUsers.join(' ') : r.excludeUsers),
      ignoreMentions: parseUserList(Array.isArray(r.ignoreMentions) ? r.ignoreMentions.join(' ') : r.ignoreMentions),
      winners: winners,
      alternates: alternates
    };
  }

  // comments: [{id, username, text, timestamp, ...}]
  // Returns { entries, eligibleUsers, totalComments, totalUsers, rejected: {excluded, keyword, mentions} }
  function applyRules(comments, rules) {
    var r = cleanRules(rules);
    var kws = parseKeywords(r.keyword);
    var excluded = {}; r.excludeUsers.forEach(function (u) { excluded[u] = 1; });
    var all = (comments || []).slice().sort(function (a, b) {
      return String(a.timestamp || '').localeCompare(String(b.timestamp || '')); // oldest first
    });
    var users = {}; all.forEach(function (c) { users[normUser(c.username)] = 1; });
    var rejected = { excluded: 0, keyword: 0, mentions: 0 };
    var entries = []; var perUser = {};
    all.forEach(function (c) {
      var u = normUser(c.username);
      if (!u) return;
      if (excluded[u]) { rejected.excluded++; return; }
      var text = String(c.text || '');
      if (kws.length) {
        var low = text.toLowerCase();
        if (!kws.some(function (k) { return low.indexOf(k) !== -1; })) { rejected.keyword++; return; }
      }
      if (r.minMentions > 0 && countMentions(text, u, r.ignoreMentions) < r.minMentions) { rejected.mentions++; return; }
      if (r.onePerUser && perUser[u]) return; // keep the person's earliest qualifying comment
      perUser[u] = 1;
      entries.push(c);
    });
    var eligibleUsers = {}; entries.forEach(function (c) { eligibleUsers[normUser(c.username)] = 1; });
    return {
      entries: entries,
      eligibleUsers: Object.keys(eligibleUsers).length,
      totalComments: all.length,
      totalUsers: Object.keys(users).length,
      rejected: rejected
    };
  }

  // Unbiased integer in [0, max) from crypto.getRandomValues (rejection sampling).
  function randomInt(max, cryptoObj) {
    var c = cryptoObj || (typeof crypto !== 'undefined' ? crypto : null);
    if (!c || !c.getRandomValues) throw new Error('No secure random source available');
    if (!(max > 0) || max > 4294967296) throw new Error('Bad range');
    var buf = new Uint32Array(1);
    var limit = Math.floor(4294967296 / max) * max;
    do { c.getRandomValues(buf); } while (buf[0] >= limit);
    return buf[0] % max;
  }

  // Picks winners + alternates. A person can only win once even when onePerUser is off.
  // Returns [{ username, comment_id, text, timestamp, alternate }]
  function pickWinners(entries, rules, randInt) {
    var r = cleanRules(rules);
    var rnd = randInt || randomInt;
    var pool = (entries || []).slice();
    var want = r.winners + r.alternates;
    var picked = []; var used = {};
    while (picked.length < want && pool.length) {
      var i = rnd(pool.length);
      var c = pool.splice(i, 1)[0];
      var u = normUser(c.username);
      if (used[u]) continue;
      used[u] = 1;
      picked.push({
        username: c.username,
        comment_id: c.id,
        text: String(c.text || '').slice(0, 300),
        timestamp: c.timestamp || null,
        alternate: picked.length >= r.winners
      });
    }
    return picked;
  }

  // Clearly fake data for the labeled demo mode. Nothing here is a real account.
  function sampleComments(selfUser) {
    var out = []; var t0 = Date.UTC(2026, 10, 12, 18, 0, 0);
    function add(user, text, minutes) {
      out.push({ id: 'sample_' + (out.length + 1), username: user, user_id: null, text: text,
        timestamp: new Date(t0 + minutes * 60000).toISOString().replace('.000Z', '+0000'),
        like_count: 0, is_reply: false, parent_id: null });
    }
    for (var i = 1; i <= 40; i++) {
      var n = ('0' + i).slice(-2);
      var kind = i % 5;
      var text = kind === 0 ? 'count me in! @sample_friend_' + n + ' @sample_pal_' + n
        : kind === 1 ? 'ENTER me please @sample_friend_' + n
        : kind === 2 ? 'so excited for this one'
        : kind === 3 ? 'enter @sample_friend_' + n + ' @sample_pal_' + n + ' @sample_crew_' + n
        : 'fire lineup';
      add('sample_user_' + n, text, i * 3);
    }
    for (var j = 1; j <= 8; j++) add('sample_user_' + ('0' + j).slice(-2), 'second comment, still in @sample_friend_x', 140 + j);
    add(selfUser || 'sample_host_account', 'Winner announced Friday @sample_user_01', 200);
    add('sample_admin_helper', 'enter @sample_friend_99 @sample_pal_99', 201);
    return out;
  }

  return {
    normUser: normUser,
    parseUserList: parseUserList,
    countMentions: countMentions,
    cleanRules: cleanRules,
    applyRules: applyRules,
    randomInt: randomInt,
    pickWinners: pickWinners,
    sampleComments: sampleComments
  };
});
