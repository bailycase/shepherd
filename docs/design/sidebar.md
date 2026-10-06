# Sidebar

> Read when you change sidebar activity groups, disclosures, thread rows or Projects.

`SidebarView` (`SidebarView.swift`, its values in `SidebarModel.swift`) on `NWSidebar` (ShepherdUI,
`Components/Navigation/Sidebar.swift`): the sidebar every Mac board draws (NWNavigation, and the
sidebars of Main, Running, NavNewThread, NavAutomations and NavHosts). 232pt on `bgBase` by
default, and it keeps its width when the side pane opens. Top to bottom: the top bar, the
destinations, Done, Pinned, Needs you, Working, Recents, Designs, and the footer.
Reference: [NWNavigation.png](boards/NWNavigation.png), revision 420, and
[NWNavigation-checklist.md](boards/NWNavigation-checklist.md). The user's clarification puts
Done first when it contains unseen completions. Pinned follows Done and keeps pinned threads
there regardless of status. Empty groups remain hidden.
Settings ▸ Appearance ▸ Organize by (or View ▸ Organize Sidebar By) swaps the activity groups for a project tree (Organized by project, below; it draws no pins); Activity is the
default. Each part follows Settings ▸ Appearance ▸ Sidebar
rows: Compact 22pt, Standard 28pt and Comfortable 36pt. Activity rows have no inter-row gap;
destinations and the project tree keep their existing 1pt gap.

The user's decisions, 2026-09-25: "Match the canvas (Recommended)": Recents replaces the This Mac /
host / space tree, ⌘N opens the New thread page instead of starting an agent at once, spaces become
the projects of the New thread page's workplace chip, and drag order, nesting and collapsing go
away. "Hide them (Recommended)": Missions, Designs, More ▸ Design systems and Archive are not built
yet, so they are hidden until built, and More holds Hosts and Extensions. "Mac user + this Mac
(Recommended)": the footer shows the Mac's user and this Mac.

- **Top bar (44pt, `NWSidebarTopBar`):** room for the window controls, a spacer that drags the
  window, then Search (a magnifying glass, "Search  ⌘K", opens the palette) and Hide sidebar
  (`sidebar.left`, ⇧⌘S) as 26pt circular icon buttons (`.nwIcon`), 4pt apart with 8pt trailing
  padding, each a 14pt `textSecondary` glyph. The chords come from `KeybindingsStore`.
