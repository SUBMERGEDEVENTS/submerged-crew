// Pure Instagram comment logic. No Deno or network imports, so it runs under Node for tests
// (docs/ig-comment-picker-check.js) and inside the Edge Functions unchanged.
//
// Facts used here come from Meta's Instagram Platform reference:
//  - GET /<IG_MEDIA_ID>/comments returns top-level comments, newest first, at most 50 per request,
//    and replies only when the `replies` field is expanded. Default fields are id, text, timestamp,
//    so `username` and `from` must be requested.
//  - Paging is cursor based: response.paging.cursors.after, and response.paging.next when more remain.
//  - IG Media has `shortcode` and `permalink`. GET /<IG_USER_ID>/media lists the most recent media
//    (up to 10K), so a post is found by listing media and matching the shortcode.
//  - GET /<IG_COMMENT_ID>/replies lists replies to one comment.

export const COMMENT_FIELDS = 'id,text,timestamp,username,like_count,from{id,username}';
export const REPLY_FIELDS = 'id,text,timestamp,username,like_count,from{id,username}';

export type Getter = (path: string, params?: Record<string, string>) => Promise<any>;

export type Comment = {
  id: string;
  username: string;
  user_id: string | null;
  text: string;
  timestamp: string | null;
  like_count: number | null;
  is_reply: boolean;
  parent_id: string | null;
};

export function shortcodeFromUrl(raw: string): string | null {
  let u: URL;
  try { u = new URL(String(raw || '').trim()); } catch (_) { return null; }
  if (!/^(www\.)?instagram\.com$/i.test(u.hostname) && !/^instagr\.am$/i.test(u.hostname)) return null;
  // /p/<code>/  /reel/<code>/  /reels/<code>/  /tv/<code>/  and the /<username>/p/<code>/ form
  const m = u.pathname.match(/^\/(?:[A-Za-z0-9._]+\/)?(?:p|reel|reels|tv)\/([A-Za-z0-9_-]+)\/?$/);
  return m ? m[1] : null;
}

export function normalizeComment(c: any, parentId: string | null): Comment | null {
  if (!c || !c.id) return null;
  const username = String(c.username || c.from?.username || '').replace(/^@/, '').trim();
  if (!username) return null;
  return {
    id: String(c.id),
    username,
    user_id: c.from?.id ? String(c.from.id) : null,
    text: String(c.text ?? ''),
    timestamp: c.timestamp ? String(c.timestamp) : null,
    like_count: typeof c.like_count === 'number' ? c.like_count : null,
    is_reply: parentId !== null,
    parent_id: parentId,
  };
}

export type Media = { id: string; shortcode: string; permalink: string | null; timestamp: string | null };

// Lists the account's media (newest first) until the shortcode matches.
export async function findMediaByShortcode(
  get: Getter, owner: string, shortcode: string, maxPages = 60,
): Promise<{ media: Media | null; pagesScanned: number }> {
  let after: string | null = null;
  for (let page = 1; page <= maxPages; page++) {
    const params: Record<string, string> = { fields: 'id,shortcode,permalink,timestamp', limit: '100' };
    if (after) params.after = after;
    const r = await get(`${owner}/media`, params);
    for (const m of r?.data || []) {
      if (m?.shortcode === shortcode) {
        return { media: { id: String(m.id), shortcode, permalink: m.permalink || null, timestamp: m.timestamp || null }, pagesScanned: page };
      }
    }
    after = r?.paging?.next ? (r?.paging?.cursors?.after || null) : null;
    if (!after) return { media: null, pagesScanned: page };
  }
  return { media: null, pagesScanned: maxPages };
}

// Gets every comment on a media object, following paging cursors.
export async function fetchAllComments(
  get: Getter, mediaId: string,
  opts: { includeReplies?: boolean; maxComments?: number; maxPages?: number } = {},
): Promise<{ comments: Comment[]; truncated: boolean; pages: number }> {
  const includeReplies = !!opts.includeReplies;
  const maxComments = opts.maxComments ?? 10000;
  const maxPages = opts.maxPages ?? 400;
  const out: Comment[] = [];
  const seen = new Set<string>();
  let truncated = false;
  const push = (c: Comment | null) => {
    if (!c || seen.has(c.id)) return;
    if (out.length >= maxComments) { truncated = true; return; }
    seen.add(c.id); out.push(c);
  };

  let fields = COMMENT_FIELDS + (includeReplies ? `,replies.limit(50){${REPLY_FIELDS}}` : '');
  let after: string | null = null;
  let pages = 0;
  while (pages < maxPages) {
    const params: Record<string, string> = { fields, limit: '50' };
    if (after) params.after = after;
    let r: any;
    try {
      r = await get(`${mediaId}/comments`, params);
    } catch (e: any) {
      // If `from` is refused for this token, retry once with the plain username field only.
      if (pages === 0 && e?.kind === 'graph_error' && /from/i.test(String(e?.message || '')) && fields.includes('from{')) {
        fields = fields.replace(/,from\{id,username\}/g, '');
        continue;
      }
      throw e;
    }
    pages++;
    for (const c of r?.data || []) {
      push(normalizeComment(c, null));
      if (includeReplies) {
        for (const rep of c?.replies?.data || []) push(normalizeComment(rep, String(c.id)));
        // More replies than fit in the expansion: page the replies edge.
        let rAfter: string | null = c?.replies?.paging?.next ? (c.replies.paging?.cursors?.after || null) : null;
        let guard = 0;
        while (rAfter && guard++ < 40) {
          const rr = await get(`${c.id}/replies`, { fields: REPLY_FIELDS, limit: '50', after: rAfter });
          for (const rep of rr?.data || []) push(normalizeComment(rep, String(c.id)));
          rAfter = rr?.paging?.next ? (rr?.paging?.cursors?.after || null) : null;
        }
      }
    }
    after = r?.paging?.next ? (r?.paging?.cursors?.after || null) : null;
    if (!after) break;
  }
  if (after) truncated = true;
  return { comments: out, truncated, pages };
}
