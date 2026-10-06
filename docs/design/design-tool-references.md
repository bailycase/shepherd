# Design tool: references, Tweak, systems and export

> Read when you work on design references, Tweak, design systems, export, deletion and import, or the Design tool on iOS.

## Design references (DesignRefStates, RefImplementMenu, RefImplementSheet, RefImplementBoard, RefSentStay, RefCopied, RefNoteBack, RefPasted, RefAtDesigns, RefAtElements, RefAtSearch, RefSentThread, RefChipHover, RefChipUpdated, RefAgentRead)

**Built on the Mac, this Mac's designs only** (docs/designs.md › Design references; ShepherdUI's
`References.swift`, `ImplementSheet.swift`, `MentionPicker.swift`, every state specimen in
`NWDesignReferenceSpecimens` with its `#Preview`). A thread shows nothing of a design but the chip
in the user's own message and one "Looked at…" line; none of it exists with the Design tool off,
or in a design's own chat. Choices the boards leave open, and where the build departs:

- **Other hosts** are ShepherdUI states only (the chip's "on another host" and "host offline",
  the picker's host tags and dimmed offline rows): the app lists and sends this Mac's designs, and
  never reaches them until remote references come.
- **The picker lists no files** (the boards' "Files" section): the component draws the rows, the
  composer offers none, as the composer has no file mentions yet.
- **Native menus** (the right-click menu, the design's •••) use the app's title case ("Implement
  in a Thread…", "Copy Reference"). The ••• menu lists the chords' actions without their chords: a
  popup button's key equivalents would answer ⌘↩ anywhere in the window.
- **The right-click menu** has no Delete: the canvas deletes no board yet.
- **A pinned version no longer kept** is refused (`version_gone`) with its reason; no board draws
  it. This includes old source-only pins without retained rendering inputs. A retained pin draws
  its original props, frame, token styles and board set, including a board since removed. “Updated
  since” includes changes to these inputs, not just changes to the board's source.
- **The note's card** opens beside its pin (a choice the boards leave open).

These departures are the user's call, 2026-09-27: references to another host's designs come
later; the picker lists designs only, and file mentions wait for a PR of their own; the ••• menu
keeps its chords off; Delete joins the right-click menu when deleting a board is built, with Undo;
and a pinned version no longer kept is refused, with Send vN offered for the current one.

- **From the canvas:** the board actions bar floats over the selection's board, an element's too,
  and ends with **Implement…** (`chevron.left.forwardslash.chevron.right`) before •••. A right-click
  (or ⌃-click) picks what it lands on, then opens Comment, Tweak | Implement in a Thread… (⌘↩) ·
  Copy Reference (⇧⌘C) | Duplicate; on the empty canvas, "Implement <design>…" and Copy Reference.
  The design's ••• (its toolbar) adds "Implement <piece>…" and Copy Reference before Delete Design…,
  naming the selection (the whole design with nothing selected). ⌘↩ and ⇧⌘C are canvas-scoped
  (`ShortcutAction.Scope.canvas`, Settings ▸ Keyboard's Designs group): answered only while the
  design shows and nothing that takes text has the keyboard with something in it, so the chat's
  composer keeps its own ⌘↩ for a draft. Clicking the canvas leaves the keyboard where it was
  (usually the chat's empty composer), and that lets them through.
- **The sheet** (`NWImplementSheet`), centered over the window on the sheet scrim: 540pt, radius
  14, `bgWindow` with the popover's line and shadow. A header (20/18/16/20): the piece's picture
  88×56 (radius 6; an element cut from its board as the canvas drew it), "Implement <piece>" in 16
  semibold, the design (and board) in 12.5 `textSecondary` · the version in mono 11 `textTertiary`,
  and a 28pt bordered close. Existing thread | New thread (`NWSegmentedPicker`). Existing: Search
  threads, then the threads (`NWImplementThreadList`: 38pt rows in a `lineSubtle` list at radius 9,
  hairlines between; the chosen one on `runningTint` with a filled 7pt `running` dot, semibold, and
  a check; others an open 1.5pt `textTertiary` ring; the project in mono 11 with a folder glyph, a
  host tag, the age in 11.5 `textTertiary`), five before they scroll: this Mac's threads that draw
  no design, most recently active first. New: Project (`NWImplementProjectLabel`, 34pt: the project
  in mono 12.5 · "This Mac", a menu of the sidebar's projects; it defaults to the project the
  design's system was built from, else the latest thread's) and "Starts on a new worktree,
  agent/implement-<piece>" (a project that isn't a git checkout: "Starts in the project: it isn’t a
  git repository, so no worktree."). Then Message ("Anything the agent should know (optional)",
  13/1.5 on `bgRaised`, radius 8), "Open the thread after sending" (`.nwCheckbox`, remembered), and
  the footer on `bgSunken` (12/16/14/20, a hairline above): exactly what goes
  (`DesignReferencePresentation.sends`, the system in mono 11), Cancel, and Send (primary, ↑).
- **Sent:** with "Open the thread after sending" on, the thread shows; off, the canvas stays and a
  toast (`NWReferenceToast`, 520pt, 11/12/11/14 padding, radius 12, a `done` check) says "Sent
  <piece> to **<thread>**." with Open thread; **Copy reference** puts the pinned string on the
  pasteboard and says "Copied a reference to <piece>. Paste it into any thread’s composer." (a
  link glyph). A toast sits 22pt above the canvas's bottom, centered, and goes after 6 seconds.
  The sheet, the toasts and a new thread's name and branch name the piece as the canvas did (its
  `data-el` name, else the canvas tag's noun: "card “Checkout funnel”"); the host names it the same
  way from the source for the chip and the picker (`DesignReferenceReading.elementNoun`: a box
  that draws a fill, border or shadow is a card, else a group; words alone are text). The footer
  names only what goes: never "0 tokens".
- **The chip** (`NWDesignReferenceChip`): 6/8/6/6 padding, radius 9, 1px `lineStrong` on
  `bgBubble`, 9pt gaps: a 40×26 picture (radius 4, a hairline ring), then design › board ›
  **element** in 12.5 (`textSecondary`, the piece `textPrimary` semibold, `›` `textTertiary`; the
  design's name gives way first) over the version in mono 10.5 · the state in 11 `textTertiary`
  ("design reference"). Updated: a 5pt `lantern` dot and "updated since · now v26" in `lanternText`.
  Deleted: 75%, the picture a dashed tile with a trash glyph, "design deleted · the copy sent here
  is kept". Hovered or open: a 1px `running` line on `runningTint`. In the composer it has a 20pt
  remove button and sits first among the attachments, which wrap; at most five. In a sent message
  it sits above the words (the "1 design reference attached." line comes off); a click opens the
  piece in the design (its board picked and centered, its element selected once the board draws).
- **The preview** (`NWDesignReferencePreview`), 8pt above the chip after a 0.45s hover, whenever
  the thread's visible part holds it there (8pt below only a sent chip too near the thread's top
  for it), kept while the pointer is on either: 340pt, 12pt padding, radius 12, the popover's surface, 10pt between
  parts. The picture 316×107 (radius 6), the breadcrumb, "v23 pinned Sep 27, 10:42 · acme-web" in
  11.5 `textTertiary` (the version `textSecondary`, the system mono), "The agent gets" with mono
  10.5 tags on `bgSelected`, and Open in design (secondary, 24pt). Updated: a box on `lanternTint`
  (8×10, radius 8): "Changed since v23 · now v26" in 12 semibold `lanternText` over mono 11 lines,
  "Open v26 in design" and **Send v26** (ghost), which puts v26 in the composer; old messages keep
  theirs.
- **The @ picker** (`NWMentionPicker`), over the thread above the card like the slash menu: "@" at
  the start or after a space opens it on the designs (40×26 pictures, the name in 13 medium, the
  system in mono · "4 boards · edited 2h ago" in 11.5 `textTertiary`, a chevron); → or ⏎ drills
  into a design, Whole design, then separate Pages and Boards sections, and a board, Whole board
  then Elements, each
  under a breadcrumb with Back (← or ⌫ with nothing typed after it), the draft spelling the way
  in ("@Checkout funnel dashboard › A · Funnel first › "); ⏎ on an element or a whole row picks it:
  the mention leaves the words and the chip joins the composer. A page row picks immediately,
  uses the outline `rectangle.stack` glyph and says "Page · 2 boards · attaches all boards".
  It attaches every board on that page as one chip, including pages with more than twelve boards.
  The chip says "Page · <name>" and opens that page in the canvas. Board and element selection
  stays unchanged. Typing searches designs, pages, boards and elements by their own names, each
  with its path, the words underlined. Page results keep their glyph, kind label and board count.
  "Nothing matches “pricng”" and "No designs yet. Start a design and its boards show up here." are
  its empty stages, said only once this Mac's designs have been read. Until then, and when the read
  fails, the picker still opens at once and says so (no board draws these, the user's decision,
  2026-10-01; `DesignMentionLoad`): **Loading designs…** is one quiet line under the "Designs"
  label, an `nwSpinner` (still under Reduce Motion) and the words in 12.5 `textSecondary`, that
  lists nothing to choose, so ↩ over it changes nothing and sends nothing; words typed meanwhile
  filter the rows when they arrive, for the draft as it stands then. A read that takes longer than
  15 seconds is **Couldn't load designs.**, with a failed-colored `exclamationmark.triangle`, the
  reason as its tooltip and VoiceOver hint, and a ghost **Retry** that reads again (the line says
  loading again while it does). A picker that has read the designs once keeps their rows through a
  later read and through its failure; an answer to a read a newer opening replaced is dropped. On
  New thread, a chosen project on another host gets one note instead ("Design references go to
  projects on this Mac."). 48pt rows, runningTint highlight, at most eight rows (a lazy list). An
  element's row draws the element itself, cut from its board (made only once the row is on screen),
  and says what it is and holds: "funnel bars · 5 steps", "list · 5 rows", "KPI tile · 1 of 4",
  "chips · All platforms, Web, iOS, Android". Whole board's "14 elements" and the Elements count
  are the rows the list holds. Esc closes it for the draft as typed.
- **A pasted reference** (a paste bringing a whole `shepherd-design-ref://…` word) becomes a chip,
  the words around it staying; typed characters and plain text stay text. ⌫ with the caret at the
  start of the words (or in an empty composer) takes the last chip back.
- **"Looked at…"** (NWActivityLine(.lookedAtDesign), the nib): "Looked at Checkout funnel
  dashboard › A · Funnel first" with what it got in mono ("picture · html · 11 styles · 8 tokens");
  open, `NWLookedAtDetails` on the calls' rail: `pic` the picture and its size, `html` the page and
  its weight, `css` the properties, `tok` the tokens and the file:lines they live in.
- **A note back** (`NWThreadNotePin`, `NWThreadNoteCard`): the comment pin's 26pt teardrop in
  `running` (a 1.5pt ring on `runningTint` over `bgRaised`, a code glyph), just after a comment's
  pin on the same element, on the board's corner while its element isn't found; its card beside it
  (300pt, 12×14, radius 12): a "Thread" tag on `runningTint`, the thread's name semibold, the age;
  the note in 13/1.5 with its `code` and #142 in mono (#142 `running`); a hairline, Open thread,
  Resolve, and "from v23".

## Tweak (DZTweak)

**Built (Mac), from the tab** (`DesignTweakPane`; docs/designs.md › Tweak): the header, groups of
`NWTweakRow`s, `NWTokenChip`s, `NWTweakScope` with its note, and the footer. The board action
waits for the actions bar. The groups are a fixed set (Layout, Color, Text) plus the board's
data-props by their section, not DZTweak's per-element ones (Bars, Labels). Sliders are
`NWValueSlider` at its own 200pt and 44pt (the board's 190 and 36 are not settled). Not drawn,
so the least that is honest: the tab with nothing selected (its header says to select an
element), a tweak that couldn't be written (the header's note says so), a data-props text field,
and a design without tokens for a role (its note says values snap to Shepherd's scale). Tweak
(the board action or the tab) edits the selected element directly. A released gesture keeps that
selection and scope even if the viewer selects something else while it saves. Local style, prop
and Reset writes finish in gesture order, including their snapshot refresh; Reset includes edits
already released before it. Undo and Redo
refuse later changes to the same style or prop rather than overwrite them; a Redo requested while
Undo is still saving waits for it.

- **On the canvas**, the element (`NWSelectionRing`, built with Select) wears a 1.5pt `running`
  ring (on NWDesignTool over a `runningTint` fill, which Shepherd draws), 8pt square handles on its corners (white, a 1.5pt
  `running` line, radius 2), and a tag 4pt above its top-leading corner naming it: 18pt, 6pt
  padding, radius 4, `running` fill, white mono 10.5 ("card · Checkout funnel"). Its comment
  pin and thread stay beside it. Changes show on the canvas as you drag.
- **The Tweak tab**, top to bottom:
  - A header (14×18 padding, a hairline under it): the path in mono 11 `textTertiary` with the
    element in `textPrimary` ("A · Funnel first › card · Checkout funnel"), and "Changes show on
    the canvas as you drag." in 11.5 `textTertiary`.
  - Groups, each 14×18 with a hairline under it and a `.nwSectionLabel()` 6pt above its rows. A row
    (`NWTweakRow`) is at least 30pt (a slider) or 32pt, 12pt gaps: the label in 12.5 `textSecondary`
    in a 92pt column, then the control. A slider (`NWValueSlider`: 3pt `lineStrong` track, `lantern`
    fill, 14pt white knob) runs 190pt with its value in mono 11.5 in a 36pt trailing column
    (`NWSliderMetrics` is 200 and 44: settle which before building); a segmented picker
    (`NWSegmentedPicker`, size `.s`: 20pt segments on `bgSunken`), a switch (`.nwSwitch`), or token
    chips sit at the trailing edge, 6pt apart.
    - **Layout:** Padding (slider, 24), Row height (slider, 46), Radius (8 · 12 · 16).
    - **Bars:** Color (token chips: accent, slate, success), Thickness (slider, 30), Rounded
      (switch).
    - **Labels:** Counts (switch), Drop-off (switch), Text size (S · M · L).
    - **Apply to:** Scope (`NWTweakScope`: "This board" · "Every funnel card", that is, every
      element that matches), with what it reaches under it in 11.5/1.45 `textTertiary`: "Every
      funnel card: A and A · phone. Values snap to acme-web tokens."
  - On an element that is one use of a shared piece, the groups give way to the **Shared piece**
    note (Shared pieces, above; `NWTweakPieceNote`).
  - A footer pinned to the bottom (12×14 padding, a hairline above): **Reset** (ghost, 24pt) on
    the leading edge, a spacer, and **Ask the agent instead…** (secondary, 24pt) on the trailing
    edge.
- **Token chips** (`NWTokenChip(token, isSelected:)`): 26pt, 8pt padding, radius 6, 6pt gap, a
  10pt swatch (radius 3) and the token's name in mono 11.5. Selected: a 1px `running` line on
  `runningTint`; otherwise a 1px `lineSubtle` line.

## Design systems (DZSystem)

**Built on the Mac** (`DesignSystemPage`; docs/designs.md › Design systems › In the app). A system
built from a repository shows as its build's layout, beside the build agent's chat with the Chat
tab alone (decision 12); any other system (Night Watch) as the Design systems page, without a
chat (not drawn). Components are live specimens drawn by the board renderer. Not drawn and built
plainly: Spacing & radii and Boards using it (rows in the type rows' anatomy), a build still
reading its project, and the report's "Read dashboard-web" activity line (the reads join
"Explored N files"). A design system is read from a
repository, its tokens file and its templates, and kept in sync. Night Watch is listed as one too ("shepherd"). A system page opens from the
design system chip, the Designs page, or More ▸ Design systems, and keeps the chat pane.

- **Header**: the breadcrumb (the 14pt nib, "Design systems", "/", the name in 13 semibold) and
  its sync state as an `NWStatusPill` ("Synced", done: 20pt, radius 4, a 6pt dot on
  `doneTint`); trailing, the design system chip.
- **Section list**, a 200pt column (18×10 padding, a hairline on its trailing edge, 2pt apart):
  30pt rows, 10pt padding, radius 6, 12.5, the count trailing in mono 10.5 `textTertiary`; the
  current one on `bgSelected`, semibold, the rest `textSecondary`. Colors 11 · Type 4 · Spacing &
  radii 7 · Components 9 · Boards using it 4.
- **Content** (24×32 padding, 26pt between sections):
  - The name in mono 22 semibold over its source in 12.5 `textSecondary`: "Read from
    `dashboard-web`: `web/static/tokens.css` and 9 templates in `templates/partials/` · synced
    4m ago" (paths in mono). Trailing, **Re-sync** (`arrow.clockwise`, secondary, 28pt).
  - **Colors**: a six-column grid, 14pt gaps, of token swatches (`NWTokenSwatch`): a 56pt
    swatch (radius 8, a 1px `bgSelected` inner line), the token in mono 11.5 semibold
    ("--accent"), and the value and the line it came from in mono 10.5 `textTertiary` ("#4f46e5
    · tokens.css:8").
  - **Type**: one row per style, 8pt vertical padding, a hairline above: the style's name in mono
    11 `textTertiary` (90pt), a specimen in the system's own face at its size and weight in
    `textPrimary` ("Checkout funnel" at display 26/700; title 15/600; body 14/400; label
    12/600), and the spec trailing in mono 10.5 `textTertiary` ("26/700").
  - **Components**: a three-column grid, 16pt gaps: a 92pt specimen tile (radius 8, 12pt side
    padding, on the system's own background) with the component drawn in the system (the
    button tile shows "Export CSV" beside "Cancel"; the chip tile a selected and a plain chip),
    and 10pt under it the name in 12.5 semibold and its template trailing in mono 10.5
    `textTertiary` ("partials/button.html"). Button, Chip, KPI tile, Card, Nav bar, Input.
    A specimen renders from its own directory so linked component styles and assets resolve
    correctly. Complete HTML documents preserve their head resources and html/body theme
    attributes; fragments use the default shell. Its HTML must include the component styling;
    token variables alone do not
    reproduce application components.
  - Each section's title ("Colors", "Type", "Components") is a `.nwSectionLabel()`, 6pt above
    its content.
  - Spacing & radii and Boards using it are listed but not drawn.
- **The chat** reports what the agent built and what doesn't match: an activity line "Read
  dashboard-web" · "tokens.css · 9 partials · 3 pages" (the document glyph), then prose: "I built
  `acme-web` from your repo: 11 colors, 4 type styles, 7 spacing and radius steps, 9
  components.", "One thing doesn't match: three templates hard-code `#4338ca` for buttons
  instead of `--accent`. Designs use the token.", and "Every board I draw is checked against
  this before you see it. Anything off-system gets fixed or flagged." (token names and values in
  mono).

## Export and share (DZExport)

**Partly built** (`DesignExportSheet`, ShepherdUI's `NWExportSheet`, `NWExportSection`,
`NWExportBoardRow` and `NWExportFormatCard`). Built as the board draws it: the 560pt card with its
close button over the 55% scrim (`sheetScrim`), Boards, Format, Use it somewhere else with Attach
to a thread and its note, and the footer. Not built: the Live link section (a network listener
that is not built; the section is left out, not drawn disabled) and Attach to a mission (waits for
Missions; left out). Not drawn and built plainly: with nothing selected on the canvas every board
opens ticked; past eight boards the rows scroll; Attach to a thread is a menu of the local threads
(most recently active first); while an export is written the sheet dims and its primary button
reads "Exporting…"; the scrim takes clicks and does nothing (Cancel, close or Escape put the sheet
away); a failure goes to the app's error dialog. What each format writes is docs/designs.md ›
Export and import. Replacing an existing export stages the complete new output on its volume;
a failed replacement reports the error and never deletes the previous export as a fallback.

Export (the header's button) opens a sheet over the design, with the boards
selected on the canvas already ticked.

- **The sheet** (the board: a 560pt card, radius 14, `bgRaised`, the popover's line and shadow,
  centered over a black 55% scrim): a header (16×18 padding, a hairline) with "Export" in
  `title` and a close button (`xmark`, 28pt, "Close"); sections at 14×18 padding with a hairline
  between them, each under a `.nwSectionLabel()`. Every other Mac sheet is an `NWDialog` (Dialogs
  and sheets: 460pt, flat on `bgWindow`, no close button); decide which anatomy Export takes
  before building it.
  - **Boards**: one 30pt row per board, 12.5, 10pt between its parts: a checkbox (`.nwCheckbox`,
    14pt: ticked `lantern` with a `textOnLantern` check; else a 1.5pt `lineStrong` box on
    `bgRaised`), the board's label, and its size trailing in mono 10.5 `textTertiary`.
  - **Format**: a 2×2 grid of format cards (`NWExportFormatCard`), 8pt gaps: 10×12 padding,
    radius 8, a 1px `lineSubtle` line; chosen, a 1px `running` line on `runningTint`. A 14pt
    radio (chosen: `lantern` with a 6pt `textOnLantern` dot; else a 1.5pt `lineStrong` ring on
    `bgRaised`), the format in 13 semibold, and its line in 11.5/1.4 `textSecondary` indented
    24pt:
    - HTML: "One standalone file per board. Opens anywhere."
    - ZIP: "HTML, tokens.css and assets."
    - PDF: "One page per board."
    - PNG: "@2x, one image per board."
  - **Live link**: "Serve on `build-01` while you keep editing" with a switch, and under it
    (8pt) the link field (`NWLiveLinkField`): 32pt, 10pt leading and 6pt trailing padding,
    radius 6, a 1px `lineSubtle` line on `bgSunken`, the URL in mono 12
    ("http://build-01:7040/d/checkout-funnel") and a 24pt copy button (`doc.on.doc`, "Copy
    link"). The link is served by the host the design runs on ("Serve on `build-01`") while you
    keep editing. The board's URL is plain `http://`: like the remote listener (docs/remote-protocol.md ›
    Remote), it has no TLS, so never describe it as a public or internet-safe link.
  - **Use it somewhere else**: **Attach to a thread** (`text.bubble`) and **Attach to a
    mission** (the Missions glyph), secondary 24pt buttons 8pt apart, and "Attached boards
    arrive as HTML plus a note of the tokens they use." in 11.5 `textTertiary`.
  - A footer (12×18 padding, a hairline above), trailing and 8pt apart: Cancel (ghost, 28pt)
    and the primary **Export 2 boards** (`square.and.arrow.up`, 28pt), whose count follows the
    ticked boards.

## Delete and import (DesignLifecycleStates)

**Built on the Mac** (docs/designs.md › Deleting and importing on the Mac; `DesignLifecycle.swift`,
`DesignLifecycleViews.swift`, ShepherdUI's `Components/DesignTool/Lifecycle.swift`), from the system
board and its screens: DesignCardMenu, DesignRecentsMenu, DesignToolbarMenu, DesignDeleteConfirm,
DesignDeleteWorking, DesignDeleted, DesignDeleteFailed, SystemCardMenu, SystemDeleteConfirm,
SystemDeleteBuilding, SystemDeleteFailed, SystemBuiltIn, ImportFileMenu, ImportNewDesign, ImportDrop,
ImportProgress, ImportDone, ImportFailed and ImportAgain. Not built: the Recents row's blue
outline while its menu is open (a native context menu reports no open state to SwiftUI), and on
iPhone and iPad none of it.

- **A design's menu** (`DesignMenu`), native and title-cased as every menu in the app, each item
  with its glyph and Delete in `failed`: on a card, a right-click anywhere on it or **•••**, a 26pt
  `bgRaised` circle on the popover's line and shadow 10pt in from the thumbnail's top-trailing
  corner, shown on hover (`NWDesignMoreButton`): Open, Rename…, Duplicate, Export…, then Delete
  Design…. On its Recents row (a right-click): the same with Remove from Recents before Delete. In its
  own toolbar, **•••** (`NWDesignToolbarMore`, a 28pt icon button) after Export: Rename…, Duplicate,
  Export…, Show Design System, then Delete Design…. A host's design: Open, Rename…, Delete Design…
  (off, with the reason under it, where the host can't delete for this Mac).
- **A system's menu**: on its card a right-click, or ••• in the count's place on hover; on its page
  ••• in the header. Open, Re-sync from <repo> (a system read from one), Rename…, Duplicate, then
  Delete Design System…. A built-in: Open, Duplicate as a New System, and Delete Design System… off
  at 45% with "Night Watch is built into Shepherd. Duplicate it to make one you can change or
  delete." under it (a native menu item's subtitle), so nobody hunts for it. A system card for a
  built-in carries the **Built-in** tag after its name (`NWDesignTagBadge`: 16pt, 5pt padding,
  radius 4, 10 `textSecondary` on `bgSelected`) over "Built into Shepherd"; one an import brought
  reads "came with Checkout funnel"; one coming with an import is dashed (`lineStrong`) with "after
  the boards" in the count's place until the design's boards are in, after every system there is.
- **The alert dialogs** (`NWDesignAlert`), each a sheet: 470pt (480 for a system's and an import's,
  500 for ImportAgain), 22pt in (18 at the bottom), on `bgWindow`. A 36pt tile at radius 10 in
  `failedTint` (ImportAgain: `lanternTint`) holding the 17pt glyph in `failed` (`lanternText`),
  14pt before the column: the title in 15.5 semibold, then 8pt apart the message in 13
  `textSecondary` (names semibold `textPrimary`, paths and systems in mono `textPrimary`), the list
  box (`NWDesignAlertList`: 10×12 padding, 6pt between lines, a hairline at radius 8 on `bgSunken`;
  the board's radius 9 is off the scale) whose lines carry a 12pt glyph, `failed` for what goes,
  `done` for what stays, `textTertiary` for a note; the buttons trailing, 8pt apart, 16pt under it.
  - **DeleteDesignDialog**: "Delete “Checkout funnel dashboard”?", "**4 boards**, their 23 versions
    and 2 comments" (a `trash`), "The design agent’s chat for this design" (a `text.bubble`), "Stays:
    `acme-web`, the design system it uses" (a `checkmark`), then "You can undo right after." in 13 `textTertiary`; Cancel (secondary) and Delete
    (`dangerFill`, the only red thing). While the agent works, a warning under the list
    (`NWDesignAlertWarning`: a 13pt triangle and 12.5 `lanternText` on `lanternTint` at radius 8;
    the board's 7% fill and 25% line are off the tokens) says "The design agent is drawing 2 boards
    right now. Deleting stops it, and what it’s drawing is lost." (the boards its writes named in the
    turn under way; with none yet, "is drawing right now"), and the button says **Stop and delete**.
  - **DeleteSystemDialog**: "Delete the design system “acme-web”?", "Its colors, type, spacing and 9
    components go from Shepherd.", then "**Used by 3 designs; they keep their copy.** Checkout funnel
    dashboard, Events explorer, Onboarding flow", "Built from `dashboard-web`. The repo isn’t
    touched.", and the note "New designs can’t pick it. Build it again from the repo any time.". A
    system still being built: "Delete “acme-mobile”?", "It’s still being built from `mobile-app`.
    Deleting stops the build and keeps nothing from it.", "No designs use it yet", "The repo
    `mobile-app` isn’t touched", and **Stop and delete**.
  - **ImportErrorDialog** ("Couldn’t import “checkout-funnel.zip”"): the reason (no `canvas.json`
    inside; "It’s 2.3 GB. Shepherd imports projects up to 1 GB. …"; "3 boards point to files outside
    the project folder. …" with up to three "boards/hero.html → ../shared/logo.svg" lines, in mono
    11.5, the target in `failed` (the board's lighter red is off the tokens); "The board **Pricing — v3**
    couldn’t be read: `boards/pricing-v3.html` is empty. The other 11 boards are fine."), then a
    `done` check and "Nothing was imported." (or "Nothing’s imported until you choose.") in 12.5
    `textTertiary`. Buttons: Choose another… and OK (primary) when it wasn't a project; OK alone for
    too large or links outside; Cancel import and **Import the other 11** for unreadable boards, the
    one case with a choice. Not drawn, built plainly in the same anatomy: one file over 16 MB ("hero.mp4
    is 40 MB. Shepherd imports files up to 16 MB. …"), a name a design can't hold, too many files,
    or unsafe canvas geometry (positive dimensions and native-integer-representable numbers).
    Tall legacy flow documents keep their sizes. A board beyond native rendering limits reports
    that it cannot draw; its canvas and source remain intact. Bitmap exports above 64 million
    pixels refuse with a smaller-image-or-PDF suggestion.
  - **ImportAgainDialog** (the tray, `square.and.arrow.down`): "“Checkout funnel” is already in
    Designs", "You imported **Checkout funnel** on Sep 20. Import it again as a separate copy, or open
    the one you have. The two don’t affect each other.", "New copy: **Checkout funnel 2** · 12 boards
    · 3 pages" (the design glyph, `pencil.tip`), "Design system: uses the `Checkout DS` you already
    have" (`paintpalette`); Cancel (ghost), Open the one I have (secondary), Import
    as a copy (primary).
- **The toast** (`NWUndoToast`) over the bottom of the main column, centered, 40pt up, at most 460pt:
  11×12 padding (14 leading), radius 12, the popover's fill, line and shadow, 12pt between its
  parts; a 15pt glyph (the trash in `textSecondary`; the triangle in `failed` after a failure), the
  words in 13 ("Deleted **Checkout funnel dashboard**."), a 24pt secondary button with a 13pt glyph
  (**Undo**; **Try again**), and a 24pt close. Undo lasts as long as the host holds the design (10
  s); nothing counts down. A failure stays until it is dismissed or tried again: "Couldn’t delete
  **Checkout funnel dashboard**. build-01, where it’s saved, didn’t answer, so it’s back." (This
  Mac's own failure names its error, then "It’s back where it was.").
- **Import** (ImportFileMenu, ImportNewDesign, ImportDrop, ImportProgress, ImportDone): File ▸
  Import Claude Design Project… (⇧⌘I) after a divider in the File menu; New design's **Import a
  project** card beside the system card (`NWDesignStartCard`: `square.and.arrow.down`, "Import a
  project", "from Claude Design", "a ZIP or folder you exported"; the board's fourth, since Capture a
  page and From a screenshot aren't built); and a drop on Designs (`NWDesignsDropTarget`, under the
  page's header, 12pt in: a 2pt dashed `lantern` line at radius 14 over `lanternTint`, the board's 6%
  fill being off the tokens, and a centered card on `bgWindow` with a `lineStrong` line: a 44pt
  `lanternTint` tile holding a 22pt `lanternText` tray, "Drop to import as a new design" in 16
  semibold, "A Claude Design project, as a ZIP or a folder" in 12.5 `textSecondary`). Only a ZIP or a
  folder shows the target. While it runs, its card leads Recent designs (`NWImportingCard`, a card's
  anatomy with a `lineStrong` line): the thumbnail's dot grid holding up to 12 board tiles, 38×24 at
  radius 3, 8pt apart in rows of four, drawn ones filled `lineStrong` (the board draws them white,
  the boards' own paper) and the rest dashed; "Importing Checkout funnel…" shimmering; "`7 of 12`
  boards · with `Checkout DS`"; a 3pt `running` bar filling on `lineSubtle`. Then the design opens on
  its first page and its agent reads it (ImportDone's chat; docs/designs.md › Import).

## Design components (NWDesignTool, NWDesignToolLight)

**Partly built** (`Packages/ShepherdUI/.../Components/DesignTool/`, each with a `#Preview` in both
appearances): `NWDesignCanvas`, `NWBoardFrame`, `NWCanvasToolbar`, `NWDesignSystemChip`,
`NWSelectionRing` (with `NWSelectionTag`), `NWCommentPin`, `NWCommentThread`, `NWCommentCard`,
the Tweak parts `NWTweakRow` (with `NWTweakHeader`, `NWTweakGroup`, `NWTweakNote`,
`NWTweakPieceNote` and `NWTweakFooter`), `NWTokenChip` (with `NWTokenChipFlow`) and `NWTweakScope`, `NWBoardActions`
(with `NWDirectionTile`, `NWCanvasNote` and `NWBoardPresentation`), and the page parts
`NWDesignCard`, `NWDesignSystemCard`, `NWDesignStartCard`, `NWDesignHeader` and
`NWDesignPaneTabs`, the Chat composer section's two sizes (`NWComposer` with
`.nwComposerSize(.compact)`; Composer, questions, and menus › Sizes), the system page's `NWSectionRail`, `NWTokenSwatch` (DZSystem's 56pt),
`NWTypeSpecimen`, `NWComponentSpecimen` and `NWDesignSystemBuildTile`, and Export's
`NWExportSheet`, `NWExportSection`, `NWExportBoardRow` and `NWExportFormatCard`. The rest of the
table is not built yet.

Night Watch's Design tool page names these components, dark and light ("Light ·
Day Watch"), with the same structure in both; NWSwift's inventory adds `NWDesignCanvas`. They belong
in ShepherdUI under `Components/DesignTool/` (NWSwift's package layout), each with a `#Preview` in
both appearances:

| Component | What it is |
| --- | --- |
| `NWDesignCanvas` | The pannable, zoomable canvas on `bgBase` with its 22pt dot grid, holding the board frames, pins and threads (NWSwift; no specimen on NWDesignTool: see A design: canvas and chat) |
| `NWBoardFrame(board, isSelected:)` | A board with its label above, its size in mono, and a `running` ring when selected; a shared piece's label adds "used in 3 boards" (not drawn on the board) |
| `NWSelectionRing(element)` | Picks an element inside a board for comments or tweaks (built: `.selected` with its tag, `.hover` the ring alone) |
| `NWCommentPin(number)` | The numbered pin, lantern "because a pin is something you asked for" (built) |
| `NWBoardActions(selection)` | Comment, Tweak, Variations, Duplicate, and •••, floating over the selected board (built, `.regular` and DZCanvas's `.compact`; with `NWDirectionTile`, `NWCanvasNote` and `NWBoardPresentation`) |
| `NWCanvasToolbar(tool:, zoom:)` | Select, comment, pan, and the zoom |
| `NWCommentCard(comment)` | A comment in the chat pane's Comments tab (and the chat) (built) |
| `NWCommentThread(comment)` | A comment on the canvas beside its pin, with Resolve and the agent's reply (built) |
| `NWActivityLine(.drew / .checked)` | The thread's activity line with the design verbs; the same component, two more kinds (built: the nib `pencil.tip` and `checkmark.shield`; a burst that only rewrote boards, "Updated A and A · phone", wears `.edit`) |
| `NWTweakRow(control)` | A slider, segmented picker, or switch: the label leading, the value trailing |
| `NWTokenChip(token, isSelected:)` | A color from the system's tokens, never a free hex |
| `NWTweakScope` | Apply to one board or every matching element |
| `NWTweakPieceNote(piece, boards:, goToSource:)` | The Tweak tab's note on one use of a shared piece, with Go to source (built; not drawn on a board) |
| `NWDesignSystemChip(system)` | In the design header; opens the system |
| `NWTokenSwatch(token)` | A token read from the repo's tokens file, with the line it came from (the specimen: a 44pt swatch 96 wide, mono 11 and 10; DZSystem draws 56pt with mono 11.5 and 10.5) |
| `NWExportFormatCard(format)` | HTML, ZIP, PDF, PNG |
| `NWLiveLinkField(url)` | The URL served from the host while you keep editing, with Copy (the specimen: mono 11, no scheme; DZExport: mono 12 with `http://`) |

Build them on what exists: the activity line, `NWValueSlider`, `NWSegmentedPicker`, `.nwSwitch`,
`.nwCheckbox`, `NWStatusPill`, `.nwPopover()`'s line and shadow, and the review's comment parts
(`NWInlineComment`, `NWCommentEditor`) as the nearest precedent for comments.

## On iPhone (MobileDesignBoard)

**Built** (`DesignBoardScreen`), with these choices: the frame's second shadow is left out (the
system's one shadow); Comment is off until tapped; a tapped pin raises its card and a tap on the
canvas lowers it; the comment being written uses the review's comment editor (`NWCommentEditor`)
where the card rises, and the element picked wears `NWSelectionRing`; an answered comment's card
shows the agent's answer under a hairline; Boards is a sheet of every board; Share hands the board
to the share sheet as a PNG, and Export offers PNG or PDF. Not drawn, and left out: replies and
Resolve on the phone, a detached pin, Play. A design opens one board at a time, full screen.

- **Navigation** (a hairline under it): back to the design ("Checkout funnel"); the board's label
  ("A · phone", 16 semibold) centered, with one 6pt dot per board under it (5pt apart, the
  current one `textPrimary`, the rest `lineStrong`); trailing, Share (`square.and.arrow.up`, a
  34pt icon button, 16pt glyph in `textSecondary`).
- **The board** on the canvas's dot grid (`bgBase`, 22pt), centered 18pt from the top and scaled to
  fit, in its board frame, with its numbered comment pins. (The board adds a second soft shadow
  under the frame, 0, 8, 30 at black 35%; the system has one shadow (Elevation), so settle it before
  building.)
- **A comment** rises as a card over the board, 12pt from the sides and clear of the toolbar
  (12×14 padding, 8pt between parts, radius 14, `bgRaised`, the popover's line and shadow): a
  header in 12 `textTertiary` with the small pin, "on **Steps list**" (the element in
  `textPrimary` semibold), and "You · now" trailing; the comment in 14/1.45 ("Make the bars
  thicker on phones. Hard to read at a glance."); and while the agent works on it, an 11pt
  running spinner and "Design agent is updating A · phone" in 12.5 `textSecondary`.
- **The toolbar** (a hairline above, on `bgWindow`, spread evenly): Comment (`text.bubble`), Ask
  the agent (`sparkle`), Boards (`square.grid.2x2`), and Export (`square.and.arrow.up`), each a
  20pt glyph over an 11pt label, 4pt apart, with 10×14 padding and 34pt below for the home
  indicator. The active one (Comment, on the board) is `running`; the rest `textSecondary`.
  With Comment on, a tap on an element pins a comment there.

## On iPad (iPadDesign, iPadSplitView)

**Built** (`App/iOS/DesignPad/`) for hosts that serve designs (`designs.v1`): the canvas and 360pt
chat pane, the header, Pencil markup (where the host offers `design.markup.v1`), Scribble in the
chat's field, and Split View with "Send to the thread". The boards render on the iPad
(docs/designs.md › On iPad, › Pencil markup). Not drawn, and built as the least that is honest:

- **The canvas's tools** are the Mac's toolbar (Select · Comment · Pan | zoom) in the bottom-left
  corner; iPadDesign draws only the Pencil palette, which comes with markup. With Comment, a tap
  on an element opens the comment editor beside it, as on the Mac.
- **The Tweak tab** is DZTweak's anatomy in the 360pt pane; a control too wide for its row goes
  under its label.
- **Export** shares the page's boards as the iPad drew them (PNGs, the share sheet), not DZExport.
- **A narrow window** without a thread in another window shows the design agent's reply card
  without "Send to the thread"; with several such windows, the button asks which thread.
- **The Designs list** the sidebar's row opens is the Mac's cards (NWDesignCard) in a grid.
- **Portrait** keeps the canvas beside the 360pt pane.
- **Markup's moments:** the palette shows while there is ink on the canvas, new or sent (the
  first Pencil stroke brings it; the board draws it beside the agent's answer), and Done with
  nothing new puts it away until the next stroke; Done reads at 40% while the markup is read and
  sent; sent ink stays on the canvas, under new ink, until its proposals are applied or kept.
  In a canvas too narrow for the centered palette to clear the toolbar (portrait), it rises 12pt
  above the toolbar. The palette's Comment is the canvas's Comment tool (a Pencil or finger tap on an
  element opens the editor). Ink is 3pt (the pen) or 12pt (the marker) on screen, and zooms with
  the boards.
- **The proposals** are comments from the moment the agent makes them, as the board counts them
  ("Comments 3" beside cards 2 and 3): **Apply both** sends them to the agent, **Keep as
  comments** leaves them. One reads **Apply**, three or more **Apply all**. Once applied or kept,
  the buttons and the Scribble line give way to "On the canvas as comments 2 and 3." in 12.5
  `textTertiary`. A markup that couldn't reach the agent, and proposals that couldn't be applied
  or kept, say so in the design's dialog and stay as they were.
- **On the Mac** the design's chat shows markup from an iPad as the words the host sends with it
  ("Pencil markup · 2 strokes · 2 notes") and the agent's call as an activity line ("Used markup ·
  2 proposed comments"); the proposals are among its comments, and the Mac draws no proposals
  card.

What the board draws:

- **Design with Apple Pencil** (iPadDesign): a design fills the screen, the canvas beside a 360pt
  chat pane.
  - The header floats over the canvas, clear of the status bar (52pt, 12pt padding, 10pt
    gaps): back to "Designs" (16, `running`), the design's name (16 semibold), a spacer, the
    design system chip, and Export (secondary, 36pt, 13 medium).
  - **Drawing on a board** is markup, never an edit: strokes in the chosen color (2–3pt, round
    caps) and handwriting stay on the canvas as ink. A floating tool palette sits centered 28pt
    above the bottom: a capsule on `bgRaised` (6×14 padding, the popover's line and shadow) with
    44pt tools (the board's glyphs read pen, marker, eraser, and comment; the current one on
    `bgSelected`), a 26pt `lineSubtle` divider, three 22pt colors (`lantern`, `running`,
    `textPrimary`; the chosen one ringed: 2pt `bgRaised`, then 2pt of its color), another
    divider, and **Done** in 15 semibold `running`.
  - **Markup becomes comments.** The agent reads the ink ("Read your markup · 2 strokes · 2 notes",
    the nib), says what it made of it ("I turned the Pencil marks into two comments. The circle is
    on the steps list of the phone board; the underline is the KPI row on A."), and proposes one
    comment per mark, each an `NWCommentCard` (the iPad card: 10×12, 6pt apart, header 12, comment
    13.5/1.45) numbered after the existing pins, whose header names board › element ("on A · phone ›
    Steps list", "on A › KPI row") and says "from your markup" where the author goes. Under them,
    **Apply both** (primary, 36pt) and **Keep as comments** (secondary, 36pt), 8pt apart, then
    "Handwriting in the chat box works too: Scribble turns it into text." in 12.5/1.5
    `textTertiary`.
  - The chat pane's tabs are 44pt at the bottom of a 76pt header (14pt labels, 18pt apart;
    "Comments 3"). The chat has 16pt padding and 12pt between items. Its prose is 14.5/1.55 and
    its activity lines are at least 34pt tall (14.5 `textSecondary`, a 14pt glyph, 9pt gap, meta
    in mono 11.5). The composer (10×14 padding, 26pt below, a hairline above) is the iPad
    thread's card at the compact size (NWDesignTool › Chat composer), placeholder "Describe a
    change, or draw on a board…": attach, the model's short name ("opus",
    `NativeModelChoices.compactName`: no provider, no "claude-" family, no date stamp), the
    thinking level alone, the context ring and Send. It has no "/" button; typing "/" still
    opens the commands. The board draws its chips 40pt and the card at radius 16; the iPad's
    thread card is the Mac's (26pt chips, radius 8), and the design chat keeps it.
- **Split View** (iPadSplitView): a design in one window beside a thread in another (Windows, under
  iOS). The design's window (586pt on the board, radius 12) carries the window's three-dot handle
  centered at its top, so its header is 76pt with 24pt above: a bare back chevron in `running`, the
  name (17 semibold), a comment button (`text.bubble`, 40pt), and Export (secondary, 36pt); the
  boards stack in one column (the desktop board, then the phone board), the selected one ringed. The
  design agent can offer its work to the thread beside it in a floating card over the canvas (360pt,
  12×14 padding, 8pt between parts, radius 12, `bgRaised`, the popover's line and shadow): "Design
  agent · now" in 12 `textTertiary`, its note in 13.5/1.45 ("Restyled boards to the new tokens the
  worker just landed. Want the thread to use these as the spec?"), and **Send to the thread**
  (primary, 36pt), which attaches the boards to that thread (Attach to a thread, under Export).