- **Destinations** (`NWSidebarDestination`; `SidebarDerivation.destinations`): a stack with 1pt
  gaps, padded 2pt above and below and 8pt at the sides. **They never move:** their order is fixed.
  Each is 30pt (24), radius 8 (`NW.Radius.m`), padded 8pt (6) at the sides, with a 20pt icon slot, a
  9pt (7) gap, and the title in Geist 13 (12) regular `textPrimary`. The icons are 15pt (13) strokes
  in `textSecondary`. Hover is `bgHover`; the selected destination is `bgSelected` with its title in
  semibold and its icon in `textPrimary`. In order:
  1. **New thread**: a `plus` in a 20pt `bgSelected` circle, and its chord trailing as keycaps
     (`NWKeycap`, `KeybindingsStore`'s `.newAgent`). It opens the New thread page.
  2. **Designs**, while the Design tool experiment is on: the outline nib. It opens Designs.
  3. **Automations**: an outline `bolt`. It opens the Automations page.
  4. **More**: a chevron in `textTertiary`, pointing right while closed and turned down while open.
     It discloses its rows, indented to 22pt leading padding: **Hosts** (`display`), carrying "n
     offline" in mono 10 `failed` while a host is neither connected nor connecting (NavHosts: "1
     offline"), which opens the Hosts page; and **Extensions** (`puzzlepiece.extension`), which
     opens Settings ▸ Pi, where the bundled extensions are. Opening Hosts opens More; the
     disclosure is not kept across launches.
- **Section headers** (`NWSidebarSectionHeader`): omit empty groups. A 9pt outline chevron
  points down while open and right while folded, 6pt before the title. The title is Geist 11.5
  medium `textSecondary`; its adjacent count is Geist Mono 10.5 `textTertiary`. Needs you uses
  `lanternText` for both. Header rows follow density with a 24pt minimum hit area and 6pt above.
  Each disclosure persists independently in `shepherd.sidebar.collapsedActivitySections` on this
  Mac. Folded groups keep their counts but build no rows. Folded Working keeps a blue pulsing
  dot, static under Reduce Motion. Done's separate "Mark all seen" button remains available
  while folded, with a 20pt visual height and 24pt hit area.
- **Needs you**: unpinned agents on this Mac or a connected host that are blocked, automation runs included
  (a subagent never waits on you: its question goes to its parent). The header is "Needs you" in
  Geist 11.5 medium `lanternText` with an adjacent mono 10.5 `lanternText` count.
  Each row (`NWSidebarRow`) is 28pt (22), radius 8, padded 8pt (6), with a 14pt leading slot
  and a 9pt (7) gap. The slot holds a thread's glowing 6pt `lantern` dot, or an automation run's
  13pt (11) `bolt` in `lanternText`. The title is in the row font, truncating at the tail. The
  reason trails in mono 10 `lanternText` ("retention?", "approve plan"): the agent's own word or
  two for its question (`Agent.waitingReason`) when its asking tool gave one, else the question
  its thread asks (`Agent.waitingOn`); else "ASK". Cut to 14 characters at a word
  (`NeedsYouReason`, shared with the iPad). Most recently active first. The agent is asked for the reason
  (the user's decision, 2026-09-25: "Ask the agent for a short reason"): Shepherd's status
  extension gives every asking tool (named like `ask` or `question`, the same rule that sets
  `blocked`) an optional `short` parameter, described to the model as 1–3 words for this sidebar,
  and takes it out of the call before the tool runs; the host reads it from the call's arguments
  and pairs it with the dialog that call opens. A child's `shepherd_parent_message` takes the
  same `short`. An agent that gives none, and an older host, fall back to the question cut short.
- **Not signed in:** an agent on this Mac whose pi can't start because it isn't signed in
  (Thread › Not signed in) is in Needs you too, with the glowing lantern dot and "sign in" as its
  reason (`NWSidebarRow(agent) · .notSignedIn`), until it starts again.
- **Pinned**: follows Done, in pin order, oldest pin first. It has the same disclosure and
  adjacent count as the other groups. Empty, it is absent. The user explicitly requested this
  addition to the supplied board. Its rows are Recents' rows, for a thread on
  this Mac or on a connected host alike (state dot, host tag, activity and completion age, the
  selected row in `bgSelected`); a pinned row wears no glyph of its own, since the header says it,
  and VoiceOver adds ", pinned" to its label. The user's decisions for it, 2026-09-30 (the request
  was "pin threads at the top in a different labeled list", and no board drew one):
  - **One place each:** a pinned thread stays in Pinned while working, blocked, idle or done.
    Its status dot, question reason and context menu still update. No other group repeats it.
    A pinned thread on a host that dropped stays
    in Pinned as the host last sent it, dimmed and without Needs you, as in Recents; one on a host
    not reached since launch is absent until it connects.
  - **What is pinned:** threads on This Mac and on connected hosts. An automation's run is not
    (the next run replaces its agent), and a design is not (it lists under Designs).
  - **How:** Pin and Unpin in the row's context menu, the thread options menu and ⌘K (below).
    They have no chord. There is no drag to reorder: the rows keep the order they were pinned in,
    and unpinning then pinning a thread again moves it last (a drag would need machinery of its
    own, as the project tree's does).
  - **Kept** per Mac, as view state beside the project tree's closed projects
    (`shepherd.sidebar.pinned` in the app's preferences, by a thread's host and agent id, so a
    pinned remote thread works): not in state.json, never sent to another device, and not reset by
    Reset settings. The iPhone and iPad do not show pins, and the project tree keeps them without
    drawing them (no Pinned section, and no Pin in its menus). A pin goes when its thread is
    deleted or its host is removed, never before the workspace has loaded or for a host that
    hasn't connected this launch.
  - **Launch and Continue** read the most recently active thread, pinned or not: a launch shows
    the thread that needs you, else the one most recently active (as before), and the New thread
    page's Continue card is the most recent running thread.
  - **Performance:** the lists derive once per change (`SidebarDerivation.lists` takes the pins
    with the source); a pin change redraws the moved row and both groups' count headers. A status
    report on a pinned thread redraws only its row (`ListPerformanceTests`).
- **Working**: unpinned running threads and live automation runs, most recently active first.
  A thread with a live, unpaused child stays here even after its own turn becomes idle or done,
  on this Mac and connected hosts. Its dot and accessibility label say running, and project-tree
  rollups use the same presentation. A child's question never puts the thread in Needs you.
  Pinned, the parent's own question, startup failures and offline hosts keep their existing rules.
  This uses the published child rows, not a changed agent status or an extra poll. See the
  [user requirement and checklist](boards/SidebarWorkingSubagents.md).
  A Working or Checking goal keeps its thread here between pi turns, on this Mac and connected
  hosts. An open question still puts it in Needs you; pinned threads remain Pinned. Paused,
  Met and cleared goals follow ordinary turn status.
  A local thread created with an opening message appears here immediately, including while pi
  starts, rather than briefly appearing in Recents. Its dot and accessibility label say running.
  Empty threads still enter Recents. Startup failures retain their existing Needs you or
  can't-start presentation. A command that starts no turn returns to Recents when no message
  remains pending. This startup presentation is local view state, not a changed agent status
  or a remote protocol field.
  Local rows draw a 28 × 12 blue sparkline from their last ten measured tool-completion rates.
  Before the first tool event it is flat, never a decorative waveform. Remote rows retain their
  host tag because the remote protocol carries no tool-activity samples.
- **Done**: the first activity group when nonempty, above Pinned, Needs you and Working.
  It contains unpinned finished, unseen threads and settled automation runs. Opening one keeps it
  here while read. Opening the same thread or a destination page changes nothing; opening a
  different thread marks the previous completion seen and moves it to Recents. A later completed
  turn returns it to Done. "Mark all seen" clears every current Done row, including the selected
  one, without changing selection or folding Done. Local rows show completion age, such as
  "2m ago". Failed turns keep their red dot. Remote rows retain the host tag.
- **Completion bookkeeping** (`SidebarCompletions`): app-owned, ephemeral generations advance on
  finished status edges, independently of the local callback/adoption pair. Repeated reports and
  refused sends never create a local completion or change its captured time. Remote records
  survive disconnects and use a changed `lastActiveAt` on reconnect as a catch-up hint. A refused
  send during disconnection is indistinguishable from a missed completion; older hosts without
  timestamps can miss a completion. An endpoint change resets that host's records. Authoritative
  deletion prunes records, but an offline snapshot does not. A parent with working children is
  not finished; finishing or clearing the last child creates a new completion generation, so an
  earlier seen parent turn cannot hide it in Recents. Identical child reports do not create more
  completions. Remote child snapshots stay cached in memory across disconnects, just like agent
  snapshots; offline precedence hides Working and Done until reconnect. Refresh replaces settled
  or empty child rows and prunes deleted agents. Disconnecting or reconnecting never fabricates a
  completion before that refresh. No extra transcript polling or new server fields.
- **Designs**: a separate group below Recents while the Design tool experiment is on. Rows use
  the outline nib and real board count, sorted by their design's last activity. A design's agent
  never has a thread row. The existing Remove from Recents action hides that design's sidebar row
  until it changes again.
- **Recents**: idle and seen unpinned threads, most recently active first. Rows retain their state,
  title, host tag and context menu. The leading
  slot is the thread's state dot (running blue, done green, failed red for a turn that ended in an
  error, hollow while idle) or an automation run's `bolt` in `textTertiary`. The selected row is
  `bgSelected` with its title in semibold. The trailing slot holds, in priority order:
  1. the ⌘-digit hint on the first nine visible threads in Done, Pinned, Working and Recents while ⌘ is held ("⌘3", micro
     `textTertiary`)
  2. a remote agent's host as a tag: mono 10 `textTertiary`, padded 4pt at the sides, in a 1pt
     `lineSubtle` border at radius 4 ("horizon"). Threads on this Mac carry no tag.
  3. "waiting" in mono 10 `textTertiary`, with a `clock` glyph in `textSecondary` in the leading
     slot, for a restored agent that the first launch's copy from your pi holds (PiAuthStates'
     `NWSidebarRow(agent) · .waiting`); VoiceOver reads "waiting". It goes when the agent starts.
  4. "can't start" in mono 10 `failed` for an agent on this Mac whose pi stopped before it served
     (Thread › Can't start), with the red dot (a thread's) or the bolt (a run's); VoiceOver reads
     "can't start". It clears the moment Retry starts pi again. A remote agent's row doesn't say
     it: the host sends it only in the thread's snapshot.
  5. a completion's age in mono 10 `textTertiary`, or "failed" in `failed` for a failed automation.

  All activity groups share one lazy scrolling stack in the rest of the column.
- **Order** (`Agent.lastActiveAt`): the host stamps an agent when a turn starts or ends
  (`AgentStatus.movesRecents`; asking and being answered happen inside a turn) and when a message is
  sent to it, and the app stamps an agent it creates. A streamed token, a repeated status report or
  a question never moves a row, so the list holds still while you read it. Agents no host has
  stamped (older hosts and state files) follow, newest created first. `lastActiveAt`, `waitingOn`
  and `waitingReason` are live state on `Agent`, broadcast to remote clients like a status;
  `waitingOn` and `waitingReason` are never written to state.json. At launch the most recently
  active agent on this Mac shows.
- **Hosts:** a connected host's agents join the appropriate activity group, tagged. A
  host that drops keeps its threads in Recents (or Pinned) as it last sent them (NavHosts' `horizon` rows), dimmed (`NWListMetrics.dimmedOpacity`,
  as on the iPad), never in Needs you since nothing there can be answered, and with a menu that
  says "Host Offline"; opening one shows the host's connection state. A host not reached since
  launch lists nothing. More ▸ Hosts says how many are offline, and the Hosts page carries their
  notices and Retry.
- **Footer** (`NWSidebarFooter`): behind a hairline, padded 10pt above and below and 12pt at the
  sides, with a 10pt gap. It holds a 26pt `bgSelected` circle with the initial in Geist 11.5
  semibold, the Mac user's full name (`NSFullUserName`) in `ui` medium over "This Mac · <the
  computer's name>" in mono 10 `textTertiary`, and a Settings gear as a 26pt icon button (⌘,) at
  the trailing end.
- **Subagents have no rows.** They live in their agent's tray, thread record lines, inspector
  and palette. Their questions go to their parent agent, not to the user. Only the thread's own
  question or missing sign-in puts an unpinned agent in Needs you.
- **Width:** 232pt by default, 190–340, by dragging the trailing edge (a 9pt handle, adjustable
  with VoiceOver in 16pt steps) or in Settings ▸ Appearance. It never narrows the main column
  below 720 and keeps its width while the side pane is open.
- **Interaction:** list rows are tap views with button traits and accessibility actions, and
  destinations are buttons. Hovering never moves or resizes anything. ⌘1–9 select the first nine
  visible threads of Done, Pinned, Working and Recents in display order. Needs you and Designs
  take no digit. ⌘↑/↓ walk every visible row in display order and wrap. Palette or programmatic
  selection unfolds the target's group and scrolls its row into view. Picking a row leaves a page for that thread.
- **Context menus** keep every action an agent had:
  - This Mac's threads (NWComposer's agent menu, with today's items between its separators):
    Rename… with its keys (⌘R), Pin or Unpin (`pin`, `pin.slash`, named for what it does now),
    Fork from Here (`arrow.branch`) and Copy Transcript
    (`doc.on.doc`); Review Changes and Open in Finder; then Finalize Worktree… and Delete
    Worktree Agent… for a worktree agent, or Delete Agent. Fork from Here copies the agent's pi
    session, as it stands, into a new session and starts "<name> (fork)" beside it in the same
    space and folder (the namer retitles it on its first turn); Copy Transcript puts what was
    said on the pasteboard, the user's and the assistant's text along pi's current branch as
    "user: …" and "assistant: …" paragraphs (`PiSessionFile.transcript`); Open in Finder opens
    the folder the agent works in. A fork or copy that finds no session says so
    (`ActionErrorDialog`). Remote threads have no Fork, Copy Transcript or Open in Finder: they
    read a file on another Mac.
  - This Mac's automation runs: Stop while the run is live (a run whose pi is still starting
    included; `AutomationRun.isLive`), else Run Now, then Delete Automation. Run Now replaces a done
    run once the new run exists; a refused Run Now shows `ActionErrorDialog`.
  - Remote threads: Rename…, Pin or Unpin, Finalize Worktree… (worktree agents), Review
    Uncommitted Changes, Review PR Changes, and Delete Agent or Delete Worktree Agent…, while the
    host is connected. A pin is this Mac's own, so while the host is offline the menu keeps Pin or
    Unpin above Host Offline.
  - Pin and Unpin are offered on thread rows in every activity group (Activity only),
    never on an automation's run, a design, or a row of the project tree.
