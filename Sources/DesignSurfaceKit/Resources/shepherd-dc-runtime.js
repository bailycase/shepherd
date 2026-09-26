/*
 * shepherd-dc-runtime.js: Shepherd's runtime for Design canvas boards (*.dc.html).
 *
 * Written for Shepherd from the documented board format alone (docs/designs.md): no Claude
 * Design code is copied, fetched or imitated. A board's head line `<script src="./support.js">`
 * reaches this file through the shepherd-design:// scheme, served after React 18 (UMD).
 *
 * What it does:
 * - reads the board's own source and takes its template: the text after the `<x-dc>` open tag,
 *   up to the last `</x-dc>` (to the end while a file is still arriving);
 * - parses the template the way `<template>.innerHTML` does and numbers every element
 *   depth-first from 0 (its tid, as view-state.md and ShepherdProtocol's DesignTemplate do);
 * - hoists `<helmet>`'s style, link and meta into the head;
 * - compiles the `<script type="text/x-dc" data-dc-script>` class (`class Component extends
 *   DCLogic`), and renders the template with React from `renderVals()`: `{{dotted.holes}}` as
 *   text, whole-value and interpolated attributes, `<sc-if>`, `<sc-for>`, `<dc-import>`, and
 *   `hint-*` placeholders while values are missing;
 * - mounts a design system's components with `<x-import component-from-global-scope="Ns.Name">`:
 *   the component a bundle the board loads (`ds/<ns>/…`) put on `window`, its attributes as
 *   props and its content as children;
 * - stamps each rendered element with `data-dc-tid` (an imported board's elements carry
 *   `data-dc-owner`, the tid of the `<dc-import>` that holds them);
 * - tells Shepherd's bridge (an isolated world) what happened through `shepherd-dc` DOM events,
 *   and takes `replaceSource(source)` to re-render in place, without navigating;
 * - answers the bridge's `shepherd-dc-describe` events with what the board's template says of an
 *   element: its path (view-state.md's child-index chain), its kind, its label (the template's
 *   own text, holes as written) and its `data-el` name, for the canvas's selection;
 * - hands the board its top-level props: the values canvas.json's `tweaks` key holds for it
 *   (Shepherd's Tweak), read at boot and given again with `replaceSource`;
 * - previews a tweak in place while it is dragged (`previewStyle`, `setProps`) and puts the
 *   board back as it was (`endPreview`) when the tweak isn't kept.
 */
