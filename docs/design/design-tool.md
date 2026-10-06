# Design tool

> Read when you work on the Design tool (Settings ▸ Experiments ▸ Design tool): designs, canvas, comments.

**Partly built, on the Mac, behind Settings ▸ Experiments ▸ Design tool (off by default).** Built:
the Designs destination and page, design rows in Recents, New thread's Start a design, New design,
and a design's canvas beside its chat, with the design agent, live reload, Select (elements and
boards picked on the canvas, their view record sent with each chat message; docs/designs.md),
comments (pins, threads, cards in the chat and the Comments tab, answered by the agent),
Tweak (its tab, written once per gesture, with Reset and Undo over each board's versions), the
board actions, boards moved by dragging, Present (decision 11:
the board focused over a scrim, its links playing) and Play, and pages with title and sticky
notes, design systems (the format, the store, installing one in a design, `system_read` and
`system_write`, `design_check` against it, `<x-import>`, Night Watch as a built-in, the system
page and its Re-sync, the Designs page's systems grid with "Build one from a repo", More ▸ Design
systems, the system chip opening its page, and New design's system card;
docs/designs.md › Design systems), Export (its sheet, the four formats and Attach to a thread;
docs/designs.md › Export and import), and deleting (with Undo), renaming and duplicating designs and
design systems and importing a Claude Design project from a ZIP or a folder (Delete and import,
below), shared pieces (a board other boards import: its "used in" label, Go to Source and Tweak's
note on a use; Shared pieces, below), and design references (Implement in a thread…, Copy reference, the composer's @ picker,
the reference chip, the agent's "Looked at…" line and the thread's note back on the canvas;
Design references, below). Not built: the live link, Attach to a mission, Present
mode's own board, Tweak snapping to an installed system's tokens, and every iPhone and iPad part;
each subsection below says what of it is built. On iPhone, a host's designs show while that host
serves them (docs/designs.md › On iPhone); the iPad's parts are not built yet. The canvas marks the whole page an
experiment. This section is the spec to build it to, board by board: the Design tool page (DZStart,
DZCanvas, DZTweak, DZSystem, DZExport), Night Watch's Design tool components (NWDesignTool,
NWDesignToolLight), the Designs destination (NavDesigns, MobileDesigns), and the phone and iPad
boards (MobileDesignBoard, iPadDesign, iPadSplitView). Where a board's value falls outside the
tokens, it is stated here as the board draws it; don't round it silently, decide it first.

**What it is.** A design is a set of **boards**: HTML mockups on a canvas you pan and zoom, drawn
and refined by a **design agent** in a chosen **design system**. You describe a page or flow, the
agent draws a few directions, and you refine them by chatting, by commenting on an element, or
by dragging a tweak control. The agent is an agent like any other: its chat is a thread, and its
tool work reads as activity lines.

**Rules that hold on every design screen:**

- **Boards keep their own design system; everything around them is Night Watch.** A board
  renders in the design's system (its fonts, colors, and components) and never takes Shepherd's
  tokens or appearance. The canvas, the chat, the comments, and the controls are Shepherd chrome
  and follow this document. "The boards themselves use the product's own design system; this is
  the chrome around them." (NWDesignTool)
