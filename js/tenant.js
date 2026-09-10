/**
 * Multi-tenant bootstrap: ?tenant=slug → tenants/{slug}.json → window.AppTenant
 */
(function (global) {
  var FALLBACK = {
    slug: 'submerged',
    name: 'SUB:MERGED',
    brand: { cyan: '#00D4C8', navy: '#0d1b2e', navy2: '#0a1525' },
    supabaseUrl: 'https://khisgmozkufnzapmldgc.supabase.co',
    supabaseAnonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtoaXNnbW96a3VmbnphcG1sZGdjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzU2MDY3NDIsImV4cCI6MjA5MTE4Mjc0Mn0.GUweJMnLLDh2bwE0NADb55GM7mTGFCTO8bNgysD5y9c',
    featureFlags: {
      socialLogin: true,
      musicMix: true,
      adminAi: true,
      leaderboard: true
    },
    copy: {
      tagline: 'Street Team Portal',
      adminTagline: 'Admin Dashboard',
      consentNote: 'By continuing you agree to let SUB:MERGED read your music taste data to personalize your experience. We never post on your behalf.'
    }
  };

  global.AppTenant = FALLBACK;
  global.__tenantLoaded = false;

  function getSlug() {
    try {
      return new URLSearchParams(global.location.search).get('tenant') || 'submerged';
    } catch (_) {
      return 'submerged';
    }
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

    var isAdmin = /admin/i.test(document.title) || /submerged_admin/i.test(location.pathname);
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
  }

  function finish(tenant) {
    global.AppTenant = tenant;
    global.__tenantLoaded = true;
    try { applyBrand(tenant); } catch (e) { console.warn('tenant brand apply failed', e); }
    document.dispatchEvent(new CustomEvent('tenantready', { detail: tenant }));
  }

  async function load() {
    var slug = getSlug();
    var tenant = FALLBACK;
    if (slug && slug !== 'submerged') {
      try {
        var res = await fetch('tenants/' + encodeURIComponent(slug) + '.json', { cache: 'no-store' });
        if (res.ok) {
          var data = await res.json();
          tenant = Object.assign({}, FALLBACK, data, {
            brand: Object.assign({}, FALLBACK.brand, data.brand || {}),
            featureFlags: Object.assign({}, FALLBACK.featureFlags, data.featureFlags || {}),
            copy: Object.assign({}, FALLBACK.copy, data.copy || {})
          });
        } else {
          console.warn('tenant config not found for', slug, '— using submerged defaults');
        }
      } catch (e) {
        console.warn('tenant load failed, using defaults', e);
      }
    } else {
      // Still try to load submerged.json so repo config wins over hardcoded fallback
      try {
        var res2 = await fetch('tenants/submerged.json', { cache: 'no-store' });
        if (res2.ok) {
          var data2 = await res2.json();
          tenant = Object.assign({}, FALLBACK, data2, {
            brand: Object.assign({}, FALLBACK.brand, data2.brand || {}),
            featureFlags: Object.assign({}, FALLBACK.featureFlags, data2.featureFlags || {}),
            copy: Object.assign({}, FALLBACK.copy, data2.copy || {})
          });
        }
      } catch (_) { /* keep FALLBACK */ }
    }
    finish(tenant);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', load);
  } else {
    load();
  }
})(window);
