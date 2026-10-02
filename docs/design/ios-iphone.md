# iOS

> Read when you change the iPhone client's shell, home, thread, new thread, queue, subagents or review.

The iOS client (`App/iOS`, [docs/ios](../ios/README.md)) is built on Night Watch, with the
phone and iPad boards as its authority. The same rules hold as on the Mac (tokens only, shared
components first), with these differences for touch:

- **Type:** the phone and iPad boards' ramp, following Dynamic Type through `relativeTo:`
  (`NWTextStyle` on iOS): `.display` 28/600, `.headline` 17/600, `.title` 16/600, `.body` 16 at 1.5
  line height, `.ui` 15/500, `.caption` 12, `.code` mono 13, `.mono` 12, `.micro` mono 11. Rows are
  15, prose 16, meta 12. The boards also use sizes the ramp has no step for; take the nearest step,
  never a literal: 13/600 section heads → `.caption` at 600; 14 secondary text (activity labels, a
  card's detail, a comment) → `.ui`; 12.5 → `.caption`; mono 10.5–11.5 → `.micro` or `.mono`. Sizes
  off the ramp go through `Font.nwSans`/`Font.nwMono` with a named metric, never a literal: the
  New thread prompt's 18 (`MobileLayout.newThreadPromptSize`), the selector chips' 13
  (`NWSelectorChipMetrics`), a repo's name in Where it runs (`NWChoiceRowMetrics.titleSize`), and
  the boards' 30pt large titles.
- **Touch targets:** 44pt (`NW.Height.touch`). Controls keep their drawn size and grow their hit
  area (`.nwTouchTarget(height:)`); rows people tap are at least 44pt tall. One deliberate
  exception: diff lines (`NWTouchDiffLine`) keep the boards' dense `NW.Height.rowCompact`, so a
  file reads as code. A tap only selects the line to comment on (a miss selects its neighbor,
  and nothing is sent until the comment is written), and VoiceOver reaches each line as its own
  button.
- **No hover:** `NWPlatform.showsHoverDetails` shows at rest what the Mac reveals on hover (a
  message's time, a turn's footer, a code block's Copy, a comment's actions); a pressed row
  shows the hover fill.
- **Navigation:** iPhone has two tabs, Home and Settings, each a stack; iPad a split view with
  the sidebar beside the thread in landscape and over it in portrait (see iOS: iPad › Shell and
  sidebar). Portrait is the window's shape (taller than wide), never what the keyboard leaves
  of it (`PadSplitLayout`).
- **Following** (the boards draw only a thread at its tail): the Mac's rule (Thread ›
  Following), with a finger's drag as the only intent. "↓ Jump to latest" (`NWJumpToLatest`)
  sits 8pt above the composer, drawn as on the Mac with a 44pt hit area.
