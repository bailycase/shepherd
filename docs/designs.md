# Designs

The Design tool (an experiment, off by default) keeps each design as a canvas of HTML boards
that a design agent draws. This page covers the files, how they change, how a board is drawn,
the design agent's tools, the Mac's screens, and the remote protocol that serves designs to
other devices.

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
  without numbers for `x`, `y`, `w` and `h`. Geometry must be safe to render: coordinates must
  round to a native integer, and dimensions must be positive and round to a native integer.
  Unsafe values refuse decoding, including old saved canvases. Tall legacy documents (including
  8001 and 10000 px) stay lossless; the 40–8000 authoring rule does not reject their import.
  Native rendering has separate allocation limits: 131072 CSS px per edge and 128 million CSS
  pixels in a layout (enough for 100 A4 flow pages), and 64 million output pixels per bitmap.
  Larger stored boards report a rendering refusal instead of allocating or changing the canvas.
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
  pins/<sha256>.dc.html        a board as a design reference pinned it (Design references, below)
  pins/<sha256>.blob           pinned canvas, support files and uploads
  checkpoints/<hash>/…         the agent's named copies of every board and the canvas (Checkpoints, below)
  project/ds/<namespace>/…     an installed design system's copy (Design systems, below)
<support>/designs/.deleted-<designID>/   a design deleted within its undo window (Deleting, below)
<support>/designs/.import-<token>/       a project being imported, staged until it is finished
<support>/designs/.unzip-<token>/        a ZIP being unpacked for an import
<support>/design-systems/<namespace>/
  tokens.json, tokens.css, README.md, components/…   a design system's files
  system.json                  Shepherd's record of it: revision, owner, sources, syncedAt
```

The hidden folders beside the designs are Shepherd's own staging: nothing serves them, and launch
and quit remove whatever is left of them (a deletion in its window completes, an import waiting on
a choice is put away).

- **The support directory**, so a design survives a worktree's deletion, stays with its edition
  (Dev, Prod, Nightly), and needs no repository write. Nothing writes a repository.
- **Designs stand alone.** A design belongs to no space or project (the user's decision on
  2026-09-26, superseding the plan's decision 10). Its agent lives in the reserved designs space
  (`Space.holdsDesigns`, hidden: never in the sidebar, a picker or the palette, never a project)
  and works in the design's own folder. Only a system build ("Build one from a repo") has a
  project: the one it reads (`sourceSpaceID`).
- **The record.** `ShepherdState.designs` holds each design's `id`, `name` (kept equal to the
  canvas `title`), `agentID`, `systemNamespace`, `createdAt` and `lastActiveAt`, a build's
  `buildsSystem` and `sourceSpaceID`, when it was removed from Recents (`recentsHiddenAt`), and
  the Claude Design project it was imported from (`importedFrom`: the file's name, the canvas's
  title and its `createdOnFiles` stamp, and when). `Agent.designID` names the design an agent draws. Both
  decode with defaults from older files; a design's `spaceID` from before designs stood alone is
  ignored, except that an older build's is read as its `sourceSpaceID`. It is still written (a
  build's project, else an id no space has), because older builds and remote clients can't
  decode a design without one.
- **Live values.** A design's `boardCount` (its listed boards) is read from its files and
  broadcast, never written to `state.json`. A write moves `lastActiveAt` the same way; it reaches
  the file with the next structural change.
- **Soft references.** A design's agent may name something gone. Deleting an agent keeps its
  design, which starts a fresh agent when next opened. Deleting a design takes the agents that
  drew it (their layouts and processes too, held with it for its undo window): a design's chat
  never becomes a thread. Deleting or
  reordering a space never touches a design or its agent.
- **At startup** the server forgets a design whose folder has no `canvas.json`, with the agents
  that drew it, and clears references to what no longer exists. A canvas that is there but
  unreadable keeps its design. Which folders are gone is read on the design store's queue, not the
  server's. Design agents last across launches, unlike automation runs (`settleDesignAgents`): one
  an older state.json kept in a user space moves into the designs space (made then if needed) with
  its layout, keeping its working directory, since its pi session is filed under it; one the
  designs space holds for a design that is gone is dropped with its layout. It then reads each
  design's board count.

## Writing

`DesignStore` (ShepherdSessions) owns the files. Every read and write runs on its own serial
queue; only the record's commit and the broadcast run on the server's queue. `SessionServer` is
the only writer, through named mutations:

| Mutation | What it does |
| --- | --- |
| `createDesign(_:)` | Makes the folder with a new canvas.json (`createdOnFiles` stamped, the name as `title`), then the record. No space changes; a build's `sourceSpaceID` must exist. A refused record removes the folder again |
| `renameDesign(_:to:)` | Renames the record and the canvas `title` |
| `deleteDesign(_:undoable:)` | Takes the record and the agents that drew it out of the workspace at once (their layouts too, and their processes stopped), sets the folder aside (`.deleted-<id>`), and holds all of it for `designUndoWindow` (10 s); then the folder goes. Answers a `DesignDeletion` (the name and the undo deadline). With `undoable` false (a system build that Delete design system stops) it is gone at once |
| `undoDesignDeletion(_:)` | Within the window: waits out the stopped processes, puts the folder back, and restores the record, the agents and their layouts where they stood in their lists, each layout on fresh `PaneID`s with no session (so a late exit of the old process touches nothing, and the app starts a fresh pi resuming the agent's session). Refused once the window has closed |
| `duplicateDesign(_:)` | A new design with a new id named "<name> copy" (then "copy 2", …): a copy of the original's canvas (titled so), boards, project files, installed systems and uploads, drawn in the same system, links left behind. Its versions, comments and agent stay with the original |
| `removeDesignFromRecents(_:)` | Records `recentsHiddenAt`: the design leaves the sidebar's Recents until it next changes (`Design.inRecents`) |
| `prepareDesignImport(from:progress:)`, `finishDesignImport(_:name:skippingUnreadable:)`, `cancelDesignImport(_:)` | Import, in two halves (Import, below) |
| `designsSpaceID()` | The reserved designs space (`Space.designs()`: hidden, `holdsDesigns`), made on first use |
| `setDesignAgent(_:agentID:)` | Records which agent draws it |
| `writeDesignBoard(_:path:source:baseRevision:)` | Writes one board's whole source |
| `updateDesignIndex(_:patch:baseRevision:)` | Applies a canvas update. A new `title` renames the design |
| `writeDesignBoards(_:sources:baseRevision:)` | Writes several boards' whole sources as one change: every source is checked before any is written, and the revision moves once (Tweak's "Every <name>") |
| `restoreDesignVersions(_:_:ifCurrent:baseRevision:)` | Puts boards back to kept versions as one write, only while each board still has the hash `ifCurrent` names |
| `editDesignBoards(_:request:)` | `boards_edit`: the same edits on many boards as one write, each reported (Batch edits, below) |
| `extractDesignPiece(_:request:)` | `board_extract`: a piece board, the source's `<dc-import>` and any replaced copies as one write (Shared pieces, below) |
| `designCheckpoint(_:request:)` | `checkpoint_create` (a copy under the design's `checkpoints/`), `checkpoint_list` (a read) and `checkpoint_restore` (one write; Checkpoints, below) |
| `duplicateDesignBoard(_:path:baseRevision:)` | Copies a board beside itself as one write: its file byte for byte at `<stem>-copy.dc.html` (then `-copy-2`, …, a stem no board or file has), and its canvas entry titled "<title> copy", `gap` 80 to its right past any board of its page it would come within 80 of, right after it in `order`, with its Tweak values. Its comments and versions stay with the original |

Reads are `designSnapshot(_:)` (the index, the revision, and every board file under `project/`
with its SHA-256, listed or not), `designBoard(_:path:)`, `designVersions(_:path:)`,
`searchDesign(_:query:)` (`board_search`), `designUsage(_:)` (the usage index; Shared pieces) and
`renderDesignBoard(_:request:)` (`board_render`; the app draws it, nothing is written).

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

A design is drawn by a pi agent whose `Agent.designID` names it. Its launch adds
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
| `board_write(path, source, baseRevision?, tokens?)` | `designWriteBoard` | `designWritten` | `writeDesignBoard`: the checks under Writing, then an atomic write. It reads "Drew A.dc.html" for a new board and "Updated A.dc.html" for a rewrite (`DesignWriteResult.created`), then the write's report (below) |
| `board_edit(path, edits, baseRevision?, tokens?)` | `designEditBoard` | `designEdited` | `editDesignBoard`: `edits` (`[{find, replace, all?}]`, at most 64) applied in order to the board's text as the design store holds it now, then the same checks and atomic write as `board_write`, as one step of the store's queue (below). The result is `board_write`'s (revision, warnings, report), with how many matches each edit replaced |
| `boards_edit(paths?, edits?, boards?, atomic?, dry_run?, checkpoint?, tokens?, baseRevision?)` | `designEditBoards` | `designBatchEdited` | The same edits on many boards as one change, each reported (below) |
| `board_search(text? regex? scope? tag? attribute? value? class? usages? paths? limit?)` | `designSearch` | `designSearchResult` | Text, structure or a piece's usages across the boards, with element ids (below) |
| `board_render(path, width?, height?, scale?, props?)` | `designRender` | `designRendered` | A picture of a board as the app draws it (below) |
| `board_extract(path, element, piece, props?, size?, frame?, copies?, checkpoint?)` | `designExtract` | `designExtracted` | An element lifted into a shared piece (Shared pieces, below) |
| `checkpoint_create(name)`, `checkpoint_list()`, `checkpoint_restore(name)` | `designCheckpoint` | `designCheckpoints` | Named copies of every board and the canvas (Checkpoints, below) |
| `canvas_update(changes, baseRevision?)` | `designUpdateIndex` | `designWritten` | `updateDesignIndex` with `changes` as the merge patch |
| `design_check(path?, snap?)` | `designSystemRead` (`snap`: `designEditBoards` first) | `designSystems` | In the extension: every hex color (in style attributes, style and script blocks, `data-props`, SVG paint) and every px size in spacing, radius and type that the design's installed systems don't hold (their colors and dark values, spacing, radii and type sizes), else that no CSS custom property in its working folder declares, with the board and lines it is on and the nearest token. Its first line is "Checked against <system or project> · N off-system values" |
| `comment_list(all?)` | `designComments` | `designComments` | The viewer's open comments (all of them with `all`), oldest first: id, number, state, element id and name, and each one's words and replies, fenced as data |
| `comment_reply(id, text)` | `designCommentReply` | `designComment` | An answer under a comment's pin (`replyToDesignComment`, author `agent`). No message resolves a comment: only the viewer does |
| `markup_propose(proposals)` | `designProposeComments` | `designProposals` | Comments proposed from the viewer's Pencil markup, one per mark: each element checked against its board's source (`invalid_markup` otherwise), named `<call id>#<n>`, its card's name the element's `data-el` name else its words, then kept as comments at once, all or none, sent nowhere. The result lists them for the agent and ends with their JSON between `markup-proposals` markers, all inside the data fence, for the chat (Pencil markup, below) |
| `system_read()` | `designSystemRead` | `designSystems` | Every design system this host keeps and the ones the design installed (its own first), fenced as data |
| `system_read(namespace)` | `designSystemRead` with `namespace` | `designSystem` | One system whole: its tokens with the file and line each came from, its components, files and README, fenced as data |
| `system_write(namespace, …)` | `designSystemWrite` | `designSystemWritten` | `writeDesignSystem`: a system's tokens, files and source stylesheets; with `install`, then `installDesignSystem` into the agent's design. With only a namespace and `install`, installs an existing system |

