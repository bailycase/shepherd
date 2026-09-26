/*
 * shepherd-dc-bridge.js: runs in Shepherd's own content world beside a board, where the board's
 * scripts can't reach it or its message handler. It listens for the runtime's `shepherd-dc`
 * events and the page's uncaught errors, measures the board itself, and posts only checked,
 * size-capped values to Shepherd.
 *
 * It also answers the canvas's selection (`__shepherdBridge`, callable in this world only):
 * `hitTest(x, y)` names the element under a point of the board, and `element(tid)` finds one again
 * after the board re-renders. Each answer is `{tid, path, x, y, width, height, kind, label, name,
 * noun}`: the geometry measured here, the rest from the runtime's `shepherd-dc-describe` answer
 * (what the board's template says), checked and clipped. An element the view record's grammar
 * can't name (nested too deep) gives way to its nearest ancestor that it can.
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
  /** The runtime's answer to the describe event in flight (answered synchronously). */
  var described = null;

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
    if (message.type === 'described') {
      described = message;
      return;
    }
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

  // MARK: Selection

  var KINDS = { text: true, image: true, shape: true, line: true, other: true };

  function describe(tid) {
    described = null;
    try { document.dispatchEvent(new CustomEvent('shepherd-dc-describe', { detail: String(tid) })); } catch (_) { return null; }
    var found = described;
    described = null;
    if (!found || found.tid !== tid || found.missing || !Array.isArray(found.path)) return null;
    return found;
  }

  /** view-state.md's grammar: tid ≤ 9999, at most 9 indexes, each ≤ 99. */
  function nameable(tid, path) {
    return tid <= 9999 && path.length >= 1 && path.length <= 9 &&
      path.every(function (index) { return Number.isInteger(index) && index >= 0 && index <= 99; });
  }

  /** The tid a drawn element stands for: its own, or the `<dc-import>` holding it. */
  function tidOf(node) {
    var raw = node.getAttribute('data-dc-owner');
    if (raw == null) raw = node.getAttribute('data-dc-tid');
    if (raw == null || !/^\d{1,6}$/.test(raw)) return null;
    return Number(raw);
  }

  /** An import's drawing: the outermost element it drew around `node`. */
  function outermost(node) {
    var owner = node.getAttribute('data-dc-owner');
    if (owner == null) return node;
    while (node.parentElement && node.parentElement.getAttribute('data-dc-owner') === owner) node = node.parentElement;
    return node;
  }

  function visibleFill(color) {
    var m = /rgba?\(([^)]*)\)/.exec(color || '');
    if (!m) return false;
    var parts = m[1].split(/[\s,\/]+/).filter(Boolean);
    return parts.length < 4 || parseFloat(parts[3]) > 0;
  }

  /** What the canvas's tag calls it ("card", "text", "button"…), read from how it is drawn. */
  function nounOf(node, found) {
    if (found.tag === 'dc-import' || found.tag === 'x-import') return 'component';
    if (found.kind === 'image') return 'image';
    if (found.kind === 'line') return 'line';
    var tag = found.tag;
    if (tag === 'button' || node.getAttribute('role') === 'button') return 'button';
    if (tag === 'a') return 'link';
    if (tag === 'input' || tag === 'textarea' || tag === 'select') return 'field';
    if (found.kind === 'text') return 'text';
    if (node.children.length === 0) return 'shape';
    var style = getComputedStyle(node);
    var boxed = visibleFill(style.backgroundColor) || parseFloat(style.borderTopWidth) > 0 ||
      parseFloat(style.borderLeftWidth) > 0 || (style.boxShadow && style.boxShadow !== 'none');
    return boxed ? 'card' : 'group';
  }

  function answer(node, tid, found) {
    var rect = node.getBoundingClientRect();
    var name = found.el || (node.getAttribute('data-dc-owner') == null ? node.getAttribute('data-el') : null);
    return {
      tid: tid,
      path: found.path.slice(0, 9),
      x: rect.left, y: rect.top, width: rect.width, height: rect.height,
      kind: KINDS[found.kind] ? found.kind : 'other',
      label: typeof found.label === 'string' ? clip(found.label, 200) : null,
      name: typeof name === 'string' && name ? clip(name, 200) : null,
      noun: nounOf(node, found)
    };
  }

  /** The element under a point of the board (its own CSS pixels), or null. */
  function hitTest(x, y) {
    if (!booted || typeof x !== 'number' || typeof y !== 'number') return null;
    var node = document.elementFromPoint(x, y);
    while (node && node.nodeType === 1 && node !== document.body && node !== document.documentElement) {
      var tid = tidOf(node);
      if (tid != null) {
        var found = describe(tid);
        if (found && nameable(tid, found.path)) {
          // An import is one element: its outermost drawing answers for it.
          var drawn = outermost(node);
          var rect = drawn.getBoundingClientRect();
          if (rect.width > 0 || rect.height > 0) return answer(drawn, tid, found);
        }
      }
      node = node.parentElement;
    }
    return null;
  }

  /** Element `tid` where it is drawn now (its first rendering), or null. */
  function element(tid) {
    if (!booted || !Number.isInteger(tid) || tid < 0) return null;
    var node = document.body && document.body.querySelector('[data-dc-tid="' + tid + '"], [data-dc-owner="' + tid + '"]');
    if (!node) return null;
    var found = describe(tid);
    if (!found || !nameable(tid, found.path)) return null;
    return answer(outermost(node), tid, found);
  }

  Object.defineProperty(window, '__shepherdBridge', {
    value: Object.freeze({ hitTest: hitTest, element: element }),
    writable: false, configurable: false, enumerable: false
  });

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
