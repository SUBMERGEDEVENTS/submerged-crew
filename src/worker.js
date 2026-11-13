/**
 * Path-based tenant routing and host canonicalization.
 * Static files are served through the ASSETS binding after the Worker runs
 * (assets.run_worker_first). See:
 * https://developers.cloudflare.com/workers/static-assets/routing/worker-script/
 * https://developers.cloudflare.com/workers/static-assets/binding/
 */

const CANONICAL_HOST = 'woosahcrew.com';
const WWW_HOSTS = new Set(['www.woosahcrew.com']);
const LEGACY_HOSTS = new Set(['submerged-crew.shaun-6ad.workers.dev']);

const RESERVED_SLUGS = new Set([
  'js',
  'tenants',
  'src',
  'docs',
  'supabase',
  'assets',
  'admin',
  'favicon.ico',
  'favicon.svg',
  'terms.html',
  'terms',
  'index.html',
  'landing.html',
  'not-found.html',
  'submerged_admin.html',
  'test.html',
  'robots.txt',
  'wrangler.jsonc',
]);

function isLocalHost(hostname) {
  return (
    hostname === 'localhost' ||
    hostname === '127.0.0.1' ||
    hostname === '::1' ||
    hostname.endsWith('.localhost')
  );
}

function isValidSlug(slug) {
  return /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/.test(slug);
}

function normalizePath(pathname) {
  if (!pathname) return '/';
  var path = pathname;
  if (path.length > 1 && path.endsWith('/')) path = path.replace(/\/+$/, '');
  if (!path) return '/';
  return path;
}

function isStaticAssetPath(pathname) {
  var p = pathname.toLowerCase();
  if (p.startsWith('/js/') || p.startsWith('/tenants/') || p.startsWith('/assets/')) return true;
  if (
    p === '/favicon.ico' ||
    p === '/favicon.svg' ||
    p === '/terms.html' ||
    p === '/terms' ||
    p === '/landing.html' ||
    p === '/not-found.html' ||
    p === '/test.html'
  ) {
    return true;
  }
  return false;
}

function redirectTo(dest) {
  return new Response(null, {
    status: 301,
    headers: { Location: dest, 'Cache-Control': 'no-store' },
  });
}

function searchWithoutTenant(searchParams) {
  var next = new URLSearchParams(searchParams);
  next.delete('tenant');
  var s = next.toString();
  return s ? '?' + s : '';
}

function planDestination(url) {
  var host = url.hostname.toLowerCase();
  var path = normalizePath(url.pathname);
  var tenantParam = (url.searchParams.get('tenant') || '').trim().toLowerCase();
  if (tenantParam && !isValidSlug(tenantParam)) tenantParam = '';

  if (path === '/submerged_admin.html' || path === '/submerged_admin') {
    path = '/' + (tenantParam || 'submerged') + '/admin';
    tenantParam = '';
  } else if (path === '/index.html') {
    path = tenantParam ? '/' + tenantParam : '/';
    tenantParam = '';
  } else if (path === '/' && tenantParam) {
    path = '/' + tenantParam;
    tenantParam = '';
  }

  path = normalizePath(path);

  var destHost = host;
  var destOrigin = url.origin;
  var isLegacy = LEGACY_HOSTS.has(host);
  var isWww = WWW_HOSTS.has(host);

  if (isLegacy || isWww) {
    destHost = CANONICAL_HOST;
    destOrigin = 'https://' + CANONICAL_HOST;
  }

  if (isLegacy && path === '/') {
    path = '/submerged';
  }

  var search = tenantParam
    ? url.search
    : searchWithoutTenant(url.searchParams);
  // If we consumed tenantParam above, drop it; if it is still set on a non-root
  // tenant path, also drop it so /submerged?tenant=acme-demo stays on /submerged.
  if (url.searchParams.has('tenant')) {
    search = searchWithoutTenant(url.searchParams);
  }

  return {
    destOrigin: destOrigin,
    destHost: destHost,
    path: path,
    search: search,
    changed:
      destHost !== host ||
      path !== url.pathname ||
      search !== (url.search || ''),
  };
}

async function tenantExists(env, slug, request) {
  if (!isValidSlug(slug) || RESERVED_SLUGS.has(slug)) return false;
  var url = new URL(request.url);
  url.pathname = '/tenants/' + encodeURIComponent(slug) + '.json';
  url.search = '';
  var res = await env.ASSETS.fetch(new Request(url, { method: 'GET' }));
  return res.ok;
}

async function fetchAsset(env, request, assetPath) {
  var url = new URL(request.url);
  url.pathname = assetPath;
  url.search = '';
  return env.ASSETS.fetch(new Request(url, request));
}

async function notFound(env, request) {
  var res = await fetchAsset(env, request, '/not-found.html');
  return new Response(res.body, { status: 404, headers: res.headers });
}

export default {
  async fetch(request, env) {
    var url = new URL(request.url);
    var plan = planDestination(url);

    if (plan.changed) {
      return redirectTo(plan.destOrigin + plan.path + plan.search);
    }

    var path = plan.path;

    if (isStaticAssetPath(path)) {
      if (path === '/terms') {
        return fetchAsset(env, request, '/terms.html');
      }
      return env.ASSETS.fetch(request);
    }

    if (path === '/') {
      return fetchAsset(env, request, '/landing.html');
    }

    var parts = path.split('/').filter(Boolean);
    if (parts.length === 1 || (parts.length === 2 && parts[1] === 'admin')) {
      var slug = parts[0].toLowerCase();
      if (RESERVED_SLUGS.has(slug) || !isValidSlug(slug)) {
        return notFound(env, request);
      }
      if (!(await tenantExists(env, slug, request))) {
        return notFound(env, request);
      }
      var asset = parts[1] === 'admin' ? '/submerged_admin.html' : '/index.html';
      return fetchAsset(env, request, asset);
    }

    return notFound(env, request);
  },
};
