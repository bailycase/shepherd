# iPad: other screens and Automations

> Read when you change the iPad's overview, Needs you, hosts, palette, Split View, settings or side pane, or Automations on iOS.

## Overview (iPadOverview)

With no thread selected the detail is the Overview (`PadOverview`).

- **Header:** "Overview" (the board's 17/600) with the summary beside it at 12.5
  `textTertiary` ("4 need you · 6 running · 3 hosts"), leading the bar; Search and New thread
  trailing (40pt circles, 18pt `textSecondary` glyphs).
- **Columns:** Needs you, Running now and Finished side by side (16pt inset, 16pt apart; the app
  12pt), each headed by its name and count (mono 11/500, uppercase, tracked 5%; Needs you in
  `lanternText`, the others `textTertiary`). They stack when three 256pt columns don't fit, and
  at accessibility sizes. Pull to refresh retries the hosts. An empty column shows a quiet card
  ("Nothing is waiting on you.", "Nothing is running.", "Nothing has finished yet."); with no
  hosts the detail is the no-hosts state.
- **Needs you cards** (`NWAttentionCard`): `bgRaised`, a 1px `lineSubtle` line, radius 12, 10×12
  inset, 8pt apart. The origin line: a 14pt `lanternText` glyph (a glowing 8pt `lantern` dot for
  a blocked thread), its kind at 12 `textTertiary` ("Thread", "Automation"), its age
  trailing; the title at 14.5/600 (the thread's name); the question
  at 13/1.4 `textSecondary`; then the answers as 28pt buttons at radius 6, 12.5: the first
  primary, the rest secondary. The asker's short options (up to three, each up to 32
  characters), or Yes and No, answer in place; anything else shows Open.
  - The board answers a subagent here ("Replace all", "Rename new"); the app draws no subagent
    card: a subagent asks its parent, never you.
  - **Not built yet:** a mission's card ("Mission · now", "Retry with hint", Open).
  - The board's "Approve plan" and "Read" are the answers a plan-approval question would offer.
    Shepherd shows them only when the asker offers them (Principles: no permission model); a
    blocked thread with no question shows "Waiting on you" and Open.
- **Running now:** one card per kind (`bgRaised`, a 1px `lineSubtle` line, radius 12), each
  opening with a caption band on `bgSunken` (mono 10.5, tracked 5%, `textTertiary`, 8×12 inset):
  "THREADS · 3", "AUTOMATIONS · 1". Rows (10×12 inset, hairlines between): the state glyph in a
  16pt column, the title at 14/500, its clock in mono 11 `textTertiary` ("4:12", "37m"), and
  under it, in mono 11.5 `textTertiary`, what it does now: the running command ("swift test
  --filter toolPreview"), its subagents ("3 subagents · 1 waiting on parent"), or its command and host
  ("swift build · This Mac"): `NWCaptionBand`, `NWOverviewRow` and `FleetThreadRow.now`; the
  subagents are the ones still going, an asking one included. The glyph is the running spinner
  (`NWListRow.Leading.glyph`), the branch in `running` while its subagents work, or the state's
  dot while it waits on you (`RunningGlyph`). A running automation's row is `AutomationRow` ("Running · 4m"; the board's
  "waiting for CI · 3 of 5 checks" needs triggers the host doesn't have). **Not built yet:**
  "MISSIONS · 2", with each mission's lanes as a 150×14 strip.
- **Finished:** one card under a "TODAY" caption band. Rows at least 52pt (6×12 inset): the outcome
  glyph (14; `done` check, `failed` cross), the title at 14/500 over its outcome at 12
  `textTertiary` ("PR #34 merged · 2h41", "3 migrations, all reversible", "1 PR failed CI"), and the
  time of day in mono 11 `textTertiary` ("11:02"; the weekday, "Mon", for an older one). The app
  lists finished threads newest first in that one card, under a band per day ("Today",
  "Yesterday", a weekday, a date; `FleetFinishedDay`), each with the check, or the `failed` cross and "failed · host" for a
  last turn that failed, "done · <folder>" otherwise, and its time; the host sends no outcome
  ("PR #34 merged"), and finished automation runs stay under Automations. **Not built yet:** a
  design's row ("4 boards · 1 comment resolved").

## Needs you (iPadInbox)

The sidebar's Needs you head opens the list beside the chosen item's detail, one at a time with
its full context.

- **List:** 380pt wide on the board (the app 360), a 1px `lineSubtle` trailing edge. Its header:
  "Needs you" (17/600) with "5 waiting" at 12.5 `textTertiary` (the app puts "3 things are
  waiting on you" at the list's top). Items (10pt inset, 2pt apart; `NWAttentionCard(style:
  .item)`: no line, the app's radius 8): 12pt inset at radius 10, the chosen one on `bgSelected`: the origin line (a 14pt `lanternText` glyph or a glowing 8pt dot,
  "Thread" at 12 `textTertiary`, the age trailing), the title at 15/600
  (the thread's name), the question at 13/1.4 `textSecondary`.
- **Detail header:** the title (17/600) and the pill with its age ("Needs you · 2m"); **not built
  yet:** a ••• menu (40pt) trailing (the board does not show its items).
- **Detail** (16×20 inset, 14pt apart): the question at 17/1.5, selectable, inline code in mono
  12 on `bgSunken`. The asker's longer message in mono on `bgSunken` (a 1px `lineSubtle` line,
  radius 8, 12×14 inset, 12/1.65). "Answer this one in the thread." under a question that needs typing;
  "Open the thread to see what it is waiting for." under a blocked thread.
- **Not built yet: structured context and trade-offs.** The board's code block names each file
  with its use count in `textTertiary` ("Sources/ShepherdApp/Tokens.swift · 41 uses",
  "…DesignTokens.swift · new, from the spec"). Its answers are cards (`bgRaised`, radius 12,
  12×14 inset): the title at 15/600, the asker's pick outlined in `lanternText` with a
  "reviewer's pick" tag (mono 9.5 `lanternText` in a 16pt box with a 1px `lanternText` line,
  radius 4), and trade-offs as "· " lines at 13.5/1.45 `textSecondary`.
- **Where it came from** ("WHERE IT CAME FROM"): 34pt lines with a 14pt `textTertiary` glyph, the
  source at 14.5 `textSecondary` and its meta in mono 11.5 `textTertiary`: "reviewer · Restyle
  native UI · async · opus · 2m ago"; "Parent thread is waiting · worker keeps going". The app
  shows one row (the thread, "A thread" or "A run of the automation <name>", its age ("· 2m ago")
  and the host tag); the mode, model and the parent's state are **not built yet**.
- **Foot** (a hairline above, 12×20 inset, 26 under, 36pt buttons, trailing): Open thread
  (ghost; primary when Open is all there is), then the answers as
  secondary buttons with the asker's pick last, primary ("Rename new ones", then "Replace
  everywhere").
- **Not built yet:** mission items ("Mission · planner").
- Empty: "Nothing needs you", "Questions and blocked threads from every host show here."

## Hosts and More (iPadHosts)

Settings ▸ Hosts shows host cards (`NWHostCard`, in columns at least 320pt wide): the name, the
address and port, the connection word, what runs there ("2 threads running · Shepherd"), Retry
while it is offline, and a refusal's reason, with Add host (secondary) under them and "Trusted
LAN or VPN only: the connection has no TLS." A card opens the host's form (Name, Address, Port,
Token, kept in the Keychain; Forget host). A compact window's More (the phone's) shows the same
cards.

**The Hosts destination** (iPadHosts, `PadHostsScreen`), from More's Hosts sub-row:

- **List** (320pt, `MobileLayout.hostsListWidth`, a 1px `lineSubtle` trailing edge): "Hosts" in
  the bar with Add host (+); rows at least 64pt (`NWHostRow`), 8×12 inset, radius 10 (the app's
  8), the chosen one on `bgSelected`: a 16pt `textSecondary` glyph, the name in mono semibold,
  what it carries at 12 `textTertiary` ("3 threads · 2 running"; "Offline · last seen 7:12 AM"
  once it drops, as this device last saw it), and an 8pt status dot trailing (`done`, `failed`).
  Under the rows, "Hosts connect over your LAN or VPN. The connection has no TLS." A row's
  context menu has Retry (while offline) and Edit Host…; pull to refresh retries the hosts.
- **Detail header:** the name (17/600), "● Connected" at 13 in the connection's color with an
  8pt dot, and the address at 12.5 `textTertiary`; a ••• menu trailing (Retry while offline,
  Edit Host…). **Not built yet:** the host's kind ("app", needs the remote protocol to say it).
- **Detail as built:** "RUNNING HERE · 3" with "threads and automations" at 12 `textTertiary`,
  then a card of the threads and automation runs going on the host now (`NWOverviewRow`s: the
  state, the title, what it does now and its clock), each opening its thread; or "Nothing is
  running here." While the host is offline, why (its failure, in `failed`), "Last seen …" and
  Retry.
- **Not built yet, the rest of the detail** (16×20 inset, two columns 12pt apart):
  - CPU and Memory cards (`bgRaised`, a 1px `lineSubtle` line, radius 12, 10×12 inset): the
    label at 12 `textTertiary`, the value at 18/600 ("44%"), its scale at 12 `textTertiary`
    ("16 cores", "of 64 GB"), and a 56pt history line.
  - The board's running rows' stations, repos and tokens used ("612k", "—").
  - A Worktrees card ("14 · 22 GB" at 15/600, "6 older than 7 days"), a version card (the
    host's Shepherd and pi versions and uptime; the board's "shepherd-d 0.4.2 · up 6 days · agent
    0.87.1"), and "LOG": the host's recent events in mono 11/1.6 `textSecondary` on `bgSunken`
    (a 1px `lineSubtle` line, radius 8, 10×12 inset), each line led by its time.
- The remote protocol carries none of this yet: no load, no token counts, no worktree inventory,
  no versions (`helloOk` has the protocol version and capabilities only), and no log.
- The board's daemon hosts ("Linux daemon", "macOS daemon", stations, missions) wait for a
  daemon; Shepherd has none.
- The board's **Clean worktrees** (secondary, in the header) would remove worktrees, which
  Shepherd never does on its own (docs/rules.md › Only these paths mutate repositories). It needs
  that rule changed before it is built.
- More's Extensions sub-row opens Settings ▸ Extensions (the host's bundled extensions, as
  Settings ▸ Pi shows them on the Mac). **Not built yet:** More's Design systems and Archive.

## Command palette (iPadPalette)

⌘K (or the sidebar's Search) presents the palette over the window, dimmed behind it
(`SearchPalette`): 820×560 (the system narrows it in a smaller window), radius 16, `bgRaised`.

- **Field** (56pt, 16pt inset, a hairline under it): a 17pt `textTertiary` magnifier, the query
  at 18 ("Search threads and actions"), a `lantern` caret, and the esc keycap (18pt, mono 10.5,
  a 1px `lineStrong` line at radius 4), which closes it.
- **Results** (a 420pt column, a 1px `lineSubtle` trailing edge, 6pt inset): section heads in
  mono 10.5 tracked 5% `textTertiary` (10×12 inset, 4 under); rows at least 48pt, 12pt inset,
  radius 8, 10pt gap: a 15pt glyph, the title at 14.5 with the match in `lanternText` semibold,
  and a line under it at 12 `textTertiary` (the state and what it waits on, what it is, or a
  quoted snippet with the match marked). The selection is `runningTint`. An action row ends in
  its chord as keycaps (the board's New mission: ⇧ ⌘ M).
- **Sections:** the board shows MISSIONS, DESIGNS, IN CONVERSATIONS (a match inside a thread
  or a subagent's run: "Checkout funnel events · validator") and ACTIONS. The app shows
  threads first, then In conversations (with host tags), then actions for the thread on screen
  (Rename…, Move up, Move down, Delete agent…) and its own (New thread, Settings), with no
  chords yet; the selected row shows the ↩ keycap.
- **Keys:** ↑ and ↓ move the selection, ↩ opens, esc closes; a tap opens a row at once, and the
  pointer moves the selection.
- **Preview** (14pt inset, 10pt apart): the glyph and title at 16/600; the pill and its stats in
  mono 11.5 `textTertiary`; a 300pt panel (`bgWindow`, a 1px `lineSubtle` line, radius 8);
  what it waits on at 13/1.45 `textSecondary`; then Open (primary, 36pt) and Open in new window
  (secondary). For a thread the app fills the panel with the latest of the thread, kept live
  while selected, and adds the ↩ keycap to Open; for an action it shows what the action does.
- **Not built yet:** the MISSIONS and DESIGNS sections, a match inside a subagent's run, the
  New mission action ("“funnel” as the goal", ⇧⌘M), and a mission's preview (its map, lanes
  and budget: "4 lanes · 3.1M of 6M · 1h38").

## Split View (iPadSplitView)

Two Shepherd windows side by side (see iOS › Windows). A narrow window keeps the thread's
layout: the sidebar toggle, the name and pill ("Running", without the clock), the header's
Subagents and Review buttons, and the live group card with shorter details ("restyling
ThreadView", "needs you", "14 pass").

**Not built yet: a Design beside the thread.** The board's right window is a design with the
design agent's note floating over it; Design tool › On iPad specifies it.

## Settings (iPadSettingsInstructions)

Settings is a list beside the page: a 300pt column (a 1px `lineSubtle` trailing edge) headed
"Settings"; rows at least 48pt, 12pt inset and gap, radius 10: a 17pt `textSecondary` glyph and
the label at 15/500; the open page's row on `bgSelected`, its glyph `textPrimary` and label
semibold. Pages: Appearance, Agents, Worktrees, Pi, Instructions, Skills, Notifications, Hosts,
Keyboard, Experiments. Agents, Worktrees, Pi and Keyboard are the host's settings, as the Mac shows them.

- **In the app** (`SettingsScreen` at regular width; a compact window gets the phone's list): the
  list is Appearance, Agents, Worktrees, Pi, Instructions, Skills, Hosts and Experiments, 10pt in from its
  edges with rows 2pt apart, and "Shepherd 0.1.0 · agent 0.87.1" under them ("pi 0.87.1" while
  the Pi page is open, as on the Mac). Beside it is the phone's own page (Agents is Defaults, Pi is
  Extensions) with its title in the bar, which says no
  "Settings" of its own. A page that opens another (Experiments' Open Instructions) switches the
  list in place.
- **Not built yet:** Keyboard (the host's chords) and Notifications (it waits for push).

**Instructions** (editing the instructions pi reads on every host; the Mac's page is Settings ›
Instructions, SettingsInstructions; `Settings/InstructionsScreens.swift`):

- **Header:** "Instructions", History (secondary) and "Save to 3 hosts" (primary).
- **Scope:** Every host | Per host (a 300pt segmented control: a `bgSelected` track at radius 9,
  30pt segments at radius 7, 13), and the sync state at 12.5 `textTertiary` ("This Mac, build-01
  synced · horizon when it's back").
- **Files** as tabs (22pt apart, a hairline under them): the name in mono 13 (the open one in
  `textPrimary` semibold with a 2pt `textPrimary` underline, the other `textSecondary`) over a
  caption at 11.5 `textTertiary` ("how you work · ~640 tokens", "rules that win · ~90 tokens").
- **Editor** (`bgWindow`, a 1px `lineStrong` line, radius 12): a bar on `bgSunken` (8×12 inset)
  with the file's path in mono 12 `textSecondary` and "● edited" at 11.5 `lanternText`; lines at
  least 26pt in mono 14/26 in `textSecondary`, numbered in a 34pt column (mono 10.5
  `textTertiary`), the edited line on `lanternTint`; at least 250pt tall.
- **Read order:** "READ IN THIS ORDER · LATER WINS", then mono 11 chips (4×8 inset, radius 6, a
  1px `lineSubtle` line, `textSecondary`) joined by "→": System prompt → root AGENTS.md → parent
  folders → repo AGENTS.md → APPEND_SYSTEM.md (the last on `lanternTint` with a `lanternText`
  line, in `textPrimary`). Under it at 12.5/1.5 `textTertiary`: "APPEND_SYSTEM.md is added to the
  end of the agent’s system prompt, so these rules beat anything in an AGENTS.md. Keep it short."
- **In the app** the bar holds the title, and History and Save (NW buttons at `l`) end the page's
  first row, after the scope control and its state, dropping under them where the row is too
  narrow. The state names every host ("Studio, build-01 synced · horizon when it's back", "…
  build-02 differs"), with Sync now as a link while one differs; Per host swaps it for a menu of
  the host being edited. The path is the host's own instructions folder, the editor is the
  phone's (`InstructionsTextEditor`) at the iPad's sizes, and it fills the height left: the read
  order and its note step aside while the keyboard is up. The chips name Shepherd's files
  ("Shepherd's AGENTS.md", "Shepherd's APPEND_SYSTEM.md"), marking the open one, and the note
  speaks for the open file (AGENTS.md: "Shepherd's AGENTS.md comes before any folder's or repo's
  AGENTS.md, so a repo's own file can refine it."). History opens a 360pt popover of the open
  file's saves on the host edited, newest first: a summary over "07:12 · from iPhone", and Restore
  on all but the newest ("current"); with Same on every host on, a restore reaches every host. The
  iPad has no key row.

## Side pane (iPadPaneBrowser, iPadPaneArtifacts, iPadPaneFiles)

Built: the Changes pane (see Review) is the only thing beside a thread; its head carries the
Changes tab alone, and the header's side-pane button shows and hides it (Thread › Header
buttons).

**Not built yet: the side pane.** Show side pane (a 40pt circle in the thread's header; Hide side
pane, on `bgSelected`, while it shows) opens a pane on the thread's trailing side, with a 1px
`lineStrong` leading edge on `bgWindow`: 620pt for Browser, 640pt for Artifacts, 720pt for
Files. The sidebar hides while it is open (Show sidebar in the header). Its tabs are the review
and three more, so the docked review becomes its Changes tab.

- **Head** (the 76pt header, 12pt leading and 10pt trailing inset): the tabs as a segmented
  control (a `bgSunken` track with a 1px `lineSubtle` line at radius 10, 3pt inset; 36pt tabs at
  radius 8, 13.5, 7pt gap; the open one on `bgWindow`, semibold, with its 15pt glyph, the others
  `textSecondary` medium): "Changes 2", "Browser", "Artifacts 3", "Files", counts in mono 11
  `textTertiary`, a 7pt `running` dot on a tab whose content the agent is changing. Close pane
  (40pt) trailing.
- **Browser** (iPadPaneBrowser):
  - A 52pt bar (8pt inset, a hairline under it): Back, Forward (at 40% with nowhere to go),
    Reload (36pt circles); the address (a 30pt capsule on `bgSunken` with a 1px `lineSubtle`
    line: a 12pt `textTertiary` glyph, the host in mono 12 and the path in `textSecondary`, and
    the host it runs on as a 20pt tag, "build-01"); then Select an element (on `lanternTint` with
    a `lanternText` glyph while on), Viewport size, and Open in your browser.
  - The page is the host's dev server, drawn in its own colors.
  - Selecting an element outlines it in 2pt `running` (radius 10, `running` at 8% inside) and
    labels it ("button.pay 240 × 44", mono 10.5 white on `running`, radius 4). Its card (188pt,
    `bgRaised`, a 1px `lineStrong` line, radius 10, the popover shadow, 8pt inset): its source
    ("Checkout.tsx:88", mono 10.5 `textTertiary`), Add to message (primary, 24pt, with its
    glyph), and Copy selector (ghost).
  - An added element rides in the composer as a chip above the field (30pt, radius 6, a 1px
    `lineStrong` line: the selector in mono 12, its source in mono 10.5 `textTertiary`, and a
    9pt remove).
  - A 32pt console bar at the foot (`bgBase`, a 1px `lineStrong` line above, 14pt apart):
    "Console" at 12/600, "Network" at 12 `textSecondary` with its count in mono 10.5
    `textTertiary`, "1 warning" at 11.5 `lanternText` with a triangle, and Hide console (24pt).
  - The thread's line for it: "Opened the checkout · localhost:5173".
- **Artifacts** (iPadPaneArtifacts): the thread's line "Made an artifact · Load test report ·
  v2" opens it here.
  - A 52pt bar: All artifacts (36pt), a 22pt `bgSelected` tile at radius 6, the name at 13/600,
    the version as a menu chip (22pt, radius 6, a 1px `lineSubtle` line, a clock glyph, "v2 · 6m
    ago" in mono 11 `textSecondary`, a chevron), Preview | Source (20pt segments), Edit, and Open
    in a window (36pt).
  - The artifact renders in its own colors on a padded surface (18pt).
- **Files** (iPadPaneFiles), the repo while pi works in it:
  - A 210pt tree on `bgBase` (a 1px `lineSubtle` trailing edge). Its head (10×12 inset, a
    hairline under it): the repo in mono 12.5/600 with Go to file, and the branch and host at 11
    `textTertiary` ("fix/pay-jump · build-01", each with its glyph). Rows 32pt at radius 5, 12.5,
    14pt deeper per level: a 9pt chevron for a folder, a 12pt `textTertiary` glyph for a file; M
    in mono 10.5/600 `lanternText` trailing on a changed file; an 11pt `running` pencil on the
    file pi is editing. The open file's row takes `bgSelected` and a semibold name.
  - Open files as 42pt tabs (`bgBase`, `lineSubtle` between them; the current one on `bgWindow`
    with a 2pt `lantern` line along its top): the name in mono 12, a 7pt `lantern` dot while
    yours is unsaved, the `running` pencil while pi edits it.
  - A 44pt path bar (a hairline under it): "src › components › Checkout.tsx" in mono 11.5
    `textTertiary`, then Revert (ghost, 24pt) and Save (secondary, 24pt, with "⌘S" in mono 10.5
    at 60%).
  - The editor: lines at least 24pt in mono 13/24, numbered in a 44pt column (mono 10.5
    `textTertiary`), each with a 3pt change bar: `lantern` for your unsaved lines (on
    `lanternTint`), `running` for lines pi changed; a `lantern` caret.
  - A 28pt status bar (a hairline above, 11 `textTertiary`): the legend ("yours, unsaved" beside
    a 3×11 `lantern` bar, "changed by the agent" beside a `running` one) and, trailing, "Ln 94, Col 48
    · TSX · Spaces: 2" in mono.
- Saving and reverting here would change a repository on the host, which only the paths in
  docs/rules.md › Only these paths mutate repositories may do; Files needs a new one decided first.

## iOS: Automations

`App/iOS/Automations` (MobileAutomations, iPadAutomations boards), from Home's Automations row
or the iPad sidebar's.

- **What an automation is here:** the Mac's fields and nothing else. It has a name, a prompt,
  a folder on its host (one of the host's spaces), and a switch: **On** starts a run each time
  Shepherd launches on the host; Run now starts one any time. The boards' schedules, triggers,
  models and repo lists are not built, because the host has none of them.
- **List** (MobileAutomations): the large title "Automations" with New automation trailing (a 36pt
  `lantern` circle with a plus; the app's toolbar `plus`), shown when a host can take one; on
  `bgWindow` with 14pt sides.
  - **Running now** heads each live run as its own card: a `running` line with a 3pt `runningTint`
    ring, 12×14 padding: a 13pt `running` spinner, the name (15/600), and the host (mono 11
    `textTertiary`) trailing, then how the run is going (13 `textSecondary`: "Running · 4m"; "Asked
    you" in `lanternText`, with a bolt in place of the spinner and a `lanternText` line with no
    ring; `NWAutomationRunCard`). A tap opens the automation. The iPad's column is one flat list
    instead, the live runs first, with no section heads.
  - **All** with the count, one card of 64pt rows (`NWAutomationRow`, 10×14 padding, 3pt between
    lines): the name (15/500), "When Shepherd starts · folder" or "By hand" (12.5 `textTertiary`;
    the host's name in mono instead of the folder when there are several hosts), how the last run
    went with its time in its tone (12: "Finished · 12h ago" in `done`, "Asked you" in
    `lanternText`, "Interrupted · 3d ago" in `failed`, "Not run yet"; "On" or "Off" until its runs
    are read), and its switch, which flips at once and waits for the host.
  - An offline host's rows read "Paused · host offline" in `textTertiary` with the switch drawn
    off; the board does not dim them. The app says "Host offline", dims the row and draws no switch.
  - The board's rows have no leading glyph and are never dimmed. The app leads each row with a
    bolt (a `running` spinner while it runs; `lantern` while it asks) and dims every automation
    that is off.
  - A host from before automations over the remote protocol keeps its rows and says under the list
    why they are read-only. Empty: "No automations" ("An automation is a saved prompt a host runs as
    a new thread. Save one here, or ask an agent on the Mac to.") with New automation.
- **Not built yet:** "Also on your Lock Screen as a Live Activity." (12 `textTertiary`) under a
  running card, once a run can be followed as a Live Activity (Notifications and Live
  Activities › Live Activities).
- **iPhone** pushes one automation; **iPad** (iPadAutomations) lists them in a 360pt column
  (`MobileLayout.automationsListWidth`; a 1px `lineSubtle` trailing edge) beside the chosen
  one's detail. The column's header is "Automations" with New automation (+, a 40pt circle). Its
  rows (at least 66pt, 8×12 inset, radius 10 (the app's 8), 2pt apart, 10pt gap; the chosen one on `bgSelected` with a
  semibold name): an 18pt glyph column (a spinner while a run works), the name at 15/500, when it
  runs at 12 `textTertiary`, how the last run went at 12 in its state's color (`running`, `done`,
  `lanternText` for "Asked you", `failed`, `textTertiary`), and the switch (30×18, `lantern` on).
  The detail's header is the name, an On or Off pill (On in `done` on `doneTint`) and the ••• menu.
- **Detail:** the On switch with what it means, Status, Runs on ("build-01 · a new thread each
  run"), Folder, the prompt, the latest fourteen runs as bars (bar height = duration), the last run,
  and every run the host kept (`NWRunRow`), each opening its thread while it exists. The footer is
  Edit and Run now (with Open run while the finished run's thread is there; running again replaces
  it), or, while a run works or asks you, Stop (confirmed: it deletes the run's thread) and Open
  run. The ••• menu has Open Run, Edit and Delete Automation (confirmed). Each confirmation rises
  from the control that asked (Stop, or the ••• menu), never from the middle of the screen. On iPad
  (iPadAutomations) the detail sits 16×20 in: fact rows at least 36pt with a hairline above (a 110pt
  label column in `textSecondary`, the value at 14, names in mono); the prompt as a card
  (`bgRaised`, a 1px `lineSubtle` line, radius 12, 12×14 inset: "Prompt" at 12 `textTertiary`, the
  text at 14/1.55); "LAST 14 RUNS" with "bar height = duration" beside it, then 120pt of bars 5pt
  apart (radius 3 on top; `done`, `failed`, `lantern` for a run that asked, at 75%, the latest at
  100%) over a hairline, and under them the first date, the counts ("failed: 1 · asked: 1") and the
  last run's time in mono 10.5 `textTertiary`. The last run is a card: its glyph, "Today 02:00 ·
  passed in 43s" at 14.5/600, and Open thread (13, `running`). The foot (a hairline above, 12×20
  inset, 26 under) holds Edit (secondary) and Run now (primary, with its glyph), 36pt.
- **Form:** Name, Prompt, Where it runs (Host when adding and more than one can take it, then
  Folder from the host's spaces), and Starts with Shepherd. Save waits for the host. A new
  automation keeps one id for the life of the form, so saving again after an answer that never
  came back can never save it twice.
- **Switches** (`NWAutomationSwitch`) flip from their whole 44pt target, caption included, and
  read as toggles to VoiceOver.
- **When a change does not come back ok:** a refusal shows a banner with the host's reason
  ("Couldn't start the run: …"). A timeout or a dropped connection says the change may have
  happened and to check before trying again; nothing is ever resent on its own. Delete closes
  the iPhone's detail only once the host has removed the automation.
- **Not built yet: a run's outcome.** The boards word a finished run by what it did ("Passed ·
  12h ago", "1 PR failed CI · 3d ago", "Paused · host offline") and show the last run's summary
  under it ("3 migrations, all reversible. 0042_funnel_partitions took 12s on the prod copy.").
  Runs today end Finished, Stopped or Interrupted, and the host sends no summary. An automation
  that runs a mission ("Weekly dependency bump · mission") waits for Missions.
