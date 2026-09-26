# Designs

The Design tool (an experiment, off by default) keeps each design as a canvas of HTML boards
that a design agent draws. This page covers the files and how they change. The canvas, the board
renderer, the agent's tools and the remote protocol come with later changes.

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
- **At startup** the server forgets a design whose folder has no readable canvas and clears
  references to what no longer exists. Which folders are gone is read on the design store's
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

Reads are `designSnapshot(_:)` (the index, the revision, and every board file under `project/`
with its SHA-256, listed or not) and `designBoard(_:path:)`.

- **Revisions.** Each design has a revision that moves with every change to its files. It is kept
  on disk, so a base from before a relaunch still compares. A write naming a `baseRevision` the
  design has moved past is refused (`stale_revision`): read again and redo the change once. A
  write that changes nothing moves nothing.
- **Atomic.** Files are written to a temporary file and renamed into place.
- **Index entries need files.** A board the index adds or changes must have its file. A board it
  removes loses its file.
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
