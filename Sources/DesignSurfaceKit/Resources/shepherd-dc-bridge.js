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
      noun: nounOf(node, found),
      // A `<dc-import>`'s board name, as written: the element is one use of that shared piece.
      piece: found.tag === 'dc-import' && typeof found.el === 'string' && found.el ? clip(found.el, 200) : null
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

  // MARK: Export

  /** A stylesheet the design serves (not Google Fonts'), as a `<style>` holding its rules. */
  function inlined(link) {
    try {
      if (!link.sheet || String(link.href).indexOf(location.protocol) !== 0) return null;
      var text = Array.prototype.map.call(link.sheet.cssRules, function (rule) { return rule.cssText; }).join('\n');
      var style = document.createElement('style');
      style.textContent = text;
      return style;
    } catch (_) { return null; }
  }

  /**
   * The board as a standalone page: the document as drawn now (the hoisted helmet in its head,
   * what the runtime rendered in its body), with no script, no runtime, none of Shepherd's
   * `data-dc-*` stamps and no handler attributes. The design's own stylesheets are inlined;
   * Google Fonts' links stay.
   */
  function staticPage() {
    if (!booted) return null;
    var originals = document.querySelectorAll('link[rel~="stylesheet"]');
    var page = document.documentElement.cloneNode(true);
    var links = page.querySelectorAll('link[rel~="stylesheet"]');
    for (var i = 0; i < links.length && i < originals.length; i++) {
      var style = inlined(originals[i]);
      if (style) links[i].parentNode.replaceChild(style, links[i]);
    }
    // Nothing that runs, embeds another document, or redirects the page leaves: an imported
    // board never passed board_write's lint, and the page opens outside the canvas's sandbox.
    var gone = page.querySelectorAll('script, x-dc, style[data-dc-runtime], link[rel~="modulepreload"], link[rel~="preload"], ' +
      'link[rel~="import"], iframe, frame, frameset, object, embed, portal, base, meta[http-equiv]');
    for (var j = 0; j < gone.length; j++) if (gone[j].parentNode) gone[j].parentNode.removeChild(gone[j]);
    var all = [page].concat(Array.prototype.slice.call(page.querySelectorAll('*')));
    for (var k = 0; k < all.length; k++) {
      var element = all[k];
      for (var a = element.attributes.length - 1; a >= 0; a--) {
        var name = element.attributes[a].name;
        var value = element.attributes[a].value;
        if (/^data-dc-/i.test(name) || /^on/i.test(name) || name.toLowerCase() === 'srcdoc' ||
            /^[\s\u0000-\u001f]*(javascript|vbscript):/i.test(value.replace(/[\t\n\r]/g, ''))) {
          element.removeAttribute(name);
        }
      }
    }
    // SVG animation can set a link's target to script.
    var animations = page.querySelectorAll('animate, set');
    for (var n = 0; n < animations.length; n++) {
      var target = (animations[n].getAttribute('attributeName') || '').toLowerCase();
      if (/(^|:)href$/.test(target) && animations[n].parentNode) animations[n].parentNode.removeChild(animations[n]);
    }
    return '<!doctype html>\n' + page.outerHTML + '\n';
  }

  // MARK: References

  /** The computed properties an element's detail lists: what implementing it needs. */
  var DETAIL_PROPS = ['display', 'position', 'top', 'right', 'bottom', 'left', 'z-index', 'box-sizing', 'width', 'height',
    'min-width', 'min-height', 'max-width', 'max-height', 'margin', 'padding', 'flex-direction', 'flex-wrap', 'flex-grow',
    'flex-shrink', 'flex-basis', 'justify-content', 'align-items', 'align-self', 'gap', 'grid-template-columns',
    'grid-template-rows', 'grid-column', 'grid-row', 'overflow', 'background-color', 'background-image', 'color', 'opacity',
    'border-top', 'border-right', 'border-bottom', 'border-left', 'border-radius', 'box-shadow', 'outline', 'font-family',
    'font-size', 'font-weight', 'font-style', 'line-height', 'letter-spacing', 'text-align', 'text-transform',
    'text-decoration-line', 'white-space', 'transform', 'fill', 'stroke', 'stroke-width', 'object-fit'];
  var DETAIL_SKIP = { '': true, 'none': true, 'normal': true, 'auto': true, '0px': true, 'static': true, 'visible': true,
    'rgba(0, 0, 0, 0)': true, '0px none rgb(0, 0, 0)': true };

  /** A copy of `node` with nothing that runs and none of Shepherd's stamps: staticPage's rules. */
  function cleaned(node) {
    var copy = node.cloneNode(true);
    var gone = copy.querySelectorAll('script, iframe, frame, frameset, object, embed, portal, base, meta[http-equiv]');
    for (var i = 0; i < gone.length; i++) if (gone[i].parentNode) gone[i].parentNode.removeChild(gone[i]);
    var all = [copy].concat(Array.prototype.slice.call(copy.querySelectorAll('*')));
    for (var k = 0; k < all.length; k++) {
      for (var a = all[k].attributes.length - 1; a >= 0; a--) {
        var name = all[k].attributes[a].name;
        var value = all[k].attributes[a].value;
        if (/^data-dc-/i.test(name) || /^on/i.test(name) || name.toLowerCase() === 'srcdoc' ||
            /^[\s\u0000-\u001f]*(javascript|vbscript):/i.test(value.replace(/[\t\n\r]/g, ''))) {
          all[k].removeAttribute(name);
        }
      }
    }
    return copy;
  }

  /**
   * Element `tid` as a design reference hands it over: its markup as drawn now (cleaned as
   * staticPage cleans a page, cut at 512 KB) and the computed styles of it and up to 300 elements
   * under it, each by its child path under the element, leaving out values that say nothing.
   */
  function elementDetail(tid) {
    if (!booted || !Number.isInteger(tid) || tid < 0) return null;
    var found = document.body && document.body.querySelector('[data-dc-tid="' + tid + '"], [data-dc-owner="' + tid + '"]');
    if (!found) return null;
    var node = outermost(found);
    var html = cleaned(node).outerHTML;
    var clipped = html.length > 524288;
    var styles = [];
    var walk = [{ node: node, path: [] }];
    while (walk.length && styles.length < 300) {
      var item = walk.shift();
      var style = getComputedStyle(item.node);
      var values = {};
      for (var p = 0; p < DETAIL_PROPS.length; p++) {
        var value = style.getPropertyValue(DETAIL_PROPS[p]);
        if (!DETAIL_SKIP[value]) values[DETAIL_PROPS[p]] = clip(value, 300);
      }
      var rect = item.node.getBoundingClientRect();
      styles.push({ path: item.path.join('/'), tag: item.node.tagName.toLowerCase(),
        rect: [rect.left, rect.top, rect.width, rect.height], style: values });
      for (var c = 0; c < item.node.children.length; c++) walk.push({ node: item.node.children[c], path: item.path.concat([c]) });
    }
    return { html: clipped ? html.slice(0, 524288) : html, clipped: clipped, styles: styles };
  }

  function color(value) {
    return value && value !== 'transparent' && !/^rgba\([^)]*,\s*0\)$/.test(value) ? value : null;
  }

  /**
   * What a flow document's page breaks need (print.md): its height, each line of text and each
   * image or drawing as [top, bottom] down the page, and the paper's color (the body's, else the
   * page's).
   */
  function printLayout() {
    var body = document.body;
    if (!booted || !body) return null;
    var y = window.scrollY;
    var lines = [];
    var blocks = [];
    var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    var range = document.createRange();
    var node;
    while ((node = walker.nextNode()) && lines.length < 50000) {
      if (!node.nodeValue || !node.nodeValue.trim()) continue;
      range.selectNodeContents(node);
      var rects = range.getClientRects();
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].height > 0) lines.push([rects[i].top + y, rects[i].bottom + y]);
      }
    }
    var drawn = body.querySelectorAll('img, svg, video, canvas, picture');
    for (var j = 0; j < drawn.length && blocks.length < 10000; j++) {
      var rect = drawn[j].getBoundingClientRect();
      if (rect.height > 0) blocks.push([rect.top + y, rect.bottom + y]);
    }
    var height = Math.max(measure().height, document.documentElement.scrollHeight, body.scrollHeight);
    var paper = color(getComputedStyle(body).backgroundColor) || color(getComputedStyle(document.documentElement).backgroundColor) || 'rgb(255, 255, 255)';
    return { height: height, lines: lines, blocks: blocks, background: paper };
  }

  Object.defineProperty(window, '__shepherdBridge', {
    value: Object.freeze({ hitTest: hitTest, element: element, elementDetail: elementDetail, staticPage: staticPage,
      printLayout: printLayout }),
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