- **A paused queue** has no hover to reveal a row's Send now or the header's tooltip: its header
  shows Send now (secondary, small; the ••• menu's Send all now) between "Paused" and the •••,
  and the reason is its VoiceOver hint. At accessibility text sizes Send now takes a row of its
  own under the title, and "Jump to latest" grows with its text.
- **Windows (iPad; iPadSplitView, iPadPalette boards):** each window is a whole Shepherd, with
  its own sidebar and thread, over the same hosts and drafts, and its own place restored on
  relaunch. "Open in new window" (`macwindow.badge.plus`) sits in a thread's options menu and
  in the sidebar's and the palette's row menus, and beside Open in the palette's preview as a
  secondary button; it brings forward a window that already shows the thread. A terminal's
  screen is in one window at a time (see Terminal). A turn's long-press menu has Copy and
  "Send to", a submenu of the threads other windows show (the thread's name over its host),
  which puts the text in that thread's composer after a blank line and brings its window
  forward; a turn also drags out as text. A composer with text over it wears the
  focus ring. iPhone shows none of this: it has one window.
- **A design beside a thread** (iPadSplitView): the board's second window is a design, which
  is not built yet (Design tool › On iPad). The thread window beside it follows the rules
  above.
- **App measures** come from `MobileLayout` (`App/iOS/Support`), as the Mac's come from
  `AppLayout`.
- **Terminal** (iPadTerminal board; `App/iOS/Terminal`, `NWTerminalTabBar`, `NWTerminalKeyRow`; the
  terminal itself as in Terminal):
  - **iPad:** the Mac's panel under the thread and composer, across the thread's width
    (`.threadTerminal(_:)`), 340pt tall by default (`shepherd.ios.terminalHeight`), sliding up from
    the bottom edge (`.pane`). Its strip is 46pt with 32pt tabs and 34pt icon buttons hit at 44
    (`NWTerminalMetrics`), in the Mac's order and states. The divider is a 36×4pt `lineStrong`
    grabber centered on the strip's top edge (an 88×22pt hit area) in place of a pointer handle,
    snapping and clamping as on the Mac, adjustable with VoiceOver, and hidden while maximized. The
    strip and key row stop growing at xxxLarge.
  - **Toggle:** the thread's options menu: Show Terminal or Hide Terminal on iPad (iPhone:
    Terminal), absent while the host is offline. With no terminal in the thread it opens one (the
    panel shows on it once the host has made it; a failure gives a haptic with no panel up, and the
    panel's banner while it is). There is no header button; iPadTerminal's is a departure
    (Terminal panel › Show and hide).
  - **Key row** (`NWTerminalKeyRow`), while a terminal has the keyboard, under it and over the
    software keyboard: `bgWindow` with a `lineSubtle` hairline on top, 8pt top and bottom padding
    and 12pt sides, keys 6pt apart (the board adds 26pt under the row for the home indicator). Keys:
    esc, tab, ctrl, ⌥, `|`, `~`, `/`, `-`, then the arrows (the board: esc, tab, ctrl, ⌥, the
    arrows, `|`, `~`, `/`; see the departures). Each is a 34pt keycap at least 44pt wide, 10pt side
    padding, radius 7, on `bgRaised` with a `lineSubtle` border, its label in Geist Mono 13
    `textPrimary`; a pressed key dims to 60%. ctrl and ⌥ latch for the next key: `lanternTint` fill,
    `lantern` border, `lanternText` label. One row where it fits; on a phone in portrait it wraps
    into two rows of six equal keys (the arrows together in the second), and only where two rows
    don't fit either does it scroll, with its scroll bar showing. A hardware keyboard types
    directly.
  - **iPhone** (no board): the options menu's Terminal opens the terminals full screen
    ("Terminal" as the inline title, the tab bar hidden) with the same tabs and +, without
    Maximize or Hide, and the same key row. It opens a terminal as it appears when there is none,
    and goes back with its last terminal.
  - **The terminal** (iPadTerminal): Geist Mono 13 at 1.6 line height, 10×16 inset, the prompt's
    user in `done`, its path in `running`, its branch in `lanternText` and `$` in `textTertiary`,
    output in `textSecondary`. The app sets `.code` (13) and follows Dynamic Type up to 20pt
    (`MobileLayout.terminalMaximumFontSize`), on `bgWindow` (see the departures) with the Mac's
    `lantern` cursor, where the board draws a `textPrimary` block (Known gaps). A tab names its
    host after its title (mono 10.5 `textTertiary`, "build-01"), as on the Mac.
  - **Closing a tab** asks first: the dialog's title names the tab ("Close zsh?", or "Close zsh (tab
    2)?" when another tab shares its title), its message says what stops ("Its shell on <host>
    stops.", "Its 3 shells on <host> stop.", "It closes on <host>."), then Close Terminal
    (destructive) and Cancel.
  - **States:** "<host> is offline."; "Update Shepherd on <host> to open terminals here." for a
    host without `pane.control.v1`, which shows its terminals but offers no + or close; there is
    no empty state. A failed terminal request shows a `failed` `NWBanner` under the strip with
    Dismiss ("Couldn't open a terminal: …" or "Couldn't close the terminal: …", "Update Shepherd on
    the host to open a terminal here." (or "…to close the terminal here."), "An agent's own thread
    can't be closed."). A host from before terminals were tabs only may still hold a split tab,
    which the panel draws as one tab per terminal.
  - As on the Mac, the iPad panel closes with its last terminal while the host is connected, and tab
    dots follow the host's news, so a tab leaving the screen (its viewer detaching, the PTY taking
    the Mac's size again) leaves no dot.
- **Commit from review** (MobileCommit, iPadCommit boards): the same parts as the Mac's sheet. On
  iPhone the changes' bar reads Send 1 comment and **Commit…** (primary), which presents a sheet
  (Cancel, "Commit n files"; Message, Files "n of m", the options card; a full-width Commit &
  push, with Ask agent to commit as a link under it and in the review's ••• menu). File rows are
  44pt and show the name alone. On iPad, Commit… (the Changes toolbar's, docked or full screen)
  opens a 400pt popover; its anatomy is in iOS: iPad › Commit. A host without
  `review.commit.v1` keeps the single Commit that asks the agent.

## iPhone: shell and shared anatomy

The iPhone boards (the iOS page) draw a 390×844 screen in the dark appearance. Build every phone
screen from these parts; the sections after this one give each board's specifics. A paragraph marked
**Not built yet** is the spec for work that has not landed.

- **Shell** (`PhoneShell`; MobileAgents, MobileSettings): two tabs, Home and Settings, each a
  `NavigationStack`. The boards' tab bar is a 1px `lineSubtle` rule over `bgWindow`, 8pt above and
  28pt below, each tab a 22pt glyph (a house, a gear) over an 11/500 label, 4pt apart, at least 44pt
  tall; the selected tab is `textPrimary`, the other `textTertiary`. The boards draw the tab bar
  only on the two roots, Home and Settings: every pushed screen (Needs you, Automations, More, a
  thread and everything opened from it, search, Instructions, Experiments) takes the whole screen.
  The app uses the system `TabView` (`house`, `gearshape`) and hides the bar (`.toolbar(.hidden,
  for: .tabBar)`) on a thread, its subagents and runs, its changes and diffs, the terminal and
  search; Needs you, Recents, Automations and More still show it.
- **Navigation:** `navigator.open(route)` pushes onto the current tab's stack (a Settings route
  switches to the Settings tab); `navigator.present(route)` presents a sheet with its own stack: New
  thread, Commit, the automation and host forms, rename and delete. Needs you, Recents, Automations
  and More push from Home; a thread pushes from any list.
- **Large-title screens** (Home, Needs you, Automations, More, Settings, Instructions, Experiments):
  54pt from the top, 16pt sides, 10pt under, no rule. The back link sits on its own 36pt line ("‹
  Home", "‹ Settings": 16 `running` with an 11pt chevron, 6pt apart), then the title (Geist 30/600,
  tracking −0.02em; Home's "Shepherd" is 28/600 with its buttons on the title's baseline, 62pt from
  the top), then an optional 13 `textTertiary` line ("4 things are waiting on you", 4pt under).
  Trailing actions are 36pt circles, 8pt apart: bordered (1px `lineStrong` on `bgWindow`, a 15pt
  `textPrimary` glyph) for Search and New thread, or filled `lantern` with a `textOnLantern` glyph
  for the screen's one create action (New automation). The app builds these on the system navigation
  bar: a large `navigationTitle`, the system back button, and `ToolbarItem`s with SF Symbols
  (`magnifyingglass`, `square.and.pencil`, `plus`).
- **Inline-title screens** (a thread, Subagents, one subagent, Changes, a diff): 54pt from the top,
  8pt leading and 12pt trailing, 10pt under, then a 1px `lineSubtle` rule. Leading, in a 70pt slot,
  the back link naming where it goes ("‹ Home", "‹ Thread", "‹ Subagents", "‹ Changes"; 16
  `running`, 4pt gap). Centered, the title (16/600, one line, truncating) over either a status line
  (12/500: a 6pt `NWStatusDot`, the state's word in its `textColor`, then "· meta" in mono
  `textTertiary`, 6pt gaps) or a mono 11.5 `textTertiary` subtitle ("working tree vs HEAD"), 2pt
  apart. Trailing, a 70pt slot of 34–36pt icon buttons, 4pt apart (Stop, •••, Next file). The app
  puts its own title view in the bar's principal slot (`ThreadTitle`, `SubagentListTitle`,
  `SubagentRunTitle`, `ReviewTitle`, `DiffTitle`: `.nw(.headline)` over `.nw(.caption)`), beside the
  system back button and toolbar items. MobileThread and MobileApproval draw an older header (a 40pt
  chevron with no word, the title left-aligned at 15/600); the centered form is the rule.
- **Screen surfaces:** a thread, a diff, one subagent, the Needs you, Automations, More and Search
  lists, and every sheet are `bgWindow`. Home, Settings, Instructions, Experiments, Changes and the
  Subagents list are `bgBase`, so their cards read as raised. Sides are 16 (`MobileLayout.gutter`)
  on threads, sheets and Home, and 14 on every other list (Needs you, Automations, More, Settings,
  Instructions, Experiments, Subagents, Changes, Search), with 10pt between blocks. The app uses 14
  (`MobileLayout.searchGutter`) only on Search and Changes, and 16 elsewhere.
- **Cards** (`NWListCard`, `.nwCard(radius: MobileLayout.cardRadius)`): `bgRaised`, a 1px
  `lineSubtle` line, 12pt corners (`NWListMetrics.cardRadius`), rows separated by 1px `lineSubtle`
  rules. Home's cards alone are `bgWindow` on its `bgBase` screen. A card that needs you (a thread's
  question) takes a `lanternText` line; a running one (Automations' Running now) a
  `running` line with a 3pt `runningTint` ring.
- **List rows** (`NWListRow`): 14pt sides, 8pt vertical padding, 12pt between parts. A leading
  column 18–20pt wide (`NWListMetrics.leadingWidth`) holds an 8pt status dot or a 15–17pt glyph in
  `textSecondary`; the title is 15/500 `textPrimary`, one line; an optional status line 2pt under
  it; one trailing accessory; an 8×14 chevron in `textTertiary`. One-line rows are 48pt
  (`NWListMetrics.rowHeight`). A title over a status line is 52pt in thread and search lists (Home,
  Search, More's rows), 56pt in choice lists (Where it runs, earlier runs), 58pt for review files
  and 64pt for automations, which have three lines. The status line is mono 11 `textTertiary` for
  threads, Geist 12.5 `textTertiary` elsewhere; it turns `lanternText` for a question. Trailing
  accessories: a count in mono 12 `textTertiary`, a setting's value in 14 `textTertiary`, a problem
  in mono `failed` ("1 host offline"), or the host a row lives on (`NWHostBadge`: mono 10.5
  `textTertiary`, a 1px `lineSubtle` line, 4pt corners, 1×5 padding; the app draws `lineStrong`).
  Link rows ("See all 4", "Show all recents") are 44pt, centered, 13/500 `textSecondary`. A pressed
  row shows the hover fill (`.nwRow`).
- **Section heads** (`NWListHeader`): 13/600 `textSecondary` (`lanternText` for Needs you), with 4pt
  sides and 2pt under; trailing, a count in mono 12 `textTertiary` (`lanternText` for Needs you), a
  note in 12 `textTertiary` ("tap to read the diff", "kept after they finish"), or an action in 13
  `running` ("Add host", "Add all"). A head that follows a card has 8pt more above it.
- **Sheets** (MobileWorkspace, MobileCommit): the screen under it dims (black at 50%); the sheet has
  16pt top corners, a 36×5 `lineStrong` grabber (8pt above, 6pt below), and a header row: Cancel (16
  `running`) leading, the title (16/600) centered and, where the sheet confirms, Done (16/600
  `running`) trailing (Where it runs; Commit's trailing slot is empty), each side in a 64pt slot,
  over a 1px `lineSubtle` rule; its body has 16pt padding. The app presents the system sheet
  (`presentationDragIndicator(.visible)`, `presentationBackground(Color.nw.bgWindow)`) with Cancel
  and Done as the stack's toolbar items.
- **Bottom bars** (the composer, Changes, a diff's comment bar, Commit): a 1px `lineSubtle` rule
  above, `bgWindow`, 12–14pt sides, 10–12pt above and 30–34pt below for the home indicator.
  Full-width actions are 48pt with 12pt corners at 16pt (`.nwReviewBar(_:)`): primary `lantern` with
  600 `textOnLantern`, secondary `bgRaised` with a 1px `lineStrong` line and 500 `textPrimary`; two
  share the width with 10pt between them.
- **Buttons inside cards** use `.buttonStyle(.nw(_:size:))`: Needs you's answers are 28pt (`.m`:
  12.5, 10pt sides); a host's Retry is 32pt (`.l`: 13, 14pt sides; the
  app's Retry on More and Home is `.s`, 24pt). The first answer is primary, the rest secondary, and
  Open or Reply… ghost. Each keeps its drawn size and hits at 44pt.
- **Switches:** `.toggleStyle(.nwSwitch)`, 30×18, `lantern` on, `lineStrong` off, hit at 44pt.
- **Status:** `AgentState` only. Header dots are 6pt, row dots 7–8pt; a state that needs you glows
  in `lantern`; idle is a hollow `textTertiary` ring. Pills (`NWStatusPill`) are 20pt with 4pt
  corners on the state's tint.
- **Colors by role.** The boards' hexes are Night Watch's roles: `#0a0b0c` `bgBase`, `#0d0e10`
  `bgWindow`, `#15171a` `bgRaised`, `#111316` `bgSunken`, `#1a1d21` `bgBubble`, `#1f2226`
  `lineSubtle`, `#2c3035` `lineStrong`, `#e8e9ec`, `#9aa0a9` and `#5f656e` the three text roles,
  `#f2a93b` `lantern`, `#f7c16e` `lanternText`, `#7aa7ff` `running`, `#46c37b` `done`, `#f0625e`
  `failed`, white at 8% `bgSelected`, and a state at 12–13% its tint. MobileThread and
  MobileApproval use a few values off the palette (a `#22262a` rule, `#767c85` meta, `#6fd49a` and
  `#a9c6ff` status words, a `#c1c5cb` paperclip): they are `lineSubtle`, `textTertiary`, the state's
  `textColor` and `textSecondary`. MobileThread also draws its idle agent as done (a filled `done`
  dot and "Idle" in `#6fd49a`); that is not the rule: idle is the hollow `textTertiary` ring and
  its word in `textTertiary` (Status, below), as on the iPad.
- **Glyphs that need you are `lanternText`** on every phone list (Home's Needs you rows, Needs
  you's origin lines, Search's missions): only a status dot glows in `lantern`.
- **Components** for these screens (ShepherdUI): `NWListCard`, `NWListRow`, `NWListHeader`,
  `NWHostBadge`, `NWAttentionCard`, `NWHostCard`, `NWWrapStack` (Fleet); `NWCapsuleComposer`,
  `NWComposerActionButton`, `NWTouchCommandList`, `NWTouchQueueCard`, `NWTouchQueueRow`,
  `NWQuestionCard`, `NWQuestionOptionCard`, `NWSelectorChip` (Composer); `NWRunCard`,
  `NWRunHistoryList`, `NWRunGoal`, `NWRunQuestion`, `NWSteerField` (Agents);
  `NWReviewFileRow`, `NWTouchDiffLine`, `NWLineCommentBar`, `NWInlineComment`, `.nwReviewBar`
  (Review); `NWTouchSearchField`, `NWSearchResultRow` (Navigation); `NWChoiceRow`, `NWGroupCard`,
  `NWCardRow` (Containers); `NWAutomationRow`, `NWAutomationSwitch` (Automations). Their measures
  are `NWListMetrics`, `NWTouchComposerMetrics`, `NWTouchQueueMetrics`, `NWTouchQuestionMetrics`,
  `NWRunTouchMetrics`, `NWSelectorChipMetrics`, `NWChoiceRowMetrics` and `NWTouchDiffMetrics`; a
  screen's own measures are `MobileLayout` extensions in its folder.

## iPhone: Home (MobileAgents)

`Home/HomeScreen.swift`, derived once per change by `HomeFeed` (`FleetModel`). Every connected host
merges into one Home.

- **Header** (62pt from the top, 20pt sides, 12pt under): "Shepherd" as the large title, with Search
  (`magnifyingglass`) and New thread (`square.and.pencil`) trailing. New thread is disabled while
  there are no hosts. Pull to refresh retries every host.
- **Destinations card** first (no head): Missions, Designs, Automations, More, each a 48pt row with
  a 17pt glyph in `textSecondary` (a folded map, a diamond, a bolt, three dots), the title, a
  trailing count and a chevron. Automations counts every host's automations (left out at zero).
  More's trailing is the offline count in `failed` mono ("1 host offline") when any host is offline.
- **Not built yet:** the Missions row (count of missions) and the Designs row (count of designs)
  lead the card. They wait for Missions and the Design tool on the Mac.
- **Offline hosts** (the app's addition; the board only counts them on More): a card of notices, one
  per host that is not connected: its status dot (a spinner while connecting), the name (15/500),
  the reason in the state's text color ("Shepherd isn't running on MacBook Air, or it can't be
  reached."), and Retry (`.nw(.secondary, size: .s)`, `arrow.clockwise`). A refused token or another
  protocol says so and waits for Edit or Retry.
- **Needs you** (head in `lanternText` with its count): 52pt rows, each a glowing 8pt `lantern` dot
  for a thread, or the origin's 15pt glyph in `lanternText` (a bolt for an automation run); the thread's name, the question in `lanternText` mono 11 under it, and (the
  app's, with several hosts) its host badge. At
  most two rows (`HomeLimits.needsYou`), then a 44pt link row: "See all N" when more wait, else
  "Answer in Needs you". A row opens where the question is answered (the thread). The board shortens a plan's question to "approve plan" ("Dock review pane");
  to Shepherd a plan is an ordinary question (Principles: No permission model), so the row shows
  the question the asker wrote.
- **Not built yet:** a mission's stuck lane as a Needs you row (a folded-map glyph in
  `lanternText`, the mission's name, "orders is stuck after 3 tries" in `lanternText`), opening the
  mission.
- **Recents** (head in `textSecondary`): 52pt thread rows, newest first: the state dot (`running`
  while working, the hollow ring while idle), the title, and a mono status line: "running · git push
  origin main · 21s" (the live call and its ticking elapsed time) or "idle · 1h ago". The app adds
  the space's name ("idle · Shepherd · 1h ago"). A row on another host carries its host badge; with
  more than one host the app tags every row. At most six rows (`HomeLimits.recents`), then "Show all
  recents", which pushes `RecentsScreen`.
- **Not built yet:** a design in Recents (a diamond glyph in `textTertiary`, its name, "design · 4
  boards").
- **Empty states:** no hosts shows `NWEmptyState` "Add a host" ("Connect to a Mac running Shepherd
  to see its threads.") with a primary Add host; no threads shows "No threads yet" ("Start one on
  any host; it shows here with the host it runs on.") with New thread in the Recents card.

## iPhone: Thread (MobileThread, MobileApproval)

`Thread/ThreadScreen.swift`, `ThreadTurns.swift`, `Composer/ThreadComposer.swift`. The thread
follows the Mac's rules (Thread) with the phone's measures below.

- **Header:** the inline title with the agent's name over its status line: the status word
  ("Idle", "Running", "Needs you" with a glowing dot while pi asks, "Failed" in `failed` while the
  last reply ended in an error, MobileThreadError), then where the agent works:
  "· ⧉ pi/swiftui-previews" (a worktree's branch in mono `textTertiary`, truncating in the middle;
  MobileThread, MobileQueue) or "· ⌂ your checkout" in `lanternText` for the space's own checkout
  (MobileQuestion). The boards dropped the turn and context counts and the clock for it, and so
  does the app; the word stays whole. Trailing, the thread's
  options (•••: Refresh, Subagents while the thread has runs, Terminal, then Rename…, Move up and
  Move down, and Delete agent… or Delete worktree agent…) at rest; while the agent runs, Stop (a
  `failed` stop square, "Stop agent" to VoiceOver) takes its place. The app keeps ••• beside Stop,
  and keeps Stop while pi asks.
- **Column:** 20pt from the header, 16pt sides, 22pt between turns, 12pt between a turn's parts
  (`MobileLayout.turnItemSpacing`). The app pads the column 16pt at the top and spaces turns 24pt
  (`MobileLayout.turnSpacing`, `NW.Space.xxl`).
- **User bubble** (`NWUserBubble`): trailing, at most 300pt, `bgBubble` with a 1px `lineStrong`
  line, 8pt corners, 10×14 padding, 15/1.45 text; its time under it at rest in mono 11
  `textTertiary` ("2:41 PM"), 4pt below (touch has no hover). The later boards (MobileSteer,
  MobileQueue, MobileQueueMenu, MobileQuestion) round it at 12, start the column 14–16pt under the
  header and space turns 12–14pt; MobileThread's 8, 20 and 22 are the rule. The app caps the bubble
  at the Mac's 600pt (`NWThreadMetrics.bubbleMaxWidth`), so on a phone it can take the whole
  column (Known gaps).
- **Thinking** (`NWThinking`): "Thought for 4s" in italic 12 `textSecondary` behind a 12pt
  disclosure chevron, 32pt tall; it expands in place.
- **Prose** (`NWAgentProse`): 16/1.5 `textPrimary`, paragraphs 8pt apart.
- **Activity lines** (`NWActivityLine`): a finished line is a 36pt button (a 13pt glyph in
  `textTertiary`, the label in 14 `textSecondary`, the meta in mono 11 `textTertiary`, a 10pt
  chevron), 8pt between parts, 4pt between lines, one per burst of work; it expands its calls. The
  running line is 26pt (MobileApproval, LiveText): the tool's 13pt glyph, still, in
  `textSecondary`, the label ("Pushing") and the command (mono 11) shimmering, the elapsed seconds
  in mono 11 `textTertiary`, then the call's last three output lines in mono 11 at 1.6 line height,
  indented 21pt, the newest in `textSecondary` and the rest `textTertiary`. Nothing spins, and no
  "Working…" row sits under it; between tools the turn ends in "Thinking…", shimmering, as on the
  Mac (Thread › Live text), with no chevron.
- **"Edited N files" card** (`NWTurnChangesCard`, ChangesStates › ChangesCard): 1px
  `lineSubtle`, 12pt corners, on `bgWindow`. Its head (10×10×12 inset): a 36pt tile (`bgSunken`,
  a 1px `lineSubtle` line, radius 8) with the ± glyph in `textSecondary`; "Edited 2 files" (15/600)
  over its stat (mono 12, `done`/`failed`); then Undo (a 36pt ghost with its ↶ glyph, 13.5/500
  `textSecondary`) and Review (secondary, 28pt, its hit area 44pt). Then 40pt rows with hairlines:
  the path at 14 with its folder in `textTertiary` and the name in `textPrimary`, "new" (12
  `textTertiary`) before a created file's stat, the stat in mono 12; three files, then "2 more",
  which opens the review too. A row opens the review at that file. Review opens the review
  scoped to that turn; Undo puts back the turn's edits in the working tree (the host's engine,
  docs/changes.md) with no dialog, and the card becomes one dashed line, "↶ Undid the agent's
  edits to 5 files" with Redo, until the next turn starts. A refusal (a file changed since)
  names the files in an alert. The card comes from the host's record of the turn
  (`turnChanges`); an older host's comes from the turn's edit calls, with no Undo. At the
  accessibility sizes the head stacks and paths take two lines.
- **Turn footer** (`NWTurnFooter`): at rest, mono 11 `textTertiary`: "2:44 PM · 3m 12s"; the app
  adds the tool-call count, Copy and Retry (the latest turn only; Thread › Retry), and "n subagents"
  when the turn spawned runs.
- **Composer:** a 1px `lineSubtle` rule, `bgWindow`, 10pt above, 12pt sides, 30pt below. A 44pt
  paperclip (Attach, `textSecondary`; shown only when the host takes images) beside the capsule
  (`NWCapsuleComposer`): at least 44pt, fully rounded, `bgRaised`, 1px `lineStrong` (`textTertiary`
  while focused), 16pt leading and 6pt trailing padding, the field at 16 (`.body`) growing to a few
  lines, and Send inside it: a 32pt `lantern` circle with a `textOnLantern` up arrow, at 35% while
  there is nothing to send. The placeholder is "Follow up…", and "Queue a follow-up…" while pi
  works (MobileApproval), which the app follows, since Send queues while pi works. The later
  queue boards (MobileSteer, MobileQueueMenu) keep "Follow up…" while pi works and draw the
  capsule the composer's full width with no paperclip, and 34pt under it; settle which rules
  before changing either. Holding Send while pi works offers Queue and Steer now. The context
  ring sits inside the capsule just before Send (Composer › Context meter › iPad and iPhone); a
  tap opens its details as a sheet. The app adds,
  while the field is in use, a row of "/ commands", model and thinking chips above it (ghost,
  28pt), and the speed chip after them where the host offers one (a menu of Standard and Fast,
  each with its line; no phone board draws any of it).
- **Following:** as in the iOS list above: only a finger's drag detaches; "↓ Jump to latest" sits
  8pt above the composer.
- **Banners** at the top of the thread, 12 `textTertiary`: "<host> is offline · showing the last
  known thread", "This agent is no longer on <host>.", "Update Shepherd on <host> to open threads
  here.", then one line for each thing the host reported shortening (Thread › Notices: what was left out and when it
  returns, nothing for older history or a long message). A pi that can't start on the
  host (Thread › Can't start) reads as its banner's title and advice on one line ("pi can't reach
  a model. Sign in to a provider for Shepherd's pi (Settings ▸ Pi), then Retry on <host>."), with
  no spinner, Send disabled,
  and "Can't start" in `failed` as the title's status.

## iPhone: New thread and Where it runs (MobileNewThread, MobileWorkspace)

`NewThread/`: presented as a sheet from Home's New thread.

- **Header:** Cancel (16 `running`) leading and "New thread" (16/600) centered, over a `lineSubtle`
  rule; nothing trailing (Start lives beside the chips).
- **Prompt:** the field takes the top, 18pt from the header with 16pt sides, in Geist 18 at 1.45
  line height (`MobileLayout.newThreadPromptSize`), focused on open with the keyboard up and a 2pt
  `lantern` caret. Placeholder: "What should the agent do?".
- **Chips** (`NWSelectorChip`, 8pt apart, wrapping): 32pt capsules on `bgRaised` with a 1px
  `lineStrong` line, 10pt sides: a 13pt `textSecondary` glyph, the value at 13 (mono for repo, host
  and model; Geist for thinking), and a 10pt `textTertiary` down chevron. Repo (a book: "shepherd"),
  Host (a display: the host's name), Model (a sparkle: the model without its provider,
  "claude-opus"), Thinking (a bulb: "Medium"; only for a model that takes a level). A chip wears a
  `lanternText` line while its picker is open. On iPhone Repo and Host open Where it runs, Model
  opens the host's model list as a sheet, and Thinking is a menu.
- **The row under the chips:** Attach (a 36pt circle, paperclip), "New worktree on `shepherd`" (12.5
  `textTertiary`, the repo in mono; "In shepherd's checkout" with the switch off), which opens Where
  it runs at its worktree card, and Start trailing: a 32pt `lantern` circle with an up arrow (a
  spinner while starting; dimmed while something blocks it, with the reason as its hint and a
  caption under the row).
- **Not built yet:** under that row, a card (1px `lineSubtle`, 10pt corners, 10×12 padding, 13
  `textSecondary`): a folded-map glyph, "Touches more than one repo?", and "Start a mission" (500
  `running`) trailing, which hands the prompt to a new mission. It waits for Missions.
- **Where it runs** (MobileWorkspace): a sheet 700pt tall over the form, "Where it runs" with Done.
  Two heads, Repo and Host, each over a `bgRaised` card of 56pt `NWChoiceRow`s (20pt leading column,
  the name in mono 15/600 over a 12.5 `textTertiary` detail, a 17pt `running` checkmark on the
  chosen one):
  - Repo: the chosen host's spaces with a book glyph and "main · ~/code/shepherd" (the checkout's
    branch, then its path), then other connected hosts' spaces with "main · on build-01"; choosing
    one moves the thread to that host. The app adds a last row, "Add repo…" ("a folder on <host>", a
    `running` plus), which browses the host's folders. The app shows the path alone, without the
    branch.
  - Host: an 8pt status dot and "connected · 2 threads running" ("connected", "connecting…"); an
    unreachable host is dimmed to 50% with "unreachable · last seen 07:12" and Retry (14 `running`)
    trailing. The app shows the failure's headline, then when this device last had it connected
    ("unreachable · last seen 7:12 AM"; `HostLastSeen`, kept on the device per host).
  - **Not built yet:** a daemon host ("build-01 · Linux daemon · 2 missions running"). Hosts are
    Macs running Shepherd until the Mac has daemon hosts.
  - Last, a card with "New worktree" (15/500) over "Keeps main clean. Merge it from Review." (12.5
    `textTertiary`, naming the base's branch) and its switch, on by default. With it on the app adds
    Branch and Base fields (the base as the host resolved it) and Fetch origin first.
- **States:** an older host says what it lacks ("Update Shepherd on <host> to start threads in a new
  worktree."); a failed start shows a `failed` `NWBanner` "Couldn't start the thread" with Try again
  or Resolve. Images and the prompt go in the same creation request; a host without image
  creation support, or an image exceeding the encoded frame limit, leaves the form intact.
  A completed start opens its thread only if its original sheet is still presented; cancelling
  or replacing that sheet leaves the created thread in Recents without changing the current screen.

## iPhone: Up next and questions

MobileSteer, MobileQueue, MobileQueueMenu, MobileQuestion; `Composer/QueueSection.swift`,
`Composer/QuestionPanel.swift`. The queue's rules are the Mac's (Up next); only its touch form
differs. Send queues the message while pi works (it goes when the turn ends), and holding it
offers the Mac's two choices (`NativeSendChoice`): Wait for the turn to end and Steer now, which
stops pi and sends at once where the host can (`native.interrupt.v1`) and steers where it cannot
(the only time a Steering row shows). There is no Return setting on iOS, and no steering at the
next step. Steer now on a row and Steer all now are the same interrupt.

- **Header while it runs:** as at rest (iPhone: Thread › Header), "Running · ⧉
  agent/native-restyle" (MobileSteer, MobileQueue), with Stop trailing; the phone's header shows
  no clock (the iPad's pill does).
- **Up next** (`NWTouchQueueCard`) sits above the capsule, 8pt apart: `bgRaised`, a 1px `lineStrong`
  line, 14pt corners. Its 38pt head (14pt leading, 4pt trailing): the queue glyph (13pt
  `textTertiary`), "Up next" (13/600 `textSecondary`), the count (mono 11.5 `textTertiary`), and •••
  (a 34pt circle: Steer all now or Send all now, "When the turn ends, send" with the delivery modes,
  Clear the queue). The rows scroll inside past three and a half (`MobileLayout.queueRowsMaxHeight`,
  at most `queueShare` of the composer's room).
- **Steering row** (only where Steer now falls back to a steer, as on the Mac), first, until pi takes it: 58pt on `runningTint`, the still 15pt `running` steer
  glyph (MobileQueue; nothing spins), the
  message at 15 on one line, "↳ Steering" (12/500 `running`, an 11pt glyph) under it, and Back to
  the queue (a 34pt button, a 16pt `textSecondary` return arrow) trailing, hit at 44pt.
- **Queued rows:** 48pt on `bgRaised` with a `lineSubtle` rule above: the number in a 22pt
  `lineStrong` ring (mono 11.5 `textSecondary`), then the message at 15 on one line. The app lets it
  wrap to two, and shows an image count and "Being edited" while an editor elsewhere holds it.
  **The first queued row while pi works also wears Steer now as a button** (decided by the user,
  2026-10-01; no board draws it): `.nw(.secondary, size: .s)`, `arrow.turn.down.right` and "Steer
  now", after the message and its image count, hit at 44pt, so touch, which has no hover, sees
  what the Mac shows at rest. Its swipe actions and long-press menu (which keeps Steer now) are
  unchanged, and an idle queue draws no button (the header's Send now is its action).
- **Swipe** a queued row left (MobileQueue): two 75pt actions slide in, Edit (`bgSelected`,
  `textPrimary`, a pencil over 12/500) and Delete (`failed`, white); a full swipe deletes. The app
  uses the system swipe actions.
- **Touch and hold** a queued row (MobileQueueMenu): the screen blurs under black at 45%, the row
  lifts at 52pt with 14pt corners, and a 250pt menu (`bgRaised`, 14pt corners, a `lineStrong` ring,
  the popover shadow) lists 44pt rows at 16 with their 18pt glyphs trailing: Steer now (Send now
  while pi is idle), Edit, Move to top (not on the first row), then after an 8pt `bgSunken` gap,
  Delete in `failed`. The app uses the system context menu with the same items; they are also
  VoiceOver actions.
- **Edit** opens a sheet ("Queued n", Cancel and Save) while the host holds the message; Delete
  leaves an Undo row in its place ("Deleted ~~text~~", Undo); clearing leaves "Cleared n messages".
- **Paused:** as in the iOS list above (Send now in the head).
- **Question** (MobileQuestion; `NWQuestionCard`, docked): the panel takes the composer's place,
  full width, docked to the bottom: `bgRaised`, 18pt top corners, a 1px `lantern` line along its
  top, the thread's content shadowed under its edge, 12pt top, 14pt sides, 34pt bottom, 10pt between
  parts. A 36×5 `lineStrong` grabber, then a 26pt head: a 13pt question glyph and "Agent is asking"
  (13/600 `lanternText`; "1 / N" in mono when several wait). The question at 18/600, 1.3 line
  height; the asker's message, if any, as code on `bgSunken`. The options: 6pt apart, each a card on
  `bgWindow` with a 1px `lineSubtle` line and 8pt corners, 11×12 padding: a 24pt number in a
  5pt-cornered `lineStrong` square (mono 11 `textSecondary`), then "Recommended" (a 20pt
  `lanternTint` chip, 11/600 `lanternText`) when the asker marked it, the title (15/600, 1.35) and
  its detail (14/1.45 `textSecondary`). Tapping one selects it (the number fills); Answer, a
  full-width 48pt `lantern` button with 12pt corners at 16/600 (`.nwReviewBar(.primary)`), stays
  at 40% until one is chosen. The panel follows the question dock's rules (Composer, questions,
  and menus › Questions; `QuestionPanel` on `NativeQuestionPrompt`, as the Mac's dock): Answer is
  the only button, and picking another option moves the pick. A yes or a no (pi's confirm, or two
  short options) is two cards side by side that answer on a tap; an open question (pi's input or
  editor) is a field over Answer. The grabber is Hide the question: a tap,
  or a drag down from it, folds the panel to one line (`NWQuestionCardHiddenLine`, the iPad's),
  which never answers it; Answer or Show the question on that line opens it again, and the next
  question arrives open.
- **What each asker takes** is the dock's table: pi's select takes only one of its options, so it
  gets no note and no Something else… (the components that drew them, which only a subagent's
  question used, were pruned: a subagent asks its parent). pi's question has no
  Dismiss: **Stop** refuses it.
- **While pi asks** the header shows "Needs you" with a glowing dot and no Stop or •••. The app
  keeps both: Stop is how a question is refused (the host cancels the questions pi waits on, then
  stops the turn), as on the Mac.
- **Not built yet:** "Something else…" for pi's own select (MobileQuestion draws it): pi's select
  takes only an offered option, so it waits for the picker block's `allowOther`.
- **After:** the thread keeps the record where pi asked (Composer, questions, and menus ›
  Questions › The record), on iPhone and iPad alike, its time showing at rest (touch has no
  hover).

## iPhone: Subagents (MobileSteer, MobileSubagents, MobileSubagent)

`Subagents/`. The runs are the Mac's (Subagents): a tray above the composer, the thread's two
record lines, a list, and a screen per run.

- **The tray** (MobileSteer, SubagentTray › iPhone; `SubagentTraySection`, `NWSubagentTray` at
  `.phone` size): the Mac's tray at touch sizes, in one card with Up next above the composer
  (`bgRaised`, a 1px `lineStrong` line, radius 12). A 38pt header (14pt leading, a 13pt glyph,
  "3 subagents" at 13/600, the cells and tally, Collapse as a 34pt circle); 44pt rows (14pt
  leading, 10pt apart): the state in a 14pt slot, the name in mono 13.5/600 in a 68pt column,
  what it is doing at 14 (the subject in mono 13), its time in mono 11, and a chevron in a 34pt
  slot; the diff stat drops. A run that asked its parent says "asked the parent: …" quietly, with no
  Answer. Tapping a row pushes its run's screen; touch and hold for Open and the run's controls. Past
  four runs, "Show N more"; open, the rows scroll inside, never more than a share of the
  composer's room. The tray's rules (when it shows, the order, what each state says) are the
  Mac's.
- **In the thread** (MobileSteer): "Started 3 subagents · worker · reviewer · tests" where the
  turn spawned them (32pt, 14), and "3 subagents finished · 45m · 7 files · +318 −64" once they
  have; both, and the footer's "3 subagents", open the runs list.
- **The runs list** (MobileSubagents; `SubagentListScreen`): "Subagents" over "1 running · 1 waiting
  on parent" in the state's color, on `bgBase` with 14pt padding. "This turn" with its count heads the
  live runs as cards (`NWRunCard`; 12×14 padding, 8pt inside):
  - Head: the branch glyph in the state's color, the name (mono 15/600), its tags ("background ·
    fable-5-1", 12 `textTertiary`), and a 20pt pill trailing (the state's tint and a 6pt dot: "37m"
    running, "Waiting on parent · 2m", "4m 02s" done).
  - Running: "step 1 of 3" (mono 12), a 4pt progress bar (`lineSubtle` track, `running` fill, 2pt
    corners), the tokens ("922k", mono), then the current call in mono 12 `textSecondary` on one
    line.
  - Asked the parent (a quiet card, a `lineSubtle` line): the question at 14/1.45 with inline code
    (mono 12 on `bgSunken`, a `lineSubtle` line, 4pt corners), then "It offered: …" in caption
    `textTertiary`. It is to read: nothing on the card answers it.
  - Done: its result at 14 and its diff stat.
  - "Earlier in this thread" with "kept after they finish" heads the finished runs as one card of
    56pt rows: a `done` check, the name (mono 15/500) over "summary · 1h ago" (12.5 `textTertiary`),
    the stat, a chevron.
- **One run** (MobileSubagent; `SubagentRunScreen`): the name over "Running · 37m", and ••• (Pause
  or Continue, Stop, Re-run, Copy Transcript) trailing. On `bgWindow`, 16pt padding, 12pt apart:
  - The goal (`NWRunGoal`): `bgSunken`, 1px `lineSubtle`, 12pt corners, 12×14 padding: "GOAL · FROM
    THE PARENT" (`.nwSectionLabel()`), then the goal at 14/1.45. The app adds "step 1 of 3 · 34%".
  - Its transcript: prose at 15/1.5, activity lines 32pt tall at 14; the running call live with its
    verb ("Building") and command shimmering and its elapsed seconds, as in the thread; nothing
    shows between calls (LiveText's "Thinking…" is the thread's alone). The app draws the live
    call without the board's output tail: the child's session holds no streamed output (Where
    Shepherd departs from the boards).
  - Its question, while it waits on its parent, on `bgSunken`, with the answers it offered, to read.
  - The steer field (`NWSteerField`) at the bottom: a 44pt capsule, "Steer worker…", Send inside it,
    and under it "to: worker · not the parent · lands before its next turn" (mono 11 `textTertiary`,
    8pt sides). Only while the run takes a steer; a finished run shows Re-run and Copy transcript
    instead.

## iPhone: Review (MobileChanges, MobileDiff, MobileCommit)

`Review/ChangesScreen.swift`, `DiffScreen.swift`, `ScopeMenu.swift`, `Commit/CommitScreen.swift`.
The review is the Mac's Changes pane (Side pane › Changes) on a host with `changes.v1`; Commit…
follows the Commit from review rule above.

- **Changes** (MobileChanges), pushed from the card: "Changes" (17/600) over the scope in
  `running` (12/500): a glyph for the scope, "Branch · vs main", a chevron. It opens the scope
  menu (ChangesStates › ScopeMenu): Last turn ("What the agent changed since your last message"),
  then Uncommitted, Unstaged, Staged, then Commits (a submenu: all commits on the branch, then
  each with its short id and age), Branch (this branch against its base, and Compare against…,
  the base picker) and Pull request ("#31 draft"), each with its diffstat; a scope the host can't
  compare says why and is off. ••• trailing: Refresh, Discard comments, Ask agent to commit,
  Finalize worktree…. A card's Review opens on that turn; a review opens on the host's default
  (Branch for a worktree agent, else Uncommitted), and after Send on Last turn. On `bgBase`, 14pt
  padding, 10pt apart:
  - The summary card (14pt padding): "3 files" (17/600) and the stat (mono 11), then the branch
    trailing (a branch glyph and "agent/pay-button-jump", mono 12 `textSecondary`); under it a
    4pt bar (`done` fill on `lineSubtle`) and "1 of 3 viewed" (12.5 `textTertiary`). The app adds
    Finalize worktree ("commit · push · PR") to the card for a worktree agent.
  - "Files" with "tap to read the diff", then one card of 58pt rows (`NWReviewFileRow`): the viewed
    mark (a `done` check, or a 14pt ring in `lineStrong`), the status letter (mono 12: M `lantern`,
    A `done`), the name (mono 14/600) over its directory (mono 11 `textTertiary`), the comment count
    (a bubble glyph and "1", 12 `running`), the stat, a chevron. A row pushes its diff. The list
    comes from the host first; a file's lines come when it is read.
  - "Your comments" with the count, then a card per comment: an 18pt circle with the author's
    initial (10/600), "FleetView.swift · line 33" (mono 12 `textTertiary`), the time, and the
    text at 14/1.45. The app labels the author "You" and adds Edit and Delete. There is no overall
    comment: anything else is said in the thread.
  - The bottom bar: Send 1 comment (secondary; "Send 3 comments", off with none) and Commit…
    (primary), 48pt each, sharing the width.
- **Base picker** (ChangesStates › BasePicker), a sheet from Compare against…: "Search branches",
  then "Compare against": the default base first ("default"), recents, then every other branch
  by its last commit, a branch checked out in another worktree tagged "worktree", the current
  base checked; then The PR's base. Rows 44pt: a branch glyph, the name in mono 13, the tag in
  mono 12 `textTertiary`. The board's "A commit…" is not offered (Known gaps).
- **Diff** (MobileDiff): the file name over "App/iOS · 2 of 3 · +9 −7" (mono 11.5), and Next file (a
  34pt button, a down chevron) trailing; the app adds Mark viewed. On `bgWindow`:
  - The hunk head in mono 11 `textTertiary` on `runningTint`, 6×12 padding.
  - Lines (`NWTouchDiffLine`) at least 22pt (`NW.Height.rowCompact`), wrapped, mono 12 at 1.55: a
    32pt number column (10.5 `textTertiary`, right-aligned, 6pt after), a 14pt sign column (`failed`
    −, `done` +), the code with syntax colors; removed lines on `failedTint`, added on `doneTint`,
    and a changed word of a paired line on its tint again (`DiffWords`).
  - Long runs fold into a 26pt row on `bgSunken` indented 46pt: a chevron and "13 more removed
    lines" (mono 11 `textTertiary`); a tap shows them.
  - A comment sits under its line: 6pt above and below, 12pt trailing, indented 46pt; `bgRaised`,
    1px `lineStrong`, 10pt corners, 10×12 padding: the initial, "You · just now", and the text at
    14.
  - A tap selects a line: `runningTint` with a 3pt `running` bar at its leading edge. The bottom bar
    then shows "line 16 selected · Suggest a change" (12 `textTertiary`; the line in mono `running`)
    over a 44pt capsule "Comment on line 16…" with Send. The app adds Done, which clears the
    selection.
  - A file the host cut short (20,000 lines, or the remote frame's size) says so under its lines.
  - **Not built yet:** "Suggest a change" (`running`, after "selected ·"): it turns the comment into
    a suggested replacement for the selected line, prefilled with the line's text, sent with the
    review as a suggestion the agent applies. Neither the phone nor the Mac has it.
- **Commit** (MobileCommit): a sheet 760pt tall over Changes: Cancel and "Commit" (the app: "Commit
  n files"). 16pt padding, 10pt apart:
  - "Message", then a card with a `lineStrong` line (12×14): the subject (16/600), the body (14/1.5
    `textSecondary`), and "Drafted from the diff · edit anything" (12 `textTertiary`, a sparkle
    glyph). The message follows the Mac's rules (Commit… sheet; `ReviewCommitStore`): "Written
    from the file list · edit anything" until a draft arrives, "Drafting from the diff…" with a
    spinner, redrafted for the ticked files while nobody has edited it ("Redrafting the
    message…"), and "May mention files you unticked" once an edited one outlives a tick.
  - "Files" with "3 of 3" (mono), then 44pt rows: a 14pt checkbox (`lantern`, 4pt corners, a
    `textOnLantern` check), the name (mono 13), the stat.
  - The options card: 52pt rows with switches: "Push after commit" over the upstream ("origin/main",
    mono 12 `textTertiary`), on; "Open a pull request instead" over "pushes a branch and opens the
    PR", off.
  - A full-width 48pt Commit & push (primary) at the bottom. The app adds Ask agent to commit as a
    link under it, and the host's steps once it runs.
- **Older hosts** (without `changes.v1`): the same screens show the working tree against HEAD, or
  the PR, from one diff; the title's menu offers those two, and Commit sends the agent a turn
  where the host doesn't commit from review.
