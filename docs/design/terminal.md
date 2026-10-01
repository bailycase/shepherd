# Terminal and terminal panel

> Read when you change a terminal tab, the panel under a thread, or ⌘J and ⌘D.

## Terminal

File and image drags route through the native terminal surface, not a window-wide input overlay.
Ordinary clicks never depend on leftover drag pasteboard contents. Covered and hidden terminals
must not receive a drop intended for foreground UI; resolving a drag does not enumerate hidden
agent layouts.

A terminal is a real PTY: libghostty on the Mac (`AppTerminalView`, through
`TerminalHost.swift`), SwiftTerm on iOS (`TerminalSurface`). Each one is a real shell and nothing in
it is pi's (TerminalStates: "Each tab is a real shell; nothing here is the agent’s"). The chrome never
parses or restyles terminal output, and the thread itself is never a terminal. There is only the
terminal: the area that holds them shows tabs, one terminal each, and never a split or a grid of
them (the user's decision, 2026-09-30; see the departures).

- **Surface:** the theme's terminal colors (`TerminalColors`), on `bgWindow` (the boards draw
  `bgBase`; see the departures). The grid sits 14pt from the sides and 10pt from the top and bottom
  (TerminalSplit; `NWTerminalMetrics.contentPadding`), 16pt and 10pt on iPad (iPadTerminal).
- **Type:** the boards set the terminal in Geist Mono with a 1.6 line height: 12pt on the Mac
  (TerminalSplit; TerminalPane's 11.5pt for its narrower split terminals is not built, as nothing
  splits) and 13pt on iPad (the `code` size there). On the Mac the family and size are Settings ▸
  Terminal's and never follow the chrome's text scale. On iOS the terminal follows Dynamic Type up
  to 20pt (`MobileLayout.terminalMaximumFontSize`).
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
  unavailable". A remote agent's terminal on the Mac reads "attaching…", "remote session
  unavailable · <reason>" and "remote session exited (n)". iOS adds "attaching…", "host offline ·
  reattaches when it is back", "open in another window" (a screen shows in one iPad window at a
  time), "review open on <host>", and " · retrying" after a refused attach.
- **Size never animates:** a terminal takes its new size once (`.nwInstant()`; see Motion), and a
  hidden one keeps its grid (Terminal panel › Nothing remounts).

## Terminal panel

A real terminal under the thread, one keystroke away (TerminalSplit, TerminalPane and TerminalStates
boards; `TerminalPanelGeometry`, `TerminalPanels`, `TerminalPanelViews.swift`; the iPad's in iOS ›
Terminal). An agent's terminals live in a panel under its thread and composer, across the
layout's whole width, and a docked side pane keeps its full height beside both (TerminalStates ›
Panel: "The side pane keeps its full height"; TerminalPane). The panel holds tabs only, one
terminal per tab: nothing splits a terminal, and there is no other arrangement. A new terminal
opens in the thread's folder (its worktree) on the thread's host, so it sees what pi sees. The
panel is a view of the agent's layout, which stays the one `PaneNode` tree the server persists and
agents drive: the thread, with every terminal a leaf beside it, a tab each, oldest first
(`PaneNode.terminals(besideThread:)`, `TerminalPanel.tabs`). A saved layout that still has a tab of
several terminals (made by builds that could split them) is flattened into one tab per terminal
when the host starts (`SessionServer.flattenSplitTerminals`), keeping each one's session, folder and
title; a client of an older host that has not done so draws such a tab as one tab per terminal.

- **Strip** (`NWTerminalTabBar`; TerminalSplit): 38pt (`NWTerminalMetrics.tabBarHeight`) on
  `bgWindow`, with a 1px `lineStrong` hairline on top and a `lineSubtle` one under it, 8pt side
  padding and 2pt gaps. From the leading edge: the tabs, then + ("New terminal"), a spacer, then
  Maximize or Restore (`arrow.up.left.and.arrow.down.right`, `arrow.down.right.and.arrow.up.left`)
  and Hide terminal (`xmark`). They are 24pt circular `.nwIcon` buttons with 14pt glyphs in
  `textSecondary`, with tooltips (`.nwHelp`); Maximize or Restore and Hide terminal carry their
  chords. The tabs and + scroll sideways when they outgrow the strip; the trailing controls never
  scroll. The board's Split right button is not built.
