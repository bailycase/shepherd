# iOS: iPad

> Read when you change the iPad client's shell, thread, composer, queue, questions, subagents, review or commit.

The iPadOS page's boards are the authority for the iPad: an 11-inch iPad, landscape at 1180×820
and portrait at 820×1180. Everything in iOS holds here (tokens only, 44pt targets, details at
rest); this section adds what the iPad boards fix. Sizes are the boards'; set them through the
iOS ramp (`NWTextStyle`, iOS › Type), never as literals. Paragraphs marked **Not built yet**
specify boards the app does not implement: build them to this text.

**Two drawings.** The thread boards (iPadThread, iPadPortrait, iPadSidebar, iPadReview,
iPadSubagents) draw the thread at full detail under a 52pt bar. The later boards (iPadNewThread,
iPadSteer, iPadQueue, iPadQuestion, iPadCommit, iPadReviewSplit, the destinations and the side
panes) draw a 76pt header (status bar included) with a 17pt title and 40pt icon buttons, and a
schematic thread behind the feature they show. The thread boards fix the thread, the composer
and the header; each later board fixes its own feature.

**Board colors to roles.** The iPad boards draw a few colors between Night Watch's roles. Use:

- meta, times, counters, the turn footer's glyphs (`#767c85`): `textTertiary`
- composer chip labels, the attach glyph, close glyphs, unselected segments (`#c1c5cb`):
  `textSecondary`
- header and card lines (`#22262a`, `#1b1e21`): `lineSubtle`
- a selected row, chip or segment, an active icon button (`#ffffff14`, `#23272c`): `bgSelected`
- the highlighted command, the palette's selection, a steering row, an open header button's fill
  (`#16223a`, `#7aa7ff21`): `runningTint`; that button's glyph (`#a9c6ff`): `running`
- added lines and done pills (`#122a1e`, `#46c37b1f`, words `#6fd49a`): `doneTint`, `done`
- removed lines (`#2a1615`, `#f0625e1f`): `failedTint`; Revert's glyph (`#f58a86`): `failed`
- sheets and popovers (a 0 12 32 black 55% shadow and a 1px `lineStrong` ring):
  `.nwPopover()`. The boards round popovers at 14 and sheets and the palette at 16
  (`MobileLayout.paletteRadius`).
- the dimming behind a sheet, the palette and the portrait sidebar: black at 50% (54% behind
  the sidebar).

A state pill is always `NWStatusPill` with `AgentState`'s colors: an idle agent's pill is
outlined with a `textTertiary` dot, as iPadNewThread, iPadPalette and the side-pane boards draw
it (iPadThread, iPadPortrait, iPadSidebar and iPadReview draw "Idle" in done's green; that is
not the rule).

## Shell and sidebar (iPadThread, iPadSidebar, iPadPortrait, iPadPortraitLaunch)

`PadShell` (`App/iOS/App`) is one `NavigationSplitView` with `PadSidebar` beside the detail: the
selected thread, or the Overview when none is. Other screens push over the detail.

- **Landscape:** the sidebar sits beside the detail, 300pt wide (iPadThread,
  `MobileLayout.sidebarWidth`), on `bgBase` with a 1px `lineSubtle` trailing edge.
