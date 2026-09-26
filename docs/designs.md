# Designs

The Design tool (an experiment, off by default) keeps each design as a canvas of HTML boards
that a design agent draws. This page covers the files, how they change, how a board is drawn,
the design agent's tools, and the Mac's screens. The remote protocol comes with a later change.

## The format

A design is a Claude Design canvas at the file level: `project/canvas.json` (version 3) and one
`project/<path>.dc.html` per board. Only the files are shared with claude.ai. Shepherd copies,
fetches and bundles none of its code; `./support.js` is a path each board keeps, and Shepherd
serves its own runtime there.

### The index

`DesignIndex` (ShepherdProtocol) reads `canvas.json`:

- **Typed fields:** `v`, `title`, `launch`, `pages`, `boards` (`x`, `y`, `w`, `h`, `title`,
  `page`, `is_interactive`, `expand`), `order`, `notes` and `designSystems`.
- **Every other key is kept verbatim, at every level:** `attachments`, `createdOnFiles`, a
  board's `frameless` or `guides`, the user's drawing notes. A known key whose value has another
  shape than expected is kept as it came, too.
- **Unreadable:** a version other than 3, a board keyed by a path outside the grammar, or a board
  without numbers for `x`, `y`, `w` and `h`.
- **Order:** `order` lists each board once, back to front. `inSync()` drops stray entries and
  appends unlisted boards by path.
- **Updates** (canvas_update) are JSON merge patches (RFC 7396): objects merge key by key, `null`
  removes a key, anything else replaces. Boards a patch adds join the end of `order` unless it
  sets `order`; boards it removes leave it.
- **Limits a write keeps:** `w` and `h` of 40–8000, stems unique regardless of case, at most 40
  pages and 200 notes with ids of `[A-Za-z0-9_-]{1,40}`, and at most 4 design systems whose
  folders match `[a-z0-9][a-z0-9_-]{0,63}`. Problems an imported index already has don't block
  an update; new ones do.

### Paths

`DesignPath` is the only way to name a board file:

- It ends in `.dc.html`, and each `/`-separated segment matches `[A-Za-z0-9_][A-Za-z0-9_.-]*`.
- A path holding `..` or `\`, or starting with `/`, is refused. So is one longer than 200
  characters, or one under `ds/`, which holds installed design systems.
- A board's stem (its file name without `.dc.html`) is what `<dc-import name>` names, and it is
  unique within a design regardless of case.
- Its view name, as a view record writes it, percent-encodes everything before `.dc.html` the
  way `encodeURIComponent` does (`flows/Cart.dc.html` reads `flows%2FCart.dc.html`).

### Element ids

A view record names an element `File.dc.html#<tid>:<path>`:

- The template is the text between a board's `<x-dc>` open tag and its last `</x-dc>`.
- `tid` numbers every element of it depth-first from 0: `<helmet>` and what it holds, `<sc-for>`,
  `<sc-if>` and `<dc-import>` included; text and comments are not elements.
- `path` names the same element by child position: its top-level ancestor's index first.
- The grammar caps `tid` at 9999, each index at 99 and the path at 9 numbers. An element past
  them has no id.

`DesignTemplate` is the Swift twin of the board runtime's numbering. It reads the template the
way an HTML parser builds it inside a `<template>`: void and raw-text elements, comments, SVG and
MathML (where `/>` closes), the end tags HTML implies (paragraphs, list items, options, headings,
table rows and cells, with the `tbody` a table implies), a nested form dropped, and stray end
tags. It does not model foster parenting (content misplaced inside a table), the rebuilding of
misnested formatting tags, or a template that starts with a table row. Boards don't write them.

`Tests/Designs/element-ids.json` is WebKit's own numbering (`template.innerHTML`) of the boards in
`Tests/Designs/boards/`: three from Shepherd's own canvas and two synthetic ones covering the
parser's edges. `DesignTemplate` matches it, and the runtime is held to the same file. When the
twin was written, it also matched WebKit on all 122 boards of the Shepherd canvas (37,235
elements).

## Storage

```text
<support>/designs/<designID>/
  project/canvas.json          the index
  project/<path>.dc.html       one per board
  revision                     Shepherd's revision counter for the design
  versions/<path>/<n>.dc.html  each board's last 20 earlier versions
```

