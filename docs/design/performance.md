# Performance

> Read when you build or change a list, a row, a scroll view, or anything that redraws often.

A list is as fast with three hundred rows as with thirty: it builds the rows on screen, and a
change redraws the rows it changed. `ListPerformanceTests` pins each rule below with a count of
row bodies (`NWRenderProbe`), which a slower machine doesn't change, and
`SHEPHERD_PERF_REPORT=1 swift test --filter ListPerformanceReport` prints each list's timings
against a large fixture (300 agents in 40 spaces, 1,000 palette results, a 2,000-line diff, a
300-file review, and a highlighted 40-file review beside a thread, a 500-turn thread, 200 subagent
runs, 2,000 folders).

- **Anything that can outgrow a screen is lazy.** The sidebar's Needs you, Pinned and Recents, the palette's
  results, the thread and the inspector's transcript, the review's diff and file strip, an open
  subagent tray, and the directory and model lists are `LazyVStack`s or `LazyHStack`s with stable
  ids. Eager stacks
  are for lists bounded by design (Settings rows, a dialog's checklist, a composer menu). A lazy
  stack in a height-capped, fixed-size scroll view still hugs a short list (the palette does).
  A list inside one of the thread's own rows is measured before it is nested: a 300-file changes
  card cost 20 ms a step nested and stays eager (one 250 ms build). A workflow of 200 subagents
  shows four tray rows at rest and two record lines in its turn; opened, the tray builds only
  the rows in view.
- **One view per row.** In a lazy `ForEach`, each element makes exactly one view: wrap an `if` or
  a `switch` in a container. A row that could be nothing (`if … else if …` with no `else`) makes
  SwiftUI build every row to count them, on every update: a 500-turn thread built 1,000 rows per
  streamed chunk until its rows were wrapped.
- **Rows are plain `Equatable` values.** Closures stay out of `==`. The highlight or the
  selection reaches a row as a `Bool`, so moving it redraws the row it leaves and the row it
  lands on; hover lives in the row itself. A store or the view model derives the rows once per
  change (`SidebarDerivation.lists`, `PaletteResults`, `DirectoryFilter`, the review's row cache): no
  filtering, sorting, or formatting in `body`.
- **A derivation is one pass over its inputs, once per change.** Group a collection once rather
  than filtering all of it for each group, and read what is memoized rather than building it again
  for a selection: the sidebar's lists derive once per change of what they read
  (`sidebarLists`), and a selection or a scroll derives nothing. At 1,500 agents in 200 spaces a
  status report took 59 ms and a selection 57 ms until the old tree's were.
- **Rows are cheap to build**, since scrolling builds them. Platform-backed modifiers cost most: a
  list row is a tap view rather than a `Button` (each brings an AppKit focus-ring view), and a
  control that shows only on hover (a diff line's `+`) is built only while hovered, in a slot that
  is always laid out.
- **The review pane scrolls at the cost of the lines coming into view.** Its rows are built only
  as they scroll in, from rows and colors derived once per file (highlighted off the main thread
  on the Mac and on iOS, landing in one change). A row compares its line and its note (a comment,
  or the editor), so a comment opening or landing redraws its line, not the 50 on screen. A
  fixed-height code line draws its gutter, numbers, sign and attributed code in one Canvas,
  rather than measuring separate text views for each part on every incoming row. Syntax colors,
  changed-word backgrounds, clipped long lines, scaled line numbers and full-line help remain;
  the row still owns accessibility labels, Comment actions and double-click handling. A
  hovered line's `+` is an image, not a `Button` (two AppKit views each, and a resting pointer
  hovers a new line every step). The right pane casts its shadow from its fill, and only while it
  floats: on its content, Core Animation redrew the shadow from the scrolling diff every step.
  `ListPerformanceTests` pins each: rows per scroll step, one row per comment, no thread row while
  the pane scrolls, no AppKit view for a hovered `+`, no shadowed layer while docked.
- **Hidden agents stay out of the visible one's updates.** Each mounted layout has a hosting view of
  its own (`AgentLayoutDeck`), and a hidden one is a hidden AppKit view: a scroll step, a keystroke,
  a streamed reply or a status report runs the visible layout's graph alone, and AppKit walks the
  same views and layers beside thirty hidden agents as beside none. In one view graph each hidden
  agent added about 0.4 M instructions to a scroll step and 1.2 M to a status report (a 1 pt step of
  the Changes pane: 10.3 M alone, 22.5 M beside 30 hidden agents, now 13.6 M; a status report 39 M,
  now 1.6 M). What still grows (a keystroke, 25 M alone and 35 M beside 30) is AppKit's
  display-cycle walks and SwiftUI's window-wide focus, which no public API reaches.
  `ListPerformanceTests` pins it by counts; `SHEPHERD_PERF_REPORT=1 swift test --filter
  HiddenAgentsReport` prints the instructions.
- **The overlaid sidebar casts its shadow from its fill**, as the floating right pane does
  (`nwFloatBackground`): on the sidebar itself, Core Animation redrew the shadow from its
  scrolling list every step.
- **The chrome around a field compares before it redraws.** The composer's control row takes an
  `Equatable` model of what it draws (`ComposerControls`), so a keystroke past the first
  character, or the field losing focus to a menu, rebuilds the field and never the chips.
  `ViewThatFits` builds and measures every alternative it is given, each with its tooltips and
  accessibility, whenever it is rebuilt, and that was half of a keystroke's main-thread time and
  a third of a menu's opening. It measures them again in the window's minimum-size pass, which
  the scene's hosting view runs from a zero-width proposal after every change to a platform
  view's intrinsic size (each keystroke in the field), so the row answers any proposal narrower
  than a real layout's without measuring (`ComposerControlsMinimum`): its minimum is never the
  window's, the thread column's is. The slash menu's matches are derived once per draft change
  (`SlashMatchCache`), ⇧⌘M and the thinking menu's command reach the composer without a pass
  over the thread, and the picker and the thinking menu compare their own inputs, so a composer
  redraw for something else leaves their rows alone. `ComposerMenuPerformanceTests` pins each
  as a count.
- **The composer changing height never reruns the thread.** Its measured height lives in its own
  observed value (`ComposerInset`), read only by the scroll view's inset modifier, so a question
  taking the card's place or giving it back (or Up next growing) redraws the composer, never the
  thread's body or its toolbar; the lazy stack only lays the rows on screen out again for the
  new inset (`ListPerformanceTests`).
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
