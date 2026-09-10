/**
 * Lightweight product analytics: console + soft insert into product_events.
 */
(function (global) {
  var buffer = [];
  var ready = false;

  function payload(event, props) {
    return {
      event_name: event,
      props: props || {},
      tenant_slug: (global.AppTenant && global.AppTenant.slug) || null,
      path: (global.location && (global.location.pathname + global.location.search)) || null,
      created_at: new Date().toISOString()
    };
  }

  function write(event, props) {
    var row = payload(event, props);
    try { console.debug('[analytics]', event, props || {}); } catch (_) {}
    var client = global.sb;
    if (!client || typeof client.from !== 'function') return;
    try {
      var q = client.from('product_events').insert(row);
      if (q && typeof q.then === 'function') {
        q.then(function () { /* soft */ }).catch(function () { /* soft */ });
      }
    } catch (_) { /* soft fail */ }
  }

  function flush() {
    while (buffer.length) {
      var item = buffer.shift();
      write(item.event, item.props);
    }
  }

  function track(event, props) {
    if (!event) return;
    if (!ready) {
      buffer.push({ event: event, props: props || {} });
      return;
    }
    write(event, props);
  }

  function analyticsReady() {
    ready = true;
    flush();
  }

  global.track = track;
  global.analyticsReady = analyticsReady;
})(window);
