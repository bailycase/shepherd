/*
 * shepherd-dc-bridge.js: runs in Shepherd's own content world beside a board, where the board's
 * scripts can't reach it or its message handler. It listens for the runtime's `shepherd-dc`
 * events and the page's uncaught errors, measures the board itself, and posts only checked,
 * size-capped values to Shepherd.
 */
(function () {
  'use strict';
  var handlers = window.webkit && window.webkit.messageHandlers;
  var handler = handlers && handlers.shepherdDesign;
  if (!handler) return;

  function post(message) {
    try { handler.postMessage(message); } catch (_) { }
  }

  function clip(value, length) {
    return String(value == null ? '' : value).slice(0, length);
  }

  function dimension(value) {
    return typeof value === 'number' && isFinite(value) && value > 0 && value <= 100000 ? value : null;
  }

  /** The board's extent: the union of what the body holds, from the page's origin. */
  function measure() {
    var width = 0;
    var height = 0;
    var body = document.body;
    if (body) {
      for (var i = 0; i < body.children.length; i++) {
        var rect = body.children[i].getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) continue;
        width = Math.max(width, rect.right + window.scrollX);
        height = Math.max(height, rect.bottom + window.scrollY);
      }
    }
    return { width: Math.ceil(width), height: Math.ceil(height) };
  }

  var booted = false;
  var last = null;
  var pending = false;

  function reportSize() {
    pending = false;
    var size = measure();
    if (last && last.width === size.width && last.height === size.height) return;
    last = size;
    post({ type: 'size', width: size.width, height: size.height });
  }

  function scheduleSize() {
    if (!booted || pending) return;
    pending = true;
    requestAnimationFrame(reportSize);
  }

  var resizes = new ResizeObserver(scheduleSize);
  function observeBody() {
    resizes.disconnect();
    if (!document.body) return;
    resizes.observe(document.body);
    for (var i = 0; i < document.body.children.length; i++) resizes.observe(document.body.children[i]);
  }

  document.addEventListener('shepherd-dc', function (event) {
    var message;
    try { message = JSON.parse(typeof event.detail === 'string' ? event.detail : ''); } catch (_) { return; }
    if (!message || typeof message !== 'object') return;
    if (message.type === 'booted' && !booted) {
      booted = true;
      var size = measure();
      last = size;
      var preview = message.preview && typeof message.preview === 'object' ? message.preview : null;
      post({
        type: 'booted', width: size.width, height: size.height,
        previewWidth: preview ? dimension(preview.width) : null,
        previewHeight: preview ? dimension(preview.height) : null
      });
      observeBody();
      new MutationObserver(observeBody).observe(document.body, { childList: true });
    } else if (message.type === 'error') {
      post({ type: 'error', phase: clip(message.phase, 32), message: clip(message.message, 2000) });
    } else if (message.type === 'rendered') {
      scheduleSize();
    }
  }, true);

  window.addEventListener('error', function (event) {
    // A resource that failed to load has no message; the runtime reports its own failures.
    if (!event.message) return;
    post({ type: 'error', phase: 'script', message: clip(event.message, 2000), line: event.lineno | 0 });
  }, true);

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    post({ type: 'error', phase: 'script', message: clip(reason && reason.message ? reason.message : reason, 2000) });
  });
})();
