# Shepherd design

This document is the authority on how Shepherd looks and behaves, on the Mac and in the iPhone
and iPad client. Where anything disagrees with it, this document wins. It is the written form of
the design canvas, "Shepherd chat UI", which the agents building Shepherd's UI never see: its
pages are macOS, iOS, iPadOS, Notifications, Missions, Design tool, and Design system · Night
Watch. That last page is **Night Watch**, Shepherd's design system: Foundations, Controls,
Status & feedback, Thread, Composer & menus, Navigation, Agents & orchestration, Review, Swift
implementation, Missions map, Mission screens, and Design tool, each drawn dark and light. Its
Option A boards are superseded (see Theme model).

Rules name their board in parentheses, e.g. (NWFoundations), so a reader can trace them, and the
Board index at the end maps every board to the section that specifies it. What the app doesn't
implement yet is still specified in full and marked **Not built yet.**: build it to that spec,
and skip it when working on shipped UI. The places Shepherd deliberately departs from the boards
are listed below; any other difference between the app and this document is a gap to fix (Known
gaps). A UI decision changes this document and the canvas together, so they never disagree.

Every value lives in code, and this document names the code so you can check it:

- **Tokens and shared components:** the ShepherdUI package (`Packages/ShepherdUI`, module
  `ShepherdUI`).
- **The Mac app's own surface dimensions:** `AppLayout`, split by domain into
  `Sources/ShepherdApp/AppLayout+<Domain>.swift`.

## Mental model: agents, not chats

Shepherd organizes work around **agents**, not chats: live workers you supervise. An agent is a
`pi --mode rpc` process with:

- a title it gives itself
- a workplace (a space's checkout, or a worktree of it)
- a lifecycle: working, blocked on you, done (or failed, when its last turn ended in an error),
  idle

Every agent renders as a native **thread** (Main, Running): the toolbar over it, the transcript
with its subagent cards, and the composer pinned under it, with questions inside the composer
and Up next above it. The UI's job is supervision: *which of my workers needs me right now, and
what did it just do?* The sidebar leads with status, and selecting an agent opens its thread.
Every UI decision should survive the question "does this help a person supervise ten working
agents at once?"

- **Names:** agents name themselves with a short task title (`Fix plan mode`), never a persona or
  a sentence. A hand-typed rename is final.
- **Spaces** are project folders that group agents in the sidebar. A space has no view of its
  own.
- **Remote hosts:** another Mac serving its agents is a section of the same sidebar, with the
  same rows and the same thread.
- **Terminals** exist only as panes of an agent's layout, shown in the terminal panel under its
  thread: the user opens one with ⌘D or the panel's +, or an agent opens one with its `pane_*`
  tools. There are no global shells, no space shell workspaces, no agent rendered as a terminal,
  and no Terminal/Native switch.
- **Words:** an agent's conversation is its *thread*, made of *turns* (yours and the agent's)
  and *messages* (Main, Running: "Copy response", "Retry turn").
- **Not built yet.** The Main and Running boards give the sidebar destinations beside the
  agents, among them **Missions** (one map from a goal to merged pull requests, across every
  repository it touches) and **Designs** (HTML mockups on a canvas, drawn and refined with a
  design agent). The Missions and Design tool boards specify them (see Sidebar destinations);
  until they exist, nothing links to them.

## Principles

In priority order:

1. **Readable measure.** The thread column is at most 820pt, and agent prose is capped at 640pt.
2. **Shape, not labels.** There are no speaker labels or avatars. A user turn is a trailing
   bubble; agent output is unboxed prose.
3. **One quiet line per stretch of work.** The tool work between two pieces of prose reads as
   one line ("Worked for 6m 40s · explored 13 files · edited 15 files · ran 22 commands"). Its
   lines, one per burst of same-kind calls, are one click away; raw arguments are behind ⌥-click.
4. **Nothing in the default view that isn't useful.** No key-hint rows, no status text that
   repeats what the thread and the sidebar row already say, no footers in menus, and nothing
   under the composer but its controls: no working directory, no hints (NWSwift).

And the rules that follow from them:

- **Flat surfaces separated by 1px lines.** Surfaces step from `bgBase` (chrome) to `bgWindow`
  (the thread) to `bgRaised` (cards, the composer, menus), with `bgSunken` for code and headers.
  Separation is a hairline, never a shadow.
- **One shadow.** `.nwPopover()` (menus, the palette, popovers) carries the system's only
  shadow. The sidebar and the side pane borrow it (`.nwFloatShadow(_:)`) only while they float
  over the window, and the switch and slider knobs have a small knob shadow. No vibrancy, no
  translucency, no gradients except the fade above the composer.
- **Honest affordances.** Never show a control that does nothing, a shortcut that isn't wired,
  or sample data in place of real data. Hide unsupported capabilities, or explain them.
- **No permission model.** Shepherd never invents approval UI, and ShepherdUI has no permission
  or approval component (NWSwift). When pi or an extension asks a question, show it as a question
  with the answers the asker offered.
- **Status is a dot or glyph plus a word.** One enum, `AgentState`, colors every status surface,
  and color is never the only signal for an actionable state.
- **Lantern means you.** The brand amber marks the primary action and anything that needs you.
  Running blue marks work in progress, links, and keyboard focus.
- **The sidebar is the primary navigation.** The command palette is a secondary jump
  surface and never the only way to reach something.
- **One primary action per surface.** A destructive action is never the ⏎ default.
- **Native controls, Night Watch styles.** A control is a Night Watch style on a native
  `Button`, `Toggle`, `Picker`, or `TextField`, so accessibility and keyboard behavior come for
  free. Where SwiftUI has no custom style (segmented, popup, slider, stepper), it is a view that
  presents itself to accessibility as the native control. Context menus are native
  `.contextMenu`. Every shared view is `NW`-prefixed, so it never collides with a system view
  (NWSwift; see Building on ShepherdUI).

## Where Shepherd departs from the boards

| Board | Shepherd | Why |
| --- | --- | --- |
| Colors as asset-catalog colorsets | A runtime theme model: `ThemeDefinition` is data (hex, `Codable`), resolved into `Color.nw` | User themes later; the roles are the contract |
| Fonts through `ATSApplicationFontsPath` / `UIAppFonts` | Registered from the package bundle at launch (`NWFonts.register()`), no Info.plist entry | ShepherdUI is a package, not an app target |
| A `ShepherdDesign` package | `Packages/ShepherdUI` | Name |
| NWSwift: test every component with `#Preview(traits: .dark / .light)` | One `#Preview` per component group, in a file per domain, drawing both appearances side by side (`NWPreviewBoth`); the preview tests render every surface in both | Both appearances in one canvas (Theme model › Building on ShepherdUI) |
| NWSwift: "every action reachable by `.keyboardShortcut`" | Every action is a menu-bar item, so the keyboard reaches it; it carries a `.keyboardShortcut` only where it has a chord (`KeybindingsStore`) | Not every action has a chord (Keyboard; Accessibility and motion) |
| NWControls: chords written ⌘ first ("⌘⇧B" in `.nwHelp`, keycaps ⌘ ⇧ B) | Apple's modifier order, ⌃⌥⇧⌘: `NWKeycap("⇧⌘B")`, "Review changes  ⇧⌘B" | The order macOS menus draw (Keyboard › Keycaps) |
| `NWStatusDot` pulsing with a SwiftUI `.animation(….repeatForever())` started in `onAppear` (NWSwift) | The glow and the spinner are Core Animation layers started at a shared clock's phase (`NWLayerGlowDot`, `NWLayerSpinner`), same look and timing | A SwiftUI-driven spinner redrew its window every display frame (Motion, Performance) |
| Running sidebar rows draw a sparkline | Running rows show elapsed time; `NWSparkline` exists but nothing uses it | Nothing records an agent's tool calls per minute |
| The thread toolbar's status pill beside the title ("Running · 0:31", "Needs you", "Idle"; NWNavigation) | No pill: the breadcrumb, then the branch chip | The thread, the composer and the sidebar row already say what the agent is doing (Principle 4; `NWThreadToolbar` has no status slot) |
| NWNavigation's toolbar: a subagents and a review toggle; TerminalSplit, TerminalPane, TerminalStates and iPadTerminal: a terminal toggle beside the side-pane button; Main: no side-pane button while the pane is closed; Subagents, SubagentsDone: no header buttons while a subagent is inspected | One side-pane button and the options menu, always there; no terminal, subagents or review toggle anywhere in the header or the pane's chrome. The terminal is ⌘J, the Pane menu and the palette (iPad and iPhone: the thread's options menu); subagents are the tray, ⌘I and the palette; the review is the side pane's Changes tab | The user's decisions (2026-09-25): "theres a single button in the top of the header to toggle the right sidebar", and "the terminal is only a toggle that pops it up from the bottom, no buttons or anything, it has nothing to do with the sidebar". Patched copies of the four terminal boards, without the header button, go to the canvas |
| The branch chip's chevron (Main, QuestionAsk and the other thread boards); no board draws what it opens | A menu: Show Changes, Copy Branch Name, and for a local agent Copy Path and Show in Finder; the tooltip has the branch, the count and the full path | A chevron must open something (honest affordances); these are what the chip is about |
| The iPad boards name the host on the chip in iPadTerminal ("build-01") but not in iPadThread | The host shows when more than one host is set up | On iPad every agent runs on another host; the name only tells hosts apart |
| Review: the side-pane button filled `bgSelected` (with a `lineStrong` ring) while the pane is open | `lanternTint` with a `lanternText` glyph, ringless, like every toolbar toggle | NWNavigation and the Controls board: a toggle is lit in lantern while its pane is open |
| Queue & steer: Steer "lands after the tool call pi is running now; the rest of that step is skipped", and "Skipped the rest of that step · N planned edits" in the thread | "Lands once pi's current tool calls finish, before its next step", and no Skipped line | pi 0.87.1 runs every call in a batch before it reads a steer: nothing is skipped, so nothing may say so (honest affordances) |
| Queue & steer: the stack and composer at radius 10, rows and fields at 7, chips at 5, the Send menu at 10 | 8 (the composer's), 6, 4, and the popover's 12 | The radius scale |
| Queue & steer: 5px gaps (the Steering pill, "Steered", "From the queue", a compact chip); 1px lines outside each 40px row, the 32px header and the card | 6 in the pill, 4 elsewhere; lines drawn inside, so three rows make a 152pt stack (the board's 157) | The space scale's 4pt steps; every card and list in the app draws its lines inside (`nwBorder`, `NWHairline` overlays) |
| Queue & steer: a custom 280pt QueueOptions popover; tooltips with keycaps | The native ••• menu (`NWOptionsMenu`); system tooltips (`.nwHelp`) | As every other ••• and tooltip in the app |
| Queue & steer: the Send menu beside the card, highlighted in `bgSelected` | Beside the card where the thread has room for it; in a narrower thread above Send, trailing edges aligned, over the trailing end of Up next while it is open; the composer menus' `runningTint` highlight | The app's column is 820pt (the boards' 620), so the room beside it runs out; the menus' one anatomy |
| Queue & steer: a row's actions take room only while it is hovered | An 82pt slot is always laid out, empty at rest | Details on hover: hovering never re-truncates the text |
| Queue & steer: message times at rest | On hover (Details on hover) | The thread's rule |
| "Pi" in board copy: Queue & steer, the question boards ("Pi is asking", "Pi asked:"; MobileQuestion, iPadQuestion), Settings ▸ Agents and the Instructions boards ("While Pi is working", "How Pi reads them", "Pi prompt") | "pi" ("pi is asking", "pi asked:"; the Settings nav's page name stays "Pi") | The app's spelling, until the rest of that redesign lands |
| Queue & steer: the queue's keys are "shown in menus and tooltips only" | Also listed under Settings ▸ Keyboard ▸ While pi is working, in the Keyboard card's order | Settings ▸ Keyboard lists every chord the app answers, and ⌘↩ is rebound there; nothing is written in or under the composer |
| Background events as in-app toasts (`.nwToast`) | A system notification when an agent finishes a turn, fails one, or is blocked on a question, or one of its subagents asks, while you aren't watching it (`AgentNotifications`; see Notifications and Live Activities) | Reaches you outside the app |
| Missions: the Missions page, the mission map, evidence review | Not built; specified in full under Missions, each part marked Not built yet | Out of scope for this pass |
| NWAgents, NWSwift: `NWInboxItem`, mission control's inbox item with a leading rule in the state's color | Not built. The Mac has no inbox (its Needs you section is not built yet; Sidebar destinations, Needs you, and Recents); iPhone and iPad list Needs you as `NWAttentionCard`s (MobileInbox, iPadInbox), with no leading rule and no missions | Out of scope for this pass |
| Controls: `.nwHelp` draws a 24pt popover-styled tip after 600ms of hover, the chord as keycaps | The system tooltip, with the chord appended as text ("Review changes  ⇧⌘B") | As every other tooltip in the app (see the Queue & steer row) |
| Controls: `.pickerStyle(.nwSegmented)`, `.pickerStyle(.nwPopup)`, `Stepper(…).nwStyle()`, `Slider(…).tint(.nw.lantern)` | Views: `NWSegmentedPicker`, `NWPopupMenu` (a native `Menu` with an `NWPopupLabel`), `NWStepper`, `NWValueSlider` (its value in mono beside it) | SwiftUI has no public custom picker, stepper, or slider style; each represents itself to accessibility as the native control |
| Controls: keycaps in menus and the palette only | Also Settings ▸ Keyboard, search fields (the board's own ⌘F), and empty states (the workspace's New agent, the terminal panel's New Terminal); never under the composer still holds | Those places teach a chord; Components and Empty workspace record the rule |
| Status & feedback: no modal alerts for agent events | One: an agent asking to delete another opens `PeerDeleteDialog` | Only the user deletes an agent, by a click (AGENTS.md › Agents never delete each other on their own) |
| NavAutomations: an Automations page with a table (When, Starts, Host, Last run, Next), filters, and New automation | The sidebar's Automations footer for this Mac; a remote host's Automations disclosure and its Details and Runs sheet | Shepherd's automations have no schedule or trigger: one is on (it starts a run when Shepherd launches) or run by hand, and nothing on the Mac creates one yet but an agent's `automation_*` tools |
| MobileAutomations, iPadAutomations: a schedule or trigger per automation ("Every day 02:00", "New issue in checkout-svc", "When CI goes green on #24"), its model and repos, a run's outcome ("Passed · 3 migrations, all reversible", "1 PR failed CI"), a CI-checks bar on a running card, and a "mission" kind | "When Shepherd starts · folder" or "By hand", an On switch and a folder on the host, the run's status word with its time ("Finished · 12h ago"), and "Running · 4m" | As NavAutomations: the host has no schedules, triggers, models, repo lists or check tracking, and a run's result is its thread (iOS: Automations) |
| MobileThread, MobileQueue, and the iPad boards (iPadThread, iPadPortrait, iPadReview, iPadSubagents, iPadQueue): each finished activity line on its own row | Two or more fold into one work-group line ("Worked for 42s · explored 7 files · edited 3 files") | Thread › Work groups: a long turn never reads as a wall of lines |
| MobileCommit: the sheet's title "Commit" | "Commit n files", as the Mac's commit sheet | The phone and the Mac share the commit form's parts |
| iPadReview: Revert file in a file's header | Not offered on iOS | The remote protocol has no revert; the Mac's local review keeps it (docs/ios/README.md › Review) |
| iPadSubagents: Fork as new agent on a finished run | Re-run and Copy transcript | Remote agents have no Fork (docs/native-subagents.md) |
| iPad sidebar footer: the person (avatar, name, "This Mac · build-01") and Settings | The hosts ("2 of 3 offline" and their names, opening Settings ▸ Hosts) and Settings | Shepherd has no accounts, only hosts (docs/ios/README.md › iPad: "a footer with the hosts and Settings") |
| ModelPicker: ⌘M opens the model picker (the ⌘M hint in its search field) | **⇧⌘M**, the hint the search field shows (from `KeybindingsStore`), and the palette's Choose model… row and the menu bar | ⌘M is the system Minimize chord |
| ModelPicker: each row's second line describes the model ("Faster, cheaper", "Fastest") | "With thinking" or "No thinking" for a model neither current nor recently used | pi's catalog carries no such description (Honest affordances) |
| NWComposer and Running: while pi runs, the placeholder "Queue a follow-up — sent when the turn ends" | The idle placeholder stays ("Follow up, or / for commands…"), as QueueSteer and QuestionAnswered draw it beside Stop | Dropped with the queue and steer redesign: ↩ queues or steers per Settings ▸ Agents, so "sent when the turn ends" would be wrong under Steer |
| Terminal: ⌃\` shows the panel, ⌃⇧\` opens a tab, ⌘K clears, ⇧⌘[ ] switch tabs | **⌘J** shows or hides it; + or ⌘D opens a tab; no clear or tab-switch chord | Every rebindable chord needs ⌘, ⌘K is the palette, and a tab is one click away |
| Terminal: the terminal on `bgBase` (Mac and iPad panels) | On `bgWindow`, the theme's terminal background | Terminal panes keep one surface everywhere |
| Terminal: rename a tab, Kill process, New terminal on This Mac, Run in terminal, send output to pi | Not built | Out of scope for this pass |
| TerminalTab · states: an exited tab stays, its output kept ("exited with an error; the output stays") | On the Mac a shell that exits closes its pane, so its tab goes at once; iOS shows the exited state until the host closes it | A process that exits on its own closes its pane (AGENTS.md › Sessions and views are separate) |
| iPadTerminal: the key row reads esc, tab, ctrl, ⌥, ↑ ↓ ← →, `\|`, `~`, `/` | esc, tab, ctrl, ⌥, `\|`, `~`, `/`, `-`, then the arrows | A row that wraps in two on a phone keeps the arrows together (`TerminalKey`); `-` for flags |
| Earlier boards, no longer on the canvas: a compose button beside the window controls and a "Jump to…" field above the sidebar tree | Neither comes back. The Search (⌘K) and Hide sidebar buttons today's boards draw there are the spec (Sidebar › Top bar, not built yet) | ⌘N (or a space's hover `+`) starts an agent, and the palette is a button, not a field |
| Subagents, SubagentsDone, SubagentCards and Review (the macOS page boards; the side-pane boards PaneStates, PaneBrowser, PaneArtifacts, PaneArtifactEdit and PaneFiles draw the same way): radius 10 cards and panes, 52pt toolbars and 48–52pt pane headers, 40pt card headers, 36pt file headers and 26pt file chips, 26–30pt buttons at radius 6–7, 13–14pt text, a 36pt ledger header with 8pt square steps, a 20pt `running` comment `+` and avatar, a comment's Edit at rest | The Night Watch boards' components (NWAgents, NWReview): radius 8, 44pt headers, 32pt file headers and 24pt chips, `s` (24pt) buttons, `ui` 12.5 text, a 32pt ledger header with 3pt bars, a lantern avatar and an 18pt lantern `+` to match it, Edit and Delete on hover | The NW boards are the system; the radius, height and type scales, and Details on hover |
| Subagents, SubagentCards: the pill carries the time ("Running · 37m 21s", "Done · 4m 02s"), a mode tag ("background", "async"), a stats row ("step 1 / 1", "78 turns · 82 tools · 922k tok") and the last call's diff and age ("+31 · 4s ago") | NWAgents' card: a plain pill; one mono line (the call by file name, the wait, or what it did with "26 tools · 12m") and the context bar; no mode anywhere | The card never grows while it runs; step, turns and tokens live in the inspector |
| SubagentCards: a running card's row of Inspect ⌘I, Steer…, Pause and Stop; a done card's files, diff, tokens and Open transcript; a failed card folded to one row with Retry and Transcript. Subagents: a done card folded to one row (its summary, diff and time) | Clicking the card inspects it; Pause/Continue, Stop and Re-run in its context menu and the inspector (which has the Steer field); a done card keeps its header and one mono line; a failed card keeps NWAgents' Open replay and Re-run | One target per card; NWAgents' labels |
| SubagentsDone: the ledger header's "45m wall · 1.5m tok · +318 −64 · 7 files"; rows with tools and questions ("1 question · 26 tools · 12m") and a glyph; the inspector's "async · claude-sonnet · 11 turns · 19 tools · 118k tok"; "Fork as new agent" | NWAgents: "all done · 45m" and the combined diff; rows "5 files · 41m" with a state dot; "claude-sonnet · 11 turns · done 11:02"; "Fork" (its tooltip says the rest) | The NWAgents board |
| Subagents: the inspector's live call row "Building swift build --target ShepherdRemote 11s" with the output's tail | "Running bash swift build…", with no time or output | A run's session file holds only finished calls: there is nothing to count or tail |
| PaneStates widths: the thread keeps 520pt, 760pt default for Files, double-click the divider for half the window, ⇧⌘O pops the pane into a window | 380pt minimum and 600 default as drawn, at most half the column, and the layout keeps 400; no double-click and no pop-out | The Navigation board's 400pt thread (`RightPaneSplit`); Files is not built; one window (Window and adaptive layout) |
| PaneStates' ⋯ menu (`SidePaneOptions`): Split below, Open pane in its own window ⇧⌘O, Reset width, then Show tabs with a check per tab | Changes' own items (Expand All Files, Collapse All Files, Copy Review as Text), then Reset Width | With Changes the only tab, a split has nothing to show below it, Show tabs nothing to hide, and a window of its own would break the one-window rule and host the review a second time: none is offered until it works (never a dead item) |
| PaneStates, Review, PaneBrowser, PaneArtifacts, PaneFiles: four tabs, Changes, Browser, Artifacts and Files | Changes alone | Only what Shepherd has (the user's decision, 2026-09-25: "dont show browser, artifacts, files, etc, only show the things we have"); the others join when they are built |
| NWThread: inline code on `bgSunken` with a 1px `lineSubtle` line, radius 4, 1×5 padding | Prose draws it in mono 12 on a `lineSubtle` fill, with no line or padding. `NWInlineCode` draws the board's form where a view holds the code (only the Component Gallery today) | A run inside `Text` cannot carry a border or padding |
| NWThread: a follow-up typed while pi works is a dashed bubble in the thread ("queued · sends when the turn ends", Edit, Send now) | It never enters the thread early: it waits in Up next above the composer and joins the thread where pi reads it | The Queue & steer boards replaced it; the host holds one queue that every viewer sees and edits |
| Settings boards: controls drawn by hand larger than the Controls board's (30pt buttons, fields and popups at radius 7 in Geist 13; a 26pt segmented control on its own track; a 180pt slider with a 4pt track and an 18pt knob; a 30×28 stepper; 22pt keycaps at radius 5; 240pt fields and a 100pt port field; a 32pt search field with a plain "⌘F"), cards at radius 10, 10pt paddings and gaps (rows, nav rows, the icon-to-name gap, under the search field), mono-free sans section labels (Geist 11/600 caps in `textSecondary`), and hexes outside the palette (`#22262a`, `#1b1e21`, `#c1c5cb`, `#767c85`, `#23272c`, `#f58a86`, `#6fd49a`) | The Controls board's components at their sizes (`NWSegmentedPicker` m, `NWPopupMenu` 200×28, `NWStepper`, `NWValueSlider` 200pt, `.nw` fields 220pt and a port 88pt, `NWKeycap`, `NWSearchField` with keycaps); the radius and space scales (cards 8, controls 6, keycaps 4; 10pt steps to 8 or 12); `.nwSectionLabel()` (Foundations' micro mono caps in `textTertiary`); the nearest roles (`lineSubtle`, `textSecondary`, `textTertiary`, `bgSelected`, `failed`, `done`) | One anatomy per control and one section label across the app; the scales and roles are the contract (SettingsAdvanced's own Update channel row already draws the Controls board's segmented control) |
| SettingsRemote: a host's state as a colored word ("connected") | A state dot plus its word, and a failed host's sentence under it | Status is a dot or glyph plus a word (Principles) |
| SettingsPi: Subagent display "Show subagent runs in the sidebar and open their inspector" | "Show subagent runs in their agent's thread, the inspector and the palette" | Subagents have no sidebar rows (Subagents); one waiting on you marks its parent's row |

Additions the boards don't have:

- **A resizable sidebar:** 232pt by default, 190–340 by dragging its edge or in Settings ▸
  Appearance, persisted, and never narrowing the main column below 720pt.
- **A paused queue** (Up next): after Stop, or a turn that failed, the queue waits: "Paused" in
  its header (why, in the tooltip), and each row's Steer now reads **Send now** (the ••• menu's
  Send all now) while pi is idle.
- **Undo for Clear the queue**, as for a single delete.
- **Keyboard focus on queued rows** (Up next): ⇥ reaches them; ↑ ↓ move between rows, ↩ edits, and
  Esc or ⇥ return to the field. The boards give a focused row only ⌥↑ ⌥↓, ⌫, and ⌘↩.
- **Show fewer** (Up next): an expanded stack collapses again, and past six rows it scrolls inside.
- **Transcript search** in the palette ("Found in conversations").
- A **quit confirmation** while agents are working.
- A **one-time notice** under the toolbar after an update moved a copy of Shepherd off the
  retired nightly channel (`NightlyMovedNotice`): an idle `NWBanner` capped at the thread's
  820pt, with Get Shepherd Nightly and Dismiss. It blocks nothing and stays until dismissed, and
  it leaves at once rather than easing the column's height, which would relay out every mounted
  layout on each frame.
- **Settings additions:** Appearance's Theme row (the theme's name), Worktrees' Merge method under
  Merge PR automatically, the Terminal page (no board draws it), Keyboard's Thread, While pi is
  working, and Window groups, the search's hits under each page, Remote's empty "No remote hosts"
  row, its Edit host form, each failed host's reason, and the listener's "Serving on port N" line,
  and Shepherd Nightly's named Nightly channel.
- **The terminal panel's empty state** ("No terminals in this thread yet." and New Terminal).
- **Thread additions** no board draws (Thread; Composer, questions, and menus): "↓ Jump to
  latest" while detached from the tail; turn jumps (⌥⌘↑ ⌥⌘↓); "Load older messages" and the
  degraded-state notices; quiet starting and resuming ("Starting pi…" only when pi is slow, history
  read from pi's session file); the framed empty thread ("New agent in `~/path`"); the "Stopped"
  note; a call's output sheet and context menu (Show Call, Review <file>, Open Output, Copy
  Output); extension widgets above the composer; the Stop all confirmation; the "Lost connection
  to the agent process." banner; several waiting questions ("1 / N") and a question's timeout
  note.
- **A confirmation before closing a terminal tab** on iOS, naming the tab and how many shells stop.

## Theme model

All design values live in **ShepherdUI**. It is SwiftUI only and holds no app state. Views
read colors from `Color.nw`, fonts from `Font.nw(_:)`, and sizes from `NW.Space`, `NW.Radius`,
and `NW.Height`, plus the app's own surface dimensions in `AppLayout`. **Never hardcode a color,
font size, or dimension in a view.**

The token boards are **NWFoundations** (every color, type style, space, radius, height,
elevation, motion, icon, and the mark, with its Swift name) and **NWSwift** (how they map onto
SwiftUI, the component inventory, the package), each drawn dark and light (NWFoundationsLight,
NWSwiftLight). A pair carries the same tokens and text; only the rendered appearance differs.
The light boards call the light variant "Day Watch"; the app has one theme, Night Watch, with
`night-watch-dark` and `night-watch-light` variants.

The canvas's older **Foundations** and **Components** boards and its `tokens.json` are Option A,
superseded by Night Watch. Take no value, name, or component from them: IBM Plex Sans and
JetBrains Mono, the 2px spacing base, 7pt and 10pt radii, 32pt sidebar rows with a 22pt indent,
a 7px status dot, the composer's and the segmented thumb's shadows, a 3px composer focus ring,
`ShepherdButton`, `AgentStatusPill`, `InlineError`'s "open Terminal mode", and the
`bg.canvas`/`accent`/`warning` role names are all gone.

A theme is pure data (`ThemeDefinition`: hex strings, `Codable`), so the built-in theme and
future user themes go through the same model:

```text
ThemeDefinition { id, name, light: ThemeVariant, dark: ThemeVariant }
ThemeVariant    { colors:   ThemeColors     // the Night Watch roles below (#RRGGBB or #RRGGBBAA)
                  syntax:   SyntaxColors    // code blocks and diffs
                  terminal: TerminalColors  // Ghostty: background, foreground, cursor,
                                            // selection, 16-color ANSI
                  pi:       PiColors }      // pi's TUI theme schema, for pi run by hand in a
                                            // terminal pane
```

- **`ThemeStore.shared`** (`@Observable`) holds the selected theme, the text scale, and the
  density. It resolves each theme once into an immutable `NWPalette` (every `Color` built when
  the theme changes) and each text scale into an `NWTypeRamp`, so a token read is a
  stored-property load.
- **Colors are dynamic:** every palette color resolves against the appearance of the view
  drawing it, so light and dark are never stored and never need a re-render.
- **Views never branch on `colorScheme` for a color** (NWSwift): light and dark come from the
  token layer. Read `colorScheme` only to force the appearance (`preferredColorScheme`) and to
  hand resolved colors to what SwiftUI doesn't draw: the Core Animation spinner and glow layers,
  the iOS terminal's UIKit view, and, through `ThemeManager`, Ghostty and the pi theme file.
- **`ThemeManager`** (app) owns only the appearance mode: System (the default; "System follows
  your Mac and switches with it."), Light, or Dark, set in Settings ▸ Appearance ▸ Mode or the
  Appearance menu. The board's rule: follow the system, and let Settings force either (NWSwift).
  `SHEPHERD_THEME=night-watch-dark` or `night-watch-light` forces one at launch (the older
  `shepherd-dark` still means dark), and Reset returns to it.
- **What `ThemeManager` pushes:** the resolved variant goes to what cannot follow appearance on
  its own. That is Ghostty surfaces (a live `setTheme`, never a remount or replay) and the pi
  theme file plus the `shepherd-active-theme` variant marker (`night-watch-dark|light`), which pi
  and editors run in a terminal pane watch. The marker's spelling is an external contract.
- **Fonts:** Geist and Geist Mono (SIL OFL, `Resources/Fonts/OFL.txt`) ship in the package
  bundle: Geist Regular, Medium, SemiBold, and Bold, each with its italic, and Geist Mono
  Regular, Medium, SemiBold, and Bold. They are registered for the process at launch on the Mac
  and iOS (`NWFonts.register()`), with no Info.plist entry (see departures). PostScript names
  are `Geist-<Weight>` and `GeistMono-<Weight>`. Terminal panes keep their own font setting.

### Roles (`ThemeColors`, read as `Color.nw.<role>`)

Values are the NWFoundations board's, as `NightWatch.swift` holds them, dark · light. The board
writes translucent roles as rgba; the theme stores them as `#RRGGBBAA`, rounded to the nearest
alpha byte: `bgHover` white at 4.5% · black at 4%, `bgSelected` white at 8% · black at 6.5%,
`lanternTint` `#f2a93b` at 13% · `#d98a12` at 13%, and each other tint its own state color at
`runningTint` 13% · 10%, `doneTint` 12% · 10%, `failedTint` 12% · 9%. The Use column is the
board's, plus where the app also uses the role.

| Group | Role | Dark | Light | Use |
| --- | --- | --- | --- | --- |
| Surfaces | `bgBase` | `#0a0b0c` | `#f2f2f0` | Sidebar, window chrome, Settings nav, the review's file strip |
| | `bgWindow` | `#0d0e10` | `#fbfbfa` | Thread, toolbar, panes, terminal panes, dialogs |
| | `bgRaised` | `#15171a` | `#ffffff` | Cards, the composer, menus, fields |
| | `bgSunken` | `#111316` | `#f5f5f3` | Code, tool output, card headers, the segmented track |
| | `bgBubble` | `#1a1d21` | `#efefec` | User messages |
| | `bgHover` | `#ffffff0b` | `#0000000a` | Row hover |
| | `bgSelected` | `#ffffff14` | `#00000011` | Selected row, the composer's focus ring |
| Lines | `lineSubtle` | `#1f2226` | `#e7e7e3` | Dividers, row separators, card borders |
| | `lineStrong` | `#2c3035` | `#d6d6d1` | Control borders, popovers, the composer |
| Text | `textPrimary` | `#e8e9ec` | `#151618` | Body, titles |
| | `textSecondary` | `#9aa0a9` | `#5f636b` | Labels, previews, descriptions |
| | `textTertiary` | `#5f656e` | `#9a9ea5` | Meta, timestamps, counts, section labels |
| | `textOnLantern` | `#17120a` | `#1a1206` | Text on a lantern fill |
| Brand and state | `lantern` | `#f2a93b` | `#e39a26` | Brand, the primary action, needs you |
| | `lanternText` | `#f7c16e` | `#945b00` | Lantern words on a tint ("ASK", "Needs you") |
| | `lanternTint` | `#f2a93b21` | `#d98a1221` | Needs-you backgrounds |
| | `running` | `#7aa7ff` | `#2f6fe0` | Running, links, focus |
| | `runningTint` | `#7aa7ff21` | `#2f6fe01a` | Running pills, menu and palette highlight |
| | `done` | `#46c37b` | `#1f9d5b` | Success, additions |
| | `doneTint` | `#46c37b1f` | `#1f9d5b1a` | Done pills, added lines |
| | `failed` | `#f0625e` | `#d9443f` | Failure, deletions, destructive |
| | `failedTint` | `#f0625e1f` | `#d9443f17` | Failed pills, removed lines, turn errors |
| Syntax (`SyntaxColors`) | `synKeyword` | `#d7a6ff` | `#8a3fb5` | Keywords |
| | `synType` | `#7ee0b5` | `#1a7f55` | Types |
| | `synString` | `#e8c07a` | `#9a6400` | Strings |
| | `synNumber` | `#9ec2ff` | `#2f6fe0` | Numbers |
| | `synFunction` | `#8fc1ff` | `#2a62c9` | Calls |
| | `synComment` | `#5f656e` | `#9a9ea5` | Comments |
| | `synVariable`, `synOperator`, `synPunctuation` | `#e8e9ec`, `#9aa0a9`, `#9aa0a9` | `#151618`, `#5f636b`, `#5f636b` | Names and punctuation: the text colors. Not on the board, which colors only the six roles above |

**Derived colors** live on `NWPalette`, not in the theme:

- `focusRing`: running at 60% (dark) / 50% (light)
- `focusDivider`: running at 34% in both appearances, for a pane divider beside the focused pane
- `popoverShadow`: `.nwPopover()`'s shadow color: black at 55% (dark), `#141414` at 12% (light)
- `scrim`: black at 30% in both appearances, behind the command palette
- `textOnFailed`: white, for labels on a `failed` fill
- `knobOn`, `knobOff`, `knobShadow`: the switch and slider knobs

**The terminal and pi palettes are derived from the roles.** Terminal panes sit on `bgWindow` with
`textPrimary` text, a `textPrimary` block cursor, and a selection on `running` at 13%
(TerminalSplit, TerminalPane; the app draws a lantern cursor and a running selection at 18% dark,
28% light, see Known gaps); each variant carries its own 16-color ANSI palette (the light one
darkened to stay readable). pi uses the same brand, state, and syntax colors, with translucent tints
flattened onto `bgWindow`, because Ghostty and pi want opaque colors.

### One status enum

`AgentState` (`running`, `attention`, `done`, `failed`, `stuck`, `queued`, `idle`) gives every
status surface its color, tint, word, and glyph: pills, dots, glyphs, step strips, banners, and
toasts each take a state (NWSwift: "All driven by AgentState"), and the spinner and the bar draw
in `running` unless given a color. The app maps its lifecycles onto it in
`AgentStateMapping.swift` (agent status, subagent runs, tool calls). Only `attention` animates:
a 1.6s glow, the dot's opacity easing 1 → 0.35 → 1, static under Reduce Motion. Draw state with
`NWStatusDot` (6pt), `NWStateGlyph`, or `NWStatusPill`, never with a view's own
`repeatForever`: the glow and the spinner run on the render server (see Motion and departures).

| `AgentState` | Word | Color | Pill fill | Glyph (`NWStateGlyph`) | App meaning |
| --- | --- | --- | --- | --- | --- |
| `running` | Running | `running` | `runningTint` | spinner | agent working, a live run or call |
| `attention` | Needs you | `lantern` (words `lanternText`) | `lanternTint` | `exclamationmark.circle` | agent blocked on a question, a run asking |
| `done` | Done | `done` | `doneTint` | `checkmark` | a finished agent, run, or call |
| `failed` | Failed | `failed` | `failedTint` | `xmark` | a failed run or call, a lost connection |
| `stuck` | Stuck | `failed` | `failedTint` | `exclamationmark.triangle` | (unused by the app today; a mission's stuck station and lane, not built: see Missions) |
| `queued` | Queued | `textTertiary` (words `textSecondary`) | none, outlined; hollow dot | `circle` | a queued or paused run |
| `idle` | Idle | `textTertiary` (words `textSecondary`) | none, outlined | `circle.fill` | an idle agent |

### Contrast rules

`ShepherdUIUnitTests` checks every built-in variant (translucent fills are painted over the
surface they sit on):

- `textPrimary`, `textSecondary`, and `textTertiary` reach 4.5:1 on `bgBase`, `bgWindow`, and
  `bgRaised`, and `textPrimary` on `bgSelected`.
- `lanternText` on `lanternTint`, each state color on its own tint (over `bgWindow` and over
  `bgRaised`), and `textOnLantern` on `lantern` reach 4.5:1.
- `lantern`, `running`, `done`, and `failed` reach 3:1 on `bgWindow` as dots and glyphs, and stay
  distinguishable from each other.
- **Documented exceptions** (the board's colors, kept; the test pins their measured ratios):
  `textTertiary` meta text (dark 3.06–3.35, light 2.40–2.69), the light state pills' words on
  their own tints (running 3.98, done 3.01, failed 3.71 over the window), the light lantern as a
  mark (2.27), and white on `failed` (dark 3.18, light 4.33).
- Every role parses, only hover, selection, and the state tints may be translucent, surfaces
  and lines stay distinct, the ANSI palette has 16 entries, the terminal background equals
  `bgWindow`, and the theme round-trips through JSON.

### Adding a theme or a role

- **A theme:** write a `ThemeDefinition` that fills every field of `ThemeColors`,
  `SyntaxColors`, `TerminalColors`, and `PiColors` for both variants (the memberwise
  initializers make the compiler enforce completeness). Add it to the list the ShepherdUI unit
  tests iterate and fix values until they pass. Then teach `ThemeManager` and the app's
  `ShepherdTheme` to resolve it for Ghostty and the pi theme file; today they resolve Night Watch
  only. Keep the variant marker's `<theme>-dark|light` spelling.
- **A role:** add a field to `ThemeColors`, a value in every theme's light and dark variant, a
  property on `NWPalette`, and a contrast rule if it carries text.

### Building on ShepherdUI

The NWSwift board is the implementation plan. ShepherdUI is its `ShepherdDesign` package
(renamed; see departures), shared by the Mac app and the iOS client:

```text
Packages/ShepherdUI/Sources/ShepherdUI/
  Tokens/       Colors (NWPalette, Color.nw), Typography (NWTextStyle, Font.nw, NWFonts),
                Metrics (NW.Space, NW.Radius, NW.Height), Motion, Elevation, AgentState,
                ThemeDefinition, NightWatch, ThemeStore, HexColor, Platform
  Resources/    Fonts/: Geist-*.otf, GeistMono-*.otf, OFL.txt (no asset catalog)
  Components/   Controls, Status, Containers, Navigation, Thread, Composer, Agents, Review,
                Dialogs, Automations, Fleet, Terminal
  Previews/     a file per domain (and its touch variants); every component in both appearances
  Diagnostics/  NWRenderProbe (debug builds only)
```

- **Tokens in Swift:** `Color.nw.<role>` (one per Foundations color), `Font.nw(.<style>)` over
  the bundled faces, `NW.Space`, `NW.Radius`, `NW.Height` (including `touch 44`), `NW.Motion`,
  and hairlines at `1 / displayScale`. No view branches on `colorScheme` for a color (Theme
  model).
- **Controls are styles on native controls:** `.buttonStyle(.nw(_:size:))` and `.nwIcon`,
  `.toggleStyle(.nwSwitch)` and `.nwCheckbox`, `.textFieldStyle(.nw)` and `.nwSearch`,
  `.progressViewStyle(.nwSpinner)` and `.nwBar`; plus `NWKeycap`, `NWCountBadge`, `NWTag`. The
  board's `PickerStyle` `.nwSegmented` and `.nwPopup` are views, `NWSegmentedPicker` and
  `NWPopupMenu`, because SwiftUI has no public custom `PickerStyle`; they present themselves to
  accessibility as the native segmented `Picker` and a native `Menu`.
- **Status:** `NWStatusPill`, `NWStatusDot`, `.nwSpinner`, `.nwBar`, `NWStepStrip`,
  `NWSparkline`, `NWBanner`, `.nwToast(item:)`, `NWEmptyState`, `.nwShimmer()`. Whatever shows a
  state takes an `AgentState` (see One status enum).
- **Thread:** prose is Markdown; inline markup goes through `AttributedString(markdown:)`
  (inline only, whitespace kept), with blocks split by the thread's own renderer. Consecutive
  calls of one kind merge into one activity line.
- **Composer and menus:** the composer's menus are overlays that float over the thread, left-aligned
  above the composer card and growing from it (`.nwTransition(.overlay, anchor: .bottomLeading)`);
  context menus are native `.contextMenu`.
- **Review:** diff lines sit in a `LazyVStack` as `NW.Height.rowCompact` rows (22pt at 100%
  Density), for fast scrolling.
- **Layout:** the Mac window lays itself out (minimum 720×600): the sidebar and the side pane
  dock when they fit and overlay below (Window and adaptive layout). The iPad client uses
  `NavigationSplitView` with `.inspector`.
- **Light and dark:** both follow the system, and Settings ▸ Appearance can force either. Every
  component has a preview in both appearances (`NWPreviewBoth` draws them side by side), and the
  preview tests render every surface in both.
- **Icons:** SF Symbols only, `.symbolRenderingMode(.monochrome)`, weight `.medium` (see Icons).
- **Keyboard:** every action is reachable from the keyboard: on the Mac as a menu-bar item, with
  a `.keyboardShortcut` whose chord comes from `KeybindingsStore` where the action has one.
  Custom controls draw their own focus ring after `.focusEffectDisabled()` (`.nwFocusRing()`).
- **iOS and iPadOS:** the same package. Controls grow their hit area to 44pt (`NW.Height.touch`,
  `.nwTouchTarget(height:)`), and fonts follow Dynamic Type through `relativeTo:`.
- **Nothing else:** no permission or approval components, and nothing under the composer but its
  controls.

**Not built yet** (NWSwift's inventory for the future boards; each surface's own section or
board holds its spec, and its parts go in a `Components/<Domain>/` folder of their own):

- Navigation: `NWSidebarDestination`, a top-level sidebar destination above the agent tree
  (NWNavigation: New thread, Missions, Designs, Automations, and More ▸; see Sidebar).
- Agents: `NWMissionNode`, `NWInboxItem`, and `NWClaimRow` (NWAgents, NWSwift; specified under
  Mission components). Experimental surfaces reuse the same parts. The iPhone and iPad Needs you
  lists (MobileInbox, iPadInbox) are built from `NWAttentionCard` instead, with no state-colored
  leading rule; `NWInboxItem` itself is not built.
- Missions map (`Components/MissionMap/`): `NWMissionMap`, `NWStation`, `NWTerminus` (MXVocab),
  `NWFlowWire`, `NWDataWire`, `NWForkBar`, `NWJoinBar`, `NWLane`, `NWFog`, `NWFrontierChip`,
  `NWOutcomeChip`, `NWPinRow`. A `Canvas` draws the wires and the stations are views on top. Layout
  is automatic: rows from time order, columns from lanes.
- Mission screens (`Components/Missions/`): `NWMissionHeader`, `NWPhaseBar`, `NWBudgetMeter`,
  `NWHostChip`, `NWChoiceCard`, the mission question card (NWSwift's `NWQuestionCard`, which needs
  its own name: the phone's agent question already has it), `NWPlannerNote`, `NWAttemptRow`,
  `NWCheckpointRow`, `NWSpendBar`, `NWTrainCard`, `NWTrainGateRow`, `NWTrainRuleRow`,
  `NWRepoTimeline`, `NWPathLockRow`, `NWContractRow`, `NWDiffAnnotation`, `NWTraceSpan`,
  `NWMergeActions` (NWMissions), `NWRollbackRow`, `NWTemplateInput`. A mission asks through
  `NWChoiceCard` lists with one planner's pick; none of it is a permission prompt.
- Design tool (`Components/DesignTool/`): `NWDesignCanvas`, `NWBoardFrame`, `NWSelectionRing`,
  `NWCommentPin`, `NWCommentCard`, `NWCommentThread`, `NWBoardActions`, `NWCanvasToolbar`,
  `NWTweakRow`, `NWTokenChip`, `NWDesignSystemChip`, `NWTokenSwatch`, `NWExportFormatCard`,
  `NWLiveLinkField`. Boards render in a `WKWebView` per frame; everything around them is native.
- iPhone extras: `NWMissionLiveActivity`, `NWMissionNotification`, `NWLaneStrip`. ActivityKit
  shows progress, and answers are `UNNotificationAction`s, so replying never opens the app.

## Typography

Geist for prose and chrome, Geist Mono for anything the agent touched (paths, commands, code,
output, counts, times), both bundled (NWFoundations). Sizes are points:

- **Mac:** sizes don't follow Dynamic Type. Every size, in the ramp or one-off, scales with
  Settings ▸ Appearance ▸ Text size (`ThemeStore.textScale`, 85–130% in 5% steps, "App chrome
  only.").
- **iOS:** the phone and iPad boards' larger ramp (the iOS column), with the Mac's weights and
  line heights except body's 1.5. Every style follows Dynamic Type: `Font.nw` builds
  `.custom(_:size:relativeTo:)` with the style's text style (display `.largeTitle`, title
  `.title3`, headline `.headline`, body `.body`, ui `.callout`, caption `.caption`, code
  `.callout`, mono `.caption`, micro `.caption2`).

`.nwText(_:)` applies a style with its line height (extra leading from the face's real metrics);
`.font(.nw(_:))` alone suits single lines.

| Style (`NWTextStyle`) | Mac spec | iOS | Board use (NWFoundations) | Also in the app |
| --- | --- | --- | --- | --- |
| `display` | Geist 28/600/1.15 | 28 | Empty states, onboarding | Settings page titles today (the Settings boards draw them at 22/600; Known gaps). There is no onboarding, and empty-state titles follow the Status board at 17/600 (`Font.nwSans`) |
| `title` | Geist 15/600/1.3 | 16 | Thread and pane titles | Dialog and sheet titles. The toolbar title and pane headers follow the Navigation board at 13/600 (`Font.nwSans(13, .semibold)`) |
| `headline` | Geist 13.5/600/1.35 | 17 | Card titles, section heads | Markdown headings |
| `body` | Geist 13.5/400/1.6 | 16/1.5 | Agent prose, bubbles | The composer field |
| `ui` | Geist 12.5/500/1.3 | 15 | Rows, buttons, controls | |
| `caption` | Geist 11.5/400/1.35 | 12 | Secondary info ("Asked 2m ago · still working") | Descriptions, footnotes |
| `code` | Geist Mono 12/400/1.55 | 13 | Code blocks, output | The review's file headers |
| `mono` | Geist Mono 11.5/400/1.3 | 12 | Paths, commands, tool rows | Diff lines |
| `micro` | Geist Mono 10.5/500/1.2 | 11 | Section labels, uppercase ("AGENTS · 19") | Counts, times. A section label is `.nwSectionLabel()`: uppercase, tracked 6% (0.06em), `textTertiary` |

- `Font.nw(_:weight:)` takes a weight for the rare emphasis the ramp lacks. `Font.nwSans(_:_:)`
  and `Font.nwMono(_:_:)` exist for the one-off sizes the boards specify (the toolbar title at
  13, row meta at 10–11, the palette field at 15). Prefer a ramp style.
- **Two prose sizes:** `NWProseSize` (the `nwProseSize` environment value) sets thread prose and
  bubbles at the ramp (`regular`) or one step smaller (`small`: body at the `ui` size). The
  subagent inspector's transcript uses `small`.
- The terminal font (family and size) is its own setting in Settings ▸ Terminal and never
  follows the chrome's text scale. The boards set the terminal in Geist Mono 12 at a 1.6 line
  height (Terminal panes); the app's default is SF Mono 12.5 today (Known gaps).

## Space, radius, height, elevation

- **Space** (`NW.Space`, 4pt grid): `xxs 2`, `xs 4`, `s 6`, `m 8`, `l 12`, `xl 16`, `xxl 24`,
  `xxxl 32`. Padding and gaps use only these steps.
- **Radius** (`NW.Radius`): `xs 4` pills, keycaps, chips · `s 6` buttons, fields, rows · `m 8`
  cards, the composer, tool groups, code blocks · `l 12` popovers, the palette, and sheets
  Shepherd draws itself (a native `.sheet` keeps the system's corners).
- **Height** (`NW.Height`): rows `rowCompact 22` (diff lines, dense lists), `row 28` (sidebar,
  tool rows, menus), `rowComfortable 36` (inbox items, ledgers), all scaled by Density and rounded
  to whole points (`NW.Height.scaled(_:)` for other row heights); controls `controlS 24` (inline
  buttons), `controlM 28` (default controls), `controlL 32` (primary actions), which never scale;
  `touch 44` on iOS. NWFoundations also names the composer's Send for `controlL`, but the
  Composer board and the Mac draw it at 28 (`NWComposerMetrics.actionSize`); iOS draws it at 32.
- **Hairlines** are 1px, not 1pt: `NWHairline`, `.nwBorder(_:radius:)`, and
  `.nwBorder(_:in:dash:)` (any shape, optionally dashed) use `NW.hairline(displayScale)`. Every
  border of a control, field, pill, keycap, banner, card, or bubble draws through them. Three
  kinds of line stay in points: the layout's dividers (pane splits and the edges of the docked
  sidebar and side pane, 1pt, because the window's arithmetic counts them), the checkbox's
  1.5pt border (the Controls board draws it heavier than its 1px lines), and the strokes of
  status dots and glyphs.
- **Elevation** (NWFoundations):
  - `.nwCard()`: flat, for panes and cards: a raised fill and a 1px line (`lineSubtle` unless
    given), radius 8 unless given. Separation is a line, never a shadow.
  - `.nwPopover()`: menus, the palette, popovers, toasts: a raised fill, a 1px `lineStrong` line,
    radius 12, and the system's only shadow, `popoverShadow` 12pt down with a 16pt radius (the
    board's `0 12px 32px`). Tooltips are the system's (`.nwHelp`), not popovers (see
    departures).
  - `.nwFloatShadow(_:)`: the popover's shadow on the sidebar or side pane while it overlays
    the window, and nothing while docked.
  - `.nwFocusRing()`: running blue at `focusRing` (60% dark, 50% light), 2pt wide, 2pt outside
    the control (a 2pt gap, then the ring), for keyboard focus only, never on a click. It turns
    off the system's focus effect (`.focusEffectDisabled()`). Every Night Watch control style
    and custom control draws it; a control left in its system style keeps the system's ring.
    `.nwFocusRing(_ visible:)` is for a field or card whose focus the caller tracks, and
    `.nwFocusRingCircle()` for icon buttons.
- **Icons** (NWFoundations, NWSwift): SF Symbols only (`Image(systemName:)`),
  `.symbolRenderingMode(.monochrome)`, weight `.medium`, 13–16pt: 14pt in icon buttons
  (`.nwIcon`). Go below 13pt only where a surface's board draws a glyph inline in a row (a
  chevron, an activity glyph, a chip's ×). Status glyphs come from `AgentState`
  (`NWStateGlyph`); never emoji. Apart from status dots and the spinner's arc, the only drawn
  marks are the crook (`NWCrook`) and the queue's glyph and grip (`NWQueueGlyph`,
  `NWGripGlyph`). The board's symbols:

  | For | Symbol | For | Symbol |
  | --- | --- | --- | --- |
  | Sidebar | `sidebar.left` | Search | `magnifyingglass` |
  | Compose (iOS; the Mac has no compose button) | `square.and.pencil` | Read | `doc.text` |
  | Send | `arrow.up` | Edit | `pencil` |
  | Stop | `stop.fill` | Bash | `terminal` |
  | Attach | `paperclip` | Grep | `text.magnifyingglass` |
  | Thinking | `lightbulb` | Warning | `exclamationmark.triangle` |
  | Check | `checkmark` | Automation | `bolt` |
  | Close | `xmark` | Mission (**not built yet**) | `scope` |
  | Subagents | `arrow.triangle.branch` | Host | `desktopcomputer` |
  | Review | `plus.forwardslash.minus` | Retry | `arrow.clockwise` |
  | More | `ellipsis` | Copy | `doc.on.doc` |
  | Disclosure, closed | `chevron.right` | Settings | `gearshape` |
  | Disclosure, open | `chevron.down` | Fork | `arrow.branch` |
  | Comment | `text.bubble` | Play, Run now | `play.fill` |

  An activity line carries one glyph per kind of work, not per tool, because calls of one kind
  merge into one line: the NWThread board draws them (Thread › Activity lines).
- **Wordmark** (`NWWordmark`, NWFoundations › Mark): the crook, then "shepherd" in lowercase
  Geist 600 in `textPrimary`. The crook is `lantern` on any background: `NWCrook`, drawn on a
  24pt grid with a 2.4 stroke, round caps and joins. `.large`: a 30pt crook, 26pt text at −3%
  tracking, 10pt apart. `.small`: a 16pt crook, 14pt text at −2% tracking, 6pt apart. It reads
  "Shepherd" to VoiceOver, and the crook alone is hidden from it. No shipped surface shows the
  wordmark yet (the Component Gallery does); `NWCrook` tops an `NWEmptyState` (unless
  `showsMark` is false) and the iOS About row.
- **App icon** (`App/AppIcon.icon`): always dark, in both appearances, with no light or tinted
  variant: a lantern in a field, the crook in `lantern` (a 2.2 stroke, its 24pt box at 40/72 of
  the tile) under a radial lantern glow (35%, clear by 70%) toward the upper right, on
  `#0d0e10`. **Shepherd Nightly** (`App/AppIconNightly.icon`) trades the lantern glow for a
  crescent in moonlight: a `textPrimary` crescent in the upper right and a `textPrimary` glow
  (22%, clear by 70%) toward the upper left, on the same black, so the two apps tell apart in
  the Dock and ⌘Tab.

## Motion

Shepherd moves the way a native Mac app does: things come from somewhere, go somewhere, and
never jump, and nothing moves for decoration. `NW.Motion` (`Tokens/Motion.swift`) holds every
motion. The Foundations board's durations are the anchors (hover 120ms, panes 180ms, sheets
240ms, the glow 1.6s, the spinner 1s, the skeleton 1.4s), and every one-shot motion runs on a
SwiftUI spring at its anchor.

**Why springs.** A spring keeps its velocity when a change is interrupted, so a hover flicked in
and out, or a pane toggled twice, retargets from where it is instead of restarting. A spring's
duration is perceptual: at its anchor a change reads as done (98.6% of the way for `.smooth`), and
the last fraction of a point settles by about 1.7× the anchor. Anything that moves layout or
slides from an edge is critically damped (`.smooth`, no overshoot), so a pane never pulls away
from the window's edge and a row never overshoots its slot. Only overlays (`.snappy`, 0.6%
overshoot as they grow from their anchor) and the confirmation pop (`.bouncy`, 4.6%) bounce.
`MotionTests` (ShepherdUI) pins all of this.

| Motion | Anchor | Curve | For | Comes and goes by | Under Reduce Motion |
| --- | --- | --- | --- | --- | --- |
| `hover` | 120ms | `.smooth` | hover and press fills, focus rings, a control's color, details shown on hover (a message's time, a turn's footer) | fading | unchanged |
| `content` | 120ms | `.smooth` | a value or label changing in place: counts, status words, an icon | cross-fading (`nwContentTransition`) | unchanged; rolling digits and symbol swaps cross-fade |
| `disclosure` | 180ms | `.smooth` | expanding and collapsing in place, the chevron turning | a 6pt nudge from the top, fading | a 120ms cross-fade |
| `list` | 180ms | `.smooth` | rows arriving, leaving, reordering | a 6pt nudge, fading | a 120ms cross-fade |
| `pane` | 180ms | `.smooth` | the side pane, the sidebar (docked or overlaid) | sliding from its edge, opaque | a 120ms cross-fade in place |
| `overlay` | 180ms | `.snappy` | the palette, composer menus, popovers | growing from 96% at its anchor, fading | a 120ms cross-fade |
| `sheet` | 240ms | `.smooth` | in-window sheets, a whole-window swap (Settings), toasts | rising from its edge, fading | a 120ms cross-fade |
| `emphasis` | 240ms | `.bouncy` | a small confirmation pop (viewed, copied, sent) | popping from 85% | nothing |
| `scroll` | 240ms | `.smooth` | turn jumps, revealing a row | — | instant |
| `glow` | 1.6s | ease-in-out, repeating | attention only: the dot's opacity 1 → 0.35 → 1 | — | static |
| `spin` | 1s | linear, repeating | running work: one turn a second | — | static |
| `shimmer` | 1.4s | ease-in-out, repeating | loading placeholders: opacity 0.55 → 1 → 0.55 | — | static |

The glow, the spinner, and the shimmer are clock-driven (`NWPhase`), so Reduce Motion can change
while they are on screen. The spinner and the glow are render-server animations: Core Animation
turns the arc and pulses the dot on their own layers (`NWLayerSpinner`, `NWLayerGlowDot`),
started at the clock's phase so every one moves in step, and one on screen costs the app no
frames (drawn by a SwiftUI timeline, a single spinner redrew its window on every display frame;
in an off-screen test window, whose host also relaid out tens of thousands of times a second,
that was most of a core in a debug build). The shimmer stays a timeline. None of them
moves under `nwMotionPaused` (see Performance). A Reduce Motion cross-fade still eases the
layout a change moves (the rows under an opening disclosure, a column a pane narrows) over its
120ms; only what arrives or leaves stops travelling.

**Applying motion.** Never write a duration or a curve in a view: an ad-hoc
`withAnimation(.easeOut(duration: 0.15))` is a bug, like a hardcoded color.

- **State a view model or store changes** (a pane opened from a menu, the palette from ⌘K, a row
  a server broadcast adds): the view attaches the motion, `.nwAnimation(_:value:)` on the
  container and `.nwTransition(_:edge:)` on what comes and goes, so every path that changes the
  value animates the same way.
- **State an action changes** (a click, a key): `withNWAnimation(_:_:)`, which reads Reduce Motion
  from the system; its `completion:` form fires once the motion has finished.
- **Content changing in place:** `.nwContentTransition(_:)` (`.numeric`, `.interpolate`,
  `.symbol`, `.crossFade`) with `.nwAnimation(.content, value:)`.
- **A confirmation:** `.nwPop(trigger:)`, or `.symbolEffect(.bounce, value:)` on an SF Symbol.
- An overlay grows from its anchor: `.nwTransition(.overlay, anchor: .bottomLeading)` for the
  composer's menus, `.top` for the palette.

**What never moves.** `.nwInstant()` drops the animation a change arrives with (an ancestor's
`nwAnimation`, a `withNWAnimation`) for its subtree; motion attached inside the subtree still
runs. Put it on what must not move, as close to it as possible.

- **Switching agents** is a visibility flip, and **keyboard navigation** (⌘1–9, ⌘↑/↓, a palette
  or menu highlight, j/k in the review) lands at once.
- **Terminal surfaces** never change size frame by frame. SwiftUI resizes a hosted NSView on every
  frame of an animated layout change (about 70 times for one 180ms pane), and for Ghostty each is
  a PTY resize. With `.nwInstant()` on the terminal view it takes its new size once while
  everything around it moves; `MotionProbeTests` pins both.
- **Streaming text** appends without motion; a finished part may fade in once. Clock text
  (elapsed times) ticks without rolling.
- **Long lists** animate what changed, never the whole list: a thread's `LazyVStack` must not
  animate every row when one turn arrives.
- **Columns take their new width at once** while a pane or the sidebar slides beside them: the
  thread beside a docked side pane, the main column beside the docked sidebar, and split
  panes. A long thread relaid out on every frame of a slide drops frames (measured in a debug
  build: gaps up to 55ms beside one thread and 171ms with five mounted layouts, against under
  9ms for plain content), so the column snaps as the motion starts and the pane slides into or
  out of the room. Window resizes, divider drags, and docked ⇄ overlaid flips never animate.
- **Selection** changes no row, so it lands at once; only rows arriving, leaving, reordering,
  or disclosing animate a list. Each agent's toolbar has its own identity, so switching never
  animates one agent's status or branch chip into another's.

## Performance

A list is as fast with three hundred rows as with thirty: it builds the rows on screen, and a
change redraws the rows it changed. `ListPerformanceTests` pins each rule below with a count of
row bodies (`NWRenderProbe`), which a slower machine doesn't change, and
`SHEPHERD_PERF_REPORT=1 swift test --filter ListPerformanceReport` prints each list's timings
against a large fixture (300 agents in 40 spaces, 1,000 palette results, a 2,000-line diff and a
300-file review, a 500-turn thread, 200 subagent runs, 2,000 folders).

- **Anything that can outgrow a screen is lazy.** The sidebar tree, the palette's results, the
  thread and the inspector's transcript, the review's diff and file strip, the run ledger, and
  the directory and model lists are `LazyVStack`s or `LazyHStack`s with stable ids. Eager stacks
  are for lists bounded by design (Settings rows, a dialog's checklist, a composer menu). A lazy
  stack in a height-capped, fixed-size scroll view still hugs a short list (the palette does).
  A list inside one of the thread's own rows is measured before it is nested: the run ledger
  builds lazily (about 6 ms a scroll step, against one 150 ms build for 200 runs), while a
  300-file changes card cost 20 ms a step nested and stays eager (one 250 ms build).
- **One view per row.** In a lazy `ForEach`, each element makes exactly one view: wrap an `if` or
  a `switch` in a container. A row that could be nothing (`if … else if …` with no `else`) makes
  SwiftUI build every row to count them, on every update: a 500-turn thread built 1,000 rows per
  streamed chunk until its rows were wrapped.
- **Rows are plain `Equatable` values.** Closures stay out of `==`. The highlight or the
  selection reaches a row as a `Bool`, so moving it redraws the row it leaves and the row it
  lands on; hover lives in the row itself. A store or the view model derives the rows once per
  change (`SidebarTree`, `PaletteResults`, `DirectoryFilter`, the review's row cache): no
  filtering, sorting, or formatting in `body`.
- **A derivation is one pass over its inputs.** Group a collection once
  (`sidebarAgentsBySpace`) rather than filtering all of it for each group, and read what is
  memoized (the space forest) rather than building it again for a selection. At 1,500 agents in
  200 spaces a status report took 59 ms and a selection 57 ms until both were.
- **Rows are cheap to build**, since scrolling builds them. Platform-backed modifiers cost most:
  one drop target covers the sidebar (`SidebarDropZone`, fed the frames the rows on screen
  register) instead of one per row, and a control that shows only on hover (a diff line's `+`)
  is built only while hovered, in a slot that is always laid out.
- **Motion never scales with the list.** A list's motion watches a small key (a layout count, the
  rows' ids), never the rows themselves, and rows scrolled back into a lazy stack are simply
  there: an entrance plays only for what arrives while the list is on screen (`nwArrival`,
  `nwRunArrival`).
- **Motion no one sees costs nothing.** A layout the workspace keeps mounted behind the visible
  one sets `nwMotionPaused`, and a continuous motion pauses while its view is off screen
  (between `onDisappear` and `onAppear`: a lazy stack keeps a row it let go of for a while). A
  restored workspace of twelve agents drew about 6,000 spinner frames every 4 s idle until they
  did (about 4 s of main-thread CPU in an off-screen test window); `IdleCostTests` counts the
  frames.
- **Motion on screen runs on the render server.** A spinner or a glow is a Core Animation animation
  on a layer (see Motion), never a view redrawn per frame: one spinner drawn by a timeline cost 2.8
  s of main-thread CPU every 3 s in an off-screen test window, and now costs what an empty window
  does. `IdleCostTests` checks that one turning and one glowing draw no frames and never lay the
  window out.

## Density and row settings

Settings ▸ Appearance ▸ Layout has two independent row controls (SettingsAppearance). The
NWFoundations heights are their 100% values:

- **Sidebar rows** (`AppSettings.sidebarRowDensity`, an `NWDensity`): a segmented Compact ·
  Standard · Comfortable, captioned "Compact 22 · Standard 28 · Comfortable 36 pt, for the
  sidebar and menus.", default Standard. `RootView` sets it on the environment
  (`.nwDensity(_:)`). The sidebar's rows and the command palette's rows and placement read it,
  and use it as a minimum height, so larger text still fits. Compact rows set titles at 12pt
  instead of 12.5 (`NWDensity.rowTitleFont`).
- **Density** (`AppSettings.uiDensity`): a slider from 80 to 150% in 5% steps, default 100%,
  captioned "Row heights across the sidebar and chrome. Lower fits more agents." It multiplies
  every row height (`NW.Height.row…`, so the sidebar and palette rows above too), the Settings
  rows and nav, the ledger rows, and the diff's lines and fold rows, rounded to whole points.
  Control heights never scale.

Text size, beside them, scales type only (Typography).

A sidebar row is therefore its density's base height × Density. `NavigationTokenTests` and
`TokenTests` (ShepherdUI) pin the heights, and `SidebarRowSettingTests` the setting.

## Window and adaptive layout

```text
┌──────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ ● ● ●            │ Space / Title  ⧉ pi/branch ●3 ⌄       ◫  ⋯   │ ± Changes 4   ⋯  ×   │
│ THIS MAC     19  ├──────────────────────────────────────────────┼──────────────────────┤
│ ⌄ Shepherd    8  │         820pt thread column                  │ side pane:           │
│   ● agent   ASK  │                       ┌──────────────┐       │ its tabs, or the     │
│   ● agent    4m  │                       │ user bubble  │       │ subagent inspector,  │
│   ○ agent        │                       └──────────────┘       │ 600pt (min 380, ≤ ½) │
│ HORIZON          │   agent prose, 640pt measure                 │                      │
│   ● Unreachable  │   ✎ Edited 4 files  +149 −63  ›              │                      │
│                  │   ┌ composer ──────────────────────────┐     │                      │
├──────────────────┤   └────────────────────────────────────┘     │                      │
│ Automations    1 │                                              │                      │
└──────────────────┴──────────────────────────────────────────────┴──────────────────────┘
```

- **One window.** `ShepherdMacApp` declares a single `Window` scene named for the edition
  ("Shepherd", or "Shepherd Nightly") with a hidden title bar; window tabbing is off, and closing
  the window leaves the app and every agent running (the Dock icon brings it back). The window has
  no title other than the toolbar's.
- **Size** (`AppLayout+Navigation.swift`; NWNavigation): minimum 720×600 (`windowMinWidth`,
  `windowMinHeight`), default 1440×900. The window controls stay at macOS's standard position
  (NWNavigation: "window controls at the standard macOS position"); the board draws them in the
  sidebar's 44pt top bar, 14pt in and 8pt apart.
- **Layout** (NWNavigation's window diagram): the sidebar sits on `bgBase` and runs behind the
  window controls; the main column sits on `bgWindow`, with the 44pt toolbar on top. A docked
  sidebar's trailing edge is a 1pt `lineSubtle` divider (`AppLayout.dividerWidth`) with a 9pt drag
  handle centred on it (`resizeHandleWidth`). There is no tab bar and no status line. An agent's
  layout is its thread with its terminal panel under it (Terminal panel, below). The thread column
  is at most 820pt (prose 640, bubbles 600), and the composer is exactly as wide as the column
  (Thread). Pane dividers are 1pt `lineSubtle`, tinted `focusDivider` where they border the focused
  pane (between split terminals the TerminalPane board draws `lineStrong`; Known gaps); dragging one
  keeps each side at least 160pt (`splitPaneMinSpan`), between 15% and 85%.
- **Switching agents flips visibility; it never remounts.** Every mounted layout stays in the
  view tree, and hidden ones are `opacity(0)`. This is what makes switching instant.

**Adaptive rules** (`ShellLayout`, pure and unit-tested in `ShellLayoutTests`):

- **Sidebar.** It docks while the main column keeps 720pt beside it (`mainColumnMinWidth`),
  narrowing to fit (to no less than 190pt). In a window narrower than that allows (190 + 1 + 720 =
  911pt; the board's "below ~911pt the sidebar hides and can overlay"), it hides on its own, and ⇧⌘S
  or the toolbar's sidebar button shows it as an overlay: its width, at most the window width minus
  48pt (`sidebarOverlayMargin`), over the workspace, with a vertical hairline on its trailing edge
  and the float shadow (`.nwFloatShadow()`). Picking a row or clicking outside closes the overlay,
  and a resize that crosses the fit point closes it at once. ⇧⌘S in a wide window hides and shows
  the docked sidebar. Either way it slides from the leading edge (`.pane`) while the main column
  takes its new width at once rather than easing (easing it would relay out every mounted layout on
  each frame); a window resize that hides or docks it is instant.
- **Toolbar inset.** While the sidebar is not docked, the toolbar's content moves a further 70pt
  in to clear the window controls (none in full screen) and leads with a sidebar button.
- **Side pane** (its tabs, or the subagent inspector over them, `RightPaneSplit`; PaneStates,
  NWNavigation). It always sits at the window's trailing edge beside the agent's whole layout:
  the thread and the terminal panel under it narrow together, and the dock rule measures the whole
  main column, never one side of a split. It docks while the main column is at least 781pt
  (layout 400 + 1 + pane 380): 600pt by default, at least 380 (PaneStates; under 480 the tabs
  drop their labels), at most half the column, and the agent's layout always keeps 400
  (`threadMinWidth`). Narrower, the pane overlays the layout from the trailing edge with the popover
  shadow. Its leading edge is the drag handle (9pt hit area, adjustable with VoiceOver in 40pt
  steps), and the width persists app-wide (`shepherd.rightPaneWidth`). No width is ever negative. It
  slides in from the trailing edge (`.pane`), and its content cross-fades when a tab and the
  inspector swap.
- **Palette:** 620pt wide, or the window minus 16pt margins, and never taller than the window
  leaves room for (`NWPaletteMetrics.placement`).
- **Composer:** in a narrow thread the chips drop their words ("/" alone, the thinking level
  alone) instead of truncating mid-word (`ViewThatFits`).

## Surfaces

### Sidebar

`SidebarView` (`SidebarView.swift`, remote sections in `RemoteSidebarSection.swift`) on `NWSidebar`:
232pt on `bgBase` by default, and it keeps its width when the side pane opens (NWNavigation).

**Not built yet.** The boards draw a different sidebar: fixed destinations (New thread ⌘N,
Missions, Designs, Automations, More), then Needs you, then Recents, and an account footer
(NWNavigation, NavNewThread, NavMissions, NavDesigns, NavAutomations, NavHosts, and every
full-window macOS board). It is specified in full under Sidebar destinations, Needs you, and
Recents, below.

Today the Mac's sidebar is the tree this section describes: This Mac and each remote host as
sections, spaces as disclosure rows, agents nested beneath them, and Automations as the footer. The
row anatomy, the states, the density, and the width are the boards' and apply to both.

The tree is one lazy list (`SidebarTree`): a fleet runs to hundreds of rows, only the rows on screen
are built, and each row is a plain value compared before it redraws.

- **Top bar (44pt, `NWSidebarMetrics.topBarHeight`):** room for the window controls, as tall as
  the toolbar beside it: it drags the window, and the tree starts beneath it with the first
  section's 12pt top padding. **Not built yet:** the boards put two 26pt circular icon buttons at
  its trailing end, 4pt apart with 8pt trailing padding, each a 14pt `textSecondary` glyph: Search
  (a magnifying glass, "Search (⌘K)", opens the palette) and Hide sidebar (`sidebar.left`, ⇧⌘S).
  Today the top bar holds nothing else: ⌘K and the menus open the command palette, ⇧⌘S hides the
  sidebar, and ⌘N, a space's hover `+`, the palette, and the menus start an agent.
- **Sections** (`NWSidebarSection`): the label in micro mono caps (`.nwSectionLabel()`: 10.5,
  uppercase, tracked as Typography says, `textTertiary`; at 70% opacity while folded) with a
  trailing count in micro `textTertiary`, padded 12pt above, 8pt at the sides, and 4pt below.
  Clicking the label folds the section. With remote hosts configured, hovering a header shows its
  machine chord (⌃⇧n) in micro tertiary before the count. A header's detail is a count, or a word in
  Geist 11 medium colored by its tone.
  1. **This Mac**, with its agent count and a hover `+` for New Space…. With no spaces while a
     host's section follows, a quiet status row says "No spaces" with New space….
  2. One section per remote host. Connected: its agent count, or "n need you" in `lanternText`
     (blocked agents plus subagents asking), and a hover `+` for a new space on the host. Otherwise
     one status row (`NWSidebarNoticeRow`: a dot, the words in the row's title font in
     `textTertiary`, and a small ghost button) stands in for its spaces: "Connecting…" (running
     dot), "Unreachable" or why the host refused ("Token refused", "Update needed", "No token",
     "Token locked") with Retry (failed dot), or "Off" with Connect (hollow dot). The three
     cross-fade in one slot as the connection retries. A connected host with automations ends with
     an **Automations** disclosure under its spaces (a space's row: its count, or how many runs wait
     on you), closed by default and remembered per host.
  3. **Automations** as the footer (`NWSidebarFooter`), behind a hairline and hidden while empty: a
     12pt `bolt` in `textSecondary`, "Automations" in `ui` `textSecondary`, and a count badge
     (`NWCountBadge`) that turns `attention` while an automation's agent needs you, padded 14pt at
     the sides and 8pt above and below. Clicking it discloses the automation rows.
- **Spaces** (`NWSidebarDisclosureRow`): a 9pt semibold chevron in `textSecondary` that turns 90°
  while open, an 8pt gap, the name in the row font at medium weight, then a `⎇n` worktree count in
  micro `textTertiary` and, in `lanternText`, how many questions wait on you (blocked agents plus
  subagents asking; `SidebarAttention`), else the agent count. Clicking toggles the space; it has no
  view of its own. A hover `+` (an 18pt `.nwIcon` with an 11pt glyph, `AppLayout.sidebarPlusSize`)
  starts a new agent in the space. Nested projects indent by path containment, and agents nest
  beneath their space.
- **Rows** (`NWSidebarRow`): the density's height (Compact 22 · Standard 28 · Comfortable 36, each ×
  Density; see Density and row settings), radius 6, 8pt leading padding plus 14pt per nesting level,
  and a 9pt gap after the dot. Titles are `ui` (12.5) regular, 12 in Compact rows, in `textPrimary`.
  The look follows the agent's state (NWNavigation's `NWSidebarRow` sample: running, needs you,
  selected, idle, stuck, hover):
  - A 6pt dot: `running` blue, `done` green, `failed` red (a finished turn that failed), a hollow
    1pt `textTertiary` ring while idle, and `lantern` glowing (1.6s) while it, or one of its
    subagents, needs you.
  - **Stuck: not built yet.** The board's stuck row is a `failed` dot with how long it has been
    stuck ("14m") in mono 10 `failed` trailing (`AgentState.stuck`, `.elapsed(since:tone: .stuck)`).
    `NWSidebarRow` can draw it, but nothing in the app detects a stuck agent, and the boards don't
    say what counts as stuck.
  - `⎇` (micro, `textSecondary`) marks a worktree agent. The title truncates at the tail, with the
    full title (and the worktree branch) in a tooltip.
  - Hover is `bgHover`; selected is `bgSelected` with the title in semibold.
- **Trailing slot** of an agent row, in priority order (`SidebarAgentRowModel.accessory`):
  1. the ⌘-digit badge while ⌘ is held ("⌘3", micro `textTertiary`)
  2. "ASK" in mono 10 `lanternText` while it, or one of its subagents, needs you
  3. elapsed time while working ("4m", counting live in mono 10 `textTertiary`). The board draws a
     running row's sparkline here (28×12, `running`); Shepherd shows the time instead (see Where
     Shepherd departs from the boards).
- **Subagents have no rows.** They live in their agent's thread (cards, the runs strip, the
  ledger, and the inspector; see Subagents below) and in the palette. A subagent waiting on you
  surfaces through its agent's row, which takes the needs-you dot and "ASK", and counts toward
  its space's and host's needs-you counts, so the row to click is always marked. Live and
  finished subagents leave the agent's row as it is.
- **Automation rows:** the automation's name, and its run's state: "running" (a run whose pi is
  still starting included), "ASK", "done", "failed" (a `failed` dot: the run's last turn ended in an
  error), or "stopped" (a hollow dot, not selectable). Clicking a row opens its run's thread, live
  or finished. Live follows the host's own rule (`AutomationRun.isLive`, read from the run log's
  open run), so a run reads done only once a turn has settled. The context menu has Stop while the
  run is live, else Run Now, and Delete Automation. Run Now replaces a done run once the new run
  exists: a done run on screen hands the workspace straight to the new run's thread, and one off
  screen leaves the selection alone. A refused Run Now (a run live or still starting) shows
  `ActionErrorDialog`.
- **A remote host's automation rows** (`RemoteSidebarSection.swift`) nest one level under its
  Automations disclosure with the same dots and words, plus "off" for one that does not start with
  Shepherd. A row dims to 55% while a change to it waits on the host. Clicking a row opens its
  run's thread, or its details while it has none. The context menu has Stop while its run is live,
  else Run Now, a Starts with Shepherd check, Details and Runs…, and Delete Automation; on a host
  from before automations over the remote protocol the menu says why it is read-only and disables
  them. Details and Runs… is a sheet (`RemoteAutomationSheet`, NavAutomations' detail pane; see
  Automations page below):
  - the title is the name, and the subtitle "Starts a thread on <host> each run."; on a read-only
    host the sheet's status line says why
  - the On switch with what it means ("Runs when Shepherd starts on <host>", or "Runs only when you
    run it"), then Status, Host and Folder rows (`NWFactRow`, host and folder in mono)
  - the prompt (`NWAutomationPrompt`)
  - the latest fourteen runs as bars as tall as each took (`NWRunBars`: done green, asked lantern,
    interrupted failed, stopped tertiary), and every run the host kept under "Recent runs"
    (`NWRunRow`), a run opening its thread while that thread exists. Before the runs arrive it says
    "Reading runs…"; with none, "No runs yet."; from a host that can't list them, "Runs are not
    available from this host."
  - its footer is Close and Run Now, with Open Run while the last run's thread is there, or Open Run
    and Stop while a run is live. An automation removed on the host while the sheet is open leaves
    "This automation is no longer on the host." and Close.
- **Width:** 232pt by default, 190–340, by dragging the trailing edge (a 9pt handle, adjustable
  with VoiceOver in 16pt steps) or in Settings ▸ Appearance. It never narrows the main column
  below 720 and keeps its width while the side pane is open.
- **Interaction:** rows are tap views with button traits and accessibility actions, so they can
  also be dragged to reorder (with a 2pt running drop line, `NWDropIndicator`, at the row's top
  or bottom edge). Only drags that started in this sidebar qualify. Hover `+` glyphs are real
  labeled buttons (and always present for VoiceOver). Hovering never moves or resizes anything:
  the machine chord and the `+` are always laid out and only fade in, and the `+` takes the
  count's slot (a header's floats over it, since it is taller than the label). Keyboard
  selection (⌘1–9, ⌘↑/↓, ⌃⇧digits) scrolls the row into view.
- **Context menus:**
  - Spaces: New Agent, Rename…, New Worktree… and Import Existing Worktree… (git repositories
    only), Remove Space….
  - Agents: Rename…, Review Changes, then Finalize Worktree… and Delete Worktree Agent… for a
    worktree agent, or Delete Agent.
  - Remote agents: Rename…, Finalize Worktree… (worktree agents), Review Uncommitted Changes,
    Review PR Changes, and Delete Agent or Delete Worktree Agent….
  - Host headers: Check Worktree Operation… (one per pending operation, first), New Space…, and
    Reconnect.
- **Motion:** rows arriving, leaving, reordering, and disclosing animate `.list` (an agent row under
  its space `.disclosure`), whatever changed them: a broadcast, a drop, a click, a reveal. Selecting
  a row changes no row, so it lands at once. Counts roll (`.numeric()`), a count and a word
  cross-fade in one slot, and a status report or a settled name changes only its row, in place
  (`.content`).

### Sidebar destinations, Needs you, and Recents

**Not built yet** on the Mac (the iPad's `PadSidebar` has most of it). This is the sidebar every Mac
board draws (NWNavigation, and the sidebars of NavNewThread, NavMissions, NavDesigns, NavAutomations
and NavHosts). It is 232pt on `bgBase`, keeps its width when the side pane opens, and has four parts
from top to bottom, each following Settings ▸ Appearance ▸ Sidebar rows. Standard values are given
first and Compact in parentheses; the boards draw no Comfortable sample.

- **Top bar (44pt):** the window controls, then Search (⌘K) and Hide sidebar (⇧⌘S) as 26pt
  circular icon buttons (see Sidebar › Top bar).
- **Destinations** (`NWSidebarDestination`, to be added to ShepherdUI's Navigation components;
  NWNavigation shows `NWSidebarDestination(.missions, isSelected: true)`). They sit in a stack with
  1pt gaps, padded 2pt above and below and 8pt at the sides. **Destinations never move:** their
  order is fixed and they never reorder or hide. Each row is 30pt (24), radius 8 (`NW.Radius.m`),
  padded 8pt (6) at the sides, with a 20pt icon slot, a 9pt gap (7), and the title in Geist 13 (12)
  regular `textPrimary`. The icons are 15pt (13) strokes in `textSecondary`. Hover is `bgHover`; the
  selected destination is `bgSelected` with its title in semibold and its icon in `textPrimary`. In
  order:
  1. **New thread**: a `plus` glyph (12pt) in a 20pt `bgSelected` circle, and its chord trailing as
     keycaps (`NWKeycap`, "⌘" "N", 18pt, read from `KeybindingsStore`). It opens the New thread page
     (below).
  2. **Missions**: a folded-map glyph. It opens the Missions page.
  3. **Designs**: a pen-nib glyph. It opens the Designs page.
  4. **Automations**: a `bolt`. It opens the Automations page.
  5. **More**: a chevron in `textTertiary`, pointing right while closed and down while open. It
     discloses Hosts (a display glyph), Design systems (a palette), Pi extensions (a puzzle piece),
     and Archive (an archive box). These are the same rows indented to 22pt leading padding. Hosts
     carries "n offline" in mono 10 `failed` while a host is unreachable (NavHosts: "1 offline").
     Design systems, Pi extensions and Archive are pages no board draws yet.
- **Needs you** (`NWSidebarSection(.needsYou, count:)`): it appears only while something waits on
  you, of any kind (a thread's question, a subagent asking, a mission's question, an automation run
  that asked). The header is "Needs you" in Geist 11.5 medium `lanternText` with the count trailing
  in mono 10.5 `lanternText`, padded 14pt (10) above, 4pt below, and 8pt (6) at the sides. Each row
  is 28pt (22), radius 8, padded 8pt (6), with a 14pt leading slot and a 9pt (7) gap. The slot holds
  the kind: a thread's glowing 6pt `lantern` dot, or the kind's 13pt (11) glyph in `lanternText` (a
  mission's map). The title is in the row font, truncating at the tail. The reason trails in mono 10
  `lanternText` ("retention?", "approve plan"; the iPad's `FleetAttention.reason`: "asked you", or
  the subagent's name). Newest first.
- **Recents** (`NWSidebarSection(.recents)`): every kind (threads, missions, designs, automation
  runs) in one list, newest first. The header is "Recents" in Geist 11.5 medium `textTertiary`,
  spaced like Needs you. The rows are the same as Needs you's. The leading slot is a thread's state
  dot (running blue, done green, failed red, hollow while idle) or the kind's glyph in
  `textTertiary` (a mission's map, a design's pen nib, an automation's bolt). The selected row is
  `bgSelected` with its title in semibold. The trailing slot holds one of:
  - a running thread's live sign (the board's 28×12 sparkline in `running`; Shepherd shows elapsed
    time, see departures)
  - "done" for a finished mission or automation run, in mono 10 `textTertiary`
  - "n boards" for a design, in mono 10 `textTertiary`
  - a remote host's name as a tag: mono 10 `textTertiary`, padded 4pt at the sides, with a 1pt
    `lineSubtle` border at radius 4 ("horizon"). Threads on this Mac carry no tag.

  An item waiting on you is in Needs you and not in Recents. The list takes the rest of the column
  and clips at the bottom.
- **Account footer:** behind a hairline, padded 10pt above and below and 12pt at the sides, with a
  10pt gap. It holds a 26pt `bgSelected` circle with the initial in Geist 11.5 semibold, the name in
  `ui` medium over the hosts in mono 10 `textTertiary` ("This Mac · build-01"), and a Settings gear
  as a 26pt icon button at the trailing end (⌘,). Shepherd has no accounts, so whose name this shows
  is undecided. The iPad's footer shows the hosts and Settings.
- **Keyboard and VoiceOver** follow the tree's rules: rows are buttons with labels, and hovering
  moves nothing. The shared model is `FleetModel` (`ShepherdRemote/Fleet.swift`), whose `needsYou`,
  `recents`, and `offlineSummary` the iPad sidebar already draws.

### Toolbar

`ThreadHeader` (`ThreadHeader.swift`) on `NWThreadToolbar`, placed by `WorkspaceHeaderView`
(`RootView.swift`); Main, Review, QuestionAsk and PaneStates draw it.

- **44pt** (`NWToolbarMetrics.height`) on `bgWindow` with a hairline beneath, 14pt leading and 8pt
  trailing padding, unified with the title bar (it drags the window). Its items sit 10pt apart.
  The trailing buttons sit 4pt apart as 28pt `.nwIcon` circles with 14pt `textSecondary` glyphs.
- **From left to right:**
  - the sidebar button (`sidebar.left`, "Show sidebar") while the sidebar is not docked
  - the breadcrumb, 8pt apart: the space in Geist 13 `textSecondary`, a `textTertiary` "/", then
    the agent's title in Geist 13 semibold `textPrimary`, truncating, with "space / title" in its
    tooltip. A remote agent's space is its space on the host (else the host's name); the chip
    names the host. When the toolbar can't hold everything at full length, the space and its "/"
    go first (`ViewThatFits`), then the chip's branch and the title truncate.
  - the branch chip (`NWBranchChip`, from `AgentBranchLabel`), 8pt after the title: where the
    agent works. 24pt (`controlS`), radius 6, 8pt side padding, 6pt gaps, a 1px `lineStrong`
    line:
    - **a worktree Shepherd made** (Main): a 12pt `square.on.square` in `textSecondary`, the branch
      in Geist Mono 11.5 `textPrimary` (truncating in the middle), "●3" in Geist Mono 10.5
      `lanternText` (the files changed; left out at zero), then for a remote agent its host (a
      10pt `display` glyph and the name in Geist 10.5 `textTertiary`, 2pt apart), and a 9pt
      `chevron.down` in `textTertiary`.
    - **the space's own checkout** (QuestionAsk: "chore/remove-homarr your checkout ●11 horizon"):
      on `lanternTint` with a `lantern` line, a `house` glyph, the branch and "your checkout"
      (Geist 11) in `lanternText`, the count, the host, and a `lanternText` chevron: pi edits the
      files you work in.
    - No chip for a directory that is no repository, or from a host too old to read one.
    - **Clicking** opens its menu (no board draws one; see the departures): Show Changes (the side
      pane on Changes), Copy Branch Name, and for a local agent Copy Path and Show in Finder. Its
      tooltip: "Worktree · pi/swiftui-previews · 3 files changed" (or "no changes", and "· on
      horizon"), then the checkout's path.
  - a spacer
  - the side-pane button (`NWSidePaneButton`, `sidebar.right`; PaneStates' SidePaneButton): "Show
    side pane" or "Hide side pane" with ⇧⌘B, a `lanternTint` circle with its glyph in
    `lanternText` while the pane shows (its tabs or an inspected subagent). It is the header's
    only pane button: the terminal, review and subagents toggles are gone (the user's decision;
    see the departures). While pi has opened something the tab strip can't show (the pane is
    closed, or a subagent is inspected over it), it takes an 8pt `running` dot at its top
    trailing corner, ringed 2pt in `bgWindow` (`NWToggleBadge`), and its tip (Side pane).
  - the options menu (`NWOptionsMenu`, "Thread options"): Refresh Thread, Load Older Messages (while
    older history exists), then Rename… after a divider.
- **Where the count comes from** (`Agent.checkout`, live state the host broadcasts, so a remote
  viewer's chip matches): the host reads each local agent's checkout with one `git
  --no-optional-locks status --porcelain=v2 --branch -z --untracked-files=all` off the main thread
  (`CheckoutMonitor`, at most four at once, requests for an agent coalescing into one read), after
  what changes it: the agent appearing, a tool call that may write files (any but read, grep,
  find and ls; at most one read a second while pi edits), a turn starting or ending, selecting the
  agent, the app coming to the front, and the review loading (a commit or a revert reloads it).
  Never a git call per frame. The count matches the review's: tracked changes against HEAD and
  untracked files.
- **No status pill, no counters.** The board puts the agent's state beside the title
  (`NWStatusPill`: "Running · 0:31", "Needs you", "Idle"); nothing sits there, because the thread and
  the sidebar row already say it (see Where Shepherd departs from the boards). The boards swapped
  the turn and context counters ("17 turns · 42k ctx") for the branch chip, and so does the app.
- **The full-window boards' toolbar** (Main, Running, SlashMenu, ModelPicker, CommandPalette, and
  the thread boards drawn with them) is 52pt with 20pt padding and a 30pt ••• with a `lineStrong`
  ring. NWNavigation's 44pt and its ringless 28pt buttons are the rule, with the full-window
  boards' breadcrumb and chip.
- **Motion:** switching agents replaces the toolbar at once, even when the switch rides an
  animation. A rename or a settled name cross-fades, the chip's count rolls, and the side-pane
  button lights up however the pane opened (a menu, a key, a link).
- **With no thread on screen**, the toolbar shows the title only: the selected space's name, or
  "Shepherd". Over a remote host's utility terminal it reads "<agent> · terminal".
- **Pane headers** (`NWPaneHeader`, NWNavigation: "Title + mono subtitle, controls right, close
  last"): at least 44pt on `bgWindow` with a hairline beneath, 12pt leading and 6pt trailing padding
  (`NWToolbarMetrics.paneLeadingPadding`, `paneTrailingPadding`), 8pt between items. The title is
  Geist 13 semibold over a 1pt gap and a micro `textTertiary` subtitle ("4 files · +67 −58", the
  counts in `done` and `failed`). Then a spacer, the pane's controls (the review's Local · PR #24
  `NWSegmentedPicker`, a ••• `NWOptionsMenu`), and close (`xmark`, "Close pane" unless the pane
  names it) always last. The review uses it ("Close review") only in a layout pane of its own (an
  older host's review leaf); the side pane has its tab strip, and the subagent inspector its own
  header (`NWInspectorHeader`; Side pane, below).

### Empty workspace

With no agent on screen, `EmptyWorkspace` (`WorkspaceView.swift`) shows an `NWEmptyState` centred in
the workspace, at most 420pt wide (`AppLayout.emptyWorkspaceMaxWidth`). It follows NWStatus's rule,
"one sentence, one or two actions": the 28pt crook, the title in Geist 17 semibold, one sentence in
12.5 `textSecondary` (at most 280pt wide, NWStatus; the app caps it at 320, see Known gaps), and the
actions 6pt apart. Keycaps come from `KeybindingsStore` (`.newAgent`). The toolbar above it shows
the selected space's name, or "Shepherd". The empty state fades in on a layer of its own while the
layouts under it flip at once (`.content`), and its variants cross-fade into one another:

- A space with no agents: "No agents in <space>", "Start one to work in <path>.", a primary
  **New agent** button, and its keycaps.
- A selected space that has agents, with none on screen: "No agent selected", "Pick one in the
  sidebar, or start another in <space>.", and the same actions.
- No spaces at all: "No spaces yet", "A space is a project folder your agents work in.", and a
  primary **New space…** button. None at all means none on this Mac (the hidden automations
  space is not one) and none on a connected host; with only a host's spaces it is the "No agent
  selected" state below.
- The workspace never stands in the hidden automations space with no agent: stopping a
  selected run moves it to the first visible space.
- Otherwise: "No agent selected", "Pick one in the sidebar, or start a new one.", and the New
  agent keycaps.

No Mac board draws an empty workspace. NWStatus draws only the component (`NWEmptyState`, "No
agents on watch", with the rule above), and the boards' nearest surface is the New thread page
(NavNewThread), which is what the first destination opens. Once destinations are built, deciding
what an empty main column shows is part of that work.

### Destination pages

**Not built yet.** Each sidebar destination opens a page in the main column, in place of a thread
(NavNewThread, NavMissions, NavDesigns, NavAutomations, NavHosts). The pages share one frame:

- **Page header:** 52pt (the thread toolbar is 44) on `bgWindow`, with a hairline beneath, 24pt
  leading and 16pt trailing padding, and 12pt between items. It holds the page title in `title`
  (Geist 15 semibold); an optional subtitle in 12.5 `textTertiary` ("3 hosts · 1 offline"); a
  spacer; a filter field ("Filter missions", "Filter designs", "Filter automations"; 220×28, radius
  6, padded 10pt, a 1pt `lineSubtle` border and no fill, a 12pt `textTertiary` magnifying glass 8pt
  before a 12pt `textTertiary` placeholder); and the page's one primary button (`.nw(.primary)`,
  28pt, radius 6, padded 10pt, a 13pt `plus` 6pt before the label in 12.5 semibold: "New mission",
  "New design", "New automation", "Add host"). Build the field on `NWSearchField`, whose chrome
  today is heavier than the board's (13pt glass, 12.5 text, the field border).
- **State tabs** (Missions, Automations), under the header, padded 16pt above, 12pt below, and 24pt
  at the sides. They are 28pt tall, padded 10pt at the sides, radius 6, and 2pt apart. Each is the
  label in 12.5 and its count in mono 10.5 `textTertiary`. The selected tab is `bgSelected`,
  `textPrimary` and semibold; the others are `textSecondary`.
- **Tables** (Missions, Automations): column labels in mono 10.5 caps, 5% tracking, `textTertiary`,
  padded 24pt at the sides and 8pt below. Rows have a hairline above, 24pt side padding, and the
  columns' gap. The selected row is `bgSelected`.
- **Cards** (Designs, Hosts): a 1pt `lineSubtle` border at radius 10 (the boards' value, between
  `NW.Radius.m` 8 and `.l` 12), clipped. The page body is padded 20pt above and below and 24pt at
  the sides.

### New thread page

**Not built yet** (NavNewThread; "⌘N or the first destination"). Today ⌘N starts an agent at once in
the selected space, with an empty thread and a ready composer (Thread › Empty thread), and ⇧⌘T opens
the New agent sheet.

- The header reads "New thread". The body centres one column vertically, padded 40pt at the sides
  and 80pt below, with 24pt gaps.
- **Heading:** "What should the agent work on?" in Geist 26 semibold, tracked −2%. This is outside
  the ramp; set it with `Font.nwSans`.
- **Composer:** the thread's `NWComposer`, 720pt wide, drawn focused (a `textTertiary` border and a
  3pt `bgSelected` ring). The placeholder is "Describe the task, or / for commands…". Its control
  row is the thread's (attach, "/ commands", the model chip, Thinking with its level, and Send, a
  28pt `lantern` circle), plus one chip only this page has. The **workplace chip** follows attach:
  a 12pt `textSecondary` repo glyph and the repo in mono ("shepherd"), a `textTertiary` "·", a
  display glyph and the host in mono ("This Mac"), and a 10pt `textTertiary` chevron, as a 26pt
  chip in 12 `textSecondary`. It picks where the thread will run. The boards draw it only on this
  page, before a thread exists; Principle 4 keeps a working directory out of a running thread's
  composer.
- **Suggestions:** three equal cards under the composer, 38pt below it (the column's 24pt gap plus
  14), 720pt across and 10pt apart. Each is padded 12pt above and below and 14pt at the sides,
  radius 8, with a 1pt `lineSubtle` border, hover `bgHover`, and 5pt gaps. It holds a kicker in 11.5
  `textTertiary` with a 12pt `textSecondary` glyph 8pt before it, a title in 13 medium truncating at
  the tail, and a detail in 11 `textTertiary`:
  - "Continue" (a speech bubble), the most recent running thread's title, "running · 42m"
  - "Bigger than one thread?" (a map), "Start a mission instead", "plans across repos"
  - "Need a mockup first?" (a pen nib), "Start a design", "HTML boards on a canvas"

  The mission and design cards wait on Missions and Designs.

### Missions page

**Not built yet**, and waiting on Missions itself (NavMissions; "every mission, filtered by state").

- **Header:** "Missions", "Filter missions", and **New mission**.
- **Tabs:** All · Needs you · Running · Drafts · Done · Templates, each with its count.
- **Table**, columns Mission · Lanes · Route · Spend · Host (1.7fr · 1.2fr · 160pt · 150pt · 110pt,
  20pt gaps). Rows are padded 14pt above and below.
  - **Mission:** a 14pt map glyph (`lanternText` while it needs you, else `textSecondary`), the name
    in 13.5 semibold, and a 10pt gap before its state pill (`NWStatusPill`): Needs you (glowing),
    Running, Draft (outlined, `textTertiary` dot), or Merged (the `done` pill worded "Merged").
    Under it, indented 24pt, is one line in 12, truncating: the question in `lanternText` while it
    needs you ("retention: 30 days or 13 months?"), else what it is doing or how it ended in
    `textTertiary` ("orders · go test ./... · 3m", "map drafted · 1 question open", "PR #34 merged ·
    2h41").
  - **Lanes:** one chip per repo, wrapping with 4pt gaps. A chip is 20pt, radius 4, a 1pt
    `lineSubtle` border, padded 6pt, with a 10pt repo glyph and the name in mono 10.5
    `textSecondary`.
  - **Route:** a 150pt strip of one 4pt segment per station (radius 2, 2pt apart): `done` for
    passed, `running` for going, `lantern` for waiting on you, `lineStrong` for ahead. Under it, 6pt
    below, "6 of 15 stations" in mono 10.5 `textTertiary`.
  - **Spend:** tokens against the budget ("2.3M / 6M tok") in mono 11 `textSecondary`, over time
    against its budget ("1h12 / 4h") in `textTertiary`, 3pt apart; a draft that has spent nothing
    reads "— / 3M tok" and "— / 2h".
  - **Host:** mono 11 `textSecondary` ("build-01", "This Mac").

### Designs page

**Not built yet** (NavDesigns; "recent designs and design systems"). The page takes the header
above ("Designs", "Filter designs", and **New design**); its recent designs and design systems
are specified with the rest of the design tool, under Design tool › Designs.

### Automations page

**Not built yet** (NavAutomations; "schedules and event triggers, with runs"). Today this Mac's
automations are the sidebar's footer rows, and a host's are a disclosure under its section with the
Details and Runs sheet (Sidebar). Shepherd's automations have no schedule or trigger, so the page's
When and Next columns and its Scheduled and On an event tabs don't apply while that holds (see Where
Shepherd departs from the boards).

- **Header:** "Automations", "Filter automations", and **New automation**. **Not built yet** on the
  Mac: nothing on the Mac creates or edits an automation (the iOS client's form has Name, Prompt,
  Where it runs, and Starts with Shepherd; iOS: Automations).
- **Tabs:** All · Scheduled · On an event, with counts.
- **Table**, columns Automation · When · Starts · Host · Last run · Next (2fr · 1.25fr · 76pt · 76pt
  · 1.15fr · 64pt, 16pt gaps). Rows are padded 12pt above and below.
  - **Automation:** its switch (`.nwSwitch`, 30×18: `lantern` on, `lineStrong` off), 10pt before the
    name in 13 semibold, truncating.
  - **When:** a 12pt glyph (a clock for a schedule, a bolt for an event) and the rule in 12
    `textSecondary` ("Every day · 02:00", "When CI goes green on #24").
  - **Starts:** a glyph and "thread" (a speech bubble) or "mission" (a map) in 12 `textSecondary`.
  - **Host:** mono 11 `textSecondary`.
  - **Last run:** a 6pt dot and the outcome with its age in 12, colored by outcome: `done` ("passed
    · 6h ago", "merged · 5h ago"), `lanternText` with a `lantern` dot ("asked you · 1h ago"),
    `failed` ("1 PR failed CI · 3d ago"), or a hollow `textTertiary` dot ("paused · host offline").
  - **Next:** mono 11 `textTertiary` ("in 17h", "on event", "finished", "paused").
- **Detail pane:** 360pt at the trailing edge with a hairline on its leading side, for the selected
  row. The sections under its header are padded 14pt above and below and 18pt at the sides, with
  a hairline between them.
  - **Header,** padded 16pt above and below and 18pt at the sides: the name in 15 semibold over
    "Starts a thread on build-01 every night" in 12 `textTertiary`.
  - **Prompt:** "PROMPT" in mono 10.5 caps `textTertiary`, 8pt above the prompt in 12.5 at 1.55 line
    height, padded 10pt above and below and 12pt at the sides, radius 8, on `bgSunken` with a
    `lineSubtle` border (`NWAutomationPrompt`).
  - **Facts:** When, Host, Repos, Model (`NWFactRow`, a 90pt label column in `textSecondary`, values
    mono except When, 6pt apart).
  - **Recent runs:** "RECENT RUNS", then 28pt rows in 12, each a 6pt dot by outcome, the date in
    mono `textSecondary` ("Sep 24 02:00"), the outcome in `textTertiary` ("3 migrations · all
    reversible", "lock timeout on orders_idx"), and the duration trailing in mono 10.5
    `textTertiary`.
  - **Footer** pinned under a hairline, padded 12pt above and below and 14pt at the sides: **Run
    now** (secondary, small, a play glyph), a spacer, and **Edit** (ghost, small).
- **This Mac's automations** have no details view yet. Their footer rows open their run's thread
  (live or finished) and do nothing without one.

### Hosts page

**Not built yet** (NavHosts; More ▸ Hosts, "where agents run"). Today hosts are managed in Settings
▸ Remote (add, edit, reconnect, remove) and shown as sidebar sections with their status rows
(Sidebar).

- **Header:** "Hosts", the subtitle "3 hosts · 1 offline", and **Add host**. There is no filter.
- **Explainer:** one paragraph in 12.5 `textSecondary`, at most 720pt wide: "Where agents run.
  Threads run on the host you pick when you start them; missions run on a daemon so they survive
  your laptop sleeping. Remote threads show the host's name as a tag in Recents." The missions and
  daemon parts wait on Missions and daemon hosts; Shepherd has no daemon (AGENTS.md).
- **Host cards,** 14pt under the explainer, three columns with 16pt gaps, each a 1pt `lineSubtle`
  border at radius 10. The board draws the middle card's border in `lineStrong` and doesn't say
  which state that is.
  - **Head,** padded 14pt above and below and 16pt at the sides, with a hairline beneath and 10pt
    gaps: a 30pt tile (radius 8, `bgSunken`, `lineSubtle` border) with a 15pt display glyph; the
    name in mono 14 semibold over what runs there in 11.5 `textTertiary` ("Shepherd app · Pi 0.8.2",
    "Shepherd daemon · Linux · Pi 0.8.2", "daemon · macOS · offline 3h"); and the state trailing in
    12 with a 6pt dot: "Connected" in `done`, "Unreachable" in `failed`.
  - **Facts,** padded 10pt above and below and 16pt at the sides: rows at least 26pt tall, a 110pt
    label column in 12.5 `textSecondary`, and values in mono 11.5 `textPrimary`. A connected host
    shows Running ("2 threads", "2 missions · 5 stations"), Worktrees with their disk use ("11 · 3.2
    GB"), and Repos ("shepherd, dashboard-web") or, for a daemon, Load ("6 of 16 cores"). An
    unreachable host shows Waiting ("2 threads, 1 automation"), Last seen ("Sep 24 07:12"), and
    Address ("horizon.local:7040").
  - **Actions** under a hairline, padded 10pt above and below and 14pt at the sides, 8pt apart,
    small: This Mac has Open in Finder (ghost); a daemon has Open terminal and Logs (ghost); an
    unreachable host has Retry (secondary, with an `arrow.clockwise`) and Remove (ghost).

### Thread

`ThreadView` (`Thread/ThreadView.swift`) lays out the rows `NativeThreadStore` derives once per
change (`NativeTurnPresentation`, `NativeActivity` in ShepherdRemote); the views only draw them.
Dimensions are in `AppLayout+Thread.swift` and ShepherdUI's `NWThreadMetrics`.

The Night Watch Thread boards are the authority for every part below: NWThread in dark, and
NWThreadLight, the same parts on the light roles with nothing else changed. Main (a thread at
rest) and Running (a thread while pi works) show the parts assembled in the window, and ToolRows
the activity line's states. Main and Running draw some parts at other sizes (prose at 15,
bubbles at 14 with 12×16 padding, times and footer meta in mono 11, 28pt footer buttons) and
their meta in a gray that is no Night Watch role (`#767c85`); where they differ, NWThread's
values, below, are the rule.

- **Layout:** a scroll view with the column centered, at most 820pt wide with 32pt gutters (16pt
  in a thread narrower than the column and both gutters, 884pt; `AppLayout.threadGutter`). User
  bubbles are at most 600pt and agent prose keeps a 640pt measure inside it; there are no speaker
  labels. 28pt top margin, 28pt between turns, 14pt between a turn's parts, 10pt between blocks
  inside one part (subagent cards in a stack, "From the queue" above its bubbles), 6pt between
  one turn's bubbles, and 4pt between consecutive activity lines (the app uses 6pt today).
- **Following:** the thread follows the tail only while the reader is within 80pt of the bottom
  (`NativeScrollFollower`). Only a live scroll gesture or a wheel tick detaches it; content
  growth, the composer resizing, and history swaps never do. While a gesture is live, layout
  changes never move the view either: a drag up measures the rows it reveals, and landing on
  the tail then would pull the thread out from under the finger. "↓ Jump to latest"
  (`NWJumpToLatest`, a `bgRaised` capsule above the composer) appears while detached if the
  agent runs or unseen output arrived: new rows or the last one growing, never the content
  height alone (a scroll or a turn jump measures the rows it reveals). The composer draws it
  over the fade it lays on the thread and under its card and menus, so the fade never washes it
  out and it never covers an open menu. A send that goes in now (pi idle, or a steer)
  re-attaches and lands on its turn, unless the reader leaves the tail again first. A follow-up
  that waits in Up next leaves the reader's place alone, then and when it goes: its delivery is
  new output like any other. The composer floats over the scroll view, which is inset by the
  composer's measured height, so the thread always ends at its last turn.
- **Turn jumps:** ⌥⌘↑ and ⌥⌘↓ move between user turns (the target lands at the top); stepping
  past the last returns to the tail.
- **History:** "Load older messages" (a small ghost button, centered) heads a thread that has
  older pages. It reads "Loading history…" while a page loads, and acts only once pi is ready.
- **Notices** above the thread explain degraded states in caption tertiary: "Last known thread ·
  refreshing before enabling actions", "This host's pi cannot answer questions here · update
  Shepherd on the host", "Some earlier output is clipped".
- **Starting:** while pi boots (a new agent, or one resuming after a relaunch) the thread is
  ready to use and quiet, never an error: it draws what it knows at once (a new agent's empty
  state, or its opening prompt as a message pi has not read yet, at 70%; a resuming agent's
  history), and a message sent meanwhile waits for pi. The opening prompt is the row pi's first
  snapshot carries, so it stays put when pi answers and when pi starts the turn; the device that
  created the agent draws it, and every other viewer sees it in that first snapshot. Nothing says
  pi is starting unless pi is slow: past two seconds (`AppLayout.startingIndicatorDelay`), well
  beyond a normal start (pi answers about 0.8 s after ⌘N, about 1 s after a relaunch), or past
  half a second (`AppLayout.blankStartingIndicatorDelay`) while the thread has nothing to show
  (a remote agent's, or one whose session file cannot be read). Then the composer's control row
  says so (see Composer › States). There is no spinner in the thread and no starting row at its
  tail. A pi that has not started after a minute gets the error banner.
- **Resuming:** an agent resuming after a relaunch shows its history at once, read from pi's
  session file (`PiSessionPreview`): the newest page, the model, and the thinking level, drawn
  exactly as pi's history is. Nothing in it acts yet (retry, load older, subagent actions)
  until pi answers, and pi's first snapshot then lands on the same rows, so nothing moves or
  flashes. Only what pi alone knows arrives with that snapshot: the "/ commands" chip (and the
  placeholder's "or / for commands"). An agent whose file
  cannot be read stays blank until pi sends its history.
- **Empty thread:** a framed `NWEmptyState` (a dashed `lineStrong` border, no crook): "New
  agent in `~/path`" (the path in Geist Mono 15 medium within the 17pt title), with "Describe
  the task. Drop or paste images to attach them, or type / for commands." A new agent is known
  to be empty, so it shows from the first frame, with the composer ready, while pi boots behind
  it. While a thread's history is not known yet (a resuming agent without a readable session
  file) the thread stays blank until pi sends it; an empty history then fades the state in.

**User turn** (`UserTurn` in `Thread/ThreadTurns.swift`, on `NWUserBubble`):

- Right-aligned, at most 600pt, `bgBubble` with a 1px `lineStrong` line, radius 8, 10×14
  padding, body text (13.5) at a 1.5 line height, selectable. No avatar and no name.
- The time ("2:41 PM") sits 5pt beneath in mono 10.5 tertiary, only while the turn is hovered
  (see **Details on hover** below): at rest it keeps its line and draws nothing.
- **Attachments** (`NWAttachmentChip`, NWThread) sit above the text inside the bubble, 6pt apart
  and 8pt above it. A chip is 26pt with a 1px `lineStrong` line and radius 6, its name in 12pt
  `textPrimary` truncating in the middle, 6pt gaps. An image chip leads with its 20pt thumbnail
  (radius 4, 3pt from the chip's edges); a file chip leads with the `doc` glyph in
  `textSecondary`, 8pt from each edge. In the composer a chip ends with a remove × in
  `textTertiary`; in a sent bubble it has none. Shepherd attaches images only today (see
  Composer › Images).
  - **Not built yet.** A sent bubble's chips show each image's thumbnail and file name, as the
    board draws `screenshot.png`. Today they read "Image" behind the file glyph, because the
    thread keeps only how many images a message carried.
  - **Not built yet.** File attachments: any file dropped, pasted, or picked (the board's
    `Spec.dc.html`) attaches as a file chip and rides with the message, in the composer and in
    the sent bubble.
- A message sent while pi is idle shows at once, at 70% opacity until pi reads it. One sent
  while pi works never enters the thread early: it waits in the composer's **Up next** (see
  Composer) and joins the thread only when pi reads it, where pi read it.
- **From the queue:** messages the queue delivered together (one turn for pi) open with
  `NWQueueDivider`, "From the queue · 2" (just "From the queue" for one) in caption tertiary
  with the queue glyph between two hairlines, then one bubble per message, 6pt apart, each with
  the time it was sent (on hover, like any bubble's).
- **Steered:** a message steered into a running turn stands inside that turn where pi read it
  (after the tool calls it waited on, at the turn's 14pt item spacing), so the turn keeps one
  footer and one changes card. Its bubble wears "Steered" above it (`arrow.turn.down.right` 11
  and caption medium, both `running`) and a `running` line instead of `lineStrong`; its time
  shows on hover. After a relaunch a steer pi read after its final message reads as an ordinary
  new turn.

**Agent turn** (`AgentTurn`): consecutive assistant messages render as one turn. Its parts are
thinking, prose, activity lines, subagent cards where their spawn calls were, notes, and errors,
in the order they happened (each stretch of work between prose opens with its thinking). Once
the turn has finished, the changes card and the footer end it. A running turn has no footer.

- **Prose** (`Prose` in `Thread/ThreadMarkdown.swift`, on `NWAgentProse`): body 13.5/1.6 in
  `textPrimary` at the 640pt measure, blocks 12pt apart, selectable, with no speaker label.
  Markdown is parsed once per turn:
  - headings at `headline`, with 4pt more above them
  - lists indented 20pt per level to any depth (the marker right-aligned 6pt before the text),
    items 4pt apart
  - bold and italic as Markdown gives them
  - quotes in italic `textSecondary`, 12pt past a 2pt `lineStrong` rule
  - inline code in mono 12 on `lineSubtle` (the board's `bgSunken` with a 1px line cannot ride a
    text run; see Where Shepherd departs from the boards), links in `running`, not underlined
  - rules as hairlines, 4pt above and below
  - tables, task lists, images, disclosures, footnotes and inline HTML as in **Rich content in
    prose** below
- **Code blocks** (`HighlightedCodeBlock` on `NWCodeBlock`): `bgSunken`, a 1px `lineSubtle` line,
  radius 8, as wide as the prose measure. A 28pt header (12pt leading, 6pt trailing, a hairline
  beneath) holds the language (or "code") in mono 10.5 tertiary and a 22pt copy button (`doc.on.doc`
  in `textSecondary`; the app draws `square.on.square`, see Known gaps) that appears on hover or
  keyboard focus and turns into a check with a pop for 1.5s after a copy. Code in mono 12 at 1.6
  with 10×12 padding, in the Syntax roles (`synKeyword`, `synType`, `synString`, `synComment`, …),
  scrolling sideways only when its longest line does not fit, never wrapped. Tree-sitter colors it
  off the main actor in the block's task (Swift, Python, Go, Rust, JavaScript, TypeScript/TSX, C,
  C++, shell, Ruby, JSON); the first frame is plain, results are cached, and a block that grows
  while streaming keeps its last colors until the new ones are ready.
- **Thinking** (`NWThinking`): the thinking in one stretch of work (between prose blocks) folds
  into one block at the start of that stretch, so per-call reasoning never splits the activity
  lines.
  - Collapsed: a 10pt chevron (pointing right, turning down as it opens) and "Thought for 4s" in
    italic 12 `textSecondary`, 6pt apart ("Thought for 1m 04s" past a minute; "Thought" when
    shorter than half a second or untimed). The whole label is the button.
  - Expanded: 8pt beneath, the text in italic 12.5 at 1.55 in `textSecondary`, 12pt past a 2pt
    `lineStrong` rule, at the prose measure. It opens and closes with `disclosure`.
  - Live: a 12pt `textSecondary` spinner, "Thinking…" in italic 12 `textSecondary`, and its
    seconds counting in mono 10.5 tertiary ("4s"), 8pt apart on a 26pt row. When thinking ends
    it cross-fades in place into what the finished row is (below), or leaves.
  - Finished, by what the stretch carries. Providers often keep their reasoning back
    (Anthropic's redacted or omitted thinking, OpenAI's encrypted reasoning, a proxy that
    streams none), and pi keeps that as a thinking block with no text; readable text is
    anything but whitespace, a summary pi left only in the block's signature included, and a
    folded row shows only the blocks that have it.
    1. Readable text: the disclosure above.
    2. No readable text, timed at half a second or more: "Thought for 10s" as a plain line, the
       collapsed label's words, type and color with no chevron. It is not a control (no hover,
       no press, no focus); its tooltip and VoiceOver say "Thought for 10 seconds. The model
       didn't share its reasoning."
    3. No readable text and no such time: no row.

    The NWThread board draws only the first; the other two are app states it does not draw.
- **Notes** ("Image attached", "Output truncated", extension messages) render as caption
  tertiary text on a 2pt rule (three lines, full text on hover).
- **Errors** (`NWTurnError`): a failed provider request, on `failedTint` with radius 6 and 8×10
  padding, at most the prose measure: a 14pt `exclamationmark.triangle` in `failed`, the message
  in `ui` regular `textPrimary` ("Model overloaded — the turn stopped after 6 tool calls."; the
  suffix only when the error ended a turn that made tool calls), "×n" in mono 11 tertiary when
  repeated, and Retry (a secondary `s` button with `arrow.clockwise`) when it ended the turn,
  10pt apart. It rises in like a row (`list`). Tool failures stay in their activity lines.
- **Stopped:** a turn the user stopped is not an error. It ends in the note "Stopped", and the
  call Stop interrupted keeps its line's usual colors with "stopped" in its meta ("Ran a
  command · sleep 40 · stopped · 7.5s"), standing alone like a failure, so the word stays
  visible.
- **Working row** (`NWWorkingRow`, Running): while the agent runs, the thread ends in one 26pt
  row, 4pt in from the column's edge: a 12pt `running` spinner and what it is doing in italic 12
  `textSecondary`, 8pt apart: "Working…" under a live activity line, "Running <tool>…", or
  "Thinking…", each label cross-fading into the next (`content`). It is one row for the whole
  run, the last part of the streaming reply. Live thinking carries its own spinner instead, and
  a pending question replaces it with the composer's question panel.
- **Footer** (`NWTurnFooter`), after a finished turn: copy (the turn's prose; tooltip "Copy the
  reply", VoiceOver "Copy response", then a check for 1.5s) and retry (resend the prompt that opened
  it, only while the agent is idle; tooltip "Send this turn's prompt again", VoiceOver "Retry turn";
  Main's labels) as 24pt icon buttons 4pt apart, then, 4pt further, "2:44 PM · 3m 12s · 23 tool
  calls" in mono 10.5 tertiary (when the prompt was sent, how long the turn took when that was a
  second or more, and the tool calls a reader can count), and "· 3 subagents" as a `running` link to
  the first run. The whole row, link included, shows only while the turn is hovered.

**A turn while pi works** (Running): the turn builds in place as its parts arrive, in the order
above, each fading in (a failed request rising like a row): "Thought for 2s", prose saying what
it will do, the stretch's finished lines ("Committed · 3 files changed"), the one live line with
its output ("Pushing · git push origin main · 3s"), and the working row last. It has no changes
card and no footer until it finishes; then both rise into place under it (`list`). The finished
turn above it keeps its footer hidden at rest, like any other.

**Details on hover.** A message's time and a finished turn's footer are hidden at rest, so a
thread reads as the conversation alone; the pointer over the message (anywhere in the turn's
row) shows them.

- **Nothing moves.** Hidden, they keep their place and draw nothing; they only fade (`.hover`,
  unchanged under Reduce Motion). A turn measures the same hovered or not.
- **Also shown** while one of the footer's controls has keyboard focus, for the moment a copy
  confirms, and whenever VoiceOver runs, so Copy response, Retry turn, the subagents link, and
  the time are always reachable (`NWMessageDetails`).
  - **Not built yet.** A user bubble with keyboard focus shows its time too, as NWThread says
    ("hovered or focused"). Today a bubble takes no focus, so its time shows only on hover or
    with VoiceOver.
- **Per message.** Each turn owns its pointer state (`MessageHover` in `ThreadTurns.swift`), and
  its whole row counts, gaps and the hidden details' place included. Only what shows the
  details reads it (an agent turn's footer; a user turn, which is just its bubbles), so the
  pointer crossing a thread never re-renders an agent turn's parts, other turns, or the thread.
- The subagent inspector's transcript follows the same rule; there "from parent" always shows
  under a message from the parent (never under your own steers and answers), and its time fades
  in beside it.

**Work groups** (`WorkGroupView` in `Thread/ThreadTools.swift`, `nativeWorkGroup`). A stretch's
activity lines (between prose, notes, errors and subagent cards) form one group, so a long turn
never reads as a wall of lines.

- **Folded:** two or more finished lines fold into one summary line, `NWActivityLine` with the
  `work` glyph (`rectangle.stack`): "Worked for 6m 40s" (wall time over its calls; "Worked"
  untimed) · "explored 13 files · edited 15 files · ran 22 commands · 17 tests passed · 5
  failed". Kinds always read in that order (explored, edited, ran, started, used); the lines
  keep the order the work took.
- **Expanded:** the summary's chevron turns down and its lines open beneath (`disclosure`), as
  below, on the same rail as a line's calls (`NWActivityRail`: a 1px `lineStrong` rail 9pt in,
  under the line's glyph, with its rows 16pt past it). The rail's lines are 4pt apart, the first
  4pt under the summary, and the rail runs 2pt past its first and last line (the app spaces the
  summary's lines 6pt today).
- **One line** stays itself: it already is one line.
- **Running calls** stand below the summary as live lines, and join it when they finish.
- **Failures are counted, not shouted.** A failed call adds "n failed" to the meta and is red
  only inside the expanded lines ("Worked for 6m 40s · … · 5 failed" stays quiet). The summary
  turns `failed` (its label, with `exclamationmark.triangle` in place of the `work` glyph; the
  meta stays tertiary) only when the group's last call failed and nothing runs after it: the
  work ended on a failure ("Worked for 19s · ran 2 commands · 2 failed").

**Activity lines** (`ActivityLineView` in `Thread/ThreadTools.swift`, on `NWActivityLine` and
`NWActivityCalls`). Within a group, a turn's tool calls merge into one quiet line per burst of
same-kind work (`nativeActivityBursts`). A failed call and the running call each stand alone;
other tools merge only with the same tool.

- **The line:** 26pt, a 13pt glyph in `textTertiary`, the label in `ui` regular (12.5)
  `textSecondary`, the meta in mono 11 tertiary, and a 10pt tertiary chevron (pointing right,
  turning down) when it expands, 8pt apart, with 4pt leading and 8pt trailing padding. It hugs
  its content and sits 4pt left of the column, so its glyph lines up with the prose. The label
  never truncates; the meta truncates at its tail. It is a real button with a radius-6 `bgHover`
  fill on hover; a line with nothing behind it has no chevron and does nothing.

  | Kind | Glyph | Done | Running |
  | --- | --- | --- | --- |
  | Explore (read, grep, find, glob, ls) | `magnifyingglass` | "Explored 7 files" · "read 5 · search 2 · 0.9s" | "Reading", "Searching", "Listing" |
  | Edit (edit, write) | `pencil` | "Edited 4 files" · "+149 −63" | "Editing", "Writing" |
  | Run (bash) | `terminal` (the app draws `apple.terminal`; Known gaps) | "Ran tests and a build" · "17 passed · build ok · 1m 02s"; "Committed" · "3 files changed" (Running); "Committed and pushed"; "Ran 2 commands" | "Running tests", "Building", "Committing", "Pushing", "Running" |
  | Subagents (spawns without a card) | `arrow.triangle.branch` | "Started 2 subagents" · "reviewer · tests" | "Starting a subagent" |
  | Other | `wrench.adjustable` | "Used <tool>" or "Used <tool> n times" | "Running <tool>" |

  Shell commands are classified by what they run (`nativeCommandClasses`: tests, build, commit,
  push), with setup and pipes (`cd`, `| tail`) ignored and test counts parsed from the output
  (Swift Testing, XCTest, and "N passed" in general).
- **Failed and stopped words.** A failed call reads as what it was doing: "Read failed", "Search
  failed", "List failed", "Edit failed", "Write failed", "Ran tests", "Ran a build", "Commit
  failed", "Push failed", "Ran a command", "Subagent failed to start", "<tool> failed". A call
  Stop interrupted reads the same way with "stopped" ("Edit stopped", "Commit stopped",
  "Subagent stopped", "<tool> stopped"; runs keep "Ran tests", "Ran a build", "Ran a command").
  The meta is the command or the file's name, then the reason ("exit 1", "3 failed", the error,
  or "stopped"), then the time.
- **Failed:** the line turns `failed` (the `exclamationmark.triangle` glyph and the label; the
  meta stays tertiary) and stays visible, never merging with its neighbours: "Ran tests" ·
  "swift test · exit 1 · 8.4s" (ToolRows), or "swift test · 3 failed · 8.4s" when the test
  counts parse; "Edit failed" · the file · the error. A piped test run that exits 0 with
  failures still fails.
- **Live:** only the current call is live, with no hover fill and no chevron: a 13pt `running`
  spinner, the progressive verb in `textPrimary`, the command or path in mono 11 tertiary, and
  its elapsed time in mono 11 `running` ("3s", "1m 20s"), 8pt apart. Its last three output lines
  sit 4pt beneath, 21pt in (under the label), in mono 11 at 1.6: the older ones `textTertiary`,
  the newest `textSecondary`. When the call ends the live line cross-fades into its finished
  line in place, and the output lines go at once.
- **Calls** (expanded, `NWActivityCalls`): an indented list on the rail, 22pt rows in mono 11
  with no gap between them and 10pt between a row's columns: the kind in `textTertiary` in a
  32pt column that widens for a longer name ("read", "edit", "bash", "spawn"), the path
  (truncated at the head) or command (at the tail) in `textSecondary`, and a stat in
  `textTertiary` ("+58 −41", "160 lines", "3 matches", "17 passed", "exit 1"; in `failed` on
  a failed call). A row has a radius-4 hover fill and the full path or command as its tooltip.
  - Clicking an edit or write opens the review pane at its file. Clicking any other call with
    output expands its first 12 lines in mono 11 `textSecondary` on `bgSunken` (radius 6, 8×10
    padding, aligned under the path); then "… n more lines" (or "Output truncated · open" for
    output the host clipped), a link, opens the whole output in a sheet.
  - The output sheet (`ToolOutputSheet`): the call's name and command in mono medium with Copy
    (secondary) and Done (primary) in its header, the output in mono 12 scrolling both ways, and
    "The host clipped this output; the full text is in pi's session file." beneath it when the
    host clipped it.
  - ⌥-click or the context menu's Show Call opens the raw arguments; the menu also has
    Review <file>, Open Output, and Copy Output.

**Changes card** (`NWChangesCard`): every finished turn that edited files ends with one.

- A card on `bgWindow`, radius 8, 1px `lineSubtle`. A 32pt `bgSunken` header (12pt leading, 6pt
  trailing, 10pt gaps, a hairline beneath): a 12pt pencil in `textSecondary`, "4 files changed"
  in `ui` semibold `textPrimary`, the diff stat in mono 11 (`NWDiffStat`: "+149" in `done`,
  "−63" in `failed`, with a true minus), and a ghost `s` **Review** button
  (`plus.forwardslash.minus`) at the trailing edge that opens the review pane at the first file.
- One 28pt row per file, hairlines between, 12pt padding and 10pt gaps: the status letter in
  mono 11 bold (M `lantern`; A `done` for a file the turn wrote without reading or editing it
  first), the directory in tertiary and the filename in `textPrimary` (mono 12, truncated at the
  head), and its diff stat in mono 11. A row has the row hover fill and opens the review pane at
  that file.

#### Rich content in prose

Agents write more than paragraphs and lists; everything they commonly write draws as a native part,
the same on the Mac, iPhone and iPad. One parser in ShepherdRemote (`nativeMarkdownParse` in
`NativeMarkdown.swift`) splits a reply into blocks once per change, in the store
(`NativeTurnPresentation`), never in a view's `body`. The app maps them onto ShepherdUI's
`NWProseBlock` (`Prose` on the Mac, `ProseView` on iOS), and ShepherdUI draws them (`Prose.swift`,
`ProseTable.swift`, `ProseParts.swift`). Inline runs are styled once per text and text scale by
`NWProseInline`. Nothing the parser does not understand is dropped or shown as markup: it reads as
text.

- **Tables** (`NWProseTableView`): GitHub pipe tables with their delimiter row. A card with
  radius 8 (`NW.Radius.m`) and a 1px `lineSubtle` border, no fill of its own. The header row
  sits on `bgSunken` in `ui` semibold `textSecondary`. Cells are in the prose size (`body`, at
  `headline`'s 1.35 line height) in `textPrimary`, with 8×12 padding (`NW.Space.m` ×
  `NW.Space.l`). Rows are split by 1px `lineSubtle` hairlines; there are no column lines.
  - Columns follow the delimiter row's alignment (`:--`, `:-:`, `--:`).
  - Cells keep their inline Markdown: code spans as the thread styles them, bold, italic,
    links, strikethrough. An escaped pipe (`\|`) stays in its cell, and a pipe inside a code
    span never splits one. Rows of uneven length are padded, and no cell is ever dropped.
  - **Sizing** (`NWTableLayout`): a column takes its widest cell's width up to
    `NWThreadMetrics.tableColumnMax` (360pt, 260pt on iOS), then wraps. A table narrower than
    the prose measure hugs its content; given room, wrapped columns grow toward their content.
    When the columns do not fit, each gives up its share down to its floor: the larger of
    `tableColumnMin` (88pt) and its widest word, so a wrapped cell breaks between words and
    never inside an identifier. A table whose floors do not fit scrolls sideways inside its
    card (it never widens the thread and never squeezes a column into an unreadable one), so on
    iPhone the first column stays legible.
  - Text is selectable. **Copy** (the code block's 22pt icon button on a `bgSunken` backing,
    at the header's trailing end) copies the table as Markdown. On the Mac it shows while the
    table is hovered or the button has focus; on iOS it always shows, and the last column
    leaves room for it.
- **Task lists:** `- [ ]` and `- [x]` draw a read-only box in the marker's place:
  `checkmark.square.fill` in `textSecondary` when done, `square` in `textTertiary` when not.
- **Nesting:** lists nest to any depth, ordered and unordered mixed, with paragraphs, code
  blocks, tables and quotes inside items; two spaces of indent nest, as agents write them.
  Bullets change by depth (•, ◦, ▪). Quotes hold blocks too, in italic `textSecondary`.
- **Images:** an image on its own line (`![alt](src)` or `<img>`). A local file that this
  device can read (the agent's working directory, `nwProseFileRoot`, is here) draws as a
  thumbnail within 360×240 (`proseImageMaxWidth`, `proseImageMaxHeight`), radius 8 with a 1px
  `lineSubtle` border, decoded off the main actor at the size drawn. Clicking it opens the file.
  Absolute paths and paths relative to the agent's folder both work. A web image is **never
  fetched** (privacy): it is a chip with the attachment chip's anatomy (26pt, 1px
  `lineStrong`, radius 6), the `photo` glyph in `textSecondary`, its alt text in 12pt
  `textPrimary` and its host in mono 10.5 tertiary. The chip opens the image in the browser.
  A remote host's agent (and every agent on iOS) shows local images as chips too, because
  its files are not on this device. An image inside a sentence reads as its alt text.
- **Footnotes:** `[^label]` references become superscript numbers in `running` (mono 10.5),
  numbered in the order they are first cited. The notes gather after the message's last block,
  below a hairline: each number in caption tertiary where a list marker sits, its text in
  caption `textSecondary`. A reference with no note reads as written.
- **HTML is never rendered raw.** `<details><summary>` becomes a disclosure
  (`NWProseDetails`), collapsed: a 10pt chevron and the summary in body medium, the whole line
  a button. Open, its blocks sit 12pt past a 2pt `lineStrong` rule, as expanded thinking does.
  `<br>` breaks the line, `<kbd>` is a keycap (`ui` on `bgSelected`), and `<b>`, `<i>`, `<s>`,
  `<code>`, `<sup>`, `<sub>` and `<a href>` style their text. `<img>`, `<hr>` and `<h1>`–`<h6>`
  become their blocks, other known tags are stripped to their text, and comments are dropped.
  Anything that only looks like a tag (`Array<Int>`) stays text.
- **Strikethrough and links:** `~~text~~` is struck through; links, `<autolinks>` and bare
  URLs are `running` and open in the browser.
- **Diagrams and math** stay code: Shepherd renders neither. A fence labelled `mermaid` (or
  `plantuml`, `dot`, `graphviz`, `d2`) says "mermaid · diagram source" after a
  `point.3.connected.trianglepath.dotted` glyph, and a `math`, `latex`, `tex` or `katex` fence
  (and a `$$` block) says "math · math source" after `function`, both 10pt tertiary in the header.
- **Streaming** (`nativeMarkdownParse(_:streaming:)`): only the text a reply is still writing
  holds anything back. Its unterminated last line waits while it is only the start of a block
  (a `|` row, a delimiter row, a bare `-`, `1.` or `#`, a fence's first line, a tag still
  open, a task box still arriving such as `- [x`, a note's `[^label]` before its colon), so it
  never draws as something else for a moment. Footnote references are numbered while the reply
  streams, before their notes (which come last) arrive, so none shows its raw label. A table header waits for its
  delimiter row instead of drawing as a paragraph. The table appears as a table as soon as
  that row lands, and grows a whole row at a time. A finished reply draws every line.
- **Performance:** the table and its cells compare equal between chunks, so a reply streaming
  under a table redraws none of it (`ListPerformanceTests`: a 200-row table).

### Composer, questions, and menus

`Composer` (`Thread/Composer.swift`) on `NWComposer`, `NWSlashMenu`, `NWModelPicker`,
`NWThinkingMenu`, and `NWSendMenu`, with Up next above the card (below). Sizes are
`NWComposerMetrics`; the app's own are in `AppLayout+Thread.swift`. The boards: Composer & menus
(NWComposer, NWComposerLight: one anatomy in both appearances, every color a role), SlashMenu,
ModelPicker, and the Question boards (QuestionAsk, QuestionPick, QuestionAnswered,
QuestionStates).

The full-window boards (Main, Running, SlashMenu, ModelPicker, CommandPalette, SettingsKeyboard)
were drawn before Night Watch's component boards and draw the same parts larger: a radius-12
composer with 32pt controls and a 14pt field, a 640pt palette with a 56pt search row, 38pt rows,
and a lantern scope pill over a 54% scrim, and 22pt keycaps, under a 52pt breadcrumb toolbar
(Toolbar). Where they disagree, the component boards (Composer & menus, Controls, Navigation) win,
with two exceptions: **the slash menu is SlashMenu's and the model picker is ModelPicker's**
(below), since a menu too narrow for pi's command and model names hid what they were. A row or
string that only a full-window board shows still holds where the component anatomy has room for
it (the palette's New agent with options…, New space on <host>…, and "PR #24").

**The card:**

- It is pinned under the thread in the same column, 16pt above the bottom
  (`AppLayout.composerBottom`), with a 48pt fade from transparent to `bgWindow` above it
  (`AppLayout.composerFade`).
- It is `bgRaised`, with a 1px `lineStrong` line and radius 8 (`NW.Radius.m`). While the field
  has focus, a menu is open, or a drop hovers, the line turns `textTertiary` inside a 3pt
  `bgSelected` ring (`NWComposerMetrics.focusRing`); both fade (`hover`). (NWComposer: "focused,
  with text".)
- Top to bottom: attachments (a row 10pt from the top and 12pt from the sides, chips 6pt apart),
  the field, and one row of controls. The field is `body` text in `textPrimary` with a `lantern`
  caret, its placeholder `textTertiary`, padded 12pt above, 14pt at the sides and 4pt below, at
  least 40pt tall (`fieldMinHeight`); it grows to 8 lines (`fieldMaxLines`), then scrolls.
  VoiceOver names it "Message the agent". The controls sit under it with 4pt above, 6pt at the
  sides and below, 2pt apart. Nothing else lives under the field: no hints, no status text.

**The control row:**

- attach: a 14pt `paperclip` in `textSecondary`, in a 26pt circular icon button (`.nwIcon`),
  only when the agent accepts images, and disabled at four attachments. Tooltip "Attach images
  (drop or paste also works), up to 4"; VoiceOver "Attach file".
- "/ commands" (only when pi reports commands): the "/" in mono (`Font.nw(.code)`), then
  "commands". It puts "/" in the field, which opens the slash menu.
- the model chip: the model's short name (after "provider/") in mono, truncating in the middle
  when the row is short of room (the provider prefix and the model's tail both show), with
  `NWChipChevron` (10pt, `textTertiary`) when it can change; tooltip "Model: <provider/id>", and
  VoiceOver reads the whole id
- the thinking chip: a 13pt `lightbulb` in `textSecondary`, "Thinking", then the level
  ("Medium") in `textPrimary` medium, and the chevron. It is hidden when the model has no
  reasoning control, as pi's levels for it (only Off), this Mac's catalog, or the host's
  `listModels` says; an unknown model keeps it.
- a spacer, then "Starting pi…" only while a slow pi keeps the thread waiting (see States),
  then the action, a 28pt circle: **Send** (a 14pt `arrow.up` in `textOnLantern` on `lantern`,
  at 35% until there is something to send) or **Stop** (a small rounded `stop.fill` square in
  `textOnFailed` on `failed`). While pi works with a draft, Stop steps aside **outlined** (a
  `lineStrong` hairline, no fill, `bgHover` under the pointer, the square in `failed`) and Send
  takes the corner, 6pt apart; filled Stop ⇄ outlined Stop + Send cross-fades (`content`).
  Tooltips: "Send (↩)", or while pi works "Queue (↩) · Steer now (⌘↩)"; "Stop the agent's turn"
  ("Stop the agent and its subagents" while subagents are live); "Answer the question first"
  while a question waits.

Chips (`.nwComposerChip(active:)`) are 26pt ghost buttons with 8pt side padding and radius 6, in
Geist 12 `textSecondary`, their parts 6pt apart, filled with `bgHover` on hover, on press, or
while their menu is open. A new model or level cross-fades in its chip (`content`); typing and
width changes stay instant. In a narrow thread (a docked side pane) the chips drop their words
("/" alone, the level without "Thinking") rather than truncate, once "Starting pi…" has dropped
its own.

**States:**

- **Idle:** Send. The placeholder is "Follow up, or / for commands…" ("Follow up…" when pi
  reports no commands), or "Describe the task, or / for commands…" on a fresh agent.
- **Running:** Stop (⌘.) while the field is empty; with a draft, Stop outlined and Send. The
  field keeps the idle placeholder (NWComposer's "Queue a follow-up — sent when the turn ends" is
  a departure; see the table). Send's tooltip names both ways, the Return setting's first:
  "Queue (↩) · Steer now (⌘↩)".
- **Accepting:** a spinner ("Waiting for pi") takes the button's place.
- **Starting:** Send is offered from the first frame, before pi has answered anything. A
  message sent while pi boots waits behind the spinner, still in the field, and goes once pi
  answers, as the field has it then (edited, or not at all once cleared). Once pi has kept the
  thread waiting for two seconds (`AppLayout.startingIndicatorDelay`; half a second over a thread
  with nothing to show, `AppLayout.blankStartingIndicatorDelay`), "Starting pi…" in
  caption `textTertiary` with a 10pt `textTertiary` spinner sits in the control row just before
  the action (its spinner gives way to the action's own while a message waits). It lives in a
  row that is always there, so it never changes the composer's height or moves the thread; it
  drops its words before the chips drop theirs, and fades out the moment pi answers. A normal
  start is over before it would show.
- **Error:** Send, plus a `failed` banner above the card, "Lost connection to the agent
  process.", with the error and Reconnect: only for a pi that was serving and went away, one
  that failed, or one that never started.

With more than one live subagent, Stop asks first (`StopAllDialog`): Stop only the agent, or
Stop all. Stop (the button, ⌘., or Esc in the composer) takes back what pi was about to read
before it aborts, so a steering message returns to the queue, and the queue then waits
(paused) until a new message, Send now, or a steer. There is no status text, key hint, or
working directory in or under the composer.

**Sending while pi works.** ↩ does what Settings ▸ Agents ▸ Return while pi is working says:
**Queue** (the default; the message waits in Up next and goes when pi settles) or **Steer**
(pi reads it once its current tool calls finish, before its next step). ⌘↩
(`alternateSend`, rebindable) always does the other one, ahead of any key equivalent in the
window (the review pane's ⌘⏎), and only while the composer or one of its queued messages has
focus. ⇧↩ inserts a newline; while pi is idle ↩ and ⌘↩ both send. Attachments ride along with a
queued or steered message.

**Send menu** (`NWSendMenu`): right-clicking Send, or holding it for
`AppLayout.sendHoldDelay` (500ms), while pi works with a draft, opens the choice at send time
(`.overlay`): beside the card, 8pt after its trailing edge and bottom-aligned with it, where
the thread has room for it and its margin (`Composer.sendMenuBeside`), so it covers none of Up
next; otherwise 8pt above the card with its trailing edge on the card's. It grows from the
corner nearest Send. Nothing about the choice is written under the composer.

- 268pt on the menus' popover, 6pt padding, rows 2pt apart; each row top-aligned with 8×10
  padding and the `runningTint` highlight: a 14pt glyph in `textSecondary`, the title in Geist
  13 medium with its description in caption tertiary beneath, and its keys as `NWKeycap`s.
- **Queue** (the queue glyph): "Goes when pi finishes this turn." **Steer now**
  (`arrow.turn.down.right`): "Lands once pi's current tool calls finish, before its next step."
- ↩'s cap sits on the Return setting's row, which is highlighted when the menu opens, and ⌘↩'s
  on the other. ↑↓ move, ↩ chooses, Esc closes, and a click outside closes it. While it is open
  Send wears a 3pt `lanternTint` ring (`hover`).

**Images** attach by drop, paste, or the paperclip (a file importer). They are resized on the
way in (longest edge 2000px), at most four per message and 2 MiB each, and shown as
`NWAttachmentChip`s in the row above the field (NWComposer, "with attachment"): 26pt, a
`lineStrong` line at radius 6, a 20pt thumbnail (radius 4) 3pt from the leading edge, 6pt, the
file name in Geist 12 `textPrimary` (truncating in the middle), and a small `textTertiary` ✕
that removes it ("Remove <name>" to VoiceOver). Problems show as a `failed` banner above the card:
"At most 4 images per message.", "<name> is not an image Shepherd can attach.", or "<name> is
over 2 MiB after resizing."

**Questions** from pi or an extension (select, confirm, input, editor) take the composer's
place, never a row in the scrolling thread, so a blocked agent is always answerable (QuestionAsk,
QuestionPick, QuestionAnswered, QuestionStates). pi stops and asks once; the thread above keeps
what pi found, and the question holds only the question, its answers, and yours.

**Today** (`QuestionPanel` in `Composer.swift`) the question replaces only the field, inside the
composer card, and the control row stays under it with Send disabled ("Answer the question
first"):

- the attention glyph (13pt) and the title in `ui`, then "1 / N" in micro tertiary when several
  wait
- the message in mono on `bgSunken` (radius 8, a `lineSubtle` line, scrolling past 140pt)
- a select's options as buttons that answer on click (the first primary), a confirm's Yes
  (primary) and No (y/n while the panel has focus), or an input's or editor's field (mono and
  5–12 lines for an editor) with Submit; each with a ghost Dismiss that cancels
- "pi may stop waiting for this answer" in micro tertiary when the question has a timeout; "An
  external editor is open · finish it before answering here" or "This question is too large to
  show here" when it cannot be answered here
- 10pt between its parts (`AppLayout.questionSpacing`); the card eases to the panel's height
  (`disclosure`), and the panel fades in (`content`)
- once answered, the panel goes and the field returns; nothing in the thread records the
  question (QuestionAnswered's record is not built), except the asking tool's own activity line
  when a tool asked. A select, confirm, input or editor dialog from an extension leaves no trace

**Not built yet: the question dock** (QuestionAsk, QuestionStates). It replaces the whole
composer card, not just its field. Its rules (QuestionStates › Rules):

1. **It takes the composer's place.** While pi waits, the bottom of the thread is the question:
   no attach, model, or thinking controls, nothing to confuse with a normal message.
2. **Context stays in the thread.** What pi found is in its message just above; the dock holds
   the question, the options, and your answer, nothing else.
3. **Label:** a question mark in lantern and a lantern outline. The thread and the sidebar show
   Needs you (the sidebar row's glowing dot and "ASK").
4. **Options** are numbered, and the number is the key. Each says what happens and what it
   costs. pi's recommendation is marked **Recommended**, never preselected.
5. **A note:** picking an option opens a note field inside it; the note goes with the answer.
6. **Something else…** is always the last row; typing there answers in your own words.
7. **Answer** is the only button. It lights up once an option is picked or Something else has
   text. There is no Dismiss: pi is waiting on an answer.
8. **After:** the composer comes back, and the thread keeps one line with the question and your
   answer as a bubble.

- **The dock** (`QuestionDock(question:options:recommended:)` on the board): `bgRaised`, radius
  12, a 1px `lantern` line inside a 3pt `lanternTint` ring, 12pt above and below and 14pt at the
  sides, 12pt between its parts, as wide as the composer card:
  - a 26pt header: a 13pt question-mark glyph and "pi is asking" in Geist 12 semibold, both
    `lanternText`, 7pt apart; trailing, a 26pt icon button, Hide the question (a 14pt chevron,
    `textSecondary`)
  - the question in Geist 16 semibold at 1.35, tracked -0.5% (`Font.nwSans(16, .semibold)`; the
    Kinds cards draw it at 15), inline code as in prose
  - the options, 6pt apart. An option is a card on `bgWindow` with a 1px `lineSubtle` line, radius
    8, 10pt above and below and 12pt at the sides, its parts 11pt apart: its number in a 20pt
    rounded square (a `lineStrong` line, mono 11 `textSecondary`; radius 4, `NW.Radius.xs`, for
    the board's 5); the title in `headline` (13.5 semibold) over its description in `ui` regular
    `textSecondary` at 1.45, 3pt apart; and, trailing at the top, a 20pt **Recommended** tag
    (`lanternTint` fill, `lanternText` 11 semibold, radius 4, 7pt side padding). The shared
    `NativeQuestionOption` (ShepherdRemote) already splits an option into number, title,
    description, and a trailing "(Recommended)".
  - **Something else…**: a row at least 38pt tall with its number and "Something else…" in 13.5
    `textTertiary`; typing there makes it a field in place.
  - a footer over a `lineSubtle` hairline, 12pt below the options: trailing, **Answer**
    (`.nw(.primary, size: .m)`, 28pt), disabled (40%) until there is an answer
- **Picked** (QuestionPick): the option takes a `lantern` line on `lanternTint`, its number fills
  (`lantern`, `textOnLantern` semibold), and a note field opens 8pt under its description
  (`bgWindow`, radius 6, a `lineStrong` line, 7pt above and below and 10pt at the sides, Geist 13
  at 1.45, the caret in `lantern`). The Recommended tag stays where it was. Picking another option
  moves the pick; nothing is answered until Answer or ↩.
- **Kinds** (QuestionStates › Kinds of question), one dock shaped by the answer pi needs:
  - **Yes or no:** short options side by side, 6pt apart, each 44pt (its number, the title in
    semibold, Recommended), answering on click; Answer is only for Something else.
  - **Pick several:** rows at least 40pt with a 14pt checkbox (`.nwCheckbox`: lantern with a check
    when ticked), the label (mono 13 semibold for a host or a path), and a note in 12
    `textTertiary`; a ticked row takes the picked style. Answer says how many ("Answer with 2
    hosts").
  - **Open question:** no options and nothing recommended: a field at least 64pt tall
    (`bgWindow`, radius 8, a `lineStrong` line, 10pt above and below and 12pt at the sides, 13.5
    at 1.5) and Answer.
  - **From a subagent:** "<name> is asking" (the question at 14.5, option titles at 13 over 12).
    It takes over only in the subagent's own view (the inspector, in place of its Steer
    composer); the parent thread keeps its composer. Today a subagent's question is answered on
    its card (Subagents › Needs you).
- **Hidden** (QuestionStates): Esc shrinks the dock to one 46pt line, so you can read the thread;
  it still holds the composer's place. The line is the same lantern card (radius 12, 14pt
  leading and 8pt trailing padding, 10pt between its parts): a 14pt glyph in `lanternText`, the
  question in 13.5 semibold (truncating), a small secondary **Answer** (24pt), and a 26pt Show
  the question button. Esc or Show the question brings the dock back.
- **The record** (QuestionAnswered; `QuestionRecord` on the board): where pi asked, the thread
  keeps one line in Geist 12.5 `textTertiary` (a 12pt glyph, "pi asked:", and the question in
  `textSecondary` medium, 7pt apart) and, 8pt below, your answer as a user bubble: the option's
  title in semibold with your note under it, 4pt apart, and "2:51 PM · answered" in mono 10.5
  tertiary beneath (on hover, like every bubble's time). pi's turn carries on under it.
- **Keys** (QuestionStates › Keyboard; shown in menus and tooltips): 1–9 pick an option, ↩
  answers, Esc hides or shows the question.
- **What pi can take:** pi's select answer is one of the options it offered, with no note or free
  text, and pi has no multi-select. By Honest affordances, the dock shows the note field,
  Something else, and Pick several only for an asker that can take them.

**Extension widgets** (an extension's `setWidget` text, ANSI stripped) appear above the card as a
micro caps title and its text. Machine payloads, `setStatus`, and `notify` are not shown.
Widgets are display-only, and the app chooses every font and color.

**Menus** float over the thread above the card, one at a time: left-aligned with it (the Send
menu beside the card, or at its trailing corner), 8pt above it (`AppLayout.menuGap`), and growing
from that corner (`.overlay`: from 96%, fading). They take no room in the composer, so opening one
never changes the composer's height, the thread's inset or scroll position, or any of the thread
outside the menu (`ComposerMenuTests`). A menu is never taller than the room above the card (it
keeps 8pt from the thread's top, `AppLayout.menuMargin`, and its list scrolls inside), and beside
a docked pane it narrows to the card. They share one anatomy (NWComposer › Menus):

- `.nwPopover()` at radius 12 (a 1px `lineStrong` line, `bgRaised`, the popover shadow), with 6pt
  padding (the model picker's parts carry their own)
- section headers (`NWMenuHeader`, 24pt; SlashMenu, ModelPicker): Geist 10.5 semibold, uppercase,
  tracked 6%, `textSecondary`, with an optional trailing count in mono 11 `textTertiary` ("4 of
  23"), 8pt from the sides (10pt in the model picker)
- rows (`NWMenuRow`, 28pt unless a menu says otherwise), radius 6 (the boards' 7 on the radius
  scale), 8pt side padding, their parts 10pt apart, with a `runningTint` highlight that the pointer
  moves too; the current choice wears a `running` check. Rows are not `Button`s (the field or the
  menu keeps keyboard focus), but they read as buttons to VoiceOver. A row never wraps: what does
  not fit truncates.
- ↑↓ move, ⏎ chooses, Esc closes and returns focus to the field, and a click anywhere outside
  the menu and the card closes it (the click still lands where it was aimed). No footers; the
  only key hints are the slash menu's ⏎ and the model picker's chord.

- **Slash menu** (`NWSlashMenu`; SlashMenu): opens when the draft is "/…" with no space yet (or
  from the chip). It spans the composer card, from its leading edge to its trailing one, 8pt above
  it. "Commands" with "n of m" (matches of all); then one-line 36pt rows
  (`NWComposerMetrics.slashRowHeight`) with 12pt sides, their parts 12pt apart: the command in
  mono 12.5 with the typed prefix in semibold `textPrimary`, the rest in `textSecondary` and its
  argument hint in `textTertiary`, in a column at least 150pt wide that grows to the whole name
  rather than wrap (`/shepherd-subagents-fleet` stays one line); the description in Geist 13
  `textSecondary`, truncating at its end; its source as an `NWTag` for prompt templates and skills
  ("prompt", "skill"; none for extension commands); and on the highlighted row a trailing ⏎ in
  mono 11 `running`. The whole command is its tooltip. Commands whose name starts with the query come first, then those whose
  name or description contains it. At most 8 rows show, fewer when the room above the card is
  shorter; with none, "No command matches “/re”" in caption tertiary. ⏎ or a click puts "/name" in
  the field and sends it when it can; ⇥ completes "/name " to keep typing. Esc closes it for the
  draft as typed; typing more reopens it. The list is pi's command registry, never hard-coded, so
  pi's interactive built-ins, which the boards draw (/resume, /reload), appear only if pi's
  `get_commands` starts returning them. Its rows are lazy, a highlight moving redraws only the two
  rows it moves between, and only ↑↓ scroll the highlight into view (the pointer's is already under
  the pointer).
- **Not built yet:** argument hints after the name in `textTertiary` ("/resume [session]",
  "/release-notes [tag]"; NWComposer, SlashMenu). `NWSlashCommand.arguments` draws them, but pi's
  `get_commands` does not send them, so the app has none to show.
- **Model picker** (`ModelPicker` on `NWModelPicker`, 380pt, its list at most 360pt tall;
  ModelPicker): from the model chip or ⇧⌘M, either of which also closes it (without `setModel` it
  beeps). A 30pt search row takes focus: a 12pt `magnifyingglass` in `textTertiary`, "Search
  models" in Geist 13, the picker's chord trailing in mono 11 `textTertiary` ("⇧⌘M", from
  `KeybindingsStore`), and a hairline under it. The list sits 4pt in from the top and bottom and 6pt
  from the sides: **Recent** (the last four models picked in any thread, newest first;
  `RecentModels`), then one section per provider in catalog order, headed with the provider's name
  4pt below what precedes it, leaving out what Recent shows. Rows are 40pt
  (`NWComposerMetrics.modelRowHeight`) with 10pt sides, their parts 10pt apart: a 12pt column
  holding a `running` check on the current model; the model's short name in mono 12.5
  `textPrimary`, truncating in the middle, so a long id keeps its provider prefix and its tail
  ("~anthropic/claude-o…pus-4-8"), over a second line in caption `textSecondary`: "Current · this
  thread", "Used 2h ago in “Plan shepherd extensions”" for a recent model (when and in which thread
  it was picked), else "With thinking" or "No thinking" as the catalog says (ModelPicker's
  "Faster, cheaper" has no source in pi's catalog; Honest affordances); and, trailing, its context
  size in mono 11 `textTertiary` ("200K", "1M"). The whole id is the row's tooltip and what
  VoiceOver reads. A query keeps the models whose id contains it and moves the
  highlight to the top. While the catalog loads, the list opens with a 12pt spinner and "Loading
  models…" in caption tertiary. Choosing sets the model, records it in Recent, and returns focus to
  the field; it picks the model only. A catalog runs to hundreds of models, so the list is lazy
  (only the rows on screen exist), derived once per catalog and query rather than while drawing
  (`ModelCatalog`, `ModelPickerState`; this Mac's catalog is asked once per process, off the main
  actor), and a hover moves the highlight without redrawing the list or scrolling it
  (`ComposerMenuPerformanceTests`).
- **Thinking menu** (`NWThinkingMenu`, 220pt; NWComposer): from the thinking chip, which also
  closes it. "Thinking", then one 28pt row per level pi offers the thread's model
  (`get_available_thinking_levels`, carried as the snapshot's `thinkingLevels`), in pi's order:
  Off, Minimal ("fastest"), Low ("quick"), Medium ("default"), High ("slower, deeper"), Extra
  high ("deeper still"), Max ("slowest, deepest"). A reasoning model usually has Off to High with
  Minimal; Extra high and Max only where pi maps them; a host that does not say offers Off, Low,
  Medium and High. The level in `ui` regular `textPrimary`, its note in Geist 12 `textTertiary`,
  and the check on the current level, trailing. It takes focus with the current level
  highlighted. The chip names the level the same way ("Extra high").
- **Agent context menu** (NWComposer › Menus: "Native NSMenu in Swift; shown for spec"): a
  native menu (`.contextMenu`), never a custom popover: Rename… with its keys (⌘R), Fork from here
  and Copy transcript (each with its glyph), a separator, Open in Finder, a separator, and Delete
  agent… as the destructive item (`role: .destructive`). The sidebar's agent menu is today's
  (Sidebar › Context menus). **Not built yet:** Fork from here, Copy transcript, and Open in
  Finder for an agent (the subagent inspector has Fork, Copy Transcript, and Show Session File in
  Finder for a finished run), and ⌘R shown beside Rename….

### Up next (the queue)

Messages sent while pi works stack in **Up next** (QueueStack, QueueSteer, QueueEdit, QueueStates;
`QueueStackView` in `Thread/QueueStack.swift`, on ShepherdUI's `NWQueueStack` and `NWQueueRow`;
sizes are `NWQueueMetrics`): a card directly above the composer card, in the same column,
`AppLayout.menuGap` (8pt) above it, under any widgets and banners. The host holds the queue
([native-thread.md](docs/native-thread.md) › The queue; its rules are `NativeQueueRules`, shared by
the host and every client), so every Mac viewing the agent sees and edits the same one. Nothing in
it has reached pi, except a Steering row. Each message can be steered in now, edited, reordered, or
deleted. **Queue** means it waits and goes when pi finishes this turn; **Steer** means pi reads it
once its current tool calls finish, before its next step (the departures table says why not "after
the tool call pi is running now").

- **Placement:** it shows while it has a row to show: a message, or an Undo row (a lone Undo row
  reads "Up next 0"). The card never moves: the stack grows upward, and the thread's inset follows
  the composer's measured height, so the thread keeps its last turn in view
  (`QueueStackIntegrationTests`). Collapse and Show more are view state (`QueueStackState`) and
  are never saved; the stack forgets its expansion once it empties.
- **The card:** `bgRaised`, a 1px `lineStrong` line drawn inside (`nwBorder`), radius `NW.Radius.m`
  (8). A 32pt header (`NWQueueMetrics.headerHeight`; 12pt leading, 6pt trailing, items 8pt apart, a
  hairline beneath): the queue glyph (`NWQueueGlyph`, 12pt, `textTertiary`: a line, then two
  indented lines behind a play mark), "Up next" in `.nwSans(12, .semibold)` `textSecondary`, the
  count in `.nwMono(11)` `textTertiary` (every message, steering ones included, never an Undo row;
  it rolls, `content`), "Paused" in `.nw(.caption)` `textTertiary` while the queue waits (its
  tooltip is the host's reason, else "The queue waits for you: send it, steer it in, or send a new
  message."), a spacer, then ••• (`NWOptionsMenu("Queue options")`) and Collapse (`chevron.down`;
  tooltip "Collapse the queue", or "Expand the queue"), both 24pt circular icon buttons
  (`NW.Height.controlS`). The chevron turns up while collapsed, and a collapsed stack is its header
  alone. Rows follow, a hairline above each but the first; they keep to the card's bottom corners.
- **A queued row** (`NWQueueRow`; QueueStack, QueueStates · queued and hover; 40pt, not scaled by
  Density; 8pt leading, 6pt trailing, items 8pt apart): the grip (`NWGripGlyph`, six `textTertiary`
  dots in an 8×14 slot, shown on hover or focus: the only drag handle, with the open-hand pointer,
  closed while dragging), its number (`NWQueueNumber`: `.nwMono(10.5)` `textSecondary` in an 18pt
  `lineStrong` ring: the order it goes, not a count, never counting Steering or Deleted rows; it
  rolls when the order changes), the text in `.nwSans(13)` `textPrimary` on one line, truncated at
  the tail (a click edits it; tooltip "Edit"), its attachments (below), and an 82pt slot
  (`NWQueueMetrics.actionsWidth`) that always keeps room for its actions, so hovering never
  re-truncates the text. The actions are built only while the row is hovered or focused: Steer now
  (`arrow.turn.down.right`; **Send now** while pi is idle), Edit (`pencil`), and Delete (`trash`),
  26pt circular icon buttons (`.nwIcon`: 14pt glyphs in `textSecondary`; under the pointer
  `textPrimary` on `bgHover`, and `bgSelected` while pressed) 2pt apart, with system tooltips
  naming their keys ("Steer now  ⌘↩", "Delete  ⌫"). Hovered, the row is `bgHover`; with
  keyboard focus it is `bgSelected` with the `focusRing` ring drawn inside it (2pt, inset 2pt,
  radius 6), since a ring outside would cover its neighbours.
- **Attachments** (QueueStates · with attachments) ride along with the message and sit after its
  text as compact chips (`NWAttachmentChip(size: .compact)`, 4pt apart): 22pt, a 1px `lineStrong`
  line, radius 4, the name in `.nwSans(11)`, 6pt padding; an image leads with its 16pt thumbnail
  (radius 3, 3pt leading), or an 11pt `photo` glyph where the bytes stayed on another Mac. The
  chips keep their width and the text truncates first. **Not built yet:** the board says elements
  from the browser and files ride along too. An element chip (an element picked in the Browser
  side pane, PaneBrowser) leads with an 11pt element glyph (a dashed square with a pointer) in
  `textSecondary`, then its selector in `.nwMono(11)`, e.g. "button.pay". The board draws no file
  chip. Today a queued message carries images only (Composer › Images).
- **A Steering row** (QueueSteer, QueueStates · steering): always first, above the queued rows, in
  the order they were steered, on `runningTint` (hovered or focused too; focus adds the ring): the
  grip's slot stays empty, then a bare 14pt `running` spinner where a queued row has its number (so
  its text starts 4pt further left), the text, `NWStatusPill(.running, label: "Steering", symbol:
  "arrow.turn.down.right")`, and Back to the queue (`arrow.uturn.backward`, a 26pt icon button 4pt
  after the pill), both shown at rest, not only on hover. Back to the queue returns it to the queue
  as #1 until pi reads it; if pi has already read it, the host refuses ("pi has already read that
  message." as the composer's notice) and the message lands in the thread where pi read it. It has
  no grip, number, Edit, or Delete, its text is not a click target, and nothing drops above it.
  Stop also returns every Steering row to the queue (Composer › States).
- **Editing** (`NWQueueEditor`; QueueEdit, QueueStates · editing): a click on the text or the
  pencil, ↩ on a focused row, or ↑ in an empty composer with no menu open (for the last queued
  message) opens the row in place. The row sinks to `bgWindow` with 8pt padding (24pt leading, so
  the number keeps its column): the number top-aligned beside a field of one to six lines
  (`.nwSans(13)` at the board's 1.5 line height, `textPrimary`, 8×10 padding, `bgRaised`, radius 6,
  a `lantern` line inside a 3pt `lanternTint` ring, a `lantern` caret after the text, placeholder
  "Queued message"), and under it, trailing and 6pt apart, Cancel (`.nw(.ghost, size: .s)`) and Save
  (`.nw(.secondary, size: .s)`, since Send stays the surface's primary; disabled while the text is
  empty). ↩ saves, ⇧↩ adds a line, Esc cancels. The message keeps its place and number. One editor
  is open at a time: opening another cancels the first. While it is open, the host holds the queue
  (renewed every `AppLayout.queueHoldRenewal`, a minute; a hold lapses after two), so nothing is
  delivered under you; saving unchanged text only releases the hold. If the message leaves the queue
  meanwhile (another Mac steered or deleted it), the editor closes.
- **Deleted** (`NWQueueDeletedRow`; QueueEdit, QueueStates · deleted): the delete goes to the host
  at once, and an Undo row takes the message's place, cross-fading in the same 40pt (34pt leading,
  `NWQueueMetrics.secondaryInset`, so it starts under the number column; 12pt trailing): a 12pt
  `trash` glyph, "Deleted" and the struck-through text in `.nw(.ui, weight: .regular)`
  `textTertiary` on one line, and Undo (`.nwLink(font: .nw(.ui))`, `running`). It counts in neither
  the header nor the numbers. It closes after `AppLayout.queueUndoWindow` (5s), counting only while
  the pointer is off it, and Undo puts the message back where it was. Clearing the queue leaves one
  such row, "Cleared 3 messages" ("Cleared 1 message"), that puts them all back. A message that
  comes back another way (Undo on another Mac, or a delete the host refused) takes its Undo row's
  place.
- **Long stack** (QueueStates · long): up to three rows (Steering, queued, and Undo rows alike) all
  show; past three, the first two and "Show N more" (`NWQueueMoreRow`: a 32pt row, 34pt leading,
  `.nwLink(font: .nwSans(12))` in `running`), so the thread keeps its room. It expands the stack in
  place ("Show fewer"). Expanded past six rows, the rows scroll inside a 240pt frame
  (`NWQueueMetrics.expandedMaxRows` × 40) with "Show fewer" pinned beneath. An editor opened below
  the fold expands it.
- **Reordering** (QueueStates · reordering): dragging the grip lifts the row out of the stack onto a
  floating card (`bgRaised` under `bgHover`, radius 8, a `lineStrong` line, the popover's shadow
  (`nwFloatShadow`), a 1° counter-clockwise lean, `NWQueueMetrics.liftTilt`), 22pt right of its slot
  and 14pt past the stack's trailing edge (`NWQueueMetrics.liftInset`), over its neighbours, the
  drop line, and the composer card. It keeps its grip but shows no actions, and follows the pointer
  at once, up to half a row past the first and last rows. Past the middle of a neighbour it takes
  the neighbour's side: the neighbours step aside (`list`), and a 2pt `lantern` drop line
  (`NWDropIndicator(color: .nw.lantern)`, inset 8pt each side) tops the gap. Letting go where it
  began changes nothing. Nothing drops above a Steering row. ⌥↑ ⌥↓ move a focused row one place.
- **The ••• menu** (QueueStates · QueueOptions; native, `NWOptionsMenu`): Steer all now
  (`arrow.turn.down.right`; **Send all now** with `arrow.up` while pi is idle), a divider, the
  section "When the turn ends, send" with an inline picker of One message per turn and Everything at
  once (a check on the current one; this agent's choice, else the host's default from Settings), a
  divider, and Clear the queue (`trash`, destructive, leaving its Undo row; Steering rows stay).
  Steer all and Clear are disabled while nothing is queued. **Everything at once** is the default:
  the queue arrives as one turn, in order, the messages joined with a blank line; a message that
  starts with "/" goes alone, and one delivery carries at most 4 images and 64 KiB
  (`NativeQueueRules.batchCount`).
- **Keys** (QueueStates · Keyboard; shown in menus and tooltips and listed under Settings ▸ Keyboard
  ▸ While pi is working, never written in or under the composer): ↩ sends queued and ⌘↩ sends and
  steers now (swapped when the Return setting is Steer; Composer › Sending while pi works); ↑ in an
  empty composer edits the last queued message; ⌥↑ ⌥↓ move the focused message; ⌫ deletes it; ⌘↩
  steers it (sends it now while pi is idle); Esc in the composer stops pi. With keyboard navigation
  on, ⇥ reaches the rows. On a focused row ↑ ↓ move between rows (↓ past the last returns to the
  field), ↩ edits, and Esc or ⇥ return to the field. Deleting a focused row hands focus to the next
  row, else the previous, else the field. On a focused Steering row only ↑ ↓, Esc, and ⇥ do
  anything.
- **Settings** (QueueStates · Settings › Agents · While pi is working; see Settings): two rows, each
  an `NWSegmentedPicker`. "Return while pi is working", subtitle "⌘↩ always does the other one."
  (the chord as `KeybindingsStore` shows it): **Queue** (the default) or Steer. "When a turn ends,
  send the queue", subtitle "All at once arrives as one turn, in order.": One per turn or **All at
  once** (the default); it is the host's default for its agents, and each agent's ••• menu overrides
  it. **Not built yet** on iPhone and iPad: the board gives every platform the same two choices, and
  iOS Settings has neither row today (the delivery mode is only in each thread's Up next menu).
- **Motion:** the stack comes and goes with `list` from the bottom (the card stays anchored); a
  queued row rises from the bottom, and a row pi takes leaves toward the thread (`list`) while the
  numbers roll (`content`); hover fills, the grip, and the actions fade (`hover`) in slots that
  are always laid out; Steer now and Back to the queue move the row (`list`) while its number and
  spinner, and its actions and pill, cross-fade (`content`); Show more and Collapse disclose
  (`disclosure`). No bubble flies from the stack into the thread.
- **In the thread** (QueueStates · In the thread, QueueSteer; Thread › From the queue and Steered):
  queued messages join the thread only when they reach pi, each keeping the time you sent it. A
  delivery opens with `NWQueueDivider` ("From the queue · 2") and one bubble per message, then pi's
  turn. A steer stands where pi read it, between tool calls, in a bubble with a `running` outline
  under "Steered". No line says what a steer skipped (see the departures table).
- **Limits and refusals:** the host holds at most 32 messages and 64 KiB of text. A send past that
  is refused with "The queue is full. Send it or clear some of it first." Like any refused queue
  action, the host's message shows as the composer's notice line above the card (caption
  `textTertiary`). A delivery pi refuses puts the messages back at the head and pauses the queue,
  with the reason in the header's tooltip.
- **Accessibility:** the header reads "Up next, 3 messages". A queued row reads "Queued 2 of 3:
  <text>" with the actions Steer now (or Send now), Edit, Delete, Move up, and Move down; a Steering
  row reads "Steering: <text>, waiting for pi's current tool calls" with Back to the queue; the
  editor's field is "Edit queued message 2"; an Undo row reads "Deleted: <text>" (or "Cleared 3
  queued messages") with Undo. The glyph, the grip, and the number are hidden from VoiceOver.

### Subagents

A subagent is a turn inside a turn (NWAgents; Subagents, SubagentsDone, SubagentCards). Its spawn
call renders as a card where the call was, and raw wait or status dumps never appear. Subagents
live in their agent's thread and the palette; they have no sidebar rows, and one waiting on you
marks its agent's row instead (see Sidebar). Finished runs stay browsable: the ledger keeps every
run, and the inspector opens any of them. Behavior is specified in
[native-subagents.md](docs/native-subagents.md).

The NWAgents board is the authority for these components. The macOS page boards (Subagents,
SubagentsDone, SubagentCards) draw an earlier version with more on each card; where they disagree
with NWAgents, Shepherd follows NWAgents, and the table in "Where Shepherd departs from the
boards" lists each difference.

The components are ShepherdUI's Agents set (`Components/Agents`); `SubagentPresentation`
(`Thread/SubagentPresentation.swift`) maps a `ChildRun` onto their values, `Thread/Subagents.swift`
lays them out, and state always comes from `AgentState` (a queued run and a run paused before its
next model request both draw as `queued`).

- **Layout per turn** (`SubagentPresentation.layout`): cards for up to three sibling runs
  (`NativeRunsStrip.collapseThreshold`); a runs strip plus the cards that need you for more; a
  ledger once every run in the group has finished and none still asks. Siblings sit in spawn
  order, 8pt apart (`AppLayout.subagentStackSpacing`), as are the strip and the cards under it.
  Once cards stand for a turn's children, the parent's `shepherd_child_wait` and
  `shepherd_child_result` calls no longer show as activity, and nothing else names them: no raw
  wait or status call shows anywhere, the parent's working row included (SubagentCards: never a
  raw "subagent_wait" dump; the app still does, see Known gaps).
- **Changing shape:** the group reshapes at once, because the rest of its turn (the next card,
  "Working…") moves at once too. What arrives while the group is on screen (a strip, the ledger in
  place of the cards, a card that needs you, the cards the strip shows) fades in where it lands
  (`nwRunArrival`); a card keeps its identity when the group folds into the strip.
- **`NWSubagentCard`** (NWAgents): `bgRaised`, padding 10×12 (the board's 10pt vertical inset),
  8pt between its lines, radius 8, a 1px `lineSubtle` line (`lantern` while it needs you).
  Clicking anywhere on the card opens the run in the inspector; the inspected card wears a
  `running` line and a 3pt `runningTint` ring outside it. Only the line's color and the ring
  ease; the card's size changes at once.
  - **Header** (8pt gaps): `NWBranchGlyph` at 13pt in the state's color, the name in `ui`
    semibold, a role `NWTag` (18pt, Geist 11 on `bgSelected`, radius 4) when it differs from the
    name, the model as a mono `NWTag` (Geist Mono 10.5; the last path part, "claude-sonnet" from
    "anthropic/claude-sonnet"), and the `NWStatusPill` (20pt) trailing. In a narrow thread the
    tags give way (the model first) before the name truncates, at once.
  - **One mono line** under the header (Geist Mono 11, `textSecondary`): the detail truncates at
    its tail and anything after it (" · 26 tools · 12m", a live wait) stays whole. Then per state:
    - **Running:** the latest call, a path shortened to its file name ("edit ThreadView.swift",
      "bash swift test"; "working" before the first). Under it the context window used: a 4pt
      `.nwBar` (`running` on `lineSubtle`, radius 2) and its percent in Geist Mono 10
      `textTertiary` ("62%"), with "Context window used" as its tooltip and VoiceOver label. The
      card never grows while it runs.
    - **Queued / Paused:** an outlined pill ("Queued", or "Paused" for a run paused before its
      next model request) and "waiting to start" or "paused before its next model request".
    - **Needs you:** "waiting on your answer · 2m" (the wait counts from the child's
      `shepherd_parent_message` call, or shows no figure). Under it the question box:
      `lanternTint`, radius 6, padding 8×10, 6pt gaps; the question as inline Markdown in `ui`
      (code spans Geist Mono 11.5 on `bgHover`, links `running`, selectable); then its answers as
      `s` buttons, the first primary and the rest secondary, and Reply… (ghost; secondary when
      there are no answers). The buttons wrap to a column when a row does not fit. Reply… opens
      a field ("Reply to <name>…") with a secondary `m` Send; ⏎ sends and the field closes.
    - **Done:** what it did, the first sentence of its summary (else its output) without its
      final period ("finished" without either), then " · 26 tools · 12m".
    - **Failed:** the exit reason, then Open replay (secondary `s`, the inspector) and Re-run
      (ghost `s`).
  - **Not built yet: several questions at once** (SubagentCards). A run with more than one
    pending question shows the first, with "1 / 2" in Geist Mono 11 `textTertiary` trailing its
    answers; answering one shows the next. `ChildRun` carries one question today, so the
    protocol must carry a list first.
  - **Live controls** sit in the card's context menu and its accessibility actions, and the
    inspector shows them: Inspect; while live, Pause (or Continue) for a running or queued run,
    with the tooltip "Pause before the next model request; current tools finish normally", and
    Stop (destructive); for a failed run, Re-run. They are disabled while the thread can't take
    commands (its agent is off screen, or its host has no subagent control). Only elapsed text
    re-renders on a clock (`NWElapsedText`, ticking exactly when its text changes, anchored to
    when it counts from, static once finished).
- **`NWRunsStrip`** (SubagentCards, in NWAgents' form): more than three sibling runs fold into one
  row in the ledger header's form: a 32pt `bgSunken` row, radius 8, a 1px `lineSubtle` line,
  10pt gaps, 12pt side padding. In it: the glyph (needs you, else running, else queued, else
  failed, else done), "12 subagents" in `ui` semibold, one step per run in spawn order (8pt wide,
  3pt tall, 3pt apart, radius 2; queued and paused steps are filled `lineStrong`), the tally in
  Geist Mono 10.5 `textTertiary` ("7 done · 3 running · 1 queued · 1 paused · 1 needs you · 1
  failed", in that order, each run counted as its step draws it), tokens ("581k tok") and the
  group's elapsed time, and a 9pt chevron that turns down while the cards show.
  - Each step is its own button: clicking it opens that run in the inspector, as its card does.
    Its target is the step plus half the gap on each side, the row's full height, so steps tile
    with no dead gap. Its tooltip names the run and its state ("worker, running"), and a hovered
    step thickens to 5pt; at rest the strip is unchanged. A click anywhere else on the row shows
    or hides every card.
  - When the row runs out of room the totals give way (tokens first) before the tally truncates.
  - Runs that need you keep their own card under the strip.
- **`NWRunLedger`** (NWAgents, SubagentsDone): once every run in the group has finished, the
  cards are replaced in place by a permanent ledger on `bgWindow`, radius 8, a 1px `lineSubtle`
  line. It is lazy, so a workflow of hundreds of runs builds only the rows on screen.
  - A 32pt `bgSunken` header (10pt gaps): the glyph (`done`, or `failed` when any run failed),
    "3 subagents" in `ui` semibold, one step per run (14pt wide, 3pt tall), "all done · 45m" (or
    "2 done · 1 failed · 45m") in Geist Mono 10.5 `textTertiary`, and trailing the combined diff
    stat in Geist Mono 11 when there is one.
  - One row per run in spawn order, a hairline above each (`rowComfortable`, 36pt × density, 12pt
    side padding, 10pt gaps): the 6pt state dot, the name in `ui` semibold in a 70pt column
    (scaled with the text size), a one-line summary in `ui` `textSecondary` (the exit reason in
    `failed` for a failed run), "5 files · 41m" in Geist Mono 10.5 `textTertiary` (files only
    when there are some), and a 9pt chevron.
  - A row opens the run in the inspector (again closes it). Hover is `bgHover`; the open row is
    `runningTint` with a 2pt `running` rule on its trailing (pane) side and a `running` chevron.

### Mission components (not built yet)

**Not built yet.** The NWAgents board's second half (dark and light): the components Missions
will use (Missions are not built; see "Where Shepherd departs from the boards"). Build them into
`Components/Agents` when Missions land.

- **`NWMissionNode`** on a dotted canvas (Mission graph): the canvas is `bgSunken` with 1pt
  `lineStrong` dots every 18pt, padding 20, radius 8, a `lineSubtle` line; stages run left to
  right with arrows between them. A node is 200pt wide, `bgRaised`, radius 8, padding 9×11, 6pt
  gaps: the name in `ui` semibold with its `NWStatusPill` trailing, the role as an `NWTag`, and a
  Geist Mono 10.5 `textSecondary` line that truncates ("DesignTokens.swift +214", "edit
  ThreadView.swift", "asks: keep alias?", "failed 3 of 3 tries", "+ ~250k · 15m", "after
  Verify"). States: done, running, needs you and failed with a 1px `lineSubtle` line; the
  selected node has a 1.5pt `running` line and a 3pt `runningTint` ring; proposed has a 1.5pt
  dashed `running` line and a "proposed" `NWTag` in place of the pill; draft or queued has a 1pt
  dashed `lineStrong` line and the outlined Queued pill.
- **`NWInboxItem`** (mission control inbox): padding 12×14, 6pt gaps, radius 8, a 1px
  `lineSubtle` line and a 2pt leading rule in the state's color. First line in `caption`
  `textSecondary`: the state dot (glowing while it needs you), the kind in semibold
  `textPrimary` ("Question"), " · ios · Ship native UI v2", and the age trailing in mono
  `textTertiary` ("2m"). Then the question in Geist 13 medium, then its answers as `s` buttons
  (the first primary, the rest secondary) and Open (ghost).
- **`NWClaimRow`** (evidence review): padding 10×12, 6pt gaps, radius 8, a `lineSubtle` line;
  the claim in `ui` medium (line height 1.4) with its verdict pill trailing, then its evidence
  as `NWTag`s ("3 tests", "before / after", "spec §5"). The verdicts are Verified, Contradicted
  and No evidence; the board draws only Verified (`done`), so choose the other two's states
  when building.

### Side pane: Changes and the subagent inspector

One pane per window beside the agent's layout (`RightPaneSplit` around the whole layout in
`AgentLayoutView`, its tabs in `SidePaneView`; PaneStates, Review, Subagents, SubagentsDone). It
sits at the workspace's trailing edge beside the thread and its terminal panel, at its full
height, and the dock rule measures the main column, never the thread's own pane. Its sizes and
adaptive rule are in "Window and adaptive layout" above. It shows only the tabs Shepherd has:
**Changes**, the review. Browser, Artifacts and Files are specified below and are not built, so
they have no tab and no placeholder (the user's decision, 2026-09-25: "dont show browser,
artifacts, files, etc, only show the things we have"); each joins `SidePaneTab` when it is.

- **Showing and hiding:** ⇧⌘B, the header's side-pane button, or View › Show Side Pane / Hide Side
  Pane. Showing opens the pane on its tab (Changes starts the review); hiding also closes an
  inspected subagent, and discards the review like a cancel. ⌃1 (View › Changes) shows Changes in
  front of an inspected subagent; it is fixed, like ⌃⇧1–9, and ⌃2–⌃4 wait for the other tabs.
  Review Changes (a sidebar row's menu), the palette's Show changes, the chip's Show Changes, a
  thread's "review ›" link and the inspector's file links show Changes too.
- **Nothing opens by itself** (PaneStates): when pi opens something for the pane (today, an
  agent's `review_diff`), the review is readied and the Changes tab takes a 6pt `running` dot
  after its count. The pane never opens, and never switches tabs or covers an inspected subagent,
  on its own. While the strip is out of sight (the pane closed, or a subagent inspected over it)
  the header's button takes the dot instead, and a tip hangs under it for 4 seconds and again
  while the button is hovered (`NWPaneNewsTip`: "pi opened a review in Changes" in `caption` with
  a 12pt glyph and the ⇧⌘B keycaps, on `bgRaised` at radius 12 with the popover shadow). Showing
  the tab clears its dot; a request while Changes is on screen just reloads it.
- **The tab strip** (`NWSidePaneTabs`; SidePaneTabs): 44pt so it lines up with the toolbar, on
  `bgWindow` with a hairline beneath, 10pt side padding, tabs 2pt apart. A tab is 28pt, padding
  0×10, radius 6, 6pt gaps: a 14pt glyph, the label in `ui` medium `textSecondary`, the count in
  `micro` regular `textTertiary` (Changes: the review's files, once loaded), and pi's dot. The
  current tab has the `bgSelected` fill, `textPrimary`, semibold; a tab's tooltip has its ⌃ chord.
  Then a spacer, the pane's ⋯ menu and close ("Hide side pane" with ⇧⌘B), 28pt `nwIcon`s 4pt
  apart. **Narrow:** under 480pt the labels drop (padding 0×9); glyphs, counts and dots stay.
- **The ⋯ menu** (`SidePaneOptions`, "Pane options"): the current tab's items (Changes: Expand All
  Files, Collapse All Files, a divider, Copy Review as Text), a divider, then Reset Width
  (disabled at the default). Split below, Open pane in its own window and Show tabs are left out
  until they can work (see the departures).
- **The subagent inspector takes the pane over** (Subagents, SubagentsDone) with its own header
  in place of the strip, whichever path inspects a run (⌘I, a tray row or card, the palette).
  Closing it goes back to the tab underneath when the pane was open, and hides the pane when it
  wasn't. The header's button stays lit while it shows.
- **Layout:** the thread keeps running beside the pane. A pane never replaces the thread and
  never changes the persisted layout. The sidebar keeps its width. The pane slides in from the
  trailing edge (`.pane`); when the inspector and a tab swap, or a new review replaces one, its
  content cross-fades (`.content`) while the pane stays put. Stepping between runs is the
  inspector's own motion (below).

**Subagent inspector** (`Thread/SubagentInspector.swift`):

- **`NWInspectorHeader`** (NWAgents), 44pt to line up with the toolbar (`AppLayout.headerHeight`),
  12pt leading and 6pt trailing padding, a hairline beneath: the branch glyph at 13pt in the run's
  state color, then "name · k of n" (the name in Geist 13 semibold, " · 3 of 3" regular
  `textSecondary`; the position only with more than one sibling) over a Geist Mono 10.5
  `textTertiary` line: "model · thinking high · 78 turns · 922k tok" while live, "model · 11
  turns · done 11:02" once finished, the last part in the state's color; the full line is its
  tooltip. A run that has left the list reads "no longer listed". Trailing, 4pt apart:
  Pause/Continue (secondary `s`, with the card's tooltip) and Stop (danger `s`) for a live run,
  ‹ › (28pt `nwIcon`, "Previous subagent", "Next subagent", disabled at the ends) to step through
  siblings, a ⋯ menu (`NWOptionsMenu` "Inspector options": Refresh Transcript while live; Copy
  Transcript and Show Session File in Finder once finished), and close ("Close the inspector").
- **Stepping runs:** inspecting another run swaps it in place, whichever path chose it (‹ ›, a
  card, a strip step, the palette): a sibling nudges in from the side it sits on in spawn order
  (`.list`), any other run cross-fades. Each run starts fresh: its transcript, draft and scroll.
- **`NWRunBrief`** (NWAgents) on `bgSunken`, padding 10×12, 8pt gaps: GOAL (Geist Mono 10, caps,
  0.5pt tracking, `textTertiary`), with "step n / m · 62%" trailing in Geist Mono 10.5
  `textTertiary` while live; the goal in `ui` `textSecondary`, up to six lines, selectable. Once
  finished, RESULT with its label in the state's color and the result in `ui` `textPrimary` as
  inline Markdown (up to eight lines; a failed run's exit reason). Under it, up to five touched
  files as `running` links in Geist Mono 11, truncated in the middle, each with its diff stat
  (Geist Mono 11): a link opens the review pane at the file ("Review this file"), or reveals it
  in Finder where there is no review. Then "n more files" in Geist Mono 11 `textTertiary`.
- **The run's own transcript**, drawn with the thread's components one step smaller
  (`nwProseSize` `.small`), 14pt padding, turns 16pt apart, times and footers on hover as in the
  thread. A live transcript opens at its end and follows; a finished one opens at its start. A
  live one ends in a working row: the call in flight ("Running bash swift build…"; its session
  file holds only finished calls), "Pause requested", or "Thinking…". Turns that arrive while it
  follows fade in where they land. With nothing yet it says "No transcript yet." (or "This run is
  no longer listed.") in `caption` `textTertiary`.
- **Its footer line** (28pt, Geist 11 `textTertiary`, 14pt side padding): "72 earlier turns" in
  mono with a Show all link ("Loading…" while it pages) when older turns are not loaded, and
  trailing "Following live" (or "Reading earlier output") while the run is live. Scrolling up
  stops following; scrolling back to the end resumes it.
  - **Not built yet** (SubagentsDone): a finished run's footer reads its position, "turn 4 of 11"
    in mono, with "Scroll for the rest" trailing while there is more below.
- **A Steer composer** while the run is live (Subagents): the composer card's anatomy on
  `bgRaised`, radius 8, a `lineStrong` line (`textTertiary` with a 3pt `bgSelected` ring while
  focused), set in 10pt from the top and 12pt from the sides, under a hairline. The field ("Steer
  <name> — delivered before its next turn") is `body`, one to six lines; ⏎ sends, ⇧⏎ adds a line.
  Beneath it "to: <name> · not the parent" in Geist Mono 11 `textTertiary` and a primary `m`
  Steer, disabled while the draft is empty. A failed send keeps the draft, and the store's notice
  shows under the card in `caption` `textTertiary`.
- **A finished run is read-only:** messages from the parent are captioned "from parent" ("10:58 ·
  from parent" while hovered; your own steers are not), and `NWRunActions` (padding 10×12, a
  hairline above) replaces the composer: Re-run (secondary `s`), Fork (secondary `s` with the
  branch glyph; "Forking…" while it runs, disabled without a session file, tooltip "Fork as a new
  agent with this run's transcript") and Copy transcript (ghost `s`; it loads every page first,
  and says "Couldn't load the full transcript. Nothing was copied." if it can't). A failed fork
  says why under the bar. Remote agents have no Fork.
  - **Not built yet** (SubagentsDone): "kept with the thread" in Geist Mono 11 `textTertiary`
    trailing the bar (`NWRunActions`' trailing slot).

**Changes** (the review: `ReviewPane` in `DiffReviewView.swift`, state in `DiffReview.swift`):

- **Bar** (Review board, `ChangesBar`): 40pt under the strip, 14pt leading and 12pt trailing
  padding, a hairline beneath. The scope and totals fill it in Geist Mono 10.5 `textTertiary`,
  truncated in the middle: "working tree vs HEAD · 4 files · +67 −58" (the counts in `done` and
  `failed`, cross-faded when they change). The directory's name leads when an agent's
  `review_diff` points it outside the agent's own directory, then the reference an agent asked for
  in place of "working tree vs HEAD"; "loading…" while loading. Then a small (`s`)
  `NWSegmentedPicker` `Local | PR`, disabled while loading; the PR side names the pull request
  ("PR #24", Review), which the app shows as "PR · <base ref>" once the base is known (Known
  gaps). Its options (Expand All Files, Collapse All Files, Copy Review as Text) are in the pane's ⋯
  menu. In a layout pane of its own (an older host's review leaf) the review keeps `NWPaneHeader`
  instead: "Review" over the same line, Local | PR, its own "Review options" ⋯, and close ("Close
  review").
- **File strip** (`NWFileStrip`, NWReview, on `bgBase` with a hairline beneath): 24pt chips 4pt
  apart inside 6pt padding, scrolling sideways (lazily). Each chip has its status letter (M
  `lantern`, A `done`, D `failed`, R `running`; Geist Mono 11 bold), the filename in Geist Mono 11,
  and for a modified or renamed file its diff stat (an added or deleted file shows only its
  letter); the full path is its tooltip. The selected chip has the `bgSelected` fill (radius 6),
  which slides to the next chip and scrolls it into view (at once for keyboard moves;
  cross-faded under Reduce Motion); viewed files dim to 50%, and a 6pt `running` dot marks a file
  the agent is editing right now.
- **File headers** (`NWFileHeader`, NWReview; pinned while their file scrolls): at least 32pt on
  `bgSunken` with a hairline beneath, 10pt leading and 6pt trailing padding, 8pt gaps. A 9pt fold
  chevron (`textTertiary`, turning as the file folds), the path in `code` mono (Geist Mono 12)
  with its directory in `textTertiary` and the filename semibold `textPrimary`, truncated at the
  head, "n hunks" in `micro` `textTertiary`, "n comments" in `micro` `running`, then 24pt
  `nwIcon` actions: Open in Xcode (`arrow.up.forward.square`; the default editor when Xcode is
  absent; local reviews only), Revert ("Revert this file"; confirmed, local working-tree reviews
  only), and Viewed (a checkmark, "Mark viewed" / "Mark unviewed", tinted `done` once viewed and
  popping as it is marked). Clicking a header makes its file the current one. A binary file shows
  "Binary file" in `caption` `textTertiary` in place of its lines.
- **Diff lines** (`NWDiffView`, `NWDiffLine`, NWReview): unified, 22pt (`rowCompact`, ×
  density), two 36pt line-number gutters (`micro` regular `textTertiary`, monospaced digits,
  right-aligned with 6pt padding, shrinking to fit five digits), a 16pt sign column (+ `done`, a
  true minus `failed`), and syntax-colored code in `mono` (Geist Mono 11.5). Removals sit on
  `failedTint`, additions on `doneTint`, and a commentable context line hovers `bgHover`. Hunk
  headers (`NWHunkHeader`) are 22pt `bgSunken` rows in `mono` `textTertiary` aligned to the code
  column. Lines are tail-truncated with the full line on hover, never wrapped. Highlighting runs
  off the main actor, once per file, with the theme's syntax colors.
- **Folding** (`NWFoldRow`): a run of more than 8 like lines (`reviewCollapseThreshold`,
  `Sources/ShepherdRemote/ReviewDiff.swift`) keeps a few lines at each end and folds the middle to a
  24pt `bgSunken` strip (× density) between hairlines: "+ 13 more removed lines · 20–32"
  ("unchanged", "added" or "removed") in `micro` regular `textTertiary` (`textSecondary` while
  hovered), 6pt into the code column (94pt). Clicking shows the lines; ⌥-click (or the VoiceOver
  action "Show the whole file") shows the whole file.
- **Comments:** hovering a line shows an 18pt lantern `+` (radius 4, a 9pt bold plus in
  `textOnLantern`) in a slot that is always laid out, and double-clicking the line also starts a
  comment ("Comment" is the line's VoiceOver action). The editor (`NWCommentEditor`) is the
  comment's card with a `running` line: the field ("Comment for the agent on this line") in `ui`,
  one to eight lines, then Cancel (ghost `s`) and Comment (secondary `s`). ⏎ saves, ⇧⏎ adds a line,
  Esc cancels, and saving an empty comment removes it. A saved comment (`NWInlineComment`,
  NWReview) is a `bgRaised` card with a `lineStrong` line, radius 8, padding 8×10, inset 6pt under
  its line and 94pt from the leading edge: a 16pt lantern avatar with the account name's initial
  (Geist 9 bold, `textOnLantern`), "You" in `caption` semibold, "line 33 · just now" in `mono`
  `textSecondary`, and Edit / Delete as `caption` links on hover; the comment in `ui`, selectable.
- **Review composer** (`NWReviewComposer`, NWReview, at the foot with 12pt padding under a
  hairline): a `bgRaised` card, radius 8, a `lineStrong` line (the focus ring while focused). The
  field "Overall comment" in Geist 13, one to five lines, 10pt from the top and 12pt from the sides;
  beneath it a row with 6pt padding: "n inline" in `micro` `textTertiary` (6pt more in), then
  **Commit** (secondary `s`; asks the agent to commit, naming every file under review; not in PR
  mode) and **Request changes** (primary `s`, ⌘⏎; sends the overall and inline comments as the
  agent's next turn, queued if it is mid-turn; enabled once there is a comment or an overall
  comment). The review closes only once the send succeeds. Where the host commits from review (a
  local review, or a remote host with `review.commit.v1`), Commit becomes **Ask agent to commit**
  (ghost) beside **Commit…** (secondary), which opens the commit sheet.
- **Commit… sheet** (`ReviewCommitSheet`, 520pt, derived from the iPadCommit board; parts in
  `Components/Review/CommitForm.swift`): "Commit n files" over "On <branch> in <repository>."
  - Titles: "Commit n files" (or "Commit"), "Committing…" while it runs, "Committed" or "Pull
    request opened" when done, "Commit stopped" when a step fails. While it reads the checkout
    the subtitle and the footer say "Reading the checkout…" (a spinner in the footer); running,
    the subtitle is "Each step must succeed before the next runs. Nothing is ever
    force-pushed.", and after a failure "A step failed, so the rest didn't run."
  - The message card (`NWCommitMessageEditor`, a raised card with a strong line): the summary in
    semibold over the description, both editable, each growing to its lines whenever its text
    changes (typed, or filled in by the host), and a note: "Drafted from the diff · edit
    anything" (a sparkle), "Written from the file list · edit anything", or a spinner with
    "Drafting from the diff…". The plain message shows at once and follows the ticked files
    until someone edits it; the drafted one replaces it only if nothing was typed meanwhile.
    Drafting follows Settings ▸ Worktrees ▸ Generate PR descriptions and its model.
  - A message nobody edited follows the ticks. The plain one is rewritten at once. A drafted one
    is drafted again for the ticked files once they stay put for 600 ms, so ticking several
    files costs one draft; the old draft stays (spinner, and Commit waits with "Redrafting the
    message…") until the new one arrives. An answer for earlier ticks is dropped, and a failed
    draft puts the plain message for the ticked files in its place. An edited message is never
    rewritten: once a file it was written for is unticked, its note reads "May mention files you
    unticked" (an exclamation circle, as quiet as the other notes).
  - "Files" with "n of m" and Select All/None, then a card of `NWCommitFileRow`s (a row-high
    checkbox row: lantern checkbox, the name in mono, its directory in tertiary, the diff stat;
    the whole row toggles). Every file starts ticked; the list scrolls past 232pt.
  - A card of two `NWCommitOptionRow`s: **Push after commit** over the upstream in mono
    ("origin/main", or "origin/feat · sets upstream"), and **Open a pull request instead** over
    what it does ("pushes feat, opens a PR into main", or "creates shepherd/<slug>, opens a PR
    into main" on the default branch). The PR option turns the push on and disables its switch;
    an option with nowhere to go is disabled.
  - An agent still working puts an attention banner ("The agent is working": its files may
    still change, and Shepherd commits them as they were when the sheet opened and stops if one
    changed) above the message and a "Commit while it works" checkbox that Commit waits for. A
    checkout the host refuses (detached HEAD, a merge or rebase in progress, unmerged paths) is a
    failed "Can't commit here" banner over the disabled form ("Can't commit from here", alone,
    when the host can't commit at all); a refused commit comes back as a failed "Nothing was
    committed" banner.
  - While the steps run, an answer that never came is an attention "Outcome not yet known"
    banner under them.
  - Footer: why Commit waits (caption), then Ask Agent to Commit (ghost), Cancel (⎋), and the
    primary: **Commit**, **Commit & push** or **Commit & open PR** (⏎).
  - Running, the body becomes the host's steps as `NWChecklistRow`s (check the checkout, create
    branch, commit n files, push to …, open a pull request into …) with each one's detail, a
    failed "Stopped" banner saying what was kept, then Open Pull Request and Done. Close while it
    runs leaves it running; Commit… shows it again. A finished commit reloads the review.
- **Empty and error states:** "Loading the diff…" in `caption` `textTertiary` beside a 12pt
  spinner; "No changes" (`NWEmptyState` without the crook) with "The working tree matches HEAD.",
  "<ref> has no changes." for an agent's reference, or "This branch matches its PR base."; a
  `failed` `NWBanner` with the error, 12pt in from the pane's edges. Loading, the diff, "No
  changes" and an error cross-fade, as does one side's diff for the other (Local | PR).
- **Keys:** j/k move between hunks, n/p between files, c comments on the current hunk's first
  changed line, v marks the file viewed or unviewed, ⌘⏎ sends, and Esc returns to the thread's
  composer. They are ignored while a comment or the overall comment is being typed, and keyboard
  moves land at once.
- **Repository changes:** per-file Revert is the only repository mutation outside the worktree
  flows (`RevertFileDialog`: "Discard changes", with a Repository row naming the directory the
  diff came from). Tracked files return to HEAD; new files move to the Trash. It acts on the
  directory the confirmed diff came from, even if the review has since moved.

A review an agent opens (`review_diff`) is the host's view state; remote viewers open their own
with ⇧⌘B. An agent may point its review at another repository or worktree (`cwd`); a new target
starts the review over (comments, summary, viewed marks, folds), and asking again reloads it in
place, marking the tab again while it is out of sight. A review that is sent (Request changes, Ask
agent to commit) closes the pane with it; one that fails to send stays, with its comments.

### Side pane: Browser, Artifacts, Files (not built yet)

**Not built yet.** The page boards give the side pane three more tabs beside Changes (PaneStates,
PaneBrowser, PaneArtifacts, PaneArtifactEdit, PaneFiles). None is shown until it is built. When
one is, it joins the strip and the ⋯ menu above and follows this section; where the boards leave a
choice open, it says so. The boards draw these surfaces at radius 10 (9 and 5 for some tiles and
rows) beside a 52pt toolbar. This section gives their other values as drawn and maps radii onto the
radius scale (8 for cards, panes and tiles, 6 for rows and controls, 12 for popovers), as the
departures table records for the page boards. Board strings say "Pi"; the app spells it "pi" (see
departures).

- **Their tabs** (`SidePaneTabs`, PaneStates): Browser (`globe`), Artifacts (with its count of new
  artifacts) and Files, after Changes, taking ⌃2–⌃4. A tab pi opened something in gets the dot and
  a brief popover under it ("Pi opened localhost:5173/checkout" with the URL in mono and its age in
  `textTertiary`; Geist 12, a 12pt glyph).
- **The rest of the ⋯ menu** (`SidePaneOptions`), once there is more than one tab: Split below,
  Open pane in its own window (⇧⌘O), Reset width, a divider, then "Show tabs" with a checkable row
  per tab. Changes can't be hidden while the thread has edits.
- **Split** (`SidePane · split`): drag a tab to the pane's bottom edge to split it (Browser over
  Files). The divider is 12pt on `bgBase` with a 36×4pt `lineStrong` grip (radius 2) between
  hairlines; the lower pane has a 34pt header (a 13pt glyph, the name in Geist Mono 12 semibold,
  the unsaved dot, and a 24pt Close split).
- **Widths** (PaneStates): 760pt default for Files (tree plus editor); double-clicking the divider
  sets half the window; the thread keeps at least 520pt. Each thread remembers its tabs, split and
  width. The pop-out window conflicts with the one-window rule (Window and adaptive layout): decide
  before building it.
- **Keys**, shown in menus and tooltips, never under the composer: ⌃2–4 switch to these tabs, ⌘L
  the address bar, ⇧⌘C select an element, ⌘P go to file, ⌘S save a file or artifact, ⇧⌘O pane in
  its own window. ⌃2–4 are fixed like ⌃1; the rest go through `KeybindingsStore`, and each must be
  added to `appOwnedChords` so a focused terminal doesn't eat it.

**Browser** (PaneBrowser, PaneStates): a WebKit view per thread. It shares cookies with nothing
else, and it reaches the thread's host through Shepherd's tunnel, which forwards the port.

- **Toolbar,** 44pt, 8pt side padding, a hairline beneath: Back, Forward and Reload (28pt
  `nwIcon`; one that can't act is disabled at 40%), 6pt, the address field, 6pt, then Select an
  element, Viewport size and Open in your browser (28pt `nwIcon`). The address field is a 30pt
  capsule on `bgSunken` with a `lineSubtle` line: a 12pt `textTertiary` glyph, the URL in Geist
  Mono 12 (host `textPrimary`, path `textSecondary`), truncating, and a 20pt capsule host chip on
  `bgRaised` (a 10pt server glyph, the host in Geist 11 `textSecondary`, "build-01"). Empty, it
  reads "Search or enter a URL" in `textTertiary`. Select an element, while on, is
  `lanternTint` with a `lanternText` glyph; a menu's button is `bgSelected` while its menu is
  open.
- **pi is using it:** pi drives the same page you see. A 2pt `running` ring insets the page, a
  pointer glyph (18pt, `running`) shows where pi points, and a floating card 12pt from the
  pane's sides under the toolbar (`bgRaised`, radius 12, a `running` line, the popover shadow;
  padding 8, 12 on the leading side) says "Pi is clicking through checkout" (`ui`, a 12pt
  `running` glyph) with Take over (secondary `s`, with a glyph). Click anywhere or Take over to
  get the page back; pi carries on in the thread.
- **Nothing open:** centered, 14pt apart: a 44pt `bgSelected` circle with a 20pt `textSecondary`
  glyph, "No page open" (Geist 14 semibold), and "Pi opens pages here when it starts a dev
  server. Ports on remote hosts are forwarded for you." (`ui` `textSecondary`, at most 330pt,
  centered). Then cards (`bgRaised`, `lineSubtle`, radius 8, padding 10×12) for the dev servers
  found in the repo ("pnpm dev" in Geist Mono 12 over "from package.json · acme-web" in Geist 11
  `textTertiary`, with "Start on build-01", secondary `s`, which runs it on the thread's host),
  and an "Open a URL" row with the ⌘L keycaps.
- **Viewport** (a 220pt menu): Fit the pane (checked by default), iPhone 16 · 393, iPad mini ·
  744, Laptop · 1280 (widths trailing in Geist Mono 11 `textTertiary`), a divider, Dark
  appearance, Throttle to 3G. A chosen width centers the page on `bgSunken` in a frame with 14pt
  top corners and a `lineStrong` line; the selection and console keep working.
- **Selecting an element** (⇧⌘C): the hovered element takes a 2pt `running` outline (radius 10,
  4pt outside it, a `runningTint` fill) with a 20pt `running` tag above it: the selector and its
  size ("button.pay 240 × 44", Geist Mono 10.5, the size at 75%; the tag's text color needs a
  role for text on `running`, which the theme doesn't have yet). A popover beside it (188pt,
  padding 8, radius 12, `bgRaised`, the popover shadow) shows the source location
  ("Checkout.tsx:88", Geist Mono 10.5 `textTertiary`), Add to message (primary `s`) and Copy
  selector (ghost `s`).
- **In the composer,** an added element is a chip above the field: 26pt, padding 0×8, radius 6,
  a `lineStrong` line, a 12pt glyph, "button.pay" in Geist Mono 12, "Checkout.tsx:88" in Geist
  Mono 10.5 `textTertiary`, and a 9pt remove ×. It goes to pi with the message. Mentioning a file
  from the Files tree puts the same kind of chip there.
- **Console drawer:** a 32pt bar on `bgBase` under a `lineStrong` line: "Console" (Geist 12
  semibold), "Network" with its count ("24", Geist Mono 10.5 `textTertiary`), "1 warning" in
  `lanternText` with a 12pt glyph, and Hide console (24pt). Its rows (at least 22pt, 14pt side
  padding, Geist Mono 11) show the time in `textTertiary` and the message in `textSecondary`,
  truncating; a warning row is `lanternTint` with its text in `lanternText`.
- **In the thread,** pi's browser work reads as activity lines: "Started the dev server · pnpm
  dev · :5173 on build-01", "Opened the checkout in Browser · localhost:5173/checkout".

**Artifacts** (PaneArtifacts, PaneArtifactEdit, PaneStates): reports, plans, diagrams and images
pi makes along the way. Each is a file on the thread's host, versioned on every save by you or
pi. Open one from the thread or the list; edit it in place.

- **In the thread:** an activity line "Made an artifact · Load test report · v2", and a card
  (`bgRaised`, a `lineStrong` line, radius 8, padding 10×12, 12pt gaps): a 34pt `bgSelected` tile
  (radius 8) with a 17pt kind glyph, the name in `body` semibold over "HTML · v2 · 6m ago" in
  Geist 12 `textTertiary` (the version in mono), and Open (secondary `s`, with a glyph).
- **The list** (`ArtifactList`): "This thread · 4", then "From the mission · <mission>" as
  section labels (Geist Mono 10.5 caps, 0.5pt tracking, `textTertiary`, padding 10/8/4/8), newest
  first. Rows are at least 48pt, padding 6×8, radius 8, 10pt gaps: a 30pt `bgSelected` tile
  (radius 8) with a 15pt glyph, the name in Geist 13 medium (semibold when open, on
  `bgSelected`) over "Markdown · v4 · just now" in `caption` `textTertiary`, plus "edited by you"
  in `micro` `lanternText` after a save of yours, and a 24pt ⋯ trailing.
- **An open artifact:** a 44pt bar under the tabs (8pt padding and gaps): All artifacts (28pt
  `nwIcon`, back to the list), a 22pt kind tile (radius 6), the name in Geist 13 semibold
  (truncating), a 22pt version chip (radius 6, `lineSubtle`, a clock glyph, "v2 · 6m ago" in
  Geist Mono 11 `textSecondary`, a chevron) that opens its versions, then a small Preview | Source
  `NWSegmentedPicker`, Edit and Open in a window (28pt `nwIcon`). Diagrams and Markdown render in
  Night Watch colors, so they follow light and dark; HTML artifacts keep their own styles, on
  their own background with 18pt padding.
- **Versions** (`ArtifactVersions`, a 280pt popover): the file's name in `caption` semibold
  `textSecondary`, then one 38pt row per version, newest first: a check on the one shown, "v4"
  over "You · 2 lines" (or "Pi · open question added") in Geist 11 `textTertiary`, and its age
  trailing in Geist Mono 11. Then Compare v3 with v4 and Restore v3. Restoring makes a new version.
- **Editing in place** (PaneArtifactEdit; the board widens the pane to 640pt): the bar becomes an
  editing bar on `lanternTint` (44pt, padding 0/10/0/12): a 14pt `lanternText` pencil, "Editing
  retry-plan.md" in Geist 13 semibold (the name in mono), "v3 → v4" in Geist Mono 11
  `lanternText`, then Source | Split | Preview, Cancel (ghost `s`) and "Save v4 ⌘S" (primary `s`,
  its chord in Geist Mono 10.5 at 60%). The source is numbered: lines at least 22pt in Geist Mono
  13, a 3pt change bar, 40pt line numbers (Geist Mono 10.5 `textTertiary`, 12pt right padding);
  Markdown marks in `textTertiary`, headings semibold `textPrimary`, list markers `lanternText`,
  code in the theme's string color, prose `textSecondary`. Your edited lines are `lanternTint`
  with a `lantern` bar, and the caret is a 2pt `lantern` bar. A 30pt footer (a hairline above,
  `caption` `textTertiary`) keys it: "Your edits" with its swatch, and trailing "Ln 15, Col 43 ·
  Markdown" in mono.
- **Your version goes back to pi:** while you edit, the thread shows "You're editing
  retry-plan.md" (`ui` `textSecondary`, a 13pt glyph) with "v4 draft · 2 lines" in Geist Mono 11
  `textTertiary`, and the composer carries a chip for the draft ("retry-plan.md v4") that goes
  with the next message.

**Files** (PaneFiles, PaneStates): the thread's worktree, on whichever host it runs. Edits save
straight to that host. Saving and Revert here would mutate the repository, which only the paths in
AGENTS.md › Only these paths mutate repositories may do: add Files to that list by a decision
before building it (as iOS: iPad › Side pane says).

- **The tree,** 210pt on `bgBase` with a hairline on its trailing side. Its header (padding
  10/10/8/12, a hairline beneath): the repository in Geist Mono 12.5 semibold with Go to file (24pt
  `nwIcon`), over the branch and host in Geist 11 `textTertiary` with 11pt glyphs ("fix/pay-jump"
  in mono · "build-01"). Rows are 24pt, radius 6, 8pt leading padding plus 14pt per level, 6pt
  gaps: a 9pt disclosure chevron (or its space), a folder (13pt `textSecondary`) or file (12pt
  `textTertiary`) glyph, the name in `ui` (semibold on `bgSelected` when open), and trailing an M
  in Geist Mono 10.5 semibold `lanternText` for a changed file and an 11pt `running` pencil for a
  file pi is editing now.
- **Its context menu:** Mention in message (a file chip in the composer), Show in Changes, Show
  history (subtitle "3 commits · 1 by Pi"), a divider, Copy path, Open in your editor.
- **Go to file** (⌘P, a 300pt popover): a 34pt field on `bgSunken` (radius 6, a 13pt glyph, the
  query in Geist Mono 13, a `lantern` caret, the ⌘P keycaps), then 38pt results: a file glyph,
  the name in `ui` over its directory in Geist 11 `textTertiary`, and its status letter trailing.
  It fuzzy-matches across the worktree on the thread's host.
- **Editor tabs** on `bgBase` with a hairline beneath: 36pt tabs, padding 0×12, a hairline on
  their trailing side, a 12pt glyph and the name in Geist Mono 12. The current tab is on
  `bgWindow` in `textPrimary` with a 2pt `lantern` line along its top and a 7pt `lantern` dot
  while unsaved; the others are `textSecondary` with a 9pt close ×, or the `running` pencil while
  pi edits that file.
- **The path bar,** 36pt, a hairline beneath: "src › components › Checkout.tsx" in Geist Mono
  11.5 `textTertiary`, then Revert (ghost `s`) and "Save ⌘S" (secondary `s`).
- **The editor:** lines at least 21pt in Geist Mono 12, a 44pt number gutter (Geist Mono 10.5
  `textTertiary`, 8pt right padding), a 3pt change bar and 10pt gap, syntax colors from the theme.
  The bar is `lantern` for your unsaved lines (which sit on `lanternTint`) and `running` for lines
  pi changed. A 28pt status bar (a hairline above, Geist 11 `textTertiary`) keys them ("yours,
  unsaved", "changed by Pi") and ends with "Ln 94, Col 48 · TSX · Spaces: 2" in mono.
- **pi changed your file:** an attention banner under the path bar (`lanternTint`, padding 10×12):
  "Pi changed Checkout.tsx while you had unsaved edits." with Compare and Keep mine (secondary
  `s`) and Use Pi's (ghost `s`). Your unsaved edits are never overwritten; Keep mine saves over
  pi's change and tells pi in the thread.

### Terminal panes

A terminal pane is a real PTY: libghostty on the Mac (`AppTerminalView`, through
`TerminalHost.swift`), SwiftTerm on iOS (`TerminalSurface`). Each one is a real shell and nothing in
it is pi's (TerminalStates: "Each tab is a real shell; nothing here is Pi's"). The chrome never
parses or restyles terminal output, and the thread pane itself never has a terminal.

- **Surface:** the theme's terminal colors (`TerminalColors`), on `bgWindow` (the boards draw
  `bgBase`; see the departures). The grid sits 14pt from the sides and 10pt from the top and bottom
  (TerminalSplit; `NWTerminalMetrics.contentPadding`), 16pt and 10pt on iPad (iPadTerminal).
- **Type:** the boards set the terminal in Geist Mono with a 1.6 line height: 12pt on the Mac
  (TerminalSplit; the narrower split panes of TerminalPane draw 11.5pt) and 13pt on iPad (the `code`
  size there). On the Mac the family and size are Settings ▸ Terminal's and never follow the
  chrome's text scale. On iOS the terminal follows Dynamic Type up to 20pt
  (`MobileLayout.terminalMaximumFontSize`).
- **Cursor and selection:** a 7×14pt block cursor in `textPrimary` (TerminalSplit), and selected
  lines on `running` at 13% (TerminalPane).
- **Output colors are the shell's**, through the 16-color ANSI palette. On the boards a prompt reads
  user and host in green (`done`), the path in blue (`running`), the branch in yellow
  (`lanternText`), `$` and dim lines in `textTertiary`, the typed command in `textPrimary`, plain
  output in `textSecondary`, warnings in `lanternText` and failures in red (`failed`). Never color
  output in the chrome.
- **States** are quiet placeholders at the top leading corner in mono `micro` regular (10.5pt),
  `textTertiary`: 10pt in on the Mac (`PanePlaceholder`, `AppLayout.panePlaceholderPadding`), at the
  terminal's own padding on iOS (`NWTerminalNotice`). They cross-fade (`.content`) and the surface
  under them never moves: "starting session…" over the surface until it is live, "session exited
  (n)" (or "session exited"), "session unavailable · <reason>", "remote host removed", and "review
  unavailable". A remote agent's pane on the Mac reads "attaching…", "remote session unavailable ·
  <reason>" and "remote session exited (n)". iOS adds "attaching…", "host offline · reattaches when
  it is back", "open in another window" (a screen shows in one iPad window at a time), "review open
  on <host>", and " · retrying" after a refused attach.
- **Size never animates:** a terminal takes its new size once (`.nwInstant()`; see Motion), and a
  hidden one keeps its grid (Terminal panel › Nothing remounts).

### Terminal panel

A real terminal under the thread, one keystroke away (TerminalSplit, TerminalPane and TerminalStates
boards; `TerminalPanelGeometry`, `TerminalPanels`, `TerminalPanelViews.swift`; the iPad's in iOS ›
Terminal). An agent's terminal panes live in a panel under its thread and composer, across the
layout's whole width, and a docked side pane keeps its full height beside both (TerminalStates ›
Panel: "The side pane keeps its full height"; TerminalPane). A new terminal opens in the thread's
folder (its worktree) on the thread's host, so it sees what pi sees. The panel is a view of the
agent's layout, which stays the one `PaneNode` tree the server persists and agents drive: each
largest subtree without the thread is a tab, oldest first (`TerminalPanel.tabs`), drawn with its own
splits.

- **Strip** (`NWTerminalTabBar`; TerminalSplit): 38pt (`NWTerminalMetrics.tabBarHeight`) on
  `bgWindow`, with a 1px `lineStrong` hairline on top and a `lineSubtle` one under it, 8pt side
  padding and 2pt gaps. From the leading edge: the tabs, then + ("New terminal"), a spacer, then
  Split right (`rectangle.split.2x1`, only while a tab is selected), Maximize or Restore
  (`arrow.up.left.and.arrow.down.right`, `arrow.down.right.and.arrow.up.left`), and Hide terminal
  (`xmark`). They are 24pt circular `.nwIcon` buttons with 14pt glyphs in `textSecondary`, with
  tooltips (`.nwHelp`); Split right, Maximize or Restore and Hide terminal carry their chords. The
  tabs and + scroll sideways when they outgrow the strip; the trailing controls never scroll.
- **A tab** (`NWTerminalTabView`): 26pt tall, radius 6 (`NW.Radius.s`), 8pt side padding, 7pt
  between its parts: the terminal glyph (`terminal`, 12pt), the title in Geist Mono 11.5 (semibold
  and `textPrimary` when selected, medium and `textSecondary` otherwise), then the selected tab's
  host and close. The selected tab sits on `bgSelected` with a `textPrimary` glyph; the others are
  clear, with a `textTertiary` glyph and `bgHover` under the pointer. Only the selected tab shows
  its close (`xmark`, 9pt, `textTertiary`; tooltip "Close terminal"). A remote tab names its host
  while selected, after its title: `desktopcomputer` at 10pt and the host's name at 10.5pt, both
  `textTertiary`, 3pt apart ("zsh  build-01"). A tab split into several panes also shows how many,
  in `micro` `textTertiary` (the app's; the boards show none).
- **Tab states** (`NWTerminalTab.Activity`; TerminalTab · states: "Remote tabs name their host.
  Running and exited tabs say so without opening them"):
  - **Idle:** the program at its prompt names the tab ("zsh"), else the folder the pane started in,
    else "Terminal".
  - **Running:** the running command names the tab ("make dev", at most 40 characters), and an 11pt
    `running` spinner (`NWSpinnerStyle`) takes the glyph's place.
  - **New output while you were away:** a 6pt `running` dot after the title, for output printed
    while the tab or the panel was off screen. It can sit beside the spinner (TerminalSplit's "make
    dev").
  - **Exited:** the tab stays and so does its output ("exited with an error; the output stays"); a
    process that failed turns the glyph into a 10pt `failed` ✕ (stroke 2). On the Mac a shell that
    exits closes its pane, so its tab goes at once (see the departures); on iOS a tab shows it
    exited (`.exited(failed:)`) until the host closes it.

  A resize is not news: a shell or TUI redraws on SIGWINCH (a window resize, maximize or restore, a
  hidden panel's panes following the geometry, a remote viewer leaving), so the host counts no
  output for a second after it gives a PTY a size (`TerminalNews`, carried as
  `RemoteTerminalActivity.newsSequence`; an older host's every read counts). Showing a tab marks it
  seen whenever the tab, its panes, or their news change (`TerminalSeenMark`), so picking a tab
  whose output matches the last one's still clears its dot. What each terminal runs comes from
  `SessionServer.terminalActivity` (a remote agent's host answers `RemoteAgentQuery.terminals`),
  polled every 2 s while the layout is on screen; an older host leaves plain tabs named for the
  folder.
- **Actions:** + opens a new tab (a pane split off the thread). Split right (⌘D in a terminal)
  splits the tab's focused pane to the right, and ⇧⌘D splits it down; ⌘D or ⇧⌘D on the thread opens
  a new tab. Closing a tab closes all its panes (as ⌘W closes one), never the thread's, and the Mac
  doesn't ask first. A new pane starts in its neighbor's folder; a remote agent's go through its
  host's pane requests, and a failed one beeps. A terminal you open (+, Split right, ⌘D or ⇧⌘D)
  takes the keyboard. A terminal that appears any other way (an agent's `pane_open`, another device)
  opens the panel on its tab and leaves the keyboard where it was.
- **Show and hide:** ⌘J, the Pane menu (Show or Hide Terminal), or the palette's terminal
  commands, while a thread with a layout is on screen. The panel slides up from the bottom and is
  only a toggle: there is no terminal button in the thread's header or anywhere in the side pane's
  chrome, and it has nothing to do with the side pane (the user's decision, 2026-09-25: "the
  terminal is only a toggle that pops it up from the bottom, no buttons or anything, it has nothing
  to do with the sidebar"; the TerminalSplit, TerminalPane, TerminalStates and iPadTerminal boards'
  header button is a departure, and patched copies without it go to the canvas). On iPad and
  iPhone, with no ⌘J without a keyboard, the thread's options menu shows it (iOS › Terminal).
  Showing gives the keyboard to the selected tab; hiding gives it back to the thread. A tab that
  printed while the panel was hidden keeps its `running` dot for when it shows (Tab states). A
  layout seen for the first time with terminals shows its panel. The panel closes with its last
  terminal, however it goes (its tab closed, the agent's `pane_close`, its shell exiting), and the
  thread takes the layout again.
- **Empty** (the app's; no board): ⌘J with no terminals shows the strip over "No terminals in this
  thread yet." (`ui`, `textSecondary`) and New Terminal (secondary) beside the new-terminal chord as
  a keycap, centered on `bgWindow`.
- **Height:** 330pt by default (`NWTerminalMetrics.panelHeight`), persisted app-wide
  (`shepherd.terminalPanelHeight`). The panel's top edge is the divider (Divider: "Drag the top
  edge. It snaps at a third, half and two-thirds; double-click resets to 330pt"): a 9pt hit area
  centered on the edge with the row-resize pointer. It snaps within 12pt of a third, half and
  two-thirds of the layout, keeps the panel at least 120pt and the thread at least 160pt, and never
  animates while dragged. VoiceOver reads it as "Terminal height" in points and adjusts it in 40pt
  steps. **Not built yet:** while it is dragged, the edge draws as a 3pt `lantern` line across the
  top of the strip (Divider).
- **Maximized** (⇧⌘↩, or the strip's Maximize): the panel takes the layout and the thread folds away
  at its size, still mounted (its draft, scroll and stream stay). Restore (the same button, or ⇧⌘↩)
  brings it and its composer back, and so does hiding the panel. The divider doesn't drag while
  maximized. **Not built yet:** the folded thread keeps one line above the strip (TerminalPanel ·
  maximized: "The thread folds to one line. Its composer comes back when you restore"): 40pt on
  `bgWindow` with a `lineSubtle` hairline under it, 14pt leading and 10pt trailing padding and 10pt
  gaps, holding the thread's title in Geist 12.5 semibold, its `NWStatusPill` ("Idle"), and at the
  trailing end a 24pt "Show the thread" icon button (`chevron.down`, `textSecondary`) that restores.
- **Nothing remounts:** every pane is placed whether it shows or not (a hidden tab or panel keeps
  its size, so its grid never changes), hidden ones are `opacity(0)` and stop rendering. ⌥⌘←/→
  move only among the panes on screen. A remote agent's panel mounts only its shown panes, so a
  hidden remote terminal is detached and never counts toward the host's smallest-viewer size.
- **A layout with no thread** (a host's utility terminal) keeps the plain split tree.
- **Split panes** (TerminalPane): a tab's panes sit side by side (Split right) or stacked, with 1pt
  dividers the board draws in `lineStrong`. **Not built yet:** in a tab of more than one pane, each
  pane has a 26pt header on the terminal's surface with a `lineSubtle` hairline under it, 10pt side
  padding and 6pt gaps: the 11pt terminal glyph, the pane's running command or program in Geist Mono
  11, and at the trailing end its host (`desktopcomputer` at 10pt and the host's name, 3pt apart).
  The focused pane's glyph, title and host name are `textPrimary` (its host glyph stays
  `textTertiary`); the others' header is `textTertiary`. A tab of one pane has no header
  (TerminalSplit): the tab names it.
- **Send output to pi** (TerminalPane; TerminalStates: "anything you select can go to Pi"). **Not
  built yet.** Selecting text in a terminal shows a floating bar beside the selection: `bgRaised`
  with a 1px `lineStrong` border, radius 9 on the board, 4pt padding and 4pt gaps, and the popover's
  shadow. It holds **Add to message** (primary, 24pt: a `lantern` fill, a 13pt `plus` and the label
  in 12pt semibold `textOnLantern`), which adds the selection to the thread's composer, and **Copy**
  (ghost, 24pt: a 13pt copy glyph and the label in 12pt medium `textSecondary`). Both buttons are
  radius 6 with 8pt side padding and 6pt between glyph and label. The selection itself reads as
  selected lines on `running` at 13%.
- **New terminal menu** (NewTerminalMenu: "+ or right-click"). **Not built yet;** today + opens a
  tab at once (see the departures). On the board, + and a right-click on a tab open a 290pt menu:
  `bgRaised`, a 1px `lineStrong` border, radius 10 on the board, 6pt padding and the popover's
  shadow. Rows are radius 6 with 8pt side padding and 9pt gaps: a 13pt `textSecondary` glyph, the
  title in `ui` (12.5pt), and the chord as keycaps (`NWKeycap`) at the trailing end; the highlighted
  row sits on `bgSelected`. Two-line rows are at least 36pt, with a detail in 11pt `textTertiary`
  under the title; one-line rows are 30pt. In order:
  - "New terminal in the worktree", detail "<space> on <host>" (`terminal`), with the new-terminal
    chord: "New tabs start in the thread's worktree on its host, so the terminal sees what Pi sees."
  - "New terminal on This Mac", detail the folder it opens in (`desktopcomputer`), for a remote
    thread.
  - "Split right" (`rectangle.split.2x1`), with its chord.
  - "Rename tab" (`pencil`).
  - "Kill process" (`xmark`).
- **Run in terminal** (TerminalStates). **Not built yet.** "Any command line from Pi can be opened
  in a new tab, typed out but not run." The board puts a Run in terminal button (secondary, small:
  24pt, a 13pt `terminal` glyph and the label in 12pt medium `textPrimary`) at the trailing end of a
  Run (bash) activity line. It opens a new tab in the thread's worktree on its host with the command
  typed after the prompt and the cursor after it, and runs nothing.
- **Keys** (Keyboard: "Shown in menus and tooltips"). The board's are Show or hide the terminal ⌃\`,
  New terminal ⌃⇧\`, Split right ⌘D, Maximize or restore ⇧⌘↩, Close the tab ⌘W, Clear ⌘K, and Next
  or previous tab ⇧⌘[ and ⇧⌘]. Shepherd's (see the departures and Keyboard): ⌘J shows or hides the
  panel, + or ⌘D (⇧⌘D) on the thread opens a tab, ⌘D splits right and ⇧⌘D splits down in a terminal,
  ⇧⌘↩ maximizes or restores, and ⌘W closes the focused pane; there is no clear or tab-switch chord.
  Every chord resolves through `KeybindingsStore`, shows in the Pane menu ("Show or Hide Terminal",
  "Maximize or Restore Terminal", and New Terminal without one) and in the strip's tooltips, and is
  unbound in Ghostty (`appOwnedChords`) so a focused terminal never eats it. ⌥⌘←/→ move among the
  panes on screen.

### Command palette

⌘K (the rebindable `commandPalette`) opens `CommandPaletteView` (`CommandPaletteView.swift`, items
in `ShepherdViewModel+Palette.swift`, matching in `CommandPalette.swift`) through
`.nwCommandPalette(isPresented:)` (NWComposer › Command palette; CommandPalette). It is a jump
surface: every destination and command in it is also in the sidebar or the menus.

- **Placement:** a 620pt `NWPaletteCard` (`.nwPopover()`, radius 12), or the window's width less
  16pt margins, 18% down the window over the 30% `scrim`, and never taller than the window leaves
  room for (at most 14 rows, then the list scrolls; `NWPaletteMetrics.placement`). The card grows
  from its top edge (`overlay`) and the scrim fades (`content`). Clicking the scrim or Esc closes
  it; VoiceOver stays inside it.
- **Search row (44pt):** a 15pt `magnifyingglass` in `textSecondary`, the field in Geist 15
  `textPrimary` with a `lantern` caret ("Search commands, agents, subagents…"), and, trailing, the
  scope control All · Commands · Agents (`NWSegmentedPicker`, small: 20pt; tooltip "Switch scope"
  with ⇥). A hairline divides it from the results, which sit 6pt inside the card.
- **Scopes:** All lists Commands, This thread, and Subagents with no query, and every section once
  there is one; Commands lists Commands and This thread; Agents lists Subagents, Agents, Spaces, and
  Found in conversations, with or without a query.
- **Sections**, in this order, under `NWPaletteSectionHeader` (24pt, mono 10 medium caps, tracked,
  `textTertiary`):
  - **Commands:** New agent ("in <space>/", ⌘N), New agent with options… (⇧⌘T), New space… (⇧⌘N),
    New space on <host>… ("remote", one per connected host), Hide or Show sidebar (⇧⌘S), Settings…
    (⌘,), and Check remote worktree operation (its host) while one is pending. **Not built yet:**
    New mission… (NWComposer; it waits for Missions).
  - **This thread** (the agent on screen): Rename ("<title>", ⌘R), Choose model… ("<model>", ⇧⌘M),
    Review diff ("working tree"), Review PR changes, and the Pane menu's terminal commands while a
    thread with a layout is on screen: Show or Hide terminal (⌘J), New terminal (⌘D, shown while the
    thread has the keyboard), and Maximize or Restore terminal (⇧⌘↩), named for what they will do.
    **Not built yet:** Review diff's file count ("working tree · 4 files"; NWComposer,
    CommandPalette) and its ⇧⌘B keycaps (NWComposer), and Review PR changes' number ("PR #24";
    CommandPalette).
  - **Subagents:** each live or recent run: its label, "<parent> · running 37m" ("needs you",
    "done", "failed"; a remote run's parent adds " · <host>"), and `arrow.turn.down.right` in its
    run's state color.
  - **Agents** (with a query, or in the Agents scope): each agent in sidebar order with "<space> ·
    <status>" (running, needs you, idle, done, failed), and each remote agent with its host. **Not
    built yet:** a working agent's elapsed time ("running · 8m"; NWComposer).
  - **Spaces:** the name and its `~/path`.
  - **Found in conversations:** conversation search needs at least 3 characters, runs off the main
    actor 250ms after the last keystroke, and reads the last 512 KB of each agent's pi session. It
    matches only what was said, the user's and the assistant's text, never pi's system prompt, tool
    definitions, thinking, tool calls or results. Its rows (`text.magnifyingglass`, the agent, its
    space) carry a caption line under the title with the match in bold `textPrimary` and the rest
    `textTertiary`; an agent already listed by name is not repeated. A host answers a remote
    client's conversation search the same way.
- **Matching:** a title that starts with the query ranks first, then one with a word that does, then
  one that contains it, then one that holds its letters in order; a match in the context ranks below
  any match in a title. Rows sort by rank within a section; sections keep their order.
- **Rows** (`NWPaletteRow`, the sidebar's row height, radius 6, 8pt side padding): a 13pt stroke
  icon in a 14pt column in `textSecondary`, 10pt, the label in the sidebar row's title font (12.5;
  12 at Compact) in `textPrimary`, dim context in Geist 12 `textTertiary`, and the real shortcut as
  `NWKeycap`s from `KeybindingsStore`. The highlight is `runningTint` with a `running` icon.
  Subagent rows wear their run's state color.
- **Keys:** ↑↓ (and the pointer) move the highlight, ↩ runs it, ⇥ cycles the scope, Esc closes. A
  new query or scope moves the highlight to the top. With nothing to list: "Nothing here yet", or
  "No matches" for a query, in caption tertiary.
- **Motion:** rows arrive, leave, and reorder (`list`), and the card follows their height; the
  highlight moving changes no row, so it lands at once.
- **What it never shows:** footer hints, ⌘1–9 numbering, or any status the sidebar or the thread
  doesn't show.

### Settings

Settings replaces the window content in place (`SettingsView.swift`; the boards SettingsAppearance
through SettingsExperiments). ⌘, toggles it, and "Back to Shepherd" or Esc returns; the swap
cross-fades on the `sheet` motion, and a page picked in the nav cross-fades on `content`. Every row
is wired: a row exists only if changing it changes the app, and a change applies at once, with no
Save or Apply (the one exception will be Instructions, not built yet, which edits files and saves
with ⌘S).

- **Navigation** (the same on every Settings board): a 232pt column on `bgBase` with a `lineSubtle`
  hairline (`NWHairline`) on its trailing edge. Top to bottom:
  - the 44pt strip for the window controls: it drags the window and holds nothing else
  - **Back to Shepherd**: `chevron.left` and the words in Geist 13, `textSecondary`, in a 30pt row
    (Esc does the same)
  - the search field (`NWSearchField`, "Search settings", its ⌘F keycap trailing while it is
    empty), `NW.Space.m` above and `NW.Space.l` below; it takes focus when Settings opens, so typing
    filters at once
  - the pages, one `NWSettingsNavRow` each, `NW.Space.xxs` apart, in this order: Appearance
    (`circle.lefthalf.filled`) · Terminal (`terminal`) · Agents (`person.2`) · Worktrees
    (`arrow.branch`) · Pi (`pi`) · Instructions (`doc.text`) · Remote
    (`dot.radiowaves.left.and.right`) · Keyboard (`keyboard`) · Advanced (`gearshape`) ·
    Experiments (`flask`). A row is 32pt × density (`NW.Height.scaled(32)`), radius `s`, with
    `NW.Space.m` side padding: a 15pt medium icon in `textSecondary` (`textPrimary` when selected),
    then, `NW.Space.m` after it, the name in Geist 13 `textPrimary`. The selected page sits on
    `bgSelected` with its name at medium (500) weight; hover is `bgHover`. **Not built yet:**
    Instructions and Experiments; the app's nav has the other eight, and the Remote icon is
    `desktopcomputer`.
  - "Shepherd x.y.z · pi x.y.z" pinned at the bottom in mono `micro`, `textTertiary`, aligned with
    the rows' icons: the app's own name, so "Shepherd Nightly …" there.
- **Search:** typing narrows the nav to pages with a match (a row's title, or a keyword such as
  "dark" for Mode or "tailscale" for Hosts) and lists the matching rows as buttons under their page
  (`caption`, `textSecondary`, indented past the icon); clicking one opens its page. When the page
  on screen has no match, the first page that does opens at once (no cross-fade per keystroke). With
  nothing matching, the nav says "No matching settings" in `caption`/`textTertiary`.
- **Content** (every page but Instructions and Experiments): the page on `bgWindow`, a 720pt column
  centered in it, 44pt from the top, 48pt from the sides and the bottom; the page scrolls, and the
  strip at its top still drags the window. Top to bottom:
  - the header: the page's name in Geist 22/600, tracked −1% (`Font.nwSans(22, .semibold)`,
    `textPrimary`, a header for VoiceOver), and `NW.Space.xs` under it one line in
    `body`/`textSecondary` that says what the page is for
  - groups, 28pt apart (from the header too). A group is a section label (`NWSectionHeader`,
    `NW.Space.xs` in from the card's edge), `NW.Space.m` above an `NWGroupCard`, and an optional
    footnote `NW.Space.m` under the card, `NW.Space.xs` in. The card is radius `NW.Radius.m` with a
    1px `lineSubtle` line, filled `bgWindow` like the page it sits on: flat, drawn by its line
    alone. `NWHairline`s separate its rows.
  - a row (`NWCardRow`, through `SettingsRow`): at least 52pt × density, `NW.Space.l` top and bottom
    and `NW.Space.xl` at the sides, the text and the control `NW.Space.xxl` apart. The title in
    Geist 13.5/500 (`Font.nw(.body, weight: .medium)`, `textPrimary`), `NW.Space.xxs` over its
    description in Geist 12.5/1.45 (`Font.nw(.ui, weight: .regular)`, `textSecondary`). A row may
    have no description (Sidebar width, Port, Thinking). The control trails, centered on the row.
  - inside a description, a flag, file or tool name is inline code: mono 11.5 on `bgSunken`, radius
    `xs`, `NW.Space.xs` side padding and no line, lighter than the standalone `NWInlineCode`
    ("passes no `--model` at all", "with `review_diff`", "Runs `pi update` once a day"). Where a
    description explains the options, their names are set at medium (500) weight, a step brighter
    than the text around them (`textPrimary`; the board's #c1c5cb is off the palette): "**Remote
    default** starts clean…".
  - rows without a title (a form's Add host, pi's version and update buttons, a remote host) are
    `SettingsActionRow`s: the same padding and minimum height, their own content leading, actions
    trailing `NW.Space.s` apart.
  - The building blocks are in `SettingsComponents.swift`: `SettingsPage`, `SettingsGroup`,
    `SettingsRow`, `SettingsActionRow`, `SettingsNote`, `SettingsSwitch`, `SettingsTextField`,
    `PathRow`. A page composes these and the shared components; a part only one page has (the font
    preview, the shortcut recorder, a remote host's row) is built from the same tokens.
- **Controls** are the Controls board's components at their own sizes, nothing hand-drawn per page
  (the Settings boards draw larger ones; see Where Shepherd departs from the boards):
  - `NWSegmentedPicker` (m, 24pt) for 2–4 options: a `bgSunken` track with a `lineSubtle` line, the
    chosen segment on `bgSelected` with a `lineStrong` ring in semibold `textPrimary`, the others in
    `textSecondary`
  - `NWPopupMenu` (at least 200pt, 28pt, radius `s`, `bgRaised`) for longer lists: the value in mono
    when it is an id (a model, a shell path), in Geist when it is a word ("Use pi's default · …",
    "Inherit parent", "System font"); a fallback, where there is one, comes first, then a divider,
    then the choices
  - the lantern switch (`SettingsSwitch`, `.nwSwitch`, 30×18) for booleans; the row's title is its
    accessibility label
  - `NWStepper` for a small count, and `NWValueSlider` for a range: 200pt, a 3pt `lineStrong` track
    filled with lantern to a 14pt knob, its value trailing in mono (at least 44pt wide,
    right-aligned) with its unit ("105%", "239 pt"); double-clicking the value returns it to its
    neutral value, and only that reset animates
  - `SettingsTextField`: 220pt `.nw` fields (a port 88pt) labelled for VoiceOver, with an example as
    the prompt; mono for addresses, ports, and tokens; a token is a secure field
  - `NWKeycap`s for shortcuts, one cap per key (⇧ ⌘ N)
  - small buttons (`size: .s`): `.secondary` for actions (Reveal, Check now, Edit), `.danger` for
    one that removes or resets (Remove, Reset…), `.ghost` for Cancel, `.nwLink` for a text action
    inside a row (a shortcut's Reset)
- **Footnotes and problems:** a footnote is Geist 12/1.5 (`Font.nwSans(12)`) in `textTertiary`: a
  sentence or two about the whole group, never a mono paragraph. An inline problem (the listener's
  bind error) sits in its row, `NW.Space.xs` under the description: an `xmark` glyph (12pt,
  `failed`), then, `NW.Space.s` after it, one sentence in the description's size in `failed` that
  says what happened in plain words ("Couldn't start: port 7433 is already in use."). It discloses,
  and the card grows with it (`disclosure`). Never show an errno or a raw error as the message; the
  technical reason may be the line's tooltip.
- **Status inside a row** is a state dot plus its word (`NWStatusDot`, the word in the state's text
  color): a remote host's connection, pi's update status. A failed remote host adds what happened
  and what to do as its problem ("studio refused the token. Edit the host to paste its current
  token."), with the client's technical reason only as that line's tooltip.
- **Never in `body`:** the installed font families are enumerated once per launch
  (`TerminalFontCatalog`), and pi's config and model catalog load in a task.

The pages, in nav order. Each names its board; the strings in quotes are the boards' copy.

#### Appearance (SettingsAppearance)

"How Shepherd looks. The terminal has its own font settings."

- **Theme:** Mode, "System follows your Mac and switches with it.": System · Light · Dark, default
  System (`ThemeManager`; the Appearance menu sets the same thing). Above it the app adds a Theme
  row, "Night Watch ships with Shepherd, in light and dark.", naming the theme in
  `ui`/`textSecondary`: a name, not a popup, while one theme ships.
- **Layout** (see Density and row settings):
  - Sidebar rows, "Compact 22 · Standard 28 · Comfortable 36 pt, for the sidebar and menus.":
    Compact · Standard · Comfortable.
  - Density, "Row heights across the sidebar and chrome. Lower fits more agents.": a slider, 80–150%
    in 5% steps, neutral 100%.
  - Text size, "App chrome only.": a slider, 85–130% in 5% steps, neutral 100%.
  - Sidebar width, no description: a slider in points ("239 pt"), 190–340, neutral 232. Dragging the
    sidebar's edge moves it too.

#### Terminal

No board draws this page; the nav lists it. "Terminal panes beside a thread: their font and which
shell they run."

- **Font** (footnote "Font changes apply to open terminals in place; running processes are
  untouched."): Font family, "Fixed-pitch families installed on this Mac. Ghostty falls back if a
  family can't be loaded.", a popup with System font, a divider, then the installed families (a
  configured family that is missing stays listed); Font size, a slider in points ("12.5 pt"), 9–24
  in 0.5pt steps; Preview, "Updates as you change the family and size.", a 320pt card on `bgWindow`
  (radius `s`) with four shell lines in the chosen font and the theme's terminal colors.
- **Shell** (footnote "A new shell applies to panes opened afterwards."): Shell, "Used by ⌘D splits
  and the panes an agent opens." (the chord read from `KeybindingsStore`), a popup of known shells
  by path, in mono.

#### Agents (SettingsAgents, with QueueStates' settings card)

"Defaults for agents you create with ⌘N or the New Agent sheet. Existing agents keep their
settings." The chord is read from `KeybindingsStore`, so a rebind never leaves the copy wrong.

- **New agents:**
  - Default model, "Preselected in the New Agent sheet. “Use pi's default” passes no `--model` at
    all.": a popup whose first item is "Use pi's default · <pi's own default model>", then a divider
    and the catalog's model ids. The catalog and pi's default load in a task, never in `body`.
  - Default thinking level, "Can be changed per agent from the composer.": Off · Minimal · Low ·
    Medium · High · Extra high · Max, default Medium (pi uses the nearest level a model has).
- **While pi is working** (the queue's settings; QueueStates' card holds this copy, "Same two
  choices on every platform"):
  - Return while pi is working, "⌘↩ always does the other one.": Queue · Steer, default Queue. The
    chord is the store's alternate send. SettingsAgents also explains each choice ("Queue waits for
    the turn to end. Steer lands after the tool call Pi is running."); QueueStates' card drops that
    sentence, and its Steer half is retired (Where Shepherd departs from the boards).
  - When a turn ends, send the queue, "All at once arrives as one turn, in order." (SettingsAgents:
    "…in the order you queued it."): One per turn · All at once, default All at once. It is the
    host's default for its agents; Up next's ••• menu sets one agent's own.

#### Worktrees (SettingsWorktrees)

"How new worktrees are created, and what Finalize does when an agent's work is done." Every
automated step of the worktree flows can be turned off here.

- **New worktrees:**
  - Base branch, "**Remote default** starts clean from origin's default branch. **Current branch**
    stacks on your checkout's in-progress work. The New Worktree sheet lets you override it.":
    Remote default · Current branch, default Remote default.
  - Fetch before creating, "Fetch the base branch first so “remote default” is the remote's latest,
    not a stale local ref.": a switch, on.
- **Finalize** (footnote "The remote branch is never deleted by Shepherd — merging the PR cleans it
  up on GitHub. Per-repo GitHub settings live in the Finalize sheet."), switches:
  - Commit remaining work, "Commits anything left in the worktree using the PR title. Off stops
    Finalize on a dirty worktree.": on.
  - Generate PR descriptions, "Drafts an editable description from the branch's commits and diff;
    falls back to commit subjects.": on. Its model is `SHEPHERD_PR_DESCRIPTION_MODEL`, not a row.
  - Delete local branch, "After the worktree is removed, once Finalize has verified everything is on
    the remote.": on.
  - Merge PR automatically, "Tries GitHub auto-merge, so branch protection and required checks still
    gate it. A PR that can't merge is left open.": off. While it is on, the app discloses a Merge
    method row under it, "Must be allowed by the repository's settings.": Squash · Merge · Rebase,
    default Squash.

#### Pi (SettingsPi)

"Extensions Shepherd bundles into pi, defaults for native subagents, and keeping pi up to date."

- **Bundled extensions** (footnote "Applies to agents launched on this Mac, including automations
  and remote agents. Running agents keep their extensions until restarted. Status and session
  tracking are always on."), switches, all on by default:
  - Name agents automatically, "Titles each new agent from its first prompt using the cheapest
    authed model. A rename you type is always final."
  - Sync pi theme, "Use Shepherd's palette in pi and follow theme changes." (the theme extension
    reaches only pi run by hand in a terminal pane; the app says so: "…when you run pi by hand in a
    shell…")
  - Panes and agent tools, "Let agents control panes, message or spawn agents, manage automations
    and send notifications."
  - Diff review tool, "Let agents open the review pane with `review_diff`."
  - Native subagents, "Shepherd helpers, agent files, scripted workflows and durable missions. Needs
    pi 0.85.1+. Children stop with their parent." Turning it off hides the next group, which
    discloses back when it returns.
  - Subagent display, "Show subagent runs in their agent's thread, the inspector and the palette.
    Off doesn't stop them running." (the board says "in the sidebar"; subagents have no sidebar
    rows, see Subagents)
- **Native subagent defaults** (only while Native subagents is on; footnote "Precedence: explicit
  call → agent file → these defaults → parent. Child tools run with your account's access."):
  - Concurrency, "Child process limit per parent, including workflows.": a stepper, 1–16, default 4.
  - Model, "Agent files and explicit calls override this.": Inherit parent, a divider, then pi's
    model ids; the configured model stays listed even when the catalog lacks it.
  - Thinking, no description: Inherit parent, a divider, then Off · Minimal · Low · Medium · High ·
    Xhigh · Max.
  - Context, "Start each child fresh, or fork the parent's conversation.": Fresh · Fork.
  - Agent discovery, "Project profiles require pi project trust. Files stay the source of truth.":
    User + project · User · Project · Bundled only.
- **Updates** (footnote "Updating never restarts running agents."):
  - Update pi daily, "Runs `pi update` once a day.", and Update extensions daily, "Runs `pi update
    --extensions` once a day.": switches; turning one on applies it at once.
  - the version row (`SettingsActionRow`): "pi 0.87.1" in the title's style, and under it a 6pt
    `NWStatusDot` and the status in its state's text color, then " · uses the pi resolved from your
    login shell" in `textSecondary`. The status is one of Checking… (running) · Updating pi… /
    Updating extensions… / Updating pi and extensions… (running) · Update available · x.y.z
    (attention) · the error, in words (failed) · Not checked yet (idle) · Up to date, plus " ·
    extensions updated" once they have been (done). The words and the dot cross-fade (`content`).
    Actions: Check now ("Checking…" while it runs) and Update now, disabled until there is something
    to update. The app splits Update now into Update pi and Update extensions, each disabled until
    it can run, "Updating…" while it does, and "Extensions updated" after.

#### Remote (SettingsRemote)

"Connect to agents on other Macs over your VPN, or let other Macs connect to this one."

- **Hosts:** one row per host (`RemoteHostRow`, a `SettingsActionRow`): the name as its title; under
  it a line led by the connection's `NWStatusDot`: the address in mono 12
  (`horizon.starlight.internal:7433`), then " · " and the connection's word in its state's text
  color, and " · 5 agents" while connected, in the description's Geist. The words: connected (done),
  connecting… (running), disconnected (idle), or a failure's headline in lower case (unreachable,
  token refused, update needed, no token, token locked; failed). A failed host adds its sentence
  under the line as the row's problem ("Shepherd isn't running on horizon, or it can't be reached.",
  "horizon refused the token. Edit the host to paste its current token.", "horizon runs a newer
  Shepherd. Update Shepherd here to connect."), with the client's reason as its tooltip. Actions:
  Edit and Reconnect (secondary), Remove (danger), each labelled with the host's name for VoiceOver.
  With no hosts the app shows one row, "No remote hosts", "Add a Mac running Shepherd below. Its
  agents appear in the sidebar under its name." Hosts arrive and leave on `list`.
- **Add host:** Name, "Shown as the sidebar section label." (prompt "mac mini"); Address,
  "VPN-reachable IP or hostname." (mono, "100.x.y.z"); Port, no description (mono, prompt "7433", or
  "7434" in Shepherd Nightly; digits only, so a pasted "7,433" never becomes another port); Token,
  "Contents of the host's remote-token file." (mono, secure, "paste token"); then an action row with
  Add host (secondary), disabled until all four are valid. Edit loads a host into the same form: the
  group is titled Edit host, and its action row reads Cancel (ghost) and Save.
- **Serve this Mac** (footnote "Remote sessions run on the host Mac; your VPN is the transport and
  the token keeps other devices out."):
  - Listener, "Let other Macs with your token connect to agents here.": a switch. While it is bound
    the description reads "Serving on port 7433. Other Macs with your token connect to agents here."
    A bind failure is the row's problem, "Couldn't start: port 7433 is already in use."
  - Token, "Paste this into the other Mac's Token field. Delete the file to revoke every client.": a
    `PathRow` for `remote-token` with Reveal.

#### Keyboard (SettingsKeyboard)

"Click a shortcut to record a new one. Shortcuts must include ⌘."

- **A shortcut row:** the action's name as its title, in sentence case with "…" when it opens a
  sheet ("New agent with options…"), and its keycaps trailing. Clicking the keycaps records: they
  become "Press keys…" (`caption` in `running` on `runningTint`, a `running` hairline, radius `xs`),
  the next chord is proposed, and ⎋ cancels. A chord the rules reject (Keyboard) is refused with its
  reason as the row's problem. A changed shortcut shows Reset (`.nwLink`) just before its keycaps,
  `NW.Space.xs` away. A change reaches every menu, keycap, and terminal surface at once.
- **Groups on the board:**
  - Agents: New agent in current checkout ⌘N · New agent with options… ⇧⌘T · New space… ⇧⌘N · Rename
    agent… ⌘R · Next agent · Previous agent · Command palette. The board shows Next agent, Previous
    agent, and Command palette rebound (⌘J, ⌘K, ⌘P) with Reset beside them; their defaults are ⌘↓,
    ⌘↑, and ⌘K.
  - Panes: Split vertically ⌘D · Split horizontally ⇧⌘D · Close pane ⌘W · Focus next pane ⌥⌘→ ·
    Focus previous pane ⌥⌘←.
  - Fixed, not recordable: Select agent 1–9, "Sidebar order; hold ⌘ to see the numbers." (⌘ 1–9) ·
    Settings (⌘ ,) · Confirm / cancel in sheets (⏎ esc).
  - Under the last group, trailing: Reset all shortcuts, a secondary button, disabled while nothing
    is changed.
- **Every rebindable action is listed**, in the menu bar's groups: the app adds Delete agent ⇧⌘W to
  Agents, a Thread group (Stop agent, Model picker, Previous turn, Next turn, Inspect subagent),
  While pi is working (QueueStates' Keyboard card, in its order: ↩ and ⌘↩ named for what they do
  under the Return setting, "Send, queued" or "Send and steer now"; Edit the last queued message ↑;
  Move the focused message ⌥↑↓; Delete the focused message ⌫; Steer the focused message ⌘↩; Stop pi
  Esc; only ⌘↩ records), a Window group (Show or hide the sidebar, the side pane), and Show or hide
  terminal ⌘J and Maximize or restore terminal ⇧⌘↩ in Panes. Its Fixed group (agents ⌘1–9, the side
  pane's Changes ⌃1, Settings, sheets, Reset all) has the footnote
  "Changes apply immediately, everywhere a shortcut is shown."

#### Advanced (SettingsAdvanced)

"Files, resets and app updates. Quitting Shepherd stops every agent."

- **Files:** Workspace state, "Spaces, agents and pane layouts restored on relaunch.", and Extension
  socket, "Where each pi process reports status and pane requests.": `PathRow`s, the file's name in
  mono `textSecondary` (`state.json`, `shepherd.sock`; the full path as its tooltip) and Reveal,
  which selects it in Finder.
- **Updates:** Check for updates automatically, a switch; Update channel, "Stable: tagged releases.
  Beta: pre-releases, plus newer stable builds. Nightly builds are a separate app, Shepherd
  Nightly.": Stable · Beta. Shepherd Nightly names its one channel instead ("Nightly", in
  `ui`/`textSecondary`), "Every push to the integration branch, least tested. Tagged releases ship
  as Shepherd." Last, "Version 0.1.0 (1)" (the short version and the build) with Check for updates.
  Debug builds have no updater: the group holds only the version row, with no button, and Sparkle's
  rows disclose once it reports it can update.
- **Reset:** Reset settings, "Restores appearance, font, agent and keyboard preferences. Spaces,
  agents and layouts are untouched.": Reset… (danger) opens `ResetSettingsDialog` ("Reset settings
  to defaults?", "Your spaces, agents and pane layouts are not affected.", Cancel and a destructive
  Reset).

#### Wide pages: Instructions and Experiments

**Not built yet.** These two pages are wider than the 720pt column: the page fills the detail area
on `bgWindow`, 44pt from the top, 40pt at the sides, 32pt at the bottom, with its blocks 20pt apart.
Under the header (the same 22/600 title and `body` explanation, capped at 820pt) sits a main column
that takes the room and a fixed side column of reference and history (330pt on Instructions, 320pt
on Experiments), 28pt and 32pt apart. Their section labels sit `NW.Space.xxs` in and `NW.Space.m`
above what they label, and a label may carry a trailing text action ("Add all"). Lists in the side
column (files, history, steps, what was added) are bare rows separated by `lineSubtle` hairlines,
not cards; only Instructions' reading order uses small cards.

#### Instructions (SettingsInstructions)

**Not built yet.** The page edits pi's two root instruction files, which every pi session reads at
its start: `AGENTS.md` ("how you work") and `APPEND_SYSTEM.md` ("rules that override everything
else"). It sits between Pi and Remote in the nav, with `doc.text`. Header: "Instructions", then
"Pi's root files, read at the start of every session: `AGENTS.md` for how you work,
`APPEND_SYSTEM.md` for rules that override everything else. Repos can still add their own
AGENTS.md." (file names in mono). As everywhere, the app writes the boards' "Pi" in running text
as "pi" (Where Shepherd departs from the boards).

- **Same on every host:** a card (radius `m`, a `lineSubtle` line, `bgWindow`,
  `NW.Space.l`/`NW.Space.xl` padding): the title "Same on every host" in the row title style, under
  it "Save once; Shepherd writes both files to each host's `~/.pi/agent/`. Offline hosts catch up
  when they're back." in `textSecondary`, and a switch trailing (on in this board).
- **Host chips** under it, 8pt apart and wrapping: one per machine (This Mac, then each remote
  host). A chip is 34pt tall, radius `m`, `NW.Space.l` side padding and 8pt gaps: a 13pt
  `desktopcomputer` glyph in `textSecondary`, the host's name in mono 12.5, a 7pt state dot, and its
  state word in Geist 11 in the state's color. With Same on every host on, the chips report sync:
  "synced" and "synced 2m ago" (done), "offline · will sync" (a `textTertiary` dot and word).
  The host whose copy is open (This Mac) is selected: a 1px `textPrimary` line on `bgSelected`, its
  name semibold; the others have a `lineStrong` line on no fill, names at 500.
- **File tabs:** `AGENTS.md` and `APPEND_SYSTEM.md` as underline tabs 22pt apart over a `lineSubtle`
  rule. A tab is the file name in mono 13 (semibold `textPrimary` and a 2pt `textPrimary` underline
  when chosen; 500 `textSecondary` otherwise) beside a Geist 11.5 `textTertiary` note of what it is
  for and its size: "how you work · ~640 tokens", "rules that win · ~90 tokens".
- **The editor**, 12pt under the tabs, filling the column: a card with a 1px `lineStrong` line,
  radius `m`, on `bgWindow`.
  - Its header (`bgSunken`, a `lineSubtle` rule under it, 8pt × 12pt padding): the file's path in
    mono 12 `textSecondary` (`~/.pi/agent/AGENTS.md`); "● edited" in Geist 11.5 `lanternText` while
    there are unsaved changes; then trailing, 24pt buttons: History and Revert (ghost, 12/500
    `textSecondary`), and the primary Save, which names where it writes ("Save to 3 hosts", or
    "Save" for one host) with its ⌘S in mono 10.5 at 60% inside the button (lantern fill,
    `textOnLantern`, 12/600). With nothing edited, Save and Revert disable (honest affordances); ⌘S
    saves while the page is open.
  - Its body: the file as plain Markdown text, mono 12.5 on 21pt lines, 10pt above and below, with a
    34pt gutter of line numbers (mono 10.5, `textTertiary`, right-aligned, 12pt before the text).
    Highlighting is light: heading markers in `textTertiary` and heading text semibold
    `textPrimary`; list bullets in `lanternText`; code spans in `synString`; everything else
    `textSecondary`. A line changed since the last save is tinted `lanternTint` across the editor.
- **How Pi reads them** (the side column, 330pt): five steps in order, each a small card (radius
  `m`, a `lineSubtle` line, `bgRaised`, 8pt × 10pt padding) joined by a 10pt connector (a 1.5pt
  `lineStrong` line under the number column): the step number in mono 10.5 `textTertiary` (16pt
  wide), a title in mono 11.5 semibold (truncating) over a note in Geist 11 `textTertiary`:
  1. "Pi's system prompt", "built in"
  2. "~/.pi/agent/AGENTS.md", "this file · every repo"
  3. "AGENTS.md in parent folders", "if any"
  4. "the repo's AGENTS.md", "most specific context"
  5. "~/.pi/agent/APPEND_SYSTEM.md", "appended last · wins"

  The open file's step is marked: a `lanternText` line on `lanternTint` (step 2 for `AGENTS.md`,
  step 5 for `APPEND_SYSTEM.md`). Under the steps, a 12/1.5 `textTertiary` note: "Later files win.
  Running sessions keep the version they started with; new threads, mission stations and automations
  get this one." (Mission stations wait for Missions.)
- **Where it writes:** the paths shown are the root of the pi Shepherd runs
  (`PiConfig.agentDirectory`). Before building, settle this page against pi isolation: Shepherd must
  never write the user's own `~/.pi/agent/`, so with a bundled pi the page edits that pi's home and
  shows its path. Saving to a remote host needs a write request in the remote protocol; an offline
  host takes the save when it reconnects.

#### Instructions per host (SettingsInstructionsHosts)

**Not built yet.** With Same on every host off, each machine keeps its own root files and the page
edits one host at a time. The explanation reads "Per host: each machine keeps its own root files.",
and the switch's card "Off: each host keeps its own files. Pick a host to edit it."

- **Host chips** pick the host to edit (the selected chip as above) and report how its files compare
  with This Mac's: a `done` dot and no word when they match; "differs · 2 lines" (`lanternText`
  dot and word) when they don't; "offline" (`textTertiary`). This Mac's chip, the reference, shows
  its dot alone.
- **Comparing a host that differs:** the editor card's header reads "build-01 compared with This
  Mac" (both names in mono, "compared with" in `textTertiary`, Geist 12.5), with a small segmented
  control (`NWSegmentedPicker` s, 20pt) trailing: Diff · build-01's file. Diff shows the file as the
  review's diff lines do, mono 12 on 22pt lines, a 34pt number gutter and a 14pt sign column:
  removed lines `−` in `failed` on `failedTint`, added lines `+` in `done` on `doneTint`, context in
  `textSecondary` with a blank sign. "build-01's file" opens that host's file in the editor.
- **Resolve** (a section label under the editor): three buttons, 28pt, wrapping: "Copy This Mac's to
  build-01" and "Copy build-01's to all hosts" (secondary), "Keep build-01 different" (ghost). Under
  them a 12/1.5 `textTertiary` note ends "Shepherd shows the difference once, then stops asking.":
  keeping a host different is remembered, and Shepherd stops asking about that difference.
- **The side column:**
  - Files on each host: a row per host, at least 48pt, a hairline above each: a 14pt
    `desktopcomputer` glyph, the name in mono 12.5 semibold over its agent directory in mono 10.5
    `textTertiary` (`/Users/baily/.pi/agent`, `/home/baily/.pi/agent`); trailing and right-aligned,
    when it last changed in Geist 11.5 ("edited 2m ago", "edited Sep 19"; "last seen 07:12" for an
    offline host) over a Geist 11 note: which files it holds ("AGENTS · APPEND", `textTertiary`), "2
    lines differ" (`lanternText`), or "matched This Mac" (`textTertiary`).
  - The other file's status in one line under its name as a label ("APPEND_SYSTEM.md", then "Same on
    all three hosts." in 12.5 `textSecondary`).
  - History · build-01: the chosen host's saves, newest first, rows at least 30pt with a hairline
    above each: the date in mono `textTertiary` in a 60pt column ("Sep 19"), what changed in 12
    `textSecondary` ("Added the Docker socket line", "Synced from This Mac", "Created by Shepherd"),
    and Restore as a trailing `running` text action.

#### Experiments (SettingsExperiments)

**Not built yet.** The last page of the nav, with `flask`: features still being tried, each off
until the user turns it on. Header: "Experiments", then "Features we're still trying out. Each is
off until you turn it on." Its one experiment today is Suggested instructions.

- **An experiment card:** a card with a 1px `lineStrong` line, radius `m`, on `bgWindow`.
  - The top, 14pt × 16pt padding, aligned to the top: a 36pt tile (radius `m`; the board's 9,
    `lanternTint`) holding the experiment's glyph (18pt, `lanternText`; `flask` here); the name in
    Geist 14/600 ("Suggested instructions") beside a small mono 10.5 tag in `lanternText` on
    `lanternTint` (18pt tall, radius `xs`) saying since when it has been on ("on since Sep 12");
    under them its description in 12.5/1.5 `textSecondary`, at most 620pt wide: "When an agent
    learns something the hard way (a re-run, a failed check, a correction from you) it drafts one
    line for your root instructions. Nothing is written until you add it."; the switch trailing.
  - Its options, while on, under a hairline on `bgBase`: rows of at least 48pt with a 13/500 title
    over a 12 `textSecondary` description and the control trailing:
    - Learn from, "Where agents may notice a lesson.": `.nwCheckbox`es 14pt apart for Missions,
      Threads, Automations (all on).
    - Can suggest for, "APPEND_SYSTEM.md overrides everything else, so it stays off unless you want
      it.": `AGENTS.md` (on) and `APPEND_SYSTEM.md` (off).
    - Hosts, "Follows Settings › Instructions. Right now that's every host, unless a lesson only
      applies to one.": a 190pt popup, "Follow Instructions".
- **Waiting for you · 3** (a label with the count, and "Add all" trailing as a `running` text
  action): the drafted lines, newest first, cards 8pt apart. A suggestion card is radius `m`, a
  `lineSubtle` line on `bgRaised`, 12pt × 14pt padding, three lines 8pt apart:
  - where it came from: a 13pt glyph for the source (a mission's map in `lanternText`; an
    automation's `bolt` and a thread's bubble in `textSecondary`), its name in 12.5/600, and the
    source's kind and age in 12 `textTertiary` ("mission · 2h ago", "automation · yesterday",
    "thread · Sep 19"); trailing, a 24pt target chip (radius `s`, a `lineStrong` line, Geist 11.5)
    that retargets it: a doc glyph and the file in mono (`AGENTS.md`), a `textTertiary` "·", a
    `desktopcomputer` glyph and the hosts in `textSecondary` ("every host", "build-01"), and a
    chevron
  - the line itself as it would be added: mono 12.5/1.5 on `doneTint` (radius `s`, 6pt × 10pt
    padding), a `done` "+ " before the Markdown (its bullet in `lanternText`, code spans in
    `synString`)
  - the reason in 12 `textSecondary` ("A missing checkout_id made two services re-run their
    stations."), then 24pt buttons: Dismiss and Edit first (ghost), and "Add to AGENTS.md"
    (secondary), which names the target file
- **How it works** (side column): three numbered steps separated by hairlines, the number in an 18pt
  `lineStrong` ring (mono 10.5 `textSecondary`), a 12.5/1.5 sentence whose lead is semibold and
  whose rest is `textSecondary`: "An agent hits something it had to learn" a re-run, a red check, or
  you telling it no. · "It drafts one line" for a root file, with the reason and which hosts it
  applies to. · "You decide" Add it, edit it first, or dismiss it. Dismissed lines aren't suggested
  again.
- **Added from suggestions:** rows of at least 44pt, a hairline above each: the added line in 12.5
  over "Sep 18 · from Ledger cleanup" in 11 `textTertiary`, and Undo as a trailing `running` text
  action.
- **About experiments:** a 12/1.5 `textTertiary` note, "Experiments can change or go away. Turning
  this one off keeps the lines you added and drops what's waiting.", and a small secondary Send
  feedback button with a bubble glyph.
- **Rules:** nothing is written to an instruction file until the user adds a line (Add, Add all, or
  Edit first then save); a dismissed line is never suggested again; Undo removes an added line from
  its file. Missions as a source waits for Missions.

### Dialogs and sheets

Creation sheets (New Agent, New Worktree, Finalize Worktree, the directory picker, the remote
worktree sheet, a remote automation's Details and Runs, the review's Commit…) and every
confirmation share one anatomy, `NWDialog` (`NWDialogMetrics`), flat on `bgWindow`, built from
the Controls and Status & feedback parts (no board draws a Mac dialog). The creation sheets and
Delete Worktree Agent take `.dialogSheetFrame()`: the window is `bgWindow` from the first frame,
and the title stays still while rows disclose.

- **Width:** 460pt by default (`NWDialogMetrics.width`); Rename 420
  (`AppLayout.renameSheetWidth`), Delete Worktree Agent 520 (`confirmSheetWideWidth`), and the
  creation sheets their own (`AppLayout+Settings.swift`: New Agent 560, New Worktree 520,
  Finalize 560, the remote worktree sheet 620, a remote automation 560, the directory picker
  480, Commit… 520).
- **Header:** a 24pt inset (`NWDialogMetrics.inset`) above and at both sides, 12pt below; the
  title in `title`/`textPrimary` (a header to VoiceOver), and 4pt under it an optional
  explanation in `body`/`textSecondary`. Both wrap.
- **Labeled rows** (`NWSheetRow`, aliased `SheetRow`): a 96pt label column in `ui`/
  `textSecondary`, 12pt, then the control filling the rest; 8pt vertical padding, at least 44pt
  (a 28pt control with 8pt above and below), and a hairline underneath from the 24pt inset to
  the trailing edge. `alignment: .firstTextBaseline` for a control that wraps. A read-only value
  (a path, a branch) is `mono`/`textSecondary`, selectable, truncated in the middle with the
  whole value as its tooltip. No form chrome and no grouped boxes.
- **Lists of steps or checks** (`NWChecklistRow`): at least 28pt (`NW.Height.row`): the 14pt
  state glyph (`NWStateGlyph`: spinner, check, cross, ring), 8pt, the label in `ui`
  (`textPrimary` while running or asking, `textSecondary` once done, `failed` when failed,
  `textTertiary` while pending), and a trailing `caption` detail (`textTertiary`, `failed` when
  failed; middle-truncated, the whole as its tooltip). A failed check's remedy discloses
  underneath, indented past the glyph. The glyph pops once when a step passes, and the row
  reads "label, state, detail" to VoiceOver.
- **Footer:** 16pt above, the 24pt inset around: an optional status on the leading edge
  (`NWDialogStatus`: `caption`/`textSecondary`, `failed` for an error, two lines at most,
  selectable: "Checking for unsaved work…", "Creating the worktree…"), and the actions
  trailing, 8pt apart. Actions never truncate; the status wraps instead.
- **Actions** (`DialogAction`): exactly one primary (`.prominent`: `.nw(.primary)`, the ⏎ default);
  Cancel is `.nw(.ghost)` with ⎋, as every board that draws a Cancel has it (Known gaps); any other
  action secondary. A destructive action is the `dangerFill` button (`.destructive`) and never the
  default: destroying things takes a click. While an action runs, its button says so ("Starting…",
  "Creating…") and is disabled.
- **Banners:** anything a destructive action would destroy is called out in an attention
  banner (`DialogBanner`: an `NWBanner` at the 24pt margins, 12pt below what precedes it,
  disclosing when it arrives late); an error is a `failed` banner. Never a system alert.
- **Acting after dismissal:** a confirmation that tears down a mounted layout (Delete Worktree
  Agent, Remove Space, an agent's delete) lets its sheet finish dismissing (300ms) before it
  acts; changing the window under a sheet mid-dismissal wedges the modal session.

New Agent's Model row takes "provider/id" (pi's default, or Settings' default, prefilled in that
form), and its Thinking row follows the composer's thinking chip: it shows only while the chosen
model (blank: the target's default) takes a thinking level, as the target's catalog says. A model
the catalog does not know, or a catalog still loading, keeps it. It offers Off, Minimal, Low, Medium
and High, with Extra high and Max where the target's models.json maps them
(`ModelListing.thinkingLevels`), and Off to High on a host without `thinking.levels.v1`; a chosen
level the model lacks shows (and starts) as the one pi would use. The model suggestions truncate
in the middle, the whole id in each one's tooltip.

**Finalize Worktree** (`FinalizeWorktreeSheet`, 560pt; no board draws it) runs commit → push →
pull request → (merge) → verify clean → remove worktree → delete local branch in one sheet,
titled by phase: "Finalize worktree", "Set up Finalize", "Worktree finalized", "Finalize stopped".

- **Checking:** "Checking prerequisites…", with a spinner and "Checking git, origin and the GitHub
  CLI…" in the footer and Cancel.
- **Set up** (when a check fails): an `NWChecklistRow` per prerequisite (Git installed, Git
  identity, Origin reachable, GitHub CLI, GitHub CLI signed in), each failing row growing its
  remedy (install the command line tools, name and email fields with Apply, "brew install gh"
  with Copy, "Open a terminal for gh login…"), and "Recommended GitHub repo settings"
  (Auto-delete merged branches, Allow auto-merge, each with Enable…). Footer: "All set — ready to
  finalize" once every check passes, then Re-run checks, Cancel, and Continue (primary).
- **Input:** Worktree and Branch rows in mono, Base (a mono field, 200pt at most, with "Will include
  n commits" beside it, in `lanternText` past 20), Title, and Description (a 72pt editor with
  Generate… / Regenerate…, or a spinner and "Generating…"). Footer: Repo setup… on the leading edge,
  Cancel, and Finalize (primary; disabled while the description generates or while the title or the
  base is empty). A checkout another operation holds shows a failed "Finalize can't start yet"
  banner.
- **Running and after:** a checklist row per step ("commit remaining work", "push branch to
  origin", "create pull request", "merge pull request" only when Settings ▸ Worktrees merges
  automatically, "verify nothing is left behind", "remove worktree", "delete local branch"), each
  with its state's glyph (pending, running, done, skipped, failed) and its detail; once done, a
  Pull request row with the URL and Open…, and Done, which closes the sheet and removes the
  agent; after a failure, Close.

`DialogSheet` and `DialogAction` (`DialogSheet.swift`) build a confirmation from that anatomy.
`AppDialogs` (`AppDialogs.swift`) presents the view model's sheets (New Agent, New Worktree,
Finalize, the directory picker and Import existing worktree, renames, deletes, a remote host's
worktree and automation sheets, a failed action), mostly with `sheet(item:)`, so a sheet keeps
the value it opened with while it animates away. The composer presents Stop all, the review
pane its Revert and Commit…, Settings ▸ Advanced its reset, and `QuitConfirmation` the quit
dialog. There is no `.alert`, `confirmationDialog`, or `NSAlert` in the app:

- Rename agent and Rename space (`RenameDialog`, 420pt): one field seeded with the name and
  focused; ⏎ renames, and an empty name cannot. Rename space adds "Sidebar label only — the
  folder on disk is not renamed."
- Delete Worktree Agent (`WorktreeDeleteDialog`, 520pt): "Delete worktree agent", "Stops <agent>.
  “Delete agent and worktree” also removes its checkout and branch.", rows for the Worktree (mono,
  middle-truncated) and the Branch, "Checking for unsaved work…" in the footer while git looks,
  an "Unreconciled work" attention banner ("<what> will be lost with the worktree.") when there
  is some, then Cancel, Delete agent only, and a destructive Delete agent and worktree that stays
  disabled until the check is in
- Remove Space (`SpaceDeleteDialog`): "Remove space", "Removes <space> from the sidebar and stops
  its <n> agents. Conversations stay on disk; the checkout is untouched. Nested project spaces
  are separate and survive.", Cancel and a destructive Remove space
- An agent asking to delete another (`PeerDeleteDialog`, "Delete agent"): rows for the agent, its
  worktree branch (else its directory, so agents sharing a name can be told apart), its space, and
  who asked, an attention banner (its pi session and everything it started stop; a worktree agent's
  worktree and branch are kept), Cancel (⎋) and a destructive Delete agent. Only that button
  approves. The dialog closes by itself when the request lapses (cancelled, the asking agent gone,
  or two minutes without an answer).
- Stop all (`StopAllDialog`): "Stop the agent and every running subagent?", a live count ("2
  subagents are still running."), Cancel, Stop only the agent, and a destructive Stop all
- The review's Revert (`RevertFileDialog`): "Discard the changes to <path>?", then "The new file
  moves to the Trash." or "The file returns to its last committed version. This cannot be undone
  from Shepherd.", a Repository row (mono, middle-truncated), Cancel and a destructive Discard
  changes. Commit… (`ReviewCommitSheet`) is described with the review pane.
- A failed agent action (`ActionErrorDialog`): "Agent action failed", the error selectable, and
  OK (primary)
- Reset settings (`ResetSettingsDialog`): "Reset settings to defaults?", "Your spaces, agents and
  pane layouts are not affected.", Cancel and a destructive Reset
- Quitting while agents are working or waiting on you (`QuitDialog`), because quitting stops
  them mid-turn: "Quit and stop every working agent?" ("Quit and stop the working agent?" for
  one), and "<n> agents are still working. Their conversations stay on disk and reopen on next
  launch." It lists the busy agents (five named in `rowCompact` rows, each with its status dot,
  its name in `ui` `textPrimary`, and "working" in `caption` `textTertiary` or "needs you" in
  `lanternText`; "and n more" under them), with Cancel (⎋) and a destructive Quit, so ⏎ never
  quits. `QuitConfirmation` puts it on the main window as a critical sheet, so it shows even over
  another sheet. A closed window is reopened first; if it is not back within a second, the
  dialog opens in a window of its own. While it asks, AppKit disables Quit, so a second ⌘Q does
  nothing. A log out, restart, or shut down quits without asking, and one that begins while the
  dialog is up answers it with Quit.

Git probes and directory listings run off the main thread; the Delete Worktree Agent dialog
keeps its destructive action disabled until the unreconciled-work check is in.

## Status language

One enum, `AgentState`, drives every status surface (NWStatus), and color always comes with a
word or a glyph's shape: a pill in headers and cards, a dot (with its word where the row has
room) in rows, a glyph in tool rows, steps, and checklists, a spinner for a tool or turn in
progress, a bar for steps and budget, and a step strip for a run's steps. The parts are under
Components › Status and feedback.

| Lifecycle | `AgentState` | Sidebar | Composer |
| --- | --- | --- | --- |
| Agent working | `running` | blue dot; elapsed trailing | Stop (outlined beside Send with a draft); ↩ queues in Up next or steers |
| Agent blocked on a question | `attention` | lantern dot, glowing; "ASK" | the question panel in place of the field |
| A subagent needs you | `attention` | its agent's row: lantern dot, glowing; "ASK" | the card's answers and Reply… |
| Agent done | `done` | green dot | Send |
| Agent done, its turn failed | `failed` | red dot | Send |
| Agent idle | `idle` | hollow ring | Send |
| pi starting | `idle` | hollow ring | Send, which waits for pi; only when pi is slow (two seconds, half a second over a blank thread), "Starting pi…" beside it |
| Connection lost | `failed` | — | Send, plus a `failed` banner with Reconnect |

Subagent runs use the same states on their dots, glyphs, pills, and steps: running, needs you,
done, failed, and queued (queued or paused, hollow). Tool calls use running, done, and failed.

**Not built yet: stuck.** `AgentState.stuck` marks an agent or run that has been running too
long without progress. Its dot and pill take `failed`'s color and tint and say for how long
("Stuck 14m", NWStatus); where a glyph stands alone it is `exclamationmark.triangle`. Nothing
detects it yet, and the board fixes no threshold.

A turn fails when pi's last reply is a provider error (not a Stop). The thread shows the error
(`NWTurnError`), and the agent's row (an automation's too) and its palette subtitle read failed
until its next turn starts.

Agent events that need a sentence are banners inside the pane they concern (Components › Status
and feedback), never a modal alert; the one modal an agent can raise is `PeerDeleteDialog`
(Dialogs and sheets).

**Outside the app** the same language holds. A notification's group follows the state
(`attention` is Needs you, `failed` is Problems, `done` is Finished), and a Live Activity draws
the same dots, glyphs and words. What each notification says, when it is sent, and what the Mac
posts today are in Notifications and Live Activities.

## Components

`Packages/ShepherdUI/Sources/ShepherdUI/Components` is the shared library, by domain, with
`#Preview`s of every component in both appearances in `Previews/`. Use a component before
composing chrome by hand. Debug builds have a **Component Gallery** (View menu,
`ComponentGallery.swift`) that shows the base components in their states.

| Domain | Components | Owned in the app by |
| --- | --- | --- |
| Controls | `.buttonStyle(.nw(_:size:tint:))` (primary, secondary, ghost, danger, dangerFill; s 24 · m 28 · l 32), `.nwIcon` and `.nwIcon(bordered:isOn:size:tint:)` (a circle, 28pt, 44 on iOS; "on" is lantern tint), `.nwLink`, `.nwRow(selected:)`, `.nwRowBackground(selected:hovering:)`; `.toggleStyle(.nwSwitch)` (30×18) and `.nwCheckbox` (14pt); `NWSegmentedPicker` (m 24, s 20), `NWPopupMenu` and `NWPopupLabel`, `NWValueSlider`, `NWStepper`; `.textFieldStyle(.nw)` and `.nw(mono:error:)` (28pt, radius 6), `.nwField(focused:error:mono:)`, `.textFieldStyle(.nwSearch)`, `NWSearchField`; `NWKeycap`, `NWCountBadge`, `NWTag`, `.nwHelp(_:shortcut:)` | across the app; the radio group is not built |
| Status | `NWStatusPill` (20pt, radius 4; a glyph in place of its dot), `NWStatusDot` (6pt), `NWStateGlyph` (14pt), `.progressViewStyle(.nwSpinner)` and `.nwBar` (4pt), `NWStepStrip`, `NWSparkline`, `NWBanner`, `.nwToast(item:)` with `NWToast`, `NWEmptyState`, `.nwShimmer()`, `NWWordmark`, `NWCrook` | across the app; `NWSparkline` and `.nwToast(item:)` have no app use (see departures), and `.nwShimmer()` none yet |
| Containers | `NWSectionHeader`, `NWGroupCard`, `NWCardRow`, `NWHairline`, `NWChoiceRow` (`NWChoiceRowMetrics`), `NWFlowLayout` | `SettingsComponents.swift`; hairlines everywhere; `NWChoiceRow` in the iOS client's New thread pickers; `NWFlowLayout` for wrapping chips and answers (iOS) |
| Navigation | `NWSidebar`, `NWSidebarSection`, `NWSidebarRow`, `NWSidebarDisclosureRow`, `NWSidebarNoticeRow`, `NWSidebarFooter`, `NWDropIndicator`, `NWDensity`; `NWThreadToolbar`, `NWPaneToggle`, `NWOptionsMenu`, `NWPaneHeader`; `.nwCommandPalette(isPresented:)`, `NWPaletteCard`, `NWPaletteSearchRow`, `NWPaletteSectionHeader`, `NWPaletteRow` | `SidebarView.swift`, `RemoteSidebarSection.swift`, `ThreadHeader.swift`, `RootView.swift`, `CommandPaletteView.swift`; the review's header (`DiffReviewView.swift`) and the inspector's ⋯ menu (`Thread/SubagentInspector.swift`) |
| Thread | `NWUserBubble` (its time shown while `revealed`; `origin: .steered`), `NWQueueDivider`, `NWAgentProse`, `NWCodeBlock`, `NWThinking`, `NWActivityLine`, `NWActivityCalls`, `NWChangesCard`, `NWDiffStat`, `NWInlineCode`, `NWAttachmentChip`, `NWTurnFooter` (shown while `revealed`), `NWTurnError`, `NWWorkingRow`, `NWJumpToLatest` | `Thread/ThreadView.swift`, `ThreadTurns.swift` (with each turn's `MessageHover`), `ThreadTools.swift`, `ThreadMarkdown.swift` |
| Composer | `NWComposer`, `.nwComposerChip(active:)`, `NWChipChevron`, `NWComposerActionButton` (outlined Stop, Send's ring), `NWMenuHeader`, `NWSlashMenu`, `NWModelPicker`, `NWThinkingMenu`, `NWSendMenu`; the queue: `NWQueueStack`, `NWQueueRow`, `NWQueueEditor`, `NWQueueDeletedRow`, `NWQueueMoreRow`, `NWQueueNumber`, `NWQueueGlyph`, `NWGripGlyph`, `NWQueueMetrics` | `Thread/Composer.swift`, `Thread/QueueStack.swift` |
| Agents | `NWSubagentCard` (`NWSubagentRun`, `NWSubagentQuestion`), `NWRunsStrip`, `NWRunLedger`, `NWInspectorHeader`, `NWRunBrief`, `NWRunActions`, `NWBranchGlyph`, `NWElapsedText`, `NWDuration`, `NWInlineMarkup`, `.nwRunArrival`; touch forms for iOS (`NWRunCard`, `NWRunGroupCard`, `NWRunHeader`, `NWRunTabs`, `NWSteerField`, …) | `Thread/Subagents.swift`, `Thread/SubagentInspector.swift`, `Thread/SubagentPresentation.swift`; the iOS client |
| Review | `NWFileStrip`, `NWFileHeader`, `NWDiffView`, `NWDiffLine`, `NWHunkHeader`, `NWFoldRow`, `NWInlineComment`, `NWCommentEditor`, `NWReviewComposer`, `NWDiffMetrics`; the commit form (`NWCommitMessageEditor`, `NWCommitFileRow`, `NWCommitOptionRow`); touch forms for iOS (`NWTouchDiffLine`, `NWSplitDiffRow`, `NWTouchFileStrip`, `NWLineCommentBar`, `NWReviewFileRow`, …) | `DiffReviewView.swift`, `ReviewCommitSheet.swift`; the iOS client |
| Dialogs | `NWDialog` (`NWDialogMetrics`), `NWDialogStatus`, `NWSheetRow`, `NWChecklistRow`, `NWSettingsNavRow` | `DialogSheet.swift`, `AppDialogs.swift`, the sheets, `QuitConfirmation.swift`, `SettingsView.swift` |
| Automations | `NWAutomationRow` (a row with its switch), `NWAutomationSwitch`, `NWFactRow` and `NWFactText`, `NWAutomationPrompt`, `NWRunBars`, `NWRunRow`, `NWAutomationMetrics` | `RemoteAutomationSheet.swift`; the iOS client's `Automations/` |
| Design tool (not built yet; `Components/DesignTool/`) | `NWDesignCanvas`, `NWBoardFrame`, `NWSelectionRing`, `NWCommentPin`, `NWBoardActions`, `NWCanvasToolbar`, `NWCommentCard`, `NWCommentThread`, `NWTweakRow`, `NWTokenChip`, `NWTweakScope`, `NWDesignSystemChip`, `NWTokenSwatch`, `NWExportFormatCard`, `NWLiveLinkField`, and `NWActivityLine`'s `.drew` and `.checked` kinds (see Design tool) | nothing yet |
| Missions map (not built yet; `Components/MissionMap/`) | `NWMissionMap`, `NWStation`, `NWTerminus`, `NWFlowWire`, `NWDataWire`, `NWForkBar`, `NWJoinBar`, `NWOutcomeChip`, `NWPinRow`, `NWLane`, `NWFog`, `NWFrontierChip` (see Missions: the map) | nothing yet |
| Mission screens (not built yet; `Components/Missions/`) | `NWMissionHeader`, `NWPhaseBar`, `NWBudgetMeter`, `NWHostChip`, `NWChoiceCard`, the mission question card, `NWPlannerNote`, `NWAttemptRow`, `NWCheckpointRow`, `NWSpendBar`, `NWTrainCard`, `NWTrainGateRow`, `NWTrainRuleRow`, `NWRepoTimeline`, `NWPathLockRow`, `NWContractRow`, `NWDiffAnnotation`, `NWTraceSpan`, `NWMergeActions`, `NWRollbackRow`, `NWTemplateInput`; iPhone: `NWMissionLiveActivity`, `NWMissionNotification`, `NWLaneStrip`; in `Components/Agents`: `NWMissionNode`, `NWInboxItem`, `NWClaimRow` (see Missions: motion, keyboard and parts to build; Mission components) | nothing yet |

Rules for every component:

- **Styles on native controls first.** Buttons, toggles, text fields, and progress views are
  styles on the native control, so keyboard and VoiceOver behavior come with it. Where SwiftUI
  has no public style (a segmented or popup picker, a stepper, a slider), the component draws
  its own control and represents itself to accessibility as the native one (see departures).
- **States come from the style**, never from the view that uses it. Hover and pressed fills
  fade on the `hover` motion. The focus ring (`.nwFocusRing()`: `focusRing`, 2pt wide, 2pt
  outside the control, following its shape) shows for keyboard focus only, never on a click.
  Disabled is 40% opacity (`nwEnabledOpacity`), fading on `hover`, while the label changes at
  once.
- **Icon-only buttons** always carry an accessibility label.
- **Banners** sit inside the pane they concern. Never a modal alert for an agent event (one
  departure: `PeerDeleteDialog`).

### Controls (NWControls, NWControlsLight)

The light board changes only colors: every measure below holds in both appearances, and every
color is a role.

**Buttons** (`.buttonStyle(.nw(kind, size:))` on a native `Button`):

| Kind | Rest | Hover | Pressed | Use |
| --- | --- | --- | --- | --- |
| `primary` | `lantern` fill, `textOnLantern` semibold | the fill lifted (the board's `#f7b84f` dark, `#eca63a` light) | the fill sunk (`#d9922a`, `#cf8a1c`) | the view's one main action ("Launch") |
| `secondary` | `bgRaised`, 1px `lineStrong`, `textPrimary` medium | `bgSelected` | `bgSelected` | everything else ("Review") |
| `ghost` | no fill or line, `textSecondary` medium | `bgHover`, `textPrimary` | `bgSelected`, `textSecondary` | low emphasis, and Cancel (the board's sample; MXTemplateSave, DZExport, QueueEdit, and PaneArtifactEdit draw Cancel ghost too) |
| `danger` | `bgRaised`, 1px `lineStrong`, `failed` medium | `failedTint` | `bgSelected` | destructive, not yet confirmed (Stop, Revert) |
| `dangerFill` | `failed` fill, white (`textOnFailed`) semibold | unchanged | the fill sunk (`#d24f4b`, `#bf3a35`) | the confirmed destructive action (Delete) |

- **Sizes:** s 24 (8pt side padding, a 12pt label), m 28 (10pt, 12.5), l 32 (14pt, 13), from
  `NW.Height.controlS/M/L`, which never scale with Density. Radius 6 (`NW.Radius.s`). Pressed
  also nudges the button down 0.5pt. On iOS a button keeps its drawn height and grows its hit
  area to 44 (`nwTouchTarget`). `tint:` recolors a secondary or ghost label (the review's
  Commit in `done`).
- **Primary appears at most once per view**, and a destructive action is never the ⏎ default.
- **With an icon:** a `Label` ("Fork" with `arrow.branch`, "Re-run" with `arrow.clockwise`),
  the symbol one step smaller than the title and 6pt before it.
- **With a shortcut:** only on the view's main action. The chord is bound (⌘⏎:
  `.keyboardShortcut(.return, modifiers: .command)`) and drawn after the title in Geist Mono
  10.5 regular at 60% opacity, 6pt after it ("Land ⌘⏎", "New agent ⌘N"). **Not built yet:** no
  button draws its chord. The review's Request changes binds ⌘⏎ and names it in its tooltip,
  and the empty workspace puts `NWKeycap`s beside New agent (Known gaps). In a sheet the primary
  is the ⏎ default instead (Dialogs and sheets).

**Icon buttons** (`.buttonStyle(.nwIcon)`, `.nwIcon(bordered:isOn:size:tint:)`): always a
circle, 28pt (`controlM`; 44 on iOS), the SF Symbol at 14pt medium, monochrome.

- rest: no fill, `textSecondary`; hover: `bgHover`, `textPrimary`; pressed: `bgSelected`
- on: `lanternTint` with the symbol in `lanternText` (the side-pane button while the pane shows,
  however it opened)
- bordered: a 1px `lineStrong` ring (the board's `ellipsis`); focus: the ring as a circle
  (`.nwFocusRingCircle()`); disabled: 40%
- The board's set: `sidebar.left`, `square.and.pencil` (hover), a pane toggle (on),
  `ellipsis` (bordered), `xmark` (focus), `paperclip` (disabled).

**Links and rows** (app additions): `.nwLink` is inline text that acts ("Show all", "Reset"),
in `caption` and `running` unless given a color, 70% while pressed. `.nwRow(selected:)` and
`.nwRowBackground(selected:hovering:)` give a row `bgSelected` when selected and `bgHover` while
hovered (while pressed on iOS), radius 6.

**Selection:**

- **Segmented** (`NWSegmentedPicker`): scopes and view modes, 2–4 options ("Local | PR #24",
  "All | Commands | Agents"). A `bgSunken` track, radius 6, with a 1px `lineSubtle` line, 2pt
  padding, and 2pt between segments. Segments are 24pt (m; s is 20) with 10pt side padding (8
  at s) and 12pt labels: medium `textSecondary`, the selected one semibold `textPrimary` on a
  `bgSelected` pill with a 1px `lineStrong` line, radius 4. The pill slides to a new segment on
  the `content` motion (a cross-fade in place under Reduce Motion); disabled dims the segments
  and the pill.
- **Switch** (`.toggleStyle(.nwSwitch)`): settings that apply immediately ("Check for
  updates"). A 30×18 capsule, `lantern` on and `lineStrong` off, with a 14pt knob 2pt inside
  (`knobOn` white when on, `knobOff` when off, a small `knobShadow`) that slides on `content`.
  The label, when shown, sits 8pt before it. Settings rows use it through `SettingsSwitch`.
- **Checkbox** (`.toggleStyle(.nwCheckbox)`): lists and "done when" checks. 14pt, radius 4:
  off is `bgRaised` with a 1.5pt `lineStrong` border; on is `lantern` with a `textOnLantern`
  checkmark; mixed is `lantern` with a 7×2 `textOnLantern` dash. The label sits 8pt after the
  box, and only the box animates.
- **Radio group** (Mac: `Picker(…).pickerStyle(.radioGroup).tint(.nw.lantern)`): rare; prefer
  segmented or a popup. 14pt circles: off `bgRaised` with a 1.5pt `lineStrong` ring, on
  `lantern` with a 6pt `textOnLantern` center. **Not built yet:** nothing needs one.

**Inputs** (native `TextField`, `Picker`, `Stepper`, and `Slider` in Night Watch styles; every
one 28pt, radius 6, on `bgRaised` with a 1px `lineStrong` line):

- **Text field** (`.textFieldStyle(.nw)`, or `.nwField(focused:error:mono:)` where the caller
  binds focus): 8pt side padding, 12.5pt text in `textPrimary`, the placeholder in
  `textTertiary`, a `lantern` caret. `mono` (Geist Mono 12) for paths, file names, and ids
  ("shepherd.sock", "~/dev/shepherd"). States: default; focus (the ring 2pt outside); error (the
  line turns `failed`, and the message sits 6pt under the field in `caption` `failed`: "Socket
  path already in use"); disabled (40%). The line and the ring fade on their own layer, so
  focusing never animates the text. Settings fields are 220pt (`AppLayout.settingsFieldWidth`).
  **Not built yet:** no field sets the error state. A field whose own value is refused shows it
  this way; a problem with a whole setting stays its row's problem line (Settings).
- **Search field** (`NWSearchField`; `.textFieldStyle(.nwSearch)` for the glass alone): a 13pt
  `magnifyingglass` in `textTertiary` 6pt before the text; the placeholder names what it
  searches ("Search agents", "Search settings"). While empty, the shortcut's keycaps trail
  (⌘F); with text, a clear `xmark` in `textTertiary` takes their place ("Clear search" to
  VoiceOver). `large` is the command palette's 56pt search row, without the chrome.
- **Popup** (`NWPopupMenu`, a native `Menu` whose label is `NWPopupLabel`): longer option lists
  ("claude-opus", "Nightly"). 10pt leading and 8pt trailing padding, the value in 12pt (Geist
  Mono for a model id), and a `chevron.down` in `textTertiary` 8pt after it; 200pt wide (the
  board's; `AppLayout.settingsPopupWidth` in Settings), where `NWPopupMenu`'s default minimum is
  180 (Known gaps). Its items are real menu items.
- **Stepper** (`NWStepper`): small integer settings ("− 3M tok +"). 24pt − and + buttons in
  `textSecondary` either side of the value in Geist Mono 12, at least 52pt wide between 1px
  `lineSubtle` rules. A bound disables its button, and the digits roll (down after −).
- **Slider** (`NWValueSlider`): 200×16, a 3pt `lineStrong` track filled with `lantern` up to a
  14pt `knobOn` knob with a hairline `lineStrong` ring and `knobShadow`. The app adds the value
  in `mono` `textSecondary` 12pt after the track ("105%"); double-clicking it restores the
  neutral value, and ← → step it while it has keyboard focus.

**Small parts:**

- **Keycap** (`NWKeycap("⇧⌘B")`, one cap per key, 3pt apart): at least 18×18 with 4pt side
  padding, Geist Mono 10.5 in `textSecondary` on `bgRaised`, radius 4, a 1px `lineStrong` line
  with a heavier bottom edge (1.5px). Only for a real, wired chord read from
  `KeybindingsStore`; in menus, the palette, Settings, search fields, and empty states (see
  departures), never under the composer.
- **Count badge** (`NWCountBadge(3, tone: .attention)`): a capsule at least 18×16 with 5pt side
  padding, Geist Mono 10 semibold: `neutral` is `textSecondary` on `bgSelected` ("19"),
  `attention` `textOnLantern` on `lantern` (needs you, "3"), `failed` white on `failed` ("1").
  Its digits roll when the count changes. The sidebar's Automations footer uses neutral and
  attention.
- **Tag** (`NWTag("worker")`, `NWTag("claude-sonnet", mono: true)`): roles, models, kinds. 18pt,
  6pt side padding, radius 4, `textSecondary` on `bgSelected`, Geist 11 (Geist Mono 10.5 when
  `mono`).
- **Tooltip** (`.nwHelp("Review changes", shortcut: "⇧⌘B")`): the label and its shortcut. The
  board draws a 24pt tip after 600ms of hover (8pt side padding, the label at 12, the chord as
  keycaps 8pt after it, `.nwPopover` chrome at radius 6); the app renders the system tooltip
  with the chord as text (see departures).

### Status and feedback (NWStatus, NWStatusLight)

Everything that tells you what an agent is doing comes from `AgentState` (Theme model › One
status enum); a view never picks a status color itself. Only `attention` animates: its dot
glows from full to 35% opacity and back over 1.6s, static under Reduce Motion. The light board
changes only colors.

- **Pill** (`NWStatusPill(state)`), in headers and cards: 20pt, radius 4, a 6pt dot and the
  state's word 6pt apart, 6pt leading and 7pt trailing padding, the word in Geist 11.5 medium
  in the state's text color on its tint. Queued and idle have no tint: a 1px `lineStrong` line
  and `textSecondary` words. `label:` replaces the word where the state says more ("Stuck
  14m", "Running · 0:31"), and `symbol:` puts an 11pt SF Symbol in the dot's place (the
  queue's Steering). A new state cross-fades its word and tint; a label that ticks changes at
  once.
- **Dot** (`NWStatusDot(state)`), in rows: 6pt, filled in the state's color. Queued is a hollow 1px
  ring in `textTertiary`; idle is a filled `textTertiary` dot. A row that names the state puts its
  word 8pt after the dot in `textSecondary`. The sidebar's agent rows draw their own dot
  (`NWSidebarRow`), hollow while idle as well as queued, as the Navigation boards do (Sidebar; the
  Status language table's "hollow ring").
- **Glyph** (`NWStateGlyph`, 14pt), in tool rows, steps, and checklists: a spinner while
  running, otherwise the state's symbol in its color; queued and idle are a 1.5pt ring.
- **Spinner** (`ProgressView().progressViewStyle(.nwSpinner)`): a tool or turn in progress. A
  13pt three-quarter arc in `running`, about 1.9pt wide, one turn a second, linear; drawn by
  Core Animation (Motion) and static under Reduce Motion.
- **Bar** (`ProgressView(value:).progressViewStyle(.nwBar)`, `.nwBar(tint:)`): steps and budget.
  4pt, radius 2, on a `lineSubtle` track; the fill is `running` unless tinted with a state's
  color (the board shows running, lantern, and done fills). VoiceOver reads a percentage. The
  subagent card's context bar, the iOS run cards, and the iOS review's progress (tinted `done`)
  use it.
- **Step strip** (`NWStepStrip`): one 3pt segment per step, 3pt apart, radius 2, each at least
  14pt and sharing the row. Done, running, and needs-you steps take their colors; pending,
  queued, and idle steps are `lineStrong`. The board draws a mission's steps; the app draws
  subagent runs with it (the runs strip, the ledger, iOS run cards). VoiceOver reads "n of m
  steps done".
- **Sparkline** (`NWSparkline`): tool calls per minute over the last 10 minutes, 36×12, a
  1.2pt `running` line. The board puts it on running sidebar rows; the app shows elapsed time
  there instead (see departures).

**Banners** (`NWBanner(state, title:message:systemImage:)`) sit inline, inside the pane they
concern: 12pt vertical and 14pt side padding, radius 8, the state's tint (`bgRaised` for queued
and idle) with a 1px `lineSubtle` line. A 15pt icon in the state's color, 2pt down; 12pt after
it the title in Geist 13 semibold (`lanternText` for attention, else `textPrimary`), and 4pt
under that the message in 12.5 `textSecondary` at a 1.5 line height, both selectable. Actions
trail, top-aligned, 6pt apart, as small (24pt) buttons. Default icons:
`exclamationmark.triangle` for attention, failed, and stuck; `checkmark` for done;
`arrow.clockwise` for running; `info.circle` otherwise. The board's four:

- **A question** (attention): "<asker> asks: <question>" ("ios asks: keep MobileTokens as an
  alias?"), the asker's context as the message ("Migrating touches 31 call sites; an alias is
  4 lines but leaves two token systems."), then the answers the asker offered (the first
  primary, the rest secondary) and a ghost **Reply…**. In the app a thread's own question is
  the composer's question panel and a subagent's is on its card, each with the offered answers
  and Reply… (Composer, Subagents); no surface draws the banner form yet.
- **A repeated failure** (failed): "<what> failed <n> times" ("tests failed 3 times"), a
  diagnosis that says whether retrying helps ("3 snapshot tests fail at Dynamic Type XL.
  Retrying won't help."), and **Open replay** (secondary). **Not built yet:** nothing counts
  repeated failures or diagnoses them, and the board fixes no threshold. Today a failed turn
  shows `NWTurnError` with its repeat count and Retry, and a failed subagent card offers Open
  replay and Re-run.
- **A host reconnecting** (running, `point.topleft.down.to.point.bottomright.curvepath`):
  "<host> reconnecting", "Last seen 3h ago. Remote agents resume when it's back.", and **Retry
  now** (secondary), in the pane of a remote agent whose host went away. **Not built yet:** the
  app shows the host's state as a sidebar notice row ("Connecting…", "Unreachable" with Retry;
  Sidebar) and a "connecting to <host>…" placeholder in a remote agent's pane, and records no
  last-seen time.
- **A mission done** (done, `checkmark`): "Mission done", "Every “done when” check is verified.
  Draft PR #34 is ready.", and **Open review** (secondary). **Not built yet:** Missions are not
  built.

The app's banners today: the composer's "Lost connection to the agent process." (failed, with
Reconnect) and a failed attachment, dialogs' `DialogBanner`s, the commit sheet's, the review's load
error, and the Nightly notice (idle); on iOS, a screen's own failure (commit, review, terminal, New
thread, Automations).

**Transient and empty:**

- **Toast** (`.nwToast(item:)` with an `NWToast`): background agent events only ("**worker**
  finished · 5 files", Open). Bottom-trailing, 16pt in, one at a time (a new one replaces the
  current one), gone after 4s, rising from the bottom on the `sheet` motion. 36pt, 12pt leading
  and 8pt trailing padding, a 7pt state dot, then the subject in semibold and the message in
  12.5 `textPrimary` (two lines at most), 10pt apart, and an optional small ghost action that
  also dismisses it; `.nwPopover(radius: NW.Radius.m)` chrome. The app posts system
  notifications instead (see departures), so nothing shows one.
- **Empty state** (`NWEmptyState(Text(title), message:)`): one sentence, one or two actions.
  Centered, 28pt vertical padding, 10pt between parts: the 28pt lantern crook (`showsMark`),
  the title in Geist 17 semibold tracked −0.02em in `textPrimary`, the sentence in 12.5
  `textSecondary` at a 1.5 line height and at most 280pt wide, then the actions 6pt apart, 4pt
  further down. The board's: "No agents on watch", "Start one here, or pick a repo and let a
  mission plan the work.", **New agent** (primary, ⌘N) and **New mission** (secondary; not
  built, Missions). `framed` draws a dashed `lineStrong` border at radius 8 (the empty
  thread, which also hides the crook with `showsMark: false`). The app's copy is under Empty
  workspace and Thread.
- **Loading placeholder** (`.redacted(reason: .placeholder).nwShimmer()`): a remote host's list
  while it loads. The board draws four 28pt rows, each a 6pt dot and an 8pt-tall bar (radius 4)
  in `bgSelected`, 10pt apart, the bars at 70%, 52%, 64%, and 40% of the width. The block pulses
  between 55% and full opacity over 1.4s (`shimmer`), static under Reduce Motion and while
  hidden (`nwMotionPaused`). **Not built yet:** the modifier exists, but a loading host shows a
  "Connecting…" sidebar row and a "connecting to <host>…" pane placeholder instead.

## Keyboard

Keyboard is first-class, and the fast path never requires a dialog. Rebindable chords live in
`KeybindingsStore` (`Keybindings.swift`; defaults in `ShortcutAction.defaultChord`, overrides
in UserDefaults under `shepherd.keybindings`).

- **One source:** menus, palette keycaps, Settings ▸ Keyboard, copy that names a chord
  (Settings ▸ Agents and Terminal), and the Ghostty unbind list all read the store. Hardcoding a
  chord in a view is a bug, and a hint is never shown for a chord that isn't wired.
- **Rules for a rebound chord:** it must include ⌘, must not use a digit (⌘1–9, ⌃⇧1–9), must not
  be ⌘, or a plain ⌘ system or terminal chord (⌘Q, ⌘H, ⌘M, ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z), and must not be
  another action's chord.
- **Keycaps** (`NWKeycap`; Controls, Composer & menus): one cap per key, modifiers first in
  Apple's order (⌃⌥⇧⌘), each at least 18pt, mono 10.5 `textSecondary` on `bgRaised` with a
  `lineStrong` line (heavier along the bottom), radius 4, 3pt apart. Arrows and ↩ draw as
  glyphs. Settings ▸ Keyboard draws the same caps (the SettingsKeyboard board's 22pt caps are a
  full-window size; see Composer, questions, and menus).
- **Recording** (Settings ▸ Keyboard): a rebindable row's keycap is a button ("Click, then press
  the new shortcut"). While it records ("Press the new shortcut — ⎋ cancels"), one row at a
  time, the window's own shortcuts stand down and a key the app cannot bind beeps.
- **A rejected chord** says why under its row, in `failed`, led by the chord: "shortcuts must
  include ⌘ — plain keys belong to the terminal", "that chord is reserved (⌘1–9, ⌘, and
  system/terminal chords like ⌘Q ⌘C ⌘V)", or "already used by “<action>”".

| Default | Action |
| --- | --- |
| ⌘N · ⇧⌘T · ⇧⌘N | New agent in current checkout · with options… · new space… |
| ⌘R · ⇧⌘W | Rename agent · delete agent |
| ⌘K | Command palette |
| ⌘↓ · ⌘↑ | Next · previous agent |
| ⌘D · ⇧⌘D · ⌘W | Split vertically · horizontally · close pane |
| ⌥⌘→ · ⌥⌘← | Focus next · previous pane |
| ⌘J · ⇧⌘↩ | Show or hide the terminal panel · maximize or restore it |
| ⇧⌘S · ⇧⌘B | Show or hide the sidebar · the side pane |
| ⇧⌘M | Model picker |
| ⌘. | Stop the agent |
| ⌥⌘↑ · ⌥⌘↓ | Previous · next turn |
| ⌘I | Inspect subagent |
| ⌘↩ | Send the other way while pi works (steer ⇄ queue), and steer a focused queued message; composer only, no menu item |

Fixed chords:

- ⌘1–9 select agents in sidebar order (hold ⌘ to see the badges).
- ⌃⇧1–9 jump to machines (this Mac is always ⌃⇧1).
- ⌃1 shows the side pane's Changes tab (View › Changes); ⌃2–⌃4 wait for its other tabs. Settings ▸
  Keyboard lists it under Fixed, and Ghostty leaves it to the app (`appOwnedChords`).
- ⌘, opens Settings, and ⌘F searches it.
- ⏎ confirms and ⎋ cancels in sheets.
- In the composer, ↩ sends (while pi works, it queues or steers per Settings) and ⇧↩ inserts a
  newline. `/` at the start opens the command list, and Esc closes a menu, then the command list,
  then stops pi while it works.
- The queue's keys (`FixedChord`, listed with the send keys under Settings ▸ Keyboard ▸ While pi
  is working, `WhileWorkingKey`): ↑ in an empty composer edits the last queued message; ⌥↑ ⌥↓
  move the focused message and ⌫ deletes it.
- The composer's menus: ↑↓ move, ⏎ chooses, Esc closes, and ⇥ completes a slash command. The
  palette: ↑↓, ↩ runs, ⇥ cycles its scope, Esc closes.
- **Not built yet** (QuestionStates › Keyboard): in the question dock, 1–9 pick an option, ↩
  answers, and Esc hides or shows the question. Today a confirm answers to y or n while its panel
  has focus, and Esc does nothing while a question waits (it never stops pi then).

Review-pane keys are listed with the review.

## Accessibility and motion

- **Controls:** every control is a real `Button`, `Toggle`, or text field, or carries button
  traits and actions (sidebar rows are tap views so they can also be dragged). Icon-only buttons
  carry an `accessibilityLabel`, and hover-only affordances (the sidebar's `+`, a message's time
  and a turn's footer, a comment's Edit and Delete, a diff line's `+`) are always reachable as
  buttons or named actions for VoiceOver.
- **Rows read as one element:**
  - agent rows: "title, [worktree,] running / needs you / idle / done" (needs you also while one
    of its subagents asks); automation rows: "name, automation, state"
  - activity lines: "Explored 7 files, read 5, search 2, 0.9s, done", with Expanded / Collapsed
    and the hint "Shows the calls"; a folded stretch: "Worked for 6m 40s, explored 13 files, …,
    5 failed, done" and the hint "Shows the steps"; call rows: "edit, Sources/A.swift, +58 −41"
  - subagent cards: "name, role, state, detail", with the context bar as the value; ledger rows:
    "name, state, summary"; runs strip steps: "name, state — open"
  - diff lines: "Removed line 16: …", with Comment as a named action; file chips: "FleetView.swift,
    modified, 10 added, 54 removed, viewed"
- **Resizing:** the sidebar edge and the side pane's handle are adjustable elements that read
  their width.
- **Modality:** the palette is modal for VoiceOver while it is up.
- **Color:** status color is always paired with a word or a glyph shape, and contrast follows the
  rules above.
- **Focus:** keyboard focus shows the running focus ring (2pt, 2pt outside the control); a click
  never does. Every Night Watch control style and custom control turns off the system's effect
  (`.focusEffectDisabled()`) and draws `.nwFocusRing()`; a control left in its system style
  keeps the system's ring (NWSwift).
- **Reduce Motion:** nothing moves (see Motion). The glow, spinners, and shimmer are static;
  panes, sheets, overlays, and expanding or arriving rows cross-fade in place (120ms); rolling
  digits and symbol swaps cross-fade; pops, turn jumps, and scroll-to animations are dropped.
  Hover and content fades are unchanged.
- **Menu bar:** every pane and agent action exists in the menu bar, with its shortcut where it
  has one (File, View, Pane, Space, Agent, Machines, Appearance), so every action is reachable
  from the keyboard (NWSwift).
- **Text size:** the Mac's type doesn't follow Dynamic Type; it scales with Settings ▸
  Appearance ▸ Text size (85–130%). On iOS every style follows Dynamic Type (`relativeTo:`), and
  controls keep a 44pt hit area (`NW.Height.touch`) (NWFoundations, NWSwift).
- **Both appearances:** every component is checked in light and dark (its preview and the
  preview renders), and the contrast rules hold in both.

## Known gaps

When a change leaves code breaking this document, list the place here until it is fixed toward
it. A sentence elsewhere that states a board's value and adds what the app does today ("the app
uses 6pt today"), or a paragraph marked **Not built yet**, is a gap in its own right; the list
below collects the rest, and the places those sentences point here.

- **Foundations** (NWFoundations against ShepherdUI):
  - Section labels track 5% (`nwSectionLabel()`, `Tokens/Typography.swift`); the board's is 6%.
  - The small wordmark tracks −3% (`NWWordmark`, `Components/Status/Wordmark.swift`); the
    board's is −2% (−3% is the large one's).
  - Copy draws `square.on.square` (`NWCopyGlyph`, `Components/Thread/Messages.swift`: code blocks
    and the turn footer); the board's is `doc.on.doc`, which the iOS menus use.
- **Controls:** sheets draw Cancel as `secondary` (`DialogSheet.swift`, and each creation sheet),
  where the board's is `ghost`. `dangerFill` lifts on hover like `primary` (`Buttons.swift`); the
  board's stays put. Primary's and dangerFill's hover and pressed fills are 12% and 10% mixes toward
  white and black, near but not the board's hexes (dark hover `#f4b352` against `#f7b84f`). No
  button draws its chord after its title: the review's Request changes names ⌘⏎ only in its tooltip,
  and the empty workspace puts keycaps beside New agent (`WorkspaceView.swift`). `NWPopupMenu`
  defaults to a 180pt minimum width (`Pickers.swift`); the board's popups are 200.
- **Status and feedback:** an empty state's sentence is capped at 320pt (`Feedback.swift`), the
  board's at 280. A banner's icon is 13pt, the board's 15.
- **Agents and review:**
  - The parent's working row reads "Running shepherd_child_wait…" while its subagent cards stand
    (`nativeWorkingLabel`, `Sources/ShepherdRemote/NativeThreadStore.swift`); Subagents says no
    raw wait shows.
  - A review in a layout pane of its own (an older host's review leaf) leaves the scope off for
    the plain local diff ("4 files · +67 −58"); the Changes tab's bar leads with "working tree vs
    HEAD" as the Review board does (`ReviewScope.text`, `Sources/ShepherdApp/DiffReviewView.swift`).
  - The PR side of Local | PR reads "PR · <base ref>"; the Review board names the pull request
    ("PR #24") (`ReviewScope.prLabel`).
  - The Agents and Review components pad and space in 10pt where their boards do (the subagent
    card's and the brief's vertical padding, the action bar, a comment's sides, the review
    composer's field, the strip's and the ledger's gaps, a file header's leading inset,
    `AppLayout.steerTopInset`), which is not a step on the space scale ("Padding and gaps use only
    these steps").
- **Settings (the boards against `SettingsView.swift`, `SettingsComponents.swift`,
  `NWSettingsNavRow`, `NWCardRow`, `NWGroupCard`):** the nav's window-controls strip 38pt
  (`AppLayout.trafficLightHeight`) instead of 44; page titles in `display` (28) instead of 22/600;
  nav rows 28pt at `ui` with a semibold selection instead of 32pt at Geist 13 and 500, rows 1pt
  apart instead of 2, nav icons at 13.5 instead of 15, the Back row 28pt, and the Remote icon
  `desktopcomputer`; 32pt page gutters instead of 48; group cards on `bgRaised` instead of flat on
  `bgWindow`; row titles in `ui` (12.5) and descriptions and footnotes in `caption` (11.5) instead
  of 13.5/500, 12.5, and 12; 16pt between a row's text and its control instead of 24, 3pt between
  title and description instead of 2, 6pt under the page title instead of 4; descriptions without
  inline code or emphasized option names; the listener's problem without its `xmark` and showing the
  raw bind error; the remote host line all in mono; Keyboard's Reset all as a danger button in a
  Fixed row, "Confirm or cancel in sheets" with ⎋, and the Reset link 8pt from its keycaps; pi's
  Update now split in two; and copy that differs (Sync pi theme, Remote's Token, Advanced's Reset
  settings). Instructions and Experiments are not built.
- **Thread and terminal** (NWThread, TerminalSplit, TerminalPane against the app):
  - Consecutive activity lines, and a work group's lines on its rail, sit 6pt apart
    (`AppLayout.activitySpacing`); the boards' are 4pt.
  - A Run (bash) activity line draws `apple.terminal` (`Components/Thread/Activity.swift`); the
    board's symbol is `terminal`.
  - The terminal's cursor is `lantern` and its selection `running` at 18% dark and 28% light
    (`NightWatch.swift`); the boards draw a `textPrimary` block cursor and a 13% selection. The
    terminal font defaults to SF Mono 12.5 (`AppSettings`); the boards set Geist Mono 12 at 1.6.
  - Split terminals' dividers are `lineSubtle`, the TerminalPane board's `lineStrong`.
- **A pi dialog posts no notification** (Notifications and Live Activities › The catalog):
  a confirm, select, input or editor dialog shows in the thread, but only a tool named like
  `ask` or `question` sets `blocked`, so any other question reaches no one outside the window
  (`Extensions/shepherd-status.ts`, `AgentNotifications.agentStatusChanged`).
- **iOS** (the phone and iPad boards against `App/iOS` and ShepherdUI's Fleet parts):
  - List heads (`NWListHeader`) are `.caption` semibold in `textTertiary`; the boards' are 13/600
    in `textSecondary` on iPhone and 13/500 on iPad. Two-line rows are 56pt everywhere
    (`NWListMetrics.twoLineRowHeight`), where Home and Search draw 52, and row dots are 7pt
    (`NWListMetrics.dot`), the boards' 8 on iPhone.
  - Glyphs that need you (Needs you rows and cards, the iPad sidebar) are `lantern`
    (`AgentState.attention`, `NWAttentionCard`); the boards' are `lanternText`.
  - User bubbles are the Mac's (`NWUserBubble`: at most 600pt, 10×14); the iPhone boards cap them
    at 300 and the iPad's at 520 with 12×16. The iPad thread column is 760pt
    (`MobileLayout.threadMaxWidth`) against 780, with turns 24 and parts 12 against 26 and 14.
  - The iPad sidebar is the system split view's: 320pt (`MobileLayout.sidebarWidth`) in both
    orientations against 300 and 340, `NWListRow`s at 48pt against 44, New thread as a
    `plus.circle` symbol against a `plus` in a 20pt `bgSelected` circle, a bar titled "Shepherd"
    with Search alone, and portrait's overlay, dimming and toggle as the system draws them, not
    the board's rounded, shadowed panel.
  - In landscape the sidebar stays beside the thread while the review docks, the subagent
    inspector opens, or the review goes full screen (`PadShell`); the boards hide it.
  - The iPad thread header has no Subagents or Review changes button (iPadThread): the ••• menu,
    a card's Open and the changes card reach them, so a thread whose changes card is not in its
    loaded history has no way into its review.
  - The iPad Automations list is 340pt (`MobileLayout.automationsListWidth`); the board's is
    360.

Deliberate exceptions stay with their rules rather than here: the layout's 1pt dividers, the
checkbox's 1.5pt border, and the strokes of status glyphs (see Hairlines), and one-off type
sizes outside the ramp, set with `Font.nwSans`/`Font.nwMono` (the boards' in Typography, and
the empty thread's path).

## iOS

The iOS client (`App/iOS`, [docs/ios](docs/ios/README.md)) is built on Night Watch, with the
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
  terminal itself as in Terminal panes):
  - **iPad:** the Mac's panel under the thread and composer, across the thread's width
    (`.threadTerminal(_:)`), 340pt tall by default (`shepherd.ios.terminalHeight`), sliding up from
    the bottom edge (`.pane`). Its strip is 46pt with 32pt tabs and 34pt icon buttons hit at 44
    (`NWTerminalMetrics`), in the Mac's order and states. The divider is a 36×4pt `lineStrong`
    grabber centered on the strip's top edge (an 88×22pt hit area) in place of a pointer handle,
    snapping and clamping as on the Mac, adjustable with VoiceOver, and hidden while maximized. The
    strip and key row stop growing at xxxLarge.
  - **Toggle:** the thread's options menu: Show Terminal or Hide Terminal on iPad (iPhone:
    Terminal), absent while the host is offline. There is no header button; iPadTerminal's is a
    departure (Terminal panel › Show and hide).
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
  - **iPhone** (no board): the options menu's Terminal opens the panes full screen ("Terminal" as
    the inline title, the tab bar hidden) with the same tabs and +, without Split right, Maximize or
    Hide, and the same key row.
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
  - **States:** "No terminals in this thread yet." with New Terminal (secondary); "<host> is
    offline."; "Update Shepherd on <host> to open terminals here." for a host without
    `pane.control.v1`, which shows its terminals but offers no +, split or close. A failed pane
    request shows a `failed` `NWBanner` under the strip with Dismiss ("Couldn't open a terminal: …"
    or "Couldn't close the terminal: …", "Update Shepherd on the host to open a terminal here." (or
    "…to close the terminal here."), "An agent's own pane can't be closed.", "A layout always keeps
    its last pane."). In a split tab the focused pane is outlined 1pt in `focusDivider`.
  - As on the Mac, the iPad panel closes with its last terminal while the host is connected, and tab
    dots follow the host's news, so a tab leaving the screen (its viewer detaching, the PTY taking
    the Mac's size again) leaves no dot.
- **Commit from review** (MobileCommit, iPadCommit boards): the same parts as the Mac's sheet. On
  iPhone the changes' bar reads Request changes and **Commit…** (primary), which presents a sheet
  (Cancel, "Commit n files"; Message, Files "n of m", the options card; a full-width Commit &
  push, with Ask agent to commit as a link under it and in the review's ••• menu). File rows are
  44pt and show the name alone. On iPad, Commit… (the docked review composer's, or the full-screen
  review's bar) opens a 400pt popover; its anatomy is in iOS: iPad › Commit. A host without
  `review.commit.v1` keeps the single Commit that asks the agent.

### iPhone: shell and shared anatomy

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
  rules. Home's cards alone are `bgWindow` on its `bgBase` screen. A card that needs you (a
  subagent's question) takes a `lanternText` line; a running one (Automations' Running now) a
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
  12.5, 10pt sides); a subagent's answers and a host's Retry are 32pt (`.l`: 13, 14pt sides; the
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
  `NWRunGroupCard`, `NWRunHistoryList`, `NWRunGoal`, `NWRunQuestion`, `NWSteerField` (Agents);
  `NWReviewFileRow`, `NWTouchDiffLine`, `NWLineCommentBar`, `NWInlineComment`, `.nwReviewBar`
  (Review); `NWTouchSearchField`, `NWSearchResultRow` (Navigation); `NWChoiceRow`, `NWGroupCard`,
  `NWCardRow` (Containers); `NWAutomationRow`, `NWAutomationSwitch` (Automations). Their measures
  are `NWListMetrics`, `NWTouchComposerMetrics`, `NWTouchQueueMetrics`, `NWTouchQuestionMetrics`,
  `NWRunTouchMetrics`, `NWSelectorChipMetrics`, `NWChoiceRowMetrics` and `NWTouchDiffMetrics`; a
  screen's own measures are `MobileLayout` extensions in its folder.

### iPhone: Home (MobileAgents)

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
  for a thread, or the origin's 15pt glyph in `lanternText` (a bolt for an automation run, a branch
  for a subagent); the thread's name, the question in `lanternText` mono 11 under it, and (the
  app's, with several hosts) its host badge. The app draws the glyph in `lantern` (Known gaps). At
  most two rows (`HomeLimits.needsYou`), then a 44pt link row: "See all N" when more wait, else
  "Answer in Needs you". A row opens where the question is answered (the thread, or the asking
  subagent's run). The board shortens a plan's question to "approve plan" ("Dock review pane");
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

### iPhone: Thread (MobileThread, MobileApproval)

`Thread/ThreadScreen.swift`, `ThreadTurns.swift`, `Composer/ThreadComposer.swift`. The thread
follows the Mac's rules (Thread) with the phone's measures below.

- **Header:** the inline title with the agent's name over its status line: the status word
  ("Idle", "Running", "Needs you" with a glowing dot while pi asks), then where the agent works:
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
  chevron), 8pt between parts, 4pt between lines; it expands its calls. The running line is 26pt: a
  13pt `running` spinner, the label in `textPrimary` ("Pushing"), the command in mono 11
  `textTertiary`, the elapsed seconds in mono 11 `running`, then the call's last three output lines
  in mono 11 at 1.6 line height, indented 21pt, the newest in `textSecondary` and the rest
  `textTertiary`. No "Working…" row sits under a live line. Two or more finished lines fold into one
  work-group line (see Where Shepherd departs from the boards).
- **Changes card** (`NWChangesCard`): 1px `lineSubtle`, 8pt corners, on `bgWindow`. Its 40pt head on
  `bgSunken`: a pencil glyph, "2 files changed" (12.5/600), the stat (`done` added, `failed`
  removed, mono 11), and Review (a 24pt ghost button, 12/500 `textSecondary`) trailing, which opens
  every change of the turn. Then a 36pt row per file: the status letter (mono 11/700; M `lantern`, A
  `done`), the path in mono 12 with its directory in `textTertiary`, its stat; a row opens the
  review at that file.
- **Turn footer** (`NWTurnFooter`): at rest, mono 11 `textTertiary`: "2:44 PM · 3m 12s"; the app
  adds the tool-call count, Copy and Retry, and "n subagents" when the turn spawned runs.
- **Composer:** a 1px `lineSubtle` rule, `bgWindow`, 10pt above, 12pt sides, 30pt below. A 44pt
  paperclip (Attach, `textSecondary`; shown only when the host takes images) beside the capsule
  (`NWCapsuleComposer`): at least 44pt, fully rounded, `bgRaised`, 1px `lineStrong` (`textTertiary`
  while focused), 16pt leading and 6pt trailing padding, the field at 16 (`.body`) growing to a few
  lines, and Send inside it: a 32pt `lantern` circle with a `textOnLantern` up arrow, at 35% while
  there is nothing to send. The placeholder is "Follow up…", and "Queue a follow-up…" while pi
  works (MobileApproval), which the app follows, since Send queues while pi works. The later
  queue boards (MobileSteer, MobileQueueMenu) keep "Follow up…" while pi works and draw the
  capsule the composer's full width with no paperclip, and 34pt under it; settle which rules
  before changing either. Holding Send while pi works offers Queue and Steer now. The app adds,
  while the field is in use, a row of "/ commands", model and thinking chips above it (ghost,
  28pt); no phone board draws it.
- **Following:** as in the iOS list above: only a finger's drag detaches; "↓ Jump to latest" sits
  8pt above the composer.
- **Banners** at the top of the thread, 12 `textTertiary`: "<host> is offline · showing the last
  known thread", "This agent is no longer on <host>.", "Update Shepherd on <host> to open threads
  here.", "Some output is clipped · the full thread is on <host>".

### iPhone: New thread and Where it runs (MobileNewThread, MobileWorkspace)

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
    trailing. The app shows the failure's headline and no last-seen time.
  - **Not built yet:** a daemon host ("build-01 · Linux daemon · 2 missions running"). Hosts are
    Macs running Shepherd until the Mac has daemon hosts.
  - Last, a card with "New worktree" (15/500) over "Keeps main clean. Merge it from Review." (12.5
    `textTertiary`, naming the base's branch) and its switch, on by default. With it on the app adds
    Branch and Base fields (the base as the host resolved it) and Fetch origin first.
- **States:** an older host says what it lacks ("Update Shepherd on <host> to start threads in a new
  worktree."); a failed start shows a `failed` `NWBanner` "Couldn't start the thread" with Try again
  or Resolve; images ride on the first send.

### iPhone: Up next and questions

MobileSteer, MobileQueue, MobileQueueMenu, MobileQuestion; `Composer/QueueSection.swift`,
`Composer/QuestionPanel.swift`. The queue's rules are the Mac's (Up next); only its touch form
differs.

- **Header while it runs:** the status line carries the elapsed time and what the thread is working
  in or on: "Running · 5m · payments" (its space), "Running · 37m · 3 subagents" (its live runs).
  The app shows the elapsed time alone.
- **Up next** (`NWTouchQueueCard`) sits above the capsule, 8pt apart: `bgRaised`, a 1px `lineStrong`
  line, 14pt corners. Its 38pt head (14pt leading, 4pt trailing): the queue glyph (13pt
  `textTertiary`), "Up next" (13/600 `textSecondary`), the count (mono 11.5 `textTertiary`), and •••
  (a 34pt circle: Steer all now or Send all now, "When the turn ends, send" with the delivery modes,
  Clear the queue). The rows scroll inside past three and a half (`MobileLayout.queueRowsMaxHeight`,
  at most `queueShare` of the composer's room).
- **Steering row**, first, until pi takes it: 58pt on `runningTint`, a 15pt `running` spinner, the
  message at 15 on one line, "↳ Steering" (12/500 `running`, an 11pt glyph) under it, and Back to
  the queue (a 34pt button, a 16pt `textSecondary` return arrow) trailing, hit at 44pt.
- **Queued rows:** 48pt on `bgRaised` with a `lineSubtle` rule above: the number in a 22pt
  `lineStrong` ring (mono 11.5 `textSecondary`), then the message at 15 on one line. The app lets it
  wrap to two, and shows an image count and "Being edited" while an editor elsewhere holds it.
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
  parts. A 36×5 `lineStrong` grabber, then a 26pt head: a 13pt question glyph and "pi is asking"
  (13/600 `lanternText`; "1 / N" in mono when several wait). The question at 18/600, 1.3 line
  height; the asker's message, if any, as code on `bgSunken`. The options: 6pt apart, each a card on
  `bgWindow` with a 1px `lineSubtle` line and 8pt corners, 11×12 padding: a 24pt number in a
  5pt-cornered `lineStrong` square (mono 11 `textSecondary`), then "Recommended" (a 20pt
  `lanternTint` chip, 11/600 `lanternText`) when the asker marked it, the title (15/600, 1.35) and
  its detail (14/1.45 `textSecondary`). Tapping one selects it (the number fills); Answer, a
  full-width 48pt `lantern` button with 12pt corners at 16/600, stays at 40% until one is chosen.
  The app adds Dismiss before Answer, Yes and No for a confirm, and a field with Send answer for
  input and editor questions.
- **While pi asks** the header shows "Needs you" with a glowing dot and no Stop or •••. The app
  keeps both.
- **Not built yet:** a last option "Something else…" (a 46pt card, its number, the text in
  `textTertiary`) that opens a field for a free answer to a select. pi's select takes only an
  offered option, so it waits for the picker block's `allowOther`.

### iPhone: Subagents (MobileSteer, MobileSubagents, MobileSubagent)

`Subagents/`. The runs are the Mac's (Subagents); the phone shows them as cards, a list and a screen
per run.

- **In the thread** (MobileSteer; `NWRunGroupCard`): several runs are one card where the turn
  spawned them: `bgRaised`, 1px `lineSubtle`, 12pt corners, 8×14 padding. Its head (a rule under
  it): a 14pt branch glyph, "3 subagents" (14/600), then "Open" (13 `running`) and a chevron, which
  opens the runs list. A 36pt row per run: the state glyph in a 14pt column (a `running` spinner, a
  glowing 7pt `lantern` dot, a `done` check), the name in mono 600 in a 72pt column, the detail at
  14 `textSecondary` ("step 1 of 3 · restyling ThreadView", "14 of 14 pass"; "needs you: rename or
  replace?" in `lanternText`), and its time in mono 11 `textTertiary`. A row opens its run. While
  the turn waits, "Waiting on worker and reviewer" (14, a 13pt `running` spinner) follows the card.
  One run is an `NWRunCard` instead; a group becomes the finished ledger once every run ends.
- **The runs list** (MobileSubagents; `SubagentListScreen`): "Subagents" over "1 running · 1 needs
  you" in the state's color, on `bgBase` with 14pt padding. "This turn" with its count heads the
  live runs as cards (`NWRunCard`; 12×14 padding, 8pt inside):
  - Head: the branch glyph in the state's color, the name (mono 15/600), its tags ("background ·
    fable-5-1", 12 `textTertiary`), and a 20pt pill trailing (the state's tint and a 6pt dot: "37m"
    running, "Needs you · 2m" glowing, "4m 02s" done).
  - Running: "step 1 of 3" (mono 12), a 4pt progress bar (`lineSubtle` track, `running` fill, 2pt
    corners), the tokens ("922k", mono), then the current call in mono 12 `textSecondary` on one
    line.
  - Needs you (a `lanternText` line): the question at 14/1.45 with inline code (mono 12 on
    `bgSunken`, a `lineSubtle` line, 4pt corners), then its answers as 32pt buttons (the first
    primary, the rest secondary) and Reply… (ghost), which opens a field for a free answer.
    Answering sends it at once.
  - Done: its result at 14 and its diff stat.
  - "Earlier in this thread" with "kept after they finish" heads the finished runs as one card of
    56pt rows: a `done` check, the name (mono 15/500) over "summary · 1h ago" (12.5 `textTertiary`),
    the stat, a chevron.
- **One run** (MobileSubagent; `SubagentRunScreen`): the name over "Running · 37m", and ••• (Pause
  or Continue, Stop, Re-run, Copy Transcript) trailing. On `bgWindow`, 16pt padding, 12pt apart:
  - The goal (`NWRunGoal`): `bgSunken`, 1px `lineSubtle`, 12pt corners, 12×14 padding: "GOAL · FROM
    THE PARENT" (`.nwSectionLabel()`), then the goal at 14/1.45. The app adds "step 1 of 3 · 34%".
  - Its transcript: prose at 15/1.5, activity lines 32pt tall at 14; the running call live with its
    verb ("Building"), command, elapsed seconds in `running`, and its last three output lines, as in
    the thread; "Thinking…" in italic 14 `textTertiary` with a bulb glyph while it thinks. The app
    shows a live call as the run's working row ("Running bash swift build…") without the output
    tail: the child's session holds no streamed output.
  - Its question, while it waits on you, on `lanternTint` with its answers.
  - The steer field (`NWSteerField`) at the bottom: a 44pt capsule, "Steer worker…", Send inside it,
    and under it "to: worker · not the parent · lands before its next turn" (mono 11 `textTertiary`,
    8pt sides). Only while the run takes a steer; a finished run shows Re-run and Copy transcript
    instead.

### iPhone: Review (MobileChanges, MobileDiff, MobileCommit)

`Review/ChangesScreen.swift`, `DiffScreen.swift`, `Commit/CommitScreen.swift`. The review is the
Mac's (Side pane › Changes); Commit… follows the Commit from review rule above.

- **Changes** (MobileChanges), pushed from the changes card: "Changes" over "working tree vs HEAD"
  (or the PR), ••• trailing (Working tree vs HEAD or Pull request, Refresh, Ask agent to commit,
  Finalize worktree…). On `bgBase`, 14pt padding, 10pt apart:
  - The summary card (14pt padding): "3 files" (17/600) and the stat (mono 11), then the branch
    trailing (a branch glyph and "main", mono 12 `textSecondary`); under it a 4pt bar (`done` fill
    on `lineSubtle`) and "1 of 3 viewed" (12.5 `textTertiary`). The app shows the branch only for a
    worktree agent, and adds Finalize worktree ("commit · push · PR") to the card for one.
  - "Files" with "tap to read the diff", then one card of 58pt rows (`NWReviewFileRow`): the viewed
    mark (a `done` check, or a 14pt ring in `lineStrong`), the status letter (mono 12: M `lantern`,
    A `done`), the name (mono 14/600) over its directory (mono 11 `textTertiary`), the comment count
    (a bubble glyph and "1", 12 `running`), the stat, a chevron. A row pushes its diff.
  - "Your comments" with the count, then a card per comment: an 18pt `bgSelected` circle with the
    author's initial (10/600), "FleetView.swift · line 33" (mono 12 `textTertiary`), the time
    trailing ("just now"), and the text at 14/1.45. The app labels the author "You" and adds Edit,
    Delete and an overall comment field.
  - The bottom bar: Request changes (secondary) and Commit… (primary), 48pt each, sharing the width.
- **Diff** (MobileDiff): the file name over "App/iOS · 2 of 3 · +9 −7" (mono 11.5), and Next file (a
  34pt button, a down chevron) trailing; the app adds Mark viewed. On `bgWindow`:
  - The hunk head in mono 11 `textTertiary` on `runningTint`, 6×12 padding.
  - Lines (`NWTouchDiffLine`) at least 22pt (`NW.Height.rowCompact`), wrapped, mono 12 at 1.55: a
    32pt number column (10.5 `textTertiary`, right-aligned, 6pt after), a 14pt sign column (`failed`
    −, `done` +), the code with syntax colors; removed lines on `failedTint`, added on `doneTint`.
  - Long removed runs fold into a 26pt row on `bgSunken` indented 46pt: a chevron and "13 more
    removed lines" (mono 11 `textTertiary`); a tap shows them.
  - A comment sits under its line: 6pt above and below, 12pt trailing, indented 46pt; `bgRaised`,
    1px `lineStrong`, 10pt corners, 10×12 padding: the initial, "You · just now", and the text at
    14.
  - A tap selects a line: `runningTint` with a 3pt `running` bar at its leading edge. The bottom bar
    then shows "line 16 selected · Suggest a change" (12 `textTertiary`; the line in mono `running`)
    over a 44pt capsule "Comment on line 16…" with Send. The app adds Done, which clears the
    selection.
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

### iPhone: Needs you (MobileInbox)

`Home/NeedsYouScreen.swift`, pushed from Home's Needs you. Every question and blocked thread on the
connected hosts, newest first.

- **Header:** the large title "Needs you", then "4 things are waiting on you" ("1 thing is waiting
  on you"). On `bgWindow`, 14pt sides, cards 10pt apart. Pull to refresh.
- **A card** (`NWAttentionCard`): `bgRaised`, 1px `lineSubtle`, 12pt corners, 10×14 padding, 6pt
  apart inside:
  - The origin line: a 14pt `lanternText` glyph (a branch for a subagent, a bolt for an
    automation run, a folded map for a mission; a glowing 8pt `lantern` dot for a thread) and
    "Subagent · Restyle native UI", "Thread", "Automation · Triage new Sentry issues" (12
    `textTertiary`), with the time since trailing ("now", "2m", "14m", "1h"). The app adds the
    host's badge when there are several hosts, and draws the glyph in `lantern` (`NWAttentionCard`;
    Known gaps).
  - The title (15/600): the thread's name, or who asks ("reviewer asks"). An automation's card is
    titled by its question ("Is this a regression from #231?") over the asker's context ("NilPointer
    in PlaceOrder started 40 minutes after #231 merged.").
  - The question (13.5/1.4 `textSecondary`), and the asker's message under it.
  - The answers that fit in place, 8pt apart and wrapping, at 28pt: a select with at most three
    short options shows them (the first primary); a confirm shows Yes (primary) and No (a pi confirm
    carries no labels of its own). Then Open (ghost; secondary when it is the only action), which
    goes where the question can be answered. Input and editor questions show Open alone.
- **A subagent's question** answers in place with its options ("Replace everywhere", "Rename new
  ones"), as its card in the thread does. The app shows Open alone for it: the list's digest does
  not carry the child's options yet.
- **Not built yet:** a mission's item ("Mission", "Checkout funnel events", "orders is stuck after 3
  tries. The planner suggests a retry with a hint.", Retry with hint and Open), and a thread's plan
  approval ("Plan ready: …", Approve plan and Read plan). They wait for Missions and plan approval
  on the Mac.
- **Empty:** "Nothing needs you" ("Questions and blocked threads from every host show here.").

### iPhone: Search (MobileSearch)

`Search/MobileSearchScreen.swift`, pushed from Home's Search. No navigation bar and no tab bar; the
keyboard is up while the query is empty.

- **Field row:** 58pt from the top, 14pt sides, 10pt gap: the field (`NWTouchSearchField`: 40pt,
  10pt corners, `bgSelected`, a 15pt magnifier and a 12pt clear ×, both `textTertiary`, the query at
  16 with a `lantern` caret; placeholder "Search threads"), then Cancel (16 `running`).
- **Results:** sections 8pt apart, each a head and a card of 52pt rows (a 16pt glyph in a 20pt
  column, the title at 15/500 over a 12.5 `textTertiary` detail, a chevron). The match is
  `lanternText` at 600 in titles and snippets.
  - "In conversations": a speech-bubble glyph, the thread's name and who said it ("Checkout funnel
    events · validator"), and the snippet in quotes with ellipses ("…funnel rows can't be joined…").
    The app shows the host's badge in place of the speaker, and adds a "Threads" section of title
    matches first.
  - A tap pushes the thread over search; Back returns to the results.
- **Not built yet:** the Missions section (a folded-map glyph in `lanternText` for one that needs
  you; "needs you · orders is stuck"), the Designs section (a diamond; "acme-web · 4 boards"), and
  Actions: "New mission" ("“funnel” as the goal") and "New design" ("“funnel” as the brief"), each
  with a plus or diamond glyph. They wait for Missions and the Design tool.
- **States:** before a query, "Search every host" ("Find a thread by its title, or by a line from
  its conversation (three letters or more)."); nothing found, "No results" ("Nothing on your hosts
  matches “q”."); while hosts answer, "Searching conversations · 3 of 12" with a spinner, and a line
  for each host left out.

### iPhone: More (MobileMore)

`Home/MoreScreen.swift`, pushed from Home's More.

- **Hosts:** the head "Hosts" with "Add host" (13 `running`) trailing, then a card per host
  (`NWHostCard`; 12×14 padding, 6pt apart, 10pt between cards):
  - A 15pt display glyph in `textSecondary`, the name (mono 15/600), what it is ("Shepherd app · Pi
    0.87", 12 `textTertiary`), and the connection trailing (a 7pt dot and "Connected" in `done`,
    "Unreachable" in `failed`, 12). The app shows the address and port where the board has what it
    is, and says "Offline".
  - What runs there: "2 threads running · shepherd, dashboard-web" (12.5 `textSecondary`).
  - Unreachable: "Last seen today 07:12 · 1 automation paused" (12.5), then Retry (32pt secondary
    with a retry glyph) and Wake on LAN (32pt ghost). The app shows why it cannot connect in
    `failed`, and Retry at 24pt (`.s`).
  - A tap opens the host's form (edit, forget). Pull to refresh retries every host. Under the cards:
    "Hosts connect over your LAN or VPN. The connection has no TLS."
- **Not built yet:** a daemon host's card ("daemon · Linux", "2 missions · 5 stations running · load
  6 of 16 cores") until the Mac has daemon hosts; Wake on LAN on an unreachable host, which sends
  the host's magic packet and then retries; a host's kind and pi version and its last-seen time,
  which need the host to report them.
- **Not built yet:** under the hosts, a card of 52pt rows: Design systems ("2 · acme-web, Night
  Watch", a palette glyph), Pi extensions ("6 installed", a puzzle glyph), and Archive ("41
  threads", a box glyph), each pushing its list. Design systems and Archive wait for the Mac; Pi
  extensions lists the bundled and installed pi extensions each host loads.

### iPhone: Settings (MobileSettings)

`Settings/SettingsScreen.swift`, the Settings tab's root: the large title "Settings" on `bgBase`,
14pt sides, cards of 48pt rows, each a 17pt `textSecondary` glyph, the name, its value trailing (14
`textTertiary`) and a chevron.

- **First card** (no head): Appearance (a palette glyph; "System", "Light" or "Dark"), then
  Notifications (a bell; "Needs you").
- **Agents:** Defaults (a sparkle; the default model, "claude-opus"), Instructions (a page;
  "AGENTS.md, APPEND"), Pi extensions (a puzzle; "6").
- **Machines:** Hosts (a display; "1 offline", or the count), then Worktrees (a branch).
- **A card of its own:** Experiments (a flask; "1 on").
- **About:** a 24pt Shepherd icon (the crook in `lantern` on `textOnLantern`'s dark, 6pt corners),
  "Shepherd 0.1.0", and "pi 0.87.1" (mono 13 `textTertiary`) trailing. The app shows "build N"
  there, since the host reports no pi version, and draws the crook at 15pt with no tile.
- **In the app** the screen is `bgWindow` with 16pt sides, a value is 12 (`.caption`), and Hosts
  shows "1 offline" as a problem (mono `failed`) or the host count ("None" with no hosts).
- **Built today:** Appearance (System, Light, Dark for this device; "System follows this device's
  appearance. Shepherd on a Mac keeps its own."), Machines ▸ Hosts (the hosts as cards, and the host
  form), and About.
- **Not built yet:** Notifications (which events notify: Needs you by default; it waits for push
  notifications), Agents ▸ Defaults (the model and thinking a new thread starts with), Pi extensions
  (the extensions each host loads), Machines ▸ Worktrees (the Mac's worktree settings for new
  threads), Instructions and Experiments (below).

### iPhone: Instructions (MobileInstructions, MobileInstructionsEdit)

**Not built yet.** Settings ▸ Instructions edits the global instructions pi reads at the start of
every session. It waits for the Mac's Instructions page (SettingsInstructions).

- **The page** (MobileInstructions): "‹ Settings", the large title "Instructions", on `bgBase` with
  14pt sides and 10pt apart. "Pi reads these at the start of every session, on every host."
  (13.5/1.5 `textSecondary`, 4pt sides). A card with one 60pt row: "Same on every host" (15) over
  "Save once, written to each host's ~/.pi/agent/" (12.5 `textTertiary`), and its switch, on.
- **Files:** a card of 64pt rows: a 17pt page glyph, the file (mono 15/600) over what it is and its
  size ("How you work · ~640 tokens", "Rules that win · ~90 tokens"; 12.5 `textTertiary`), a
  chevron: AGENTS.md, APPEND_SYSTEM.md. A row opens the editor.
- **Hosts:** a card of 52pt rows: a display glyph, the host (mono 15), and its sync state trailing
  (13): "synced" and "synced 2m ago" in `done`, "offline · will sync" in `textTertiary`.
- **The editor** (MobileInstructionsEdit): an inline header with "‹ Back" (90pt slot), the file
  (mono 15/600) over "every host · edited" (11.5 `textTertiary`), and Save (16/600 `running`)
  trailing. The file in mono 13 on 21pt lines with a 28pt number column (10.5 `textTertiary`,
  right-aligned, 8pt after); Markdown marks in `textTertiary` (`#`) or `lanternText` (`-`), headings
  600 `textPrimary`, list text `textSecondary`, code spans in the syntax string color; the line
  being edited on `lanternTint`; a `lantern` caret. Over the keyboard, a key row on `bgSunken` with
  a `lineSubtle` rule: 32pt keys at least 38pt wide on `bgRaised`, 6pt corners, mono 14: `#`, `-`,
  `` ` ``, `**`, Tab.
- **Where it writes:** the board saves into each host's `~/.pi/agent/`, which Shepherd must never
  write (AGENTS.md › Gotchas: never install anything into `~/.pi/agent/`). Decide where these files
  live on the host before building it.

### iPhone: Experiments (MobileExperiments)

**Not built yet.** Settings ▸ Experiments: features still being tried, each off until turned on. It
waits for the Mac's Experiments page (SettingsExperiments).

- **The page:** "‹ Settings", the large title "Experiments", on `bgBase`, 14pt sides, 10pt apart.
  "Still being tried out. Each is off until you turn it on." (13.5/1.5 `textSecondary`).
- **An experiment:** a card with one row (14pt padding, 12pt apart, top-aligned): a 30pt square on
  `lanternTint` with 8pt corners holding a 16pt `lanternText` flask, then "Suggested instructions"
  (15/600) over "Agents draft a line for your root AGENTS.md when they learn something the hard way.
  Nothing is written until you add it." (12.5/1.45 `textTertiary`), and its switch.
- **Learn from:** a card of 46pt rows, Missions, Threads, Automations (15), each with a 15pt
  `running` checkmark when chosen.
- **Waiting for you:** the head with "Add all" (13 `running`), then a card of rows (12×14,
  top-aligned): the source's glyph, 16pt (a folded map in `lanternText` for a mission; a speech
  bubble for a thread and a bolt for an automation in `textSecondary`), the suggested line in mono
  13/1.45 with a `done` "+ " before it and code spans in the syntax string color, where it came from
  under it ("Checkout funnel events · AGENTS.md", "… · build-01"; 12 `textTertiary`), and a chevron
  that opens it to add or dismiss. Nothing is written until you add it. Adding writes the root
  AGENTS.md, so it waits on the same decision as Instructions' Where it writes.

### iOS: iPad

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

#### Shell and sidebar (iPadThread, iPadSidebar, iPadPortrait, iPadPortraitLaunch)

`PadShell` (`App/iOS/App`) is one `NavigationSplitView` with `PadSidebar` beside the detail: the
selected thread, or the Overview when none is. Other screens push over the detail.

- **Landscape:** the sidebar sits beside the detail, 300pt wide (iPadThread), on `bgBase` with a
  1px `lineSubtle` trailing edge.
- **Portrait** (the window taller than wide, keyboard ignored): the thread takes the width, and
  the sidebar slides over it at 340pt (iPadSidebar), its trailing corners rounded 14, with the
  floating shadow (`.nwFloatShadow`) and the thread dimmed behind it. Tapping the dimmed thread
  ("Dismiss sidebar") or choosing a row hides it. At a launch in portrait with nothing chosen,
  the sidebar is out over the dimmed Overview, since the Overview alone offers no way to a thread
  (iPadPortraitLaunch, drawn by the user's decision of 25 Sep 2026); a tap on the dim only closes
  it, as iPadOS overlays do, and Show sidebar brings it back. The thread's header gains Show sidebar
  (`sidebar.left`, a 44pt circle) at its leading end. Rotating keeps the selection, the pushed
  screens and the composer's focus.
- **Top bar** (56pt, 14pt leading and 8pt trailing inset): Search (⌘K), which opens the palette,
  and Hide sidebar, trailing, as 36pt circles with 16pt `textSecondary` glyphs. The board has no
  title. The app's bar is the system's: titled "Shepherd", with Search as its one item and the
  split view's own sidebar toggle (Known gaps).
- **Destinations** (8pt inset, 1pt apart): 44pt rows at radius 8, 10pt inset, a 20pt leading
  column 12pt from a 15pt label (`.ui`). New thread leads with `plus` in a 20pt `bgSelected`
  circle; the rest with 18pt `textSecondary` glyphs, and More with a `textTertiary` chevron,
  since it expands in place (iPadHosts). Built: New thread (disabled with no hosts),
  Automations (its count trailing), More (the offline summary, "1 host offline", as an alert
  trailing). A pushed destination's row is selected.
- **Not built yet: Missions and Designs** sit between New thread and Automations (a map glyph and
  a diamond glyph). They wait for the Mac's Missions and Designs.
- **Not built yet: More expands in place** (iPadHosts): its sub-rows indent to 24pt, Hosts (with
  "1 offline" in mono 10 `failed`), Design systems, Pi extensions and Archive, each a destination
  of its own. Today More opens one page of host cards (see Hosts and More).
- **Section heads** (14pt above, 10pt inset, 4pt under): 13/500. "Needs you" in `lanternText`
  with its count in mono 10.5 `lanternText`, a 44pt target that opens Needs you; "Recents" in
  `textTertiary`.
- **Rows** (44pt, radius 8, 10pt inset, 12pt gap): a 14pt status column, the title at 15 in
  one line, and a trailing detail in mono 10. The selected thread takes `bgSelected` and a
  semibold title. Status: in Needs you, a glowing 6pt `lantern` dot for a thread, or the
  origin's 16pt glyph in `lanternText` for anything else (a mission's map, an automation's
  bolt; the app leads a subagent's item with its branch glyph); in Recents, a 6pt `running` dot
  while it runs, a hollow 6pt `textTertiary` dot at rest, a 6pt `failed` dot for a failed one,
  and a 16pt `textTertiary` glyph for a design, a mission or an automation run.
- **Needs you rows** end in the reason in mono 10 `lanternText`. The boards summarize the
  question ("retention?", "approve plan", "orders stuck") or name the subagent that asks
  ("reviewer"); the app writes "asked you", "needs you", or the subagent's name.
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

#### Thread (iPadThread, iPadPortrait, iPadSubagents, iPadReview)

`ThreadScreen` is shared with the phone; on iPad (regular width) it draws as follows.

- **Header** (the system bar, the boards' 52pt, a `lineSubtle` hairline under it): Show sidebar
  when the sidebar is hidden; the name at `.title` (16/600), the branch chip (`NWBranchChip` as on
  the Mac, without its chevron: the branch, the files changed, and the host when more than one is
  set up; iPadThread: "pi/swiftui-previews ●3"), and the status pill (`NWStatusPill`, with the
  running clock: "Running · 37m"); then, trailing, 44pt icon buttons in `textPrimary`. The
  counters ("17 turns · 42k ctx") are gone, as on the boards.
- **Header buttons on the board:** Subagents, Review changes, and Thread options (•••). A
  button whose pane is open takes a `runningTint` fill and a `running` glyph: Subagents while
  the inspector shows (iPadSubagents), Review changes while the review does (iPadReview);
  iPadSteer's 76pt header draws the open one on `bgSelected` instead. The app puts Stop
  (`stop.fill` in `failed`, while pi runs or asks; iPadSteer and iPadQueue
  draw it) and ••• there instead; Subagents is in the ••• menu (while the thread has runs), a
  card's Open and the footer's link, and review opens from the changes card. The ••• menu:
  Refresh, Subagents, Show or Hide Terminal (the terminal has no header button), Open in new
  window, and the agent actions (rename, move, delete).
- **Column:** 780pt wide beside the sidebar (772pt in portrait), 24pt gutters, 24pt above the
  first turn; turns 26pt apart and a turn's parts 14pt apart. Beside the review the column is
  512pt (prose 15, bubbles 14), and beside the subagent inspector 672pt (prose 15, bubbles 15).
  The app caps it at 760pt (`MobileLayout.threadMaxWidth`) and spaces turns 24 and parts 12, as on
  the phone (Known gaps).
- **User bubble:** trailing, at most 520pt (432 beside the review, 420 beside the inspector),
  12×16 inset, radius 8, `bgBubble` with a 1px `lineStrong` line, 15/1.5; the time under it in
  mono 11 `textTertiary`, at rest. The app draws the Mac's bubble (at most 600pt, 10×14 inset).
- **Thinking:** "Thought for 4s" as a 32pt disclosure, 13 `textSecondary` with a 12pt chevron.
- **Prose:** `.body` at 16, line height 1.55 on the iPad boards, capped at 680pt.
- **Work:** the boards list each burst as its own 36pt line (a 13pt `textTertiary` glyph, the
  summary at 14 `textSecondary`, its meta in mono 11 `textTertiary`, a 10pt chevron): "Explored 1
  file · read 1", "Edited 2 files · +58 −45", "Ran tests and a build · 1 passed · build ok". The
  app folds a finished stretch into one "Worked for" line (Principles, Where Shepherd departs).
  The running call keeps its own live line: a `running` glyph, the summary in `textPrimary`,
  the command in mono 11.5 `textTertiary` and its clock in mono `running` ("Running tests · go
  test ./ledger/... · 18s").
- **Changes card:** `bgWindow`, a 1px `lineSubtle` line, radius 8. A 44pt header on `bgSunken`
  (12pt glyph, "2 files changed" at 12.5/600, "+58 −45" in mono 11 `done`/`failed`, and Review, a
  24pt ghost button with its glyph); then 40pt file rows with hairlines between: the status
  letter in mono 11 bold (`lantern` for M, `done` for A), the path in mono 13 with its directory
  in `textTertiary`, and its stat. Review opens every change of the turn; a row opens its file.
- **Turn footer:** Copy response and Retry turn as 36pt circles with 15pt `textTertiary`
  glyphs, then "2:44 PM · 3m 12s · 6 tool calls" in mono 11 `textTertiary`, and "· 3 subagents"
  as a link when the turn spawned runs. At rest (no hover).
- **Notices** (caption `textTertiary`, above the turns; the app's, not the boards'): "<host> is
  offline · showing the last known thread", "This agent is no longer on <host>.", "Update
  Shepherd on <host> to open threads here.", "Some output is clipped · the full thread is on
  <host>", "This host was forgotten." "Load older messages" ("Loading history…" while it loads)
  is a small ghost button at the head.

#### Composer and commands (iPadThread, iPadPortrait)

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
  medium, a chevron; only for a model that takes a level); then Send, trailing: a 40pt `lantern`
  circle with `arrow.up` 16 in `textOnLantern`, at 35% while there is nothing to send. Hold Send
  to Steer now; ⌘↩ sends.
- **Commands** (iPadPortrait): typing "/" opens the list inside the card, above the field: 6pt
  inset, a 1px `lineStrong` line, radius 14, `bgRaised`. Its head (4×8): "COMMANDS" at 11/600,
  uppercase, tracked 6%, `textSecondary`, and "4 of 23" in mono 11 `textTertiary`. Rows at least
  44pt, radius 9, 12pt inset and gap: the name in a 160pt column in mono 13.5 (the typed prefix
  in `textPrimary` semibold, the rest in `textSecondary`), the description at 14
  `textSecondary`, and a source tag ("prompt", 11 `textSecondary` on `bgBubble`, radius 4)
  trailing. The highlighted row is `runningTint`. The draft shows in mono while it is a command.
  Five rows show before the list scrolls.
- **Not built yet: argument hints.** After a command's name, its arguments in mono
  `textTertiary` ("/resume [session]", "/release-notes [tag]"). pi's commands reach the client
  without arguments (`NativeCommand` carries a name, a description and a source), so the host
  must send them first.

#### Up next and steering (iPadQueue, iPadSteer)

Up next follows iOS (and Composer › Up next); on iPad it is a card above the composer card,
8pt apart, as wide as it.

- **Card:** `bgRaised`, a 1px `lineStrong` line, radius 14.
- **Head** (38pt, 14pt leading inset, a hairline under it): the queue glyph (13, `textTertiary`),
  "Up next" at 13/600 `textSecondary`, the count in mono 11.5 `textTertiary`, and Queue options
  (•••, a 34pt circle) trailing. The ••• menu: Steer all now (Send all now while pi is idle),
  "When the turn ends, send" (the delivery mode), and Clear the queue.
- **Rows** (50pt, a hairline above each, 14pt leading and 8pt trailing inset, 12pt gap):
  - A steering row, first, on `runningTint`: `arrow.turn.down.right` 15 in `running`, the text at
    15, the "Steering" pill (24pt, radius 6, `runningTint`, `running` 12.5/500 with its 12pt
    glyph), and Back to the queue (a 34pt circle).
  - A queued row on `bgRaised`: its number in a 22pt circle (a 1px `lineStrong` line, mono 11.5
    `textSecondary`), then the text at 15; an image count when it carries images.
- **Swipe** a queued row left: Edit (80pt, `bgSelected`, a 17pt `pencil` over "Edit" at 12/500)
  and Delete (80pt, `failed`, white). Long-press: Steer now, Edit, Move to top, Delete. A delete
  leaves an Undo row.
- **Header while it runs:** "Running · 5m" and Stop (iPadQueue). **Not built yet:** Show side
  pane beside them (see Side pane).

#### Questions (iPadQuestion)

A question takes the composer's place: a card, not the phone's docked panel, up to 900pt wide
(wider than the thread's column), 10pt above the thread's end and 26pt from the bottom. The
header's pill turns "Needs you" (attention, glowing).

- **Card:** `bgRaised`, a 1px `lantern` line, radius 16, a 3pt `lanternTint` ring outside it;
  14×18 inset (16 at the bottom), parts 12pt apart.
- **Head** (26pt): a 13pt glyph and "pi is asking" at 13/600, both `lanternText` ("Pi is asking"
  on the board; see Where Shepherd departs); **not built yet:** Hide the question (a 40pt
  circle, trailing), which folds the card to read the thread and never answers it.
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
- **Not built yet: a note in the chosen answer** ("Keep the encrypted secret out of the PR."):
  a field inside the chosen card (`bgWindow`, a 1px `lineStrong` line, radius 6, 7×10 inset,
  14.5/1.45, a `lantern` caret) sent with the answer. The answer protocol carries the choice
  only.
- **Not built yet: "Something else…"**, a last full-width row (at least 48pt, its number
  outlined, the placeholder at 15 `textTertiary`) that takes a typed answer.
- **Foot** (a hairline above): Answer, primary, 36pt, enabled once an answer is chosen. The app
  adds Dismiss, which cancels the question (the board has none). A confirm shows Yes and No; an
  input or editor question a field and "Send answer".
- **The app's additions:** "1 / N" (mono `textTertiary`) in the head when several questions
  wait; the asker's longer message in mono on `bgSunken` under the question; "pi may stop
  waiting for this answer" under an answer with a timeout; and, for a question it cannot show,
  "An external editor is open on the host · finish it there" or "This question is too large
  to show here · answer it on the host".

#### New thread (iPadNewThread)

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
  14.5/600, what it is at 12 `textTertiary` ("Shepherd app · Pi 0.87"), what it carries at 11.5
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

#### Subagents (iPadSubagents, iPadSteer)

Runs open in an inspector beside the thread (`PadSubagentInspector`), never over it: 460pt on
iPadSubagents and 400pt on iPadSteer (the app lets it range 340–480, 400 ideal), with a 1px
`lineStrong` leading edge on `bgWindow`. Closing it returns to the thread as it was. With no run
chosen (All subagents) it lists the thread's runs under a "Subagents" head with their tally.

- **A live group** in the thread (iPadSteer): a `bgRaised` card, a 1px `lineSubtle` line, radius
  12, 12×14 inset. Its head: a 15pt glyph and "3 subagents" at 14.5/600. A 32pt row per run
  (radius 6, 12.5): its state glyph (a spinner running, a glowing 7pt `lantern` dot asking, a
  check done), the name in mono semibold in a 128pt column, what it does in `textSecondary`
  ("step 1 of 3 · restyling ThreadView"; "needs you: rename or replace?" in `lanternText`), and
  its time in mono 11 `textTertiary`. The run the inspector shows takes `bgSelected`. Under the
  card, while the spawning turn is live: "Waiting on worker and reviewer" with a `running`
  glyph, at 14.5 `textPrimary`.
- **A finished group** becomes the ledger (iPadSubagents): `bgWindow`, a 1px `lineSubtle` line,
  radius 12. Its head (at least 44pt, on `bgSunken`): a 16pt `done` glyph, "3 subagents" at
  14/600, an 8pt square per run at radius 2 in its state color, and "all done · 45m" in mono 11
  `textSecondary`. Rows at least 52pt (6×12 inset, hairlines between): the state glyph (14), the
  name at 14/600 with its meta in mono 11 `textTertiary` ("5 files · 41m"; "1 question · 12m"
  for a run that asked; the app shows the files and the time only), the result at 13
  `textSecondary`, and a chevron. The run the inspector shows takes `runningTint` with a 3pt
  `running` bar on its trailing edge and a `running` chevron. The turn's footer adds "· 3
  subagents" as a link.
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

#### Review (iPadReview, iPadReviewSplit)

`PadReviewScreen` has two layouts; Full screen and Beside the thread switch between them.

**Docked** (iPadReview): the thread keeps the left and the review takes the right: 620pt, never
more than 58% of the detail, with a 1px `lineStrong` leading edge on `bgWindow`. The board hides
the sidebar (Show sidebar in the thread's header) so the thread keeps a 512pt column; so do the
inspector's boards (iPadSubagents, iPadSteer). The app keeps the sidebar in landscape whatever
docks (`PadShell` shows both columns in landscape), so the thread narrows between the two until
the user hides it (Known gaps).

- **Head** (the bar's height, 16pt leading and 6pt trailing inset, a hairline under it):
  "Review" at 15/600 over "4 files · +67 −58" in mono 11 `textTertiary`; the source switch,
  Local | PR #24 (a `bgSelected` track at radius 10, 3pt inset; 30pt segments at radius 8, 13;
  the chosen one on `bgWindow`, semibold, the other `textSecondary`); and Close review (a 44pt
  circle, `xmark` 13 in `textSecondary`). The app adds Full screen and, for a worktree agent,
  Finalize worktree, and its segment reads "PR".
- **File strip** (on `bgBase`, 8×12 inset, 6pt apart, a hairline under it; `NWTouchFileStrip`):
  36pt chips at radius 9 in mono 12: the status letter bold (`lantern` M, `done` A), the name,
  and its stat. The current file's chip takes `bgSelected`.
- **File head** (at least 44pt, on `bgSunken`, 14pt leading inset): the path in mono 13 (the
  directory `textSecondary`, the name semibold), "2 hunks" in mono 11 `textTertiary`, then Mark
  viewed (a 44pt circle; `done` once viewed). The board's Revert file (a `failed` glyph) is not
  offered over remote (see Where Shepherd departs).
- **Diff** (unified): 24pt lines in mono 12.5, two 34pt gutters in mono 11 `textTertiary`, a
  14pt sign column. The hunk header on `bgSunken` in mono 11 `textSecondary`. Removed lines on
  `failedTint`, added on `doneTint`, signs in `failed` and `done`, code in syntax colors. A run
  of removed lines folds into a 36pt row on `bgSunken` between `lineSubtle` hairlines, indented
  82pt: a 10pt plus and "13 more removed lines · 18–32" in mono 11.5 `textSecondary`; a tap
  unfolds it. Tapping a line opens a comment editor under it.
- **Comment** under its line, indented 82pt to the code: `bgRaised`, a 1px `lineStrong` line, radius
  10, 10×12 inset: an 18pt initial on `running` in white, "You" semibold, "line 33 · just now" in
  mono 12 `textSecondary`, then the text at 14/1.5.
- **Review composer** (a hairline above, 10×12 inset, 28 under): a `bgRaised` card at radius 14
  with a 1px `lineStrong` line: the field "Overall comment" at 15/1.5, then "1 inline" in mono
  11 `textTertiary`, Commit (40pt at radius 10, `bgWindow` with a 1px `lineStrong` line, 14/500
  in `done`) and Request changes (primary, 40pt at radius 10, 14/600). With `review.commit.v1`
  the app's Commit… opens the commit popover, and Ask agent to commit keeps the turn that asks
  the agent. A failed send shows "Couldn't send the review" with Dismiss.

**Full screen** (iPadReviewSplit): the review takes the window; the board draws no sidebar. The
app fills the detail column, so in landscape the sidebar stays beside it (Known gaps).

- **Head** (the 76pt header): "‹ Thread" (16, `running`, back to the thread), "Review" at 17/600,
  the agent's pill with its clock ("Running · 42m"), and "working tree vs HEAD" at 12.5
  `textTertiary`; trailing, the source switch (a `bgSunken` track with a 1px `lineSubtle` line
  at radius 6; 24pt segments at radius 4, 12; the chosen one on `bgSelected` with a 1px
  `lineStrong` ring), 8pt, Commit… (secondary, 36pt) and Request changes (primary, 36pt). The app
  adds Beside the thread and Finalize worktree, and a host without `review.commit.v1` shows
  Commit, which asks the agent.
- **File list** (260pt, a 1px `lineSubtle` trailing edge, 12×10 inset, 4pt apart): "3 FILES"
  (`.nwSectionLabel()`) with "+97 −48"; rows at least 58pt, 8×12 inset, radius 10: the status
  letter in mono 12 bold, the name in mono 13/600 over its directory in mono 11 `textTertiary`,
  the stat in mono 11 and a comment count (an 11pt `running` bubble and "1") trailing, names
  whole. The current row takes `bgSelected`; viewed files are marked. At the foot (a hairline
  above, 14×16 inset): "OVERALL" and "Add an overall comment…" at 13 `textTertiary`.
- **File head** (46pt on `bgSunken`, 14pt inset): a 14pt file glyph, the path in mono 13, its
  stat, Viewed (a 14pt checkbox at radius 4 with the 1.5pt `lineStrong` border on `bgRaised`,
  and "Viewed" at 13 `textSecondary`), and Unified | Split (20pt segments).
- **Split:** column heads "HEAD" | "WORKING TREE" ("BASE" | "BRANCH" for a PR) in mono 10.5
  tracked 4% `textTertiary`, 6×12 inset, 48pt leading; halves split by a 1px `lineSubtle` line.
  Rows 26pt in mono 12, a 34pt number column in mono 10.5 `textTertiary`, a 14pt sign column;
  removed rows on `failedTint`, added on `doneTint`. A fold is a 26pt `bgSunken` row ("13 more
  removed lines", mono 11 `textTertiary`) on its side, blank `bgSunken` on the other; a side with
  no line opposite is hatched (`lineSubtle` stripes at 135°, every 6pt). Comments sit under
  their line in the right half, 44pt in.

#### Commit (iPadCommit)

Commit… opens a popover under it (`.commitPopover`): 400pt wide, `bgRaised`, radius 14 on the
board (`.nwPopover()`), with its arrow; 16pt inset, parts 12pt apart.

- **Title:** "Commit 3 files" at 16/600; the count follows the ticked files ("Committing…",
  "Committed", "Pull request opened", "Commit stopped" as it runs).
- **Message card** (`bgWindow`, a 1px `lineStrong` line, radius 10, 10×12 inset, 6pt apart): the
  summary at 14.5/600, the body at 13/1.5 `textSecondary`, and "Drafted from the diff" at 11.5
  `textTertiary` with an 11pt sparkle (the app: "Drafted from the diff · edit anything"). Both
  lines edit in place.
- **Files** (rows at least 36pt, 10pt gap): a 14pt checkbox at radius 4 (`lantern` with a
  `textOnLantern` check when ticked), the name in mono 12.5, its stat in mono 11. Every file
  starts ticked; an untouched message redrafts for the ticked files. The list scrolls past
  220pt.
- **Options** (rows at least 46pt, a hairline above each): Push after commit (its upstream,
  "origin/main", at 12 `textTertiary`) and Open a pull request instead ("pushes a branch, opens
  the PR"), titles at 14.5, each with a 30×18 switch (`lantern` on, `lineStrong` off).
- **Foot:** Cancel (the board's ghost; the app's secondary) and the primary, whose title
  follows the options: Commit, Commit & push, or Commit & open PR. The app adds Ask agent (ghost,
  leading), which sends the agent a turn instead.
- **States** (the app's): "Reading the changes on the host…" while it loads; "Can't commit
  from here" when the host can't; "The agent is working" with a "Commit while it works"
  switch; "Can't commit here" for a detached HEAD or a merge in progress; "Redrafting the
  message…" while Commit waits on a new draft; "Starting on the host…", then each step, then
  Done, or Close while it continues on the host; "Nothing was committed", "Stopped", "Outcome
  not yet known".

#### Overview (iPadOverview)

With no thread selected the detail is the Overview (`PadOverview`).

- **Header:** "Overview" (the board's 17/600) with the summary beside it at 12.5
  `textTertiary` ("4 need you · 6 running · 3 hosts"); Search and New thread trailing (40pt
  circles, 18pt `textSecondary` glyphs).
- **Columns:** Needs you, Running now and Finished side by side (16pt inset, 16pt apart; the app
  12pt), each headed by its name and count (mono 11/500, uppercase, tracked 5%; Needs you in
  `lanternText`, the others `textTertiary`). They stack when three 256pt columns don't fit, and
  at accessibility sizes. Pull to refresh retries the hosts. An empty column shows a quiet card
  ("Nothing is waiting on you.", "Nothing is running.", "Nothing has finished yet."); with no
  hosts the detail is the no-hosts state.
- **Needs you cards** (`NWAttentionCard`): `bgRaised`, a 1px `lineSubtle` line, radius 12, 10×12
  inset, 8pt apart. The origin line: a 14pt `lanternText` glyph (a glowing 8pt `lantern` dot for
  a blocked thread), its kind at 12 `textTertiary` ("Thread", "Subagent", "Automation"), its age
  trailing; the title at 14.5/600 ("reviewer · Restyle native UI" for a subagent); the question
  at 13/1.4 `textSecondary`; then the answers as 28pt buttons at radius 6, 12.5: the first
  primary, the rest secondary. The asker's short options (up to three, each up to 32
  characters), or Yes and No, answer in place; anything else shows Open.
  - The board answers a subagent in place ("Replace all", "Rename new"); the app offers Open
    there.
  - **Not built yet:** a mission's card ("Mission · now", "Retry with hint", Open).
  - The board's "Approve plan" and "Read" are the answers a plan-approval question would offer.
    Shepherd shows them only when the asker offers them (Principles: no permission model); a
    blocked thread with no question shows "Waiting on you" and Open.
- **Running now:** one card per kind (`bgRaised`, a 1px `lineSubtle` line, radius 12), each
  opening with a caption band on `bgSunken` (mono 10.5, tracked 5%, `textTertiary`, 8×12 inset):
  "THREADS · 3", "AUTOMATIONS · 1". Rows (10×12 inset, hairlines between): the state glyph in a
  16pt column, the title at 14/500, its clock in mono 11 `textTertiary` ("4:12", "37m"), and
  under it, in mono 11.5 `textTertiary`, what it does now: the running command ("swift test
  --filter toolPreview"), its subagents ("3 subagents · 1 needs you"), or its command and host
  ("swift build · This Mac"). The app writes "running · <activity>" and draws no caption bands
  or subagent line. A running automation's row is `AutomationRow` ("Running · 4m"; the board's
  "waiting for CI · 3 of 5 checks" needs triggers the host doesn't have). **Not built yet:**
  "MISSIONS · 2", with each mission's lanes as a 150×14 strip.
- **Finished:** one card under a "TODAY" caption band. Rows at least 52pt (6×12 inset): the outcome
  glyph (14; `done` check, `failed` cross), the title at 14/500 over its outcome at 12
  `textTertiary` ("PR #34 merged · 2h41", "3 migrations, all reversible", "1 PR failed CI"), and the
  time of day in mono 11 `textTertiary` ("11:02"; the weekday, "Mon", for an older one). The app
  lists finished threads newest first with "done · host" and how long ago, without day bands,
  outcomes, or finished automation runs. **Not built yet:** a design's row ("4 boards · 1 comment
  resolved").

#### Needs you (iPadInbox)

The sidebar's Needs you head opens the list beside the chosen item's detail, one at a time with
its full context.

- **List:** 380pt wide on the board (the app 360), a 1px `lineSubtle` trailing edge. Its header:
  "Needs you" (17/600) with "5 waiting" at 12.5 `textTertiary` (the app puts "3 things are
  waiting on you" at the list's top). Items (10pt inset, 2pt apart): 12pt inset at radius 10, the
  chosen one on `bgSelected`: the origin line (a 14pt `lanternText` glyph or a glowing 8pt dot,
  "Subagent · Restyle native UI" at 12 `textTertiary`, the age trailing), the title at 15/600
  ("reviewer asks"), the question at 13/1.4 `textSecondary`.
- **Detail header:** the title (17/600) and the pill with its age ("Needs you · 2m"); **not built
  yet:** a ••• menu (40pt) trailing (the board does not show its items).
- **Detail** (16×20 inset, 14pt apart): the question at 17/1.5, selectable, inline code in mono
  12 on `bgSunken`. The asker's longer message in mono on `bgSunken` (a 1px `lineSubtle` line,
  radius 8, 12×14 inset, 12/1.65). "Answer this one in the thread." under a subagent's question;
  "Open the thread to see what it is waiting for." under a blocked thread.
- **Not built yet: structured context and trade-offs.** The board's code block names each file
  with its use count in `textTertiary` ("Sources/ShepherdApp/Tokens.swift · 41 uses",
  "…DesignTokens.swift · new, from the spec"). Its answers are cards (`bgRaised`, radius 12,
  12×14 inset): the title at 15/600, the asker's pick outlined in `lanternText` with a
  "reviewer's pick" tag (mono 9.5 `lanternText` in a 16pt box with a 1px `lanternText` line,
  radius 4), and trade-offs as "· " lines at 13.5/1.45 `textSecondary`. A subagent answers here
  like any other asker.
- **Where it came from** ("WHERE IT CAME FROM"): 34pt lines with a 14pt `textTertiary` glyph, the
  source at 14.5 `textSecondary` and its meta in mono 11.5 `textTertiary`: "reviewer · Restyle
  native UI · async · opus · 2m ago"; "Parent thread is waiting · worker keeps going". The app
  shows one row (the thread, "A thread", "Its subagent reviewer" or "A run of the automation
  <name>", and the host tag); the mode, model, age and the parent's state are **not built yet**.
- **Foot** (a hairline above, 12×20 inset, 26 under, 36pt buttons, trailing): Open thread
  (ghost; Open subagent for a run, primary when Open is all there is), then the answers as
  secondary buttons with the asker's pick last, primary ("Rename new ones", then "Replace
  everywhere").
- **Not built yet:** mission items ("Mission · planner").
- Empty: "Nothing needs you", "Questions and blocked threads from every host show here."

#### Hosts and More (iPadHosts)

Built: More opens a page of host cards (`NWHostCard`, in columns at least 320pt wide): the name,
the address and port, the connection word, what runs there ("2 threads running · Shepherd"),
Retry while it is offline, and a refusal's reason; "Add host" (a small `running` ghost button)
in the head, and the footnote "Hosts connect over your LAN or VPN. The connection has no TLS." A
card opens the host's form (Name, Address, Port, Token, kept in the Keychain; Forget host).
Settings ▸ Hosts shows the same cards, with Add host (secondary) under them and "Trusted LAN or
VPN only: the connection has no TLS."

**Not built yet: the Hosts destination** (iPadHosts), reached from More's Hosts sub-row:

- **List** (320pt, a 1px `lineSubtle` trailing edge): "Hosts" with Add host (+) in its header;
  rows at least 64pt, 8×12 inset, radius 10, the chosen one on `bgSelected`: a 16pt
  `textSecondary` glyph, the name in mono 15/600, what it is and carries at 12 `textTertiary`
  ("app · 2 threads"; "offline since 07:12" once it drops), and an 8pt status dot trailing
  (`done`, `failed`).
- **Detail header:** the name (17/600), "● Connected" at 13 `done` with an 8pt dot, and the kind
  and address at 12.5 `textTertiary`; a ••• menu trailing.
- **Detail** (16×20 inset, two columns 12pt apart):
  - CPU and Memory cards (`bgRaised`, a 1px `lineSubtle` line, radius 12, 10×12 inset): the
    label at 12 `textTertiary`, the value at 18/600 ("44%"), its scale at 12 `textTertiary`
    ("16 cores", "of 64 GB"), and a 56pt history line.
  - "RUNNING HERE · 5" with "stations, threads and automations" at 12 `textTertiary`; 36pt rows
    with hairlines between (13): the state glyph, the name in mono semibold, what it belongs to
    in `textSecondary`, the repo and the tokens used in mono 11.5 `textTertiary` ("612k", "—").
  - A Worktrees card ("14 · 22 GB" at 15/600, "6 older than 7 days"), a version card (the
    host's Shepherd and pi versions and uptime; the board's "shepherd-d 0.4.2 · up 6 days · Pi
    0.87.1"), and "LOG": the host's recent events in mono 11/1.6 `textSecondary` on `bgSunken`
    (a 1px `lineSubtle` line, radius 8, 10×12 inset), each line led by its time.
- The remote protocol carries none of this yet: no load, no per-host list, no worktree
  inventory, no versions (`helloOk` has the protocol version and capabilities only), and no log.
- The board's daemon hosts ("Linux daemon", "macOS daemon", stations, missions) wait for a
  daemon; Shepherd has none.
- The board's **Clean worktrees** (secondary, in the header) would remove worktrees, which
  Shepherd never does on its own (AGENTS.md › Only these paths mutate repositories). It needs
  that rule changed before it is built.
- **Not built yet: More's other pages:** Design systems, Pi extensions (the host's bundled
  extensions, as Settings ▸ Pi shows them on the Mac), and Archive.

#### Command palette (iPadPalette)

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

#### Split View (iPadSplitView)

Two Shepherd windows side by side (see iOS › Windows). A narrow window keeps the thread's
layout: the sidebar toggle, the name and pill ("Running", without the clock), the header's
Subagents and Review buttons, and the live group card with shorter details ("restyling
ThreadView", "needs you", "14 pass").

**Not built yet: a Design beside the thread.** The board's right window is a design with the
design agent's note floating over it; Design tool › On iPad specifies it.

#### Settings (iPadSettingsInstructions)

Built: Settings pushes over the detail as one list: Appearance (System, Light, Dark), Machines ›
Hosts (the count, or "n offline"), and About.

**Not built yet: Settings as a list beside the page.** A 300pt column (a 1px `lineSubtle`
trailing edge) headed "Settings"; rows at least 48pt, 12pt inset and gap, radius 10: a 17pt
`textSecondary` glyph and the label at 15/500; the open page's row on `bgSelected`, its glyph
`textPrimary` and label semibold. Pages: Appearance, Agents, Worktrees, Pi, Instructions,
Notifications, Hosts, Keyboard, Experiments. Agents, Worktrees, Pi and Keyboard are the host's
settings, as the Mac shows them; Notifications waits for push; Instructions and Experiments wait
for the Mac.

**Not built yet: Instructions** (editing the instructions pi reads on every host; the Mac's page
is Settings › Instructions, SettingsInstructions):

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
  1px `lineSubtle` line, `textSecondary`) joined by "→": pi prompt → root AGENTS.md → parent
  folders → repo AGENTS.md → APPEND_SYSTEM.md (the last on `lanternTint` with a `lanternText`
  line, in `textPrimary`). Under it at 12.5/1.5 `textTertiary`: "APPEND_SYSTEM.md is added to the
  end of pi's system prompt, so these rules beat anything in an AGENTS.md. Keep it short."
- The board edits `~/.pi/agent/APPEND_SYSTEM.md`. Shepherd never writes into `~/.pi/agent/`
  (AGENTS.md › Gotchas) and keeps its own pi apart from the user's, so the files it edits must
  be decided before this is built.

#### Side pane (iPadPaneBrowser, iPadPaneArtifacts, iPadPaneFiles)

Built: the docked review (see Review) is the only thing beside a thread.

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
    a 3×11 `lantern` bar, "changed by Pi" beside a `running` one) and, trailing, "Ln 94, Col 48
    · TSX · Spaces: 2" in mono.
- Saving and reverting here would change a repository on the host, which only the paths in
  AGENTS.md › Only these paths mutate repositories may do; Files needs a new one decided first.

### iOS: Automations

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
    you" in `lanternText`). The app draws the live runs as rows in a list card under the head.
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
- **iPhone** pushes one automation; **iPad** (iPadAutomations) lists them in a 360pt column (the app
  340, `MobileLayout.automationsListWidth`; a 1px `lineSubtle` trailing edge) beside the chosen
  one's detail. The column's header is "Automations" with New automation (+, a 40pt circle). Its
  rows (at least 66pt, 8×12 inset, radius 10, 10pt gap; the chosen one on `bgSelected` with a
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

## Notifications and Live Activities

How Shepherd reaches you outside its window, on iPhone, iPad and Mac. The authority is the
Notifications page (NotifCatalog, NotifPhoneBanner, NotifPhoneStacks, NotifPhoneRich,
NotifPhoneReply, NotifPhoneReview, NotifPhoneSummary, NotifSettings, NotifiPadBanner,
NotifiPadCenter, NotifMac) and the lock-screen boards (MobileLock, MobileAnswer, MobileLiveLock,
MobileIsland, iPadLock).

**What is built:** only the Mac's banners for its own agents (`AgentNotifications`, worded by
`AgentBanners`; On the Mac today, below). The iOS client posts no notifications and has no Live
Activities or widgets: it drops every host's connection in the background, and a push needs a relay
that doesn't exist yet ([docs/ios](docs/ios/README.md) › Not in the first release). On iPhone and
iPad, Home's Needs you inbox stands in: questions and blocked threads across hosts, answered in
place when short. Everything else in this section is **not built yet**, and several kinds wait on
features that don't exist either (Missions, plan approval, token budgets, Designs).

**Who draws what.** The system draws a notification: its card, its type, the app icon, the relative
time, the "TIME SENSITIVE" label, stacks, and where the actions appear. Shepherd decides the words
(title, subtitle, body), the actions and their order, the interruption level, the group
(`threadIdentifier`), what a tap opens, and any rich content (a content extension, attachments). So
the boards' notification cards are the system's, filled with Shepherd's content. A Live Activity,
the Dynamic Island and a widget are Shepherd's own drawing, in Night Watch. Where a board draws
something only the system decides, this section says so. Never rebuild the system's chrome inside
the app to get it.

### The catalog

Every notification Shepherd sends, in three groups (NotifCatalog): **Needs you** (the `attention`
state), **Problems** (`failed`) and **Finished** (`done`). Titles name the thing. Bodies are one
sentence. Actions are the same choices the app shows for that moment, never more. In Needs you and
Problems the first action is the recommended one, and the only one in lantern wherever a surface
draws emphasis (a Live Activity, the iPad boards' buttons); Finished work's actions are plain.

| Group | Kind | Title | Body (the board's words) | Actions, in order | Level | Grouped by |
| --- | --- | --- | --- | --- | --- | --- |
| Needs you | Planner question | the mission ("Refund events") | the question: "Which key joins a refund to the funnel?" | each option, the planner's pick first ("order_id", "payment_id"), then Reply… | Active | mission |
| Needs you | Subagent question | "thread · subagent" ("Restyle native UI · reviewer") | the question: "Rename the new tokens, or replace the old ones everywhere?" | each option the subagent offered ("Replace everywhere", "Rename new ones"), then Reply… | Active | thread |
| Needs you | Plan to approve | the thread ("Dock review pane") | "Plan ready: dock the review pane on the right." | Approve plan, Open | Active | thread |
| Needs you | Stuck lane | the mission ("Checkout funnel events") | "orders is stuck after 3 tries." (the banner adds the planner's pick: "The planner suggests a retry with a hint.") | Retry with hint, Replan the lane, Open | Time Sensitive | mission |
| Needs you | Out of budget | the mission | "Paused at 6M tokens. About 0.9M to finish." | Add 1M and resume, Open | Time Sensitive | mission |
| Needs you | Off the map | the mission | "Paused: a contract change needs a patch." | Review patch | Active | mission |
| Needs you | Ready to review | the mission | "4 PRs ready. Contract: 10 of 10 passed." | Approve · start train (needs Face ID; the board's chip carries a lock), Open | Active | mission |
| Needs you | Automation question | the automation ("Triage new Sentry issues") | the question: "Is this a regression from #231?" | each option ("Yes, open a fix", "No") | Active | automation |
| Problems | Turn failed | the thread ("Fix remote nightly") | what failed: "Build failed in RemoteClient.swift." | Retry, Open | Active | thread |
| Problems | Automation failed | the automation ("Weekly dependency bump") | "1 PR failed CI." | Retry, Open | Active | automation |
| Problems | Host offline | "*host* is offline" ("horizon is offline") | what waits on it: "1 automation paused until it's back." | Retry | Active | host |
| Finished | Turn finished | the thread ("Investigate SwiftUI live preview") | the turn's result: "Done. 3 files changed, tests pass." | Review | Passive | thread |
| Finished | Mission merged | the mission | "Merged in order: 4 PRs in 2h58." | Open | Passive | mission |
| Finished | Automation passed | the automation ("Nightly migrations dry run") | "3 migrations, all reversible." | none: a tap opens it | Passive | automation |
| Finished | Boards ready | the design ("Onboarding flow") | "4 boards drawn in acme-web." | Open | Passive | design |

- **The subtitle is the kind** as this table names it ("Planner question", "Turn finished"), plus "·
  *where*" when the moment has a place ("Stuck lane · orders-svc"). Host offline's is "Host"
  (NotifiPadCenter).
- **Which setting covers a kind** (NotifSettings › Send me): Questions and approvals (planner,
  subagent and automation questions, plans, reviews), Blocked work (stuck lanes, empty budgets),
  Failures (failed turns, failed automations, hosts going offline), Finished work.
- **Built:** on the Mac, and only partly, Subagent question, Turn failed and Turn finished, plus a
  blocked agent's question (see On the Mac today). An automation's run is an ordinary agent wearing
  the automation's name, so its question, failure and finish post as that agent's. Nothing else in
  the table exists yet: Missions, plan approval, budgets, Designs, and host notifications are not
  built.

### Rules for sending

As the board lists them (NotifCatalog › Rules):

1. **One device: the one you're using.** If the Mac had input in the last 2 minutes, only the Mac
   gets it. Otherwise the phone or iPad you used last does (NotifSettings' "Only when I'm away from
   my Mac").
2. **Answer once, gone everywhere.** Answering on any device clears the notification from the
   others. The board clears it with a silent push.
3. **Progress is a Live Activity.** Running threads, missions and automations update their Live
   Activity. A notification only marks a change that needs you, or an end.
4. **Time Sensitive only when blocked and spending.** A stuck lane or an empty budget can break
   through Focus. Nothing else can: every other Needs you kind and every Problem is Active.
5. **Successes are quiet.** Finished work is Passive and lands in the Scheduled Summary; failures
   are Active. (Whether Shepherd is in the Scheduled Summary is the person's choice in iOS Settings;
   Passive is what Shepherd sets.)
6. **Grouped by the thing, not the app.** `threadIdentifier` is the mission, thread, automation,
   host or design (the board's payload: `"thread-id": "mission:anl-214"`), so a busy mission is one
   stack.
7. **Never a permission prompt.** No notification asks to allow a command or a tool. They carry
   decisions about the work, not about the agent's access (Principles › No permission model).
   **Built:** the Mac's banners carry status and questions only.
8. **Approving code needs Face ID.** An action that merges or pushes is `.authenticationRequired`,
   so a locked phone can't start a merge train. NotifPhoneReview asks for Face ID even on an
   unlocked phone; `.authenticationRequired` alone asks only for an unlocked device, so that needs
   Shepherd's own Face ID check before it acts.
9. **Quiet while you watch.** No notification for a thread that's open on screen; its Live Activity,
   or the view itself, already shows it. **Built on the Mac:** a status or subagent banner is
   skipped while its agent is selected and Shepherd is frontmost.

### Anatomy

A notification, top to bottom (NotifCatalog › Anatomy; NotifPhoneBanner):

1. **Interruption level:** "TIME SENSITIVE" over the title, on stuck lanes and empty budgets only.
   The system draws it.
2. **Title:** the mission, thread or automation (the host, for Host offline), never "Shepherd". A
   subagent's question is "*thread* · *subagent*".
3. **Subtitle:** the kind and where: "Stuck lane · orders-svc".
4. **Body:** one sentence, with the planner's pick when there is one: "orders is stuck after 3
   tries. The planner suggests a retry with a hint."
5. **Long press** (on a banner, pulling it down) shows a rich view (attempts, lanes, thumbnails) and
   up to three actions.

**A tap opens the thing it names,** straight to what asked, even from a cold launch: the mission (at
the station that asked, MXNav), the thread at its question, the automation's run, the review, the
boards. **Built on the Mac:** a click brings Shepherd forward and selects the agent, and a click
that launches Shepherd still lands; a banner whose agent is gone only brings Shepherd forward.

Words follow the boards: sentence case, the thing's own name, " · " between parts, figures as digits
("3 tries", "4 PRs", "10 of 10 passed"), durations as the app writes them ("2h58", "1h38").

### Actions and answering

The board's categories (NotifCatalog's `NotificationCategories.swift`):

| Category | Actions (identifier, title, options) |
| --- | --- |
| `shepherd.stuck` | `retry-hint` "Retry with hint"; `replan` "Replan the lane"; `open` "Open" (`.foreground`) |
| `shepherd.review` | `approve` "Approve · start train" (`.authenticationRequired`). The board's code has only this action; NotifPhoneReview lists Open review under it |
| `shepherd.question` | one action per option the asker offered, then `reply` "Reply…": a `UNTextInputNotificationAction` whose button is "Send", with the placeholder "Tell the planner…" for a planner question |

- **Order:** the recommended answer first (the planner's pick), then the other options, Reply…, and
  Open last. Where the system lists actions (a long press on iPhone), up to three show
  (NotifCatalog); MobileAnswer's four (two options, Reply…, Open mission) is the most any board
  lists.
- **Glyphs** (SF Symbols, `UNNotificationActionIcon`), as the boards draw them: `checkmark` on the
  planner's pick (MobileAnswer), `arrow.clockwise` on Retry, `map` on Replan the lane, `text.bubble`
  on Reply…, `faceid` on Approve · start train, `chevron.right` on Open (Open mission in
  NotifPhoneRich, Open review). Other options carry none. MobileAnswer draws `map` on its Open
  mission instead; the boards disagree, so settle it before building.
- **Answers go where the question came from.** A typed answer or a chosen option goes to the
  subagent that asked, not its parent thread (NotifPhoneReply: "Goes to the reviewer, not the parent
  thread."), and to the planner for a planner question. Tapping a choice needs no typing.
- **Answering never opens Shepherd** (NWMissions: the choices are actions "so answering never opens
  the app"). Open, Review and Review patch open Shepherd at the thing.

### iPhone

**Not built yet.** The iPhone posts nothing today (What is built, above).

- **Banner** (NotifPhoneBanner): a Time Sensitive stuck lane shows over any other app, with the
  anatomy above. Pulling the banner down shows the choices; tapping it opens the mission.
- **Notification Center** (NotifPhoneStacks): stacks by `threadIdentifier`, so a mission's
  notifications are one stack ("2 more from this mission" under the newest), and each thread,
  automation and host is its own. Finished work collapses ("3 more finished · in your 6 PM
  summary"). The stuck lane leads the list; NotifCatalog's payload gives it `relevance-score` 0.9.
- **Lock Screen** (MobileLock): the board draws three notifications under the clock (the stuck lane,
  a planner question, and an automation's finish: "Merge PR #24 after CI", "Merged. main is
  green."), then the mission's Live Activity (Live Activities, below). The system decides that
  order. The board draws a question as "Refund events · question" with no subtitle and the options
  in its body ("…: order_id or payment_id?"); the catalog's anatomy (the kind as subtitle, the
  question as the body) is the rule.

**Rich views** (a long press). Each is Shepherd's own content in the system's expanded card, drawn
in Night Watch from the same tokens as the app: `bgRaised` behind (radius 20, padding 14 × 16,
its blocks 12pt apart in the stuck-lane view, 10pt in the review), `textPrimary` text,
`textSecondary` for supporting lines, `textTertiary` for meta, `lineSubtle` hairlines, a 26pt app
icon (radius 6) beside the title (14pt semibold) and its meta (a mono 10pt "TIME SENSITIVE" in
`lanternText`, or the time at 12pt in `textTertiary`). Under the card, the system lists the actions
(Actions and answering).

- **Stuck lane** (NotifPhoneRich): the mission's lanes as `NWLaneStrip` rows ("A lane as a tiny
  subway line", NWMissions; not built): the lane's name (mono 11pt, `textSecondary`, a 90pt column),
  a 120pt three-stop track (9pt stops joined by 2pt lines in `done`; a finished stop filled `done`,
  the running one a ring in `running` on `bgRaised`, the stuck one filled `failed`), then where it
  is in mono 10.5pt ("done" and "at join" in `textTertiary`, "go test" in `running`, "stuck" in
  `failed`), 20pt rows 4pt apart. Under a hairline: the headline ("orders is stuck after 3 tries",
  14.5pt semibold), then each attempt (a 16pt circle outlined in `failed` with its number in mono
  9.5pt, then what that try did at 12.5pt in `textSecondary`: "Wrote OrderPlaced after InsertOrder",
  "Wrapped the test in a savepoint · same failure", "Reset the outbox · same failure"), rows at
  least 24pt. Last, the planner's read on `bgSunken` (radius 12, padding 10 × 12): "Planner's read"
  (11.5pt, `textTertiary`) over its paragraph (13pt, line height 1.45) ending in the hint. Actions:
  Retry with hint, Replan the lane, Open mission.
- **Planner question** (MobileAnswer): the question, then under a hairline why it matters (13pt,
  `textSecondary`: "Changes the validation contract, so nothing is drafted until you answer. The
  rest of the brief is ready."), then each option: its name in mono semibold (an 84pt column) and
  what choosing it means in `textSecondary` ("payments-svc already has it on every refund"), the
  pick marked "· planner's pick" in `lanternText`. Actions: the pick (`checkmark`), the other
  option, Reply…, Open mission.
- **Subagent question, replying** (NotifPhoneReply): the question notification on top; under it,
  over the keyboard, the choices as 34pt buttons (radius 8, `bgRaised`, 13.5pt) on a `bgSunken`
  strip, then the reply field: a capsule at least 38pt tall (radius 19, `bgRaised`, a `lineStrong`
  border, 16pt text, a lantern caret) with **Send** beside it (16pt semibold, `running`). Tapping a
  choice answers without typing. The typed answer goes to the subagent that asked.
- **Ready to review** (NotifPhoneReview): the mission and "now", then "Ready to review" (15pt
  semibold); "Contract: 10 of 10 passed" (13pt) after a `checkmark.shield` in `done`, and "· merges
  in this order" in `textTertiary`; then one row per PR in merge order, at least 26pt: its place
  (mono 10.5pt, `textTertiary`, a 12pt column), the repository (mono semibold), the PR number (mono
  11.5pt, `running`) and `NWDiffStat` (mono 11pt). Actions: Approve · start train (`faceid`), Open
  review. Approving asks for Face ID even on an unlocked phone ("Approving needs Face ID, even with
  the phone unlocked. The diffs are one tap away in Open review.").
- **Scheduled Summary** (NotifPhoneSummary): finished work arrives Passive, so it can wait for the
  summary ("Your Evening Summary", "7 notifications · Shepherd"). Each entry is the catalog's title
  and body (Mission merged, Boards ready, Turn finished, Automation passed). Under Boards ready the
  board draws three board thumbnails side by side (58pt tall, sharing the width, radius 8, 6pt
  apart), from its attachments. The system draws the summary and its "3 more".

### iPad

**Not built yet.** The same catalog, anatomy and rules as the iPhone, with room to spare.

- **Actions without a long press** (NotifiPadBanner, NotifiPadCenter): "On iPad the actions sit
  right in the notification: there's room, so you don't need to long-press first." The boards draw
  them as a row of 28pt buttons (`NW.Height.controlM`, radius 6, 12.5pt, 8pt apart, 8pt under the
  body): the recommended one primary (`lantern` fill, `textOnLantern`, semibold), the other choices
  secondary (`bgRaised`, a `lineStrong` border), Reply… and Open ghost (`textSecondary`). Retry
  carries `arrow.clockwise`. Where no option is recommended (a planner question without a pick,
  NotifiPadCenter), no button is primary. **Platform limit:** iPadOS, like iOS, shows a
  notification's actions only once it is expanded, so building this as drawn needs a decision first.
- **Banner** (NotifiPadBanner): 480pt wide, centred 30pt under the top edge, over whatever is on
  screen: the subagent's question with Replace everywhere (primary), Rename new ones, Reply…. The
  board's backdrop (the Missions list and a stuck lane's detail) belongs to Missions.
- **Notification Center** (NotifiPadCenter): a 520pt column, 36pt from the right edge, headed
  "Notification Center" and the app's group ("Shepherd · 9"). Rich previews show at full width:
  Boards ready ("4 boards drawn in acme-web. 2 comments resolved.") shows its thumbnails as a row of
  86pt-tall tiles sharing the width (radius 8, 8pt apart); a board still drawing is a `.nwShimmer()`
  tile on `bgSelected`. The stuck lane keeps its stack; a planner question offers its options and
  Reply…; Host offline reads "horizon is offline", "Host", "1 automation paused until it's back."
  with Retry, its only action, drawn secondary.
- **Lock Screen** (iPadLock): no Dynamic Island on iPad. Live Activities stack in a 440pt column on
  the right (36pt from the edge, 46pt down), notifications under them, and a Shepherd widget sits
  under the clock (Lock-screen widget, below).

### On the Mac today

`AgentNotifications` posts, and `AgentBanners` words, a banner for this Mac's own agents
(`Tests/ShepherdAppUnitTests/AgentBannersTests.swift` pins the rules):

| Moment | Title | Body | Sound |
| --- | --- | --- | --- |
| A turn finished | the agent | "Agent finished" | no |
| A turn failed | the agent | "Turn failed", then the error's first line | yes |
| The agent is blocked on a question (a tool named like `ask` or `question` sets `blocked`) | the agent | "Agent needs your input" | yes |
| A subagent asks a question | the agent | "Subagent *label* needs your input", then the question's first line | yes |
| The agent's `notify` tool | the tool's title | the agent's name, then the tool's body | yes |

- **When:** a status banner posts only when a turn ends (working to done) or the agent becomes
  blocked (working to blocked); idle churn from a launch or a session restart posts nothing. Nothing
  posts while you watch that agent (it is selected and Shepherd is frontmost), except the `notify`
  tool, which always posts because the agent asked.
- **Quotes:** an error or question is cut to its first line, at most 200 characters, ending in "…"
  when cut.
- **Replacing:** an agent's own banners replace each other (one per agent). Each subagent's question
  has its own, posted once per question however often its extension republishes, and again only when
  the question changes. Every `notify` is its own.
- **Clicking** brings Shepherd forward and selects the agent (see Anatomy). Banners from the
  previous run are removed at launch, because their sessions died with it.
- **Frontmost:** banners show while Shepherd is in front, for the agents you aren't watching.
- **Permission** is asked the first time Shepherd has something to post (alerts and sound), never at
  launch. Notifications are turned on and off in System Settings ▸ Notifications; Shepherd has no
  toggle of its own. Only the `notify` tool has a switch: Settings ▸ Pi's bundled panes extension
  ("…manage automations and send notifications") carries it.
- **Not yet as the catalog says:** no subtitle and fixed phrases instead of the kind and a
  one-sentence result; no actions, Reply… or Review; no `threadIdentifier` (macOS stacks every
  banner under Shepherd); no interruption levels; a subagent's title is its agent's name rather than
  "*thread* · *subagent*"; an answered question's banner stays until it is replaced or Shepherd
  relaunches; a pi dialog (confirm, select, input, editor) that doesn't set `blocked` posts nothing;
  a remote host's agents and a lost host post nothing.

### Mac

**Not built yet** (NotifMac): the Mac follows the catalog with the Mac's own notification styles.

- **Anything that needs you is an alert,** so it stays until you act. The first action is its button
  ("Retry with hint"), and **Options** holds the rest of the choices ("Replan the lane", "Take over
  in a thread", "Open mission", "Mute this mission"). A stuck lane shows "TIME SENSITIVE".
- **Questions take a typed answer inline:** a Planner question opens a reply field with **Send**,
  and the answer goes to whoever asked.
- **Finished work is a banner** and leaves on its own: Turn finished ("Done. 3 files changed, tests
  pass.") with **Review**.
- **Stacks:** the board draws the rest collapsed as "2 more from Shepherd · Merge PR #24 after CI,
  Nightly migrations"; the catalog's rule (grouped by the thing, not the app) is the rule.
- **Every host's threads:** the board's sidebar holds another Mac's threads ("horizon"), and the
  catalog's Turn failed example ("Fix remote nightly") is one of them, so a remote host's work
  notifies on this Mac as its own does.
- **Mute** from Options ("Mute this mission"), and from a thread's or mission's ••• menu (Settings,
  below).
- **Platform limits:** macOS sets alert or banner style per app, in System Settings, not per
  notification, so "alerts for Needs you, banners for finished work" needs a decision before it is
  built. Time Sensitive needs the Time Sensitive Notifications entitlement, on the Mac as on iPhone.
- The board's backdrop (Missions, Designs, a Needs you section and Recents in the sidebar) is the
  Missions and Design tool boards', not the Mac's sidebar (Sidebar).

### Settings ▸ Notifications (iPhone and iPad)

**Not built yet** (NotifSettings). A screen pushed from Settings (its row is on the MobileSettings
board), titled "Notifications" with "Settings" as its back label. It is built like the rest of iOS
Settings: `SettingsSection` headers (`NWListHeader`; the board draws them 13pt semibold in
`textSecondary`, where `NWListHeader` draws the caption size in `textTertiary`) over
`NWListCard`s (`bgRaised`, a `lineSubtle` border, radius 12, `NW.Radius.l`), rows of `NWListRow`
height (48pt, or 56pt with a second line: the title at 15pt, the line under it at 12.5pt in
`textTertiary`), 14pt side padding, and `.nwSwitch` switches (30 × 18, lantern when on).

- **Send me** (a switch each; all four are on in the board):
  - Questions and approvals: "Planner, subagent and automation questions, plans, reviews"
  - Blocked work: "Stuck lanes and empty budgets. Can break through Focus."
  - Failures: "Failed turns, failed automations, hosts going offline"
  - Finished work: "Quietly, and in your Scheduled Summary"
- **Which device:**
  - Only when I'm away from my Mac (a switch): "Your Mac gets it first. This phone only after 2
    minutes idle."
  - Live Activities: its value ("On") and a chevron (the page it opens is not drawn).
- **Per mission and thread:** a row per mission, thread or automation (the board's third is an
  automation), each with its level as the value and a chevron: **Everything**, **Only blocked** or
  **Only failures** ("Checkout funnel events · Everything", "Refunds in the ledger · Only blocked",
  "Nightly migrations dry run · Only failures").
- **Footer** (12pt, `textTertiary`): "Mute anything from its ••• menu. Lock-screen previews follow
  iOS settings." So a thread's ••• menu (and a mission's) gets a Mute item, and Shepherd has no
  preview setting of its own.

On the Mac, Shepherd has no notification settings page today and no board draws one; only the
panes extension's switch in Settings ▸ Pi governs the `notify` tool (On the Mac today).

### Live Activities

**Not built yet** (MobileLiveLock, MobileLock, iPadLock; the Dynamic Island below). Running work
shows its progress on the Lock Screen: a thread, a thread with subagents, an automation, a mission.
A notification marks only a change that needs you, or an end (Rules).

**The card:** `bgRaised`, radius 22, padding 13 × 15, its lines 9pt apart (MobileLock's mission
card: 14 × 16 and 10pt); cards stack 8pt apart (10pt on iPad, in its 440pt column). They use Night
Watch roles and follow the device's appearance (the boards draw dark); only the island is always
dark. Sizes the iOS ramp doesn't name are set with `Font.nwSans` and `Font.nwMono` at the board's
size.

- **Header** (every card): a leading glyph, the title (14pt semibold, `textPrimary`, one line), and
  trailing meta in mono 11.5pt `textTertiary`. The glyph says what it is and how it's going: a 14pt
  spinner in `running` for a working thread, `NWBranchGlyph` (15pt) for a thread with subagents (in
  `lanternText` while one needs you), a bolt in `running` for an automation, the crook (`NWCrook`,
  15pt, in `lantern`) for a mission. The meta is the elapsed time for a thread (counting live:
  "4:12", "37m"), the host for an automation ("This Mac"), elapsed over the time budget for a
  mission ("1h38 / 4h").
- **A thread** (MobileLiveLock, iPadLock): what it's doing now (13.5pt, `textPrimary`: "Running
  tests") with the command in mono 11.5pt `textTertiary` ("swift test --filter toolPreview"); then
  its changes and where it runs (12pt, `textSecondary`: "Edited 3 files", `NWDiffStat` in mono 11pt,
  "· This Mac" in `textTertiary`); then **Steer** and **Stop**.
- **A thread with subagents** ("Restyle native UI · 3 subagents"): one row per subagent (13pt): its
  state (an 11pt spinner in `running`, the glowing 7pt `attention` dot, or a 12pt checkmark in
  `done`), its label in mono semibold (a 70pt column), then what it's doing in `textSecondary`
  ("step 1 of 3 · restyling ThreadView", "14 of 14 pass") or its question in `lanternText` ("Replace
  the old token names everywhere?"). While one asks, the buttons are its options: the first primary,
  the second secondary ("Replace everywhere", "Rename new ones").
- **An automation** ("Merge PR #24 after CI"): what it waits on (13.5pt: "Waiting for CI") with its
  progress in mono `textTertiary` ("3 of 5 checks · ~4m"); an `NWStepStrip` of 5pt segments 4pt
  apart (done, running, then pending in `lineStrong`); and what happens next (12pt, `textSecondary`:
  "Merges into main when all checks are green."). No buttons.
- **A mission** (MobileLock, iPadLock): one `NWLaneStrip` row per lane (the label in mono 11pt
  `textSecondary` in a 104pt column, a 130pt three-stop track, where it is in mono 10.5pt; the
  stuck-lane view's colors, iPhone above), 20pt rows 10pt apart (9pt on iPad). On iPhone a footer
  says what needs you and what's next (12.5pt: the glowing 7pt `attention` dot, "orders needs you"
  in `lanternText`, "· then validator, ~40m" in `textTertiary`); on iPad it has buttons instead:
  **Retry with hint** (primary) and **Open**. NWMissions names it `NWMissionLiveActivity` and
  draws it smaller (Missions: iPhone and iPad: radius 18, 12×14 padding, 8pt apart, 18pt rows,
  an 80pt label column in mono 10.5, the step in mono 10, the title at 13/600). The two boards
  disagree; settle one set of measures before building.
- **Buttons:** 34pt capsules (radius 17) sharing the card's width, 8pt apart, 13.5pt semibold.
  Secondary is `bgSelected` with `textPrimary`; Stop is `bgSelected` with `failed` text; primary is
  `lantern` with `textOnLantern`. At most one primary. **Steer** takes a message for the thread
  without opening Shepherd; **Stop** stops the turn and asks nothing (MobileIsland).

**Platform limits** to settle before building: a Live Activity can't hold a text field, so Steer
can't take text in place; a button runs an App Intent, which runs while the device is locked only if
the intent's authentication policy allows it; and an update pushed from the host can't be encrypted,
so what it carries (a command, a question's text) would cross the push relay in the clear.

### Dynamic Island

**Not built yet** (MobileIsland). Every Live Activity has three sizes. The island is always black,
so its colors don't change with the theme: text is white (the board's `#f4f5f7`) and 55% white for
secondary, buttons are 14% white, and the state colors are Night Watch's dark values (`running`,
`lantern`, `done`, `failed`). These whites are not roles yet; add them as roles before building
(Adding a theme or a role).

- **Compact** (a 36pt pill beside the camera, 12pt inside):
  - Thread: a spinner and the current command (mono 11.5pt, 55% white: "swift test"), elapsed on the
    right (mono 12.5pt semibold, `running`: "4:12").
  - Subagents: the crook and how many are running ("3", white), then a lantern dot (8pt) and how
    many need you ("1", `lantern`).
  - Automation: a bolt and "CI", and on the right an 18pt ring that fills as checks pass (`running`
    over 18% white).
  - Design agent: a pen-nib glyph and the design ("Onboarding", 55% white), boards drawn so far on
    the right ("2/4").
  - Finished thread: a checkmark in `done`, "Pushed" and the branch ("main", 55% white). It stays 4
    seconds, then the activity ends.
- **Minimal** (two at once): the newer activity keeps a compact pill (a spinner and "4:12"), and the
  older shrinks to a 36pt dot; a 9pt lantern dot in it means something there needs you.
- **Expanded** (a long press; radius 40, padding 20 × 24, lines 10pt apart):
  - Thread: a spinner, the title (15pt semibold) and elapsed (mono 12.5pt, `running`); "Running
    tests" (13.5pt) with the command (mono 11.5pt, 55%); "Edited 3 files · +67 −48 · This Mac"
    (12.5pt, 55%, the counts in `done` and `failed`); then **Steer** and **Stop** (38pt capsules,
    radius 19, 14% white, 14pt semibold; Stop's text `failed`). Steer opens a text field without
    launching the app; Stop asks nothing.
  - Subagents: the crook, "reviewer needs you" (15pt semibold) and the thread ("Restyle native UI",
    12pt, 55%); the question (13.5pt, code in mono 12pt: "Two token names collide with
    `Tokens.textSecondary`. Rename the new ones, or replace the old ones everywhere?"); its options
    as buttons, the first primary (`lantern`, `textOnLantern`: "Replace all"), then "Rename new
    ones". A subagent's question is answered in place.
  - Design agent: the pen nib, "Onboarding flow" and "2 of 4"; the boards as 62pt tiles (radius 8,
    8pt apart), filling in as they're drawn: a drawn board's thumbnail, the one being drawn
    shimmering on 12% white with a small spinner, the rest empty at 6% white; then **Open boards**.

### Lock-screen widget (iPad)

**Not built yet** (iPadLock). A Shepherd widget under the clock: counts only, and a tap opens the
Overview. 340pt wide, radius 22, padding 16 × 18, on the system's lock-screen glass (the board's 10%
white). Its header is the crook (14pt) and "Shepherd" (13pt semibold, 72% white). Three counts sit
22pt apart, each a figure (34pt semibold) over its label (12.5pt, 72% white): "4" in `lantern` over
"need you", "6" over "running", "3" over "merged today". Its last line is the hosts: "build-01 and
This Mac online · horizon offline".

### Delivery

**Not built yet.** NotifCatalog's pipeline: the host decides and sends; a push relay carries only
IDs and one line of text through Apple's push service; the device's Notification Service Extension
fetches the rich content (attempts, lanes, thumbnails) from the host, "so code never passes through
the relay". Its payload carries the title, subtitle and body, the category, the `thread-id`, the
interruption level, a relevance score, `mutable-content`, and the host and station. The board names
a host daemon (`shepherd-d`) that Shepherd doesn't have: sessions live in the app (AGENTS.md), so
the app is what sends.

**Previews:** when these are built, each surface gets a preview render like every other: the Live
Activity cards and the island's sizes, the iPad widget, Settings ▸ Notifications, and the rich
views, in both appearances (the island in dark only).

## Missions

**Not built yet.** Missions carries one goal across every repo it touches, from a sentence to merged
PRs, as a map you supervise. It is designed on the canvas's Missions page (MX* boards), the Night
Watch system pages "Missions map" (MXVocab, MXVocabLight) and "Mission screens" (NWMissions,
NWMissionsLight), the Mac's Missions destination (NavMissions), and the phone and iPad boards
(MobileMissions, MobileMission, MobilePatch, MobileMerge, iPadMissions, iPadMissionMap,
iPadMissionReview). It is planned for after the native app is stable: build it only when asked, and
then build it to this section.

What exists today is data, not UI:

- `Extensions/shepherd-missions.ts` keeps mission records for native subagents and workflows
  (`shepherd_mission`; [docs/native-subagents.md](docs/native-subagents.md) › Missions): a title,
  objective, status, runs and attachments per project. Nothing draws them, and none of the map's
  ideas (lanes, stations, the contract, the train) map onto them.
- pi's `/missions` command (native subagents) prints those records as text, and Settings ▸ Pi's
  Native subagents subtitle mentions "durable missions". Nothing else in the app says mission.
- Parts a mission reuses are built: a station's transcript and steer field are the subagent
  inspector's (Side pane), its worktree is `GitWorktree`'s, a merge builds on Finalize
  ([docs/worktrees.md](docs/worktrees.md)), and the review gate is drawn with the review pane's
  parts (`NWFileHeader`, `NWDiffView`, `NWHunkHeader`, `NWInlineComment`).

Strings in this section are the boards' own, except "Pi" ("own Pi session"): the app spells it "pi"
today (the Queue & steer departure records that for its redesign; confirm it for missions before
building). The boards place every mission on a host "daemon"; Shepherd has no daemon today
(AGENTS.md), so where a mission runs is still to be decided.

### Missions: how a mission runs

A mission moves through four phases, Goal → Map → Run → Done (`NWPhaseBar`). MXFlow draws its steps
top to bottom in stages (Start, Describe, Draft, Review, Clear the fog, Launch, Run, Verify, Review,
Land, Done) and four actors, drawn as columns: **You** ("you decide, answer, approve"), **Shepherd**
("planner + validator, on the daemon"), **Workers** ("one Pi session per station"), and **Repos &
CI** ("branches, checks, PRs"). Lantern marks the only steps where you act; everything else runs on
the host without you.

1. **Start a mission** (you): ⌘K → New mission, Missions ▸ New mission, `/mission` in any thread, or
   paste a ticket or pick a saved map. Every way in opens the same planner chat.
2. **Say where you want to end up** (you): one message, like to any agent; a ticket or spec is
   optional. Answer its scope questions in the same chat.
3. **Planner builds the brief**: reads the ticket and linked docs, searches your repos to pick the
   lanes, gathers context, sizes the limits; the validator drafts the contract alongside. It only
   asks what changes the scope; everything else becomes fog on the map.
4. **Planner drafts the map** ("Draft the map"): one lane per repo; stations, checks, forks, the
   merge order. Anything it can't decide becomes fog, with a question or research station on its
   edge.
5. **Research starts right away**: research stations are read-only sessions (code, docs, registries;
   no branches, no code).
6. **Review the map** (you): rewire stations, change a model or a budget, bypass a station, or ask
   the planner in words ("split orders into outbox + relay stations").
7. **Answer the questions** (you): only the decisions that need you, on the edge of the fog.
8. **Answers become patches**: real stations replace the fog. Apply one, edit it, or let fog patches
   apply on their own within budget.
9. **Launch** (you): leftover fog is fine; known ground runs while fog clears ahead of it. From
   here you can walk away.
10. **Lanes spin up**: per station, a worktree on a mission branch in its repo (`orders-svc @
    mission/anl-214`) and its own session that gets only its inputs.
11. **Stations do the work** until their own "done when" passes, then hand off outputs (a branch, a
    tag, a summary). One at a time, except where the map forks.
12. **Station checks**: a command after each station (`buf`, `go test`). Pass → next station; fail →
    back to the worker, up to 2 retries; still failing → pause.
13. **Validator runs the contract** after the join: builds the e2e stack from every branch, seeds
    it, runs the hidden checks.
14. **Route the findings**: all pass → your review; a finding with an owner → back to that station,
    automatically; no owner → off the map.
15. **Off the map** (you): the mission pauses and the planner proposes a patch; re-runs follow the
    data wires. Apply it and the mission resumes.
16. **Review the PR set** (you): one review across every repo, with the validator's evidence.
    Approve, or send changes; they go back as findings.
17. **Merge train**: PRs merge one by one in dependency order, each waiting for its CI; tags are cut
    on the way (`contracts #412` → `v1.8.0`).
18. **Done**: the route taken, the contract (now visible), merge order and spend per repo, and Save
    as map template.

Shepherd interrupts you for four things only: **a question** (a decision on the fog's edge only you
can make), **a patch** (fog cleared, or the run left the map), **a stuck station** (still failing
after its retries, or out of budget), and **the final review** (approve the PR set before anything
merges). During the run, all you do (MXInputs) is answer questions, apply patches (or let fog
patches auto-apply), steer a station if you want to ("use the existing outbox"), and approve the PR
set. What you no longer do (MXFlow): write code, babysit agent threads, copy context between
repos, open or merge PRs by hand, decide merge order.

**What you put in** (MXInputs): one message about where you want to end up, optionally a ticket or a
file. There are no forms: the planner builds the brief, and you change anything by saying so.

| In the brief | How the planner gets it | To change it, say |
| --- | --- | --- |
| Destination | Rewritten from your message and the ticket | "also track refunds" |
| Lanes | Searches your repos for owners, producers and consumers; asks if the scope is ambiguous | "add payments-svc" |
| Context | The ticket and linked docs, the relevant protos and schemas, each lane's README and AGENTS.md | drop a file in the chat |
| Validation contract | A validator agent drafts it from the goal and the code; hidden from workers | "also check p99 latency" |
| Test environment | Reuses what the repos already have and extends it to the other lanes | "use staging instead" |
| Size & limits | Estimated from the lanes and checks, with headroom ("~4.1M · ~3h → limits 6M · 4h · 3 forks") | "cap it at 3M" |
| Host | Your default host | "run it on this Mac" |
| Models | Planner and validator on your default; the planner picks per station | "use opus for orders" |
| Open questions | Asked in the chat only if they change the scope; the rest become fog | answer now or on the map |

Each station also carries, editable in the map's inspector: **Goal** (what it must achieve in its
own repo), **Model** (overrides the mission default), **Inputs** (data wires in: a branch, a module
version, a spec), **Outputs** (data wires out: branch, tag, summary), **Exits** (where pass, fail
and budget go), **Done when** (checks the worker can see and run), **Budget** (tokens and time), and
**Bypass** (skip it without deleting it).

### Missions: getting there

**Not built yet.** Missions live in the same window and sidebar as threads, and every station is a
thread you can open (MXNav):

- **The sidebar's Missions destination** opens every mission (running, drafts, done) with New
  mission at the top right, and opens where the thread was. It sits in the boards' destination list
  (New thread, Missions, Designs, Automations, More), which the Mac's sidebar does not have (see
  Sidebar).
- **Needs you**, under the destinations, pins a mission (or a thread) waiting on you with its
  question ("retention?" in `lanternText`, mono 10) until you answer.
- **⌘K** from anywhere (the sidebar has no field; the palette is keyboard-first): "New mission…",
  or part of a mission's name to jump to it.
- **`/mission`** in any thread ("Turn this thread into a mission") hands the conversation to the
  planner: you land in its chat with the brief already started. `/missions` is "Open Missions". pi's
  native subagents runtime already registers a `/missions` that prints records; the two must not
  collide.
- **The thread's ••• menu** gains "Turn into mission…" (a 13pt symbol), the same as `/mission`.
- **A notification** for a mission opens the station that asked, even if the app was closed (the
  Mac banner: the crook, "Checkout funnel events needs you", "retention: raw events for 30 days or
  13 months?", "now"). Everything that doesn't need you stays in Recents.

Three places, one hop apart (MXNav › Moving between the three places): a **thread**, headed by its
space and title ("Shepherd / Investigate SwiftUI…"); the **mission** (click it in the sidebar; ⌘[
goes back), headed "Missions / Checkout funnel events", where the sidebar tucks away to give the map
room and ⌘0 brings it back; and a **station thread** (Open as thread, at the foot of a selected
station's inspector), the station's own session shown like any thread, whose breadcrumb ("Checkout
funnel events › orders", the mission in `lanternText`) returns to the map and whose composer is the
station's steer field ("Steer orders…"). ⌘0 is the boards' chord; the app's show-sidebar chord is
⇧⌘S (Keyboard), and a new chord goes through `KeybindingsStore` like every other.

**The Missions page** (NavMissions: header, state tabs, and the Mission · Lanes · Route · Spend ·
Host table) is specified under Destination pages › Missions page; build it from there. Its
Templates tab is below (Missions: templates). A mission's glyph is a folded map (14pt on the Mac,
`lanternText` while it needs you, else `textSecondary`; 15pt on iPhone and iPad).

**Mission states** and the words their pill says (`NWStatusPill`; lantern pills glow):

| State | Pill | Color |
| --- | --- | --- |
| New, before the first message | New | outlined, `textTertiary` dot |
| Waiting on you, in a list (Missions page, iPhone, iPad) | Needs you | attention |
| The planner is working | Planning | running |
| The planner is asking | Planning · 1 question | attention |
| Map drafted, not launched | Draft | outlined |
| A patch waits for you | Patch ready | attention |
| Running | Running | running |
| A lane is stuck, or held by a lock | Running · 1 lane stuck, Running · 1 lane held | attention |
| Paused | Paused · off the map, Paused · out of budget | attention |
| The PR set waits for you | Review · needs you | attention |
| The train is merging | Merging · 2 of 4 | running |
| Finished | Done (Merged in lists) | done |

### Missions: chrome and phases

**Not built yet.** Every Mac mission screen shares one header, `NWMissionHeader(mission)`
(NWMissions › Mission chrome): where you are, which phase, what it has spent, where it runs, and the
one action that fits the state.

- **52pt** on `bgWindow` with a hairline beneath, 10pt leading and 12pt trailing padding, 12pt gaps.
  Leading: a 28pt sidebar button (every mission board draws it, docked sidebar or not), then the
  breadcrumb: a 14pt folded-map glyph and "Missions" in 13 `textTertiary`, "/", the mission's name
  in 13/600 ("New mission" before it has one), and its state pill.
- **Centered: `NWPhaseBar`** (`.goal`, `.map`, `.run`, `.done`), items 24pt tall, 9pt padding,
  radius 6, 2pt apart with a 9pt chevron in `textTertiary` between: a finished phase has an 11pt
  check in `done` and its word in 12/500 `textSecondary`; the current one sits on `bgSelected`,
  12/600 `textPrimary`, its number in mono 10 `lanternText`; a later one is `textTertiary` with its
  number in mono 10. Review and the merge train are part of Run.
- **Trailing** (14pt gaps): the meters once the mission runs (the Map phase shows an estimate
  instead, mono 11 `textTertiary`: "est. 4.1M of 6M · 3h10 of 4h"), the host chip, and the one
  action:

| State | Action |
| --- | --- |
| New, Planning, Review, Done | none |
| Draft, Patch ready | **Launch** (primary, a 13pt symbol, ⌘⏎) |
| Running, stuck, held | **Pause** (secondary, a 13pt symbol) |
| Paused | **Resume** (secondary, disabled at 40% until the pause is resolved) |
| Merging | **Pause train** (secondary) |
| While the Stop dialog is up | **Stop** (`.danger`, drawn pressed on `bgSelected`) |

**`NWBudgetMeter(.tokens | .time, used:, cap:)`**, 92pt wide: a mono 10 line ("tokens" in
`textTertiary`, then "2.3M" in `textSecondary` and "/ 6M" in `textTertiary`), 3pt under it a 3pt
bar, radius 2, on `lineSubtle`. The board's rule is "neutral, then lantern past 80%, red at the
cap"; the screens fill it `running` while the mission runs, `lantern` while it is paused for you,
`failed` at the cap, and `done` once finished. On the phone the bar is 4pt with the value in
`textPrimary`.

**`NWHostChip(host)`**: 24pt, 8pt padding, radius 6, a `lineSubtle` border, a 12pt host symbol, the
name in mono 11.5 `textSecondary`, and a 5pt `done` dot (no board draws another state). ShepherdUI's
`NWHostBadge` (a smaller mono chip with no symbol or dot) is the row-sized relative.

Mission screens hide the sidebar to give the map room; New mission, intake, starting from a template
(MXTemplateStart) and the Templates tab keep it docked.

### Missions: the map

**Not built yet.** The map (MXVocab, MXVocabLight) is drawn with stations, wires, lanes and fog,
laid out automatically top to bottom. You change the logic, never the positions.

**Stations.** Every station has a kind, a lane (its repo) and a state. Decisions are diamonds,
because they end in labelled outcomes rather than work.

- **Work stations** are 190×44 cards, radius 8, `bgRaised` with a 1px `lineStrong` border, 8pt gaps,
  9pt leading and 10pt trailing padding: a 22pt symbol box (radius 6, `bgSunken`, `lineSubtle`
  border, a 12pt symbol) and two lines, the name in mono 12/600 over a 10.5 `textTertiary` subtitle,
  with an optional trailing mark.
- **Decisions** draw a dashed border and, in place of the box, an 18pt diamond (a square turned 45°,
  radius 3, `bgSunken`, `lineStrong` border) holding a 10pt symbol.

| Kind | Call site | Drawn as | Example |
| --- | --- | --- | --- |
| Agent | `NWStation(.agent(role: .worker), name: "orders")` | work station; a trailing estimate in draft | "orders", "worker · fable-5-1", "~900k"; its own session and worktree in its lane's repo |
| Check | `NWStation(.check("go test ./..."))` | 172×32, radius 6, `bgSunken`, `lineStrong` border, a 12pt terminal symbol, the command in mono 11 `textSecondary` | a command; its exit code picks the edge |
| Contract | `NWStation(.contract(mission.contract))` | work station | "validator", "e2e · 11 hidden checks"; workers only get findings |
| Merge | `NWStation(.merge(pr: 318))` | work station | "merge #318", "orders-svc"; one per repo, chained in dependency order |
| Research | `NWStation(.decision(.research))` | decision | "event-audit", "research · find sources"; runs without you and clears fog with evidence |
| Question | `NWStation(.decision(.question))` | decision with a dashed `lantern` border, a 3pt `lanternTint` halo and a glowing 7pt lantern dot | "retention", "you · 30d or 13 mo?"; glows until you reply |
| Prototype | `NWStation(.decision(.prototype))` | decision | "rollups", "prototype · 2 options"; builds throwaway options to pick from |
| Gate | `NWStation(.gate)` | work station, its symbol in `lanternText` | "review", "you · approve 4 PRs"; you approve or send changes back |
| Sub-map | `NWStation(.submap(template))` | work station with a second card (`bgSunken`, `lineStrong`) peeking out 4pt up and to the right | "registry", "map · Buf registry"; a saved map used as one station |
| Start | `NWTerminus(.start(mission.goal))` | 176×44, a 22pt circle with a 1.5pt `textSecondary` ring | "goal", "ANL-214 · 4 repos"; top of the map, holds the goal and inputs |
| Destination | `NWTerminus(.destination)` | 200×44, a 22pt circle with a 1.5pt `textPrimary` ring | "merged in order", "funnel live in analytics"; reached only when the contract passes |
| Fork / Join | `NWForkBar(lanes: 1...4)`, `NWJoinBar(.all)` | a 4pt bar, radius 2, across the lanes it spans, labelled at its right end in mono 10 `textTertiary` ("fork", "join · all") | parallel work only happens where a fork is drawn; a join waits for all (or any) |

**Station states** (`.stationState(_:)`). Color only ever means state: blue moving, green done, red
failed, lantern needs you.

| State | Border and halo | Name | Trailing mark |
| --- | --- | --- | --- |
| `.draft` | `lineStrong` | `textPrimary` | the estimate, mono 10 `textTertiary` ("~900k") |
| `.queued` | `lineStrong` | `textSecondary`, symbol `textSecondary` | a 7pt hollow ring, 1.2pt `textTertiary` |
| `.running` | `running`, 3pt `runningTint` halo | `textPrimary` | a 12pt spinner in `running` |
| `.done` | `lineStrong` | `textSecondary`, symbol `textSecondary` | a 13pt check in `done` |
| `.failed` | `failed`, 3pt `failedTint` halo | `textPrimary` | an 11pt xmark in `failed` |
| `.needsYou` | `lantern`, 3pt `lanternTint` halo | `textPrimary` | a glowing 7pt `lantern` dot |
| `.notTaken` | dashed `lineStrong`, the card at 42% | as it was, symbol `textSecondary` | as it was (the estimate stays); the route stays drawn |
| `.patchAdded` | dashed `done` on `bgWindow`, 3pt `doneTint` halo | `textPrimary` | "NEW" in mono 10/600 `done`; dashed green until applied |

- **Selected** (`.stationSelected(true)`): a neutral ring outside the state's border, 2pt of
  `bgWindow` then 1.5pt of `textPrimary`. Color stays reserved for state; lanes, kinds and selection
  are neutral.
- **Paused at a checkpoint** (MXBudget): a 1px `lantern` border, no halo.
- **A resolved decision** keeps its dashed border, turns its name `textSecondary`, shows the done
  check, and carries its outcome as a small chip on its top-right corner: 15pt, 5pt padding, radius
  4, `bgWindow`, a `lineStrong` border, mono 9.5 ("registry ✓", "13 mo" in `lanternText`). The same
  chip marks other facts on a station: "retry ×1", "1 of 11 failed" in `failed`, "patched" in
  `done`, "from fog", "re-run", "learned" in `lanternText`, the time on the destination ("2h58").

**Flow wires** (`NWFlowWire`). Flow is geometry: orthogonal lines with 10pt corners, round caps.

| Wire | Stroke |
| --- | --- |
| `.upcoming` | 2pt `lineStrong` |
| `.travelled` (with its outcome) | 2pt `textSecondary` at 75% |
| `.moving` (into a running station) | 2pt `running`, dashed 6/3, the dash advancing 18pt every 0.9s |
| `.notTaken` | 1.5pt `lineStrong` at 80%, dashed 3/4; kept on the map after the run |
| `.patch` | 2pt `done`, dashed 5/4 |
| `.retry(max: 2)` | 2pt `textSecondary` at 75% (drawn as travelled), from a check's side back up into its station's side with 9pt corners, and a chevron head (1.8pt); the only wire that goes up |

A fork or join bar takes its wire's color: `lineStrong` ahead, `textSecondary` once travelled,
`done` in a patch.

**Outcome chips** (`NWOutcomeChip(.fail(retry: 2))`) label every edge out of a check, decision or
gate: 18pt, 5pt padding, radius 4, `bgWindow`, a `lineSubtle` border, mono 10.5. `done` for "pass"
and "all pass"; `failed` for "fail", "fail · retry ≤2", "findings", "findings → owner", "no owner";
`textSecondary` for neutral results ("registry ✓", "none", "no"); `lanternText` for your answers and
gates ("13 mo", "approve", "changes", "key"); `wireData` with an 8pt pin for data ("events
v1.8.0-rc.1").

**Data wires and pins.** Data is string: a dashed bezier in **`wireData`**, 1.5pt, dashed 4/3 at
90%, leaving an output pin and entering an input pin (3.2pt circles filled `bgWindow` with a 1.5pt
`wireData` stroke). They are drawn for the selected station, or all of them in the Data view.
Re-runs follow data wires, so a contract change re-runs exactly the stations that read it. Call
site: `NWDataWire(from: buf.out(.events), to: orders.in(.events))`.

- **`wireData` is a new role**: `#d7a6ff` dark, `#8a3fb5` light (the syntax keyword colors). Add it
  the way "Adding a theme or a role" says.
- **`NWPinRow(pin)`** in the inspector: 28pt, radius 6, 6pt padding, a 10pt pin glyph, the name in
  mono 12/600, its type in mono 10.5 `wireData`, a spacer, the source or target in mono 11
  `textTertiary` ("← buf", "→ validator, #318"), and the value in mono 11 `textSecondary`,
  truncating at 150pt ("v1.8.0-rc.1", "none yet"). Inputs on the way in, outputs on the way out.
- **Pin types** (`enum PinType { case gitRef, goModule, … }`), each a 22pt chip (8pt padding, radius
  4, `lineSubtle` border, mono 11, an 8pt glyph): git ref, go module, proto package, doc, summary,
  findings, test output, migration, PR.

**Lanes, fog and frontier.** One lane per repo, the mission's own lane first. Fog covers what isn't
decided yet; the decision on its edge is the frontier.

- **`NWLane(repo:)`**: columns 218pt apart on the full map, divided by dashed 1px `lineSubtle`
  verticals. Each head is the repo in mono 11/500 `textSecondary` after a 12pt repo symbol in
  `textTertiary`, over its stack in mono 10 `textTertiary` ("buf · protos", "go · kafka → pg", "go ·
  grpc · outbox"). The mission lane reads "mission" and "orchestration", both tertiary. Cross-lane
  wires are the hand-offs between services.
- **`NWFog(reason:)`**: a dashed `lineStrong` region, radius 12, on `bgSunken` hatched at 135° with
  1px `lineSubtle` lines every 7pt, 8pt padding: an 18pt cloud in `textTertiary`, "Undecided" in
  12/600 `textSecondary`, and the reason in 11 `textTertiary` ("storage layout, partitions and
  rollups follow from retention"). A patch replaces it once the decision above it is resolved.
- **`NWFrontierChip(mission.frontier)`**: 26pt, 10pt padding, radius 6, `bgWindow`, a `lineSubtle`
  border, 11.5 `textSecondary`: "FRONTIER" in mono 10 tracked `textTertiary`, then "1 researching"
  (a 10pt spinner), "1 needs you" (a glowing 6pt lantern dot), "1 undecided" (a 12pt cloud). What is
  moving, what needs you, what is still fog.

**Rules** (the board's own):

- **The map grows downward.** Patches append new stations below; they never rewrite what already
  ran.
- **Flow is geometry, data is string.** Rigid orthogonal wires for control, soft beziers for
  hand-offs.
- **Color means state, nothing else.** Lanes, kinds and selection are all neutral.
- **Only retries go up.** Every other route reads top to bottom, in time order.
- **Off the map means pause.** When no route covers a finding, the mission stops and proposes a
  patch.
- **Workers never see the contract.** Only the validator reads the checks; stations get findings.

**The map canvas** (MXMap and every full-map screen): `bgWindow`, with an overlay bar 14pt from the
top and 16pt from the sides (8pt gaps): `NWSegmentedPicker` (small) **Flow | Data | Both**; a 1×18
`lineSubtle` divider; a zoom group (26pt, radius 6, `lineSubtle` border: zoom out, "100%" in mono
10.5 `textSecondary` 34pt wide, zoom in, as 22pt icons); **Fit map** (a 26pt circle with a
`lineStrong` border); a spacer; and the frontier chip, or the screen's own status chip in its place.
A legend sits 16pt from the bottom-left in mono 10.5 `textTertiary`, 14pt apart, showing only the
marks on screen: flow (a 2pt `textTertiary` stroke), data (a `wireData` bezier), undecided (a 16×10
hatched swatch), patch, not taken.

### Missions: shared parts

**Not built yet.** Mission screens are built from these parts (NWMissions), besides the map.

**The inspector** (a right column, 440pt; 520pt for the brief and Save as template) on `bgWindow`
with a hairline on its leading edge:

- **Header**, 14pt top and bottom, 18pt leading and 12pt trailing padding, a hairline beneath: a
  28pt symbol box (radius 7, `bgSunken`, `lineSubtle` border, a 14pt symbol in the state's color:
  `done` for a patch or Done, `failed` off the map, `lanternText` when it waits on you), the title
  (a station's name in mono 15/600, anything else in Geist 15/600) with a kind tag (18pt, 6pt
  padding, radius 4, `lineStrong` border, mono 10.5 `textSecondary`: "agent", "clears fog", "2 of 4
  merged"; `failed` or `lanternText` for "paused 11:46") and a live station's pill ("Running · 14m",
  "Stuck · 3 tries"). Its second line is 11.5 `textTertiary`: "lane" and a lane chip (20pt, 7pt
  padding, radius 4, `bgSunken`, `lineSubtle` border, an 11pt repo symbol, mono 11 `textSecondary`),
  or a sentence ("proposed by planner · claude-opus · 10:42", "1 of 11 contract checks failed ·
  nothing is running"). Trailing: ••• and close, 28pt icons.
- **Sections**, 16pt/18pt padding with a hairline between: a label in mono 10.5/500 caps tracked 5%
  `textTertiary`, then an optional note in 11 `textTertiary` on the right ("data wires in", "re-runs
  follow the data wires").
- **Fact rows**, at least 28pt, 12.5: the label 104pt wide in `textSecondary`, the value in mono 12
  with an optional mono 10.5 `textTertiary` note. A cost reads "4.1M → 4.8M of 6M": the old value
  and the arrow in `textTertiary`, the new one in `textPrimary`, the cap in `textTertiary`.
- **Change rows**, at least 28pt: a mono 600 mark in a 14pt column (`+` in `done`, `−` in `failed`,
  `↻` in `running`, `=` in `textTertiary`), the name in mono 600 (`textTertiary` for `=`), a
  description in `textSecondary`, and a meta in 11 `textTertiary`.
- **Log rows** ("Decisions so far", "Log"), at least 26pt, 12: the time in mono 10.5 `textTertiary`
  38pt wide, the subject in mono 600, "→" in `textTertiary`, the result in `textPrimary`, and who
  did it in 11 `textTertiary` ("research · 4m", "you", "auto · rule", "someone else").
- **Footer**, 12pt/14pt padding with a hairline above, 6pt gaps (10pt/14pt with 24pt buttons in the
  station inspector): ghost actions first, a spacer, then secondary actions and the one primary,
  which shows "⌘⏎" in mono 10.5 at 60% after its label. A destructive action (Stop mission) is
  `.buttonStyle(.nw(.danger))` (bordered, `failed` text), on the leading side.

**Asking you.** A mission only stops for you with a question or a short list of choices, and one of
them is always the planner's pick. None of this is a permission prompt.

- **`NWChoiceCard(option, isPicked:)`**: 11pt/12pt padding, radius 8, 10pt gaps, a `lineSubtle`
  border: a 14pt radio (1.5pt `lineStrong` ring on `bgRaised`; when chosen, a `lantern` disc with a
  6pt `textOnLantern` center), then the title in 13/600, tags, and a meta in mono 10.5
  `textTertiary` ("~150k · 10m", "+1 station · ~350k · 25m", "7M cap"), over a description in
  12/1.45 `textSecondary`. The chosen card has a `lanternText` border on `lanternTint`. The
  planner's pick carries "planner's pick" (16pt, 5pt padding, radius 4, a `lanternText` border, mono
  9.5 `lanternText`); the chosen retry holds its hint as an editable field (8pt/10pt padding, radius
  6, `bgRaised`, `lineStrong` border, 12.5/1.5).
- `NWChoiceCard(option, risk: .high)` turns the meta `failed` ("likely conflict").
- `NWChoiceCard(option).disabled(true)` stays visible at 45% with "not possible" as its meta and the
  reason as its description ("The contract needs this lane.").
- **The mission's question card** (`NWQuestionCard(question)` on the board; ShepherdUI already has
  an `NWQuestionCard` for the phone's agent questions, so this one needs its own name): 14pt/16pt
  padding, radius 10, `bgRaised`, a `lanternText` border while unanswered (`lineSubtle` once
  answered), a 15pt question symbol in `lanternText`, the question in 13.5/600, why it matters in 12
  `textTertiary` ("Changes the contract."), and the offered answers as secondary buttons with a
  ghost "Something else…". Answered, the chosen answer becomes a `lanternTint` pill with a
  `lanternText` border and a check, and the others fade to 40%.
- **`NWPlannerNote(note)`**, the planner's diagnosis above the choices: 12pt/14pt padding, radius 8,
  `bgSunken`, `lineSubtle` border; a header in 11.5 `textTertiary` with a 12pt symbol ("Planner's
  read · claude-opus · 11:52") over 13/1.55 text (13.5 in a station's tab).

**When a lane struggles**: enough evidence to decide without opening a transcript.

- **`NWAttemptRow(attempt)`**: 12pt vertical padding, a hairline above, 12pt gaps: a 22pt circle
  with the number in mono 11, border and number `failed`; then "Attempt 1" in 12.5/600 with mono 11
  `textTertiary` meta ("11:14 · fable-5-1 · 612k"), what it tried in 12.5 `textSecondary` with its
  diff stat, and its failure in a mono 11.5/1.55 block (11 on NWMissions; 7pt/10pt padding, radius
  6, `failedTint`, "--- FAIL" in `failed`). A repeat of the same failure collapses to its summary
  line with a "same failure" tag (18pt, `lineStrong` border, mono 10.5 `failed`).
- **`NWCheckpointRow(station)`**, a station paused at a turn boundary, committed and resumable: at
  least 32pt, 12.5: an 11pt pause symbol in `lanternText`, the station in mono 600 (96pt), its lane
  in mono 11 `textTertiary` (116pt), "turn 14 · clean at `a1f3c9e`" in `textSecondary`, and its
  spend in mono 11 `textTertiary`.
- **`NWSpendBar(lane, used:, planned:)`**: at least 26pt, 12: the lane in mono `textSecondary`
  (120–128pt), an 8pt track (radius 4, `lineSubtle`) filled `textTertiary` up to the plan and
  `lantern` beyond it, the plan marked by a 2×16 tick in `textPrimary` at 70%, and the value in mono
  11 (`lanternText` when over, "/ 1.3M" in `textTertiary`). A legend under the bars: "planned" (the
  tick) and "over plan" (a 12×6 lantern swatch).

### Missions: intake

**Not built yet.** **New mission** (MXStart) asks one question. The sidebar stays docked with
Missions selected; the header reads "Missions / New mission" with an outlined "New" pill, the phase
bar on 1 Goal, and the host chip alone.

- The column (40pt side and 60pt bottom padding, 28pt gaps): "Where do you want to end up?" in
  26/600 tracked −2%, over 13.5/1.55 `textSecondary` at most 560pt wide: "Describe the end state,
  like you would to any agent. The planner finds the repos, the context and the checks, and only
  asks what it can't work out."
- **The goal field**: 720pt wide, radius 10, `bgRaised`, focused (a `textTertiary` border and the
  composer's 3pt `bgSelected` ring); the field in 14.5/1.5 with 16pt padding, at least 76pt tall
  ("Add checkout funnel analytics so product can see drop-off at every step…"); under it an attach
  button (28pt, labelled "Attach a ticket, spec or screenshot") and Send (a 30pt lantern circle, at
  35% until there is text).
- **"OR START FROM"** (mono 10.5 tracked `textTertiary`), then a row of cards, 10pt apart, each
  12pt/14pt padded, radius 8, a `lineSubtle` border, `bgHover` on hover: a 13pt symbol and the name
  in mono 12/600, a line in 12.5 `textPrimary`, and a meta in 11 `textTertiary`. A ticket
  ("ANL-214", "Checkout funnel analytics", "assigned to you · Linear"), a thread ("continue from
  this thread", "thread · 42m ago"), a saved map ("Contract change", "protos → producers →
  consumers", "saved map · used 3×").

**Planner intake** (MXGoal): you chat, the brief builds itself. The pill reads "Planning".

- **The chat** (26pt top and 36pt side padding, at most 720pt, 14pt gaps) is a thread: your message
  as `NWUserBubble`; the planner's work as activity lines ("Read ANL-214 · 2 linked docs", "Explored
  7 repos · search 14 · read 22 · 48s"); prose at 13.5/1.6, at most 680pt, with inline code; and a
  scope question as the mission's question card. The composer card sits below (12pt/36pt/18pt
  padding): 720pt, radius 10, `bgRaised`, `lineStrong` border, "Reply to the planner, or tell it
  what to change…", attach and Send.
- **The brief** (a 540pt column): a header (14pt/18pt padding) with "Mission brief" in 15/600 over
  "built by the planner as you talk · click anything to change it" in 11.5 `textTertiary` after a
  10pt spinner while it builds. Then its sections (14pt/18pt padding, a hairline between; the label
  in mono 10.5/500 caps tracked 5% `textTertiary`, its source on the right in mono 10.5
  `textTertiary`):
  - **Destination** ("from your message + ANL-214"): 13.5/1.55 with inline code.
  - **Lanes · 4 repos** ("found by searching producers and consumers"): rows at least 30pt, radius
    6, 6pt padding, 12.5, hover `bgHover`: a 12pt repo symbol, the repo in mono 600 (132pt), its
    role in `textSecondary` ("emits OrderPlaced via outbox"), and its branch in mono 10.5
    `textTertiary` ("main"). A lane left out stays listed at 55%, its name struck through, with why
    ("out: you said checkout and orders only").
  - **Context** ("5 found"): chips 24pt, 8pt padding, radius 6, `lineSubtle` border, 11.5: an 11pt
    symbol, the name in mono, the kind in 10.5 `textTertiary` ("ticket", "linked", "× 4").
  - **Validation contract** ("validator · hidden from workers"): rows at least 26pt, 12, an 11pt
    symbol in `textTertiary` and the check, with its kind in mono 10.5 `textTertiary` ("cmd"); then
    "8 more · still reading analytics-ingest" in `textSecondary` after an 11pt spinner, and where it
    runs in 11.5 `textTertiary` ("Runs in `compose.e2e.yml` from analytics-ingest, extended with
    checkout + orders").
  - **Size**: fact rows for Estimate ("~4.1M tok · ~3h"), Limits ("6M · 4h · 3 forks", "sized from 4
    lanes") and Runs on ("build-01", "your default").
  - **Still open**: a 13pt cloud in `textTertiary`, the decision in mono 600, the question in
    `textSecondary`, and "becomes fog on the map" in mono 10.5 `textTertiary`.
  - **Footer**: "Nothing writes code until you launch." in 11.5 `textTertiary`, and **Draft the
    map** (primary, ⌘⏎).
- The planner asks only what changes the scope; an answered question stays in the chat as the chosen
  pill. Clicking anything in the brief changes it by telling the planner.

### Missions: map, patches and the run

**Not built yet.** From the Map phase on, the sidebar is hidden and the screen is the map canvas
beside the inspector.

**Map** (MXMap): the pill reads "Draft", the header shows the estimate and **Launch**.

- The canvas shows the frontier chip, and at its bottom-right an ask field: 440pt, 40pt tall, radius
  8, `bgRaised`, a `lineStrong` border and the popover shadow, a 13pt symbol, "Ask the planner to
  change the map…" in 13 `textTertiary`, and a 28pt Send.
- **The station inspector**: Goal (13/1.55); Runs as (Session "own Pi session"; Model and Host as
  `NWPopupMenu`s in mono 12, "claude-fable-5-1", "build-01"; Worktree in mono 11.5 `textSecondary`,
  "orders-svc @ mission/anl-214"); Inputs ("data wires in") and Outputs ("data wires out") as pin
  rows; Exits ("flow wires out"): rows 28pt, an 18×8 arrow in `textTertiary`, an outcome chip
  ("done", "failed", "budget"), the target in mono 600 ("go test ./...", "retry ×2", "pause") and a
  note in 11 `textTertiary` ("then pause for a patch", "at 900k"); Station done when ("the worker
  sees these"): 14pt checkboxes, 12.5; Budget: Tokens and Time as `NWStepper`s ("900k", "40m"). Its
  footer: **Bypass** and **Remove station** (ghost, 24pt), a spacer, **Duplicate to lane…**
  (secondary, 24pt).
- Research stations start as soon as the map is drafted.

**Fog clears** (MXPatch): your answer becomes a patch on the map. The pill reads "Patch ready"
(glowing); Launch stays, the estimate updates.

- The map previews the patch: new stations in `.patchAdded`, the answered decision resolved with its
  outcome chip ("13 mo"), a bypassed route in `.notTaken`. The status chip reads "Previewing patch ·
  +2 stations · fog cleared" (26pt, radius 6, a `done` border on `doneTint`, a 12pt symbol in
  `done`, the detail in mono 10.5 `done`); the legend shows flow, patch, not taken.
- **The patch inspector**: "Patch" with the tag "clears fog"; Decision it resolves (the decision in
  mono 600 with its question in `textSecondary`, then your answer as a bubble, 10pt/12pt padding,
  radius 8, `bgBubble`, `lineStrong` border, 13/1.5, headed "You · 10:41" in 11 `textTertiary`);
  What changes (change rows); Why this shape (12.5/1.55 `textSecondary`); Cost; Decisions so far.
  Above the footer, a row (12pt/18pt padding) with "Apply fog patches automatically when they fit
  the budget" in 12 `textSecondary` and a switch. Footer: **Reject** (ghost), **Edit on map**
  (secondary), **Apply patch** (primary, ⌘⏎).

**Run** (MXRun): a mini-map beside the live station. The pill reads "Running", the meters fill in
`running`, and the action is Pause.

- **The left column** (640pt): the mini-map, 554pt tall with a hairline beneath: stations at 112×28
  (radius 6, 16pt symbol boxes at radius 5, 12pt diamonds, names in mono 10.5/600), checks at 112×22
  (mono 10), lanes 124pt apart with heads in mono 9.5/500, and an "Open full map" icon (24pt) in a
  bottom corner. Under it:
  - **Frontier** ("3 moving"): rows 30pt, radius 6, 12.5: a 12pt spinner, the station in mono 600,
    its lane and elapsed time in mono 11 `textTertiary`; the selected row on `bgSelected`. Then
    "then `join` → `validator` (e2e) once all three pass" in 11.5 `textTertiary`.
  - **Waiting on you**: "Nothing. Next check-in is `review`, approving the 4 PRs."
  - **Decisions so far**, log rows ("10:58 · buf → failed once, retried · auto").
- **The live station** fills the rest: the inspector header with its pill ("Running · 14m"), then a
  tab strip (18pt padding, a hairline beneath): tabs 36pt tall in 12.5, the chosen one at 600
  `textPrimary` over a 2pt `textPrimary` underline, the rest `textSecondary`: **Transcript**,
  **Evidence**, **Inputs · 2**, **Diff** "+84 −6"; on the right, mono 11 `textTertiary` "fable-5-1 ·
  612k of 900k". The transcript (22pt/28pt padding, at most 720pt) opens with "Started from `fork`
  at 10:58 with `events v1.8.0-rc.1` and `spec ANL-214`" (11.5 `textTertiary`, the data in mono
  `wireData`), then the thread's own components: prose, activity lines with their file rows, a
  running row (a 13pt spinner, "Running tests", the command in mono 11 `textTertiary`, the elapsed
  time in mono 11 `running`) and its streamed output in mono 11/1.6 `textTertiary` with the newest
  line `textSecondary`. At the bottom (12pt/28pt/16pt padding), the steer field: 44pt, radius 8,
  `bgRaised`, `lineStrong` border, "Steer orders — delivered before its next turn", and a 28pt Send.
  This is the subagent inspector's transcript and steer, in a station.

**Off the map** (MXOffMap): an upstream contract change; re-runs follow the data wires. The pill
reads "Paused · off the map", the meters fill `lantern`, and Resume is disabled.

- The map shows the failed validator (chip "1 of 11 failed"), the finding's "no owner" edge, and the
  proposed patch below it in `.patchAdded` ("schema-2", "buf breaking · rc.2", then "analytics ↻"
  and "orders ↻" with "re-run" chips, and "validator ↻"), its fork and join bars in `done`; an
  untouched lane says why in mono 10.5 `textTertiary` ("unchanged / doesn't read OrderPlaced"). The
  status chip reads "Paused at `validator` · previewing patch · +2 stations · 3 re-runs" (a `failed`
  border on `failedTint`).
- **The inspector**: "Off the map" with the tag "paused 11:46" in `failed`, "1 of 11 contract checks
  failed · nothing is running"; What happened (12.5/1.55 `textSecondary`); Finding (10pt/12pt
  padding, a 2pt `failed` rule on the leading edge, radius 0/6/6/0, `failedTint`, 12.5/1.55, footed
  by "from check 3 of 11 · the check itself stays hidden" in 11 `textTertiary` with a lock);
  Proposed patch ("re-runs follow the data wires", change rows, a skipped lane as `=` with
  "skipped"); Considered and rejected (each option in `textPrimary` over its reason in
  `textTertiary`, 12.5/1.45; "Validators can't weaken the contract."); Cost. Footer: **Stop
  mission** (`.danger`), **Edit on map** (secondary), **Apply patch** (primary, ⌘⏎).

**Done** (MXDone): route history, the contract revealed, merge order. The pill reads "Done", Goal,
Map and Run are checked and Done is current, the meters fill `done`, and there is no header action.

- The map shows the route it took: every station done, patch stations now plain with a "patched"
  chip, a station that came from fog marked "from fog", the destination selected with its time. The
  status chip (26pt, radius 6, a `lineSubtle` border) lists "21 stations", "2 patches", "1 retry",
  "2 decisions" 12pt apart in mono 10.5 `textSecondary`, then "1 route not taken" in
  `textTertiary`.
- **The inspector**: "Merged in order" with "Done · 2h58"; "4 PRs · 4.8M of 6M tokens · $44"; a
  summary in 13/1.6; **Contract · now visible** ("11 / 11" in mono 11 `done`), rows at least 24pt,
  12, a 12pt check and a mono 10.5 `textTertiary` note ("2,000 orders", "212 → 219ms"); **Merged, in
  order**, rows at least 28pt: the order in mono 10.5, a 13pt merge glyph in `done`, the repo in
  mono 600, the PR in mono `running`, its diff stat, and the time or tag ("13:02 · v1.8.0"); **Spend
  by lane**, rows at least 24pt: the lane in mono (120pt), a 6pt bar (radius 3, `lineSubtle`, filled
  `textTertiary` relative to the largest lane), the value in mono 11; **Planner's note for next
  time** (12.5/1.55 `textSecondary`). Footer: **Run again** (ghost, with a symbol) and **Save as map
  template** (primary, with a symbol).

### Missions: review, evidence and the merge train

**Not built yet.** **The review gate** (MXReview) is one pass over every PR, with the contract's
evidence beside the diff. The pill reads "Review · needs you".

- **Three columns** over a 56pt footer: the PR set (320pt), the diff, and the contract (420pt).
- **PR set**: a head (16pt/16pt/12pt padding) with "PR set" and "merges in this order", then "4 PRs
  · 21 files" in 12.5/600 with its stat and "CI green ×4" in mono 10.5 `textTertiary`, and a 4pt
  `.nwBar` in `done` beside "viewed 7 of 21" (11.5 `textTertiary`). PR rows are 32pt, radius 6,
  12.5: a 10pt disclosure chevron, the order in mono 10.5, the repo in mono 600, the PR in mono 11
  `running`, a spacer, files viewed ("3 / 3") in mono 10.5 `textTertiary`, and a 12pt CI check. An
  open PR lists its files, 28pt, inset 30pt: a 14pt Viewed checkbox, the path in mono 12 (the
  directory `textTertiary`, the name at 600 when selected), its stat; the selected file on
  `bgSelected`. At the bottom, **Planner's summary** (12/1.5 `textSecondary`).
- **The diff** is the review pane's: a 44pt file header on `bgSunken` ("orders-svc /
  internal/orders/" `textTertiary` and "place.go" at 600, the stat, Viewed, and Unified | Split),
  26pt hunk headers on `runningTint`, 22pt lines with 44pt number gutters and an 18pt sign column.
  Between lines sit **`NWDiffAnnotation`** cards (10pt/12pt padding, radius 8, `bgRaised`,
  `lineStrong` border): `.check(5)` pins a validator judgment to the lines it judged ("Check 5 ·
  Outbox only, never inline", "judge · passed" in `wireData`, a 13pt check); `.patch(id)` says why a
  line exists ("Added by a patch", "schema-2 → orders ↻" in `textTertiary`, a lantern symbol, traced
  to the finding that caused it). A draft comment ("You · draft", an 18pt avatar) offers **Send to
  the orders lane** (secondary, 24pt) or **Just a note** (ghost), with "Sending adds a patch: orders
  re-runs, then the validator." in 11 `textTertiary`.
- **Contract**: a header with a `done` symbol, "Contract" and "10 passed · 1 is you", over "visible
  to you now · workers never saw it". **`NWContractRow(check)`** rows: at least 28pt, radius 6, 12:
  the number in mono 10 (16pt), a 14pt state column, the check, and its evidence kind in mono 10 on
  the right: ci, sql, trace, k6 in `textTertiary`, judge in `wireData`, you in `lanternText` (with a
  glowing 7pt dot until you approve). The selected row expands: what it proves (11.5/1.45
  `textSecondary`), its query (mono 11/1.6 on `bgSunken`, radius 6, syntax colored), its result as a
  small table (header cells on `bgSunken` in mono 10.5 `textTertiary`, good values in `done`), and
  **Open evidence** (secondary, 24pt) and **Re-run** (ghost). Its footer: "Validator ran at 12:52 on
  `build-01` in its own worktree, against `compose.e2e.yml` with all four services." (11.5/1.5
  `textTertiary`).
- **The footer** (56pt, a hairline above): "Changes you send go to the lane that owns the file. The
  map adds a patch, and the validator runs again before you're asked back." (12 `textTertiary`),
  then **`NWMergeActions`**: **Request changes · 1** (secondary) and **Approve 4 PRs · start the
  train** (primary, ⌘⏎). Changes go to the lane that owns the file, as a patch.

**Evidence** (MXEvidence): what the validator ran for one check, traced across services.

- The column (20pt/28pt padding): a breadcrumb in 12 `textTertiary` ("Review / Contract / Check 2 of
  11", the last in `textSecondary`), the check as a 20/600 title, then its pill ("Passed · 2,000 of
  2,000 orders"), the sample in mono 11 `textTertiary` ("trace 4f2a…c81 · 1 of 50 sampled · 1.08s"),
  and **Trace | Rows | Commands** (`NWSegmentedPicker`, small).
- **The trace** (a card, radius 10, `lineSubtle` border): "ONE ORDER, END TO END" with a legend
  (request `running`, outbox write `done`, event on a topic as a 1.5pt dashed `wireData` outline,
  database `textSecondary`), time ticks every 200ms in mono 10 `textTertiary`, and one 32pt row per
  span (alternate rows on `bgHover`): the service in mono 11.5 `textTertiary` (132pt) and the span
  in `textPrimary`, its **`NWTraceSpan(kind:)`** bar (12pt, radius 3) at its offset with the
  duration after it in mono 10 `textTertiary`; hand-offs between spans are dashed `wireData` curves,
  as on the map.
- Under it, two columns: **Row it produced** (a table in mono 11) and the **payload** (proto as JSON
  on `bgSunken`, syntax colored).
- **The inspector**: "How it was checked", "hidden from workers · 12:52 on build-01 · 3m10"; Would
  fail if; **Steps** ("5 commands"), each 10pt padded with a hairline above: its number in mono 11,
  the command in mono 11.5 over its result in 12 `textSecondary` with an 11pt check; **Keep it**,
  with **Save as an e2e test** (secondary, 24pt). Footer: **Re-run check** (ghost) and **Back to
  review** (secondary).

**Merge train** (MXTrain): the order comes from the data wires, with staging and a soak between
services. The pill reads "Merging · 2 of 4"; the action is Pause train.

- A bar (14pt/24pt padding): **Map | Train** (`NWSegmentedPicker`, small), a spacer, and "Drag a
  card to change the order. The planner checks it against the data wires." (11.5 `textTertiary`).
- **`NWTrainCard(pr, state:)`**, one per PR, left to right, joined by 38pt arrows (2pt `lineStrong`
  with a chevron): 234pt wide, radius 10, `bgRaised`, `lineSubtle` border. Its head (12pt/14pt
  padding, a hairline beneath): a 20pt circle with the order in mono 10.5, the repo in mono 13/600;
  the PR in mono `running`, its stat, and its role in `textTertiary` ("shared protos", "consumer",
  "producer"); and its pill: **Merged** (`done`), **In the train** (`running`; the card gets a
  `running` border and a 3pt `runningTint` ring), **Waiting** (outlined, hollow dot; the card at
  70%). Its gates follow (8pt/14pt/10pt padding).
- **`NWTrainGateRow(gate)`**: at least 28pt, 12.5, a 14pt glyph column: done (13pt check), running
  (12pt spinner), failed (11pt xmark), fixed by a rule (a 13pt symbol and "auto" in `lanternText`),
  queued (7pt hollow ring, the name in `textTertiary`); the meta in mono 10.5 `textTertiary` ("CI
  green 12:58", "Soak 10m · 6m left", "Bumped in 3 repos · go.mod"). A note can sit under a gate,
  indented 24pt, in 11 `textTertiary` ("main moved at 13:12"). A soaking card shows its health on
  `bgSunken` (radius 6, mono 10.5): errors "0.00%" in `done`, "consumer lag p95", "events ingested".
- The gates run top to bottom inside each card, in this order (MXTrain, NWMissions): **Rebase on
  main**, **CI**, **Merge**, then what the lane ships. A shared contract is tagged and bumped where
  it is imported ("Tagged v1.8.0", "Bumped in 3 repos · go.mod"); a service is deployed and soaked
  ("Deploy to staging", "Soak 10m", per the Between services rule). The first card has no rebase. A
  finished gate reads in the past tense with its time or count ("CI green 12:58", "Merged 13:02",
  "Deployed to staging 3/3"), a pending one in the imperative ("Rebase on main", "CI", "Merge"), and
  a running one with its elapsed or remaining time ("CI 2m", "Soak 10m · 6m left").
- When a rule acted, a note on `lanternTint` (10pt/12pt padding, radius 8, 12/1.5, a lantern symbol)
  says so: "…The train fixed it without asking, because lockfile conflicts are on your **fix
  automatically** list. A code conflict would have paused here."
- **Why this order** ("worked out from the data wires, not guessed"), a card (16pt/18pt padding,
  radius 10, `lineSubtle` border): rows at least 30pt, 12.5/1.5: the order in mono `textTertiary`
  (44pt), the reason in 600 (250pt), the explanation in `textSecondary` ("contracts first",
  "analytics-ingest before producers", "checkout, then orders").
- **The inspector**: "Merge train" with "2 of 4 merged", "one PR at a time · started 12:58 · ~30m
  left"; **Rules** ("host default · change for this mission"): **`NWTrainRuleRow(rule)`** rows at
  least 34pt, the rule in 12.5 `textSecondary` and an `NWPopupMenu` (190pt): Between services
  "staging + 10m soak", Lockfile conflicts "fix automatically", Code conflicts "pause and ask", Red
  CI after merge "revert, then pause", Merge window "weekdays 9–4 CT"; **Log**. Footer: **Skip
  soak** (ghost) and **Pause train** (secondary).

### Missions: when things go wrong

**Not built yet.** Only the part that's stuck pauses.

**Stuck lane** (MXStuck): three failed tries pause that lane; the rest keep going. The pill reads
"Running · 1 lane stuck"; the action stays Pause.

- **The left column**: the mini-map (the stuck station and its check in `.failed`, selected);
  **Lanes** ("1 paused · 3 moving or done"): rows 32pt, radius 6, 12.5: a 14pt state glyph, the repo
  in mono 600 (128pt), the state in `textSecondary` ("done, waiting at join"; "stuck after 3 tries"
  in `failed`), its time in mono 11 `textTertiary`; then "Only orders-svc paused. The other lanes
  keep going. `join` waits for orders, so nothing else is blocked yet." (12/1.5 `textTertiary`);
  **Why it paused** ("from the go test exits"): exit rows ("fail → retry, tries 2 and 3"; "fail ×3 →
  pause this lane, and ask you").
- **The station**: its pill reads "Stuck · 3 tries" in `failed` on `failedTint` (`AgentState
  .stuck`), and its tabs lead with **Attempts · 3** ("fable-5-1 · 870k of 900k"). The tab (22pt/28pt
  padding, 18pt gaps, at most 780pt): the planner's read; **Attempts** ("orders · 870k of its 900k")
  as attempt rows; **What next** as choice cards: Retry with a hint (the planner's pick, "~150k ·
  10m", its hint editable), Replan the lane ("+1 station · ~350k · 25m", "Adds `outbox-tx` before
  orders…"), Take over in a thread ("mission waits at join"; "Opens a thread in this worktree. When
  you're done, hand it back and the lane re-runs its check."), and Drop the lane, disabled ("not
  possible"). Footer: what the choice costs ("The hint raises orders to 1.05M. The mission stays
  under 6M.", 11.5 `textTertiary`), **Take over** (secondary), **Retry with hint** (primary, ⌘⏎).

**Out of budget** (MXBudget): every station stops at a checkpoint. The pill reads "Paused · out of
budget"; the tokens meter is full in `failed`, time in `lantern`; Resume is disabled.

- **The left column**: the mini-map (checkpointed stations with a `lantern` border); **Stopped at a
  checkpoint** ("2 stations") as checkpoint rows, then "Stations stop at their next turn and commit
  to their worktree. Nothing is cut off mid-edit, and resuming picks up the same Pi session."
  (12/1.5 `textTertiary`).
- **The inspector**: "Out of budget", "paused 12:31" in `lanternText`, "6.0M of 6M tokens · 2h31 of
  4h · nothing is running"; What happened; **Spend vs plan** ("6.0M total") as spend bars with their
  legend; **Left to do** ("estimated from this run"): rows at least 26pt (`↻` or `·`, the station in
  mono 600 at 104pt, what's left, the estimate in mono 11 `textTertiary`), and a total row over a
  dashed `lineSubtle` rule ("To finish", "~0.9M · ~40m" in mono 12); **What next**: Add 1M and
  resume (the planner's pick, "7M cap", "The cap goes to 7M, about $9 more. Both stations pick up
  from their checkpoints."), Land what's ready ("2 of 4 lanes"), Stop and keep the branches
  ("Nothing merges. The 4 draft PRs stay open and the worktrees are kept for 7 days."); and a card
  (10pt/12pt padding, radius 8, `lineSubtle` border) with "Pause when a lane goes 50% over its
  plan", "Would have paused at 12:05, when analytics hit 1.95M." (11 `textTertiary`) and a switch.
  Footer: **Stop mission** (`.danger`), **Land what's ready** (secondary), **Add 1M and resume**
  (primary, ⌘⏎).

**Two missions, one repo** (MXLocks): locks are on paths, with a queue. The pill reads "Running · 1
lane held".

- The column (26pt/32pt padding, 26pt gaps):
  - **Repos over time**, with a legend of 18×10 swatches (radius 3): this mission (`runningTint`
    with a `running` border), another mission by name (`lineStrong`), held (lantern-tint stripes at
    135° with a dashed `lantern` border), planned (a dashed `running` border); the other mission's
    planned work is dashed `lineStrong` ("merges ~13:21"). **`NWRepoTimeline(repos, missions:)`**: a
    56pt row per repo with a hairline above and its name in mono 11.5/600 with an 11pt symbol, hour
    ticks in mono 10 `textTertiary`, bars 16pt tall (radius 4) labelled in mono 10 at 8pt in
    ("funnel · order.proto", "held · place.go" in `lanternText`, "merges ~13:21"), and now as a
    1.5pt `running` line with "now 12:12" in mono 10 `running`.
  - **Paths each mission holds**: **`NWPathLockRow(lock)`**, one row per repo both missions touch:
    columns REPO (150pt), the other mission, THIS MISSION, RESULT (230pt); rows at least 36pt, 12, a
    hairline above: the repo in mono 600, the paths in mono `textSecondary`, and the result with a
    12pt symbol ("no overlap · both run" and "free" in `done`, "place.go overlaps · waits" in
    `lanternText`). Under it a note on `bgSunken` (radius 8, `lineSubtle`, 12/1.5): "Missions lock
    **paths, not repos**. A mission holds the paths its stations plan to write, taken from the map.
    A station that writes outside its paths pauses and asks."
  - **Queue on orders-svc · place.go**: rows 34pt, 12.5 (30/260/flex/160): the position in mono 11
    `textTertiary`, the mission at 600, its state after a 6pt dot ("holding · merge train, 2 of 4";
    a glowing lantern dot for "this mission · waiting"; a hollow one for "draft · plans to write
    place.go"), and when in mono 11 `textTertiary` ("releases ~13:21", "starts ~13:21", "not
    launched"); this mission's row on `bgSelected`.
- **The inspector**: "orders-svc is held" with "queue #1", "by Checkout funnel events · merges
  ~13:21"; **The overlap** ("1 file"), a card on `bgSunken` with the path in mono 12/600 and what
  each mission changes; **What next**: Wait for it to merge (the planner's pick, "starts ~13:21"),
  Stack on its branch ("starts now"), Run anyway ("likely conflict" in `failed`); **Meanwhile**, the
  mission's other lanes as 32pt rows. Footer: "You'll get a notification when orders starts." and
  **Wait in queue** (primary, ⌘⏎).

**Stop** (MXCancel): what happens to each lane, with safe defaults. Stop (the header's, or Stop
mission in a paused inspector) opens a dialog over the mission:

- A scrim of black at 55%, and the dialog 96pt from the top, 940pt wide, radius 12, `bgRaised`, with
  the popover's border and shadow.
- **Head** (20pt/24pt/12pt padding): "Stop Checkout funnel events?" in 17/600; "2 of 4 PRs are
  already merged. This is what stopping does to each lane. The planner picked safe defaults; change
  anything before you stop." (13/1.5 `textSecondary`); an `NWStepStrip` of the train, 280pt wide.
- **Lanes** (24pt side padding): columns LANE (170pt), NOW (210pt), ON STOP (170pt), WHAT HAPPENS;
  heads in mono 10 caps tracked `textTertiary`; rows 12pt padded with a hairline above.
  **`NWRollbackRow(lane)`**: the lane in mono 12.5/600 over its PR in mono 11 `running` ("#97 ·
  merged", "#231 · open"); now in 12/1.45 `textSecondary`, after a 6pt state dot for merged work
  ("On staging, migration `0042` applied"); an `NWSegmentedPicker` (small): **Keep | Revert** for
  merged work, **Close | Leave open** for open PRs, none for the mission's own sessions; and what
  happens in 11.5/1.45 `textTertiary`, with a revert's plan in mono 10.5 `lanternText` ("revert #97
  → down 0042 → staging"). Defaults: additive merged work is kept, merged work with a migration is
  reverted, open PRs close (the branch stays), and the mission's sessions stop (the compose stack is
  torn down).
- "Keep worktrees for" with an `NWPopupMenu` ("7 days"), and "You can re-open the mission from
  Missions › Stopped until then." (11.5 `textTertiary`).
- **Footer** (12pt/16pt/12pt/24pt padding, a hairline above): the tally in mono 11 `textTertiary`
  ("1 revert · 2 PRs closed · 2 sessions stopped · 1 kept"), a spacer, **Pause instead**
  (secondary), and **Stop mission** (`.buttonStyle(.nw(.dangerFill))`: `failed` with
  `textOnFailed`), which is never the ⏎ default.

### Missions: templates

**Not built yet.** A finished mission becomes a map you can reuse. Inputs are data, so they render
in `wireData`: `Text(template: "Every {events.last} joins on {join key}")` draws each `{input}` in
`wireData`.

**Save as template** (MXTemplateSave), from Done's Save as map template:

- The map shows the template: lane heads and subtitles with their inputs in braces ("{consumer}", "1
  repo"; "{producers}", "1 or more · a lane each"; "add {events}"; "{events} → {table}"), a repeated
  station as "producer ×n" with a "one per producer" chip, and what the run taught it as a
  `.patchAdded` station ("join key", "you · asked up front") with a "learned" chip in `lanternText`.
  The status chip reads "Template preview · 17 stations · 6 inputs · 1 learned"; bottom-left,
  "`{input}` filled in when you start a mission from it". Template stations are 210pt wide and lanes
  262pt apart.
- **The inspector** (520pt): "Save as template", "from Checkout funnel events · 2h58 · 4.8M";
  **Name** (a 28pt text field, then a description field, 8pt/10pt padding, radius 6, `bgRaised`,
  `lineStrong`, 12.5/1.5); **Inputs** ("found by comparing the goal with the map"):
  **`NWTemplateInput(input)`** rows at least 30pt, 12, columns INPUT (104pt, mono `wireData`), KIND
  (92pt, 11.5 `textTertiary`: "proto messages", "repos, 1+", "pg table", "field", "duration"), THIS
  RUN (mono 11 `textSecondary`), FILLED BY (76pt, 11 `textTertiary`: "your goal", "planner"; "asks
  you" in `lanternText`), heads in mono 9.5 caps tracked; **Changed from this run** (change rows: `+
  join key` "learned", `= retry ≤2`, `↻ contract` "11 checks become 9 with inputs", `− registry`
  "sub-map route was never taken"); **Contract, with inputs** (rows with inputs in `wireData`, then
  "6 more · still hidden from workers when the template runs"); **Share**: **Just me | Team**
  (`NWSegmentedPicker`, small) and "Saved as `.shepherd/maps/add-event.yml` in contracts. Changes go
  through a PR." Footer: **Cancel** (ghost), **Save template** (primary, ⌘⏎).

**Missions ▸ Templates** (MXTemplates): the Missions page with the Templates tab chosen, shared
through a repo and reviewed like code.

- **Table**: TEMPLATE 1.7fr, LANES 1fr, RUNS 50, AVG 60, SHARED 80, 18pt gaps; rows 12pt/24pt: a
  13pt symbol and the name in 13.5/600 over its inputs in mono 11 `textTertiary` ("events,
  producers, consumer, table, join key, retention"); lanes in mono 11.5 `textSecondary` ("contracts
  · consumer · producers ×n"); runs in mono 12; average in mono 12 `textSecondary`; shared in 12
  `textSecondary` ("team", "just me"). Under it: "Save any finished mission as a template from its
  Done screen. Team templates live in a repo, so they're reviewed like code." (12 `textTertiary`).
- **Detail** (420pt): the name in 15/600 over its file in mono 11 `textTertiary`
  (".shepherd/maps/add-event.yml · contracts"); its map at 84×26 (checks 84×20, lanes 96pt apart);
  **Runs** ("3 · all merged": Average "2h40 · 4.6M tokens", Patches per run "1.3 → 0 last run");
  **Learned from runs** (rows at least 24pt: the date in mono 10.5 `textTertiary`, 48pt, and the
  lesson in `textSecondary`). Footer: **Edit map** (ghost), **Start a mission** (primary).

**Start from a template** (MXTemplateStart): five of six inputs filled, one question first. The pill
reads "Planning · 1 question" (glowing).

- The chat as in intake: activity lines "Read PAY-311 · 1 linked doc" and "Matched a template · Add
  an event across services · used 3×"; the filled inputs as a list (the input in mono `wireData`,
  "→", its value as inline code); "The template asks one thing before it draws anything:" and an
  unanswered question card ("Which key joins a refund to the funnel?", "Asked up front since the
  funnel mission, where a missing join key cost a re-run of two services.", order_id, payment_id,
  Something else…).
- **The brief** (520pt), "started from a template · click anything to change it": Destination
  ("PAY-311 + your message"); **Template** ("3 runs · avg 2h40"): its chip (24pt, radius 6,
  `lineSubtle`) and change rows against the last run (`= consumer`, `± producers` in `running`, `+
  check` "new"); Lanes · 3 repos ("template + planner"); Validation contract ("7 more from the
  template"); Size ("~3.1M tok · ~2h10", "from 3 runs"; "5M · 3h · 2 forks"); **Still open** with a
  glowing lantern dot ("join key", "order_id or payment_id?", "needed to draft"). Footer: "Answer
  the join key to draw the map." and **Draft the map**, disabled at 40% until it is answered.

### Missions: iPhone and iPad

**Not built yet.** The phone is for missions that run while you're away: a Live Activity for
progress, notifications with answers built in, and the few decisions a mission stops for. Map
editing stays on the Mac ("Take over on your Mac", "Open on your Mac"). The iOS rules hold (Dynamic
Type, 44pt targets, no hover).

- **`NWLaneStrip(stations)`**, a lane as a tiny subway line: 14pt tall, stops 4.5pt in radius joined
  by 2pt lines; a finished stop is a `done` disc (its line `done`), a running one a `bgRaised` disc
  with a 2pt `running` ring, a failed one a `failed` disc, and a pending one a 3.6pt `bgRaised` disc
  with a 1.5pt `lineStrong` ring (its line `lineStrong`).
- **`NWMissionLiveActivity(mission)`** (ActivityKit), one strip per lane and the one thing that
  needs you: a card (radius 18, `bgRaised`, 12pt/14pt padding, 8pt gaps) with a 14pt lantern crook,
  the mission in 13/600 and "1h38 / 4h" in mono 11 `textTertiary`; a row per lane (18pt: the lane in
  mono 10.5 `textSecondary`, 80pt; its strip; its step in mono 10 in its state's color, "go test",
  "stuck"); and a glowing 7pt lantern dot with "orders needs you" in 12 `lanternText`.
- **`NWMissionNotification(question)`**: a `UNNotificationCategory` with the choices as actions, so
  answering never opens the app ("Refund events · question", "Which key joins a refund to the
  funnel?"). A mission notification opens the station that asked.

**iPhone Missions** (MobileMissions): from Home, with "‹ Home" (16 `running`) and two 36pt circle
buttons, Search (a `lineStrong` border) and New mission (`lantern`, a plus); the title "Missions" in
30/600. Filters are capsules 32pt tall (12pt padding, 13.5): the chosen one `textPrimary` with
`bgWindow` text at 600, the rest on `bgSelected`, counts in mono 11 at 70%. Missions sit in one card
(radius 12, `bgRaised`, `lineSubtle` border), a hairline between rows (12pt/14pt padding, 8pt gaps):
a 15pt symbol, the name in 15.5/600 and its pill; the state in 13 (`lanternText` when it needs you:
"orders is stuck after 3 tries"); repo chips (mono 10.5, 1pt/6pt padding, radius 4); and the route
strip (4pt segments, 2pt apart) with the spend in mono 11 `textTertiary` ("3.1M / 6M").

**A mission** (MobileMission): a header (58pt top, hairline beneath) with "‹ Missions" and a 34pt
More, the name in 22/600 and its pill. The body on `bgBase` (14pt padding, 12pt gaps):

- the meters (4pt bars, values in `textPrimary`) and the host in mono 11.5;
- **Needs you** (13/600 `textSecondary`, the count in mono 12 `lanternText`), then its card: 14pt
  padding, radius 14, `bgRaised`, a `lanternText` border; a glowing 8pt dot, "orders is stuck" in
  16/600 and "3 tries" in mono 11.5 `textTertiary`; the planner's read in 14/1.45 `textSecondary`;
  and stacked 48pt buttons (radius 12, 16pt): **Retry with the planner's hint** (primary), **Replan
  the lane** (secondary), **Take over on your Mac** (text, `running`);
- **Lanes** ("3 moving or done"), a card (radius 14): rows at least 30pt with the lane in mono
  12.5/600 (126pt), its strip (80pt), and its state in mono 11.5 ("done", "go test · 2m" in
  `running`, "at join", "stuck" in `failed`), then "then join → validator → review → merge train"
  (12.5 `textTertiary`);
- at the bottom (10pt/14pt/34pt padding, a hairline above), a capsule field (42pt, radius 21,
  `bgRaised`, `lineStrong`): "Tell the planner…".

**Patch sheet** (MobilePatch): apply from the phone. A sheet over the mission (a 50% black scrim),
640pt tall, radius 16 on top, `bgWindow`, a 36×5 grabber in `lineStrong`: "Patch for orders-svc" in
20/600 over "proposed by the planner · 11:55" (13 `textTertiary`); its changes (14/1.35: the mark in
mono 600, the station in mono 600 over what it does in 13 `textSecondary`); the cost in a card
(radius 12, `bgRaised`, rows at least 26pt, 13.5: "Tokens 3.1M → 3.5M of 6M"); a note ("Only
orders-svc changes. join still waits for it, so nothing else re-runs."); and 48pt buttons, **Apply
patch** (primary) and **Open on your Mac** (secondary).

**Review** (MobileMerge): approve the PR set, start the train. The pill reads "Review · needs you".
The planner's summary (14/1.5 `textSecondary`); a **Contract** card (a 17pt check, "Contract"
16/600, "10 passed" as a `done` pill; rows at least 28pt in 14 with a 14pt check; "Show all 10, with
evidence" in 13 `running`); **PR set** ("merges in this order"), a card of rows at least 42pt: the
order in mono 11.5 `textTertiary`, the repo in mono 14/600 over the PR in `running`, its stat and "3
files", a 14pt check and an 8×14 chevron. Footer: **Approve 4 PRs · start the train** (primary) and
**Request changes** (secondary), both 48pt.

**iPad** (iPadMissions, iPadMissionMap, iPadMissionReview), missions on a big screen:

- **List and detail** beside the sidebar (the boards' 300pt iPad sidebar with Missions chosen): a
  340pt list column with a 76pt header ("Missions" 17/600, a 40pt New mission icon), capsule filters
  (30pt, 13), and rows (12pt padding, radius 10, the selected one on `bgSelected`): a 15pt symbol,
  the name in 15/600 and its pill, the state in 12.5, and a 160pt lane strip of the mission's route.
  The detail: a 76pt header (the name, its pill, a 40pt •••), a bar (10pt/16pt) with the meters, the
  host chip and **Open map** (36pt, secondary), the mini-map (stations 96×28, lanes 108pt apart),
  and the needs-you card floating 14pt from the sides and 26pt from the bottom (14pt/16pt padding,
  radius 14, a `lanternText` border, the popover's shadow) with 36pt buttons: **Retry with the
  planner's hint**, **Replan the lane**, **Take over** (ghost).
- **Mission map** (iPadMissionMap): a 76pt header with "‹ Missions" (16 `running`), the name and
  pill, the meters, the host chip and **Pause** (36pt). The whole map in a 700pt column (stations
  124×33, lanes 140pt apart) with "pinch to zoom · tap a station · two-finger drag to pan" in mono
  10.5 `textTertiary` at its bottom-left; beside it the station: its name in mono 16/600 with its
  pill and "orders-svc · fable-5-1 · 870k of 900k" in mono 12; the planner's read (radius 10,
  14/1.55); attempts as 36pt rows (a 20pt number, what it tried, "same failure", the time); the
  choice cards; and a footer (12pt/16pt/26pt) with **Take over** and **Retry with hint** at 36pt.
- **Mission review** (iPadMissionReview): PR set, diff and contract in three columns under a 76pt
  header ("‹ Map", "Review · Checkout funnel events", Needs you, and **Request changes · 1** and
  **Approve 4 PRs · start the train** at 36pt). The PR list is 270pt ("4 PRs · merge order" in mono
  11 caps, PR rows at least 44pt in 13.5, file rows at least 40pt inset 30pt); the diff keeps the
  Mac's parts with 30pt number gutters; the contract column is 380pt ("Contract · 10 passed" and "+
  your approval"; rows at least 36pt in 13, the selected one expanded with its result, **Open
  trace** and **Re-run**).

### Missions: motion, keyboard and parts to build

**Not built yet.**

- **Motion:** needs-you stations, dots and pills glow (the 1.6s attention glow); running stations,
  frontier rows and gates spin (1s); a moving flow wire's dash advances 18pt every 0.9s, linear and
  repeating. The dash is a new continuous motion: add it to `NW.Motion` as a clock-driven,
  render-server animation like the spinner, static under Reduce Motion and stopped under
  `nwMotionPaused`. Nothing else on the map moves by itself; a patch appends below (the map grows
  downward) and the canvas never re-lays out what already ran.
- **Keyboard:** ⌘⏎ (⌘↩) performs a mission screen's primary action (Draft the map, Launch, Apply
  patch, Retry with hint, Add 1M and resume, Wait in queue, Approve N PRs · start the train, Save
  template); ⌘[ goes back from a mission to the thread; ⌘K offers "New mission…" and the missions by
  name. New chords go through `KeybindingsStore`, and the boards' ⌘0 for the sidebar yields to the
  existing ⇧⌘S. ⌘↩ already means "send the other way" in a composer while pi works (Keyboard), so
  decide which wins in the planner chat and a station's steer field before building.
- **Performance:** the map, the Missions table, the log and the attempts are long lists: lazy, one
  view per row, rows as `Equatable` values, with an `ListPerformanceTests` budget each (see
  Performance).

**Parts the boards name** (NWSwift, NWMissions, MXVocab), to build in ShepherdUI with a `#Preview`
in both appearances. NWSwift files them in two folders: the map in `Components/MissionMap/`
(`NWMissionMap` and its parts; a `Canvas` draws the wires and the stations are views on top, laid
out automatically: rows from time order, columns from lanes) and the screens in
`Components/Missions/`. See Theme model › Building on ShepherdUI.

| Group | Parts |
| --- | --- |
| Map (`MissionMap/`) | `NWMissionMap`, `NWStation` (kinds `.agent(role:)`, `.check`, `.contract`, `.merge(pr:)`, `.decision(.research \| .question \| .prototype)`, `.gate`, `.submap`), `.stationState(_:)`, `.stationSelected(_:)`, `NWTerminus(.start \| .destination)`, `NWForkBar`, `NWJoinBar`, `NWFlowWire`, `NWOutcomeChip`, `NWDataWire`, `NWPinRow`, `PinType`, `NWLane`, `NWFog`, `NWFrontierChip` |
| Chrome | `NWMissionHeader`, `NWPhaseBar`, `NWBudgetMeter`, `NWHostChip` |
| Asking you | `NWChoiceCard` (`isPicked:`, `risk:`, `.disabled`), the mission question card, `NWPlannerNote` |
| Struggling | `NWAttemptRow`, `NWCheckpointRow`, `NWSpendBar` |
| Train and locks | `NWTrainCard`, `NWTrainGateRow`, `NWTrainRuleRow`, `NWRepoTimeline`, `NWPathLockRow` |
| Review and evidence | `NWContractRow`, `NWDiffAnnotation(.check \| .patch)`, `NWTraceSpan`, `NWMergeActions` |
| Stopping and templates | `NWRollbackRow`, `NWTemplateInput`, `Text(template:)` |
| iPhone | `NWMissionLiveActivity`, `NWMissionNotification`, `NWLaneStrip` |

Reuse before adding: `NWStatusPill`, `NWStepStrip`, `NWSegmentedPicker`, `NWPopupMenu`, `NWStepper`,
`.toggleStyle(.nwSwitch)`, `.nwCheckbox`, `NWTag`, `NWSearchField`, the thread's components, and the
review pane's.

## Design tool

**Not built yet.** Nothing in this section exists in the Mac app, the iOS client, or ShepherdUI: no
Designs destination, canvas, design agent, design system reader, export, or live link. The iOS
client's first release leaves it out until the Mac has it ([docs/ios](docs/ios/README.md)), and its
search draws no Designs section (`MobileSearchScreen`). The canvas marks the whole page an
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
  a design still loading, a failed drawing or sync, an offline host, Present mode, the
  contents of the ••• menus, and keyboard shortcuts. Any shortcut added goes through
  `KeybindingsStore`.

### Where designs appear

- **Mac sidebar** (NavDesigns, DZStart, and every sidebar board): a **Designs** destination
  between Missions and Automations, its glyph the pen nib (the boards' nib; `pencil.tip` is the
  nearest SF Symbol), selected in `bgSelected` with its title semibold. A design in Recents shows
  the nib (13pt, `textTertiary`) in place of the status dot and its board count in mono 10
  `textTertiary` ("Checkout funnel dashboard  4 boards"). The Mac sidebar today is the
  This Mac / host / space tree (Sidebar); the destination list, Designs third, is specified under
  Sidebar destinations, Needs you, and Recents and is not built yet.
- **iPad sidebar** (iPadSidebar and every iPad board with the sidebar): the same Designs
  destination between Missions and Automations, in its 44pt rows at 15, and design rows in
  Recents with their board count ("4 boards").
- **More ▸ Design systems** (NavHosts, iPadHosts, MobileMore): on the Mac and iPad a row "Design
  systems" nested under More, beside Pi extensions; on iPhone a More row "Design systems" over
  "2 · acme-web, Night Watch".
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

### Designs (NavDesigns, MobileDesigns)

**Not built yet.**

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
  its source in 11.5 `textTertiary` ("dashboard-web · tokens.css"; the board gives Night Watch
  "shepherd · DesignTokens.swift", a file Shepherd doesn't have: name ShepherdUI's `Tokens/`), and
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

### New design (DZStart)

**Not built yet.** New design (the destination's button, "Start a design", or Search's action)
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
    least 72pt tall, `body`), placeholder "A checkout funnel dashboard for the product team…"; under
    it only attach (`paperclip`, "Attach a screenshot or file") and Send (the composer's 28pt
    lantern circle, 35% until there is text).
  - **"DESIGN SYSTEM & STARTING POINT"** (`.nwSectionLabel()`), 10pt above three equal cards in
    a row, 10pt apart. Each card: 12×14 padding, radius 8, 1px `lineSubtle`, 6pt between its
    lines, the hover fill: a 13pt glyph and a title in mono 12 semibold; a line in 12.5
    `textPrimary`; a note in 11 `textTertiary`. The chosen card is `lanternTint` with a
    `lanternText` line and glyph.
    1. The design system found in the repo, drawn chosen: nib, "acme-web", "design system
       · dashboard-web", "found in web/static/tokens.css".
    2. `link`, "Capture a page", "paste a URL to start from", "staging or production".
    3. `photo`, "From a screenshot", "drop an image or a file", "PNG, PDF, Figma export".

### A design: canvas and chat (DZCanvas)

**Not built yet.** Opening a design fills the main column: the header, then the canvas beside a
420pt chat pane. The boards draw it with the sidebar hidden.

- **Header** (the toolbar row, on `bgWindow` with a hairline; the boards draw it 52pt, as every
  toolbar board does; the app's toolbar is 44, see Toolbar): the sidebar button (`sidebar.left`,
  "Show sidebar") while the sidebar is hidden; the breadcrumb (nib, "Designs" in 13
  `textTertiary`, "/", the design's name in 13 semibold); a spacer; the **design system chip**;
  **Present** (`play.fill`, a 28pt icon button, "Present"); and **Export**
  (`square.and.arrow.up`, a 28pt secondary button). 12pt between the header's groups, 8pt
  between the trailing controls.
- **The design system chip** (`NWDesignSystemChip`): 24pt, 8pt padding, radius 6, a 1px
  `lineSubtle` line, three of the system's colors as 8pt squares (radius 2, 2pt apart), then its
  name in mono 11.5 `textSecondary`. Clicking it opens the system (Design systems, below).
- **The canvas** fills the rest, on `bgBase` with a dot grid: 1px `lineStrong` dots every 22pt.
  It pans (the Pan tool) and zooms (the toolbar shows 42% on DZCanvas, 72% on DZTweak); the
  boards draw no zoom limits.
  - **Boards** (`NWBoardFrame`) sit in a grid 44pt apart, from 44pt in and 52pt down. Each has
    its label 24pt above it: the name in 12 semibold (`textPrimary` when selected, else
    `textSecondary`) and, 8pt after it, its size in mono 10.5 `textTertiary`. The frame is the
    board's page at the canvas's zoom, radius 4, with a 1px black 30% outline and a soft drop
    shadow (0, 12, 32 at black 35%). A selected board wears a 2pt `running` ring outside the
    frame. Several boards can be selected at once (DZExport shows two); how is not drawn.
  - **"Ask for another direction"**: after the last board (36pt after it on DZCanvas), a
    300×190 dashed tile (1px `lineStrong`, radius 6), `plus` (16pt) over "Ask for another
    direction" in 12 `textTertiary`, 6pt apart, centered. It asks the agent for one more
    direction.
  - **Board actions** (`NWBoardActions`) float above the selected board: Comment (`text.bubble`),
    Tweak (`slider.horizontal.3`), Variations (`square.grid.2x2`), Duplicate (`doc.on.doc`), and •••
    (a 28pt circle). On NWDesignTool: a `bgRaised` bar with 4pt padding, radius 12, 2pt between
    items, a 1px `lineStrong` line and the popover's shadow; items 28pt tall, 10pt padding, radius
    8, 6pt gap, a 13pt glyph in `textSecondary`, the label in 12.5 `textPrimary`. (DZCanvas draws it
    smaller: a 32pt bar at radius 10 with 26pt items at radius 6 in 12.) Comment pins a comment to
    the board's element you pick next; Tweak opens the Tweak tab.
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
    - "Updated A and A · phone" · "funnel card · 1 change" (`pencil`, as an edit)

    A comment you make on the canvas joins the chat as its `NWCommentCard` (below), and the
    agent's answer sits inside the card under a hairline: its activity line, then its reply
    ("Done. Counts sit next to each percentage on both boards.").
  - **The composer** (12pt above it, 14pt at the sides and below): `NWComposer`'s card at rest (a
    1px `lineStrong` line; the board's radius is 10, off the radius scale, and the composer's 8:
    settle which before building), the field at least 34pt, placeholder "Describe a change, or click
    something on the canvas to comment…", with attach (`paperclip`, "Attach a screenshot or file")
    and Send (35% until there is text) only: no model, thinking, or command chips.

### Comments (DZCanvas, DZTweak, NWDesignTool)

**Not built yet.**

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

### Tweak (DZTweak)

**Not built yet.** Tweak (the board action or the tab) edits the selected element directly.

- **On the canvas**, the element (`NWSelectionRing`) wears a 1.5pt `running` ring (on
  NWDesignTool over a `runningTint` fill), 8pt square handles on its corners (white, a 1.5pt
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
  - A footer pinned to the bottom (12×14 padding, a hairline above): **Reset** (ghost, 24pt) on
    the leading edge, a spacer, and **Ask the agent instead…** (secondary, 24pt) on the trailing
    edge.
- **Token chips** (`NWTokenChip(token, isSelected:)`): 26pt, 8pt padding, radius 6, 6pt gap, a
  10pt swatch (radius 3) and the token's name in mono 11.5. Selected: a 1px `running` line on
  `runningTint`; otherwise a 1px `lineSubtle` line.

### Design systems (DZSystem)

**Not built yet.** A design system is read from a repository, its tokens file and its templates,
and kept in sync. Night Watch is listed as one too ("shepherd"). A system page opens from the
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

### Export and share (DZExport)

**Not built yet.** Export (the header's button) opens a sheet over the design, with the boards
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
    keep editing. The board's URL is plain `http://`: like the remote listener (AGENTS.md ›
    Remote), it has no TLS, so never describe it as a public or internet-safe link.
  - **Use it somewhere else**: **Attach to a thread** (`text.bubble`) and **Attach to a
    mission** (the Missions glyph), secondary 24pt buttons 8pt apart, and "Attached boards
    arrive as HTML plus a note of the tokens they use." in 11.5 `textTertiary`.
  - A footer (12×18 padding, a hairline above), trailing and 8pt apart: Cancel (ghost, 28pt)
    and the primary **Export 2 boards** (`square.and.arrow.up`, 28pt), whose count follows the
    ticked boards.

### Design components (NWDesignTool, NWDesignToolLight)

**Not built yet.** Night Watch's Design tool page names these components, dark and light ("Light ·
Day Watch"), with the same structure in both; NWSwift's inventory adds `NWDesignCanvas`. They belong
in ShepherdUI under `Components/DesignTool/` (NWSwift's package layout), each with a `#Preview` in
both appearances:

| Component | What it is |
| --- | --- |
| `NWDesignCanvas` | The pannable, zoomable canvas on `bgBase` with its 22pt dot grid, holding the board frames, pins and threads (NWSwift; no specimen on NWDesignTool: see A design: canvas and chat) |
| `NWBoardFrame(board, isSelected:)` | A board with its label above, its size in mono, and a `running` ring when selected |
| `NWSelectionRing(element)` | Picks an element inside a board for comments or tweaks |
| `NWCommentPin(number)` | The numbered pin, lantern "because a pin is something you asked for" |
| `NWBoardActions(selection)` | Comment, Tweak, Variations, Duplicate, and •••, floating over the selected board |
| `NWCanvasToolbar(tool:, zoom:)` | Select, comment, pan, and the zoom |
| `NWCommentCard(comment)` | A comment in the chat pane's Comments tab (and the chat) |
| `NWCommentThread(comment)` | A comment on the canvas beside its pin, with Resolve and the agent's reply |
| `NWActivityLine(.drew / .checked)` | The thread's activity line with the design verbs; the same component, two more kinds (`NWActivityLine.Kind` has neither yet) |
| `NWTweakRow(control)` | A slider, segmented picker, or switch: the label leading, the value trailing |
| `NWTokenChip(token, isSelected:)` | A color from the system's tokens, never a free hex |
| `NWTweakScope` | Apply to one board or every matching element |
| `NWDesignSystemChip(system)` | In the design header; opens the system |
| `NWTokenSwatch(token)` | A token read from the repo's tokens file, with the line it came from (the specimen: a 44pt swatch 96 wide, mono 11 and 10; DZSystem draws 56pt with mono 11.5 and 10.5) |
| `NWExportFormatCard(format)` | HTML, ZIP, PDF, PNG |
| `NWLiveLinkField(url)` | The URL served from the host while you keep editing, with Copy (the specimen: mono 11, no scheme; DZExport: mono 12 with `http://`) |

Build them on what exists: the activity line, `NWValueSlider`, `NWSegmentedPicker`, `.nwSwitch`,
`.nwCheckbox`, `NWStatusPill`, `.nwPopover()`'s line and shadow, and the review's comment parts
(`NWInlineComment`, `NWCommentEditor`) as the nearest precedent for comments.

### On iPhone (MobileDesignBoard)

**Not built yet.** A design opens one board at a time, full screen.

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

### On iPad (iPadDesign, iPadSplitView)

**Not built yet.**

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
    in mono 11.5). The composer (10×14 padding, 26pt below, a hairline above) is one field at
    least 44pt tall (radius 12, 1px `lineStrong`, `bgRaised`, 14pt leading padding),
    placeholder "Describe a change, or draw on a board…" at 15, with a 32pt send that is a plain
    `textSecondary` glyph, not the lantern circle.
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

## Verifying visuals

- **Previews:** `ShepherdPreviewTests` render every surface offscreen, in light and dark:
  - thread states (idle, running, thinking, queued, failed, prose, question, empty, starting
    before and after the delay, restoring from disk, a hovered turn, "Jump to latest" over the
    fade, a long stretch folded into one line) and the activity-line states
  - the composer and its menus
  - the queue (the Queue & steer boards): Up next over a running thread with a hovered row and
    a draft (Stop outlined beside Send), a Steering row under a steered message, the editor with
    a Deleted row and the Send menu, every row and stack state, and "From the queue" and
    "Steered" in the thread
  - subagent cards, the ledger, and the inspector
  - the review pane, and its Commit… sheet in every state
  - the palette, the toolbar, the sidebar at each row density, and the window at its minimum
  - the terminal panel: two tabs under the thread, the first split, and maximized
  - every Settings page, sheet, and dialog
  - the empty states

  They write `<surface>-<light|dark>.png` into `$SHEPHERD_PREVIEW_DIR` (the suites are skipped
  when it is unset), so you, or an agent, can look at them:

  ```sh
  SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
  ```

- **Windows:** preview windows sit off-screen and never take focus.
- **Motion:** SwiftUI keeps animating in an off-screen window, so `MotionProbe`
  (`Tests/ShepherdAppIntegrationTests/Support`) records a thin strip of one every few milliseconds
  while a change settles. Compare the frames with the start and end states (`inBetween`,
  `firstColumn(differingFrom:)`, `lastRow(differingFrom:)`) to show that a surface slides, that it
  only fades under Reduce Motion (`.environment(\._accessibilityReduceMotion, true)`), or that it
  stays instant. `MotionProbeTests` is the example. An off-screen window completes removal
  transitions at once (even an explicit `withAnimation`'s completion fires within a frame), so
  record what arrives; what leaves runs the same transition in reverse.
- **Component Gallery:** in Debug builds, the View menu has a Component Gallery.
- **The running app:** build and run the `Shepherd (Dev)` scheme and check the change in both
  appearances.

## Board index

Every board on the canvas, the section of this document that specifies it, and how much of it
the app has. Light variants share their dark board's row. **Built** means the app draws the
board as specified here, give or take what Known gaps and the departures table list;
**Partial** means some of it is built and the rest is marked **Not built yet** where it is
specified; **Not built yet** means none of its surface exists. A board is judged on its own
subject: the destinations sidebar that most macOS boards draw around it is NWNavigation's and
NavNewThread's, the Settings nav's Instructions and Experiments rows are those boards', and a
full-window board's larger sizes and second lines give way to the component boards (Composer,
questions, and menus), except SlashMenu's and ModelPicker's, which specify their menus.

**macOS**

| Board | Specified in | Status |
| --- | --- | --- |
| Main | Thread; Composer, questions, and menus; Toolbar (breadcrumb, branch chip, side-pane button) | Built |
| Running | Thread (A turn while pi works); Composer, questions, and menus | Built |
| SlashMenu | Composer, questions, and menus › Slash menu | Partial |
| ModelPicker | Composer, questions, and menus › Model picker | Built |
| CommandPalette | Command palette | Partial |
| ToolRows | Thread › Work groups, Activity lines | Built |
| Review | Side pane › Changes; Side pane: Browser, Artifacts, Files (its other tabs) | Partial |
| Subagents | Subagents; Side pane › Subagent inspector | Partial |
| SubagentsDone | Subagents (`NWRunLedger`); Side pane › Subagent inspector | Partial |
| SubagentCards | Subagents (`NWSubagentCard`, `NWRunsStrip`) | Partial |
| SettingsAppearance | Settings › Appearance; Density and row settings | Built |
| SettingsAgents | Settings › Agents | Built |
| SettingsWorktrees | Settings › Worktrees | Built |
| SettingsPi | Settings › Pi | Built |
| SettingsRemote | Settings › Remote | Built |
| SettingsKeyboard | Settings › Keyboard; Keyboard | Built |
| SettingsAdvanced | Settings › Advanced | Built |
| SettingsInstructions | Settings › Wide pages, Instructions | Not built yet |
| SettingsInstructionsHosts | Settings › Instructions per host | Not built yet |
| SettingsExperiments | Settings › Experiments | Not built yet |
| NavNewThread | Sidebar destinations, Needs you, and Recents; New thread page | Partial |
| NavMissions | Missions page; Missions | Not built yet |
| NavDesigns | Designs page; Design tool › Designs | Not built yet |
| NavAutomations | Automations page; Sidebar (automation rows, Details and Runs) | Partial |
| NavHosts | Hosts page; Settings › Remote | Partial |
| PaneBrowser | Side pane (Browser) | Not built yet |
| PaneArtifacts | Side pane (Artifacts) | Not built yet |
| PaneArtifactEdit | Side pane (Artifacts › Editing in place) | Not built yet |
| PaneFiles | Side pane (Files) | Not built yet |
| PaneStates | Side pane (tabs, dot, narrow, ⋯, button); Side pane: Browser, Artifacts, Files | Partial |
| QueueStack | Up next (the queue) | Built |
| QueueSteer | Up next (the queue); Thread › User turn (Steered) | Built |
| QueueEdit | Up next (the queue); Composer › Send menu | Built |
| QueueStates | Up next (the queue); Settings › Agents, Keyboard | Partial |
| QuestionAsk | Composer, questions, and menus › Questions | Partial |
| QuestionPick | Composer, questions, and menus › Questions | Partial |
| QuestionAnswered | Composer, questions, and menus › Questions | Partial |
| QuestionStates | Composer, questions, and menus › Questions; Keyboard | Partial |
| TerminalSplit | Terminal panes; Terminal panel (no header button: departures) | Built |
| TerminalPane | Terminal panes; Terminal panel (Split panes, Send output to pi; no header button: departures) | Partial |
| TerminalStates | Terminal panel (no header toggle: departures) | Partial |

**iOS**

| Board | Specified in | Status |
| --- | --- | --- |
| MobileAgents | iPhone: shell and shared anatomy; iPhone: Home | Partial |
| MobileThread | iPhone: Thread | Built |
| MobileApproval | iPhone: Thread | Built |
| MobileLock | Notifications and Live Activities › Live Activities | Not built yet |
| MobileAnswer | Notifications and Live Activities › Actions and answering | Not built yet |
| MobileMission | Missions › Missions: iPhone and iPad | Not built yet |
| MobilePatch | Missions › Missions: iPhone and iPad | Not built yet |
| MobileMerge | Missions › Missions: iPhone and iPad | Not built yet |
| MobileLiveLock | Notifications and Live Activities › Live Activities | Not built yet |
| MobileIsland | Notifications and Live Activities › Dynamic Island | Not built yet |
| MobileNewThread | iPhone: New thread and Where it runs | Partial |
| MobileWorkspace | iPhone: New thread and Where it runs | Partial |
| MobileSteer | iPhone: Up next and questions; iPhone: Subagents | Partial |
| MobileSubagents | iPhone: Subagents | Built |
| MobileSubagent | iPhone: Subagents | Partial |
| MobileQueue | iPhone: Up next and questions | Partial |
| MobileQueueMenu | iPhone: Up next and questions | Built |
| MobileQuestion | iPhone: Up next and questions | Partial |
| MobileChanges | iPhone: Review | Partial |
| MobileDiff | iPhone: Review | Partial |
| MobileCommit | iPhone: Review; iOS (Commit from review) | Built |
| MobileInbox | iPhone: Needs you | Partial |
| MobileSearch | iPhone: Search | Partial |
| MobileMissions | Missions › Missions: iPhone and iPad | Not built yet |
| MobileDesigns | Design tool › Designs | Not built yet |
| MobileDesignBoard | Design tool › On iPhone | Not built yet |
| MobileAutomations | iOS: Automations | Partial |
| MobileMore | iPhone: More | Partial |
| MobileSettings | iPhone: Settings | Partial |
| MobileInstructions | iPhone: Instructions | Not built yet |
| MobileInstructionsEdit | iPhone: Instructions | Not built yet |
| MobileExperiments | iPhone: Experiments | Not built yet |

**iPadOS**

| Board | Specified in | Status |
| --- | --- | --- |
| iPadThread | iOS: iPad › Shell and sidebar, Thread, Composer and commands | Partial |
| iPadReview | iOS: iPad › Review | Built |
| iPadSubagents | iOS: iPad › Subagents | Partial |
| iPadPortrait | iOS: iPad › Shell and sidebar, Composer and commands | Partial |
| iPadSidebar | iOS: iPad › Shell and sidebar | Partial |
| iPadPortraitLaunch, iPadPortraitLaunchLight | iOS: iPad › Shell and sidebar (Portrait) | Built |
| iPadLock | Notifications and Live Activities › Live Activities, Lock-screen widget (iPad) | Not built yet |
| iPadOverview | iOS: iPad › Overview | Partial |
| iPadNewThread | iOS: iPad › New thread | Partial |
| iPadSteer | iOS: iPad › Up next and steering, Subagents | Partial |
| iPadReviewSplit | iOS: iPad › Review | Built |
| iPadCommit | iOS: iPad › Commit; Side pane › Changes (Commit… sheet) | Built |
| iPadQueue | iOS: iPad › Up next and steering | Partial |
| iPadQuestion | iOS: iPad › Questions | Partial |
| iPadMissions | Missions › Missions: iPhone and iPad | Not built yet |
| iPadMissionMap | Missions › Missions: iPhone and iPad | Not built yet |
| iPadMissionReview | Missions › Missions: iPhone and iPad | Not built yet |
| iPadInbox | iOS: iPad › Needs you | Partial |
| iPadAutomations | iOS: Automations | Partial |
| iPadHosts | iOS: iPad › Hosts and More | Partial |
| iPadPalette | iOS: iPad › Command palette; iOS (Windows) | Partial |
| iPadDesign | Design tool › On iPad | Not built yet |
| iPadSplitView | iOS (Windows); iOS: iPad › Split View; Design tool › On iPad | Partial |
| iPadSettingsInstructions | iOS: iPad › Settings | Partial |
| iPadPaneBrowser | iOS: iPad › Side pane | Not built yet |
| iPadPaneArtifacts | iOS: iPad › Side pane | Not built yet |
| iPadPaneFiles | iOS: iPad › Side pane | Not built yet |
| iPadTerminal | iOS (Terminal); Terminal panes (the options menu shows it: departures) | Partial |

**Notifications**

| Board | Specified in | Status |
| --- | --- | --- |
| NotifCatalog | Notifications and Live Activities › The catalog, Rules for sending, Anatomy, Actions and answering | Partial |
| NotifPhoneBanner | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneStacks | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneRich | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneReply | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneReview | Notifications and Live Activities › iPhone | Not built yet |
| NotifPhoneSummary | Notifications and Live Activities › iPhone | Not built yet |
| NotifSettings | Notifications and Live Activities › Settings ▸ Notifications | Not built yet |
| NotifiPadBanner | Notifications and Live Activities › iPad | Not built yet |
| NotifiPadCenter | Notifications and Live Activities › iPad | Not built yet |
| NotifMac | Notifications and Live Activities › On the Mac today, Mac | Partial |

**Missions**

| Board | Specified in | Status |
| --- | --- | --- |
| MXNav | Missions › Missions: getting there | Not built yet |
| MXFlow | Missions › Missions: how a mission runs | Not built yet |
| MXStart | Missions › Missions: intake | Not built yet |
| MXGoal | Missions › Missions: intake | Not built yet |
| MXMap | Missions › Missions: the map; map, patches and the run | Not built yet |
| MXPatch | Missions › Missions: map, patches and the run | Not built yet |
| MXRun | Missions › Missions: map, patches and the run | Not built yet |
| MXOffMap | Missions › Missions: map, patches and the run | Not built yet |
| MXDone | Missions › Missions: map, patches and the run | Not built yet |
| MXInputs | Missions › Missions: how a mission runs | Not built yet |
| MXReview | Missions › Missions: review, evidence and the merge train | Not built yet |
| MXEvidence | Missions › Missions: review, evidence and the merge train | Not built yet |
| MXTrain | Missions › Missions: review, evidence and the merge train | Not built yet |
| MXStuck | Missions › Missions: when things go wrong | Not built yet |
| MXBudget | Missions › Missions: when things go wrong | Not built yet |
| MXLocks | Missions › Missions: when things go wrong | Not built yet |
| MXCancel | Missions › Missions: when things go wrong | Not built yet |
| MXTemplateSave | Missions › Missions: templates | Not built yet |
| MXTemplates | Missions › Missions: templates | Not built yet |
| MXTemplateStart | Missions › Missions: templates | Not built yet |

**Design tool**

| Board | Specified in | Status |
| --- | --- | --- |
| DZStart | Design tool › New design | Not built yet |
| DZCanvas | Design tool › A design: canvas and chat, Comments | Not built yet |
| DZTweak | Design tool › Tweak | Not built yet |
| DZSystem | Design tool › Design systems | Not built yet |
| DZExport | Design tool › Export and share | Not built yet |

**Design system · Night Watch**

| Board | Specified in | Status |
| --- | --- | --- |
| NWFoundations, NWFoundationsLight | Theme model; Typography; Space, radius, height, elevation; Motion | Partial |
| NWControls, NWControlsLight | Components › Controls | Partial |
| NWStatus, NWStatusLight | Components › Status and feedback; Status language | Partial |
| NWThread, NWThreadLight | Thread | Partial |
| NWComposer, NWComposerLight | Composer, questions, and menus; Command palette | Partial |
| NWNavigation, NWNavigationLight | Window and adaptive layout; Sidebar; Sidebar destinations, Needs you, and Recents; Toolbar | Partial |
| NWAgents, NWAgentsLight | Subagents; Side pane › Subagent inspector; Mission components | Partial |
| NWReview, NWReviewLight | Side pane › Changes | Built |
| NWSwift, NWSwiftLight | Theme model › Building on ShepherdUI | Partial |
| MXVocab, MXVocabLight | Missions › Missions: the map | Not built yet |
| NWMissions, NWMissionsLight | Missions (Missions: shared parts and the screens that use them) | Not built yet |
| NWDesignTool, NWDesignToolLight | Design tool › Design components | Not built yet |
| Foundations, Components (Option A) | Theme model (superseded: take nothing from them) | Superseded |