- **Portrait** (the window taller than wide, keyboard ignored): the thread takes the width, and
  the sidebar slides over it at 340pt (iPadSidebar, `MobileLayout.sidebarOverlayWidth`), its trailing corners rounded 14, with the
  floating shadow (`.nwFloatShadow`) and the thread dimmed behind it. Tapping the dimmed thread
  ("Dismiss sidebar") or choosing a row hides it. At a launch in portrait with nothing chosen,
  the sidebar is out over the dimmed Overview, since the Overview alone offers no way to a thread
  (iPadPortraitLaunch, drawn by the user's decision of 25 Sep 2026); a tap on the dim only closes
  it, as iPadOS overlays do, and Show sidebar brings it back. The thread's header gains Show sidebar
  (`sidebar.left`, a 44pt circle) at its leading end. Rotating keeps the selection, the pushed
  screens and the composer's focus. Crossing compact and regular width keeps the active route
  stack too (review, subagents, terminals and Settings included), never an old thread selection
  from the other layout. Settings keeps its root and returns to the Settings tab at compact width.
- **Top bar** (56pt, 14pt leading and 8pt trailing inset): Search (⌘K), which opens the palette,
  and Hide sidebar, trailing, as 36pt circles with 16pt `textSecondary` glyphs. The board has no
  title. The app's bar is the system's, with no title as the board: Search, and the split view's
  own sidebar toggle (Known gaps).
- **Destinations** (8pt inset, 1pt apart): 44pt rows at radius 8, 10pt inset, a 20pt leading
  column 12pt from a 15pt label (`.ui`). New thread leads with `plus` in a 20pt `bgSelected`
  circle; the rest with 18pt `textSecondary` glyphs, and More with a `textTertiary` chevron,
  since it expands in place (iPadHosts). Built: New thread (disabled with no hosts),
  Automations (its count trailing), More (folded, the offline summary, "1 host offline", as an
  alert trailing). The rows are `NWListRow(compact: true)`, New thread's plus an
  `NWListRow.Leading.badge`. A pushed destination's row is selected.
- **Not built yet: Missions and Designs** sit between New thread and Automations (a map glyph and
  a diamond glyph). They wait for the Mac's Missions and Designs.
- **More expands in place** (iPadHosts), its chevron turning down, kept per window: its sub-rows'
  content starts 24pt in (12pt past the others, `MobileLayout.sidebarSubrowIndent`), their
  selection the full row, Hosts (with "1 offline" in mono
  `failed`), which opens the Hosts destination (Hosts and More), and Extensions (Settings ▸
  Extensions). A page under More opened from elsewhere unfolds it. **Not built yet:** the
  board's Design systems and Archive sub-rows (Design systems waits for the Design tool, hidden
  until built; Archive for an archive).
- **Section heads** (14pt above, 10pt inset, 4pt under): 13/500 (`NWListHeader(style: .sidebar)`). "Needs you" in `lanternText`
  with its count in mono 10.5 `lanternText`, a 44pt target that opens Needs you; "Recents" in
  `textTertiary`.
- **Rows** (44pt, radius 8, 10pt inset, 12pt gap): a 14pt status column, the title at 15 in
  one line, and a trailing detail in mono 10. The selected thread takes `bgSelected` and a
  semibold title. Status: in Needs you, a glowing 6pt `lantern` dot for a thread, or the
  origin's 16pt glyph in `lanternText` for anything else (a mission's map, an automation's
  bolt; the app leads a subagent's item with its branch glyph); in Recents, a 6pt `running` dot
  while it runs, a hollow 6pt `textTertiary` dot at rest, a 6pt `failed` dot for a failed one,
  and a 16pt `textTertiary` glyph for a design, a mission or an automation run. A failed
  thread's row (iPadThreadError) takes the `failed` dot and "failed" in mono 10 `textTertiary`
  in place of its host tag: a remote client hears no turn failure from the host (Status
  language), so Home's digest reads it from the thread itself, as the header does (a last turn
  that ended in an error, `FleetDigest.lastTurnFailed`), until the next turn starts. The phone's
  rows keep their state word.
- **Needs you rows** end in the reason in mono 10 `lanternText`. The boards summarize the
  question ("retention?", "approve plan", "orders stuck") or name the subagent that asks
  ("reviewer"), which the app does not draw: a subagent never asks you. The app writes the
  agent's own short reason when it gave one, cut as on the Mac (`NeedsYouReason`), else "asked
  you" or "needs you".
- **Recents rows** end in the host tag (mono 10 `textTertiary` in a 1px `lineSubtle` box at
  radius 4) only when threads from several hosts mix. Running rows draw no sparkline (see
  Where Shepherd departs). **Not built yet:** a design's row (the diamond glyph, and "4 boards"
  in mono 10 `textTertiary`) and a finished mission's (the map glyph and "done"). The boards
  also list finished automation runs here (a bolt and "done"); the app keeps runs under
  Automations, and a run that asks you shows in Needs you with a bolt.
- A row's context menu has Open in new window.
- **Footer** (a `lineSubtle` hairline above, 10×12 inset): the hosts, not a person (see Where
  Shepherd departs): `desktopcomputer` (`failed` while any host is offline), "2 of 3 offline",
  "3 connected" or "No hosts" at `.ui` medium, the host names in mono `textTertiary` under it,
  the whole a 44pt target that opens Settings ▸ Hosts; then a Settings gear (a ghost icon
  button). The board draws a 26pt initial avatar, the name at 12.5/500 and "This Mac · build-01"
  in mono 10 `textTertiary`.

## Thread (iPadThread, iPadPortrait, iPadSubagents, iPadReview)

`ThreadScreen` is shared with the phone; on iPad (regular width) it draws as follows.

