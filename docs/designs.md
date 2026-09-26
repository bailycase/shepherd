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
- **Pages and notes** (`DesignCanvasLayout`): a board or note is on the page it names when the
  index has that page, else on the first, so nothing listed goes missing; a canvas opens on
  `launch.page` when it has it, else the first page. A note is a title (`title1` and the other
  `title*` kinds), a sticky (`sticky`), or a drawing (every other kind), and runs as wide as its
  `maxW`, else its `w`. Every note round-trips whatever its kind.
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
  comments.json                the viewer's comments (Comments, below), beside project/
  assets/<id>.<ext>            uploads, served to boards as /_blob/<id>
  versions/<path>/<n>.dc.html  each board's last 20 earlier versions
  project/ds/<namespace>/…     an installed design system's copy (Design systems, below)
<support>/design-systems/<namespace>/
  tokens.json, tokens.css, README.md, components/…   a design system's files
  system.json                  Shepherd's record of it: revision, owner, sources, syncedAt
```

- **The support directory**, so a design survives a worktree's deletion, stays with its edition
  (Dev, Prod, Nightly), and needs no repository write. Nothing writes a repository.
- **Designs stand alone.** A design belongs to no space or project (the user's decision on
  2026-09-26, superseding the plan's decision 10). Its agent lives in the reserved designs space
  (`Space.holdsDesigns`, hidden: never in the sidebar, a picker or the palette, never a project)
  and works in the design's own folder. Only a system build ("Build one from a repo") has a
  project: the one it reads (`sourceSpaceID`).
- **The record.** `ShepherdState.designs` holds each design's `id`, `name` (kept equal to the
  canvas `title`), `agentID`, `systemNamespace`, `createdAt` and `lastActiveAt`, and a build's
  `buildsSystem` and `sourceSpaceID`. `Agent.designID` names the design an agent draws. Both
  decode with defaults from older files; a design's `spaceID` from before designs stood alone is
  ignored, except that an older build's is read as its `sourceSpaceID`.
- **Live values.** A design's `boardCount` (its listed boards) is read from its files and
  broadcast, never written to `state.json`. A write moves `lastActiveAt` the same way; it reaches
  the file with the next structural change.
- **Soft references.** A design's agent and an agent's design may name something gone. Deleting
  an agent keeps its design, which starts a fresh agent when next opened. Deleting a design takes
  its agent in the designs space with it (nothing else reaches that agent). Deleting or reordering
  a space never touches a design or its agent.
- **At startup** the server forgets a design whose folder has no `canvas.json` and clears
  references to what no longer exists. A canvas that is there but unreadable keeps its design. Which folders are gone is read on the design store's
  queue, not the server's. Design agents last across launches, unlike automation runs
  (`settleDesignAgents`): one an older state.json kept in a user space moves into the designs
  space (made then if needed) with its layout, keeping its working directory, since its pi
  session is filed under it; one the designs space holds for a design that is gone is dropped
  with its layout. It then reads each design's board count.

## Writing

`DesignStore` (ShepherdSessions) owns the files. Every read and write runs on its own serial
queue; only the record's commit and the broadcast run on the server's queue. `SessionServer` is
the only writer, through named mutations:

| Mutation | What it does |
| --- | --- |
| `createDesign(_:)` | Makes the folder with a new canvas.json (`createdOnFiles` stamped, the name as `title`), then the record. No space changes; a build's `sourceSpaceID` must exist. A refused record removes the folder again |
| `renameDesign(_:to:)` | Renames the record and the canvas `title` |
| `deleteDesign(_:)` | Removes the record and its agent in the designs space (its layout and processes; an agent elsewhere only loses its `designID`), then removes the folder |
| `designsSpaceID()` | The reserved designs space (`Space.designs()`: hidden, `holdsDesigns`), made on first use |
| `setDesignAgent(_:agentID:)` | Records which agent draws it |
| `writeDesignBoard(_:path:source:baseRevision:)` | Writes one board's whole source |
| `updateDesignIndex(_:patch:baseRevision:)` | Applies a canvas update. A new `title` renames the design |
| `writeDesignBoards(_:sources:baseRevision:)` | Writes several boards' whole sources as one change: every source is checked before any is written, and the revision moves once (Tweak's "Every <name>") |
| `restoreDesignVersions(_:_:ifCurrent:baseRevision:)` | Puts boards back to kept versions as one write, only while each board still has the hash `ifCurrent` names |
| `duplicateDesignBoard(_:path:baseRevision:)` | Copies a board beside itself as one write: its file byte for byte at `<stem>-copy.dc.html` (then `-copy-2`, …, a stem no board or file has), and its canvas entry titled "<title> copy", `gap` 80 to its right past any board of its page it would come within 80 of, right after it in `order`, with its Tweak values. Its comments and versions stay with the original |

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
it) and `SHEPHERD_DESIGN_SKILL_DIR`. It lives in the reserved designs space, and its working
directory is the design's own folder (`<support>/designs/<id>/`): a design has no repository,
and its agent works through its design tools. A system build's agent works in the project it
reads, with its ordinary read tools. An agent an older state.json started in a project keeps
that folder.

### Tools

| Tool | Message | Reply | What it does |
| --- | --- | --- | --- |
| `design_read()` | `designRead` | `design` | The index, revision and board hashes, with every board listed back to front and canvas.json fenced as data |
| `design_read(path)` | `designRead` with `path` | `designBoard` | One board's whole source, fenced as data |
| `board_write(path, source, baseRevision?)` | `designWriteBoard` | `designWritten` | `writeDesignBoard`: the checks under Writing, then an atomic write. It reads "Drew A.dc.html" for a new board and "Updated A.dc.html" for a rewrite (`DesignWriteResult.created`) |
| `canvas_update(changes, baseRevision?)` | `designUpdateIndex` | `designWritten` | `updateDesignIndex` with `changes` as the merge patch |
| `design_check(path?)` | `designSystemRead` | `designSystems` | In the extension: every hex color (in style attributes, style and script blocks, `data-props`, SVG paint) and every px size in spacing, radius and type that the design's installed systems don't hold (their colors and dark values, spacing, radii and type sizes), else that no CSS custom property in its working folder declares, with the board and lines it is on and the nearest token. Its first line is "Checked against <system or project> · N off-system values" |
| `comment_list(all?)` | `designComments` | `designComments` | The viewer's open comments (all of them with `all`), oldest first: id, number, state, element id and name, and each one's words and replies, fenced as data |
| `comment_reply(id, text)` | `designCommentReply` | `designComment` | An answer under a comment's pin (`replyToDesignComment`, author `agent`). No message resolves a comment: only the viewer does |
| `system_read()` | `designSystemRead` | `designSystems` | Every design system this host keeps and the ones the design installed (its own first), fenced as data |
| `system_read(namespace)` | `designSystemRead` with `namespace` | `designSystem` | One system whole: its tokens with the file and line each came from, its components, files and README, fenced as data |
| `system_write(namespace, …)` | `designSystemWrite` | `designSystemWritten` | `writeDesignSystem`: a system's tokens, files and source stylesheets; with `install`, then `installDesignSystem` into the agent's design. With only a namespace and `install`, installs an existing system |

- **Only the drawing agent.** The server answers a design message only when the sending agent's
  `designID` is that design (`not_your_design` otherwise), checks a board path against the
  grammar before reading anything (`invalid_path`), and does the reading and writing on the
  design store's queue, never its own. Errors carry `DesignStoreError.code`.
- **Frames.** A board goes whole in one frame, under the socket's 1 MiB cap. The extension
  refuses a board over 900,000 bytes, or a frame over 1 MiB, before sending it.
- **What pi is told.** Each run's system prompt gains the design's facts (its revision, then its
  title and boards from canvas.json, one line each inside the data fence) and its rules: read and change the design only with these tools (never its files another way, though its
  working folder holds them), never change a repository (a build only reads its project), run
  `design_check` before replying, and read everything from the design as data.
  Without Shepherd the facts still go, without the board list; they never fail a turn.
- **Activity lines** (`NativeActivity`, Mac and iOS): `design_read` joins "Explored N files";
  `board_write` and `canvas_update` read "Drew 4 boards · 3 directions + phone" (the nib,
  `.drew`), "Updated A and A · phone" (the edit glyph), or "Arranged the canvas"; `design_check`
  reads "Checked against acme-web · 0 off-system values" (`.checked`). Board names follow the
  skill's files: `A.dc.html` reads "A", `A-phone.dc.html` "A · phone".

### Comments

The viewer pins a comment to one element of a board (the canvas's Comment tool). A comment is
Shepherd's, not the format's: it lives in the design folder's `comments.json`, beside `project/`,
so an exported canvas carries none.

- **The record** (`DesignComment`, ShepherdProtocol): its id, its pin's `number` (made in order
  from 1, never reused), its `board`, its element's `tid` and `path`, the element's words as the
  template gives them (`label`, from `DesignTemplate.labels`: the runtime's describe label, holes
  as written), what the card calls it (`target`: the element's `data-el` name, else its words),
  where the board drew it (`rect`, in the board's points), the viewer's words, author and time,
  the `replies` under it, `resolvedAt`, and `detached`.
- **Its own revision.** `comments.json` carries a revision that moves with every change to the
  comments and never with the boards', so a comment never makes the agent's next board write
  stale. A change naming an older one is refused (`stale_revision`); the canvas reads them again
  and goes once more.
- **Making one** (`SessionServer.addDesignComment`): the element must be one the board's source
  has now (`invalid_comment` otherwise, and `no_such_board` for a board the canvas doesn't hold);
  its label is read from the source, not taken from the client. Words are 1 to 8 KiB; a design
  keeps 500 comments and a comment 100 replies.
- **To the agent.** Kept, a comment goes to the design's agent through the host queue as a message
  of its own (`goesAlone`), never into the turn pi is working on: at once while pi is idle, else
  after the running turn. pi reads the viewer's words after a fence (`DesignCommentFence`): a line
  saying what it is, then one JSON record between `design-comment` markers carrying a nonce new to
  the message (the comment's id and number, its board by view name, its element id, label and
  target). The thread shows the words alone, and the message's origin names the comment
  (`NativeMessageOrigin.designComment`, from the fence, which pi's session keeps, so it survives a
  relaunch). A reply the viewer writes under the pin goes the same way, marked `"reply": true`,
  and draws as their words. The fence always goes first, so words starting with "/" never run
  as a pi command (a view record, by contrast, stays off a command). A comment that can't go (no agent, pi not running or starting) is
  kept and says why; it doesn't go later on its own.
- **Answers and resolving.** The agent answers under the pin with `comment_reply` once the change
  is made. Only the viewer resolves (`resolveDesignComment`), and may open one again.
- **Drift.** A rewrite renumbers a board's elements, so every write of a board finds its open
  comments' elements again (`DesignCommentAnchor`): the element at the same path with the same
  words; else one with the same words, nearest the old path; else the element at the same path
  (its words changed where it stands, typically the edit the comment asked for); else the comment
  detaches where it was ("element changed"). A board leaving the canvas detaches its comments;
  one found again later attaches again.

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

## Design systems

A design system is a named set of tokens, components and a README that Shepherd keeps apart
from any design, so several designs can be drawn in one. Installed in a design, a copy of its
files sits in the canvas under `ds/<namespace>/` and is recorded in canvas.json's
`designSystems`, as the Design format installs one; boards link it from there, and
`design_check` checks against it.

### tokens.json

`DesignSystemTokens` (ShepherdProtocol) reads a system's `tokens.json` in either of two shapes and
keeps every key it doesn't name, at the top and on each token:

- **Shepherd's schema** (`"format": "shepherd-tokens/1"`, what Shepherd writes):

  ```json
  {
    "format": "shepherd-tokens/1", "name": "acme-web", "namespace": "acme-web",
    "colors": [{"name": "--accent", "value": "#4f46e5", "dark": "#818cf8",
                "source": {"file": "web/static/tokens.css", "line": 8}}],
    "type": [{"name": "display", "size": 26, "weight": 700, "lineHeight": 1.2, "family": "Inter",
              "tracking": -0.01, "transform": "uppercase", "sample": "Checkout funnel"}],
    "spacing": [{"name": "--space-4", "px": 16, "source": {"file": "web/static/tokens.css", "line": 20}}],
    "radii": [{"name": "--radius-md", "px": 8}],
    "fonts": [{"name": "sans", "family": "Inter", "fallback": "system-ui, sans-serif"}],
    "components": [{"name": "Button", "source": {"file": "templates/partials/button.html"},
                    "specimen": "components/Button.html", "export": "Acme.Button"}]
  }
  ```

  A color's `value` (and `dark`, its dark variant) is a hex, a color function or a named color;
  `size` and `px` are px; a `source` is `{file, line}` or `"file:line"`, the file relative to the
  project it was read from. A component's `specimen` is a file of the system showing it, and its
  `export` the global its bundle mounts it by.
- **A canvas's own shape** (the Shepherd canvas's `project/tokens.json`): `color.light` names the
  colors, `color.dark` their dark values; `type` maps style names to `{font, size, weight,
  lineHeight, tracking, transform}` with `font` naming one of `fonts`; `space` and `radius` map
  step names to px (read as `space.4`, `radius.md`). A value in `color` that isn't a color (a
  shadow) keeps the whole map where it was, and `size` and `motion` stay as unknown keys.
- **Unreadable:** a token without its name or value, a list that isn't one.
- **What a write may hold** (`problems()`): names of letters, digits and `. _ -` (a leading `--`
  kept); colors that are colors, with nothing that could break out of a stylesheet (`;`, braces,
  `url(`); type sizes of 1–400 and weights of 1–1000; steps of 0–10,000 px; a specimen by the
  system's file grammar; an export as `Ns.Name` (no `__proto__`, `prototype` or `constructor`);
  500 tokens and 200 components at most.
- **tokens.css** is generated from the tokens (`css()`) unless the system brings its own: every
  color and step on `:root` (a name that isn't a custom property reads `bg.canvas` →
  `--bg-canvas`), `--font-<name>`, `--text-<style>-size`, `-weight` and `-line-height`, and the
  dark values under `[data-theme="dark"]`, which a board opts into on its root. Its first line
  (`/* Generated by Shepherd from tokens.json`) marks it as Shepherd's, so a later write or
  re-sync rewrites it; a stylesheet without it is the author's and is left alone.
- **Stylesheets** are read by `DesignSystemCSS.declarations`: every custom property with its file
  and the line its name is on, comments skipped, `!important` dropped, values with parentheses
  and commas kept whole. `DesignCSSDeclaration.label` is what the system's page lists: "--accent
  #4f46e5 · tokens.css:8".

### Where systems live

`DesignSystemStore` (ShepherdSessions) keeps them in the support directory's
`design-systems/<namespace>/` (`[a-z0-9][a-z0-9_-]{0,63}`), on its own queue:

- **Files:** `tokens.json`, `tokens.css`, `README.md`, and whatever else the system needs
  (`components/Button.html`, a bundle's `bundle.js` and `bundle.css`): relative paths of
  `[A-Za-z0-9_][A-Za-z0-9_.-]*` segments, at most 6 deep, ending in json, css, js, md, html, svg
  or txt; 64 files, 900,000 bytes each (a frame), 8 MB in all.
- **`system.json`** is Shepherd's record (`DesignSystemInfo`), never one of the system's files and
  never installed: its title, revision (moves with each write), when it was made, changed and
  last synced, the design whose agent built it (`ownerDesignID`), the project it was read from
  (`spaceID`) and its stylesheets there (`sources`, relative to the project).
- **Built in:** Night Watch (`night-watch`), generated by the app from ShepherdUI's tokens
  (`NightWatchSystem`: every `ThemeColors` and `SyntaxColors` role with its light and dark value,
  the type ramp, the space and radius scales, Geist and Geist Mono) and registered with the
  server at launch. It lives in memory, is listed first, installs like any system, and is never
  written or synced.
- **Links are never followed.** A `design-systems/<namespace>` that is a link or a file is no
  system: it is not listed, and reading, writing or installing it refuses (`not_a_folder`). Inside
  a system, a linked file is not one of its files, and a write never goes through a linked
  folder (`invalid_file`); an install checks each file's folder under the design's
  `ds/<namespace>/` the same way before it makes anything.
- **At most 100** systems on a host.

### Writing, installing, re-syncing

| Mutation | What it does |
| --- | --- |
| `writeDesignSystem(_:for:)` | Writes a system for a design's agent. A new namespace becomes that design's; an existing one must be (`not_your_system`), and a built-in never is (`read_only_system`). `tokens` are checked (`invalid_tokens`) and written as given, other files written or (null) removed, `tokens.css` generated when the tokens change and the stylesheet is Shepherd's. `sources` are read from a system build's project (`sourceSpaceID`), never written (any other design has no project: its sources are kept unread, and Re-sync refuses them): one that isn't there is noted, not refused. A `baseRevision` the system moved past is refused (`stale_revision`). Changed files move the revision and tell the app (`onDesignSystemsChanged`) |
| `installDesignSystem(_:namespace:baseRevision:)` | Copies every file of a system but `system.json` into the design's `project/ds/<namespace>/` (files an earlier copy had and this one doesn't leave), and records it in canvas.json's `designSystems` (`title`, `namespace`, `version` (the system's revision), `copiedAt`, `"origin": "shepherd"`) in place of the earlier record of that folder, else last: one design revision. The design is then drawn in it (`Design.systemNamespace`, persisted). A folder whose record isn't Shepherd's (a system installed on claude.ai, with its `artifact`), or a `ds/<namespace>/` with no record, is kept as it is (`namespace_taken`); a canvas holds 4 systems |
| `resyncDesignSystem(_:)` | Re-sync, manual: reads the system's `sources` again from its project (only inside it, at most 1 MB each) and takes back what changed (`DesignSystemTokens.resynced`): a color or step whose `source` names one of them takes its value and line there now, or leaves when it is no longer declared; a custom property no token names joins (a hex as a color, a length as a radius or spacing step by its name); type, fonts and components are the author's. The revision moves when the tokens change, `syncedAt` always ("synced 4m ago", `DesignSystemPresentation.synced`). Designs keep the copy they installed until it is installed again. A built-in, a system without sources or whose project is gone refuses (`no_sources`) |

Reads: `designSystemSummaries()` (each system's record, whether it is built in, and its counts:
colors, type styles, spacing and radius steps, components), `designSystem(_:)` (tokens, README
up to 64 KB, files) and `designSystemListing(_:)` (what `system_read` lists for a design: every
system, and the design's installed ones with the tokens of their copies, read from their
`tokens.json`, else from the custom properties of their `tokens.css`, so a system installed on
claude.ai is still checked against).

### The agent's side

- **Building one from a repository** ("Build one from a repo", DZSystem): the agent reads the
  project's tokens file, templates and pages with its ordinary tools, writes the system with
  `system_write` (tokens with their sources, specimens, a README, the stylesheets it read), and
  reports what doesn't match (values the templates hard-code instead of a token). The repository
  is only read.
- **Drawing in one:** boards link `ds/<namespace>/tokens.css` (and a bundle's files) after the
  `support.js` line, use its custom properties, and mount its components with `<x-import>` (The
  runtime, above).
- **What pi is told:** each run's facts list the design's installed systems inside the data fence,
  and the rules say to draw in the installed system and to change a system only with
  `system_write`.
- **Activity lines:** `system_read` joins "Explored N files" (`ds/<namespace>`, or "design
  systems"); `system_write` reads "Used system" with its namespace.

### In the app

- **The catalog** (`DesignSystemCatalog`, owned by the view model) holds the host's systems as
  last read: each one's record and counts, and its tokens, README and file list. It reads them
  again when the server says one changed (`onDesignSystemsChanged`: a write, a re-sync) and when
  a page that shows them opens; a system whose revision didn't move keeps what was read.
- **"Build one from a repo"** (NavDesigns' dashed tile, a menu of projects when there are
  several) makes a design that builds a system (`Design.buildsSystem`, persisted, false in older
  files) from the project (`sourceSpaceID`: the system keeps its source repo, for Re-sync),
  named after it, and starts its agent in the designs space, working in the project's folder,
  with Settings' default model
  and these words: "Build a design system from this project: read its tokens file, its component
  templates and a few pages (read only), write the system with system_write, and tell me what
  doesn't match." A project that has a build opens it instead. A build has no card and no Recents
  row; its system (the one whose `ownerDesignID` is the build) is its page.
- **A system's page** (DZSystem, `DesignSystemPageModel`): a build's page is its agent's layout
  (`DesignSystemLayoutView`), the system beside the agent's 420pt chat with the Chat tab alone
  (decision 12), mounted and hidden like any agent's; before the agent writes its system it says
  "Reading <project>…". Any other system (Night Watch, or one a canvas's agent wrote) opens as the
  Design systems page (`MainDestination.designSystem`), without a chat. The page:
  - the header: "Design systems / acme-web", "Synced" once read from a project ("Syncing" while a
    re-sync runs), and the system's chip;
  - the section list, each with its count: Colors, Type, Spacing & radii, Components, and Boards
    using it (the boards of the designs drawn in it); a section scrolls to its label;
  - the name over "Read from `dashboard-web`: `web/static/tokens.css` and 9 templates in
    `templates/partials/` · synced 4m ago" (a built-in: "Generated from ShepherdUI's tokens"; a
    system whose project is gone: its counts), and **Re-sync** (`resyncDesignSystem`), disabled
    for a system without stylesheets or project;
  - colors as token swatches with the line each came from, type styles in the system's own face,
    the spacing and radius steps, components, and the designs drawn in it.
- **Specimens.** A component's `specimen` file is drawn by the board renderer, never as SwiftUI:
  the page reads the system's files (`SessionServer.designSystemContents`), wraps each specimen
  in a board of the tile's size on the system's background with its `tokens.css` linked
  (`DesignSpecimenBoard`), and renders it off screen from those files held in memory
  (`DesignSurface(designID:files:)`, `DesignSpecimens`), again only when the system's revision
  moves. A specimen over 64 KB, or none, leaves its tile empty. Nothing is written to disk.
- **The Designs page's systems** (NavDesigns): the systems built here by title, the builds still
  reading their project ("dashboard-web · building"), then the built-ins, in lazy rows of three
  ending in "Build one from a repo". A card has four of the system's colors (its accent, text,
  background and a status color by name, then the rest), its source ("dashboard-web ·
  tokens.css"; Night Watch: "shepherd · ShepherdUI Tokens") and how many designs are drawn in it,
  and opens its page.
- **More ▸ Design systems** opens the system page shown last, else the first system built here,
  else Night Watch; it is selected while a system's page shows. **A design's system chip** opens
  its system's page, and draws three of its colors.
- **New design** (DZStart) picks no project. The card is the design system the design is drawn
  in: the one picked from its menu, else the most recently changed system built here, else Night
  Watch. It names the repo a system was read from as information ("acme-web", "design system ·
  dashboard-web", "found in web/static/tokens.css"; a system whose project is gone: "design
  system"; one a design's agent wrote without sources: "made in Shepherd"; Night Watch: "design
  system · shepherd", "built into Shepherd"). Its menu picks another system. Send installs the
  system in the new design before its agent starts.

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

  Anything else is a 404, and a board that isn't there fails its load. A surface over files in
  memory (a design system's, for its specimens) serves those files by the same grammar and the
  runtime, and no uploads.
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
- **Design-system components.** `<x-import component-from-global-scope="Acme.Button">` mounts
  the component an installed system's bundle (loaded in the board's head from `ds/<namespace>/`)
  put on `window`: a dotted path of own properties from a global the page didn't have before the
  bundle (the runtime notes the page's globals when it loads, ahead of any bundle), never
  `__proto__`, `prototype` or `constructor`, ending in a function or a React element type.
  Attributes are props (kebab-case to camelCase, `class` to `className`; an `on…` prop only as a
  function from `renderVals()`), the content is `children`, and `style` places and sizes its
  slot, which then answers selection for it; without one the slot takes no box
  (`display: contents`) and what the component drew answers, marked `data-dc-owner` with the
  import's tid (as an import's drawing is). A component that isn't there, or throws while it
  draws, draws nothing and is reported; the rest of the board draws.
- **Not yet:**
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
- **Export.** `staticPage()` answers the board as a standalone page (the bridge's `staticPage`, in
  its own world); `printLayout()` its height, its lines of text and its images and drawings, and
  its paper's color, for a flow document's page breaks; `image(scale:)` and `pdf(_:)` draw it as
  an image and as PDF pages (Export).

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
  with its first board (the first in `order`) rendered off screen, and the host's design systems
  (Design systems › In the app). A card names the design's system: the one installed in it last
  (`Design.systemNamespace`); a design drawn in none names nothing.
- **Recents** lists a design as one row (the nib and "4 boards"), placed by its last change. Its
  agent has no row of its own and takes no ⌘-digit; the palette leaves it out too.
- **New design** (DZStart; the page's button, New thread's "Start a design") takes a brief,
  images and the design system (the card; Design systems › In the app). Send makes the design,
  starts its agent in the designs space, in the design's own folder, with Settings' default model
  and the brief as its first message, and opens the design. The agent is named after the design
  and gets no namer.
- **A design's screen** (DZCanvas) is its agent's layout (`DesignLayoutView`): the canvas beside a
  420pt chat pane holding the agent's thread, whose composer has attach and Send only, under a
  toolbar with the breadcrumb, the pages menu (with more than one page), the design's system,
  Present (below) and Export (below). Opening a design whose agent is gone starts a fresh one. Switching away and back is
  a visibility flip, and a design's canvas (where it looks, the tool, the selected board) lasts
  the app's run. A design's screen has no terminal panel.
- **The canvas** (`NWDesignCanvas`) pans with two fingers, the Pan tool or space-drag, and zooms
  with a pinch or ⌘-scroll about the pointer. It opens fitted to the boards, never above 100%.
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

### Comments (Comment)

- **Making one.** With the Comment tool, a click on a board names the element under it (the same
  hit test as Select; a board's label or nothing named takes no comment): it takes the selection
  ring and the next pin, and the review's comment editor opens under it ("Comment for the design
  agent", "on A · Checkout funnel"; ⏎ keeps it, esc cancels, an empty one is none). The Comment
  tool rings the element under the pointer as Select does.
- **Pins** (`NWCommentPin`) sit centered on their elements' top-trailing corners: where a live
  view of the board draws the element now (found again by tid and path after a write), else where
  it was when the comment was made. Only open comments have pins.
- **The thread** (`NWCommentThread`) opens under its element, its trailing edge at the pin's, kept
  inside the canvas: a click on a pin, or on a card in the Comments tab. It shows who and when,
  Resolve, the comment, each answer under a hairline ("Design agent · 1m"), and Reply…. A click
  anywhere on the canvas closes it.
- **The chat.** A message carrying a comment draws as the comment's card (`NWCommentCard`: the
  small pin, "on A · Checkout funnel", "You · 2m", the words), and the agent's reply to it sits
  inside the card under a hairline, without the turn's footer.
- **The Comments tab** lists the open comments' cards, oldest first (a lazy list, one row per
  card), and its label counts them. The chat's thread stays mounted under it.
- **Failures** (a comment kept but not delivered, a refused one) go to the app's error dialog.

### Board actions (DZCanvas)

The board picked whole last (not an element) wears the board actions (`NWBoardActions`, drawn as
DZCanvas draws it): its bottom 2pt above the board's label, its leading edge at the frame's
middle, kept inside the canvas. Nothing floats over a presented board.

- **Comment** takes the Comment tool: the element picked next takes the comment.
- **Tweak** opens the Tweak tab on the board (its data-props).
- **Variations** sends the design agent "Draw variations of the selected board as new boards
  beside it.", and **"Ask for another direction"** (the dashed tile 36pt after the page's last
  board) "Draw another direction as a new board." (`DesignScreenModel.variationsMessage`,
  `anotherDirectionMessage`). The words are fixed; the board goes as data in the message's view
  record (its one `selectedBoards` entry for Variations, none for another direction), which the
  host fences ahead of them like any record. They go like a message typed in the chat
  (`NativeThreadStore.send(text:designContext:)`), waiting in the queue while pi works. A design
  whose agent is gone says so.
- **Duplicate** (`duplicateDesignBoard`, at the revision the canvas read; a stale one is read
  again and made once more) picks the copy whole once it is there.
- **•••** holds Play for an interactive board (`is_interactive`) and is disabled otherwise.

### Moving a board

With Select, a drag that starts on a board's label, or anywhere on a board picked whole, moves the
board; any other drag pans, as before. While it drags, only that board's frame moves (and redraws,
once per step) and nothing is written. Where it lands is written once, as whole canvas points: a
canvas update of its `x` and `y` alone, at the revision the canvas read; a stale one is read again
and written once more. The board stays where it landed while the write goes, and a failure goes
to the app's error dialog.

### Present and Play

Present (the toolbar's button; decision 11, until Present mode has a board) shows the board picked
last, else the one nearest the middle of the view, focused over the canvas: the `scrim`, and the
board fitted inside the canvas's margins, never over 100% (`NWBoardPresentation`). Play (•••, on
an interactive board) shows that board the same way.

- The presented board is the design's one live view while it is shown (`DesignHost.present`):
  every other live view is given up and the canvas under the scrim draws snapshots.
- Its view takes clicks, so its handlers run. A link to another board of the design (relative,
  or from the canvas root with a leading `/`) comes back from the renderer as `.link` and shows
  that board instead (`DesignScreenModel.follow(link:from:)`); a link to a board the design
  doesn't list, or out of the design, goes nowhere, and the board never navigates.
- Present again, or a click on the scrim, goes back to the canvas. While a board is presented,
  the chat's record is `focused` on it.

### Pages and notes

A canvas with pages shows one at a time: the page it opens on, then the one picked in the
toolbar's pages menu (shown with more than one page). A page's boards, its title and sticky notes
(`NWCanvasNote`, read-only, under the boards and scaled with the canvas), the label rooms and the
fit are the page's own; switching fits the new page and drops what was selected on the last.

### The view record

The design screen publishes what it shows (`DesignScreenModel.viewRecord`, a
`DesignViewRecord` in ShepherdProtocol), and its chat's sends carry it (`NativeThreadStore`'s
`designContext`, where the host lists `designContext`; docs/native-thread.md › Design context):

- `mode`: `canvas`, or `focused` while a board is presented (Present, Play): `visibleBoards` is
  that board alone and nothing is selected.
- `page` and `pageName`: the page shown, by id, and its name cut to 60 characters, on a canvas
  with pages (a page id outside the grammar goes as neither).
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

- **Live views.** A design on screen keeps at most five `DesignBoardView`s (one while a board is
  presented): the board holding
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
  them, one board changing redraws one frame (`design.board`) with one snapshot, and a board
  dragged redraws its own frame once per step and no other. The Designs
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
- **Tokens.** The design's tokens are the CSS custom properties its board declares and the
  stylesheets in its agent's working folder declare (`DesignTokens`, `DesignProjectTokens`; the
  same walk as `design_check`): the design's own folder, or the project an older design's agent
  still works in. Lengths snap to the tokens named for their role (`--space-*`, `--radius-*`,
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

### Export (DZExport)

Export in the header opens the sheet over the window (`DesignExportSheet`, as DZExport draws it:
the 560pt card with its close button, on a 55% black scrim). The boards the canvas has selected
(picked whole, holding a selected element, or presented) open ticked, every board when none is;
the primary button counts the ticks ("Export 2 boards"). Each ticked board is rendered off screen
by a view of its own at zoom 1 (`DesignExporter` in `DesignHost.swift`), one at a time, from what
the design store reads for it (`SessionServer.designExportFiles`: the boards, every board they
import, the project's other files, and the uploads they name).

- **Where it goes.** Only where the save panel points: one file for a ZIP or a PDF (named for the
  design) and for a single board's page or image, else a folder holding one file per board
  (`DesignExportNames.destination`). The files are staged under the temporary folder and moved
  there whole once every board is done; what is there is replaced, as the panel confirmed.
  Nothing writes a repository.
- **HTML.** One standalone page per board (`<path>.html`): the bridge's `staticPage` serializes
  what the board draws, the hoisted helmet in its head, with no script, no runtime and none of
  Shepherd's `data-dc-*` stamps or handler attributes. Since the page opens outside the canvas's
  sandbox (and an imported board never passed `board_write`'s lint), it also keeps no iframe,
  object, embed, `base`, `http-equiv` meta, `srcdoc`, `javascript:` url, or SVG animation that
  retargets a link. The design's own stylesheets are inlined;
  Google Fonts' links stay. Uploads (`/_blob/<id>`) are inlined as data URLs, fonts included, and
  a link to another exported board (`<a href="B.dc.html">`, or from the canvas root) goes to its
  page. A support file the board links by a relative path (not an upload) is not carried.
- **ZIP.** The pages (uploads pointed at `assets/`), `tokens.css` (a `:root` block of every custom
  property the boards and the stylesheets in the design agent's working folder declare,
  `DesignExportTokens`), `assets/`
  (the uploads they name), and the canvas as a project folder (format.md): `project/canvas.json`
  narrowed to the exported boards with every other key kept (`DesignBundle.index`), each exported
  board's and each imported board's source as written, and the project's other files (`ds/`,
  support files). Made with `/usr/bin/ditto`. The folder imports into Shepherd again; on claude.ai
  the files are the format's, but uploads are Shepherd's own `assets/`, not claude.ai's.
- **PDF.** One document, a page per board in canvas order, at 96 CSS px to the inch (print.md): a
  fixed board (`print` absent or `fixed`) is one page at its frame's size; a flow board
  (`"print": "flow"`, `paper` `letter` or `a4`) runs onto that paper, cut between lines of text and
  never through an image or drawing that fits a page, with 5% of a page blank at each cut in the
  paper's color (`DesignPrint.pages`), at most 100 pages. WebKit draws each page's slice
  (`createPDF`); CoreGraphics puts the pages together (`DesignPDF`).
- **PNG.** Each board at twice its size in pixels (`<path>@2x.png`).
- **Attach to a thread** (a menu of the local threads, most recently active first) writes the
  ticked boards as standalone pages and `tokens.css`, a note of the tokens they use (or every
  token when they reference none), into a folder of the drop folder (pruned after a day), and
  leaves them in that thread's composer as file chips; the thread opens. They go with its next
  message as a list of their paths under the words (`NativeAttachedFile`). Attach to a mission
  waits for Missions, and the live link (a listener on the host) is not built; the sheet leaves
  both out.

### Import

File ▸ Import Claude Design Folder… (with the Design tool on) reads a canvas folder from disk into
a new standalone design (`SessionServer.importDesign`, decision 4; no project needed or chosen),
and opens it (its agent starts then). The folder is only read.

- **Which folder.** A canvas's `project/` itself (it holds `canvas.json`), or a folder holding
  `project/` and, from a Shepherd export, `assets/`. Everything else in it is left behind.
- **Rules** (`DesignImport`): links anywhere in what is read are refused, as is anything that is
  neither a file nor a folder; every name passes the path grammar's segment rule; at most 16 levels,
  512 files, 16 MB a file and 256 MB in all; uploads are `assets/<id>.<ext>`. Each file is opened
  without following a link and checked for its size before it is read. Hidden files and any
  `support.js` (Shepherd serves its own runtime there) are left behind.
- **The canvas** is kept byte for byte, every key with it; one without a title is titled after
  the folder, still keeping every key. A canvas this build can't read refuses the import.
- **Atomic.** The copy is staged beside the designs and moved into place whole, then the record
  is committed; a refused or failed import leaves nothing behind.

### Not built yet

Not drawn on any board, so left out until they are: the Designs page with no designs, a design
still loading or failing to draw, the design row's and the chat's ••• menus (so no rename or delete
in the app yet), Present mode's own board (Present shows a board focused meanwhile), the board
actions' ••• beyond Play, an interactive board's blue mark and Play button on its frame (format.md;
Play is in •••), closing Present with Escape, a board that asks to fill the window (`expand:
"fill"`, shown fitted like any), drawing notes, the Capture a page and From a screenshot starting points, zoom
presets and keyboard shortcuts (so no Escape to clear a selection), a board's list of versions
(Restore exists on the server, and the app offers only Undo), and a Tweak tab with nothing
selected (it says to select an element). For comments: an empty Comments tab (it is blank), a
detached pin (it stays where its element was, and its thread and card say "element changed"),
resolved comments (they leave the canvas and the tab; nothing lists them yet), and a comment that
couldn't reach the agent (the error dialog says so; it isn't sent again). Not drawn and built
plainly: the pages menu (a popup in the toolbar), notes (a title's and a sticky's size and look),
moving a board (by its label or while picked whole), Duplicate's name and place for the copy, and
the words Variations and another direction send.

For design systems (Design systems › In the app): Tweak doesn't yet snap to an installed
system's tokens.json (it reads the board's custom properties and those the stylesheets in its
agent's working folder declare, which for a design's own folder include its installed systems'
copied `tokens.css`). Not drawn, and built
plainly: a build still reading its project ("Reading <project>…" and nothing else), the Design
systems page with no chat for a system without its own agent, a build on the grid before it has
written its system, the Spacing & radii and Boards using it sections (rows in the type rows'
anatomy), a type style without a sample (its name), and a failed build or re-sync (the error
dialog). The chat's "Read dashboard-web · tokens.css · 9 partials · 3 pages" activity line isn't
built: the agent's reads join "Explored N files".