- **Comments pin to elements, not boards.** A comment names its board and its element ("on
  A · Checkout funnel"), and the agent answers under it once it has made the change.
- **Pins are lantern,** because a pin is something you asked for (Lantern means you). Selection
  on the canvas (a board, an element) is running blue.
- **Values come from the system.** A tweak snaps to the design system's tokens, and a color is
  always one of its tokens, never a free hex (NWTokenChip). Every board the agent draws is
  checked against the system before you see it, and anything off-system is fixed or flagged
  ("Checked against acme-web · 0 off-system values"; DZSystem's chat: "Every board I draw is
  checked against this before you see it. Anything off-system gets fixed or flagged.").
- **Board labels** read "<direction letter> · <name>" ("A · Funnel first", "B · Step table",
  "C · Trend first"), and a board drawn for another size of the same direction adds the size
  ("A · phone"). A board's size is its CSS pixel size in mono ("1280 × 800", "390 × 844").
- **Counts are the board's words:** "4 boards", "2 comments", "3 directions + phone",
  "18 tokens · 9 components".
- **Not drawn on any board**, so design them before building: the Designs page with no designs,
  a design still loading, a failed drawing or sync, an offline host, Present mode (until it is,
  Present shows the board focused: A design, below), the chat pane's •••, a shared piece's label,
  Go to Source and the Tweak tab's note on a use (Shared pieces, below), and keyboard shortcuts
  (Import's ⇧⌘I is ImportFileMenu's). Any shortcut added goes through
  `KeybindingsStore`.

## Where designs appear

- **Mac sidebar** (NavDesigns, DZStart, and every sidebar board): a **Designs** destination
  between Missions and Automations, its glyph the pen nib (the boards' nib; `pencil.tip` is the
  nearest SF Symbol), selected in `bgSelected` with its title semibold. A design in Recents shows
  the nib (13pt, `textTertiary`) in place of the status dot and its board count in mono 10
  `textTertiary` ("Checkout funnel dashboard  4 boards"). Built behind the Design tool
  experiment: the destination (selected on its page and on New design) and the design rows, whose
  agents have no row of their own and take no ⌘-digit.
- **iPad sidebar** (iPadSidebar and every iPad board with the sidebar): the same Designs
  destination between Missions and Automations, in its 44pt rows at 15, and design rows in
  Recents with their board count ("4 boards").
  **Built** for hosts that serve designs (`designs.v1`, their Design tool on): the destination
  (after New thread while Missions is hidden) opens the Designs list, and each design is a
  Recents row with the nib and "4 boards", placed by when it last moved; its agent's thread has no
  row of its own.
- **More ▸ Design systems** (NavHosts, iPadHosts, MobileMore): on the Mac and iPad a row "Design
  systems" nested under More, beside Extensions; on iPhone a More row "Design systems" over
  "2 · acme-web, Night Watch". Built on the Mac behind the experiment: the palette glyph
  (`paintpalette`), between Hosts and Extensions; it opens the system page shown last (not drawn)
  and is selected while a system's page shows.
- **New thread** (NavNewThread): the last of the suggestion cards under the prompt, "Need a
  mockup first?" (a 12pt nib in `textSecondary`, the words in 11.5 `textTertiary`), "Start a
  design" (13 medium), "HTML boards on a canvas" (11 `textTertiary`).
- **iPhone Home** (MobileAgents): a "Designs" destination row with its count ("4") between
  Missions and Automations; a design in Recents reads "design · 4 boards" in mono 11 under its
  name, with the nib in the leading slot.
- **Search and the palette** (MobileSearch, iPadPalette): a Designs section ("DESIGNS" on iPad)
  whose rows read the name (the match in `lanternText` semibold) over "acme-web · 4 boards". On
  iPhone the results also end in an action row, "New design" over "“funnel” as the brief" (the
  query in `lanternText` semibold); the iPad palette draws no such action.
- **Live Activities** (MobileIsland): the design agent's compact activity is the nib, the design
  in mono ("Onboarding") and "2/4" (boards drawn so far); expanded, the name, "2 of 4", the four
  boards as thumbnails that fill in as they are drawn (the one being drawn shimmers), and "Open
  boards".

## Designs (NavDesigns, MobileDesigns)

**Mac: built** (`DesignsPage`), except a card's "2 comments" and the Night Watch skeleton. The
systems are the host's (docs/designs.md › Design systems › In the app); a design without one
names no system (designs stand alone, below: a card never names a project). A system build still reading its project is a card with no swatches over
"dashboard-web · building" (not drawn). With no designs the page shows its header and the
systems. Not drawn, and built plainly: each connected host that serves designs (`designs.v1`)
lists its designs after This Mac's, under the host's name in the section label's style, in the
same cards; one opens on the same canvas beside its agent's chat on the host (docs/designs.md ›
Remote). **iPhone: built** (`DesignsScreen`), with these choices: New design is the navigation
bar's prominent button in `lantern` and Search a plain one (the bar's glass, not the board's
outlined circle); a design the agent is drawing reads "drawing · 2 boards" (the host doesn't say
how many boards it will draw, so not "2 of 4"); a tile's background is its board's own (its
top-leading pixel). Not drawn, and built plainly: a host that serves no designs (the screen says
so), no designs yet, a design's own screen (its boards in the tiles' anatomy, with Ask the agent),
and a system's screen (its counts, colors, type and steps as rows).