- **Header** (the system bar, the boards' 52pt, a `lineSubtle` hairline under it): Show sidebar
  when the sidebar is hidden; the name at `.title` (16/600), the branch chip (`NWBranchChip` as on
  the Mac, without its chevron: the branch, the files changed, and the host when more than one is
  set up; iPadThread: "pi/swiftui-previews ●3"), and the status pill (`NWStatusPill`, with the
  running clock: "Running · 37m"; "Failed" on `failedTint` after a reply that failed,
  iPadThreadError); then, trailing, 44pt icon buttons in `textPrimary`. The
  counters ("17 turns · 42k ctx") are gone, as on the boards.
- **Header buttons on the board:** Subagents, Review changes, and Thread options (•••). A
  button whose pane is open takes a `runningTint` fill and a `running` glyph: Subagents while
  the inspector shows (iPadSubagents), Review changes while the review does (iPadReview);
  iPadSteer's 76pt header draws the open one on `bgSelected` instead. The app has one
  side-pane button, as the Mac (see the departures): Show side pane (`sidebar.right`) opens the
  Changes pane; while the review docks or the subagent inspector shows it is lit (a
  `runningTint` fill, its glyph in `running`) and reads Hide side pane, which closes that pane
  (`threadSidePaneOpen`). Then Stop (`stop.fill` in `failed`, while pi runs or asks; iPadSteer
  and iPadQueue draw it) and •••. The card's corner is Stop as well while pi runs and the field and
  attachments are empty, as on the Mac. Subagents is in the ••• menu (while the thread has runs), a
  card's Open and the footer's link. The ••• menu: Refresh, Subagents, Show or Hide Terminal
  (the terminal has no header button), Open in new window, and the agent actions (rename, move,
  delete).
- **Column:** 780pt wide beside the sidebar (772pt in portrait), 24pt gutters, 24pt above the
  first turn; turns 26pt apart and a turn's parts 14pt apart. Beside the review the column is
  512pt (prose 15, bubbles 14), and beside the subagent inspector 672pt (prose 15, bubbles 15).
  The app caps it at 780pt (`MobileLayout.threadMaxWidth`) with 24pt gutters
  (`MobileLayout.padThreadGutter`), and spaces turns 24 and parts 12, the space scale's steps (Known
  gaps).
- **User bubble:** trailing, at most 520pt (432 beside the review, 420 beside the inspector),
  12×16 inset, radius 8, `bgBubble` with a 1px `lineStrong` line, 15/1.5; the time under it in
  mono 11 `textTertiary`, at rest. The app sets `nwUserBubbleMetrics` to `.pad` on iPad (520pt,
  12×16); the bubble's text stays the thread's prose size.