- **The support directory**, so a design survives a worktree's deletion, stays with its edition
  (Dev, Prod, Nightly), and needs no repository write. Nothing writes a repository.
- **The record.** `ShepherdState.designs` holds each design's `id`, `name` (kept equal to the
  canvas `title`), `spaceID`, `agentID`, `systemNamespace`, `createdAt` and `lastActiveAt`.
  `Agent.designID` names the design an agent draws. Both decode with defaults from older files.
- **Live values.** A design's `boardCount` (its listed boards) is read from its files and
  broadcast, never written to `state.json`. A write moves `lastActiveAt` the same way; it reaches
  the file with the next structural change.
- **Soft references.** A design's agent and an agent's design may name something gone. Deleting
  an agent keeps its design, which starts a fresh agent when next opened. Deleting a design keeps
  its agent. A deleted space keeps its designs.
- **At startup** the server forgets a design whose folder has no `canvas.json` and clears
  references to what no longer exists. A canvas that is there but unreadable keeps its design. Which folders are gone is read on the design store's
  queue, not the server's. It then reads each design's board count.

## Writing

`DesignStore` (ShepherdSessions) owns the files. Every read and write runs on its own serial
queue; only the record's commit and the broadcast run on the server's queue. `SessionServer` is
the only writer, through named mutations:

| Mutation | What it does |
| --- | --- |
| `createDesign(_:)` | Makes the folder with a new canvas.json (`createdOnFiles` stamped, the name as `title`), then the record. A refused record removes the folder again |
| `renameDesign(_:to:)` | Renames the record and the canvas `title` |
| `deleteDesign(_:)` | Removes the record, clears `designID` on its agent, then removes the folder |
| `setDesignAgent(_:agentID:)` | Records which agent draws it |
| `writeDesignBoard(_:path:source:baseRevision:)` | Writes one board's whole source |
| `updateDesignIndex(_:patch:baseRevision:)` | Applies a canvas update. A new `title` renames the design |
| `writeDesignBoards(_:sources:baseRevision:)` | Writes several boards' whole sources as one change: every source is checked before any is written, and the revision moves once (Tweak's "Every <name>") |
| `restoreDesignVersions(_:_:ifCurrent:baseRevision:)` | Puts boards back to kept versions as one write, only while each board still has the hash `ifCurrent` names |

Reads are `designSnapshot(_:)` (the index, the revision, and every board file under `project/`
with its SHA-256, listed or not), `designBoard(_:path:)` and `designVersions(_:path:)`.

- **Revisions.** Each design has a revision that moves with every change to its files. It is kept
  on disk, so a base from before a relaunch still compares. A write naming a `baseRevision` the
  design has moved past is refused (`stale_revision`): read again and redo the change once. A
  write that changes nothing moves nothing.
- **Atomic.** Files are written to a temporary file and renamed into place. A board is never written
  through a linked folder that leads outside the design, and no folder is made there.
- **Index entries need files.** A board the index adds or changes must have its file. A board it
  removes loses its file, unless that file lies through a linked folder.
- **Checks** (`DesignBoardCheck`, ShepherdProtocol) before a board is written:
  - At most 900,000 bytes, so it fits the extension socket's 1 MiB frame.
  - The head line `<script src="./support.js"></script>`, exactly.
  - No `<iframe>`, `<object>` or `<embed>`, and no `data:` URI where a URL goes (an attribute,
    a script setting one, CSS `url()` or `@import`).
  - A template between `<x-dc>` and `</x-dc>`.
  - A root element sized in px the same as `$preview` in `data-props`, when both are given.
  - Warnings, passed back with the write: `innerHTML`, a key handler on the window or the
    document, and a missing `$preview`.
- **Limits:** 512 files per design, and no new board whose stem another board already has.

### Versions

- **Every write that replaces a board keeps what it held** as the board's next version, in
  `versions/<path>/<n>.dc.html` beside `project/` (so the board scheme never serves one and it is
  no board). Numbers count up from 1 per board; the newest 20 are kept.