**Mac** (NavDesigns): the Designs destination fills the main column.

- **Header** (the toolbar row, 52pt on the board as on every toolbar board; see Toolbar):
  "Designs" in `title` at 24pt leading padding, a spacer, a 220pt filter field (`NWSearchField`;
  the board: 28pt, radius 6, a 1px `lineSubtle` line, a 12pt glass and "Filter designs" in 12
  `textTertiary`), and the primary **New design** (`plus`, `.buttonStyle(.nw(.primary))`,
  28pt). 12pt between them, 16pt trailing padding.
- **Content**: 20×24 padding, 26pt between sections. Each section has a plain label in 12
  medium `textTertiary` ("Recent designs", "Design systems"), 12pt above its grid.
- **Recent designs**: a four-column grid, 16pt gaps. A **design card** is a radius-10 card with a
  1px `lineSubtle` line and the hover fill. Its top is a 172pt thumbnail on `bgBase` with the
  canvas's dot grid at 16pt, a hairline under it, and the design's first board centered in it
  (256×160 for a desktop board, 74×160 for a phone board) in its board frame. Under it, at
  12×14 padding and 5pt apart: the name in 13.5 semibold; the system's name in mono
  `textSecondary` then "· 4 boards · 2 comments" in 11.5 `textTertiary`; "edited 2h ago" in 11
  `textTertiary`. A design in Night Watch ("Settings redesign") draws a Shepherd skeleton: a
  `bgWindow` window with a `bgBase` sidebar and `lineStrong` text bars. The selected card wears
  a 2pt `textPrimary` ring.