- **Motion:** rows arriving, leaving and moving up animate `.list` (keyed on the rows' ids, never
  the rows), and More's rows disclose (`.disclosure`). Selecting a row changes no row's place, so
  it lands at once. A status report or a settled name changes only its row, in place (`.content`),
  and counts roll (`.numeric()`).
- **Gone with the old tree:** the Automations footer and a host's Automations disclosure, space
  nesting by path, and the ⌃⇧1–9 machine jumps. Its preference keys (`shepherd.collapsedSpaces`,
  `collapsedHosts`, `localMachineCollapsed`, `automationsExpanded`, `expandedRemoteAutomations`,
  `collapsedRemoteSpaces`) stay in older preferences, unread. Projects, their counts and hover +,
  drag order, collapsing and host sections came back as the Projects style (2026-09-26).

## Departures from revision 420

- Done comes first when nonempty, as explicitly requested by the user.
- Pinned is an extra group after Done, explicitly requested by the user, and keeps pinned threads in
  every status.
- Compact section headers are 24pt instead of 22pt to meet the Mac minimum hit area. Thread rows
  remain 22pt.
- Remote rows keep their host tags instead of a sparkline or completion age. The protocol has no
  activity samples, and the host identity must stay visible.
- Missions and Archive remain hidden because their destinations do not exist. Designs and
  Design systems remain behind the existing Design tool experiment.

