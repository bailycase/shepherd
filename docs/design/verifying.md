# Verifying visuals

> Read when you check a UI change: previews, windows, motion probes, the Component Gallery.

- **Previews:** `ShepherdPreviewTests` render every surface offscreen, in light and dark:
  - thread states (idle, running, thinking, queued, failed, prose, question, empty, starting
    before and after the delay, restoring from disk, a hovered turn, "Jump to latest" over the
    fade, a long stretch of burst lines, a turn between tools ending in "Thinking…") and the
    activity-line states
  - the composer and its menus
  - the queue (the Queue & steer boards): Up next over a running thread with a hovered row and
    a draft (Stop outlined beside Send), a Steering row under a steered message, the editor with
    a Deleted row and the Send menu, every row and stack state, and "From the queue" and
    "Steered" in the thread
  - the subagent tray (every state, a hovered waiting row, one card with Up next, the record
    lines, and its iPad and iPhone sizes), a thread with it live, finished, and with a queue,
    and the inspector
  - the review pane, and its Commit… sheet in every state
  - the palette, the toolbar, the sidebar at each row density, and the window at its minimum
  - the terminal panel: two tabs under the thread (`app-window-terminal-panel`), a running tab
    (`app-window-terminal-running`), maximized (`app-window-terminal-maximized`), the new terminal
    menu (`app-window-terminal-menu`), and its parts on their own (`terminal-parts`: the folded
    thread, the selection bar, the tab menu and the drag line)
  - every Settings page, sheet, and dialog
  - the empty states

  They write `<surface>-<light|dark>.png` into `$SHEPHERD_PREVIEW_DIR` (the suites are skipped
  when it is unset), so you, or an agent, can look at them:

  ```sh
  SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
  ```

- **Text size:** `Preview.renderMatrix` renders light and dark at each text scale (1 and 1.5 by
  default; the Mac's largest Text size is 1.3), writing `<surface>-x1.5-<light|dark>.png` beside
  the others. Use it where clipping or wrapping could hide, and render empty and long text too.
- **Real data:** a preview is driven from the real producer (the store, the extension's output, the
  formatter), never strings copied from the board; copy that differs from the board is a departure
  to list or a bug to fix.
- **Controls:** `ControlPress` (Tests/ShepherdTestSupport) presses a control by accessibility label
  and measures its hit area, in a process of its own (docs/testing.md › Pressing a control).
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
