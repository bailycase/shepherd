import Foundation

/// The scripts the Browser puts in every page (DESIGN.md › Side pane › Browser). The picker and
/// the network count run in Shepherd's own content world (`BrowserHost.world`), which the page
/// can't see or call, and post to a handler only that world has. Two things only the page's own
/// world can read: what its `console` says, and a React dev build's fibers (JS properties on the
/// page's DOM nodes are per world). So a small shim runs there: it wraps `console` and reports
/// errors to a console-only handler, and answers the picker's source question through a DOM
/// attribute. It holds no handler for picks: a page can at most forge a console line.
enum BrowserScripts {
    /// The page world's handler for console lines.
    static let consoleHandler = "shepherdConsole"
    /// Shepherd's world's handler for picks, moves, cancels and the network count.
    static let pickerHandler = "shepherdBrowser"

    /// In the page's world, at document start.
    static let pageShim = #"""
    (() => {
      if (window.__shepherdShim) return;
      Object.defineProperty(window, '__shepherdShim', { value: true });
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.shepherdConsole;
      const format = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) return (value.name || 'Error') + ': ' + value.message;
        try { const json = JSON.stringify(value); return json === undefined ? String(value) : json; } catch (e) { return String(value); }
      };
      const post = (level, args) => {
        if (!handler) return;
        try {
          const text = Array.prototype.map.call(args, format).join(' ');
          handler.postMessage({ level: level, text: text.slice(0, 2000) });
        } catch (e) {}
      };
      for (const [name, level] of [['log', 'log'], ['info', 'log'], ['debug', 'log'], ['warn', 'warning'], ['error', 'error']]) {
        const original = console[name];
        if (typeof original !== 'function') continue;
        console[name] = function (...args) { post(level, args); return original.apply(this, args); };
      }
      window.addEventListener('error', (event) => {
        const where = event.filename ? '  ' + String(event.filename).split('/').pop() + ':' + event.lineno : '';
        post('error', [String(event.message || 'Error') + where]);
      });
      window.addEventListener('unhandledrejection', (event) => post('error', ['Unhandled rejection: ' + format(event.reason)]));
      // The picker asks where an element came from: a React dev build keeps its JSX location on
      // the element's fiber. The answer goes back as an attribute, which every world sees.
      document.addEventListener('shepherd:source', (event) => {
        const element = event.target;
        if (!(element instanceof Element)) return;
        const key = Object.keys(element).find((k) => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
        let fiber = key ? element[key] : null;
        for (let depth = 0; fiber && depth < 40; depth += 1, fiber = fiber.return) {
          const source = fiber._debugSource;
          if (source && source.fileName) {
            element.setAttribute('data-shepherd-source', source.fileName + ':' + source.lineNumber);
            return;
          }
        }
      }, true);
    })();
    """#

    /// In Shepherd's world, at document end.
    static let picker = #"""
    (() => {
      if (window.__shepherdBrowser) return;
      const post = (message) => { try { window.webkit.messageHandlers.shepherdBrowser.postMessage(message); } catch (e) {} };
      let colors = { accent: '#7aa7ff', tint: 'rgba(122,167,255,0.13)', text: '#17120a' };
      let selecting = false;
      let picked = null;
      let host = null, box = null, tag = null, tagLabel = null, tagSize = null;

      const overlay = () => {
        if (host && host.isConnected) return;
        host = document.createElement('shepherd-picker');
        host.style.cssText = 'all: initial; position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;';
        const root = host.attachShadow({ mode: 'closed' });
        box = document.createElement('div');
        tag = document.createElement('div');
        tagLabel = document.createElement('span');
        tagSize = document.createElement('span');
        tagSize.style.opacity = '0.75';
        tag.append(tagLabel, tagSize);
        root.append(box, tag);
        document.documentElement.appendChild(host);
      };
      const paint = () => {
        box.style.cssText = 'position: fixed; box-sizing: border-box; border: 2px solid ' + colors.accent + '; border-radius: 10px; background: '
          + colors.tint + '; pointer-events: none; display: none;';
        tag.style.cssText = 'position: fixed; height: 20px; display: none; align-items: center; gap: 6px; padding: 0 7px; border-radius: 4px; background: '
          + colors.accent + '; color: ' + colors.text + '; font: 10.5px/20px "Geist Mono", ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap; pointer-events: none;';
      };
      const hide = () => { if (box) { box.style.display = 'none'; tag.style.display = 'none'; } };
      const show = (element) => {
        overlay();
        paint();
        const r = element.getBoundingClientRect();
        box.style.left = (r.left - 4) + 'px';
        box.style.top = (r.top - 4) + 'px';
        box.style.width = (r.width + 8) + 'px';
        box.style.height = (r.height + 8) + 'px';
        box.style.display = 'block';
        tagLabel.textContent = label(element);
        tagSize.textContent = Math.round(r.width) + ' × ' + Math.round(r.height);
        tag.style.left = Math.max(0, r.left - 2) + 'px';
        tag.style.top = (r.top - 26 >= 0 ? r.top - 26 : r.bottom + 6) + 'px';
        tag.style.display = 'flex';
      };

      const stable = (name) => /^[A-Za-z_-][\w-]*$/.test(name) && !/\d{4,}/.test(name) && name.length <= 40;
      const label = (element) => {
        const name = element.localName;
        if (element.id && stable(element.id)) return name + '#' + element.id;
        const cls = Array.from(element.classList).find(stable);
        return cls ? name + '.' + cls : name;
      };
      const selector = (element) => {
        const parts = [];
        for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
          if (node.id && stable(node.id) && document.querySelectorAll('#' + CSS.escape(node.id)).length === 1) {
            parts.unshift('#' + CSS.escape(node.id));
            return parts.join(' > ');
          }
          let part = node.localName;
          if (node === document.documentElement) { parts.unshift(part); break; }
          for (const cls of Array.from(node.classList).filter(stable).slice(0, 2)) part += '.' + CSS.escape(cls);
          const parent = node.parentElement;
          if (parent) {
            const same = Array.from(parent.children).filter((child) => child.localName === node.localName);
            if (same.length > 1 && Array.from(parent.children).filter((child) => child.matches(part)).length > 1) {
              part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
            }
          }
          parts.unshift(part);
          const candidate = parts.join(' > ');
          try { if (document.querySelectorAll(candidate).length === 1) return candidate; } catch (e) {}
        }
        return parts.join(' > ');
      };
      const source = (element) => {
        const marked = element.closest('[data-source],[data-inspector-relative-path]');
        if (marked) {
          const direct = marked.getAttribute('data-source');
          if (direct) return direct;
          const path = marked.getAttribute('data-inspector-relative-path');
          const line = marked.getAttribute('data-inspector-line');
          if (path) return line ? path + ':' + line : path;
        }
        element.dispatchEvent(new CustomEvent('shepherd:source'));
        const found = element.getAttribute('data-shepherd-source');
        if (found !== null) element.removeAttribute('data-shepherd-source');
        return found || null;
      };
      const rect = (element) => {
        const r = element.getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height };
      };
      const pick = (element) => {
        picked = element;
        selecting = false;
        show(element);
        const r = rect(element);
        post({ kind: 'pick', selector: selector(element), label: label(element), source: source(element),
               html: element.outerHTML.slice(0, 4000), rect: r });
      };

      const target = (event) => {
        const element = event.composedPath ? event.composedPath()[0] : event.target;
        return element instanceof Element ? element : (event.target instanceof Element ? event.target : null);
      };
      const swallow = (event) => {
        if (!selecting) return;
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
      };
      window.addEventListener('mousemove', (event) => {
        if (!selecting) return;
        const element = target(event);
        if (element && element !== host) show(element);
      }, true);
      for (const type of ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'auxclick', 'contextmenu']) {
        window.addEventListener(type, swallow, true);
      }
      window.addEventListener('click', (event) => {
        if (!selecting) return;
        swallow(event);
        const element = target(event);
        if (element) pick(element);
      }, true);
      window.addEventListener('keydown', (event) => {
        if (!selecting || event.key !== 'Escape') return;
        swallow(event);
        selecting = false;
        hide();
        post({ kind: 'cancel' });
      }, true);
      const follow = () => {
        if (!picked || selecting) return;
        if (!picked.isConnected) { picked = null; hide(); return; }
        show(picked);
        post({ kind: 'rect', rect: rect(picked) });
      };
      window.addEventListener('scroll', follow, { capture: true, passive: true });
      window.addEventListener('resize', follow, { passive: true });

      let resources = 0, timer = 0;
      const report = () => { if (!timer) timer = setTimeout(() => { timer = 0; post({ kind: 'network', count: resources + 1 }); }, 250); };
      try {
        new PerformanceObserver((list) => { resources += list.getEntries().length; report(); }).observe({ type: 'resource', buffered: true });
      } catch (e) {}
      report();

      Object.defineProperty(window, '__shepherdBrowser', { value: Object.freeze({
        setSelecting(on, palette) {
          if (palette) colors = palette;
          selecting = !!on;
          picked = null;
          hide();
          return selecting;
        },
        clear() { picked = null; hide(); },
        pickAt(x, y) { const element = document.elementFromPoint(x, y); if (element) pick(element); return !!element; },
      }) });
    })();
    """#
}