## Organized by project (Sidebar — Projects)

`SidebarProjectsList` (`SidebarProjectsView.swift`, its values in `SidebarProjectsModel.swift`
and `ShepherdViewModel+SidebarProjects.swift`) on `NWProjectRow`, `NWProjectsHeader` and
`NWSidebarSection(.host)` (ShepherdUI, `Components/Navigation/SidebarProjects.swift`): the boards
SidebarTree, SidebarProjects and SidebarProjectsHosts. Mac only: the iPad and iPhone keep Activity.

- **Destinations stay** on top in both styles; only the list under them changes. It is one scroll
  view either way, so switching (Settings or the View menu) keeps the thread on screen selected,
  opens its project and scrolls its row into view.
- **A project is a space** of This Mac's (`Space`). The reserved spaces never are: an
  automation's run sits in the project its folder is in (the deepest project holding its `cwd`),
  with its bolt, or nowhere in the tree when no project holds it (the Automations page and ⌘K
  still list it). Designs and their agents are not in the tree (see Where Shepherd departs from
  the boards); missions are not built.
- **Header:** "Projects" in Geist 11.5 medium `textTertiary`, spaced like Recents, with an 18pt +
  circle (`NWProjectsHeader`) opening a menu: Add Project…, and under Hidden from Sidebar a Show
  <project> for each hidden one.