- **A restore is a write.** `restoreDesignVersions` writes the kept content back, so what it
  replaced becomes a version too, and a restore can be undone. With `ifCurrent` it refuses a board
  whose hash moved since (`stale_revision`): an undo never takes back a later write.
- **A board the index removes loses its versions** with its file.

## The design agent

A design is drawn by an ordinary pi agent whose `Agent.designID` names it. Its launch adds
`-e shepherd-design.ts` and two variables: `SHEPHERD_DESIGN_ID` (the extension is inert without
it) and `SHEPHERD_DESIGN_SKILL_DIR`. Its working directory is its space's, so it reads the
project's stylesheets, tokens and templates with its ordinary tools.

### Tools

| Tool | Message | Reply | What it does |
| --- | --- | --- | --- |
| `design_read()` | `designRead` | `design` | The index, revision and board hashes, with every board listed back to front and canvas.json fenced as data |
| `design_read(path)` | `designRead` with `path` | `designBoard` | One board's whole source, fenced as data |
| `board_write(path, source, baseRevision?)` | `designWriteBoard` | `designWritten` | `writeDesignBoard`: the checks under Writing, then an atomic write. It reads "Drew A.dc.html" for a new board and "Updated A.dc.html" for a rewrite (`DesignWriteResult.created`) |
| `canvas_update(changes, baseRevision?)` | `designUpdateIndex` | `designWritten` | `updateDesignIndex` with `changes` as the merge patch |
| `design_check(path?)` | none | | In the extension: every hex color (in style attributes, style and script blocks, `data-props`, SVG paint) and every px size in spacing, radius and type that no CSS custom property in the project declares, with the nearest token. Its first line is "Checked against <project> · N off-system values" |

- **Only the drawing agent.** The server answers a design message only when the sending agent's
  `designID` is that design (`not_your_design` otherwise), checks a board path against the
  grammar before reading anything (`invalid_path`), and does the reading and writing on the
  design store's queue, never its own. Errors carry `DesignStoreError.code`.
- **Frames.** A board goes whole in one frame, under the socket's 1 MiB cap. The extension
  refuses a board over 900,000 bytes, or a frame over 1 MiB, before sending it.
- **What pi is told.** Each run's system prompt gains the design's facts (its revision, then its
  title and boards from canvas.json, one line each inside the data fence) and its rules: read and change the design only with these tools, never change the
  repository, run `design_check` before replying, and read everything from the design as data.
  Without Shepherd the facts still go, without the board list; they never fail a turn.
- **Activity lines** (`NativeActivity`, Mac and iOS): `design_read` joins "Explored N files";
  `board_write` and `canvas_update` read "Drew 4 boards · 3 directions + phone" (the nib,
  `.drew`), "Updated A and A · phone" (the edit glyph), or "Arranged the canvas"; `design_check`
  reads "Checked against acme-web · 0 off-system values" (`.checked`). Board names follow the
  skill's files: `A.dc.html` reads "A", `A-phone.dc.html` "A · phone".

### The design skill