- **Thinking:** "Thought for 4s" as a 32pt disclosure, 13 `textSecondary` with a 12pt chevron.
- **Prose:** `.body` at 16, line height 1.55 on the iPad boards, capped at 680pt.
- **Work:** the boards list each burst as its own 36pt line (a 13pt `textTertiary` glyph, the
  summary at 14 `textSecondary`, its meta in mono 11 `textTertiary`, a 10pt chevron): "Explored 1
  file · read 1", "Edited 2 files · +58 −45", "Ran tests and a build · 1 passed · build ok". The
  app draws the same lines, one per burst.
  The running call keeps its own live line (LiveText): the tool's glyph, still, the summary and
  the command shimmering, and its clock in mono `textTertiary` ("Running tests · go test
  ./ledger/... · 18s").
- **"Edited N files" card** (iPadReview): the phone's card (`NWTurnChangesCard`) at the iPad's
  column width: the 36pt tile, "Edited 5 files" (15/600) over "+200 −8", Undo and Review, then
  "ledger/outbox.go" rows at 14 ("new" before a created file's stat) and "2 more". Its rules are
  the phone's (iPhone: Thread).
- **Turn footer:** Copy response and Retry turn (the latest turn only) as 36pt circles with 15pt `textTertiary`
  glyphs, then "2:44 PM · 3m 12s · 6 tool calls" in mono 11 `textTertiary`, and "· 3 subagents"
  as a link when the turn spawned runs. At rest (no hover).
- **Notices** (caption `textTertiary`, above the turns; the app's, not the boards'): "<host> is
  offline · showing the last known thread", "This agent is no longer on <host>.", "Update
  Shepherd on <host> to open threads here.", one line for each thing the host reported
  shortening (Thread › Notices; nothing for older history or a long message), "This host was
  forgotten.", and a pi that can't start as the phone's one line (iPhone:
  Thread › Banners). Older history loads automatically when the reader reaches the top, keeping
  their visible turn in place (Thread › History); there is no load-history button.

## Composer and commands (iPadThread, iPadPortrait)

- **Placement:** under the thread, 10pt above it, 24pt gutters and 28pt under it, over the fade
  from `bgWindow` at 0% to `bgWindow` at 30% of its height; as wide as the thread's column.
- **Card:** `bgRaised`, a 1px `lineStrong` line, radius 16; the board's faint shadow (0 1 3, 18%) is
  dropped (Principles: one shadow). The field at 15/1.5 (14×16 inset, 4 under it), placeholder
  "Follow up, or / for commands…" ("Follow up…" before the host lists commands, "Queue a follow-up…"
  while pi runs), in `textTertiary`. While the field has focus its line turns `textTertiary` and the
  caret is `lantern` (iPadQueue); the app adds the Mac's focus ring.
- **Control row** (4×6 inset, 6 under, 2pt apart): Attach (a 44pt circle, `paperclip` 18 in
  `textSecondary`), then 40pt chips at radius 10 with 13pt labels in `textSecondary`, 12pt
  inset: "/ commands" (mono, the slash in `textTertiary`), the model (mono, "claude-opus", with a
  10pt chevron), and Thinking (a 14pt `lightbulb`, "Thinking", the level in `textPrimary`
  medium, a chevron; only for a model that takes a level); then the context ring (Composer ›
  Context meter › iPad and iPhone) and Send, trailing: a 40pt `lantern`
  circle with `arrow.up` 16 in `textOnLantern`, at 35% while there is nothing to send. Send queues
  while the agent works; hold it for Steer now; ⌘↩ on a hardware keyboard presses Send, so it
  queues. The ring and Send keep their place when the row scrolls at the
  accessibility text sizes.
- **Commands** (iPadPortrait): typing "/" opens the list inside the card, above the field: 6pt
  inset, a 1px `lineStrong` line, radius 14, `bgRaised`. Its head (4×8): "COMMANDS" at 11/600,
  uppercase, tracked 6%, `textSecondary`, and "4 of 23" in mono 11 `textTertiary`. Rows at least
  44pt, radius 9, 12pt inset and gap: the name in a 160pt column in mono 13.5 (the typed prefix
  in `textPrimary` semibold, the rest in `textSecondary`), the description at 14
  `textSecondary`, and a source tag ("prompt", 11 `textSecondary` on `bgBubble`, radius 4)
  trailing. The highlighted row is `runningTint`. The draft shows in mono while it is a command.
  Five rows show before the list scrolls.
- **Argument hints.** After a command's name, its arguments in mono `textTertiary`
  ("/resume [session]", "/release-notes [tag]"), from the host's prompt-template hint
  (`NativeCommand.arguments`, `NWTouchCommand.arguments`; Composer › Slash menu), on iPad and
  iPhone alike.

## Up next and steering (iPadQueue, iPadSteer)

Up next follows iOS (and Composer › Up next); on iPad it is a card above the composer card,
8pt apart, as wide as it. While subagents show, it is the lower section of the tray's card
(iPadSteer; Subagents below), under a `lineStrong` rule, with no card of its own.

- **Card:** `bgRaised`, a 1px `lineStrong` line, radius 14.
- **Head** (38pt, 14pt leading inset, a hairline under it): the queue glyph (13, `textTertiary`),
  "Up next" at 13/600 `textSecondary`, the count in mono 11.5 `textTertiary`, and Queue options
  (•••, a 34pt circle) trailing. The ••• menu: Steer all now (Send all now while pi is idle),
  "When the turn ends, send" (the delivery mode), and Clear the queue.
- **Rows** (50pt, a hairline above each, 14pt leading and 8pt trailing inset, 12pt gap):
  - A steering row (the fallback's, as on the Mac), first, on `runningTint`: `arrow.turn.down.right` 15 in `running`, the text at
    15 on one line, the "Steering" pill after it (24pt, radius 6, `runningTint`, `running` 12.5/500
    with its 12pt glyph; `NWTouchQueueRow(wide: true)`, where the phone puts "↳ Steering" under
    the text), and Back to the queue (a 34pt circle).
  - A queued row on `bgRaised`: its number in a 22pt circle (a 1px `lineStrong` line, mono 11.5
    `textSecondary`), then the text at 15; an image count when it carries images. The first
    queued row while the agent runs also has a labelled **Steer now** button after them (decided
    by the user, 2026-10-01; iPhone and iPad alike, see iPhone: Up next), a hardware ⌘↩ staying
    as it is.
- **Swipe** a queued row left: Edit (80pt, `bgSelected`, a 17pt `pencil` over "Edit" at 12/500)
  and Delete (80pt, `failed`, white). Long-press: Steer now, Edit, Move to top, Delete. A delete
  leaves an Undo row.
- **Header while it runs:** "Running · 5m", the side-pane button and Stop (iPadQueue).

## Questions (iPadQuestion)

A question takes the composer's place: a card, not the phone's docked panel, up to 900pt wide
(wider than the thread's column), 10pt above the thread's end and 26pt from the bottom. The
header's pill turns "Needs you" (attention, glowing).

- **Card:** `bgRaised`, a 1px `lantern` line, radius 16, a 3pt `lanternTint` ring outside it;
  14×18 inset (16 at the bottom), parts 12pt apart.
- **Head** (26pt): a 13pt glyph and "Agent is asking" at 13/600, both `lanternText`; and,
  trailing, **Hide the question**: a 40pt circle (`.nwIcon`, a 44pt touch target) with an 18pt
  `chevron.down` in `textSecondary`, overhanging the head rather than growing it, which folds the
  card to read the thread and never answers it ("Hide the question" to VoiceOver). The phone's
  docked panel hides from its grabber instead.
- **Folded** (`NWQuestionCardHiddenLine`; no board draws it, so it follows the Mac's hidden
  line, QuestionStates › hidden): the same lantern card around one row, 16pt leading and 4pt
  trailing: a 14pt glyph in `lanternText`, the question in `headline` (truncating), a secondary
  **Answer** (m), and Show the question (the same 40pt circle, `chevron.up`); either button
  unfolds it. It still holds the composer's place, because the agent is still waiting. Only that
  question stays folded: the next one arrives open (`NativeQuestionHiding`, the Mac's rule).
- **The question:** 19/600/1.35.
- **Answers,** numbered, side by side in two columns when each gets at least 220pt, 8pt apart;
  one column otherwise:
  - An answer card: 12×14 inset, radius 8, 11pt gap: its number in a 24pt square at radius 5
    (mono 11), then "Recommended" when the asker marks one (20pt, radius 4, `lanternTint`,
    `lanternText` 11/600), the title at 15/600/1.35, and its description at 14/1.45
    `textSecondary`.
  - At rest: `bgWindow`, a 1px `lineSubtle` line, the number outlined in `lineStrong` with
    `textSecondary`. Chosen: `lanternTint` with a `lantern` line, the number on `lantern` in
    `textOnLantern` semibold.
- **No note and no "Something else…".** The board draws a note field in the chosen answer and a
  last full-width "Something else…" row, but no asker takes either: pi's dialogs take neither,
  and a subagent asks its parent (the dock's What each asker takes). The components that drew
  them (`NWQuestionNoteField`, `NWQuestionOtherCard`) were pruned, with the subagent variant.
- **Foot:** Answer, primary, 36pt, trailing, enabled once there is an answer; there is no
  Dismiss (Stop refuses pi's question, as on the Mac and the phone). A yes or a no is two cards
  side by side that answer on a tap; an open question is a field over Answer.
- **The app's additions:** "1 / N" (mono `textTertiary`) in the head when several questions
  wait; the asker's longer message in mono on `bgSunken` under the question; "The agent may stop
  waiting for this answer" under an answer with a timeout; and, for a question it cannot show,
  "An external editor is open on the host · finish it there" or "This question is too large
  to show here · answer it on the host".

## New thread (iPadNewThread)

New thread is a form sheet over the thread: 600pt wide, radius 16, `bgWindow`, the popover
shadow, the window dimmed behind it.

- **Bar** (14×18 inset, a hairline under it): Cancel (16, `running`), "New thread" (16/600),
  Start (16/600, `running`; disabled until there is a prompt and a host).
- **Body** (18pt inset, parts 18pt apart):
  - The prompt at 18/1.45, at least 110pt tall, placeholder "What should the agent do?", a
    `lantern` caret.
  - Chips (`NWSelectorChip`: 32pt capsules on `bgRaised` with a 1px `lineStrong` line, a 13pt
    `textSecondary` glyph, the value at 13, a 10pt `textTertiary` chevron): the repo (mono,
    "shepherd"), the host (mono, "This Mac"), the model (mono), and the thinking level
    ("Medium"; only for a model that takes one). A chip whose popover is open wears a
    `lanternText` line.
  - Attach (a 36pt circle, `paperclip` 16) and "New worktree on `shepherd`" (12.5
    `textTertiary`, the repo in mono), which opens the worktree popover (the switch, the branch
    and the base).
  - **Not built yet:** "Touches more than one repo? **Start a mission**": a row with a 1px
    `lineSubtle` line at radius 10, 10×12 inset, a 14pt glyph, 13 `textSecondary`, the link in
    `running` medium. It waits for Missions.
- **Chip popovers** open under their chips. "Run on" (the host's): 300pt wide on the board,
  radius 14, its title at 13/600 (12×14 inset), then a row per host, at least 60pt with a
  hairline above: an 8pt status dot (`done` connected, `failed` unreachable), the name in mono
  14.5/600, what it is at 12 `textTertiary` ("Shepherd app · agent 0.87"), what it carries at 11.5
  `textSecondary` ("2 threads · load low"), and a `running` check on the chosen one. An
  unreachable host dims to 55% and reads "unreachable since 07:12" with Retry (13, `running`).
  Built: the dot, the name, the connection and its running threads ("connected · 1 thread
  running"), "unreachable" and Retry. **Not built yet:** the kind, the host's pi version, its
  load and the time it went down; the remote protocol carries none of them.
- **Not built yet: daemon hosts** ("build-01 · Linux daemon · 2 missions · 6 of 16 cores",
  "horizon · macOS daemon"). Every host is a Mac running Shepherd.
- Other popovers (the app's): Repo (the host's spaces first, other hosts' after, and Add repo,
  which browses the host's folders), Model, and New worktree. A failure shows "Couldn't start
  the thread" with Try again or Resolve.

## Subagents (iPadSubagents, iPadSteer)

Runs open in an inspector beside the thread (`PadSubagentInspector`), never over it: 460pt on
iPadSubagents and 400pt on iPadSteer (the app lets it range 340–480, 400 ideal), with a 1px
`lineStrong` leading edge on `bgWindow`. Closing it returns to the thread as it was. With no run
chosen (All subagents) it lists the thread's runs under a "Subagents" head with their tally.

- **The tray** (iPadSteer, iPadSubagents, iPadSplitView, SubagentTray › iPad;
  `SubagentTraySection`, `NWSubagentTray` at `.pad` size): above the composer, in one card with
  Up next (radius 12). A 40pt header (14pt leading, 4pt trailing, a 13pt glyph, "3 subagents" at
  13/600, the cells and tally, Collapse as a 34pt circle); 44pt rows (14pt leading, 4pt
  trailing, 10pt apart): the state in a 14pt slot, the name in mono 13/600 in an 80pt column,
  what it is doing at 13.5 (the subject in mono 12.5), its diff stat and time in mono 11, then
  Answer (lantern `m`) for a run that needs you, else a chevron in a 34pt slot. The run the
  inspector shows is selected: `bgSelected` (the needs-you tint kept) with a 2pt leading rule,
  `running`, or `lantern` on a run that needs you, whose Answer gives way to the chevron. A row
  opens its run in the inspector; touch and hold for Open, Answer and the run's controls. It
  stays until your next message once every run finished ("all done"; iPadSubagents).
- **In the thread:** "Started 3 subagents · worker · reviewer · tests" and, once they finished,
  "3 subagents finished · 45m · 7 files · +318 −64" (34pt, 14); both, and the turn's footer "·
  3 subagents", open the runs.
- **Inspector head, one run** (the bar's height, 14pt leading inset): its state glyph (16), the
  name at 15/600 with "· 3 of 3" at 400 `textSecondary`, and its meta in mono 11 `textTertiary`
  ("claude-sonnet · 11 turns · done 11:02", the finish in `done`); Previous subagent and Close
  as 44pt circles. The app adds Next, a ••• menu (Pause, Continue, Stop, Re-run, where the host
  takes them) and All subagents (`list.bullet`).
- **Inspector head, a live group of up to four** (iPadSteer): the runs as a segmented control (a
  `bgSelected` track at radius 9, 2pt inset; 30pt segments at radius 7, 13; the chosen one on
  `bgRaised`, semibold) and Close. At accessibility sizes, or with more runs, the one-run head
  steps through them instead.
- **Goal and result** (a band on `bgBase` with a hairline under it, 14×16 inset, 10pt apart):
  "GOAL" and "RESULT" labels (11/600, uppercase, tracked 6%; `textSecondary`, and `done` for the
  result), the goal at 14/1.5 `textSecondary`, the result at 14/1.5 `textPrimary`.
- **A run asking** (iPadSteer): its glyph (15, `lanternText`), the name in mono 16/600, its mode
  and model at 12 `textTertiary` ("async · opus"), and the pill "Needs you · 2m". The question at
  15/1.5, inline code in mono 12 on `bgSunken` with a 1px `lineSubtle` line at radius 4. Answers
  as 36pt buttons: the first primary, the rest secondary, and Reply… (ghost, `textSecondary`),
  which opens a reply field.
- **Not built yet:** the question's code block (`bgSunken`, a 1px `lineSubtle` line, radius 8,
  10×12 inset, mono 10.5/1.6 with syntax colors, file captions as comments) and each answer's
  description (the title at 13/600 in a 150pt column, the description at 13/1.45
  `textSecondary`). A subagent's options reach the client as titles only.
- **Transcript** (16pt inset, parts 14pt apart; `NWProseSize.small`): the parent's message as a
  bubble (at most 340pt, 10×14 inset, 14) with "10:58 · from parent" under it, then the run's
  prose (15/1.55) and activity lines. iPadSteer draws "Its run" for an asking run as a summary of
  its steps ("Read the spec · 2 files", "Compared tokens · 18 names", "Asked the parent · 2m
  ago"); the app shows the live transcript there too.
- **Foot** (a hairline above, 10×12 inset, 28 under): a live run has the steer field ("Steer
  reviewer…", captioned "to: reviewer · not the parent · lands before its next turn"); a finished
  one Re-run (secondary, 40pt at radius 10) and ••• (44pt). The app adds Copy transcript. The
  board's Fork as new agent is not offered over remote (see Where Shepherd departs).

## Review (iPadReview, iPadReviewSplit)

`PadReviewScreen` has two layouts: the pane's ••• (Full screen) and "‹ Thread" switch between
them. Both read the host's Changes engine (`changes.v1`) as the phone does (iPhone: Review):
the scope menu, the base picker, a file's lines fetched as it nears the screen, word diffs.

**Docked** (iPadReview): the thread keeps the left and the Changes pane takes the right: 640pt,
never more than 58% of the detail, with a 1px `lineStrong` leading edge on `bgWindow`. The board
hides the sidebar so the thread keeps a 540pt column; the app keeps the sidebar in landscape
(`PadShell`), so the pane narrows and its toolbar drops the viewed count, then the stat, rather
than clip (Known gaps).

- **Pane head** (52pt, 10pt inset, a hairline under it): the Changes tab (36pt, radius 6,
  `bgSelected`, 12.5/600, its glyph and the file count in mono 10.5 `textTertiary`), then Pane
  options (a 28pt bordered circle: Full screen, Finalize worktree…) and Close pane (28pt). The
  board's Browser, Artifacts and Files tabs are not built on iPad (Side pane).
- **Toolbar** (ChangesStates › ChangesToolbar; 54pt, 12pt leading, a hairline under it): the
  scope pill (36pt, radius 6, `bgRaised`, a 1px `lineStrong` line: a branch glyph, "Branch" at
  15/600, a chevron), the scope's stat (mono 12), then "👁 2/5 viewed" (a 24pt `bgSunken`
  capsule, 12 `textSecondary`), Commit… (secondary, 28pt, the commit glyph), then 36pt icons:
  Refresh, Collapse all files (Expand all once every file is folded), the split toggle (its
  glyph is the mode it switches to), and Diff options (•••: Word diffs, Hide whitespace changes,
  Load full files, then Copy git apply command and Copy as patch). Changing a host-side diff
  option reloads the displayed hunks even when the compared trees did not change; a late reply
  for an older option or scope never replaces them.
- **Compare row** (38pt on `bgBase`, 12pt inset): the head in mono 12 `textSecondary`, →, the
  base in mono 12 `textPrimary` with a chevron (Branch only: the base picker, a popover), and
  "merge base 3f2a91c" (or a turn's `after “…”`) in mono 11 `textTertiary` trailing.
- **File strip** (`NWTouchFileStrip`): 36pt chips in mono 12 (the status letter bold, the name,
  the stat); the chip tapped is filled, and the stack scrolls its file to the top; viewed files
  dim.
- **Files, stacked** in one lazy list: each file's head sticks while its file scrolls (44pt on
  `bgRaised`, hairlines above and below): a disclosure chevron, the status letter, the folder in
  `textTertiary` and the name semibold (mono 12), its stat, and Viewed (a 14pt checkbox and
  "Viewed" at 12 `textSecondary`); ticking Viewed folds the file away, and a tap on the head folds
  or opens it. The board's per-file Comment and Open buttons are not built (Known gaps).
- **Diff** (unified while the pane is narrow, ChangesStates' rule: split from 900pt): lines in
  mono 12.5, two 34pt gutters in mono 11 `textTertiary`, a 14pt sign column; removed lines on
  `failedTint` and added on `doneTint`, each with a 3pt `failed`/`done` bar at its leading edge
  (the gutter bar), a changed word on its tint again. A hunk's head is the unchanged lines before
  it ("95 unmodified lines", 44pt on `bgSunken` between hairlines, a ⌃⌄ glyph, 12
  `textSecondary`); a tap asks the host for the whole file. Long runs fold as on the phone.
  Tapping a line opens a comment editor under it.
- **Comment** under its line, indented to the code: `bgRaised`, a 1px `lineStrong` line, radius 10,
  10×12 inset: an 18pt initial, "You" semibold, "line 103 · just now" in mono 12 `textSecondary`,
  Edit and Delete, then the text at 14/1.5.
- **Send bar** (`NWReviewSendBar`, only while comments wait; a hairline above, `bgWindow`): a
  `running` bubble, "1 comment" semibold and "on outbox.go, not sent yet" in `textSecondary`,
  then Discard (ghost) and Send to agent (primary). Sent, the review closes and opens next on
  Last turn. There is no overall comment box. A failed send shows "Couldn't send the comments"
  with Dismiss.

**Full screen** (iPadReviewSplit): the review takes the detail column (the sidebar stays in
landscape, Known gaps).

- **Head** (the bar): "‹ Thread" (back beside the thread), "Review" at 17/600, the scope pill and
  the stat; trailing, "2/5 viewed", Commit…, the split toggle and Diff options (which adds Refresh
  and Collapse all here), and Finalize worktree for a worktree agent.
- **Compare row** as docked.
- **File list** (260pt on `bgBase`, a 1px `lineSubtle` trailing edge, 12×10 inset, 4pt apart):
  "5 FILES" (`.nwSectionLabel()`) with "+200 −8"; rows at least 58pt, radius 10: the status letter
  in mono 12 bold, the name in mono 13/600 over its directory in mono 11 `textTertiary`, the
  comment count and the stat trailing. The file tapped is filled and scrolled to; viewed files
  dim.
- **Split** (the default here): halves split by a 1px `lineSubtle` line; rows in mono 12, a 34pt
  number column, a 14pt sign column, removed rows on `failedTint` and added on `doneTint` with
  their gutter bars; a side with no line opposite is hatched (`lineSubtle` stripes at 135°, every
  6pt). Folds sit on their side, blank `bgSunken` on the other. Comments sit under the side they
  were written on.
- **Send bar** across the foot, as docked.

## Commit (iPadCommit)

Commit… opens a popover in the invoking window only (`.commitPopover`); another window shares
its operation status, never its presentation or dismissal. A second viewer joins the existing
editable form without reloading over its unsaved message. Forget discards local form and operation
state, ignores later replies, and never rolls back a commit already sent to the host. The popover is 400pt wide, `bgRaised`, with its arrow; 16pt
inset, parts 12pt apart.

- **Title:** "Commit 5 files" at 17/600 and "to agent/refund-events" in mono 12 `textTertiary`
  ("Committing…", "Committed", "Pull request opened", "Commit stopped" as it runs).
- **Message card** (`bgWindow`, a 1px `lineStrong` line, radius 10, 10×12 inset): the summary
  semibold, the body in `textSecondary`, and "Drafted from the diff · edit anything" with a
  sparkle. Both lines edit in place. The primary is "Commit & push" here, on the phone and on the
  Mac: one wording and one note everywhere (the user's call, 2026-09-25; the iPadCommit board
  matches).
- **Options** as checkboxes (rows at least 44pt): Push to origin (the upstream it pushes to in
  12 `textTertiary`) and Open a pull request (where the PR goes). The popover commits every
  changed file; the phone's sheet is where files are ticked off. The board's "draft" pull request
  is not offered: the host opens a ready one (Known gaps).
- **Foot:** Cancel (secondary) and the primary, whose title follows the options: Commit, Commit &
  push, or Commit & open PR. The app adds Ask agent (ghost, leading), which sends the agent a turn
  instead.
- **States** (the app's): "Reading the changes on the host…" while it loads; "Can't commit
  from here" when the host can't; "The agent is working" with a "Commit while it works"
  switch; "Can't commit here" for a detached HEAD or a merge in progress; "Redrafting the
  message…" while Commit waits on a new draft; "Starting on the host…", then each step, then
  Done, or Close while it continues on the host; "Nothing was committed", "Stopped", "Outcome
  not yet known".
