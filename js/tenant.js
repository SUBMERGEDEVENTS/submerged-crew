/**
 * Multi-tenant bootstrap: /{slug} (or ?tenant= fallback) -> /tenants/{slug}.json -> window.AppTenant
 */
(function (global) {
  var FALLBACK = {
    slug: null,
    name: 'Woosah',
    brand: { cyan: '#00D4C8', navy: '#0d1b2e', navy2: '#0a1525' },
    supabaseUrl: 'https://khisgmozkufnzapmldgc.supabase.co',
    supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtoaXNnbW96a3VmbnphcG1sZGdjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2MDY3NDIsImV4cCI6MjA5MTE4Mjc0Mn0.GUweJMnLLDh2bwE0NADb55GM7mTGFCTO8bNgysD5y9c',
    featureFlags: {
      socialLogin: true,
      musicMix: false,
      adminAi: false,
      leaderboard: true
    },
    copy: {
      tagline: 'Street Team Portal',
      adminTagline: 'Admin Dashboard',
      consentNote: 'By continuing you agree to let this program read your music taste data to personalize your experience. We never post on your behalf.'
    }
  };

  var RESERVED_SLUGS = {
    js: 1,
    tenants: 1,
    src: 1,
    docs: 1,
    supabase: 1,
    admin: 1,
    'favicon.ico': 1,
    'favicon.svg': 1,
    'terms.html': 1,
    terms: 1,
    'index.html': 1,
    'landing.html': 1,
    'not-found.html': 1,
    'submerged_admin.html': 1,
    'test.html': 1
  };

  function normalizePath(pathname) {
    var path = pathname || '/';
    if (path.length > 1) path = path.replace(/\/+$/, '');
    return path || '/';
  }

  function resolveTenantSlug(loc) {
    loc = loc || global.location;
    try {
      var path = normalizePath(loc.pathname);
      var parts = path.split('/').filter(Boolean);
      if (parts[0] && !RESERVED_SLUGS[parts[0].toLowerCase()]) {
        return parts[0].toLowerCase();
      }
      var q = new URLSearchParams(loc.search).get('tenant');
      if (q) return q.toLowerCase();
    } catch (_) { /* ignore */ }
    return null;
  }

  function tenantRedirectUrl(loc) {
    loc = loc || global.location;
    var slug = resolveTenantSlug(loc);
    if (!slug) return loc.origin + '/';
    var path = normalizePath(loc.pathname);
    var suffix = /\/admin$/.test(path) ? '/admin' : '';
    return loc.origin + '/' + slug + suffix;
  }

  global.AppTenant = FALLBACK;
  global.__tenantLoaded = false;
  global.resolveTenantSlug = resolveTenantSlug;
  global.tenantRedirectUrl = tenantRedirectUrl;

  function getSlug() {
    return resolveTenantSlug();
  }

  function formatBrandedName(name) {
    if (!name) return '';
    if (name.indexOf(':') !== -1) {
      var parts = name.split(':');
      return parts[0] + '<span>:</span>' + parts.slice(1).join(':');
    }
    return name;
  }

  function hexToRgb(hex) {
    var h = (hex || '').replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    if (h.length !== 6) return null;
    return {
      r: parseInt(h.slice(0, 2), 16),
      g: parseInt(h.slice(2, 4), 16),
      b: parseInt(h.slice(4, 6), 16)
    };
  }

  function applyBrand(tenant) {
    var root = document.documentElement;
    var brand = tenant.brand || {};
    if (brand.cyan) {
      root.style.setProperty('--cyan', brand.cyan);
      var rgb = hexToRgb(brand.cyan);
      if (rgb) {
        root.style.setProperty('--cyan-dim', 'rgba(' + rgb.r + ',' + rgb.g + ',' + rgb.b + ',0.1)');
        root.style.setProperty('--cyan-border', 'rgba(' + rgb.r + ',' + rgb.g + ',' + rgb.b + ',0.28)');
      }
    }
    if (brand.navy) root.style.setProperty('--navy', brand.navy);
    if (brand.navy2) root.style.setProperty('--navy2', brand.navy2);

    var isAdmin = /admin/i.test(document.title) || /submerged_admin/i.test(location.pathname) || /\/admin$/.test(normalizePath(location.pathname));
    document.title = isAdmin
      ? ('Admin · ' + tenant.name)
      : ('Street Team Portal · ' + tenant.name);

    document.querySelectorAll('[data-tenant-name]').forEach(function (el) {
      el.innerHTML = formatBrandedName(tenant.name);
    });
    document.querySelectorAll('[data-tenant-tagline]').forEach(function (el) {
      el.textContent = (tenant.copy && (isAdmin ? tenant.copy.adminTagline : tenant.copy.tagline)) || el.textContent;
    });
    document.querySelectorAll('[data-tenant-consent]').forEach(function (el) {
      if (tenant.copy && tenant.copy.consentNote) el.textContent = tenant.copy.consentNote;
    });
    document.querySelectorAll('[data-tenant-mix]').forEach(function (el) {
      el.textContent = tenant.name + ' Weekly Mix';
    });
    document.querySelectorAll('[data-tenant-mix-vol]').forEach(function (el) {
      var vol = el.getAttribute('data-tenant-mix-vol') || '12';
      el.textContent = tenant.name + ' Vol. ' + vol;
    });
  }

  function finish(tenant) {
    global.AppTenant = tenant;
    global.__tenantLoaded = true;
    if (tenant && tenant.slug) {
      try { global.localStorage.setItem('woosah_tenant', tenant.slug); } catch (_) { /* ignore */ }
    }
    try { applyBrand(tenant); } catch (e) { console.warn('tenant brand apply failed', e); }
    document.dispatchEvent(new CustomEvent('tenantready', { detail: tenant }));
  }

  async function load() {
    var slug = getSlug();
    var tenant = Object.assign({}, FALLBACK, slug ? { slug: slug } : {});
    if (!slug) {
      finish(tenant);
      return;
    }
    try {
      var res = await fetch('/tenants/' + encodeURIComponent(slug) + '.json', { cache: 'no-store' });
      if (res.ok) {
        var data = await res.json();
        tenant = Object.assign({}, FALLBACK, data, {
          slug: data.slug || slug,
          brand: Object.assign({}, FALLBACK.brand, data.brand || {}),
          featureFlags: Object.assign({}, FALLBACK.featureFlags, data.featureFlags || {}),
          copy: Object.assign({}, FALLBACK.copy, data.copy || {})
        });
      } else {
        console.warn('tenant config not found for', slug, '- using product defaults');
      }
    } catch (e) {
      console.warn('tenant load failed, using defaults', e);
    }
    finish(tenant);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', load);
  } else {
    load();
  }
})(window);