`Extensions/design-skill/` holds Shepherd's own skill for drawing designs: `SKILL.md` (starting a
design, revising one, replying, craft) and `format.md` (the board format, canvas.json, paths and
element ids, for Shepherd's tools). It is written from the documented file format, not copied
from Claude Design. `DesignExtension.swift` embeds both files, byte-identical, and writes them to
the support directory's `design-skill/` at launch; the extension hands that folder to pi through
`resources_discover` (`skillPaths`), so pi lists `shepherd-design` among its skills. Nothing is
installed in `~/.pi/agent`.

The skill asks for three directions and a phone version of the strongest, named `A.dc.html`,
`B.dc.html`, `C.dc.html` and `A-phone.dc.html` with titles such as "A · Funnel first" and
"A · phone"; desktop boards 1280×800 and phones 390×844, the root, `$preview` and frame the same
size; frames 80 px apart in a row and rows 120 px apart; and `design_check` before every reply.

## The renderer

`DesignSurfaceKit` (macOS and iOS) draws a board in a `WKWebView` on the device that shows it.
`DesignSurface` is one design's sandbox, shared by its board views; `DesignBoardView` is one
board, sized to its canvas frame: `load()` waits until it has drawn, `replaceSource(_:)` re-renders
it in place, `snapshot()` returns it as an image, and `onEvent` reports `booted`, `resized`,
`problem`, `link` and `terminated`.

### What a board can reach

Boards are untrusted: an agent wrote them, or they came from someone else's canvas.

- **One scheme.** A board loads from `shepherd-design://<design>/project/<path>`, and the scheme
  serves only:
  - `project/…/support.js`: Shepherd's runtime (React, ReactDOM, then `shepherd-dc-runtime.js`),
    whatever the folder holds there.
  - `project/**`: the design's files, each segment by the path grammar, and only when the file
    resolves (links followed) inside `project/`.
  - `/_blob/<id>`: an upload in the design's `assets/`.

  Anything else is a 404, and a board that isn't there fails its load.
- **A data store per design,** non-persistent, so nothing a board stores outlives the surface or
  reaches another design.
- **Content rules** block every load except the scheme and Google Fonts
  (`fonts.googleapis.com/css2`, `fonts.gstatic.com`). A surface made with `network: .none` blocks
  those too.
- **A CSP on every response:** scripts only from the design and never inline (`'unsafe-eval'` is
  there because the runtime compiles a board's logic), styles from the design, inline, and Google
  Fonts, and no frames, workers, objects, forms, or connections elsewhere.
- **No navigation.** Every navigation is refused. An in-project link (relative to the board, or
  from the canvas root with a leading `/`) comes back to the host as `.link(path)`, and a
  `#fragment` link scrolls. No window opens, and nothing downloads.

### The runtime

`shepherd-dc-runtime.js` is written from `format.md` and `view-state.md` alone. No Claude Design
code is copied, fetched or imitated.

- **The template.** It reads the board's source, takes the text after the `<x-dc>` open tag up to
  the last `</x-dc>` (or to the end, while a file is still arriving), and parses it as
  `<template>.innerHTML` does.
- **Helmet.** `<helmet>`'s `style`, `link` and `meta` move to the head.
- **Logic.** The `<script type="text/x-dc" data-dc-script>` class (`class Component extends
  DCLogic`) is a React class component: `props`, `state`, `setState`, `forceUpdate` and the
  lifecycle, with `render()` drawing the template from `renderVals()`. A board without logic
  draws with no values. Logic that doesn't compile is reported, and the markup still draws.
- **Holes** are dotted lookups into `renderVals()` and the loops around them (`item`, `$index`),
  or literals. Anything else draws nothing, as the format says.
- **Attributes.** `x="{{ path }}"` is the raw value, `x="a {{p}} b"` a string, and `class` and
  `for` map to `className` and `htmlFor`.
  - An HTML element keeps its `style` text exactly as written: the browser reads it, shorthands
    and `!important` included. SVG and a bound style object go through React's style object.
  - Only a function from `renderVals()` handles an event (`onClick="{{ pick }}"`); handler text
    never runs.
  - A value written on a control (`<input value>`, `checked`) is where it starts, not a value it
    is held to.
- **Control flow.** `<sc-if value>` and `<sc-for list as>` work as the format describes. While a
  value is missing, `hint-placeholder-val` and `hint-placeholder-count` stand in.
- **Imports.** `<dc-import name="Card">` fetches the sibling `Card.dc.html` and draws it inline.
  Its other attributes become props, kebab-case to camelCase. `hint-size` sizes the placeholder
  until it arrives. A board that imports itself, or imports nested more than eight deep, draws the
  placeholder.
- **Element ids.** Every element is numbered depth-first from 0, `DesignTemplate`'s numbering,
  and each one drawn carries `data-dc-tid`, the hoisted helmet included. What an import draws
  carries `data-dc-owner`, the tid of the `<dc-import>` that holds it, since selection stops at
  the import. The runtime also keeps each element's path (view-state.md's child-index chain)
  and answers a `shepherd-dc-describe` event (the bridge's, with a tid) with what the template
  says of it: its path, its tag, its kind (`text` for text or a field, `image`, `line`, `shape`
  for a container or an SVG shape, else `other`), its label (the template's own text in it,
  holes as written, or an image's `alt`) and its `data-el` name (an import's board name).
- **Tweak previews.** `previewStyle([{tid, style}])` sets properties on every rendering of the
  board's own elements (a value past what a tweak writes is left out), `endPreview()` puts back
  exactly what they had, and `setProps(json)` redraws with new props; none writes anything.
  `DesignBoardView.previewStyle(_:)`, `previewProps(_:)` and `endPreview()` call them.
- **Not yet:**
  - `<x-import>` (design-system components) comes with design systems.
  - A board's top-level props are canvas.json's `tweaks` for it, read at boot and handed to
    `replaceSource` again (Tweak).
  - A hole in the helmet draws empty.
  - A change to a board's `<head>` lines, or to a board it imports, shows at its next `load()`,
    not on `replaceSource`.

### The bridge

A script in a content world of Shepherd's own (`shepherd-design-bridge`) is the only one that can
post to the view. It listens for the runtime's `shepherd-dc` events and the page's uncaught errors,
measures the board itself, and posts checked values: `booted` (what it drew, and its `$preview`),
`size` changes after that, and errors with their phase. `replaceSource` calls the runtime in the
board's own world, where a board can only affect itself.

- **Selection.** The bridge answers the canvas (in its own world only, `__shepherdBridge`):
  - `hitTest(x, y)` takes the element under a point of the board (its own CSS pixels) and walks
    up to the nearest one the view record's grammar can name (an element nested past it gives
    way to its ancestor; one inside an import, to the `<dc-import>`, measured as that instance's
    outermost drawing).
  - `element(tid)` finds an element again where it is drawn now (its first rendering), after a
    live reload.
  - Each answer is `{tid, path, x, y, width, height, kind, label, name, noun}`: the geometry
    measured by the bridge, the rest from the runtime's describe answer, and a noun for the
    canvas's tag read from how it is drawn (`button`, `link`, `field`, `text`, `image`, `line`,
    `component`; a container with a fill, border or shadow is a `card`, one without a `group`,
    an empty one a `shape`).
  - `DesignBoardView.hitTest(at:)` and `element(tid:)` return it checked as a `DesignHit`: a tid
    or path outside the grammar, or a rect that isn't finite and on the board, is none.