- **`board_edit`** (`DesignBoardEdits`, `DesignStore.editBoard`) exists because a board is 30 to 95 KB
  and the agent's own `edit` and `write` tools can't reach a design's files (they live in the
  support directory, not its working folder), so every small change cost a whole `board_write`.
  - **On the host, on the store's queue.** The store reads the board, applies the edits and
    writes the result in one turn of its serial queue, so nothing lands between the read and the
    write, and two edits to one board each apply to what the other left (neither is lost).
    `baseRevision` is compared first, as for `board_write` (`stale_revision`).
  - **Exact matching.** `find` is exact bytes, whitespace and line endings included: no regular
    expressions, no Unicode equivalence, no folding of `\r\n` to `\n` (a failed `find` says when the
    board's lines end in CRLF and its own don't). Edits apply in order, each to what the one before
    left. A `find` must match exactly once, where overlapping matches count as several; with `all`
    every match is replaced, left to right without overlapping. An empty `find`, no edits, or more
    than 64 is `invalid_edit`; a result over 900,000 bytes is `board_too_large`, refused before
    it is built.
  - **All or nothing.** An edit that matches nothing (`edit_not_found`, naming the edit, and
    where the first line of its `find` does appear) or several times without `all`
    (`edit_ambiguous`, with the lines it is on) fails the call, and so does a result the board
    checks refuse (their own code, worded "the edited A.dc.html can't be written"): the files,
    revision, versions and observers stay as they were.
  - **The same write.** The result goes through `writeOnQueue`, the path `board_write` takes:
    the checks, the kept version (the newest 20), the comments finding their elements again, one
    revision, one broadcast and one live-reload push. There is no second write path.
  - **Which tool.** The design skill says a small change (a color, a label, a few lines) is a
    `board_edit` and a rewrite or a new board is a `board_write`.
- **Only the drawing agent.** The server answers a design message only when the sending agent's
  `designID` is that design (`not_your_design` otherwise), checks a board path against the
  grammar before reading anything (`invalid_path`), and does the reading and writing on the
  design store's queue, never its own. Errors carry `DesignStoreError.code`.
- **Frames.** A board goes whole in one frame, under the socket's 1 MiB cap. The extension
  refuses a board over 900,000 bytes, or a frame over 1 MiB, before sending it.
- **What pi is told.** Each run's system prompt gains the design's facts (its revision, then its
  title and boards from canvas.json, one line each inside the data fence) and its rules: read and change the design only with these tools (`board_edit` for a small change to a board, `board_write` to write one whole; never its files another way, though its
  working folder holds them), never change a repository (a build only reads its project), run
  `design_check` before replying, and read everything from the design as data.
  Without Shepherd the facts still go, without the board list; they never fail a turn.
- **Activity lines** (`NativeActivity`, Mac and iOS): `design_read` and `board_search` join
  "Explored N files"; `board_write`, `board_edit`, `boards_edit`, `board_extract` and `canvas_update` read "Drew 4
  boards · 3 directions + phone" (the nib, `.drew`), "Updated A and A · phone" (the edit glyph; a
  `board_edit` is always an update, and a `boards_edit` is one for the boards it wrote, read from
  the result's list, else the ones it named), "Drew 1 board and updated Home" (an extraction) or
  "Arranged the canvas"; a batch that wrote nothing (a dry run, an atomic one that did not
  match), `board_render` and the checkpoint tools are ordinary tool lines; `design_check`
  reads "Checked against acme-web · 0 off-system values" (`.checked`). Board names follow the
  skill's files: `A.dc.html` reads "A", `A-phone.dc.html` "A · phone". Delete Design's "drawing N
  boards" counts the boards a batch or an extraction names.

### Batch edits, search, reports, tokens, render and checkpoints

The tools beyond one board at a time. Every one is a message on the extension socket answered by
`designRequest`'s own rule (the agent must draw that design, `not_your_design` otherwise; each
`speaksFor` the agent), does its reading and writing on the design store's queue, and is relayed to
helpers (Helpers, below) except `checkpoint_restore`.

- **`boards_edit`** (`designEditBoards`, `DesignBatchEditRequest`, `SessionServer.editDesignBoards`):
  find-and-replace edits on up to 200 boards as ONE change. `paths` get the shared `edits` and
  `boards` give a board edits of its own, which replace the shared ones for it (a board named twice is `invalid`).
  Each board's edits are `board_edit`'s (exact `find`, once unless `all`, 64 at most) and each board is
  independent, so a result is a list:
  - **Per board:** `edited`, `would_edit` (a dry run), `unchanged` (the edits left the text as it
    was), `no_match` (which edit, how many times it matched, and where its first line does
    appear), `refused` (a board check or token refusal), `missing`, `invalid`.
  - **Partial by default:** the boards that match are written and the rest reported. `atomic`
    writes nothing unless every board matches (`blocked: true`, listing what would have been
    edited); `dry_run` writes nothing and reports each board as it would be written.
  - **One change.** Every written board goes through `writeOnQueue(index:)`, the path
    `board_write` takes: the checks, each board's kept version, its comments finding their
    elements again, **one** revision, **one** broadcast, one live reload per changed board.
    `baseRevision` is compared first.
  - **`checkpoint: "name"`** saves the design under that name first (Checkpoints, below), in the
    same turn of the store's queue, and says which checkpoints it dropped to make room.
