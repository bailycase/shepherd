import Foundation

/// The script an agent's browser tools run in the thread's page (docs/browser.md). It lives in
/// Shepherd's own content world (`BrowserSession.world`), which the page can't see or call, and
/// answers every call with a JSON string. Refs (`e1`, `e2`, …) are made by `read` and kept in a map
/// inside the script: a later read, or a new document, ends them.
///
/// Events the tools dispatch are DOM events: `isTrusted` is false. That is also how the page tells
/// the agent's clicks from the user's own, which take the page over (`userInput`).
extension BrowserScripts {
    /// In Shepherd's world, at document start, main frame.
    static let agent = #"""
    (() => {
      if (window.__shepherdAgent) return;
      const post = (message) => { try { window.webkit.messageHandlers.shepherdBrowser.postMessage(message); } catch (e) {} };
      let refs = new Map();
      let issued = 0;
      let active = false;
      let reported = false;

      // ---- text helpers -------------------------------------------------------------------
      const clip = (value, limit) => {
        const text = String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
        return text.length > limit ? text.slice(0, limit - 1) + '…' : text;
      };
      const quote = (value) => '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
      const docOf = (node) => node.ownerDocument || node;
      const winOf = (node) => docOf(node).defaultView || window;
      const styleOf = (el) => winOf(el).getComputedStyle(el);
      const SKIP = new Set(['script', 'style', 'noscript', 'template', 'head', 'meta', 'link', 'title', 'base']);
      const OPAQUE = new Set(['select', 'textarea', 'option', 'optgroup', 'svg', 'canvas', 'input']);

      // A shadow host shows its shadow tree; a slot shows what is assigned to it.
      const childrenOf = (node) => {
        const list = [];
        const source = node.shadowRoot ? node.shadowRoot.childNodes : node.childNodes;
        for (const child of source) {
          if (child.nodeType === 1 && child.localName === 'slot') {
            const assigned = child.assignedNodes({ flatten: true });
            for (const inner of (assigned.length ? assigned : Array.from(child.childNodes))) list.push(inner);
          } else {
            list.push(child);
          }
        }
        return list;
      };

      const textOf = (root, limit) => {
        let out = '';
        const walk = (node, depth) => {
          if (out.length >= limit * 2 || depth > 40) return;
          if (node.nodeType === 3) { out += node.data; return; }
          if (node.nodeType !== 1) return;
          const tag = node.localName;
          if (SKIP.has(tag) || OPAQUE.has(tag)) return;
          if (node.getAttribute('aria-hidden') === 'true') return;
          const style = styleOf(node);
          if (style.display === 'none') return;
          if (tag === 'img') { out += ' ' + (node.alt || '') + ' '; return; }
          const hidden = style.visibility === 'hidden' || style.visibility === 'collapse';
          for (const child of childrenOf(node)) {
            if (hidden && child.nodeType === 3) continue;
            walk(child, depth + 1);
          }
          if (!style.display.startsWith('inline') && style.display !== 'contents') out += ' ';
        };
        walk(root, 0);
        return clip(out, limit);
      };

      // ---- roles and names ----------------------------------------------------------------
      const INPUT_ROLES = { button: 'button', submit: 'button', reset: 'button', image: 'button', checkbox: 'checkbox',
        radio: 'radio', range: 'slider', number: 'spinbutton', search: 'searchbox', file: 'file input', color: 'color input' };
      const LANDMARKS = { nav: 'navigation', main: 'main', header: 'banner', footer: 'contentinfo', aside: 'complementary',
        form: 'form', dialog: 'dialog', article: 'article', table: 'table', tr: 'row', ul: 'list', ol: 'list', fieldset: 'group' };
      const ACTION_ROLES = new Set(['button', 'link', 'checkbox', 'radio', 'switch', 'tab', 'menuitem', 'menuitemcheckbox',
        'menuitemradio', 'option', 'combobox', 'textbox', 'searchbox', 'slider', 'spinbutton', 'treeitem', 'file input', 'color input']);
      const inputType = (el) => (el.getAttribute('type') || 'text').toLowerCase();

      const roleOf = (el) => {
        const explicit = (el.getAttribute('role') || '').trim().split(/\s+/)[0];
        if (explicit && explicit !== 'presentation' && explicit !== 'none') return explicit;
        const tag = el.localName;
        if (tag === 'a') return el.hasAttribute('href') ? 'link' : null;
        if (tag === 'button' || tag === 'summary') return 'button';
        if (tag === 'input') { const type = inputType(el); return type === 'hidden' ? null : (INPUT_ROLES[type] || 'textbox'); }
        if (tag === 'textarea') return 'textbox';
        if (tag === 'select') return (el.multiple || el.size > 1) ? 'listbox' : 'combobox';
        if (/^h[1-6]$/.test(tag)) return 'heading';
        if (tag === 'img') return 'img';
        if (tag === 'iframe' || tag === 'frame') return 'iframe';
        if (el.isContentEditable && el.getAttribute('contenteditable') !== 'false'
            && !(el.parentElement && el.parentElement.isContentEditable)) return 'textbox';
        return LANDMARKS[tag] || null;
      };
      const isSemanticInteractive = (el, role) => {
        const tag = el.localName;
        if (tag === 'a') return el.hasAttribute('href') || (role != null && ACTION_ROLES.has(role));
        if (tag === 'button' || tag === 'select' || tag === 'textarea' || tag === 'summary') return true;
        if (tag === 'input') return inputType(el) !== 'hidden';
        return role != null && ACTION_ROLES.has(role);
      };
      const looksClickable = (el, style) => {
        if (el === el.ownerDocument.body || el === el.ownerDocument.documentElement) return false;
        if (el.hasAttribute('onclick')) return true;
        if (style.cursor !== 'pointer') return false;
        const parent = el.parentElement;
        return !(parent && styleOf(parent).cursor === 'pointer');
      };

      const nameOf = (el) => {
        const labelledby = el.getAttribute('aria-labelledby');
        if (labelledby) {
          const named = labelledby.split(/\s+/).map((id) => { const target = docOf(el).getElementById(id); return target ? textOf(target, 120) : ''; })
            .join(' ').trim();
          if (named) return clip(named, 120);
        }
        const aria = el.getAttribute('aria-label');
        if (aria && aria.trim()) return clip(aria, 120);
        const tag = el.localName;
        if (tag === 'input' || tag === 'select' || tag === 'textarea') {
          const type = tag === 'input' ? inputType(el) : '';
          if (type === 'button' || type === 'submit' || type === 'reset') {
            return clip(el.value || (type === 'submit' ? 'Submit' : type === 'reset' ? 'Reset' : ''), 120);
          }
          if (type === 'image') return clip(el.alt || el.title || 'Submit', 120);
          const labels = el.labels ? Array.from(el.labels).map((label) => textOf(label, 120)).join(' ').trim() : '';
          if (labels) return clip(labels, 120);
          return clip(el.getAttribute('placeholder') || el.title || el.getAttribute('name') || '', 120);
        }
        if (tag === 'img') return clip(el.alt || el.title || '', 120);
        const own = textOf(el, 120);
        if (own) return own;
        const image = el.querySelector && el.querySelector('img[alt]');
        const vector = el.querySelector && el.querySelector('svg title');
        return clip(el.title || (image && image.alt) || (vector && vector.textContent) || '', 120);
      };

      const describe = (el) => {
        const role = roleOf(el);
        const name = role && role !== 'heading' && role !== 'img' ? nameOf(el) : '';
        if (role) return role + (name ? ' ' + quote(name) : '');
        let label = el.localName;
        if (el.id) label += '#' + el.id; else if (el.classList && el.classList.length) label += '.' + el.classList[0];
        const text = textOf(el, 40);
        return label + (text ? ' ' + quote(text) : '');
      };
      const targetOf = (el) => {
        const role = roleOf(el) || (el.localName === 'div' || el.localName === 'span' ? 'element' : el.localName);
        return { role, name: nameOf(el) || textOf(el, 60) };
      };

      const isDisabled = (el) => {
        try { if (el.matches(':disabled')) return true; } catch (e) {}
        return el.getAttribute('aria-disabled') === 'true';
      };
      const isVisible = (el) => {
        if (!el.isConnected) return false;
        if (typeof el.checkVisibility === 'function') {
          if (!el.checkVisibility({ checkVisibilityCSS: true })) return false;
        } else {
          const style = styleOf(el);
          if (style.display === 'none' || style.visibility === 'hidden') return false;
        }
        const r = el.getBoundingClientRect();
        return r.width > 0 || r.height > 0;
      };
      const topRect = (el) => {
        const r = el.getBoundingClientRect();
        let x = r.left, y = r.top;
        let win = winOf(el);
        for (let guard = 0; guard < 8 && win !== window.top; guard += 1) {
          let frame = null;
          try { frame = win.frameElement; } catch (e) {}
          if (!frame) break;
          const f = frame.getBoundingClientRect();
          x += f.left; y += f.top;
          win = win.parent;
        }
        return { x, y, width: r.width, height: r.height };
      };

      // ---- read ---------------------------------------------------------------------------
      const state = (el, role) => {
        const flags = [];
        const tag = el.localName;
        if (tag === 'input') {
          const type = inputType(el);
          if (type === 'checkbox' || type === 'radio') flags.push(el.checked ? 'checked' : 'unchecked');
          else if (type === 'password') flags.push(el.value ? 'value=[hidden]' : 'empty');
          else if (!['button', 'submit', 'reset', 'image', 'file', 'color'].includes(type)) {
            flags.push(el.value ? 'value=' + quote(clip(el.value, 200)) : 'empty');
            if (el.placeholder) flags.push('placeholder=' + quote(clip(el.placeholder, 60)));
          }
        } else if (tag === 'textarea') {
          flags.push(el.value ? 'value=' + quote(clip(el.value, 200)) : 'empty');
          if (el.placeholder) flags.push('placeholder=' + quote(clip(el.placeholder, 60)));
        } else if (tag === 'select') {
          const options = Array.from(el.options);
          const chosen = options.filter((o) => o.selected).map((o) => clip(o.text, 40));
          flags.push('value=' + quote(chosen.join(', ')));
          flags.push('options=[' + options.slice(0, 12).map((o) => quote(clip(o.text, 40))).join(', ') + (options.length > 12 ? ', …' : '') + ']');
        } else if (el.isContentEditable && role === 'textbox') {
          const text = clip(el.textContent, 200);
          flags.push(text ? 'value=' + quote(text) : 'empty');
        } else if (tag === 'summary' && el.parentElement && el.parentElement.localName === 'details') {
          flags.push(el.parentElement.open ? 'expanded' : 'collapsed');
        } else if (tag === 'a') {
          let href = el.href || '';
          try { const u = new URL(href); href = u.origin === location.origin ? u.pathname + u.search + u.hash : href; } catch (e) {}
          if (href) flags.push('href=' + quote(clip(href, 120)));
        }
        const checked = el.getAttribute('aria-checked'); if (checked) flags.push(checked === 'true' ? 'checked' : checked === 'mixed' ? 'mixed' : 'unchecked');
        const selected = el.getAttribute('aria-selected'); if (selected === 'true') flags.push('selected');
        const expanded = el.getAttribute('aria-expanded'); if (expanded) flags.push(expanded === 'true' ? 'expanded' : 'collapsed');
        if (isDisabled(el)) flags.push('disabled');
        if (el.required || el.getAttribute('aria-required') === 'true') flags.push('required');
        if (el.readOnly) flags.push('readonly');
        if (docOf(el).activeElement === el) flags.push('focused');
        return flags;
      };

      const read = (options) => {
        refs = new Map();
        issued = 0;
        const maxChars = Math.max(500, Math.min(options.maxChars || 30000, 60000));
        const maxLines = 4000;
        const lines = [];
        let chars = 0;
        let truncated = false;
        const emit = (depth, text) => {
          if (truncated) return;
          const line = '  '.repeat(Math.min(depth, 12)) + '- ' + text;
          if (lines.length >= maxLines || chars + line.length + 1 > maxChars - 200) { truncated = true; return; }
          lines.push(line);
          chars += line.length + 1;
        };
        const emitInteractive = (el, role, depth) => {
          const ref = 'e' + (++issued);
          refs.set(ref, el);
          const name = nameOf(el);
          emit(depth, [role, name ? quote(name) : '', '[' + ref + ']'].concat(state(el, role)).filter(Boolean).join(' '));
          return ref;
        };
        let scope;
        const emitFrame = (el, depth) => {
          const label = clip(el.title || el.getAttribute('name') || '', 80);
          let inner = null;
          try { inner = el.contentDocument; } catch (e) {}
          if (inner && inner.body) {
            emit(depth, 'iframe' + (label ? ' ' + quote(label) : ''));
            scope(inner.body, depth + 1, false);
          } else {
            emit(depth, 'iframe' + (label ? ' ' + quote(label) : '') + ' (another origin: its content is not shown)');
          }
        };
        scope = (container, depth, textless) => {
          let run = '';
          const flush = () => {
            const text = clip(run, 400);
            run = '';
            if (text && !textless) emit(depth, 'text ' + quote(text));
          };
          const visit = (node) => {
            if (truncated) return;
            if (node.nodeType === 3) { run += node.data; return; }
            if (node.nodeType !== 1) return;
            const el = node;
            const tag = el.localName;
            if (SKIP.has(tag) || el.getAttribute('aria-hidden') === 'true') return;
            const style = styleOf(el);
            if (style.display === 'none') return;
            const hidden = style.visibility === 'hidden' || style.visibility === 'collapse';
            if (hidden) {
              for (const child of childrenOf(el)) { if (child.nodeType === 1) visit(child); }
              return;
            }
            const role = roleOf(el);
            if (isSemanticInteractive(el, role)) { flush(); emitInteractive(el, role, depth); return; }
            if (tag === 'img') {
              flush();
              const alt = clip(el.alt, 120);
              if (alt) emit(depth, 'img ' + quote(alt));
              return;
            }
            if (tag === 'svg' || tag === 'canvas' || tag === 'video' || tag === 'audio') {
              if (tag === 'svg') return;
              flush(); emit(depth, tag); return;
            }
            if (tag === 'iframe' || tag === 'frame') { flush(); emitFrame(el, depth); return; }
            if (/^h[1-6]$/.test(tag)) {
              flush();
              emit(depth, 'heading ' + quote(textOf(el, 200)) + ' [level=' + tag[1] + ']');
              if (el.querySelector('a[href],button,input,select,textarea,[role=button],[role=link]')) scope(el, depth + 1, true);
              return;
            }
            if (role && LANDMARKS[tag] === role && role !== 'heading') {
              flush();
              const name = el.getAttribute('aria-label') || (el.getAttribute('aria-labelledby') ? nameOf(el) : '');
              emit(depth, role + (name ? ' ' + quote(clip(name, 80)) : ''));
              scope(el, depth + 1, false);
              return;
            }
            if (looksClickable(el, style)) {
              const name = nameOf(el);
              if (name) {
                flush();
                emitInteractive(el, 'clickable', depth);
                scope(el, depth + 1, true);
                return;
              }
            }
            const block = !style.display.startsWith('inline') && style.display !== 'contents';
            if (block) flush();
            for (const child of childrenOf(el)) visit(child);
            if (block) flush();
          };
          for (const child of childrenOf(container)) visit(child);
          flush();
        };

        let root = document.body || document.documentElement;
        if (options.selector) {
          try { root = document.querySelector(options.selector); } catch (e) {
            return { error: 'invalid', message: 'The selector ' + quote(options.selector) + ' is not valid: ' + e.message };
          }
          if (!root) return { error: 'not_found', message: 'No element matches ' + quote(options.selector) + '.' };
        }
        const doc = document.documentElement;
        const maxY = Math.max(0, doc.scrollHeight - window.innerHeight);
        emit(0, 'viewport ' + window.innerWidth + '×' + window.innerHeight + ', scrolled ' + Math.round(window.scrollY) + ' of ' + Math.round(maxY) + ' px');
        scope(root, 0, false);
        let text = lines.join('\n');
        if (truncated) text += '\n[Snapshot truncated. Read one part with selector, or scroll and read again.]';
        return { text, truncated, refs: issued, title: document.title, url: location.href };
      };

      // ---- refs ---------------------------------------------------------------------------
      const target = (ref) => {
        if (typeof ref !== 'string' || !/^e[0-9]+$/.test(ref)) {
          return { error: 'no_such_ref', message: quote(ref) + ' is not a ref; refs look like e12 and come from browser_read.' };
        }
        const el = refs.get(ref);
        if (!el || !el.isConnected) return { error: 'stale_ref', message: 'ref ' + ref + ' is stale; call browser_read again' };
        return { el };
      };
      const peek = ({ ref }) => {
        const t = target(ref);
        return t.error ? t : { ok: true, target: targetOf(t.el) };
      };

      // ---- events -------------------------------------------------------------------------
      const FOCUSABLE = 'a[href],button,input,select,textarea,summary,[tabindex],[contenteditable]:not([contenteditable="false"])';
      const focusFor = (el) => {
        const focusable = el.closest ? el.closest(FOCUSABLE) : null;
        if (focusable && !isDisabled(focusable)) { try { focusable.focus({ preventScroll: true }); } catch (e) {} }
        else { const current = docOf(el).activeElement; if (current && current.blur) current.blur(); }
      };
      const contains = (outer, inner) => {
        for (let node = inner; node; node = node.parentNode || node.host) { if (node === outer) return true; }
        return false;
      };
      const deepHit = (doc, x, y) => {
        let hit = doc.elementFromPoint(x, y);
        for (let guard = 0; hit && hit.shadowRoot && guard < 10; guard += 1) {
          const inner = hit.shadowRoot.elementFromPoint(x, y);
          if (!inner || inner === hit) break;
          hit = inner;
        }
        return hit;
      };
      const sequence = (node, win, x, y, detail) => {
        const base = { bubbles: true, cancelable: true, composed: true, view: win, clientX: x, clientY: y, screenX: x, screenY: y };
        const pointer = (type, extra) => node.dispatchEvent(new win.PointerEvent(type,
          Object.assign({ pointerId: 1, pointerType: 'mouse', isPrimary: true }, base, extra)));
        const mouse = (type, extra) => node.dispatchEvent(new win.MouseEvent(type, Object.assign({}, base, extra)));
        pointer('pointerover', {});
        pointer('pointerenter', { bubbles: false });
        mouse('mouseover', {});
        mouse('mouseenter', { bubbles: false });
        pointer('pointermove', {});
        mouse('mousemove', {});
        pointer('pointerdown', { button: 0, buttons: 1, detail });
        const allowed = mouse('mousedown', { button: 0, buttons: 1, detail });
        if (allowed) focusFor(node);
        pointer('pointerup', { button: 0, buttons: 0, detail });
        mouse('mouseup', { button: 0, buttons: 0, detail });
        mouse('click', { button: 0, buttons: 0, detail });
        return base;
      };

      const click = ({ ref, double }) => {
        const t = target(ref);
        if (t.error) return t;
        const el = t.el;
        const label = describe(el);
        if (isDisabled(el)) return { error: 'disabled', message: label + ' (' + ref + ') is disabled.' };
        try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (e) {}
        let rect = el.getBoundingClientRect();
        let node = el;
        if (rect.width === 0 && rect.height === 0) {
          const first = el.labels && el.labels[0];
          if (first && isVisible(first)) { node = first; rect = first.getBoundingClientRect(); }
        }
        if (!isVisible(node) && !(rect.width > 0 || rect.height > 0)) {
          return { error: 'hidden', message: label + ' (' + ref + ') is not visible.' };
        }
        const doc = docOf(node);
        const win = winOf(node);
        const x = Math.min(Math.max(rect.left + rect.width / 2, 0), win.innerWidth - 1);
        const y = Math.min(Math.max(rect.top + rect.height / 2, 0), win.innerHeight - 1);
        const hit = deepHit(doc, x, y);
        if (hit && !contains(node, hit) && !contains(hit, node)
            && !(el.labels && Array.from(el.labels).some((l) => contains(l, hit)))) {
          return { error: 'covered', message: label + ' (' + ref + ') is covered by ' + describe(hit)
            + ' at its center; close or scroll past what is over it.' };
        }
        const on = hit && (contains(node, hit)) ? hit : node;
        sequence(on, win, x, y, 1);
        if (double) {
          sequence(on, win, x, y, 2);
          on.dispatchEvent(new win.MouseEvent('dblclick', { bubbles: true, cancelable: true, composed: true, view: win, clientX: x, clientY: y, detail: 2 }));
        }
        return { ok: true, target: targetOf(el), rect: topRect(node) };
      };

      const nativeSet = (el, value) => {
        const win = winOf(el);
        const proto = el.localName === 'textarea' ? win.HTMLTextAreaElement.prototype
          : el.localName === 'select' ? win.HTMLSelectElement.prototype : win.HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
        setter.call(el, value);
      };
      const fireInput = (el, data, inputType) => {
        const win = winOf(el);
        el.dispatchEvent(new win.InputEvent('input', { bubbles: true, composed: true, inputType: inputType || 'insertText', data: data == null ? null : data }));
      };
      const fireChange = (el) => el.dispatchEvent(new (winOf(el).Event)('change', { bubbles: true }));
      const replaceValue = (el, next, data, inputType) => {
        const win = winOf(el);
        const allowed = el.dispatchEvent(new win.InputEvent('beforeinput', { bubbles: true, cancelable: true, composed: true, inputType: inputType || 'insertText', data: data == null ? null : data }));
        if (!allowed) return false;
        nativeSet(el, next);
        try { el.setSelectionRange(next.length, next.length); } catch (e) {}
        fireInput(el, data, inputType);
        return true;
      };
      const TEXTLESS = new Set(['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'hidden', 'color']);

      const keyEvent = (el, type, spec) => {
        const win = winOf(el);
        return el.dispatchEvent(new win.KeyboardEvent(type, {
          key: spec.key, code: spec.code, ctrlKey: !!spec.ctrl, shiftKey: !!spec.shift, altKey: !!spec.alt, metaKey: !!spec.meta,
          keyCode: KEYCODES[spec.key] || (spec.key.length === 1 ? spec.key.toUpperCase().charCodeAt(0) : 0),
          bubbles: true, cancelable: true, composed: true, view: win }));
      };
      const KEYCODES = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, ' ': 32, ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39,
        ArrowDown: 40, Home: 36, End: 35, PageUp: 33, PageDown: 34 };

      const deepActive = () => {
        let el = document.activeElement;
        for (let guard = 0; el && guard < 10; guard += 1) {
          if (el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
          else if ((el.localName === 'iframe' || el.localName === 'frame')) {
            let inner = null;
            try { inner = el.contentDocument && el.contentDocument.activeElement; } catch (e) {}
            if (inner && inner !== el.contentDocument.body) el = inner; else break;
          } else break;
        }
        return el;
      };
      const tabbables = (doc) => {
        const all = Array.from(doc.querySelectorAll('a[href],button,input,select,textarea,summary,[tabindex],[contenteditable]:not([contenteditable="false"])'))
          .filter((el) => !isDisabled(el) && el.getAttribute('tabindex') !== '-1' && !(el.localName === 'input' && inputType(el) === 'hidden') && isVisible(el));
        const positive = all.filter((el) => el.tabIndex > 0).sort((a, b) => a.tabIndex - b.tabIndex);
        return positive.concat(all.filter((el) => el.tabIndex <= 0));
      };
      const moveFocus = (step) => {
        const list = tabbables(document);
        if (!list.length) return null;
        const current = document.activeElement;
        let index = list.indexOf(current);
        index = index < 0 ? (step > 0 ? 0 : list.length - 1) : (index + step + list.length) % list.length;
        list[index].focus({ preventScroll: false });
        return list[index];
      };
      const submitOf = (form) => form.querySelector('button[type=submit],button:not([type]),input[type=submit]');

      const insertInto = (el, text) => {
        const tag = el.localName;
        if ((tag === 'input' && !TEXTLESS.has(inputType(el))) || tag === 'textarea') {
          const value = tag === 'input' ? text.replace(/[\r\n]+/g, '') : text;
          const start = typeof el.selectionStart === 'number' ? el.selectionStart : el.value.length;
          const end = typeof el.selectionEnd === 'number' ? el.selectionEnd : start;
          return replaceValue(el, el.value.slice(0, start) + value + el.value.slice(end), value);
        }
        if (el.isContentEditable) return docOf(el).execCommand('insertText', false, text);
        return false;
      };

      const pressKey = (spec) => {
        const el = deepActive() || document.body;
        const before = keyEvent(el, 'keydown', spec);
        const printable = spec.key.length === 1 && !spec.ctrl && !spec.meta;
        let prevented = !before;
        const tag = el.localName;
        if (before) {
          if (spec.key === 'Tab') {
            moveFocus(spec.shift ? -1 : 1);
          } else if (spec.key === 'Enter') {
            if (!keyEvent(el, 'keypress', spec)) prevented = true;
            else if (tag === 'textarea') insertInto(el, '\n');
            else if (el.isContentEditable) docOf(el).execCommand('insertParagraph', false);
            else if (tag === 'input' && el.form && !TEXTLESS.has(inputType(el))) {
              const submitter = submitOf(el.form);
              try { el.form.requestSubmit(submitter && !isDisabled(submitter) ? submitter : undefined); } catch (e) { el.form.requestSubmit(); }
            } else if (tag === 'a' || tag === 'button' || tag === 'summary' || el.getAttribute('role') === 'button' || el.getAttribute('role') === 'link') {
              el.click();
            }
          } else if ((spec.ctrl || spec.meta) && spec.key.toLowerCase() === 'a') {
            if (tag === 'input' || tag === 'textarea') el.select(); else docOf(el).execCommand('selectAll', false);
          } else if (spec.key === 'Backspace' || spec.key === 'Delete') {
            if ((tag === 'input' && !TEXTLESS.has(inputType(el))) || tag === 'textarea') {
              const start = el.selectionStart, end = el.selectionEnd;
              let from = start, to = end;
              if (start === end) { if (spec.key === 'Backspace') from = Math.max(0, start - 1); else to = Math.min(el.value.length, end + 1); }
              if (from !== to) replaceValue(el, el.value.slice(0, from) + el.value.slice(to), null, spec.key === 'Backspace' ? 'deleteContentBackward' : 'deleteContentForward');
              try { el.setSelectionRange(from, from); } catch (e) {}
            } else if (el.isContentEditable) {
              docOf(el).execCommand(spec.key === 'Backspace' ? 'delete' : 'forwardDelete', false);
            }
          } else if (printable) {
            if (keyEvent(el, 'keypress', spec)) insertInto(el, spec.key); else prevented = true;
          }
        }
        keyEvent(el, 'keyup', spec);
        if (!prevented && spec.key === ' ' && (tag === 'button' || tag === 'summary' || (tag === 'input' && ['checkbox', 'radio', 'button', 'submit'].includes(inputType(el)))
            || el.getAttribute('role') === 'button')) el.click();
        const now = deepActive();
        return { ok: true, target: el === document.body ? { role: 'page', name: '' } : targetOf(el),
          focus: now && now !== document.body ? describe(now) : null, rect: now && now !== document.body ? topRect(now) : null };
      };

      const type = ({ ref, text, clear, submit }) => {
        const t = target(ref);
        if (t.error) return t;
        const el = t.el;
        const label = describe(el);
        if (isDisabled(el)) return { error: 'disabled', message: label + ' (' + ref + ') is disabled.' };
        if (el.readOnly) return { error: 'invalid', message: label + ' (' + ref + ') is read-only.' };
        try { el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' }); } catch (e) {}
        if (!isVisible(el)) return { error: 'hidden', message: label + ' (' + ref + ') is not visible.' };
        const tag = el.localName;
        const win = winOf(el);
        try { el.focus({ preventScroll: true }); } catch (e) {}
        if (tag === 'select') {
          const options = Array.from(el.options);
          const wanted = text.trim().toLowerCase();
          const match = options.find((o) => o.value === text) || options.find((o) => o.text.trim().toLowerCase() === wanted)
            || options.find((o) => o.text.toLowerCase().includes(wanted));
          if (!match) {
            return { error: 'invalid', message: 'No option "' + text + '" in ' + label + '. Options: ' + options.slice(0, 12).map((o) => quote(clip(o.text, 40))).join(', ') };
          }
          nativeSet(el, match.value);
          fireInput(el, null, 'insertReplacementText');
          fireChange(el);
        } else if ((tag === 'input' && !TEXTLESS.has(inputType(el))) || tag === 'textarea') {
          const value = tag === 'input' ? text.replace(/[\r\n]+/g, '') : text;
          const base = clear ? '' : el.value;
          if (!replaceValue(el, base + value, value)) return { error: 'invalid', message: 'The page refused the input.' };
          fireChange(el);
        } else if (el.isContentEditable) {
          const doc = docOf(el);
          if (clear) { doc.execCommand('selectAll', false); doc.execCommand('delete', false); }
          else { const selection = win.getSelection(); selection.selectAllChildren(el); selection.collapseToEnd(); }
          if (!doc.execCommand('insertText', false, text)) { el.textContent = (clear ? '' : el.textContent) + text; fireInput(el, text); }
        } else if (tag === 'input' && (inputType(el) === 'checkbox' || inputType(el) === 'radio')) {
          return { error: 'invalid', message: label + ' (' + ref + ') is a ' + inputType(el) + ': use browser_click.' };
        } else if (tag === 'input' && inputType(el) === 'file') {
          return { error: 'invalid', message: label + ' (' + ref + ') is a file input; files can not be chosen from here.' };
        } else {
          return { error: 'invalid', message: label + ' (' + ref + ') does not take text.' };
        }
        const result = { ok: true, target: targetOf(el), rect: topRect(el) };
        if (submit) { const pressed = pressKey({ key: 'Enter', code: 'Enter' }); result.submitted = !!pressed.ok; }
        return result;
      };

      // ---- scroll, wait, screenshot ------------------------------------------------------
      const scrollable = (el) => {
        for (let node = el; node && node !== document.body; node = node.parentElement) {
          const style = styleOf(node);
          if (/(auto|scroll)/.test(style.overflowY + style.overflowX) && (node.scrollHeight > node.clientHeight || node.scrollWidth > node.clientWidth)) return node;
        }
        return null;
      };
      const scroll = (options) => {
        let holder = null;
        if (options.ref) {
          const t = target(options.ref);
          if (t.error) return t;
          if (!options.direction) {
            t.el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
            return { ok: true, target: targetOf(t.el), rect: topRect(t.el), y: Math.round(window.scrollY), maxY: Math.round(Math.max(0, document.documentElement.scrollHeight - window.innerHeight)) };
          }
          holder = scrollable(t.el);
        }
        const doc = document.documentElement;
        const box = holder || null;
        const viewH = box ? box.clientHeight : window.innerHeight;
        const viewW = box ? box.clientWidth : window.innerWidth;
        const amount = options.amount > 0 ? options.amount : null;
        const by = (left, top) => (box || window).scrollBy({ left, top, behavior: 'instant' });
        const to = (left, top) => (box || window).scrollTo({ left, top, behavior: 'instant' });
        const height = box ? box.scrollHeight : doc.scrollHeight;
        switch (options.direction) {
          case 'down': by(0, amount || Math.round(viewH * 0.8)); break;
          case 'up': by(0, -(amount || Math.round(viewH * 0.8))); break;
          case 'right': by(amount || Math.round(viewW * 0.8), 0); break;
          case 'left': by(-(amount || Math.round(viewW * 0.8)), 0); break;
          case 'top': to(box ? box.scrollLeft : window.scrollX, 0); break;
          case 'bottom': to(box ? box.scrollLeft : window.scrollX, height); break;
          default: return { error: 'invalid', message: 'direction must be up, down, left, right, top or bottom.' };
        }
        const y = box ? box.scrollTop : window.scrollY;
        const maxY = Math.max(0, height - viewH);
        return { ok: true, y: Math.round(y), maxY: Math.round(maxY), container: box ? describe(box) : null };
      };
      const check = (options) => {
        if (options.ref) {
          const t = target(options.ref);
          if (t.error) return options.gone ? { met: true } : t;
          const shown = isVisible(t.el);
          return { met: options.gone ? !shown : shown };
        }
        const haystack = ((document.body && document.body.innerText) || '').toLowerCase();
        const found = haystack.includes(String(options.text || '').toLowerCase());
        return { met: options.gone ? !found : found };
      };
      const rectOf = ({ ref }) => {
        const t = target(ref);
        if (t.error) return t;
        try { t.el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch (e) {}
        if (!isVisible(t.el)) return { error: 'hidden', message: describe(t.el) + ' (' + ref + ') is not visible.' };
        return { ok: true, rect: topRect(t.el), target: targetOf(t.el), viewport: { width: window.innerWidth, height: window.innerHeight } };
      };
      const info = () => ({
        title: document.title, url: location.href, ready: document.readyState,
        width: window.innerWidth, height: window.innerHeight, y: Math.round(window.scrollY),
        maxY: Math.round(Math.max(0, document.documentElement.scrollHeight - window.innerHeight)),
      });

      // The user's own click or key in the page, while the agent is using it, takes it over. The
      // agent's events are dispatched by script, so they are not trusted.
      for (const name of ['pointerdown', 'keydown']) {
        window.addEventListener(name, (event) => {
          if (event.isTrusted && active && !reported) { reported = true; post({ kind: 'userInput' }); }
        }, true);
      }

      Object.defineProperty(window, '__shepherdAgent', { value: Object.freeze({
        read, peek, click, type, pressKey, scroll, check, rectOf, info,
        setActive(on) { active = !!on; reported = false; return active; },
      }) });
    })();
    """#
}