- **Live reload.** `replaceSource` keeps the document. The same logic keeps its state, and new
  logic takes over the old state. Logic that doesn't compile is refused, and the board keeps
  what it showed.
- **`booted`** comes once imports, fonts and images have settled, or after three seconds.
- **Snapshots** are `boardSize` from the top left, at the view's backing scale (1× offscreen).

### React

React 18.3.1's production UMD builds (`react`, `react-dom`) are the one vendored dependency, MIT
(`Resources/react/LICENSE`), loaded only inside board web views. They are the npm 18.3.1 tarballs'
files; the tarballs matched the registry's integrity hashes when vendored. `DesignRuntimeTests`
pins their SHA-256, so a changed file fails until it is vetted and pinned again.

### Fidelity

`DesignCanvasFidelityCheck` (opt-in, `SHEPHERD_DESIGN_CANVAS`) renders a whole canvas. Every one
of the 122 local boards of Shepherd's own canvas boots without a problem. Each draws its canvas
frame, except `ToolRows.dc.html`, whose root and `$preview` are 760×520 on a 760×700 frame.
Snapshots checked by eye draw as authored: Geist from Google Fonts, inline SVG icons, grids,
and the boards' dark and light surfaces.

## The app (Mac)

Settings ▸ Experiments ▸ Design tool (`AppSettings.designToolEnabled`, off by default) shows
everything here; off, the Designs pages don't open and designs have no rows. Designs made while it
was on keep their files and agents either way.

- **The Designs destination** sits between New thread and Automations. Its page
  (`DesignsPage`, NavDesigns) shows recent designs as cards, most recently edited first, each
  with its first board (the first in `order`) rendered off screen, and the systems they are drawn
  in. Until design systems exist, a design's system is its project's name.
- **Recents** lists a design as one row (the nib and "4 boards"), placed by its last change. Its
  agent has no row of its own and takes no ⌘-digit; the palette leaves it out too.