- **`board_search`** (`designSearch` → `designSearchResult`, `DesignBoardSearch`, host side: the
  boards' text on the store's queue, no WebKit): `text` (a regular expression with `regex`,
  `ignore_case`) in the markup (default), the visible `text` or the `labels` (aria-label, alt,
  title, placeholder, `data-el`, an import's name); `tag`, `attribute` (+ `value`) and `class` by
  structure over the template tree (`DesignBoardTree`: every element with its attributes and
  ancestors, so a `<div>` top bar is found as well as a `<header>`); `usages` for a piece
  (`<dc-import name="X">` of every board). A structural match answers its element id
  (`File.dc.html#tid:path`, the numbering of Element ids above), its ancestor chain and a snippet. At
  most 20 boards listed (100 at most), 5 matches each and an 8 s budget, with a tail saying how
  many more there are; everything from the boards is fenced as data. A search with nothing to look for, or a
  pattern that is not a regular expression, is `invalid_search`.
- **The report after a write** (`DesignBoardReporter`, `DesignWriteResult.report`; at most about 12
  lines): tags balanced (the position of the first imbalance and its kind: unclosed, stray, an
  element closed by another's end tag), exactly one root, the root's size against `$preview` and
  the frame, the size and its change, a compact diff against the version it replaced (changed
  lines, five shown), `<dc-import>`s of boards the design does not have, and the tokens report
  below. It is part of the answer of `board_write`, `board_edit` and each written board of
  `boards_edit`; board-derived text in it (a tag name, a diff line) is fenced as data.
- **Token enforcement** (`tokens: "warn" | "snap" | "strict"` on `board_write`, `board_edit`,
  `boards_edit`; `DesignTokenCheck`): against the design's installed systems' tokens (the same
  values `design_check` reads, in Swift, with the same regexes). A value counts as **introduced** when
  it is on a line this write added or changed, so `warn` (the default) lists only what THIS write
  brought in and never the old values; `snap` replaces each introduced hex color and role px size
  with the nearest token as `var(--token)` (colors by RGB distance, lengths within their role:
  `--space-*`, `--radius-*`, `--text-*`) and reports each replacement; `strict` refuses the write
  and lists them (`tokens_off_system`). A design with no installed system has no tokens, so
  nothing is introduced against it. `design_check(path, snap: true)` snaps what is already on one
  board (`snapExisting`), then checks. canvas.json is unchanged by all of this.
- **`board_render`** (`designRender` → `designRendered`, `DesignRenderRequest`, `renderDesignBoard`):
  a picture of one board as the app draws it, at its frame's size (`width` and `height` 40 to 8000
  CSS px, `scale` 1 to 2, `props` as Tweak would set them). The server reads the board and
  everything it imports through the export path (`DesignExportFiles`) and the app draws it in a
  non-persistent `DesignSurface` of its own (`DesignRendering.picture(for:)`, one render at a time
  through `DesignRenderQueue`), so it works with the design off screen, never touches a live
  canvas view, and never the canvas's rasterizer. It is capped at 1600 px on its longest edge and
  350 KB (`DesignRenderImage`: PNG, else JPEG at falling quality, else smaller, the reply saying
  what was reduced), and answers `timeout` after 60 s, `render_unavailable` when no app serves
  it, or the board's own problem. Only the agent's own design. The extension attaches the
  picture only when the model can view images; otherwise the words say so.
- **`checkpoint_create`, `checkpoint_list`, `checkpoint_restore`** (`designCheckpoint`,
  `DesignCheckpointRequest`/`Result`): see Checkpoints, below.
- **`board_extract`** (`designExtract`, `DesignExtraction`): see Shared pieces, below.

### Checkpoints

A checkpoint is a named copy of every board and canvas.json, kept in the design's folder
(`checkpoints/<the first 12 bytes of the lower-cased name's SHA-256, in hex>/` with `manifest.json`, `canvas.json`
and `boards/…`, beside `versions/` and `pins/`), so a sweeping change by an agent can be taken
back whole.

- **Names** are 1 to 60 characters of letters, digits, spaces and `_ - . , ' ( ) # + :`, not case
  sensitive (`DesignCheckpointName`); `checkpoint_create` of a name that exists is
  `checkpoint_exists`. The folder name is a hash, so no name reaches a path.
- **Bounds:** 20 checkpoints per design and 200 MB of them (`DesignStore.checkpointCaps`). Saving
  past either drops the oldest and says which; a design whose boards alone exceed the size cap
  is `checkpoint_too_large`.
- **Restore is ONE change** (`restoreCheckpoint`, one `commit`): boards written since are put
  back, boards deleted since are made again, boards added since are removed, and canvas.json is
  put back with the design's installed `designSystems` as they are now. It first saves the design
  as "before restore <name>", so a restore can itself be undone by restoring that. Every board
  that changed keeps what it held as a version.
- **Never touched:** comments (their anchors are found again in the restored boards, or
  detached, as for any write) and installed design systems (`project/ds/`).
- **Not exported.** A checkpoint is not part of Export, a ZIP or a duplicate (Duplicate copies the
  design's canvas, boards, systems and uploads, as before); it is the agent's working history, like
  a board's versions.

### Helpers

A design agent can start native subagents ("helpers", [native-subagents.md](native-subagents.md))
to change boards in parallel. A helper is a pi of its own with every `SHEPHERD_*` variable stripped,
so it has no agent id, socket or design, and since the extension socket serves a message only on a
connection the agent's own pi opened (ARCHITECTURE.md › Extensions and the extension socket), a separate process could not
speak for the design anyway. The agent's pi can, so its design tools are relayed to the helpers
through it:

- **The mechanism.** `shepherd-design.ts` publishes its tools in a process-wide registry
  (`globalThis[Symbol.for("shepherd.design.relay.v1")]`: the design's id, whether the session is
  live, and each relayed tool as registered with pi) while it is active, which only a design agent's
  is, and withdraws it at `session_shutdown`. `shepherd-children.ts`, loaded into the same pi,
  reads it. For a helper whose profile lists some of those tools in `tools:`, the helper's bridge
  (the children extension again, run as `SHEPHERD_CHILD`) registers a proxy for each from the schemas
  the parent passes in `SHEPHERD_CHILD_RELAY`, so they count as the helper's own tools: the
  startup check of the tools a profile asked for passes, and `tools:` narrows them as it does any tool.
- **A call.** The proxy sends one `input` request up the channel a helper already has to its parent
  (its RPC stdout, answered on its stdin, which the children extension used to refuse as unsupported
  human interaction), titled `shepherd-relay:v1:<id>` and carrying `{tool, params}`. The parent checks
  it, runs the design extension's own `execute` for that tool in its own process, with the helper's
  signal, and answers with the result or the error in Shepherd's own words (a `stale_revision`
  reads "the design changed since revision 4 (it is at 6); read it again and redo the change"). So
  every design message Shepherd sees comes from the agent's own connection and agent id, through the
  same handlers and checks as its own calls. `baseRevision` and the store's serial queue behave as
  always: helpers writing different boards never conflict, and each `board_edit` applies to the
  board's text as it is when it lands.
- **Which tools.** `design_read`, `design_check` (its `snap` writes one board), `system_read`,
  `comment_list`, `board_search` and `board_render` only read. `board_write`, `board_edit`,
  `boards_edit`, `board_extract`, `checkpoint_create`, `checkpoint_list` and `canvas_update` are the
  point of it: the store serializes them. `system_write`
  is relayed under the agent's own identity, so the rule that only the design that built a
  system changes it holds exactly as for the agent. `comment_reply`, `markup_propose` and
  `checkpoint_restore` are never relayed: the first two are the agent's voice toward the viewer
  (it answers a comment once every helper is done and says what changed where, and a markup
  proposal belongs to one turn of the agent's), and a restore rewinds every board, a sibling's
  work included. A picture from `board_render` crosses the relay as a small PNG or JPEG part and
  reaches the helper only when the helper's own model can view images (the parent's model is no
  judge of that).
- **Only the listed ones, only this design.** The parent holds the allowlist (the profile's
  design tools, narrowed by the parent's own active tools) and refuses any other tool, a call over
  1 MiB either way (the socket's frame cap; a board is at most 900,000 bytes), a ninth call in
  flight from one helper, and a session that no longer draws a design. The proxies carry no design
  id, so a helper can name no other design. A profile that lists a design tool for a parent that
  draws no design, or one of the two that are never relayed, fails at `shepherd_child_start`, saying
  why, before anything launches.
- **Cancellation.** The design extension's tools stop waiting when the signal they are given aborts
  (the request already sent still reaches Shepherd, and a write may land, but its reply is dropped).
  A helper whose tool call is aborted tells its parent which call to drop (`shepherdRelayCancel`),
  and the parent drops every call of a helper that is stopped or exits, even one killed outright.
  `shepherd_child_result` shows `relaying`, the calls in flight.
- **The profile.** `tools: read, design_read, board_edit, design_check` is a design helper's line
  (add `bash`, `edit` and `write` only for work outside the design). It needs no `extensions:` line
  for the design extension: a profile that still lists `shepherd-design.ts` loads it into the helper
  as it always did, inert without its environment, and the relayed tools are the ones that work. A
  helper gets no skill unless its profile names one, so the parent's task carries the board rules it
  needs, and the design agent's prompt says so.

### Design agents and ordinary threads

An agent draws a design while its `designID` names one in the workspace
(`ShepherdState.isDesignAgent`). Its thread is that design's Chat tab and nothing else. Only it
gets `shepherd-design.ts`, the design skill, the design facts in its prompt,
`SHEPHERD_DESIGN_ID` and `SHEPHERD_DESIGN_SKILL_DIR`. A thread with no design never gets any of
them, whether the experiment is on or off. The rule holds in both directions:

- **Peers.** A design agent launches without the panes extension, so it has no `terminal_*`,
  `agent_*`, `automation_*` or `notify` tools. The server also refuses `listAgents`,
  `sendToAgent`, `spawnAgent` and `coordinateAgent` from it or aimed at it, with `not_a_thread`,
  so an older installed copy of the extension can't get around the rule. agent_list leaves it
  out.
- **The Mac's chrome.** A design agent has no sidebar row, no ⌘-digit and no palette row, the
  palette lists none of its subagents, and the palette's transcript search never reads its chat.
  It posts no banners: a thread's "Turn finished", question and subagent banners (and their
  Review action) never speak for a design. The Hosts page counts no thread for it.
- **Remote clients.** A client that reads designs (`designs.v1` in its hello) gets the host's
  designs and the agents that draw them while the host serves designs (its experiment on): its
  design screens show them, and it applies the same chrome rules. Any other client, and every
  client while the experiment is off, gets the host's state without `designs`, without their
  agents, and without those agents' layouts (`ShepherdState.withoutDesigns`); turning the
  experiment on or off sends reading clients the state again. `RemoteHostClient` applies the
  same rule to whatever a host sends, keeping designs only from a host that offers `designs.v1`,
  so an older host's designs reach no Mac, iPhone or iPad client that has no screen for them.
- **A forgotten design.** Deleting a design, or startup forgetting one whose folder is gone,
  takes the agents that drew it (Undo brings them back with it, still drawing it). Clearing their `designID` instead would turn the design's chat,
  fences and all, into an ordinary thread.
- **The one way in.** A thread gets a piece of a design only when the user hands it one: a
  design reference (Design references, below). Nothing else of a design reaches a thread, and a
  reference never reaches a design's agent.

### Comments

The viewer pins a comment to one element of a board (the canvas's Comment tool). A comment is
Shepherd's, not the format's: it lives in the design folder's `comments.json`, beside `project/`,
so an exported canvas carries none.

- **The record** (`DesignComment`, ShepherdProtocol): its id, its pin's `number` (made in order
  from 1, never reused), its `board`, its element's `tid` and `path`, the element's words as the
  template gives them (`label`, from `DesignTemplate.labels`: the runtime's describe label, holes
  as written), what the card calls it (`target`: the element's `data-el` name, else its words),
  where the board drew it (`rect`, in the board's points), the viewer's words, author and time,
  the `replies` under it, `resolvedAt`, and `detached`; and `proposal`, the design agent's
  proposal from Pencil markup it was kept from (below), else nothing, with `proposalSettledAt`,
  when the viewer applied it or kept it as it is (nil while it waits).
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
installed in a pi home.

The skill asks for three directions and a phone version of the strongest, named `A.dc.html`,
`B.dc.html`, `C.dc.html` and `A-phone.dc.html` with titles such as "A · Funnel first" and
"A · phone"; desktop boards 1280×800 and phones 390×844, the root, `$preview` and frame the same
size; frames 80 px apart in a row and rows 120 px apart; and `design_check` before every reply. It
also teaches the revising tools (one `boards_edit` for the same change on many boards, found with
`board_search`; reading the write's report; `tokens`; `board_render` to look; checkpoints before a
sweeping change) and when to extract a shared piece, how to name one, what its props are, that it
has no slots and nests at most 8 deep, and how to swap one (Shared pieces, below).

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
| `renameDesignSystem(_:to:)` | Rename…: the system's title in `system.json`; its namespace (its folder, and designs' `ds/` folders) stays. A built-in refuses (`read_only_system`) |
| `duplicateDesignSystem(_:)` | Duplicate (a built-in's "Duplicate as a New System"): the same files under the first of `<namespace>-copy`, `-copy-2`, … no system has, titled "<title> copy", nobody's build, keeping where it was read from for Re-sync |
| `deleteDesignSystem(_:)` | Delete Design System…: its folder goes, and the build that made it with its agent (stopped, nothing to undo). Designs keep the copy they installed (their `ds/<namespace>/` and `systemNamespace` stay), and the repository is never touched. A built-in refuses (`read_only_system`) |
| `deleteSystemBuild(_:)` | A build still reading its project, before it wrote a system: the build goes with its agent |

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
  in a board of the tile's size beside the specimen file, on the system's background with its
  root `tokens.css` linked (`DesignSpecimenBoard`). Relative links therefore resolve from the
  specimen's own directory. It renders off screen from those files held in memory
  (`DesignSurface(designID:files:)`, `DesignSpecimens`), again only when the system's revision
  moves. A specimen over 64 KB, or none, leaves its tile empty. Nothing is written to disk.
  Specimens may be HTML fragments or complete HTML documents. Complete documents keep their
  head resources and html/body attributes, including theme classes, while their body content
  enters the board. Fragments can link system-local stylesheets through `<helmet>`. Neither
  form compiles application source components. Tokens declare variables only;
  source paths do not import TSX, utility CSS, providers, or application build dependencies.
- **The Designs page's systems** (NavDesigns): the systems built here by title, the builds still
  reading their project ("dashboard-web · building"), then the built-ins, in lazy rows of three
  ending in "Build one from a repo". A card has four of the system's colors (its accent, text,
  background and a status color by name, then the rest), its source ("dashboard-web ·
  tokens.css"; Night Watch: "Built into Shepherd" beside its Built-in tag; a system an import
  brought: "came with Checkout funnel") and how many designs are drawn in it, and opens its page.
  A right-click, or ••• in the count's place on hover, opens its menu (Deleting and importing on
  the Mac, below). A design card names its system by title ("Checkout DS"), else its folder.
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

## Shared pieces

A **piece** is a board other boards mount with `<dc-import name="Card">`: drawn once, followed by
every board that imports it. Nothing is added to the format; the pieces follow from what the
runtime already does, and this section records it (`DesignPieceImportTests`).

- **Resolving.** `name` plus `.dc.html`, from the importing board's own folder (`parts/Card` is
  below it; `DesignImports.resolve`). It never climbs (`..`) or leaves the design; a name that is
  not a board draws the `hint-size` placeholder and reports the problem.
- **Props.** The import's other attributes are the piece's props, kebab-case read as camelCase
  (`item-count` is `itemCount`): text and numbers as written, and a whole-value hole
  (`items="{{ rows }}"`) keeps its list, number or function. `children="…"` as an attribute is the
  piece's `children`, as text.
- **No slots.** Markup written between `<dc-import>` and `</dc-import>` is not passed down, drawn,
  or an error: a piece that needs a different inside takes it as a prop (a string or a list) or is
  two pieces. This is what the runtime does with the format as documented, and Shepherd adds no
  Shepherd-only extension for it (a `children` attribute with text is the whole of it).
- **Depth and loops.** Imports nest at most 8 deep (the deeper ones draw their placeholder and
  report "imports nest more than 8 deep"), and a board that imports itself, directly or through
  others, draws a placeholder where the loop closes ("a board imports itself"). A piece inside a
  piece is drawn before the board settles (`load()` returns with every level drawn).
- **Element ids.** Elements of a piece belong to it, not to the importer: they carry
  `data-dc-owner`, and the importer's numbering (Element ids) counts the `<dc-import>` only. A
  pick stops there (`DesignElementPick.piece`).
- **The usage index** (`DesignUsageIndex`, ShepherdProtocol): for every board, the boards that
  import it, the pieces it imports (and the ones it names that the design lacks), derived from
  each board's `<dc-import>`s found in the template tree (`DesignImports`). The store keeps each
  board's imports by its hash and rebuilds the index once per revision, re-reading only the
  boards that changed (`DesignStore.usage`, `SessionServer.designUsage`); a revision builds it
  once however many boards redraw.
- **`board_extract(path, element, piece, props?, size?, frame?, copies?, checkpoint?)`**
  (`designExtract` → `designExtracted`, `DesignExtraction.plan`): lifts one element (its id from
  `design_read` or `board_search`) into a new board beside the source and puts a `<dc-import>`
  in its place, as ONE change (the piece, the source and every replaced copy: one revision). The piece's
  `$preview` is the element's px size (or `size`); `props` turn text in the element into props
  (`{{ label }}` in the piece, `label="…"` on the import); `copies` (boards, or `"all"`) replaces
  other boards' exact copies of the element, whitespace aside, with imports of their own; copies
  that differ are skipped and reported, never merged. A refusal is `invalid_extract`, naming
  why: a piece name that is not a board name or is not beside or below the source, a board whose tags don't
  balance, an element id that names nothing or has moved, the board's root or `<helmet>`, a reserved or
  repeated prop name or text that is not in the element exactly once, an element with no fixed px
  size and no `size`, or a piece that exists. The piece needs no frame; `frame` gives it one.
- **Swapping a piece** is `board_search(usages: "Old")` then one `boards_edit` replacing the import's
  `name` in those boards. The skill says so.
- **On the Mac's canvas** (docs/design/design-tool.md › Shared pieces): a piece other boards import says "used in
  N boards" in its label; a board that imports a piece redraws (live view and snapshot) when the
  piece changes and a board that imports nothing does not (`DesignHost.Board.deps`, from the
  usage index; a live view loads again and keeps what it imported); a pick on a use offers **Go to
  Source** (the right-click menu and the Tweak tab's note), which picks the piece's board whole and
  brings it into view; and Tweak writes no style on an instance (the note says to change the piece).
  Not built: a Components page, remote clients' usage labels and dependency redraws (the usage
  index is the host's, and no remote message carries it), and dependency tracking for thumbnails
  and the @ picker's pictures, which redraw when their own board changes.
- **Budgets.** One revision derives one usage index (`DesignToolsStoreTests`), and one piece
  edit redraws exactly its importers (`DesignSharedPiecesFlowTests`); `DesignPerformanceTests`
  is unchanged.

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
- **`booted`** comes once imports, hoisted stylesheets, fonts and images have settled, or after three seconds.
- **Snapshots** are `boardSize` from the top left, at the view's backing scale (1× offscreen).
- **Export.** `staticPage()` answers the board as a standalone page (the bridge's `staticPage`, in
  its own world); `printLayout()` its height, its lines of text and its images and drawings, and
  its paper's color, for a flow document's page breaks; `image(scale:)` and `pdf(_:)` draw it as
  an image and as PDF pages (Export).
- **An element's detail.** `elementDetail(tid:)` (the bridge's `elementDetail`) answers an
  element as a design reference hands it over: its markup as drawn, cleaned as a standalone page
  is (no script, no handler, none of Shepherd's stamps, cut at 512 KB), and the computed styles
  of it and up to 300 elements under it by child path, leaving out values that say nothing.

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
  420pt chat pane holding the agent's thread, with the thread's composer at its compact size, under a
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
  card), and its label counts them with the notes threads left on the design (Notes back,
  RefNoteBack's "Comments 2" over a comment and a note; `DesignScreenModel.commentsTabCount`). The
  chat's thread stays mounted under it.
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
  recently wanted first (`DesignLivePlan`). A live view's page always lays out at the board's
  `w` × `h` in CSS pixels, whatever the zoom: its web view is the board's size at a page zoom of
  1, scaled to the board's frame on screen (AppKit's bounds, UIKit's transform, so clicks and
  touches map through the same scale). Never WebKit's page zoom: it scales font sizes, so below
  about 56% its minimum font size swells text until labels wrap, above 100% the system font's
  size-dependent tracking narrows text until paragraphs rewrap, and at fractional zooms the layout
  viewport loses a pixel. Zooming changes no layout and reloads nothing; above 100% a live board
  is its 100% drawing scaled up, like a snapshot. A live view shows once its first snapshot is
  taken. During a zoom gesture every board draws its snapshot;
  live views follow once the canvas rests.
- **Snapshots.** Every other board draws its last snapshot, rendered by one off-screen view at a
  time (`DesignRasterizer`), so any canvas holds at most six web views. Snapshots are kept per
  design within a pixel budget, never evicting a board on screen. A hidden design gives up its
  live views and keeps its snapshots.
- **Live reload.** A write that changes a design's files pushes `onDesignRevision` for the designs
  on screen, at most once per frame. The canvas pulls the snapshot and hands the renderer only the
  boards whose hash changed: a live board takes its new source in place (`replaceSource`, no
  navigation, its state kept; source the runtime refuses leaves it as it was), and any other board
  renders one new snapshot. New boards appear and removed boards leave.
- **Dependencies.** A board that imports a piece redraws when the piece changes: the host marks
  each board with the pieces it imports (`DesignHost.Board.deps`, from the usage index), a changed
  hash in any of them counts as the board's own change, and a live view loads again (keeping what
  it imported) rather than taking its source in place. A board that imports nothing is not
  redrawn.