- **Design systems**: a three-column grid, 16pt gaps, of system cards (radius 10, 1px `lineSubtle`,
  12×14 padding, the hover fill, 12pt between their parts): four of the system's colors as 14pt
  swatches (radius 4, 3pt apart, a 1px white 10% inner line), the name in mono 12.5 semibold over
  its source in 11.5 `textTertiary` ("dashboard-web · tokens.css"; Night Watch reads "Built into
  Shepherd" after its Built-in tag, as DesignLifecycleStates draws it), and
  the count trailing in 11 `textTertiary` ("3 designs", "1 design"). The last tile is dashed (1px
  `lineStrong`, radius 10, 12×14 padding): a 12pt `plus` and "Build one from a repo" in 12.5
  `textSecondary`, 8pt apart, centered.

**iPhone** (MobileDesigns), pushed from Home's Designs row:

- **Navigation**: back to "Home"; trailing, **Search** (a 36pt circle outlined in `lineStrong`)
  and **New design** (a 36pt `lantern` circle, `plus` in `textOnLantern`). The large title is
  "Designs" (30/600).
- **Recent**: a list header ("Recent" in 13 semibold `textSecondary` on the board; `NWListHeader`
  draws `caption` semibold `textTertiary`; Known gaps › iOS), then a two-column grid (14pt between
  rows, 12pt between columns). Each design is a 110pt thumbnail (radius 10, 1px `lineSubtle`, on the
  design's own background) showing its first board scaled to the tile, top-leading (a phone board
  centered); its name in 14 semibold, truncating; and "acme-web · 4 boards · 2m" in 12
  `textTertiary`. A design the agent is still drawing reads "drawing · 2 of 4".
- **Design systems**: under the same header, a list card (`NWListCard`, radius 12) of rows at
  least 52pt tall (8×14 padding, 12pt gaps, hairlines between): three 7×14 swatches (radius 2,
  2pt apart) in a 20pt column, the name in mono 15 medium over "dashboard-web · tokens.css" in
  12.5 `textTertiary`, and a chevron. Night Watch is the second row.

## New design (DZStart)

**Built** (`NewDesignPage`), without the Capture a page and From a screenshot cards (the design
tool plan's decision 9; they come later). **Designs stand alone** (the user's decision,
2026-09-26, superseding the plan's decision 10 that a design belongs to a project): New design
picks no project, and a design's agent works in the design's own folder, in a reserved hidden
space. The one card is the design system, drawn chosen: the one picked, else the system changed
last among those built here, else Night Watch. It keeps naming the repo a system was read from,
as information about the system ("acme-web", "design system · dashboard-web", "found in
web/static/tokens.css"); choosing it picks no project. Its menu (not drawn) picks another
system; Send installs the system in the new design. The composer card keeps `NWComposer`'s
radius 8. New design (the destination's button, "Start a design", or Search's action)
opens this page in the main column, with the sidebar showing and Designs selected.

- **Header** (52pt on the board; see Toolbar): the breadcrumb, 8pt apart: the nib (14pt
  `textTertiary`), "Designs" (13 `textTertiary`), "/" (`textTertiary`), and "New design" (13
  semibold). Nothing trails it. The board also draws the Show sidebar button (`sidebar.left`)
  ahead of the breadcrumb while the sidebar shows; follow Toolbar instead: the button shows only
  while the sidebar is not docked.
- **The page** is one centered column, 26pt between its parts, sitting a little above center
  (60pt more room below than above):
  - "What do you want to design?" at 26/600, tracked −2%, and under it, 12pt apart, "Describe
    the page or flow. The design agent draws it as HTML boards in your design system, and you
    refine it on the canvas." in `body` `textSecondary`, at most 560pt wide, centered.
  - **The prompt**, a 720pt composer card (`NWComposer`'s card: `bgRaised`, drawn focused, a
    `textTertiary` line in a 3pt `bgSelected` ring; the board's radius is 10, off the radius scale,
    and the composer's 8: settle which before building): the field (14pt padding, 4pt below, at
    least 72pt tall, `body`), placeholder "A checkout funnel dashboard for the product team…";
    under it the standard composer's row at the regular size (NWDesignTool › Chat composer):
    attach (`paperclip`, "Attach a screenshot or file"), the model chip, the thinking chip
    in the combined model-settings button, and Send (the composer's 28pt lantern circle, 35% until there is text).
    The model and level are This Mac's defaults (Settings ▸ Agents) until picked; the model
    picker and the model-settings popover open under the card, as on New thread, and the design agent
    starts on what they say. After that they stay with the design's pi session. There is no
    context ring before the design has a conversation. The board also draws "/ commands": left
    out for New thread's reason (no pi runs before the design exists to list its commands);
    see Known gaps.
  - **"DESIGN SYSTEM & STARTING POINT"** (`.nwSectionLabel()`), 10pt above three equal cards in
    a row, 10pt apart. Each card: 12×14 padding, radius 8, 1px `lineSubtle`, 6pt between its
    lines, the hover fill: a 13pt glyph and a title in mono 12 semibold; a line in 12.5
    `textPrimary`; a note in 11 `textTertiary`. The chosen card is `lanternTint` with a
    `lanternText` border and glyph.
    1. The design system found in the repo, drawn chosen: nib, "acme-web", "design system
       · dashboard-web", "found in web/static/tokens.css".
    2. `link`, "Capture a page", "paste a URL to start from", "staging or production".
    3. `photo`, "From a screenshot", "drop an image or a file", "PNG, PDF, Figma export".

## A design: canvas and chat (DZCanvas)

**Partly built** (`DesignScreen`: a design agent's layout). Built: the header (44pt, the app's
toolbar; the system chip opens its system's page, Export opens its sheet), the canvas with its board frames and
toolbar, the chat pane with its Chat, Comments and Tweak tabs and the agent's thread; its
composer is `NWComposer`'s card at radius 8, Select (Selection, below), comments (Comments,
below), the board actions, boards moved by dragging, Present and
Play, and pages with their notes. Not built: the tabs' •••. A
board frame's outline is `lineStrong` and its shadow the popover's (the board's black 30% and 35%
are off the tokens). Opening a design fills the main column: the header, then the canvas beside a
420pt chat pane. The boards draw it with the sidebar hidden.

- **Header** (the toolbar row, on `bgWindow` with a hairline; the boards draw it 52pt, as every
  toolbar board does; the app's toolbar is 44, see Toolbar): the sidebar button (`sidebar.left`,
  "Show sidebar") while the sidebar is hidden; the breadcrumb (nib, "Designs" in 13
  `textTertiary`, "/", the design's name in 13 semibold); a spacer; the **design system chip**;
  **Present** (`play.fill`, a 28pt icon button, "Present"); and **Export**
  (`square.and.arrow.up`, a 28pt secondary button). 12pt between the header's groups, 8pt
  between the trailing controls. A canvas with more than one page adds its **pages menu**
  before the chip (not drawn: `NWPopupMenu` with the page shown, each page by name, the current
  one checked).
- **Present** (decision 11, until Present mode is drawn): the board picked last (else the one
  nearest the middle of the view) focused over the canvas: the `scrim` over it, and the board
  fitted inside the canvas's 44 and 52pt margins, never over 100%, in its frame, with no label. It
  is the design's one live view while shown and takes its own clicks, so its handlers run and a
  link to another board of the design (`<a href="B.dc.html">`, or `/` for the canvas root) shows
  that board instead; any other link goes nowhere. Present lights up (its `isOn` fill) while a
  board is shown; Present again, or a click on the scrim, goes back to the canvas.
- **The design system chip** (`NWDesignSystemChip`): 24pt, 8pt padding, radius 6, a 1px
  `lineSubtle` line, three of the system's colors as 8pt squares (radius 2, 2pt apart), then its
  name in mono 11.5 `textSecondary`. Clicking it opens the system (Design systems, below). A
  design drawn in no system shows no chip: it has no project to name in its place.
- **The canvas** fills the rest, on `bgBase` with a dot grid: 1px `lineStrong` dots every 22pt.
  It pans (the Pan tool) and zooms (the toolbar shows 42% on DZCanvas, 72% on DZTweak); the
  boards draw no zoom limits.
  - **Boards** (`NWBoardFrame`) sit in a grid 44pt apart, from 44pt in and 52pt down. Each has
    its label 24pt above it: the name in 12 semibold (`textPrimary` when selected, else
    `textSecondary`) and, 8pt after it, its size in mono 10.5 `textTertiary`; a shared piece other
    boards import adds, 8pt after the size, "used in 3 boards" in sans 10.5 `textTertiary`
    (Shared pieces, below). The frame is the
    board's page at the canvas's zoom, radius 4, with a 1px black 30% outline and a soft drop
    shadow (0, 12, 32 at black 35%). A selected board wears a 2pt `running` ring outside the
    frame. Several boards can be selected at once (DZExport shows two); how is not drawn, and
    Shepherd uses shift (Selection, below).
  - No "Ask for another direction" tile follows the boards. Ask in the design chat for a new
    direction; the selected board's Variations action remains available.
  - **Board actions** (`NWBoardActions`) float above the selected board: Comment (`text.bubble`),
    Tweak (`slider.horizontal.3`), Variations (`square.grid.2x2`), Duplicate (`doc.on.doc`), and •••
    (a 28pt circle). On NWDesignTool: a `bgRaised` bar with 4pt padding, radius 12, 2pt between
    items, a 1px `lineStrong` line and the popover's shadow; items 28pt tall, 10pt padding, radius
    8, 6pt gap, a 13pt glyph in `textSecondary`, the label in 12.5 `textPrimary`. (DZCanvas draws it
    smaller: a 32pt bar at radius 10 with 26pt items at radius 6 in 12.) Comment pins a comment to
    the board's element you pick next; Tweak opens the Tweak tab. Built as DZCanvas draws it,
    over the board picked whole last (not an element): its bottom 2pt above the board's label,
    its leading edge at the frame's middle (DZCanvas: 332 over a board from 44 to 582), kept 16pt
    inside the canvas's sides and 4pt from its top, where it may cover the label of a board at the
    very top. Items fill `bgHover` on hover. Variations and Duplicate act on that board; ••• holds
    Play for an interactive board (`is_interactive`) and is disabled otherwise.
  - **Moving a board** (not drawn): with Select, a drag that starts on a board's label, or on a
    board picked whole, moves it; any other drag pans. It follows the pointer and is written
    once, where it lands.
  - **Notes** (not drawn): a page's title notes (`title1`) and stickies sit on the canvas under
    the boards, read-only, scaled with it: a title in 64pt semibold `textPrimary` (canvas points)
    wrapping at its `maxW`; a sticky's words in 16 on a `bgRaised` card with a `lineStrong` line,
    radius 8, 16pt padding, 240 wide unless it says. Drawings aren't drawn.
  - **Selection** (built; Select): a click on a board picks the element under it, a click on a
    board's label (or where the board names nothing) picks the board whole, shift adds or takes
    away, and a click on the empty canvas clears. Selected elements wear `NWSelectionRing` (Tweak,
    below: the ring over its `runningTint` fill, the handles), and the latest one its tag
    ("card · Checkout funnel": what it is, then its `data-el` name or its first words). The
    element under the pointer wears the ring alone, with no fill, handles or tag. None of the
    boards draws a hovered element, several selected elements, or which of them carries the tag,
    so these are Shepherd's until one does. What the canvas shows (boards on screen, the
    selection) goes with every message the chat sends, as data for the agent.
  - **Comment pins** (`NWCommentPin`) on their elements, numbered in order (below).
  - **The canvas toolbar** (`NWCanvasToolbar`), 16pt from the bottom-leading corner: a 38pt
    `bgRaised` bar, 4pt padding, radius 12, the popover's line and shadow. Three 30pt circle
    tools with 15pt glyphs: Select (`cursorarrow`), Comment (`text.bubble`), and Pan
    (`hand.raised`); the current one on `bgSelected` in `textPrimary`, the others clear in
    `textSecondary`. Then an 18pt `lineSubtle` divider (4pt margins) and the zoom in mono 11
    `textSecondary` ("42%").
- **The chat pane**, 420pt, a 1px `lineSubtle` line on its leading edge, on `bgWindow`:
  - **Tabs**, a 40pt row (18pt leading, 12pt trailing padding) with a hairline under it: Chat,
    Tweak, and Comments with its count in mono 10 `textTertiary`, 18pt apart, in 12.5. The
    current tab is `textPrimary` semibold on a 2pt `textPrimary` underline; the others are
    `textSecondary`. A ••• (28pt) trails the row.
  - **Chat** is the design agent's thread, 18pt padding and 14pt between items, with the
    thread's components: `NWUserBubble` (the board: at most 340pt, 10×14 padding, radius 8, a
    1px `lineStrong` line on `bgBubble`, `body`, its time "10:40" in mono 10.5 `textTertiary`
    5pt under it; see Thread for when times show), the agent's prose (the board sets it at
    13/1.6, with the direction letters bold), and `NWActivityLine`s, 4pt apart, with the design
    verbs:
    - "Read the design system" · "acme-web · 18 tokens · 9 components" (a document glyph,
      `doc.text`)
    - "Drew 4 boards" · "3 directions + phone" (the nib; `.drew`)
    - "Checked against acme-web" · "0 off-system values" (`checkmark.shield`; `.checked`)
    - "Updated A and A · phone" · "funnel card · 1 change" (`pencil`, as an edit; a rewrite with
      `board_write`, a change in place with `board_edit` and one `boards_edit` over many boards,
      "Updated 12 boards", read alike; the boards a batch wrote are counted, not the ones it
      asked for; a batch that wrote nothing, a dry run or an atomic one that did not match, is
      an ordinary tool line saying so)
    - "Drew 1 board and updated Home" (`board_extract`: the piece drawn, its source updated);
      `board_search` joins the explore line as a search; `board_render` and the checkpoint tools
      are ordinary tool lines (the thread's other tools)

    A comment you make on the canvas joins the chat as its `NWCommentCard` (below), and the
    agent's answer sits inside the card under a hairline: its activity line, then its reply
    ("Done. Counts sit next to each percentage on both boards.").
  - **The composer** (12pt above it, 14pt at the sides and below) is the thread's composer at its
    compact size (NWDesignTool › Chat composer; Composer, questions, and menus › Sizes): `NWComposer`'s card at radius
    8, placeholder "Describe a change, or click something on the canvas to comment…", and one
    row of attach, "/", the model, the thinking level alone, the context ring (once the design
    agent has a conversation) and Send. Everything a thread's composer does works here: the slash
    menu (pi's commands; `/login` stays in Settings), the model picker and thinking menu (⇧⌘M
    and the menu command reach it), the ring's details and Compact, Up next with queue and steer,
    and attachments. A model or level change goes to the design agent's pi as a thread's does
    (`setModel`, `setThinking`). What it sends still carries the canvas's view record. A system
    build's chat (DZSystem) and a remote design's chat have the same composer.

## Shared pieces (not drawn on any board)

**Built on the Mac** (docs/designs.md › Shared pieces). A **piece** is a board other boards import
with `<dc-import name="Card">`: it is drawn once and every importer follows it. The boards draw
none of this, so these are Shepherd's, made of the canvas's own parts; there is no Components
page, and nothing here adds a control the user has to learn.

- **The label.** A piece that at least one other board imports says so in its board label, after
  the size: "used in 3 boards" ("used in 1 board"), in sans 10.5 `textTertiary`
  (`NWBoardLabel`; the accessibility label gets it too). Boards nothing imports show nothing
  extra. The count is derived once per design revision (`DesignUsageIndex`), never per board
  redraw.
- **Picking a use.** Selection stops at a `<dc-import>`: a click anywhere in a piece's drawing
  picks the import ("component · Card"), never an element inside it, which belongs to the piece.
  A comment on it is about that use.
- **Go to Source.** With a use picked, the right-click menu has **Go to Source** (`arrow.turn.down.right`,
  after Tweak, before the reference actions), and the Tweak tab's note has a small secondary
  **Go to source** button. It picks the piece's board whole, brings it to the middle of the view
  (and its page into view). It is offered only when the piece has a frame on the canvas, and has
  no chord.
- **Tweak on a use** (`NWTweakPieceNote`): the piece draws the instance, so a style written on it
  would do nothing and the tab offers none. Where the groups would be, a **Shared piece** group
  (`.nwSectionLabel()`, 14×18 padding, a hairline under it): "This is one use of Card, drawn by 3
  boards. Its look comes from the piece: change the piece to change every use." in 11.5/1.45
  `textTertiary` (the scope note's), and Go to source under it. Nothing is written, and Reset is
  off.
- **Redrawing.** A board that imports a piece redraws when the piece changes (live view and
  snapshot), and a board that imports nothing does not.
- **Not drawn here:** a Components page, a piece's usage list (the agent finds usages with
  `board_search`), and the iPhone and iPad (a remote design draws no usage label, its pieces
  redraw only when the viewer's board reloads).

## Comments (DZCanvas, DZTweak, NWDesignTool)

User reference for the list actions: [DesignComments.png](boards/DesignComments.png).
[Checklist, control validation, and renders](evidence/design-comment-actions/README.md).

**Built on the Mac** (`NWCommentPin`, `NWCommentThread`, `NWCommentCard`; docs/designs.md ›
Comments), as below, with these choices the boards leave open:

- The pin's shadow is the knob's small shadow role (`knobShadow`, 6pt blur, 4pt down), not the
  boards' black 40%, and it has no second shadow.
- A new comment is written in the review's comment editor (`NWCommentEditor`: "Comment for the
  design agent", "on A · Checkout funnel", Cancel and Add comment) where its thread will open: no
  board draws a comment being written. The board action (Comment) waits for the board actions bar.
- In the chat, the agent's reply inside the card has no turn footer, and the card ends at the
  first compaction in that reply: the compaction's line and everything after it are an ordinary
  reply under the card, with its own footer.
- The Comments tab's card opens its board directly: select it, switch to its page, exit Present,
  center the board in the canvas, and open its thread. A canvas pin opens in place without moving
  the viewport. The tab remains available after opening a card.
- Hovering a card reveals a text-only "Resolve" action in a 24pt small ghost button at
  the header's trailing edge, visually replacing author and age without changing the card's
  height. Keyboard focus and VoiceOver also reveal it; the card's named Resolve accessibility
  action works at rest. The open and resolve buttons are siblings, with 24pt minimum hit areas.
- A resolved comment leaves the canvas and the Comments tab (the chat keeps its card); nothing
  lists resolved comments yet. The Comments tab's count is the open comments' and the notes
  threads left (RefNoteBack), and it shows no count at zero; with none it is blank.
- A comment whose element a rewrite left nowhere keeps its pin where the element was, and its
  thread and card add "element changed". Not drawn on any board: design it.
- A comment that couldn't reach the agent is kept, and the app's error dialog says why. Not drawn.

- **A pin** (`NWCommentPin(number)`): a 26pt `lantern` teardrop, round but for a 4pt bottom-leading
  corner, which is its point, set on the element's top-trailing corner. The number in mono 12 bold
  `textOnLantern`, and a small shadow (0, 4, 12 at black 40%, in both appearances; a second shadow,
  where the system has one (Elevation): settle it before building). In a card's header the pin is
  18pt (a 3pt point, mono 10 bold).
- **Making one:** the canvas toolbar's Comment tool, the board action, or (iPhone) the toolbar's
  Comment, then click or tap an element: the element takes the selection ring and the pin, and
  the thread opens beside it.
- **The comment thread** (`NWCommentThread`), on the canvas beside its pin, under its element:
  320pt wide (DZTweak draws 330), 12×14 padding, 10pt between parts, radius 12, `bgRaised`, the
  popover's line and shadow.
  - A header in 11.5 `textTertiary`: the author in `textPrimary` semibold ("You"), the age
    ("2m"), and a trailing **Resolve** (a ghost 24pt button in 12 medium `textSecondary`,
    `checkmark`).
  - The comment in 13/1.5.
  - The agent's reply under a hairline (8pt above): "Design agent · 1m" (the name semibold
    `textPrimary`) over its text in 13/1.5, e.g. "Done on A and A · phone. Want the drop-off
    line in counts too?"
  - "Reply…": a 32pt field, 10pt padding, radius 8, 1px `lineStrong`, 12.5 `textTertiary`
    (DZTweak; NWDesignTool's specimen stops at the reply).
- **The comment card** (`NWCommentCard`), in the chat and the Comments tab: 12×14 padding, 8pt
  between parts, radius 10, 1px `lineStrong`, `bgRaised`. Its header in 11.5 `textTertiary`:
  the small pin, "on" and the board · element in `textPrimary` semibold ("on A · Checkout
  funnel"), and trailing author · age ("You · 2m"). The comment in 13/1.5. On iPad the card is
  10×12 with 6pt between parts, its header in 12 and the comment in 13.5/1.45 (iPadDesign); on
  iPhone it is a sheet over the board (On iPhone, below).