- **New design** (DZStart; the page's button, New thread's "Start a design") takes a brief and
  images and the project the design belongs to (the selected space, else the most recently used;
  the card's menu picks another). Send makes the design, starts its agent in that project with
  Settings' default model and the brief as its first message, and opens the design. The agent is
  named after the design and gets no namer.
- **A design's screen** (DZCanvas) is its agent's layout (`DesignLayoutView`): the canvas beside a
  420pt chat pane holding the agent's thread, whose composer has attach and Send only, under a
  toolbar with the breadcrumb, the design's system, and Present and Export (disabled until they
  are built). Opening a design whose agent is gone starts a fresh one. Switching away and back is
  a visibility flip, and a design's canvas (where it looks, the tool, the selected board) lasts
  the app's run. A design's screen has no terminal panel.
- **The canvas** (`NWDesignCanvas`) pans with two fingers, the Pan tool or space-drag, and zooms
  with a pinch or ⌘-scroll about the pointer. Comment is drawn disabled. It opens fitted to the
  boards, never above 100%.
- **Board labels** sit 24pt above their boards where the boards around them leave room
  (`NWLabelRoom`): where the row above is closer (rows 120 apart are about 20pt at the opening
  17%), a label moves down toward its frame, keeping at least 2pt; where not even that fits, it
  isn't drawn; and a label running past a narrow board stops before the next board along.

### Selection (Select)

- **A click** names what it lands on (`DesignScreenModel.pick`): on a board, the board's own hit
  test names the element under it (the board takes a live view to be asked); on a board's label,
  or where nothing is named, the board is picked whole; on the empty canvas the selection
  clears. Shift adds a pick, or takes a picked one back out. At most 20 are kept, most recent
  last.
- **Rings** are drawn natively over the boards from the reported rects times the zoom
  (`NWSelectionRing`): every selected element wears the 1.5pt `running` ring over its tint and
  the corner handles, and the latest its tag ("card · Checkout funnel": the noun, then its
  `data-el` name or its label). A board picked whole wears its frame's ring.
- **Hover.** The element under the pointer wears the ring alone. The board under the pointer
  takes a live view (`DesignLivePlan.wanted`'s `hovered`, after the selected board), and one
  hit test runs at a time with the pointer's latest place next.
- **After a rewrite** a live board reports that it drew new source, and its selected elements
  are found again where it draws them now (by tid, keeping the path); one it no longer draws
  leaves the selection. The board holding the latest pick stays live.

### The view record

The design screen publishes what it shows (`DesignScreenModel.viewRecord`, a
`DesignViewRecord` in ShepherdProtocol), and its chat's sends carry it (`NativeThreadStore`'s
`designContext`, where the host lists `designContext`; docs/native-thread.md › Design context):

- `mode`: `canvas` (`focused` waits for Present).
- `visibleBoards`: up to 20 boards whose frames are on screen, in canvas order.
- `selectedBoards`: up to 20 boards picked whole or holding a selected element.
- `selected`: up to 20 element ids, most recent last; `selection`: the last five with their
  `kind` and `label` (one line, cut to 60 characters).
- `dirty`: false; nothing on the screen is unwritten yet.
- Boards go by view name (`DesignPath.viewName`). A record breaks the grammar with more than
  its limits, a board that isn't a view name, a selection not among `selected`, an element on a
  board it doesn't select, a label on two lines or over 64 characters, or anything selected
  while focused. The host drops such a record whole and fences a good one ahead of the message
  as data; the skill tells the agent how to read it.

### Rendering

`DesignHost.swift` is the only app file that imports DesignSurfaceKit.

- **Live views.** A design on screen keeps at most five `DesignBoardView`s: the board holding
  the latest pick (down to 10% zoom), the board under the pointer with Select (at any zoom), and
  the boards nearest the middle of the view (from 25%), recycled least
  recently wanted first (`DesignLivePlan`). A live view draws at the canvas's zoom with WebKit's
  page zoom, so it lays out at the board's size and stays sharp, and it shows once its first
  snapshot is taken. During a zoom gesture every board draws its snapshot; live views follow once
  the canvas rests.
- **Snapshots.** Every other board draws its last snapshot, rendered by one off-screen view at a
  time (`DesignRasterizer`), so any canvas holds at most six web views. Snapshots are kept per
  design within a pixel budget, never evicting a board on screen. A hidden design gives up its
  live views and keeps its snapshots.