- **Project row** (`NWProjectRow`): the density's height, radius 8, padded 2pt outside a thread
  row (6pt, 4 in Compact) and 8pt (6) trailing; a 14pt chevron slot (a 9pt semibold
  `textTertiary` chevron, right while closed and turned down while open, `.disclosure`), a
  `folder` in `textSecondary`, the name in the row font at medium, 6pt apart, and the count
  trailing in mono 10.5 `textTertiary`. Closed, the count rolls up what is inside: a glowing
  lantern dot and the count in `lanternText` while something waits on you, a running dot while
  something runs, else the count alone. Hovered (`bgHover`), the count gives way to + (New thread
  in this project) and ··· (the project menu), 20pt circles 2pt apart with 11pt glyphs, built only
  while hovered. A project on a host that is not connected dims and takes no +.
- **Threads** are the Recents rows (`NWSidebarRow`, `nested`), led 20pt further in so their dot
  sits under the folder, with the same dots, words, reasons and tags. **Needs you rows stay in
  their project** with the amber dot and the reason; there is no Needs you section.
- **Order:** projects keep the spaces' order, which a drag changes (`SessionServer.moveSpace`),
  and a project added on this Mac or by a remote client goes on top. Inside a project the newest
  activity comes first (`Agent.lastActiveAt`, as Recents). Every project shows, an empty one too.