- **The agent's pictures.** `board_render` (the server's `onDesignRender`, served by
  `ShepherdViewModel+DesignRender`) draws in a view of its own, off screen, one request at a
  time, from the files the server read (`DesignRendering.picture(for:)`): it holds no canvas slot
  and works with the design off screen.
- **Budgets** (`DesignPerformanceTests`, over 172 boards): at most six web views, panning recycles
  them, one board changing redraws one frame (`design.board`) with one snapshot, a board
  dragged redraws its own frame once per step and no other, and zooming never reloads a live
  board or changes its page zoom. The Designs
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
- **A use of a shared piece** offers no style (the piece draws it): the Tweak tab shows a Shared
  piece note and Go to source instead of the groups (`DesignTweakTarget.instanceOf`; Shared
  pieces). A data-props or Reset write never happens on one.
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

A Claude Design project exported as a ZIP or a folder becomes a new standalone design (decision 4;
no project needed or chosen), from File ▸ Import Claude Design Project… (⇧⌘I, `.importDesign` in
`KeybindingsStore`), New design's "Import a project" card, or a drop on the Designs page. Shepherd
has no link to claude.ai: it is always a file. The source is only read. It runs in two halves on
the server (`SessionServer.prepareDesignImport`, then `finishDesignImport`), so nothing is in
Designs until the viewer's choice, if one is needed, is made.

- **A ZIP is checked before anything is unpacked** (`DesignArchive`, ShepherdProtocol): its table
  of contents is read from the file's end (ZIP64 too): an archive over 1 GB, a name that is
  absolute, climbs out (`..`), uses a backslash or a drive (zip slip), a link or a device (by its
  mode, whichever system the ZIP says made it, as ditto reads it), a file over 16 MB, or entries
  unpacking to over 1 GB are refused. Only then does `/usr/bin/ditto -x -k` unpack it, into
  `.unzip-<token>/` beside the designs, off the server's queue and the design store's (a queue of
  its own), and the unpacked folder is checked again as any folder is. ditto unpacks what the
  data holds, not the sizes the table claims, so what lands is measured every 100 ms and ditto is
  stopped once it passes 1 GB: a ZIP that understates its sizes is refused as too large rather
  than filling the disk.
- **Which folder.** Where the ZIP or folder holds `canvas.json` or `project/canvas.json`, else the
  one folder it holds that does (a ZIP of a folder). A folder holding `project/` brings `assets/`
  from a Shepherd export too. Everything else is left behind.
