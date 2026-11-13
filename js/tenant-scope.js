/**
 * Tenant scoping helpers for Supabase queries.
 *
 * Existing rows have no tenant_slug (NULL). Those belong to the dogfood
 * tenant "submerged", which is how the app treated all data before a
 * tenant column existed. Other tenants never match NULL rows.
 *
 * Requires the proposed tenant_slug migration (not applied). Queries
 * that filter on tenant_slug will fail until that column exists.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    module.exports = factory();
  } else {
    root.TenantScope = factory();
  }
})(typeof window !== 'undefined' ? window : globalThis, function () {
  var SUBMERGED = 'submerged';
  var SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;

  function isValidSlug(slug) {
    return SLUG_RE.test(slug);
  }

  function normalizeSlug(slug) {
    return String(slug == null ? '' : slug).trim().toLowerCase();
  }

  function resolveSlug(slug) {
    if (slug == null || slug === '') {
      try {
        if (typeof window !== 'undefined' && window.resolveTenantSlug) {
          slug = window.resolveTenantSlug();
        }
      } catch (_) { /* ignore */ }
    }
    return normalizeSlug(slug);
  }

  // Description of the PostgREST filter to apply. Pure; safe to unit test.
  function filterFor(slug) {
    var s = resolveSlug(slug);
    if (!s || !isValidSlug(s)) return null;
    if (s === SUBMERGED) {
      return { type: 'or', value: 'tenant_slug.eq.submerged,tenant_slug.is.null' };
    }
    return { type: 'eq', column: 'tenant_slug', value: s };
  }

  function apply(query, slug) {
    var f = filterFor(slug);
    if (!f) {
      throw new Error('Refusing unscoped query: missing or invalid tenant slug');
    }
    if (f.type === 'or') return query.or(f.value);
    return query.eq(f.column, f.value);
  }

  function withTenant(fields, slug) {
    var s = resolveSlug(slug);
    if (!s || !isValidSlug(s)) {
      throw new Error('Refusing write without a valid tenant slug');
    }
    return Object.assign({}, fields || {}, { tenant_slug: s });
  }

  return {
    SUBMERGED: SUBMERGED,
    isValidSlug: isValidSlug,
    normalizeSlug: normalizeSlug,
    filterFor: filterFor,
    apply: apply,
    withTenant: withTenant
  };
});