- **A tab** (`NWTerminalTabView`): 26pt tall, radius 6 (`NW.Radius.s`), 8pt side padding, 7pt
  between its parts: the terminal glyph (`terminal`, 12pt), the title in Geist Mono 11.5 (semibold
  and `textPrimary` when selected, medium and `textSecondary` otherwise), then the selected tab's
  host and close. The selected tab sits on `bgSelected` with a `textPrimary` glyph; the others are
  clear, with a `textTertiary` glyph and `bgHover` under the pointer. Only the selected tab shows
  its close (`xmark`, 9pt, `textTertiary`; tooltip "Close terminal"). A remote tab names its host
  while selected, after its title: `desktopcomputer` at 10pt and the host's name at 10.5pt, both
  `textTertiary`, 3pt apart ("zsh  build-01").
- **Tab states** (`NWTerminalTab.Activity`; TerminalTab · states: "Remote tabs name their host.
  Running and exited tabs say so without opening them"):
  - **Idle:** the program at its prompt names the tab ("zsh"), else the folder the terminal
    started in, else "Terminal".
  - **Running:** the running command names the tab ("make dev", at most 40 characters), and an 11pt
    `running` spinner (`NWSpinnerStyle`) takes the glyph's place.
  - **New output while you were away:** a 6pt `running` dot after the title, for output printed
    while the tab or the panel was off screen. It can sit beside the spinner (TerminalSplit's "make
    dev").
  - **Exited:** the tab stays and so does its output ("exited with an error; the output stays"); a
    process that failed turns the glyph into a 10pt `failed` ✕ (stroke 2). On the Mac a shell that
    exits closes its terminal, so its tab goes at once (see the departures); on iOS a tab shows it
    exited (`.exited(failed:)`) until the host closes it.

  A resize is not news: a shell or TUI redraws on SIGWINCH (a window resize, maximize or restore, a
  hidden panel's terminals following the geometry, a remote viewer leaving), so the host counts no
  output for a second after it gives a PTY a size (`TerminalNews`, carried as
  `RemoteTerminalActivity.newsSequence`; an older host's every read counts). Showing a tab marks it
  seen whenever the tab or its news changes (`TerminalSeenMark`), so picking a tab
  whose output matches the last one's still clears its dot. What each terminal runs comes from
  `SessionServer.terminalActivity` (a remote agent's host answers `RemoteAgentQuery.terminals`),
  polled every 2 s while the layout is on screen; an older host leaves plain tabs named for the
  folder.
- **Actions:** + opens the new terminal menu, whose first row opens a new tab. ⌘D is New Terminal,
  from the thread or from a terminal: a new tab in the thread's folder, never a split. Closing a
  tab closes its terminal (as ⌘W does, Close Terminal), never the thread's, and the Mac doesn't ask
  first. A remote agent's terminals go through its host's requests, and a failed one beeps and shows
  nothing. A terminal you open (+, ⌘D, or ⌘J with none) takes the keyboard. A terminal that appears
  any other way (an agent's `terminal_open`, another device) opens the panel on its tab and leaves
  the keyboard where it was. ⇧⌘] and ⇧⌘[ go to the next and the previous tab, wrapping, while the
  panel shows; an agent's `terminal_focus` shows the panel on that tab.
- **Show and hide:** ⌘J, the Terminal menu (Show or Hide Terminal), or the palette's terminal
  commands, while a thread with a layout is on screen. The panel slides up from the bottom and is
  only a toggle: there is no terminal button in the thread's header or anywhere in the side pane's
  chrome, and it has nothing to do with the side pane (the user's decision, 2026-09-25: "the
  terminal is only a toggle that pops it up from the bottom, no buttons or anything, it has nothing
  to do with the sidebar"; the TerminalSplit, TerminalPane, TerminalStates and iPadTerminal boards'
  header button is a departure, and patched copies without it go to the canvas). With no terminal in
  the thread, ⌘J opens one (in the thread's folder, on the thread's host), shows the panel on it and
  gives it the keyboard; the Terminal menu's and the palette's Show Terminal do the same, and a
  remote agent's is requested from its host, where a failure beeps and shows nothing. There is no
  empty state and never an empty panel (departures). On iPad and iPhone, with no ⌘J without a
  keyboard, the thread's options menu shows it, and with none it opens one too (iOS › Terminal).
  Showing gives the keyboard to the selected tab; hiding gives it back to the thread. A tab that
  printed while the panel was hidden keeps its `running` dot for when it shows (Tab states). A
  layout seen for the first time with terminals shows its panel. The panel closes with its last
  terminal, however it goes (its tab closed, the agent's `terminal_close`, its shell exiting), and
  the thread takes the layout again.
- **Height:** 330pt by default (`NWTerminalMetrics.panelHeight`), persisted app-wide
  (`shepherd.terminalPanelHeight`). The panel's top edge is the divider (Divider: "Drag the top
  edge. It snaps at a third, half and two-thirds; double-click resets to 330pt"): a 9pt hit area
  centered on the edge with the row-resize pointer. It snaps within 12pt of a third, half and
  two-thirds of the layout, keeps the panel at least 120pt and the thread at least 160pt, and never
  animates while dragged. VoiceOver reads it as "Terminal height" in points and adjusts it in 40pt
  steps. While it is dragged, the edge draws as a 3pt `lantern` line across the top of the strip
  (Divider).
- **Maximized** (⇧⌘↩, or the strip's Maximize): the panel takes the layout and the thread folds away
  at its size, still mounted (its draft, scroll and stream stay). With no terminal there is nothing
  to maximize, and the shortcut only beeps. Restore (the same button, or ⇧⌘↩)
  brings it and its composer back, and so does hiding the panel. The divider doesn't drag while
  maximized. The folded thread keeps one line above the strip (`NWTerminalFoldedThread`;
  TerminalPanel · maximized: "The thread folds to one line. Its composer comes back when you
  restore"): 40pt on `bgWindow` with a `lineSubtle` hairline under it, 14pt leading and 10pt
  trailing padding and 10pt gaps, holding the thread's title in Geist 12.5 semibold, its
  `NWStatusPill` ("Idle"), and at the trailing end a 24pt "Show the thread" icon button
  (`chevron.down`, `textSecondary`, its tooltip with ⇧⌘↩) that restores. Only a maximized layout
  reads its agent's state, so a status report reruns no other layout.
- **Nothing remounts:** every terminal is placed whether it shows or not (a hidden tab or panel keeps
  its size, so its grid never changes), hidden ones are `opacity(0)` and stop rendering. A remote
  agent's panel mounts only its shown terminal, so a hidden remote terminal is detached and never
  counts toward the host's smallest-viewer size.
- **A layout with no thread** (a host's utility terminal) has no panel: it draws one terminal per
  leaf of its layout, with no strip.
- **Send output to the agent** (TerminalPane, drawn there on a split terminal and here on the
  tab's one terminal; TerminalStates: "anything you select can go to the
  agent"). Selecting text in a terminal of a thread's layout shows a floating bar beside the
  selection (`NWTerminalSelectionBar`, `TerminalSelectionOverlay`): `bgRaised` with a 1px
  `lineStrong` border, radius 9, 4pt padding and 4pt gaps, and the popover's shadow, hanging 4pt
  under the selection's last line at the terminal's trailing edge, 8pt in (over its first line where
  there is no room below). It holds **Add to message** (primary, 24pt: a `lantern` fill, a 13pt
  `plus` and the label in 12pt semibold `textOnLantern`), which adds the selection to the thread's
  composer as a code block after what is typed there and gives the thread the keyboard, and
  **Copy** (ghost, 24pt: a 13pt copy glyph and the label in 12pt medium `textSecondary`). Both
  buttons are radius 6 with 8pt side padding and 6pt between glyph and label. The bar goes when
  the selection does (the next click, key or drag) and after either button. The selection itself
  reads as selected lines on `running` at 13%. A host's utility terminal (no thread) has no bar.
- **New terminal menu** (`NWTerminalMenu`, `TerminalMenuLayer`; NewTerminalMenu: "+ or
  right-click"). + and a right-click (or ⌃-click) on a tab open a 290pt menu hanging 4pt under the
  strip from + or that tab: `bgRaised`, a 1px `lineStrong` border, radius 10, 6pt padding and the
  popover's shadow. Its rows are the Changes menus' (`NWChangesMenuRow`): radius 6 with 8pt side
  padding and 9pt gaps, a 13pt `textSecondary` glyph, the title in `ui` (12.5pt), and the chord as
  keycaps (`NWKeycap`) at the trailing end; hovering fills `bgHover`. Two-line rows are at least
  36pt, with a detail in 11pt `textTertiary` under the title; one-line rows are 30pt. A click
  anywhere else or esc closes it. In order:
  - "New terminal in the worktree", detail "<space> on <host>" ("payments on This Mac"; `terminal`),
    with the new-terminal chord (⌘D): "New tabs start in the thread's worktree on its host, so the
    terminal sees what the agent sees."
  - For the tab (right-clicked, else the selected one): "Rename tab" (`pencil`), which asks for the
    name in a rename sheet (a blank name goes back to naming the tab after what it runs; the name
    rides on the terminal's leaf, `LeafPane.title`, so it persists and every viewer sees it); and
    "Kill process" (`xmark`), which kills the command running in the tab's terminal with its whole
    process group (SIGKILL) and leaves its shell, disabled while the shell sits at its prompt. On a
    host's agent Rename tab and Kill process go through the host (`terminal.control.v1`) and are
    disabled against an older host. The board's Split right row is not built.
  - **Not built:** "New terminal on This Mac" (for a remote thread): a remote agent's layout is its
    host's, so a terminal of this Mac has no place in it (see Known gaps).
- **No Run in terminal** (a departure from TerminalStates: "Any command line from the agent can
  be opened in a new tab, typed out but not run"). Removed 2026-09-26 at the user's request: no
  use in agent threads. A finished command's activity line and its call rows' context menus
  offer nothing of the terminal's.
- **Keys** (Keyboard: "Shown in menus and tooltips"). The board's are Show or hide the terminal ⌃\`,
  New terminal ⌃⇧\`, Split right ⌘D, Maximize or restore ⇧⌘↩, Close the tab ⌘W, Clear ⌘K, and Next
  or previous tab ⇧⌘[ and ⇧⌘]. Shepherd's (see the departures and Keyboard): ⌘J shows or hides the
  panel (opening a terminal when there is none), ⌘D is New Terminal (a new tab, from the thread or
  from a terminal; + opens the new terminal menu), ⇧⌘↩ maximizes or restores, ⌘W is Close Terminal
  (the focused terminal's tab; never the thread), and ⇧⌘] and ⇧⌘[ are Next Terminal and Previous
  Terminal; there is no clear chord and no split chord. Every chord resolves through
  `KeybindingsStore`, shows in the Terminal menu ("New Terminal", "Show or Hide Terminal", "Maximize
  or Restore Terminal", "Next Terminal", "Previous Terminal"; File holds "Close Terminal") and in the
  strip's tooltips, and is unbound in Ghostty (`appOwnedChords`) so a focused terminal never eats
  it. ⇧⌘D and ⌥⌘←/→ are bound to nothing; they stay in `appOwnedChords` only because Ghostty's own
  split and goto bindings are silent no-ops in embedded libghostty that would swallow them. A
  terminal becoming AppKit's first responder also selects its tab, including right-click and
  selection-drag acquisition: Close and Kill act on the terminal receiving keyboard input, not the
  last tab whose SwiftUI tap gesture completed.
  Plain Space belongs to the terminal while its surface is first responder,
  before AppKit or SwiftUI can use it to activate a control. It follows the terminal's normal
  text-input path, including input-method composition; unfocused terminals leave it alone.
  A canvas's window-wide Space-to-pan handler ignores hidden layouts and text-input clients,
  including terminals, even when the pointer is over the canvas's remembered bounds.