- **Rules** (`DesignImport`): links anywhere in what is read are refused, as is anything that is
  neither a file nor a folder; every name passes the path grammar's segment rule; at most 16 levels,
  512 files, 16 MB a file and 1 GB in all (`maxProjectBytes`; an export still reads at most 256 MB
  of a project's other files); uploads are `assets/<id>.<ext>`. Each file is opened without
  following a link and checked for its size before it is read. Hidden files and any `support.js`
  (Shepherd serves its own runtime there) are left behind. Imported geometry uses the safe numeric
  rules above, not the narrower authoring size range; original metadata and tall flow sizes stay.
- **Boards** are read in canvas order and copied into `.import-<token>/` as they are, the
  progress counting them (`DesignImportProgress`: checking, then "7 of 12 boards", then opening).
  A board whose markup points outside the project (`DesignImport.outsideReferences`: a `src`,
  `href`, `poster`, `srcset` or CSS `url()` that climbs out of the project from the board's
  folder, a `file:` URL, or a path on a disk such as `/Users/…` or `~/…`) refuses the whole
  import. A listed board whose file is empty or isn't text is unreadable: that is the viewer's
  choice (Cancel import, or leave those boards out, their files and canvas entries, on purpose).
  A listed board with no file at all is kept listed, as before (an imported index's problems
  don't block).
- **Failures** (`DesignImportFailure`, in ImportFailed's words): not a project (no canvas.json), too
  large (the project, checked before unpacking, or one file), links outside (listing up to three,
  "boards/hero.html → ../shared/logo.svg"), unreadable boards, or refused with a reason (a bad name,
  too many files, a canvas this build can't read). Every one leaves nothing behind: staging is
  removed, and so is anything unpacked.
- **The canvas** is kept byte for byte, every key with it; one without a title is titled after
  the ZIP or folder (its name without `.zip`), still keeping every key. A copy imported under
  another name, or with boards left out, is the same canvas merged with the new title and without
  those boards' entries.
- **Import again.** A project already in Designs (`DesignImportOrigin.isSameProject`: the same
  `createdOnFiles` stamp, else, where either has none, the same title) is never merged: the viewer
  imports a separate copy under the next free number ("Checkout funnel 2", `DesignNaming`), or
  opens the one there is.
- **Its design system comes along** as a system of its own (`DesignSystemStore.adopt`), marked
  with the design it came with (`DesignSystemInfo.cameWith`): the files of each system the canvas
  lists under `designSystems` whose `ds/<namespace>/` it holds and whose `tokens.json` Shepherd
  reads, only a system's kinds of file. A system this host already has with the same files is
  used instead of adding a second (the preview says so), else it takes the namespace or the first
  free `<namespace>-2`, …. The design is drawn in the first, under the name it was kept as
  (`Design.systemNamespace`), never in a different system that happens to share its namespace.
- **Atomic.** Only finishing moves the staged folder into place whole and then commits the
  record; a refused or failed import, a cancel, or a quit leaves nothing behind.
- **First open** (ImportDone): the app opens the design and starts its agent with a first message
  saying the design came from Claude Design (the file's name) and asking it to read the boards,
  notes and design system, run design_check, say what it found, change nothing until asked, and
  ask what to work on first.

## Design references

A design reference hands a thread a piece of a design on purpose: the whole design, a board, or
one element of it (docs/native-thread.md › Design references). It is the only way anything of a
design reaches an ordinary thread (Design agents and ordinary threads, above), and it never
reaches a design's agent. The whole feature waits behind Settings ▸ Experiments ▸ Design tool.
"Implement in a thread…", "Copy reference", the composer's @ picker, the reference chip and the
canvas's thread pins are built on the Mac from DesignRefStates and the Ref* boards (On the Mac,
below; docs/design/design-tool-references.md › Design references); the model below is what they call.

### The reference

`DesignReference` (ShepherdProtocol) names the host (`local`, or a remote host's id), the design,
optionally a board (nil: the whole design), optionally an element of that board (`tid:path`), and a
pinned revision; its label ("Checkout › A · Funnel first › button “Pay now”", each part one line
cut short) is for chips and menus and never travels. Its string is what Copy reference copies:

```text
shepherd-design-ref://<host>/<designID>[/<board view name>[#<tid>:<path>]][@<revision>]
```

- **By id only:** a design folder's id, the board's view name (`flows%2FCart.dc.html`) and the
  element's halves. Never a path on disk, a token, or anything the design's files say.
- **Not `shepherd-design://`,** the board sandbox's scheme, which WebKit serves boards from.
- **Read forgivingly:** whitespace and line breaks around it, wrapping `<…>`, quotes or
  backticks, the scheme and host in any case, lower-case escapes, a trailing slash, and a board
  written as its path. Anything outside the grammars (a board with `..`, under `ds/`, or with
  characters a board path can't hold; an element with no board; an element's rendering index; a
  revision that isn't a number) is no reference.
- **Pinned when picked:** `SessionServer.pinDesignReference` (Copy reference, the @ picker, the
  Implement sheet, a pasted chip) checks the design is here, the board on its canvas and the
  element in its source, and pins the reference at the design's revision then. The complete bounded
  rendering input set is kept: canvas.json (unknown keys intact), project files, installed tokens
  and uploads. `DesignStore.pinBoards` writes content-addressed board and blob files under `pins/`;
  `pins/index.json` maps each revision to those inputs and each whole-design pin to its board set.
  Capture serves only these immutable bytes, including boards removed from today's canvas. Props,
  frame and CSS-only edits count as updated since, even when board text is unchanged. Source-only
  pins from older builds still answer source reads, but cannot capture an old rendering: that send
  returns `version_gone`, never a current rendering labelled as an older revision.
  The newest 200 revisions are retained; after the trimmed index is written successfully, only
  unreferenced hash objects are removed. An unreadable or unwritable index refuses the pin and
  never authorizes collection. Inputs are capped at 16 MB per file and 256 MB per pin; a pin over
  the cap fails explicitly rather than omitting dependencies. Freshness reads historical hashes
  from the manifest alone and hashes current files one at a time without retaining their bytes. It answers `PreparedDesignReference`: the pinned, labelled
  reference, what the host read (the design's name, the board's title and size, the element's
  words and `data-el` name or tag), and `outline` (`DesignReferenceOutline`), what a send of it
  carries, which the sheet's footer says (`DesignReferencePresentation.sends`: "Sends a picture,
  its HTML, 11 styles and 8 tokens from acme-web."). The footer and the copy count by the same
  rules from the same source (`DesignReferenceService.reading`): styles are the CSS properties the
  piece's elements declare inline (`DesignReferenceReading.declaredStyles`; custom properties are
  tokens), tokens the installed systems' tokens it reads.

### Sending one

`NativeThreadStore` keeps up to five references beside the draft (`attach(reference:)`, one per
piece: a later one, "Send vN" among them, takes the older one's place; `NativeAttachedReference`:
the pinned reference, its label and outline) and sends them with the next message;
`send(text:references:)` sends at once without touching the draft. A message with references
reads its words, then "1 design reference attached." (the count, nothing the design says). The
send carries each reference's string alone (`NativeThreadRequest.send`'s `designReferences`,
`designReferences` in `supportedActions`).

- **The host keeps a copy** (`SessionServer.nativeThread` → `captureDesignReferences`, off its
  queue): the design is here, the board on its canvas, the element in the board's source; a
  design's agent, another Mac's design, more than five references, or a piece that is gone is
  refused and nothing goes. Each reference is resolved at the revision it pins (a whole design:
  the boards it held then, even when the canvas has others first now), and its copy is kept with
  the message (below). A pinned version no longer kept is refused (`version_gone`), never swapped
  for the design as it is now: only "Send vN" sends a newer one. A reference with no revision is
  pinned as it is now. Nothing is kept if any of it fails, and with no app to draw the
  copy the send is refused (`render_unavailable`).
- **pi reads it fenced** (`DesignReferenceFence`): a line saying it is data, then one JSON
  record per reference between `design-ref` markers carrying a nonce new to the message: its
  pinned string, what the host read from the files (the design's name, the board's view name,
  title and size, the element's id and words, the revision), the copy's id and its files' paths
  (a whole design's: how many boards it holds, of how many). What a client sent beyond the string
  is never kept. The fence always goes first, so words starting with "/" stay words, and such a
  message goes to pi on its own, never joined in the queue. It is the only fence such a message
  carries: a design view record sent beside it is dropped (`RPCThreadState.sendContext`).
- **Only the user's own message draws its references.** The thread takes the fence off, and
  carries its records (without the copy's paths) as the message's `designReferences` for the chip,
  only for a message the user sent in that thread: one the host dispatched or delivered from its
  queue carrying copies it kept for that send (`Dispatch.designPayloads`,
  `QueueItem.designPayloads`), whose fence names those copies and no other (never ids read from
  the text alone: a peer agent's prompt or a client typing a fence reaches pi as a send too), and
  whose origin record (`ThreadOriginStore.Record.references`, kept per pi session, so it
  outlives a relaunch and a session preview reads it too) names every copy the fence carries. A
  message that arrived any other way (another agent's `agent_send`, an extension) shows the fence
  as text, and so does a fence whose records name no copy. The palette's transcript search and
  notifications take the fence off to show the words. Clients that draw no chip (the iOS client,
  for now) show the words and the "1 design reference attached." line.
- **Grants.** A send grants the thread's agent the copies it kept (`Agent.designGrants`,
  persisted, empty in older files; each grant names its copy, `payload`): design_get reads those
  copies and nothing else, and only once pi has the message: while it is on its way or waits in
  the host's queue (steering included) its copies are withheld
  (`RPCThreadState.withheldDesignPayloads`), so design_get and design_note answer `not_granted`
  for them. A send pi refused, or a queued message deleted before pi read it, takes
  its grants and copies back; such a message can't be restored (Undo leaves it out). The same
  piece sent twice keeps both copies (each message's chip reads its own). An agent keeps at most
  100 grants, the oldest (and their copies) going first. Deleting the agent takes its grants and
  copies. Deleting the design keeps them: the copy was sent with the message and still reaches the
  agent (the chip says the design is gone). Startup drops a design agent's grants and grants from
  before copies were kept, and removes copies no grant names.
- **Remote:** a reference goes only into a thread on the Mac that runs it. A remote client's
  send with references is refused (`design_references_local`), and `RemoteHostClient` refuses
  one before it goes; a reference to another Mac's design is refused (`remote_design`). The
  picker lists this Mac's designs only; the chip's "another host" and "host offline" states and the
  picker's host tags are ShepherdUI states the app doesn't reach yet (`DesignReferenceFreshness.hostOffline`,
  `DesignMentionHost.remote`).

### The copy

`DesignReferencePayload` (ShepherdProtocol) is what a reference sent, resolved once when the
message went and kept with it under the support directory's
`design-refs/<agent>/<payload>/` (`DesignReferencePayloadStore`, on its own queue; never the drop
folder, which is pruned after a day). `payload.json` is the manifest; beside it:

- `<stem>[-<tid>]@2x.png`: the board, or the element cut from it, at twice its size;
- `<stem>.html`: the board's standalone page (Export's: no runtime, no scripts);
- for an element, `<stem>-<tid>.element.html` and `.styles.json`: its markup and computed styles
  (`elementDetail`), the element's own computed styles also in the manifest;
- `<stem>.source.dc.html`: the board's source as it was sent (`changes` compares two copies);
- `<stem>[-<tid>]-tokens.md`: the installed systems' tokens the piece reads, each with the file and
  line it came from when the system was built from a repository, and each `<x-import>` component
  with the system's source component for its export;
- a whole design: each board's picture, page and source (`01-<stem>@2x.png`, …), at most twelve
  (`DesignReferencePayload.maxBoards`), in canvas order, and how many boards the design had.

The app draws it (`SessionServer.onDesignReferenceCapture`, `DesignRendering.capture`): each board
off screen at zoom 1 in a view of its own, the pinned source swapped in (`replaceSource`) when the
file on disk moved on since (the head's lines are the file's). The server's queue never renders
or reads files; nothing but paths crosses the socket. The chip reads the copy
(`SessionServer.designReferencePayload(agentID:payloadID:)`), so it keeps showing what was sent.

**Freshness** (`DesignReferenceFreshness`, DesignRefStates' chip states), computed by the host off
the main thread and its queue: `current`; `updatedSince(latest:changes:)`, the design's revision now
and short lines of what changed in the piece since the copy (a sent chip,
`designReferenceFreshness(agentID:payloadID:)`) or since the version pinned (a chip in the
composer, `designReferenceFreshness(_:)`): an element's own style changes ("padding 24px → 20px",
a token by its name), its words, and elements added or removed inside it; a board's elements; a
whole design's boards (`DesignReferenceReading.changeLines`, `designChangeLines`, six lines at
most); `deleted` when the design or the board is gone. "Send vN" (`sendLatestDesignReference`)
puts the same piece pinned at the revision now in the composer in place of the older chip; nothing
newer reaches the agent until the user sends it.

### The @ picker

`SessionServer.designMentionCatalog()` answers `DesignMentionCatalog` (ShepherdRemote): this Mac's
designs (most recently active first; a design being built as a design system is left out), each
design's boards in canvas order, and each board's elements (at most 300: those with words or a
`data-el` name, leaving out the runtime's scaffold and an element that only repeats its parent's
words), each row with its breadcrumb and the design's revision. An element's row says what it is
and holds (`DesignElementSummary`, from the source): a kind noun, then the first run of like
children in it or up to three levels under it counted with their noun (their `data-el` name, a
loop's `as`, else row, bar or card: "funnel bars · 5 steps", "list · 5 rows"), or its place among
like siblings qualified by its parent's name ("KPI tile · 1 of 4"), with chips (buttons, links or
pills of a few words) listed by their words ("chips · All platforms, Web, iOS, Android"), else
what it is and how many elements it holds. A board's element count is the rows the picker lists
on it. It is derived off the main thread and the server's queue, and a design unchanged since the
last call is not read again (`DesignMentionCache`, by revision).
`rows(in:)` gives a scope's rows (the designs; a design's own row, the whole design, then its
boards; a board's own row, "Whole board", then its elements), and `search(_:)` matches every level
by each word of the query, in the catalog's order. The composer keeps the results whose own name
holds a word of the query (the path places each; RefAtSearch), so a design named for the query
doesn't list every board and element in it.

The read is asked once per opening of the picker, and the picker says where it stands before it has
rows (`DesignMentionLoad`, `DesignReferenceChips.startCatalogRead`): "Loading designs…" until the
first answer, "Couldn't load designs." with Retry after 15 seconds
(`DesignReferenceChips.defaultCatalogTimeout`), and "No designs yet" or "Nothing matches" only after
an answer. Each read has a number and an answer to a read a newer opening replaced is dropped; a
catalog already read keeps its rows through a later read and its failure.

### The New thread page

A thread can start from design pieces (docs/design/pages.md › New thread page › Design references).
`NewThreadState` keeps the chips (`references`, pinned by `prepareDesignReference` as the picker
picks, at most five, each piece once: `[NativeAttachedReference].attach`), and the page's own
`DesignReferenceChips` (`ShepherdViewModel.makeNewThreadReferenceChips`) reads the catalog and
draws the chips and pictures for no thread. Send starts the agent without an opening prompt
(`NewAgentConfig.initialName` names it from the words or the first piece, provisional) and
`deliverOpeningDesignReferences` sends its first message through the host once pi serves, the way
Implement's new thread does (`sendDirectly`, 90 seconds' wait), carrying the prompt and the images
as the message's words: the same `nativeThread` send a thread's composer makes, so the record is
fenced, the copy kept, the agent granted it, and the thread draws the chip. The opening prompt's
own path (`OpeningPrompt`, the pending row) is not used, because it cannot capture a copy. A
project on another host takes none: Send is refused with the reason, and the picker opens on a note.

### design_get

`shepherd-design-refs.ts` gives an ordinary thread `design_get(ref, what)`, read only, and
`design_note(ref, text)` (Notes back, below). It loads for every agent that draws no design while
Settings ▸ Experiments ▸ Design tool and Settings ▸ Pi ▸ Design references are both on (a running
agent follows a change at its next start), inert without `SHEPHERD_DESIGN_REFS`, and registers its
tools only once the thread holds a reference: at load when the variable is `granted` (the agent
held a grant when pi started), else the first time a message arrives with the fence (pi's `input`
event). A thread that was never handed a piece carries nothing of them in its prompt.

design_get answers only from the copies the user sent to this thread, never the design as it is
now: a ref with a revision reads the copy sent at that revision, one without the latest sent.

| `what` | Answer |
| --- | --- |
| `summary` | The ref, design, board (title), element (words), size, the revision it was sent at, what the copy holds, and the other versions of the piece this thread was sent |
| `image` | The copy's PNG (the board, or the element cut from it, at twice its size), which the extension hands pi as an image (up to 4.5 MB); a whole design's: each board's, as files |
| `html` | The copy's standalone page (a whole design's: each board's), files |
| `element` | The element's markup and computed styles, two files; refused for a board or design |
| `tokens` | The installed systems' tokens the piece read, with their sources, and its components |
| `changes` | What changed from the previous version of the piece sent to this thread to this one: for a board, its elements added, removed and changed (matched by content, then by place), and how many moved; for an element, whether it moved, its tag, words or attributes, and what changed inside it; for a whole design, its boards. With one version sent, it says a newer one reaches the thread only when the user sends it |

- **The server answers** (`designGet`, answered with `designReference`) only for a copy the
  agent was sent (`not_granted`; `no_copy` when its folder is gone), never to a design's agent
  (`not_a_thread`), and refuses a ref outside the grammar (`invalid_reference`), an unknown aspect
  (`invalid_what`) and another Mac's design (`remote_design`).
- **Data, never instructions:** everything read from the design comes back between
  `design-data` markers with a nonce new to the answer (`DesignReferenceData`), cut at 128 KB so a
  reply fits the socket's 1 MiB frame; `changes` quotes a start tag on one line, cut at 300
  characters.
- **"Looked at…"** (NWActivityLine(.lookedAtDesign)): each answer carries
  `DesignReferenceLookedAt` (the piece, what the agent got: picture and its size, page and its
  bytes, styles, tokens and the files and lines they came from), which the extension keeps in the
  call's details. The thread joins consecutive design_get calls on one ref into one line
  (`DesignReferenceCall.calls(in:)`, ShepherdRemote) and reads what they got from the copy
  (`SessionServer.designReferenceLookedAt(agentID:ref:aspects:)`).

### Notes back

`design_note(ref, text)` leaves a short note on a board or element the thread was sent
("Implemented in #142 on agent/checkout-funnel."): `designNote`, answered with `designNote`
(`DesignThreadNote`). One paragraph of plain text, whitespace and control characters folded, at
most 500 characters (`invalid_note`); only for a board or element this thread was sent
(`not_granted`, `no_piece` for a whole design), on a design still here, never from a design's
agent; at most six in ten minutes per thread (`rate_limited`). A new note from the thread on the
same piece replaces its last; a design keeps at most 200. Notes are kept in the design's
`thread-notes.json`, beside `project/` and never inside it, so the design agent never edits or
reads them, and export, duplicate and remote sync leave them out. The canvas reads them
(`SessionServer.designThreadNotes`, hinted by `onDesignThreadNotesChanged`) and draws each as the
thread's pin (blue, a code glyph: never a comment, never the design agent), naming the thread
(`thread`, its name then; `agentID` opens it) and the version it was sent ("from v23"); Resolve
removes it (`removeDesignThreadNote`). A note is never shown to a design agent; one that ever is
goes fenced as data.

### On the Mac

The surfaces (docs/design/design-tool-references.md › Design references has their measures):

- **The canvas** (`DesignScreenModel+References.swift`): the selection is the reference (the last
  pick: an element, or a board picked whole; nothing selected, the whole design,
  `DesignReferenceSelection`). Implement… in the board actions (which float over an element's
  board too), the right-click menu (`NWDesignCanvas`'s `contextMenu`: it picks what the click landed
  on first, then answers the items as a native menu), the design's ••• (`DesignMenuAction.implement`,
  `.copyReference`), and the canvas-scoped ⌘↩ and ⇧⌘C (`DesignCanvasKeys`: a local monitor, only
  while the design shows and no terminal or board page has the keyboard, nor a text field holding
  text or the chat holding a draft; the chat's empty composer, which keeps the keyboard when the
  canvas is clicked, lets them through).
- **Implement in a thread…** (`ImplementSheetModel`, `ShepherdViewModel+DesignReferencesUI.swift`):
  the piece is pinned as the sheet opens (`prepareDesignReference`), so the footer's words are what
  goes. An existing thread is one of this Mac's that draws no design (`designAttachTargets`); a new
  one starts through the New thread page's creation (`startAgent`) in the chosen project, on a new
  worktree (`GitWorktree.add`, based per Settings ▸ Worktrees) named `agent/implement-<piece>` (a
  direction's letter dropped; "-2", "-3"… when taken), named "Implement <piece>" until the namer
  names it, and gets the piece as its first message. A thread whose store is polling (on screen,
  `isLive`) sends through its store; any other (the sheet's usual case: never shown, or shown and
  hidden since, whose store stays `ready` but has no host to ask) through the host, once its pi
  serves (`sendDesignReferences`, at most 90 seconds' wait), into the host's queue while pi works.
  The host's answer decides the outcome: a message it took is sent however the thread's layout
  changed meanwhile (never reported as a failure, never sent twice), and a refusal says why in
  the host's words. "Open
  the thread after sending" is remembered (`AppSettings.implementOpensThread`,
  `shepherd.designs.implementOpensThread`); off, the canvas keeps the screen and a toast offers the
  thread. Copy reference pins the piece and copies its string (`copyToPasteboard`).
- **The thread** (`Thread/DesignReferenceChips.swift`): `DesignReferenceChips`, one per local
  thread that draws no design while the Design tool is on (the `designReferences` environment
  value, nil otherwise), reads each sent chip's copy (its picture, scaled off the main thread, and
  what it holds) and how it stands, once per chip and again when a design changes, and the
  "Looked at…" lines' `DesignReferenceLookedAt`. A thread without it (another host's) draws each
  chip from its record, with no picture or state.
- **The composer** (`Thread/ComposerMentions.swift`): the mention is the draft's last "@" at its
  start or after whitespace with no line break after it (`ComposerMention`); its words spell the
  scope ("Design › Board › ", resolved by titles, `MentionScope.spelled`) and the filter after it.
  The picker's rows are derived once per change of the draft or the catalog
  (`MentionPickerState`), read from `designMentionCatalog()` each time it opens, with pictures from
  the renderer: a design's first board, a board's own (rendered on demand at thumbnail priority:
  `DesignBoardPictures`), and an element's own, cut from its board (`DesignElementCrops`). An
  element's picture is asked for only when its row comes on screen (the lazy list's rows); the
  shared rasterizer draws the board once per design revision, finding every element the picker
  lists on it in one call (`DesignBoardView.elements(tids:)`), the last two boards are kept to cut
  from, and the cuts (the thumbnail's 40×26 at 2x, from the element's top-leading corner) are made
  off the main thread and kept per revision. A cut landing redraws its own row alone. ⌫ with the
  caret at the start of the words (or in an empty field) takes the last chip back: the field binds
  its selection outside Observation (`ComposerCaret`). A pick pins the piece and attaches it (`attachDesignReference`); a paste
  that brings a whole reference word does the same (`ComposerReferencePaste`); a failure says why in
  the composer's banner. The iOS client draws no chip yet: its thread shows the words and the
  "1 design reference attached." line.
- **Notes back** on the canvas: read with the design's pulls and on `onDesignThreadNotesChanged`;
  a note's pin sits on its element's top-trailing corner where a live board finds it (after a
  comment's pin there), else on its board's corner; its card opens beside the pin, with Open thread
  (while the thread is here) and Resolve. The Comments tab counts notes with the comments.
- **A sent chip's preview** opens above the chip whenever the thread's visible part holds it
  above (measured from the thread's top in its own space, not the scroll view's, which starts
  under the thread's top margin), and below only when it doesn't.
- **Departures from the Ref* boards** (the user's call, 2026-09-27): the design's ••• menu lists
  Implement and Copy Reference without their chords; the canvas's right-click menu has no Delete
  until deleting a board is built, with Undo; the @ picker has no Files section until file
  mentions come in a PR of their own; other hosts' designs (the picker's host tags, the chip's "on
  another host" and "host offline") are ShepherdUI states only until remote references come; and
  a pinned version no longer kept is refused (`version_gone`), with Send vN offered for the
  current one.

## Deleting and importing on the Mac (DesignLifecycleStates)

Built on the Mac behind the Design tool experiment (`ShepherdViewModel+DesignLifecycle.swift`,
the words in `DesignLifecycle.swift`, the views in `DesignLifecycleViews.swift`).

- **Menus** (`DesignMenu`): a design card's (a right-click anywhere on it, or ••• on hover) holds
  Open, Rename…, Duplicate, Export… and Delete Design…; its row in Recents adds Remove from
  Recents; ••• in its own toolbar holds Rename…, Duplicate, Export…, Show Design System and Delete
  Design…. A host's design offers Open, Rename… (through the host's canvas update) and Delete
  Design…, which is off with its reason where the host doesn't offer `design.delete.v1`. A system's
  (its card, ••• on its page) holds Open, Re-sync from <repo> (a system read from a repo), Rename…
  (its title; the namespace stays), Duplicate and Delete Design System…; a built-in holds Open,
  Duplicate as a New System, and Delete Design System… off with the reason under it; a build still
  reading its repo holds Open and Delete.
- **Delete design** asks first (`DeleteDesignDialog`): "4 boards, their 23 versions and 2
  comments", "The design agent’s chat for this design", "Stays: acme-web, the design system it
  uses", "You can undo right after."; while the agent works, the warning (the boards it is
  drawing in the turn under way, by its board writes) and Stop and delete. Then the window goes back
  to Designs if it showed the design, the design and its agent leave every surface at once, and
  the toast says "Deleted Checkout funnel dashboard." with Undo until the host lets it go (nothing
  counts down). Undo restores it and starts its agent's pi again. A failure brings it back and the
  toast says why, with Try again ("build-01, where it’s saved, didn’t answer, so it’s back." for a
  host's design).
- **Quitting** within the undo window completes the deletion: state.json no longer lists the
  design, and quitting (or the next launch, after a crash) removes the set-aside folder. There is
  no Trash.
- **Delete design system** asks first (`DeleteSystemDialog`): what goes, "Used by 3 designs; they
  keep their copy." with their names (or "No designs use it yet"), "Built from dashboard-web. The
  repo isn’t touched.", "New designs can’t pick it."; a system still being built says the build
  stops and nothing it read is kept (Stop and delete). Its page, if shown, goes back to Designs. A
  failure keeps it and the toast names why, with Try again. There is no Undo.
- **Import** fills its card first among Recent designs (`NWImportingCard`: the tiles filling, the
  title shimmering, "7 of 12 boards · with Checkout DS", the bar), its system dashed among the
  systems ("came with Checkout funnel", "after the boards") until the boards are in; then the design
  opens. A failure or a question is a dialog (`DesignImportDialog`); Escape puts a staged import
  away.

### Not built yet

Not drawn on any board, so left out until they are: the Designs page with no designs, a design
still loading or failing to draw, the chat pane's •••, Present mode's own board (Present shows a board focused meanwhile), the board
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

For design references: remote references (a design on another host, the chip's "on another host"
and "host offline" states, the picker's host tags and dimmed offline rows) are drawn as ShepherdUI
states only; the picker lists no files; an element's picker row draws its board's picture and says
its tag and what is inside it; the right-click menu has no Delete (the canvas deletes no board);
the iOS client shows a sent reference as its words and the "1 design reference attached." line.
Not drawn and built plainly: a sheet whose piece couldn't be pinned (the footer says why and Send
stays off), a send that failed (the sheet stays, the reason under its fields), no thread yet (the
sheet opens on New thread), and a reference that couldn't join the composer (its banner).

## Remote

A host serves its designs to other devices over the remote listener (`designs.v1`), and each
device renders the boards itself: the host sends files, never pixels. The listener has no TLS;
a VPN or trusted network is the transport boundary, as for everything else it serves.

### The protocol

`RemoteRequest.design` carries a `RemoteDesignRequest`, answered with a `RemoteDesignResult`
(`RemoteDesigns.swift`, ShepherdProtocol):

| Request | Answer | What it does |
| --- | --- | --- |
| `list` | `listing` | Every design with a canvas (not a system build), most recently changed first: its record, revision, board count, open comments, and its first board's path, hash and size for a thumbnail; and the host's design systems |
| `index(id)` | `index` | The design's snapshot (index, revision, board hashes) and every file under `project/` a board may load, with its SHA-256 and size: boards, installed systems, stylesheets, fonts, images. Never `canvas.json` (the index) or any `support.js` (each device serves its own runtime) |
| `boards(id, paths, knownShas)` | `files` | The files among `paths` (nil: all) whose hash isn't the one `knownShas` names: changed only. Their bytes come inline while they fit 256 KiB (`designChunkBytes`); the rest are listed without bytes. Also the paths unchanged and the ones the design lacks |
| `file(id, path, sha256, offset)` | `chunk` | A piece of one file from `offset`, up to 256 KiB, while it still has that hash (`stale_file` otherwise: read the index again) |
| `asset(id, blobID, offset)` | `chunk` | A piece of an upload (`/_blob/<id>`) with its file name, hash and size; a download resumes from the next offset |
| `comments`, `addComment`, `replyToComment`, `resolveComment` | `comments`, `comment` | The host's comment mutations: the element checked against the board's source, the comment handed to the design agent fenced as data, each change at the comments' revision |
| `writeBoards`, `updateIndex`, `duplicateBoard`, `restoreVersions` | `boardsWritten`, `written`, `duplicated` | Tweak, a board moved, Duplicate and Undo, through `writeDesignBoards`, `updateDesignIndex`, `duplicateDesignBoard` and `restoreDesignVersions` with their checks and revisions |
| `system(namespace)` | `system` | One design system whole |
| `delete(id)`, `undoDelete(id)` | `deleted(DesignDeletion)`, `ok` | Delete and its Undo (`design.delete.v1`, offered with `designs.v1`): through the host's own `deleteDesign` and `undoDesignDeletion`, so the host holds the design for its undo window; an undo after it is refused (`design_refused`). A host without the capability answers `unsupported`, and a Mac client leaves Delete off with the reason |
| `sendMarkup(id, markup)` | `markupSent` | Pencil markup (`design.markup.v1`): the record checked against the canvas and the boards' sources, then handed to the design agent fenced, as a turn of its own; why it didn't reach the agent, or nil. Nothing is kept |
| `settleProposals(id, proposals, deliver, base)` | `proposalsSettled` | The viewer's answer to the agent's proposals, which the host kept as comments when the agent made them (`design.markup.v1`): each named proposal's comment settled (`proposalSettledAt`), all or none, at the comments' revision, once; with `deliver` each one settled now goes to the agent as a comment does |
| `watch(ids)` | `ok` | The designs this client shows; replaces the last set |
| `create(brief, systemNamespace)` | `created(designID, agentID)` | New design from another device (a design belongs to no project): the host checks the brief (trimmed, at most 8 KB) and the system's name on its queue, then its app makes the design as its own New design does (`SessionServer.onRemoteCreateDesign`), selecting nothing there. A host with no app to make it refuses (`unsupported`) |

- **Pushed:** `designChanged(id, revision, commentsRevision)` after each change to a watched
  design, one per write: a hint to pull, carrying no files. `capabilitiesChanged` goes to a
  client that lists `designs.v1` when the host's experiment turns on or off. Only a client that
  lists `designs.v1` may `watch` (`update_required` otherwise), so no other client is ever
  pushed a design frame.
- **The experiment:** the host offers `designs.v1` only while its Settings ▸ Experiments ▸
  Design tool is on (`SessionServer.setDesignsServed`), and refuses every design request while
  it is off (`designs_off`). A device shows design surfaces only for a host that offers it.
- **Answered by the server itself,** with no GUI hop, off its queue: files are read and written
  on the design store's (`RemoteDesignService`).
- **What is served:** only files under a design's `project/` (each segment by the file grammar,
  a link that leads out of it never followed, 16 MB a file) and its `assets/` uploads. A path
  outside the grammar is refused (`invalid_path`) before a file is touched, and an offset
  outside the file with `invalid_offset`. A piece reads only its own bytes once the file's hash
  is known for its size and modification time. A client keeps a download within the size its
  first piece named and the 16 MB cap.
- **Writes** go through the same server mutations as the host's own canvas, with the same
  checks: a board path outside the grammar, a board the lint refuses, a stale revision.
- **Sends:** the design agent's chat is its thread over the native-thread requests; a send's
  view record rides `designContext` where the host lists `design.context.v1`, fenced by the host
  as data.

### The client (ShepherdRemote)

- **`RemoteHostClient.design(_:)`** sends a request where the host offers `designs.v1`;
  `onDesignChanged` and `onCapabilitiesChanged` deliver the pushes on the main queue.
- **`RemoteDesignCache`** keeps remote designs' files by SHA-256, per host and design: bytes are
  checked against their hash before they are kept, which paths name which hash, uploads by id,
  and downloads under way (so a dropped connection resumes). It holds them in memory within a
  budget, giving up the designs used least recently, and optionally on disk
  (`<directory>/<host>/<design>/<sha>`).
- **`RemoteDesignSource`** is one design's files: `sync()` reads the index and fetches every file
  whose hash the cache lacks (a few to a reply, a large one in pieces, a stale file read again
  once), and it serves them to the renderer as a `DesignFileSource`, fetching a file not yet
  synced on demand and an upload in pieces on first use. It serves `canvas.json` from the synced
  index (fetching that index on demand for a fresh thumbnail), never through `boards`, so the
  first load and every recycled view receive persisted tweaks.
- **`RemoteDesignLibrary`** (`@Observable`) is one host's designs: its listing, a source per
  design, the designs on screen (`watch`), and the pushes for them.
- **Rendering:** `DesignSurface(designID:source:)` (DesignSurfaceKit) serves a source's files by
  the same scheme, grammar and sandbox as a folder's; `support.js` is always the device's own
  runtime.

### On the Mac

- **The Designs page** lists each connected host's designs under its name, after This Mac's
  (not drawn), their first boards drawn here.
- **Opening one** selects its agent on the host, whose layout draws as the design's screen
  (`RemoteDesignLayoutView`): the same canvas and chat pane as a local design's, the boards
  rendered from the files the host served, the chat its thread on the host. Moves, Tweak (its
  undo too), Duplicate, Variations, comments and replies go to the host; the host pushes changes
  for the designs on screen, and the canvas pulls what changed.
- **Its menu** (a card's, and ••• in its toolbar) renames it through the host's canvas update and
  deletes it on its host (`delete`, then `undoDelete` from the toast); where the host doesn't offer
  `design.delete.v1`, Delete is off with the reason. Duplicate, Export… and Remove from Recents
  are This Mac's alone for now.
- **Not yet:** a design whose agent is gone on its host doesn't open (it says so; only the host
  starts a fresh agent), the header's system chip and Export do nothing for a host's design,
  Tweak snaps to the board's own tokens (the project's stylesheets are on the host), a host's
  design agent is a plain thread in Recents rather than a design row, and a host's design
  systems aren't on the page.

### On iPhone

The iOS client's designs track (`App/iOS/Designs`; docs/ios/CONTRACTS.md) shows a host's designs
only while that host offers `designs.v1`, and follows its Design tool as it turns on and off
(`capabilitiesChanged`). Boards render on the phone from the files each host served by hash
(`RemoteDesignCache` in the app's caches folder, shared with the iPad's store through
`HostDesignLibraries`); nothing renders on the host. In the iPad's split view a design found in
search opens on its canvas (On iPad, below).

- **Rendering.** `DesignHost.swift` is the phone's one file that imports DesignSurfaceKit (the
  iPad's is `PadDesignRenderer.swift`). At most two web views live: the board on screen, and one
  off-screen renderer that draws tiles and the Boards sheet into images (cached by hash) and
  exports, one board at a time. A board view on iOS gets a viewport of the board's width at the
  zoom it is shown at, as on iPad, so it lays out as on the Mac, and it never scrolls inside its
  frame.
- **Where designs show:** Home's Designs row with its count, a design's agent as its design's
  Recents row ("design · 4 boards", opening the design; never a running, Needs you or finished
  thread, nor counted among a host's threads, and a system build's agent has no row), the
  Designs screen (MobileDesigns: tiles
  from each design's first board, then the design systems), search's Designs section and its "New
  design" action, and More ▸ Design systems.
- **A design** opens on its boards (a grid; not drawn), watched while on screen so new boards
  land, and a board opens full screen
  (MobileDesignBoard): pinch zooms (the board lays out at its own size, scaled to fit, as on the
  Mac; above its own size it is its 100% drawing scaled up), a drag pans a zoomed
  board, a sideways swipe moves between boards, and pins sit on their elements' top-trailing
  corners, found again by tid in the live board. A tapped pin raises its card, with "Design agent
  is updating <board>" while the design agent works and hasn't answered it, else its answer.
  - **Comment** on, a tap names the element under it (the bridge's hit test) and the review's
    comment editor pins a comment there through `addComment`, as the Mac's canvas does.
  - **Ask the agent** opens the design agent's thread, and the board's view record (the board on
    screen, and the element being commented on) rides the next send (`design.context.v1`).
  - **Boards** is a sheet of every board; **Export** and Share render the board at zoom 1 as a
    PNG (twice its size) or a PDF (print.md) and hand it to the share sheet.
- **New design** (not drawn) is a form: the brief, the host to make it on (only when several
  serve designs), and a design system; no project, since a design stands alone. The host makes
  it (`create`) and it opens.
- **Not yet:** replies, Resolve and a detached pin's note on the phone; a board's interactive
  Play and links; Tweak, moves and Duplicate; a design without an agent in Recents; Pencil
  markup (iPad only, below); push notifications and Live Activities (they need the push relay).

### On iPad

`App/iOS/DesignPad/` (docs/ios/README.md › Designs), for every connected host that offers
`designs.v1`: a host that stops offering it (its experiment off) takes its designs away at once,
through `capabilitiesChanged`.

- **The store** (`PadDesigns`) keeps each design's canvas for the app's run, and which designs
  are on screen in any window: their hosts push changes for those alone. It shares each host's
  `RemoteDesignLibrary` and the one `RemoteDesignCache` (48 MB in memory, files also under the
  app's Caches) with the iPhone's store (`HostDesignLibraries`), which tells a host the designs
  either has on screen, since a connection keeps one watched set, and hands its pushes to both.
- **Rendering** (`PadDesignRenderer.swift`, the iPad's one file that imports DesignSurfaceKit):
  one live board in the app (`DesignTouchLivePlan`: the board a tap asks about, then the
  selected one, then the one nearest the middle; a design taking it takes it from any other on
  screen) and one off-screen view that draws every other board's snapshot in turn, two web views
  at most; the `design-pad-pan` fixture pans a 64-board canvas and counts them. Snapshots are at
  most 640pt wide, 64 MB per design. A page gets a viewport of its board's width at the canvas's zoom, so it lays out as
  on the Mac and draws sharp (`DesignBoardView` on iOS). Web views not on the canvas wait on a
  stage at the back of the window, where WebKit still draws them.
- **Touch** (`NWCanvasTouchInput`): a drag pans, a pinch zooms, a tap selects or, with Comment,
  opens the editor on the element under it. Fingers and pointers only: an Apple Pencil's touches
  go to the markup layer over the canvas (`PadDesignMarkupLayer`, Pencil markup, below).
- **Writes** go through the host: comments, replies and Resolve at the comments' revision, Tweak
  (`DesignTweakModel`, shared with the Mac) with its board writes and undo, Duplicate; a stale
  revision reads the design again and goes once more. A send carries the canvas's view record.
- **Split View:** in a window narrower than 760pt the boards stack in one column, the chat is
  behind the header's button, and the design agent's latest reply floats over the canvas. "Send
  to the thread" (`DesignSpecHandoff`) attaches the boards picked on the page shown, else the
  page's boards (four at most, what one message takes), drawn first where they aren't yet, to
  the composer of the thread another window shows, with "Use the attached boards as the spec.",
  and brings that window forward; the viewer sends it. Nothing the design's files say (its
  title, a board's name) goes into that message: the thread it goes to reads no fence.
- **Export** shares the page's boards as PNGs through the share sheet, drawing any not drawn yet.

### Pencil markup

On iPad the viewer can draw on the canvas with an Apple Pencil (iPadDesign) where the host offers
`design.markup.v1` (with `designs.v1`, while its Design tool is on).

- **Ink** (`PadDesignMarkup`, `PadDesignMarkupLayer`): a PencilKit canvas over the boards that
  draws with the Pencil alone. Hit-testing gives it a Pencil's touches and leaves every other to
  the canvas, so a finger pans and pinches; where UIKit doesn't say which kind a touch is, the
  layer takes touches while there is ink and pans and pinches with a finger itself. The ink is
  kept in canvas points and drawn through the viewport, so it stays on its boards at every zoom.
  The palette (`NWMarkupPalette`) shows while there is ink: pen, marker, eraser, Comment (the
  canvas's Comment tool), three inks, Done.
- **Done reads the markup on the iPad** (`PadDesignMarkupReader`, `DesignMarkupReading`):
  - Each stroke's shape: a loop, a nearly straight line, a V (an arrowhead drawn on its own), an
    arrow drawn in one stroke, or none. An arrowhead joins the line whose end it sits on (a line
    longer than the writing); small shapes among writing are letters; a level line is an
    underline, any other line a mark; strokes with no shape group into writing by proximity.
  - Writing is read by Vision's text recognition, on the device; nothing goes over the network.
    Writing it can't read is a mark.
  - Notes go with marks: an arrow between a note and a loop or line ties them (and is no mark of
    its own); an arrow from a note to nothing marked is the mark, pointing away from the note;
    any other note goes with the nearest mark without one; a note with no mark is a mark where it
    is written.
  - Each mark's board is the one it overlaps most (else the nearest); its element is chosen
    among the elements the board reports under it (a loop's middle; a little above an underline
    at a quarter, half and three quarters along; an arrow's head) and their ancestors from the
    board's template, located on the live board: the best-matching box for a loop or mark, the
    element whose bottom the line runs along for an underline, the deepest under an arrow's head.
- **The record** (`DesignMarkup`, ShepherdProtocol): `{strokes: [{kind, board, element, label,
  note}]}`, 1 to 20 marks in the order drawn, each `kind` one of `circle`, `underline`, `arrow`,
  `mark`, its board by view name, its element (`File.dc.html#tid:path`, on that board) or none
  for the board as a whole, and its note on one line of at most 280 characters. The host
  refuses a record outside the grammar, or naming a board the canvas lacks or an element the
  board's source lacks (`invalid_markup`), reads each label from the source, and hands the agent
  the record fenced (`DesignMarkupFence`: a line saying it is data, then the JSON between
  `design-markup` markers carrying a nonce new to the message), then "Pencil markup · 2 strokes
  · 2 notes", as a turn of its own through the host queue, like a comment. The message's origin
  (`NativeMessageOrigin.designMarkup`) carries the counts. Sent ink stays on the canvas until its
  proposals are applied or kept; ink that couldn't go stays as it was. The palette shows while
  there is ink on the canvas, new or sent, and Done with nothing new puts it away until the next
  stroke.
- **The agent's answer.** The skill and the prompt have it read the marks, call `markup_propose`
  once with a comment per mark, say in a sentence which mark became which comment, and change no
  board until the viewer applies them. The host keeps the proposals as comments as the call
  makes them (iPadDesign: "Comments 3" beside cards 2 and 3), author the viewer, their pins
  placed by the device that shows them (the host draws nothing, so they carry no `rect`).
- **In the chat** (iPad): the markup message reads "Read your markup · 2 strokes · 2 notes" with
  the nib; the reply's `markup_propose` call gives way to the proposals card
  (`NWMarkupProposals`) under its words: comment cards numbered as their pins are, named
  "A · phone › Steps list", "from your markup". **Apply both** sends each comment to the agent as
  a comment is sent; **Keep as comments** leaves them on the canvas as they are; both settle the
  proposals through `settleProposals`, once, so the card reads "On the canvas as comments 2 and
  3." afterwards, on any device. The Mac shows the markup's words, the comments, and an activity
  line for the call.