- **Drag** a project by its row (no drop targets): the offset picks the project it lands before,
  a 2pt `running` line (`NWDropIndicator`, 4pt in from the sides) marks where between the rows,
  and the dragged row dims to 55%. Only This Mac's projects move, among themselves.
- **Keep idle threads** (Settings, 7 days by default): an idle or finished thread quiet for
  longer leaves the tree; running threads, anything waiting on you, and threads no host has
  timed stay. The palette still finds them. The cutoff is kept to the hour, so the tree derives
  again at most hourly for it.
- **Hide from Sidebar** (the project menu) sets `Space.sidebarHidden`, written to state.json:
  the project and its threads leave the tree, and the + beside Projects brings it back.
- **Hosts:** not grouped, a connected host's threads sit in This Mac's project of the same name,
  tagged with the host as in Recents; a project only hosts have follows This Mac's, by name.
  **Group by host** (Settings) gives a section per host, This Mac first, each headed by its name
  (`NWSidebarSection(.host)`: Geist 11.5 medium `textTertiary`, and "unreachable" in mono 10
  `failed` while the host is not connected), its projects inside, and its rows without the tag.
  A host's projects follow its own order.
- **Project menu** (right-click a project, or ···; native): New Thread in <project> (on the host
  its newest thread runs on, else This Mac, else a connected host that has it), Reveal in Finder
  and Open in Terminal (This Mac's projects: the Mac's Terminal in the folder), Copy Path,
  Collapse All, and Hide from Sidebar (This Mac's).
- **Keys:** a click on a project opens or closes it and gives the tree the keyboard: ← closes
  that project and → opens it (plain arrows, only while the tree has focus, so never a chord for
  `KeybindingsStore` or Ghostty's list). ⌥-click opens or closes every project. ⌘1–9 and ⌘↑/↓
  follow the open projects' threads in order. Closed projects are remembered
  (`shepherd.sidebar.collapsedProjects`, view state, not reset by Reset settings).
- **Density:** the tree's rows follow Sidebar rows like the rest of the sidebar.
- **Performance:** one lazy stack; the tree derives once per change (`SidebarDerivation.tree`,
  cached on `SidebarSource` and `SidebarTreeOptions`), a closed project builds no thread rows,
  and a status report redraws its row and its project's. `ListPerformanceTests` pins opening,
  scrolling, a status change and opening a project.