(function () {
  'use strict';
  if (window.__shepherdDC) return;

  var React = window.React;
  var ReactDOM = window.ReactDOM;
  // The page's own globals before any design system's bundle loads (the runtime comes first in
  // the head): an `<x-import>` reaches only globals a bundle added after it.
  var PAGE_GLOBALS = new Set(Object.getOwnPropertyNames(window));
  var h = React.createElement;
  var Fragment = React.Fragment;

  var SVG_NS = 'http://www.w3.org/2000/svg';
  var MATH_NS = 'http://www.w3.org/1998/Math/MathML';

  // The template stays hidden until it is rendered: the page's parser has already laid it out
  // as plain body content.
  var hide = document.createElement('style');
  hide.setAttribute('data-dc-runtime', '');
  hide.textContent = 'x-dc{display:none!important}';
  (document.head || document.documentElement).appendChild(hide);

  // MARK: Messages to the bridge

  function emit(type, fields) {
    var message = { type: type };
    if (fields) for (var key in fields) message[key] = fields[key];
    try {
      document.dispatchEvent(new CustomEvent('shepherd-dc', { detail: JSON.stringify(message) }));
    } catch (_) { /* never throw into a board */ }
  }

  function describe(error) {
    if (error == null) return 'unknown error';
    if (typeof error === 'string') return error;
    var text = error.message ? String(error.message) : String(error);
    return error.name && error.name !== 'Error' ? error.name + ': ' + text : text;
  }

  function report(phase, error) {
    emit('error', { phase: phase, message: describe(error) });
  }

  // MARK: Reading a board

  /** The parts of a board's source: its template, its logic, its props and its title. */
  function readBoard(source) {
    var open = /<x-dc(?=[\s>])[^>]*>/i.exec(source);
    if (!open) return null;
    var start = open.index + open[0].length;
    var end = source.toLowerCase().lastIndexOf('</x-dc>');
    if (end < start) end = source.length;
    var board = { fragment: source.slice(start, end), script: '', props: null, title: null };
    var after = new DOMParser().parseFromString(source.slice(end), 'text/html');
    var script = after.querySelector('script[data-dc-script]') || after.querySelector('script[type="text/x-dc"]');
    if (script) {
      board.script = script.textContent || '';
      var raw = script.getAttribute('data-props');
      if (raw) {
        try { board.props = JSON.parse(raw); } catch (error) { report('props', error); }
      }
    }
    var head = new DOMParser().parseFromString(source.slice(0, open.index), 'text/html');
    var title = head.querySelector('title');
    if (title) board.title = title.textContent;
    return board;
  }

  // MARK: Holes

  var HOLE = /\{\{([\s\S]*?)\}\}/g;

  function parseExpression(raw) {
    var text = raw.trim();
    if (text === 'true') return { literal: true };
    if (text === 'false') return { literal: false };
    if (text === 'null') return { literal: null };
    if (text === 'undefined') return { literal: undefined };
    if (/^-?\d+(\.\d+)?$/.test(text)) return { literal: Number(text) };
    var quoted = /^'([^']*)'$/.exec(text) || /^"([^"]*)"$/.exec(text);
    if (quoted) return { literal: quoted[1] };
    if (/^[A-Za-z_$][\w$]*(\.[\w$]+)*$/.test(text)) return { path: text.split('.') };
    // Anything else (an expression) renders nothing, as the format says it fails silently.
    return { invalid: text };
  }

  /** Text split around its holes, or null when it has none. */
  function parseParts(text) {
    if (text.indexOf('{{') < 0) return null;
    var parts = [];
    var last = 0;
    var match;
    HOLE.lastIndex = 0;
    while ((match = HOLE.exec(text))) {
      if (match.index > last) parts.push(text.slice(last, match.index));
      parts.push(parseExpression(match[1]));
      last = HOLE.lastIndex;
    }
    if (last < text.length) parts.push(text.slice(last));
    return parts;
  }

  function lookup(expression, scope) {
    if ('literal' in expression) return expression.literal;
    if (!expression.path) return undefined;
    var head = expression.path[0];
    var value;
    var found = false;
    for (var loop = scope.loop; loop; loop = loop.parent) {
      if (Object.prototype.hasOwnProperty.call(loop.vars, head)) {
        value = loop.vars[head];
        found = true;
        break;
      }
    }
    if (!found) value = scope.vals == null ? undefined : scope.vals[head];
    for (var i = 1; i < expression.path.length; i++) {
      if (value == null) return undefined;
      value = value[expression.path[i]];
    }
    return value;
  }

  function asText(value) {
    if (value == null || typeof value === 'boolean' || typeof value === 'function') return '';
    return String(value);
  }

  /** A whole-value attribute (`x="{{ path }}"`) is the raw value; anything else is a string. */
  function evaluate(parts, scope) {
    if (parts.length === 1 && typeof parts[0] !== 'string') return lookup(parts[0], scope);
    var text = '';
    for (var i = 0; i < parts.length; i++) {
      text += typeof parts[i] === 'string' ? parts[i] : asText(lookup(parts[i], scope));
    }
    return text;
  }

  function interpolate(parts, scope) {
    if (typeof parts === 'string') return parts;
    var text = '';
    for (var i = 0; i < parts.length; i++) {
      text += typeof parts[i] === 'string' ? parts[i] : asText(lookup(parts[i], scope));
    }
    return text;
  }

  // MARK: The template

  var HELMET_TAGS = { style: true, link: true, meta: true };

  /**
   * Parses a template and numbers its elements as view-state.md does: depth-first, every
   * element counted (helmet, sc-*, dc-import included), text and comments not.
   */
  function compileTemplate(fragment) {
    var template = document.createElement('template');
    template.innerHTML = fragment;
    var next = 0;
    var helmets = [];
    var elements = [];

    function children(parent, parentPath) {
      var out = [];
      var nodes = parent.childNodes;
      var index = 0;
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        if (node.nodeType === 3) {
          out.push({ text: parseParts(node.data) || node.data, raw: node.data });
          continue;
        }
        if (node.nodeType !== 1) continue;
        var element = {
          tid: next++,
          tag: node.localName,
          name: node.localName.toLowerCase(),
          foreign: node.namespaceURI === SVG_NS || node.namespaceURI === MATH_NS,
          attrs: [],
          children: null,
          // view-state.md's path: the top-level index first, then each element-child index.
          path: parentPath.concat(index++)
        };
        elements[element.tid] = element;
        for (var a = 0; a < node.attributes.length; a++) {
          var attribute = node.attributes[a];
          element.attrs.push({ name: attribute.name, value: attribute.value, parts: parseParts(attribute.value) });
        }
        element.children = children(node.localName === 'template' ? node.content : node, element.path);
        if (element.name === 'helmet') helmets.push(element);
        out.push(element);
      }
      return out;
    }

    var nodes = children(template.content, []);
    return { nodes: nodes, helmets: helmets, count: next, elements: elements };
  }

  // MARK: Describing an element

  var IMAGES = { img: true, picture: true, video: true, canvas: true, image: true };
  var LINES = { line: true, polyline: true, hr: true };
  var SHAPES = {
    div: true, section: true, article: true, aside: true, main: true, header: true, footer: true, nav: true,
    figure: true, form: true, ul: true, ol: true, li: true, table: true, svg: true, rect: true, circle: true,
    ellipse: true, polygon: true, path: true
  };
  var FIELDS = { input: true, textarea: true, select: true };
  var SILENT = { style: true, script: true, title: true, helmet: true };

  function templateAttribute(element, name) {
    var found = attribute(element, name);
    return found ? found.value : null;
  }

  /** The template's own text inside an element, holes as written, on one line. */
  function templateText(element) {
    var text = '';
    (function walk(nodes) {
      for (var i = 0; i < nodes.length && text.length < 400; i++) {
        var node = nodes[i];
        if (node.text !== undefined) text += ' ' + node.raw;
        else if (!SILENT[node.name]) walk(node.children);
      }
    })(element.children);
    return text.replace(/\s+/g, ' ').trim();
  }

  function hasOwnText(element) {
    return element.children.some(function (node) { return node.text !== undefined && node.raw.trim() !== ''; });
  }

  /** view-state.md's kind: text (a typeable container too), image, shape, line or other. */
  function kindOf(element) {
    if (IMAGES[element.name]) return 'image';
    if (LINES[element.name]) return 'line';
    if (FIELDS[element.name] || templateAttribute(element, 'contenteditable') != null || hasOwnText(element)) return 'text';
    if (SHAPES[element.name]) return 'shape';
    return 'other';
  }

  /** What the board's template says of element `tid`, or null when it has none. */
  function describeElement(tid) {
    var element = current && current.template ? current.template.elements[tid] : null;
    if (!element) return null;
    var label = element.name === 'img' ? templateAttribute(element, 'alt') : templateText(element);
    var named = element.name === 'dc-import' ? templateAttribute(element, 'name')
      : element.name === 'x-import' ? templateAttribute(element, 'component-from-global-scope')
      : templateAttribute(element, 'data-el');
    return {
      tid: tid,
      path: element.path,
      tag: element.name,
      kind: element.name === 'dc-import' || element.name === 'x-import' ? 'other' : kindOf(element),
      label: label ? String(label).slice(0, 200) : null,
      el: named && named.indexOf('{{') < 0 ? String(named).slice(0, 200) : null
    };
  }

  document.addEventListener('shepherd-dc-describe', function (event) {
    var tid = Number(typeof event.detail === 'string' ? event.detail : NaN);
    var found = Number.isInteger(tid) && tid >= 0 ? describeElement(tid) : null;
    emit('described', found || { tid: tid, missing: true });
  }, true);

  function attribute(element, name) {
    for (var i = 0; i < element.attrs.length; i++) if (element.attrs[i].name === name) return element.attrs[i];
    return null;
  }

  function attributeValue(element, name, scope) {
    var found = attribute(element, name);
    if (!found) return undefined;
    return found.parts ? evaluate(found.parts, scope) : found.value;
  }

  // MARK: Helmet

  /**
   * Puts a board's helmet (style, link and meta) in the head, replacing what `key` put there.
   * The board's own helmet keeps its tids; an imported board's helmet carries none.
   */
  function hoistHelmet(key, helmets, stampTids) {
    var signature = JSON.stringify(helmets.map(function (helmet) { return helmet.children; }));
    var existing = document.head.querySelectorAll('[data-dc-helmet]');
    var current = [];
    for (var i = 0; i < existing.length; i++) if (existing[i].getAttribute('data-dc-helmet') === key) current.push(existing[i]);
    if (current.length && current[0].__dcSignature === signature) return;
    current.forEach(function (node) { node.remove(); });
    var added = [];
    helmets.forEach(function (helmet) {
      helmet.children.forEach(function (child) {
        if (child.text !== undefined || !HELMET_TAGS[child.name]) return;
        var node = document.createElement(child.name);
        child.attrs.forEach(function (attr) {
          if (attr.name.indexOf('on') === 0) return;
          try { node.setAttribute(attr.name, attr.parts ? interpolate(attr.parts, { vals: null, loop: null }) : attr.value); } catch (_) { }
        });
        node.textContent = child.children.map(function (text) {
          return text.text !== undefined ? interpolate(text.text, { vals: null, loop: null }) : '';
        }).join('');
        if (stampTids) node.setAttribute('data-dc-tid', String(child.tid));
        node.setAttribute('data-dc-helmet', key);
        document.head.appendChild(node);
        added.push(node);
      });
    });
    if (added.length) added[0].__dcSignature = signature;
  }

  // MARK: Attributes → React props

  var EVENTS = {};
  [
    'Copy', 'Cut', 'Paste', 'CompositionEnd', 'CompositionStart', 'CompositionUpdate', 'KeyDown', 'KeyPress',
    'KeyUp', 'Focus', 'Blur', 'Change', 'BeforeInput', 'Input', 'Invalid', 'Reset', 'Submit', 'Error', 'Load',
    'Click', 'ContextMenu', 'DoubleClick', 'Drag', 'DragEnd', 'DragEnter', 'DragExit', 'DragLeave', 'DragOver',
    'DragStart', 'Drop', 'MouseDown', 'MouseEnter', 'MouseLeave', 'MouseMove', 'MouseOut', 'MouseOver', 'MouseUp',
    'PointerDown', 'PointerMove', 'PointerUp', 'PointerCancel', 'GotPointerCapture', 'LostPointerCapture',
    'PointerEnter', 'PointerLeave', 'PointerOver', 'PointerOut', 'Select', 'TouchCancel', 'TouchEnd', 'TouchMove',
    'TouchStart', 'Scroll', 'Wheel', 'Abort', 'CanPlay', 'CanPlayThrough', 'DurationChange', 'Emptied',
    'Encrypted', 'Ended', 'LoadedData', 'LoadedMetadata', 'LoadStart', 'Pause', 'Play', 'Playing', 'Progress',
    'RateChange', 'Seeked', 'Seeking', 'Stalled', 'Suspend', 'TimeUpdate', 'VolumeChange', 'Waiting',
    'AnimationStart', 'AnimationEnd', 'AnimationIteration', 'TransitionEnd', 'Toggle'
  ].forEach(function (name) {
    EVENTS[('on' + name).toLowerCase()] = 'on' + name;
    EVENTS[('on' + name + 'Capture').toLowerCase()] = 'on' + name + 'Capture';
  });
  EVENTS.ondblclick = 'onDoubleClick';

  // Boolean attributes React knows by their lower-case name: written bare in markup (the value
  // is ""), they mean true. Every other bare attribute passes through as written.
  var BOOLEANS = {
    async: true, checked: true, controls: true, default: true, defer: true, disabled: true, hidden: true,
    loop: true, multiple: true, muted: true, open: true, required: true, reversed: true, scoped: true,
    seamless: true, selected: true
  };
  var VOID = {
    area: true, base: true, br: true, col: true, embed: true, hr: true, img: true, input: true, link: true,
    meta: true, param: true, source: true, track: true, wbr: true
  };

  var styleCache = new Map();

  /** An inline style as a React style object, for elements that can't take the text. */
  function parseStyle(text) {
    var cached = styleCache.get(text);
    if (cached) return cached;
    var style = {};
    var depth = 0;
    var quote = null;
    var start = 0;
    var declarations = [];
    for (var i = 0; i <= text.length; i++) {
      var c = text[i];
      if (i === text.length || (c === ';' && depth === 0 && !quote)) {
        declarations.push(text.slice(start, i));
        start = i + 1;
      } else if (quote) {
        if (c === quote) quote = null;
      } else if (c === '"' || c === "'") {
        quote = c;
      } else if (c === '(') {
        depth++;
      } else if (c === ')') {
        depth = Math.max(0, depth - 1);
      }
    }
    declarations.forEach(function (declaration) {
      var colon = declaration.indexOf(':');
      if (colon < 0) return;
      var name = declaration.slice(0, colon).trim();
      var value = declaration.slice(colon + 1).trim().replace(/\s*!\s*important\s*$/i, '');
      if (!name || !value) return;
      if (name.indexOf('--') === 0) {
        style[name] = value;
      } else {
        style[name.toLowerCase().replace(/^-ms-/, 'ms-').replace(/-([a-z])/g, function (_, letter) { return letter.toUpperCase(); })] = value;
      }
    });
    if (styleCache.size > 4000) styleCache.clear();
    styleCache.set(text, style);
    return style;
  }

  function setProp(props, element, name, value, bound, custom) {
    if (name === 'key') { props.key = value; return; }
    if (name === 'ref') {
      if (typeof value === 'function' || (value && typeof value === 'object')) props.ref = value;
      return;
    }
    if (name.length > 2 && name[0] === 'o' && name[1] === 'n') {
      // Only a function bound from renderVals() handles an event; handler text never runs.
      var event = EVENTS[name];
      if (event && typeof value === 'function') props[event] = value;
      return;
    }
    if (name === 'style') {
      if (value == null || value === false || value === '') return;
      if (typeof value === 'object') { props.style = value; return; }
      if (element.foreign) { props.style = parseStyle(String(value)); return; }
      // An HTML element takes the style text as written: React passes an attribute it doesn't
      // know through to setAttribute, which lower-cases the name on HTML elements. The browser
      // then reads the text itself (shorthands, !important, prefixes) exactly as the file does.
      props.STYLE = String(value);
      return;
    }
    if (name === 'class') { props[custom ? 'class' : 'className'] = value; return; }
    if (name === 'for' && !custom) { props.htmlFor = value; return; }
    if (!bound && (element.name === 'input' || element.name === 'textarea' || element.name === 'select')) {
      // Written values are where a control starts, not values it is held to.
      if (name === 'value') { props.defaultValue = value; return; }
      if (name === 'checked') { props.defaultChecked = true; return; }
    }
    if (!bound && !custom && BOOLEANS[name]) { props[name] = true; return; }
    props[name] = value;
  }

  // MARK: Rendering

  function stamp(props, element, context) {
    if (context.owner == null) props['data-dc-tid'] = element.tid;
    else props['data-dc-owner'] = context.owner;
  }

  function renderNodes(nodes, scope, context) {
    var out = [];
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      if (node.text !== undefined) {
        out.push(interpolate(node.text, scope));
      } else {
        out.push(renderElement(node, scope, context));
      }
    }
    return out;
  }

  function textOf(nodes, scope) {
    var text = '';
    for (var i = 0; i < nodes.length; i++) if (nodes[i].text !== undefined) text += interpolate(nodes[i].text, scope);
    return text;
  }

  function renderElement(element, scope, context) {
    switch (element.name) {
      case 'helmet': return null;
      case 'sc-if': return renderIf(element, scope, context);
      case 'sc-for': return renderFor(element, scope, context);
      case 'dc-import': return renderImport(element, scope, context);
      case 'x-import': return renderGlobalImport(element, scope, context);
    }
    var custom = element.tag.indexOf('-') >= 0;
    var props = {};
    for (var i = 0; i < element.attrs.length; i++) {
      var attr = element.attrs[i];
      setProp(props, element, attr.name, attr.parts ? evaluate(attr.parts, scope) : attr.value, !!attr.parts, custom);
    }
    stamp(props, element, context);
    if (VOID[element.name]) return h(element.tag, props);
    if (element.name === 'textarea') {
      if (!('value' in props) && !('defaultValue' in props)) props.defaultValue = textOf(element.children, scope);
      return h('textarea', props);
    }
    if (element.name === 'style' || element.name === 'title' || element.name === 'script') {
      return h.apply(null, [element.tag, props].concat(textOf(element.children, scope) || []));
    }
    return h.apply(null, [element.tag, props].concat(renderNodes(element.children, scope, context)));
  }

  function renderIf(element, scope, context) {
    var value = attributeValue(element, 'value', scope);
    if (value === undefined && attribute(element, 'hint-placeholder-val')) {
      value = attributeValue(element, 'hint-placeholder-val', scope);
    }
    if (!value) return null;
    return h.apply(null, [Fragment, null].concat(renderNodes(element.children, scope, context)));
  }

  function renderFor(element, scope, context) {
    var list = attributeValue(element, 'list', scope);
    var as = attribute(element, 'as');
    var name = as && as.value.trim() ? as.value.trim() : 'item';
    var items;
    if (Array.isArray(list)) {
      items = list;
    } else if (list === undefined) {
      var count = Number(attributeValue(element, 'hint-placeholder-count', scope)) || 0;
      items = [];
      for (var n = 0; n < Math.min(Math.max(count, 0), 100); n++) items.push(undefined);
    } else if (list && typeof list[Symbol.iterator] === 'function' && typeof list !== 'string') {
      items = Array.from(list);
    } else {
      items = [];
    }
    return items.map(function (item, index) {
      var vars = { $index: index };
      vars[name] = item;
      var inner = { vals: scope.vals, loop: { vars: vars, parent: scope.loop } };
      return h.apply(null, [Fragment, { key: index }].concat(renderNodes(element.children, inner, context)));
    });
  }

  // MARK: Components

  var DEFINITION = typeof Symbol === 'function' ? Symbol('shepherd.dc.definition') : '__shepherdDCDefinition';

  /** Where a component renders: its file, the dc-import that holds it, and the imports above. */
  var Frame = React.createContext(null);

  class DCLogic extends React.Component {
    constructor(props) {
      super(props);
      this.state = {};
    }

    renderVals() {
      return {};
    }

    render() {
      var definition = this.constructor[DEFINITION];
      if (!definition) return null;
      var vals = this.renderVals();
      var context = this.context || { owner: null, chain: [], url: location.href };
      return h.apply(null, [Fragment, null].concat(renderNodes(
        definition.template.nodes, { vals: vals == null ? {} : vals, loop: null }, context)));
    }
  }
  DCLogic.contextType = Frame;

  function blankComponent() {
    return class extends DCLogic {};
  }

  function compileComponent(script, label) {
    if (!script || !script.trim()) return { Component: blankComponent() };
    try {
      var factory = new Function('DCLogic', 'React',
        '"use strict";\n' + script + '\n;return typeof Component === "function" ? Component : null;\n//# sourceURL=' +
        encodeURI(label) + '.logic.js');
      var Component = factory(DCLogic, React);
      if (!Component || !(Component.prototype instanceof DCLogic)) {
        throw new Error('the board script defines no class Component extends DCLogic');
      }
      return { Component: Component };
    } catch (error) {
      return { Component: null, error: error };
    }
  }

  // MARK: Imports

  var imports = new Map();
  var importListeners = new Map();
  var importsInFlight = 0;
  var importsIdle = [];

  function notifyImport(url) {
    var listeners = importListeners.get(url);
    if (listeners) listeners.forEach(function (listener) { listener(); });
  }

  function settleImport() {
    importsInFlight--;
    if (importsInFlight === 0) {
      var waiting = importsIdle;
      importsIdle = [];
      waiting.forEach(function (resolve) { resolve(); });
    }
  }

  function whenImportsIdle() {
    if (importsInFlight === 0) return Promise.resolve();
    return new Promise(function (resolve) { importsIdle.push(resolve); });
  }

  /** The URL a `<dc-import name>` names: a sibling board, never outside the design's project. */
  function importURL(name, from) {
    if (typeof name !== 'string' || !/^[A-Za-z0-9_][A-Za-z0-9_.-]*(\/[A-Za-z0-9_][A-Za-z0-9_.-]*)*$/.test(name)) return null;
    if (name.indexOf('..') >= 0) return null;
    var url;
    try { url = new URL(name + '.dc.html', from); } catch (_) { return null; }
    if (url.protocol !== location.protocol || url.host !== location.host || url.pathname.indexOf('/project/') !== 0) return null;
    url.hash = '';
    url.search = '';
    return url.href;
  }

  function loadImport(url) {
    if (imports.has(url)) return;
    imports.set(url, { state: 'loading' });
    importsInFlight++;
    fetch(url, { cache: 'no-store' }).then(function (response) {
      if (!response.ok) throw new Error('no board at ' + decodeURI(new URL(url).pathname.replace(/^\/project\//, '')));
      return response.text();
    }).then(function (source) {
      var board = readBoard(source);
      if (!board) throw new Error('the imported board has no <x-dc> template');
      var compiled = compileComponent(board.script, url);
      if (compiled.error) throw compiled.error;
      var template = compileTemplate(board.fragment);
      compiled.Component[DEFINITION] = { template: template, url: url };
      hoistHelmet('import:' + url, template.helmets, false);
      imports.set(url, { state: 'ready', Component: compiled.Component });
    }).catch(function (error) {
      report('import', error);
      imports.set(url, { state: 'failed' });
    }).then(function () {
      notifyImport(url);
      settleImport();
    });
  }

  function subscribeImport(url, listener) {
    var listeners = importListeners.get(url);
    if (!listeners) importListeners.set(url, listeners = new Set());
    listeners.add(listener);
    return function () { listeners.delete(listener); };
  }

  function hintBox(hint) {
    var style = {};
    if (typeof hint === 'string' && hint.indexOf(',') > 0) {
      var sizes = hint.split(',');
      style.width = sizes[0].trim();
      style.height = sizes[1].trim();
    }
    return style;
  }

  function ImportSlot(props) {
    var frame = props.frame;
    var url = props.url;
    var entry = React.useSyncExternalStore(
      React.useCallback(function (listener) { return url ? subscribeImport(url, listener) : function () { }; }, [url]),
      function () { return url ? imports.get(url) : undefined; });
    var owner = frame.owner == null ? props.tid : frame.owner;
    if (!entry || entry.state !== 'ready') {
      return h('div', { 'data-dc-owner': owner, 'data-dc-placeholder': '', style: hintBox(props.hint) });
    }
    return h(Frame.Provider, { value: { owner: owner, chain: frame.chain.concat(url), url: url } },
      h(entry.Component, props.childProps));
  }

  function camelCase(name) {
    return name.replace(/-([a-z0-9])/g, function (_, letter) { return letter.toUpperCase(); });
  }

  function renderImport(element, scope, context) {
    var name = attributeValue(element, 'name', scope);
    var hint = attributeValue(element, 'hint-size', scope);
    var childProps = {};
    element.attrs.forEach(function (attr) {
      if (attr.name === 'name' || attr.name.indexOf('hint-') === 0) return;
      childProps[camelCase(attr.name)] = attr.parts ? evaluate(attr.parts, scope) : attr.value;
    });
    var url = importURL(name, context.url);
    if (url && context.chain.indexOf(url) >= 0) {
      report('import', new Error('a board imports itself: ' + name));
      url = null;
    } else if (url && context.chain.length > 8) {
      report('import', new Error('imports nest more than 8 deep at ' + name));
      url = null;
    } else if (url) {
      loadImport(url);
    } else {
      report('import', new Error('not a board name: ' + String(name)));
    }
    return h(ImportSlot, { url: url, frame: context, tid: element.tid, hint: hint, childProps: childProps });
  }

  // MARK: Design-system components

  var GLOBAL_PATH = /^[A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*){1,5}$/;
  var NOT_EXPORTS = new Set(['__proto__', 'prototype', 'constructor']);

  /** The component `Ns.Name` names: a global a design system's bundle added, then its own properties. */
  function globalComponent(path) {
    if (typeof path !== 'string' || !GLOBAL_PATH.test(path)) return null;
    var parts = path.split('.');
    if (PAGE_GLOBALS.has(parts[0])) return null;
    var value = window;
    for (var i = 0; i < parts.length; i++) {
      if (NOT_EXPORTS.has(parts[i]) || value == null) return null;
      var holder = Object(value);
      if (!Object.prototype.hasOwnProperty.call(holder, parts[i])) return null;
      value = holder[parts[i]];
    }
    if (typeof value === 'function') return value;
    if (value && typeof value === 'object' && value.$$typeof) return value;
    return null;
  }

  /** A component that fails to render draws nothing and says why; the board goes on. */
  class ComponentBoundary extends React.Component {
    constructor(props) {
      super(props);
      this.state = { failed: false };
    }

    static getDerivedStateFromError() {
      return { failed: true };
    }

    componentDidCatch(error) {
      report('component', new Error(this.props.path + ': ' + describe(error)));
    }

    render() {
      return this.state.failed ? null : this.props.children;
    }
  }

  /** Marks what a component drew as the `<x-import>`'s, so selection names the import. */
  function claim(slot, owner) {
    var walker = document.createTreeWalker(slot, NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (node) {
        if (node.hasAttribute('data-dc-x-import')) return NodeFilter.FILTER_REJECT;
        if (node.hasAttribute('data-dc-tid') || node.hasAttribute('data-dc-owner')) return NodeFilter.FILTER_SKIP;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var node;
    while ((node = walker.nextNode())) node.setAttribute('data-dc-owner', String(owner));
  }

  function GlobalSlot(props) {
    var ref = React.useRef(null);
    var owner = props.owner;
    React.useLayoutEffect(function () {
      var slot = ref.current;
      if (!slot) return undefined;
      claim(slot, owner);
      var observer = new MutationObserver(function () { claim(slot, owner); });
      observer.observe(slot, { childList: true, subtree: true });
      return function () { observer.disconnect(); };
    });
    var slotProps = { ref: ref, 'data-dc-x-import': props.path };
    // `style` on an `<x-import>` places and sizes its slot, which then answers for it; without
    // one the slot takes no box, and what the component drew answers instead.
    if (props.style) {
      slotProps.STYLE = String(props.style);
      if (props.stamp != null) slotProps['data-dc-tid'] = props.stamp;
      else slotProps['data-dc-owner'] = owner;
    } else {
      slotProps.STYLE = 'display: contents';
    }
    var inner = props.component
      ? h(ComponentBoundary, { path: props.path }, h.apply(null, [props.component, props.childProps].concat(props.children)))
      : null;
    return h('div', slotProps, inner);
  }

  function renderGlobalImport(element, scope, context) {
    var path = attributeValue(element, 'component-from-global-scope', scope);
    var component = globalComponent(path);
    if (!component) report('component', new Error('no design system component ' + String(path)));
    var childProps = {};
    var style = null;
    element.attrs.forEach(function (attr) {
      var name = attr.name;
      if (name === 'component-from-global-scope' || name.indexOf('hint-') === 0) return;
      var value = attr.parts ? evaluate(attr.parts, scope) : attr.value;
      if (name === 'style') { style = value; return; }
      if (name === 'key' || name === 'ref' || name === 'dangerouslysetinnerhtml') return;
      var prop = name === 'class' ? 'className' : name === 'for' ? 'htmlFor' : camelCase(name);
      // Only a function from renderVals() handles an event; handler text never runs.
      if (/^on[A-Z]/.test(prop) && typeof value !== 'function') return;
      childProps[prop] = value;
    });
    return h(GlobalSlot, {
      path: String(path), component: component, childProps: childProps, style: style,
      stamp: context.owner == null ? element.tid : null, owner: context.owner == null ? element.tid : context.owner,
      children: renderNodes(element.children, scope, context)
    });
  }

  // MARK: Props

  /** The board's path under the project, as canvas.json keys it. */
  function boardKey() {
    var path = location.pathname;
    if (path.indexOf('/project/') !== 0) return null;
    try { return decodeURIComponent(path.slice('/project/'.length)); } catch (_) { return null; }
  }

  function plainObject(value) {
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  }

  /** The board's tweaked props from canvas.json's text: `tweaks[<board path>]`. */
  function tweaksIn(text) {
    if (!text) return {};
    try {
      var canvas = plainObject(JSON.parse(text));
      var tweaks = canvas && plainObject(canvas.tweaks);
      var key = boardKey();
      return (tweaks && key && plainObject(tweaks[key])) || {};
    } catch (_) {
      return {};
    }
  }

  // MARK: The board

  class Host extends React.Component {
    constructor(props) {
      super(props);
      this.state = { failed: false };
      this.instance = null;
      var host = this;
      this.capture = function (instance) { host.instance = instance; };
    }

    static getDerivedStateFromError() {
      return { failed: true };
    }

    componentDidCatch(error) {
      report('render', error);
    }

    componentDidUpdate() {
      var carried = this.props.carry && this.props.carry.state;
      if (carried && this.instance && this.props.carry.pending) {
        this.props.carry.pending = false;
        this.instance.setState(carried);
      }
    }

    render() {
      if (this.state.failed) return null;
      return h(Frame.Provider, { value: this.props.frame },
        h(this.props.component, Object.assign({}, this.props.boardProps, { ref: this.capture })));
    }
  }

  var root = null;
  var host = null;
  var hostKey = 0;
  var current = null;

  function mount(board, props) {
    var compiled = compileComponent(board.script, location.pathname.split('/').pop());
    if (compiled.error) {
      report('logic', compiled.error);
      compiled.Component = blankComponent();
    }
    var template = compileTemplate(board.fragment);
    compiled.Component[DEFINITION] = { template: template, url: location.href };
    hoistHelmet('board', template.helmets, true);
    if (board.title != null) document.title = board.title;
    current = { Component: compiled.Component, script: board.script, carry: null, template: template, props: props || {} };
    root = ReactDOM.createRoot(document.body);
    render();
  }

  function render() {
    var element = h(Host, {
      key: hostKey,
      ref: function (instance) { host = instance; },
      component: current.Component,
      frame: { owner: null, chain: [location.href], url: location.href },
      boardProps: current.props,
      carry: current.carry
    });
    ReactDOM.flushSync(function () { root.render(element); });
  }

  /**
   * Re-renders the board from new source in place: no navigation, and its state is kept.
   * `props` (JSON text), when given, are its top-level props from now on.
   */
  function replaceSource(source, props) {
    if (!root || !current) return { ok: false, error: 'the board has not started' };
    var board = readBoard(String(source));
    if (!board) return { ok: false, error: 'the board has no <x-dc> template' };
    var Component = current.Component;
    var carry = null;
    if (board.script !== current.script) {
      var compiled = compileComponent(board.script, location.pathname.split('/').pop());
      if (compiled.error) {
        report('logic', compiled.error);
        return { ok: false, error: describe(compiled.error) };
      }
      Component = compiled.Component;
      var previous = host && host.instance;
      if (previous && previous.state) carry = { state: Object.assign({}, previous.state), pending: true };
    }
    var template;
    try {
      template = compileTemplate(board.fragment);
    } catch (error) {
      report('template', error);
      return { ok: false, error: describe(error) };
    }
    var nextProps = current.props;
    if (typeof props === 'string') nextProps = tweaksObject(props);
    Component[DEFINITION] = { template: template, url: location.href };
    hoistHelmet('board', template.helmets, true);
    if (board.title != null) document.title = board.title;
    var sameComponent = Component === current.Component;
    current = { Component: Component, script: board.script, carry: carry, template: template, props: nextProps };
    // What a preview changed is what the new source says now.
    previews = new Map();
    if (host && host.state.failed) hostKey++;
    render();
    if (sameComponent && host && host.instance) {
      ReactDOM.flushSync(function () { host.instance.forceUpdate(); });
    }
    emit('rendered');
    return { ok: true };
  }

  function tweaksObject(json) {
    try { return plainObject(JSON.parse(json)) || {}; } catch (_) { return {}; }
  }

  // MARK: Previews

  /** Each element a preview changed, with the values it had before: node → {property: [value, priority]}. */
  var previews = new Map();
  var PROPERTY = /^(--[A-Za-z0-9_-]{1,62}|[a-z][a-z-]{0,62})$/;
  var VALUE = /^[A-Za-z0-9 #.%(),_+\/-]{0,200}$/;

  /**
   * Shows style changes on the board's own elements without writing them: `changes` is
   * `[{tid, style: {property: value}}]`, an empty value taking the property out. Every rendering
   * of each element changes (a loop draws one element many times). Returns how many changed.
   */
  function previewStyle(changes) {
    if (!Array.isArray(changes)) return 0;
    var changed = 0;
    changes.forEach(function (change) {
      var tid = change && change.tid;
      var style = change && plainObject(change.style);
      if (!Number.isInteger(tid) || tid < 0 || !style) return;
      var nodes = document.querySelectorAll('[data-dc-tid="' + tid + '"]');
      for (var i = 0; i < nodes.length; i++) {
        var node = nodes[i];
        if (!node.style) continue;
        var saved = previews.get(node);
        if (!saved) previews.set(node, saved = {});
        for (var property in style) {
          var value = style[property];
          if (!PROPERTY.test(property) || typeof value !== 'string' || !VALUE.test(value)) continue;
          if (!(property in saved)) saved[property] = [node.style.getPropertyValue(property), node.style.getPropertyPriority(property)];
          if (value === '') node.style.removeProperty(property);
          else node.style.setProperty(property, value, saved[property][1]);
        }
        changed++;
      }
    });
    return changed;
  }

  /** Puts back every value a preview changed. */
  function endPreview() {
    previews.forEach(function (saved, node) {
      for (var property in saved) {
        if (saved[property][0] === '') node.style.removeProperty(property);
        else node.style.setProperty(property, saved[property][0], saved[property][1]);
      }
    });
    previews = new Map();
    return true;
  }

  /** The board's top-level props (JSON text), drawn at once: a data-props tweak being dragged. */
  function setProps(json) {
    if (!root || !current) return { ok: false, error: 'the board has not started' };
    current.props = tweaksObject(json);
    render();
    emit('rendered');
    return { ok: true };
  }

  /** Waits (at most three seconds) for imports, fonts and images, so a first look is whole. */
  function settle() {
    var images = function () {
      return Promise.all(Array.prototype.filter.call(document.images, function (image) { return !image.complete; })
        .map(function (image) {
          return new Promise(function (resolve) {
            image.addEventListener('load', resolve, { once: true });
            image.addEventListener('error', resolve, { once: true });
          });
        }));
    };
    var fonts = function () {
      void document.body.offsetHeight;
      return document.fonts ? document.fonts.ready : Promise.resolve();
    };
    var work = whenImportsIdle().then(fonts).then(images).then(fonts);
    return Promise.race([work, new Promise(function (resolve) { setTimeout(resolve, 3000); })]);
  }

  function boot() {
    // canvas.json holds the board's tweaked props; a canvas that can't be read gives none.
    var canvas = fetch('/project/canvas.json', { cache: 'no-store' }).then(function (response) {
      return response.ok ? response.text() : '';
    }).catch(function () { return ''; });
    fetch(location.href, { cache: 'no-store' }).then(function (response) {
      if (!response.ok) throw new Error('could not read the board (' + response.status + ')');
      return Promise.all([response.text(), canvas]);
    }).then(function (read) {
      var board = readBoard(read[0]);
      if (!board) throw new Error('the board has no <x-dc> template');
      mount(board, tweaksIn(read[1]));
      var preview = board.props && board.props.$preview;
      return settle().then(function () {
        var size = preview && typeof preview.width === 'number' && typeof preview.height === 'number'
          ? { width: preview.width, height: preview.height } : null;
        emit('booted', { preview: size });
      });
    }).catch(function (error) {
      report('boot', error);
      emit('booted', { preview: null });
    });
  }

  var api = Object.freeze({ replaceSource: replaceSource, previewStyle: previewStyle, endPreview: endPreview, setProps: setProps });
  Object.defineProperty(window, '__shepherdDC', { value: api, writable: false, configurable: false, enumerable: false });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  } else {
    boot();
  }
})();
