// Shared helpers for the Instagram comment picker Edge Functions.
// Official docs this follows (Instagram Platform, Meta):
//   Business Login for Instagram   /docs/instagram-platform/instagram-api-with-instagram-login/business-login
//   IG Media comments edge         /docs/instagram-platform/instagram-graph-api/reference/ig-media/comments
//   IG Comment fields              /docs/instagram-platform/instagram-graph-api/reference/ig-comment
//   IG User media edge             /docs/instagram-platform/instagram-graph-api/reference/ig-user/media
//   Refresh access token           /docs/instagram-platform/reference/refresh_access_token
// The Instagram token never leaves the server. Nothing here logs a token or a URL that contains one.
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
export { COMMENT_FIELDS, fetchAllComments, findMediaByShortcode, REPLY_FIELDS } from './ig_logic.ts';

export const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
export const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
export const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
export const IG_APP_ID = Deno.env.get('IG_APP_ID') || '';
export const IG_APP_SECRET = Deno.env.get('IG_APP_SECRET') || '';
export const GRAPH_VERSION = Deno.env.get('IG_GRAPH_VERSION') || 'v27.0';
export const REDIRECT_URI =
  Deno.env.get('IG_REDIRECT_URI') || `${SUPABASE_URL}/functions/v1/ig-oauth-callback`;

export const HOSTS = ['graph.instagram.com', 'graph.facebook.com'] as const;
export type IgHost = typeof HOSTS[number];

const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;
export function cleanTenant(v: unknown): string | null {
  const s = String(v ?? '').trim().toLowerCase();
  return SLUG_RE.test(s) ? s : null;
}

// Browser origins allowed to call the functions and to be returned to after connecting.
const EXTRA_ORIGINS = (Deno.env.get('IG_ALLOWED_ORIGINS') || '')
  .split(',').map((s) => s.trim()).filter(Boolean);
export function originAllowed(origin: string | null): boolean {
  if (!origin) return false;
  if (EXTRA_ORIGINS.includes(origin)) return true;
  if (origin === 'https://woosahcrew.com' || origin === 'https://www.woosahcrew.com') return true;
  // Workers Builds branch previews of this repo.
  return /^https:\/\/[a-z0-9-]+-submerged-crew\.shaun-6ad\.workers\.dev$/.test(origin) ||
    origin === 'https://submerged-crew.shaun-6ad.workers.dev';
}
export function corsHeaders(origin: string | null): Record<string, string> {
  const h: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
  if (originAllowed(origin)) h['Access-Control-Allow-Origin'] = origin!;
  return h;
}
export function json(data: unknown, status: number, origin: string | null = null) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders(origin) },
  });
}

export function serviceClient(): SupabaseClient {
  return createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
}

// Verifies the caller's Supabase JWT and that they are an admin of this tenant,
// using the same public.is_tenant_admin() check the admin page uses.
export async function requireTenantAdmin(
  req: Request, tenant: string,
): Promise<{ userId: string } | null> {
  const auth = req.headers.get('Authorization') || '';
  if (!/^Bearer\s+\S+/i.test(auth)) return null;
  const userSb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data: u, error: uErr } = await userSb.auth.getUser();
  if (uErr || !u?.user?.id) return null;
  const { data: ok, error } = await userSb.rpc('is_tenant_admin', { p_tenant: tenant });
  if (error || ok !== true) return null;
  return { userId: u.user.id };
}

// ───────────── signed OAuth state (CSRF + tenant + return origin) ─────────────
function b64url(bytes: Uint8Array): string {
  let s = '';
  bytes.forEach((b) => (s += String.fromCharCode(b)));
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function unb64url(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
async function hmacKey(): Promise<CryptoKey> {
  if (!IG_APP_SECRET) throw new Error('IG_APP_SECRET is not set');
  return crypto.subtle.importKey(
    'raw', new TextEncoder().encode('woosah-ig-state:' + IG_APP_SECRET),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'],
  );
}
export async function signState(p: { t: string; u: string; o: string }): Promise<string> {
  const body = b64url(new TextEncoder().encode(JSON.stringify({ ...p, e: Date.now() + 10 * 60 * 1000, n: crypto.randomUUID() })));
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', await hmacKey(), new TextEncoder().encode(body)));
  return body + '.' + b64url(sig);
}
export async function verifyState(state: string): Promise<{ t: string; u: string; o: string } | null> {
  const [body, sig] = String(state || '').split('.');
  if (!body || !sig) return null;
  try {
    const ok = await crypto.subtle.verify('HMAC', await hmacKey(), unb64url(sig), new TextEncoder().encode(body));
    if (!ok) return null;
    const p = JSON.parse(new TextDecoder().decode(unb64url(body)));
    if (!p || typeof p.e !== 'number' || p.e < Date.now()) return null;
    if (!cleanTenant(p.t) || typeof p.u !== 'string' || !originAllowed(p.o)) return null;
    return { t: p.t, u: p.u, o: p.o };
  } catch (_) {
    return null;
  }
}

// ───────────── Graph API ─────────────
export class GraphError extends Error {
  status: number; code: number | null; kind: string;
  constructor(status: number, code: number | null, message: string) {
    super(message);
    this.status = status; this.code = code;
    // 190 = invalid or expired token, 102 = session invalid, 10/200-299 = permission problems.
    this.kind = code === 190 || code === 102 ? 'token_expired'
      : code === 4 || code === 17 || code === 32 || code === 613 || status === 429 ? 'rate_limited'
      : code === 10 || (code !== null && code >= 200 && code <= 299) ? 'permission'
      : 'graph_error';
  }
}

// Never put the URL or token in an error message.
export async function graphGet(host: IgHost, path: string, token: string, params: Record<string, string> = {}): Promise<any> {
  const u = new URL(`https://${host}/${GRAPH_VERSION}/${path.replace(/^\/+/, '')}`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  u.searchParams.set('access_token', token);
  let res: Response;
  try {
    res = await fetch(u.toString(), { headers: { Accept: 'application/json' } });
  } catch (_) {
    throw new GraphError(502, null, 'Could not reach Instagram');
  }
  let body: any = null;
  try { body = await res.json(); } catch (_) { /* leave null */ }
  if (!res.ok || body?.error) {
    const e = body?.error || {};
    throw new GraphError(res.status, typeof e.code === 'number' ? e.code : null,
      String(e.message || 'Instagram returned an error').replace(/access_token=[^&\s"]+/gi, 'access_token=[hidden]'));
  }
  return body;
}

export { shortcodeFromUrl } from './ig_logic.ts';