- **Live reload.** A write that changes a design's files pushes `onDesignRevision` for the designs
  on screen, at most once per frame. The canvas pulls the snapshot and hands the renderer only the
  boards whose hash changed: a live board takes its new source in place (`replaceSource`, no
  navigation, its state kept; source the runtime refuses leaves it as it was), and any other board
  renders one new snapshot. New boards appear and removed boards leave.
- **Budgets** (`DesignPerformanceTests`, over 172 boards): at most six web views, panning recycles
  them, and one board changing redraws one frame (`design.board`) with one snapshot. The Designs
  grid builds only the cards on screen (`ListPerformanceTests`, `design.card`).

### Tweak (DZTweak)

The chat pane's Tweak tab edits the selection (the latest pick) directly
(`DesignTweakModel`, `DesignTweakPane`; the controls are `DesignTweakControls`, pure).

- **Controls.** An element's inline style offers a fixed set, grouped as DZTweak groups them:
  Layout (Direction and Gap for a flex or grid container, Padding, Radius), Color (Fill for a
  shape or an element with a background color, Text for text), and Text (Text size, S · M · L).
  A value the board's logic sets (`{{ … }}`) is left out, as is the whole style when it is one
  hole. Then the board's `data-props` (`DesignProps`): a switch for `boolean`, a picker or a menu
  for `enum`, a slider for a bounded number (a stepper or a field otherwise), token chips for
  `color`, a field for `text`; grouped by their `section`, "Board" otherwise. A board picked whole
  shows its data-props alone.
- **Tokens.** The design's tokens are the CSS custom properties its board declares and its
  project's stylesheets declare (`DesignTokens`, `DesignProjectTokens`; the same walk as
  `design_check`). Lengths snap to the tokens named for their role (`--space-*`, `--radius-*`,
  `--text-*`); a design with none for a role snaps to Shepherd's own scale, and the scope's note
  says so. A color is always a token, never a free hex: without color tokens there is no Color
  group. A value the board declares as a token is written as `var(--name)`, anything else as its
  value (`24px`, `#4f46e5`).
- **Writing.** While a slider drags, the change shows in the board's live view
  (`DesignHost.previewStyle`: the runtime's `previewStyle` on every rendering of the element, or
  `setProps`) and nothing is written. On release the change is written once:
  - A style is spliced into the board's source at the parser's offsets (`DesignStyleEdit`): one
    declaration's value rewritten, a declaration added after the last, or the attribute added;
    every other byte stays as written, and the board is never serialized again.
  - "Every <name>" (the element's `data-el`) splices every element of that name on every board as
    one write (`writeDesignBoards`); "This board" writes the one element.
  - A data-props value goes to canvas.json as `{"tweaks": {"<board path>": {"<prop>": value}}}`
    (decision 13), clamped and checked by its editor; the board draws it as a prop, and agents
    keep the key as one they don't know.
  - Each write finds the element by its path in the source it splices (an agent's write can move
    its tid) and names the revision it read. A stale one is read again and the change made once
    more; a second failure says so under the header. A value that could load anything (`url()`,
    `image-set()`) is never written or previewed.
- **Reset** puts back what this session changed on the selection (each element's declared values
  from before its first tweak, removed where it had none; the board's props). An element a later
  write moved is left alone rather than given another's values. **Undo** (Edit ▸
  Undo) restores the versions a tweak's write kept, only while the boards still hold what it
  wrote; Redo writes the tweak again.
- **"Ask the agent instead…"** opens the Chat tab with its composer taking the keyboard; the
  message sent carries the selection as data (The view record).
- **Budget** (`DesignPerformanceTests`): a drag redraws no board frame, and its release redraws
  only the tweaked board's.

### Not built yet

Not drawn on any board, so left out until they are: the Designs page with no designs, a design
still loading or failing to draw, the design row's and the chat's ••• menus (so no rename or delete
in the app yet), Present mode, the Capture a page and From a screenshot starting points, zoom
presets and keyboard shortcuts (so no Escape to clear a selection), a board's list of versions
(Restore exists on the server, and the app offers only Undo), and a Tweak tab with nothing
selected (it says to select an element). Comments, Variations
and the board actions bar come with the rest of this phase.
