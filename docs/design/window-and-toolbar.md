# Window, adaptive layout and toolbar

> Read when you change the window, how it adapts to a narrow size, or the toolbar.

## Window and adaptive layout

```text
┌──────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ ● ● ●      ⌕  ◧  │ Space / Title  ⧉ pi/branch ●3 ⌄       ◫  ⋯   │ ± Changes 4   ⋯  ×   │
│ ⊕ New thread  ⌘N ├──────────────────────────────────────────────┼──────────────────────┤
│ ⚡ Automations    │         820pt thread column                  │ side pane:           │
│ › More           │                       ┌──────────────┐       │ its tabs, or the     │
│ Needs you      1 │                       │ user bubble  │       │ subagent inspector,  │
│ ● agent  why?    │                       └──────────────┘       │ 600pt (min 380, ≤ ½) │
│ Recents          │   agent prose, 640pt measure                 │                      │
│ ● agent       4m │   ✎ Edited 4 files  +149 −63  ›              │                      │
│ ○ agent  horizon │   ┌ composer ──────────────────────────┐     │                      │
├──────────────────┤   └────────────────────────────────────┘     │                      │
│ (B) Name     ⚙   │                                              │                      │
└──────────────────┴──────────────────────────────────────────────┴──────────────────────┘
```

- **One window.** `ShepherdMacApp` declares a single `Window` scene named for the edition
  ("Shepherd", or "Shepherd Nightly") with a hidden title bar; window tabbing is off, and closing
  the window leaves the app and every agent running (the Dock icon brings it back). The window has
  no title other than the toolbar's.
- **Size** (`AppLayout+Navigation.swift`; NWNavigation): minimum 720×600 (`windowMinWidth`,
  `windowMinHeight`), default 1440×900. The window controls stay at macOS's standard position
  (NWNavigation: "window controls at the standard macOS position"); the board draws them in the
  sidebar's 44pt top bar, 14pt in and 8pt apart. The one exception is the maximized side pane's
  rail (ChangesWide), which stacks them (Side pane › Changes › Maximized).
- **Layout** (NWNavigation's window diagram): the sidebar sits on `bgBase` and runs behind the
  window controls; the main column sits on `bgWindow`, with the 44pt toolbar on top. A docked
  sidebar's trailing edge is a 1pt `lineSubtle` divider (`AppLayout.dividerWidth`) with a 9pt drag
  handle centred on it (`resizeHandleWidth`). There is no tab bar and no status line. An agent's
  layout is its thread with its terminal panel under it (Terminal panel, below). The thread column
  is at most 820pt (prose 640, bubbles 600), and the composer is exactly as wide as the column
  (Thread).
- **Switching agents flips visibility; it never remounts.** Every mounted layout stays in the
  view tree, each in a hosting view of its own, and hidden ones are hidden views. This is what
  makes switching instant.

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
  steps; a double-click takes the pane to half the column, PaneStates' "double-click the divider"),
  and the width persists app-wide (`shepherd.rightPaneWidth`). No width is ever negative. It
  slides in from the trailing edge (`.pane`), and its content cross-fades when a tab and the
  inspector swap.
- **Palette:** 620pt wide, or the window minus 16pt margins, and never taller than the window
  leaves room for (`NWPaletteMetrics.placement`).
- **Composer:** in a narrow thread the chips drop their words ("/" alone, the thinking level
  alone) instead of truncating mid-word (`ViewThatFits`). A pane under 520pt (a design's 420pt
  chat) draws the composer at its compact size (`NWComposerSize.compact`), where they never show
  them.

## Toolbar

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
  - the options menu (`NWOptionsMenu`, "Thread options"): Refresh Thread, then Rename… and Pin or
    Unpin (`pin`, `pin.slash`; the sidebar row menu's item) after a divider. Pin is offered where
    the Activity sidebar shows pins, never for an automation's run or in the project tree.
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
- **A page** (New thread, Automations, Hosts) covers the toolbar with its own 52pt header
  (Destination pages). Over a remote host's utility terminal the toolbar reads "<agent> ·
  terminal".
- **Pane headers** (`NWPaneHeader`, NWNavigation: "Title + mono subtitle, controls right, close
  last"): at least 44pt on `bgWindow` with a hairline beneath, 12pt leading and 6pt trailing padding
  (`NWToolbarMetrics.paneLeadingPadding`, `paneTrailingPadding`), 8pt between items. The title is
  Geist 13 semibold over a 1pt gap and a micro `textTertiary` subtitle ("4 files · +67 −58", the
  counts in `done` and `failed`). Then a spacer, the pane's controls (the review's Local · PR #24
  `NWSegmentedPicker`, a ••• `NWOptionsMenu`), and close (`xmark`, "Close pane" unless the pane
  names it) always last. The review uses it ("Close review") only in a layout pane of its own (an
  older host's review leaf); the side pane has its tab strip, and the subagent inspector its own
  header (`NWInspectorHeader`; Side pane, below).

## Nothing on screen

With no thread on screen (no agent at all, or the one shown went away with no earlier one to return
to), the main column shows the New thread page (NavNewThread), the first destination. No board draws
an empty workspace, and the tree's empty states (a space with no agents, no spaces) went with the
tree.
