# The board format

A board is one `.dc.html` file: an ordinary HTML page whose visible part is a template inside
`<x-dc>`, rendered by the runtime that `./support.js` loads, plus an optional logic class that
feeds the template. Shepherd serves its own runtime at `./support.js`; the line only has to be
there, exactly as written below.

## A whole board

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Checkout funnel</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Figtree:wght@400;600&display=swap">
<style>
:root { --ink: #1c2330; --muted: #5b6474; --ground: #f7f6f2; --accent: #3056d3; --space-4: 16px; --radius-2: 8px; }
body { margin: 0; font-family: Figtree, system-ui, sans-serif; background: var(--ground); color: var(--ink); }
</style>
</helmet>
<main style="width: 1280px; height: 800px; box-sizing: border-box; padding: 48px; display: flex; flex-direction: column; gap: 24px">
<h1 style="margin: 0; font-size: 32px">Checkout funnel</h1>
<div style="display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px">
<sc-for list="{{ steps }}" as="step" hint-placeholder-count="4">
<section style="padding: 16px; border-radius: var(--radius-2); background: #ffffff">
<div style="color: var(--muted); font-size: 13px">{{ step.name }}</div>
<div style="font-size: 28px; font-weight: 600">{{ step.share }}</div>
</section>
</sc-for>
</div>
<sc-if value="{{ showNote }}" hint-placeholder-val="{{ true }}">
<p style="margin: 0; color: var(--muted)">Drop-off is measured from the step before.</p>
</sc-if>
<button type="button" onClick="{{ toggleNote }}" style="align-self: flex-start">Toggle note</button>
</main>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{"showNote":{"editor":"boolean","default":true},"$preview":{"width":1280,"height":800}}'>
class Component extends DCLogic {
  state = { hidden: false };
  renderVals() {
    return {
      steps: [
        { name: "Cart", share: "100%" },
        { name: "Shipping", share: "64%" },
        { name: "Payment", share: "41%" },
        { name: "Done", share: "37%" },
      ],
      showNote: (this.props.showNote ?? true) && !this.state.hidden,
      toggleNote: () => this.setState({ hidden: !this.state.hidden }),
    };
  }
}
</script>
</body>
</html>
```

## The rules that matter

- **The head line** `<script src="./support.js"></script>` is exact. Shepherd refuses a board
  without it.
- **One template** between `<x-dc>` and `</x-dc>`. `<helmet>` inside it holds what belongs in
  the page's head: `<style>` for page basics and custom properties, and at most a Google Fonts
  `css2` `<link>`.
- **The root element has a fixed size** (`width` and `height` in px, `box-sizing: border-box`),
  the same as `$preview` in `data-props` and the frame's `w` and `h` in canvas.json. Shepherd
  refuses a root whose size differs from `$preview`.
- **Style with inline `style="…"`** on each element; lay out with flex or grid and `gap`. A
  grid of equal tracks is written `grid-template-columns: repeat(N, minmax(0, 1fr))`.
- **Close every element and quote every attribute.** Use lower-case tag names.

## Templates

- `{{ a.b }}` is a lookup into what `renderVals()` returns (or a loop variable), never an
  expression: no operators, calls or `!`. Compute values in `renderVals()` and name them.
  A hole in text renders as escaped text.
- An attribute that is one hole, `onClick="{{ pick }}"`, receives the value itself (a
  function, a number); an attribute with text around a hole, `title="Step {{ n }}"`, becomes a
  string. `class` and `for` work as written. Events use the camel-case names (`onClick`,
  `onInput`, `onChange`).
- `<sc-for list="{{ items }}" as="item" hint-placeholder-count="3">` repeats its children with
  `item` and `$index` in scope. `<sc-if value="{{ flag }}" hint-placeholder-val="{{ true }}">`
  shows its children when the value is true. Always give the `hint-*` attributes: they draw
  placeholders while a board is still arriving.
- `<dc-import name="Card" item="{{ it }}" hint-size="320px,120px"></dc-import>` mounts the
  sibling board `Card.dc.html` in place; its other attributes become the child's props
  (`data-id` reads as `dataId`). Never self-close it, and don't name a prop `name`.
- Links between boards: `<a href="B.dc.html">` moves a playing prototype to board B. Style the
  `<a>` itself as the button.

## Logic

- The `<script type="text/x-dc" data-dc-script>` block holds `class Component extends DCLogic`
  in plain JavaScript: no imports, no TypeScript, no `render()`.
- `renderVals()` returns what the template reads: values, lists, and handlers. `this.props`,
  `this.state` and `this.setState` work as in a React class, and so do the lifecycle methods.
- Every piece of the interface is template markup. Never build it from script (`innerHTML`,
  `appendChild`), and never listen for keys on `window` or `document`.
- A board whose controls really work gets `"is_interactive": true` in its canvas.json frame.

## data-props

`data-props` on the script tag is single-quoted JSON: `&amp;` for `&` and `&#39;` for `'`
inside it. Each key declares a prop, `{"editor": "text" | "color" | "int" | "float" | "range" |
"boolean" | "enum" | null, "default": …}`, with `options` for enum and `min`, `max`, `step` for
numbers. Declare few: switches and values that cut across the whole board (a density, a
variant, one accent). Copy stays literal markup. `$preview: {"width", "height"}` is the board's
size. The viewer sets these in Tweak and the values arrive as props, so read each as
`this.props.x ?? <default>` in `renderVals()`.

## What a board may not hold

No `<iframe>`, `<object>` or `<embed>`; no `data:` URIs; no network beyond one Google Fonts
stylesheet. Shepherd refuses the first three outright.

## canvas.json

```json
{
  "v": 3,
  "title": "Checkout funnel",
  "boards": {
    "A.dc.html": { "x": 0, "y": 0, "w": 1280, "h": 800, "title": "A · Funnel first" },
    "A-phone.dc.html": { "x": 0, "y": 920, "w": 390, "h": 844, "title": "A · phone" }
  },
  "order": ["A.dc.html", "A-phone.dc.html"],
  "pages": [],
  "notes": {}
}
```

- `boards` holds one frame per board, keyed by its path: `x`, `y`, `w` and `h` in CSS px (`w`
  and `h` from 40 to 8000), a `title`, and optionally `page` (a page id), `is_interactive`, and
  `expand: "fill"` for a board that scrolls like a page.
- `order` lists the boards back to front. Shepherd keeps it in step with `boards`.
- `pages` (`[{"id", "name"}]`) group boards; `notes` hold titles and stickies on the canvas.
  Leave the user's notes, and every key you don't recognize, as they are.
- `tweaks` holds the data-props values the viewer set in Tweak, by board path and prop
  (`{"A.dc.html": {"density": "compact"}}`). Keep it; change it only when asked.
- Tweak also edits a board's inline styles in place (padding, radius, a token color), so a
  board can change between your reads: read it again before rewriting it.
- `canvas_update` changes it with a merge patch, so send only what changes:
  `{"boards": {"B.dc.html": {"x": 1360}}}` moves B, `{"boards": {"C.dc.html": null}}` removes C.

## Board paths

A board path ends in `.dc.html`; each `/`-separated part starts with a letter, digit or `_`
and holds only those, `.` and `-`. No spaces, no `..`, no leading `/`, nothing under `ds/`.
File names are unique regardless of case.

## Element ids

When someone points at an element, it arrives as `File.dc.html#<tid>:<path>`. Count every
element between `<x-dc>` and the last `</x-dc>` in source order from 0 (`<helmet>` and what it
holds, `<sc-for>`, `<sc-if>` and `<dc-import>` included; text and comments are not elements):
that count is the `tid`. The `path` names the same element by position: its top-level
ancestor's index among the template's top-level elements, then its index among each parent's
element children, joined by `/`. In the board above, `<helmet>` is `0:0`, its `<style>` is
`2:0/1`, `<main>` is `3:1`, and the `<h1>` is `4:1/0`.
