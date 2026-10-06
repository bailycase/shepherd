# Blank-thread recovery

The completed-worker thread still draws its messages above the tray and composer. The fix changes
scroll recovery, not the layout, controls, or styling. Design departures: none.

`AgentsPreviewTests.threadSubagentsDone` renders these images through `NativeThreadStore` and
`ThreadView`, in light and dark at text scales 1 and 1.3:

```sh
SHEPHERD_PREVIEW_DIR=/tmp/shepherd-blank-previews swift test \
  --filter 'AgentsPreviewTests/threadSubagentsDone'
```

- [Light](thread-subagents-done-light.png)
- [Dark](thread-subagents-done-dark.png)
- [Light, text scale 1.3](thread-subagents-done-x1.3-light.png)
- [Dark, text scale 1.3](thread-subagents-done-x1.3-dark.png)

These are normal-state previews, not a capture of the reported intermittent failure. The
marker-only regression in `ThreadTailGuardTests` fails before the original fix and passes afterward.
`ThreadTailFlowTests` checks the rendered transcript after a long live turn becomes a paged
history with completed workers, and after the tray disappears. The guard-disabled OS reproducer
is intermittent; guard-enabled recovery assertions remain required.

## Build 236 follow-up

Build 236 did not resolve the reported intermittent blank screen. The follow-up tests a second
recovery gap: a live reply is replaced with history, while SwiftUI still reports its removed ID
and the bottom marker as visible. Recovery must recognize the stale ID without needing another
visibility callback. The regression fails before the current-row check and passes with it.
A separate regression protects a reader who scrolls during recovery from a final jump to the tail.

`ThreadTailFlowTests.workersFinishingDuringLongTurnsKeepTheTranscriptVisible` streams two long
turns, completes workers, changes the row IDs at the live-to-history boundary, and checks painted
content in a 2000 by 870 window. It runs with both the native scroll view and its test adapter.
This sequence passes, but it has not reproduced the user's exact intermittent screen. The
follow-up does not claim to resolve every cause of blank content.

Validation for the follow-up passed the 53-test recovery, blank-screen, switching and scrolling
run, then the updated worker sequence and reader-interruption regressions. Streaming redraw
budgets, worker-tray control presses, 12 previews and the Dev build also passed. The four
completed-worker PNGs above are byte-for-byte unchanged on the new render. No design departures.

## Rendered reproduction attempts

`ThreadCompletionReproductionTests` checks recognized text in captured frames instead of trusting
scroll-target callbacks or counting any non-background pixel. It does not call the fixture's
forced-layout loop between streaming updates. Captures contain generated fixture content only.

The Xcode 26.6 optimized build ran with build 236's visibility check, temporarily without the
current-row-ID change. All 70 completion captures contained transcript text:

- 16 completion transitions in the standalone thread, with both scroll implementations.
- 54 transitions in the mounted workspace at 900 by 600, 2000 by 870 and 3200 by 1400. These use a
  real scratch `SessionServer`, stub pi, persisted history, running and completed workers, thread
  switching, window resizing and final agent status updates.

Representative final captures from the follow-up are saved as
[workspace](completion-probe-workspace.png) and [long turn](completion-probe-long-turn.png).
Two additional large-history captures passed using the follow-up. These checks did not reproduce
an empty transcript. False OCR matches caused early probe failures; the saved screenshots showed
visible text in each, so those were not instances of the reported bug.

The optimized run used an isolated scratch package containing the app integration test target.
The full package has an unrelated Swift 6.2 concurrency error in `NativeThreadStoreTests`. The
linked SDK matched Xcode 26.6; the host runtime was macOS 27.0 build 26A5353q. Thread rendering code
matches build 236. The base checkout has a later nested-tool projection change, but these fixtures
contain no nested tool calls.

AppKit captures redraw the view, so those earlier probes could not rule out a stale compositor
frame. A later probe verified that `CGWindowListCreateImage` can capture a process's own windows
without Screen Recording permission. `ThreadWindowCapture` loads that deprecated public function
at runtime because the newer SDK marks it unavailable to Swift. It uses only its off-screen
scratch window IDs. It does not ask AppKit to redraw or capture the user's windows.

The expanded matrix checks worker completion, hidden completion, resize, composer height, detached
readers, empty/failing/cancelled replies, thinking-only/tool-only replies, history replacement and
very long replies with both native and SwiftUI tail following. Nothing reads or changes the user's
running Shepherd or its support directory. These results do not yet establish the cause of the
reported failure.

The failed deterministic checks found additional defects:

- Recovery attempts stayed exhausted for the thread's lifetime. A later turn now gets fresh bounded
  attempts when it finishes, without clearing reader detachment or cooldown.
- Completion while hidden could stop recovery until another geometry callback. Making the same
  layout visible again now rechecks it, without remounting the view.
- An escape-heavy newest message could exceed the history reserve and leave a finished snapshot
  with neither rows nor a paging cursor. Budgeting now keeps one size-bounded newest message and
  its cursor. A 128 KiB bound on the encoded message and cursor prevents oversized producer IDs
  from consuming the rest of the frame.
  Tests exercise both the real cached-history path and the uncached parity path, control characters
  split over 128 blocks, wrapped remote-frame size, and an oversized producer ID.

These are proven defects, but not a reproduction of the user's random blank completion.

An isolated source export of build 236, tag commit `b65912c0`, also passed the compositor probes:
40 completion boundary cases plus 16 standalone and 54 full-workspace completion captures.
This run used Xcode 26.6 release optimization and the unmodified build 236 app sources.
Only integration test sources and the temporary package's test target list differed. These
results still use the host's macOS 27 runtime; they do not rule out an OS-specific failure.

The follow-up passed 44 integration tests across the guard, scroll, blank-screen, worker-motion,
completion-reproduction and boundary suites, plus the 16 snapshot budget unit tests and real-server
budget test. The matrix covers 42 parameterized boundaries. The Dev build and 14 documentation
checks also passed. Vision's test helper now uses CPU recognition and checks the full screenshot;
macOS 27's GPU path failed independently of Shepherd, and tiny OCR crops failed even on CPU.

Run the probes with:

```sh
swift test --filter 'ThreadCompletionReproductionTests|ThreadCompletionMatrixTests'
```

They leave generated screenshots in the test process's temporary `shepherd-completion-repro`
directory and take several minutes. The failed-regression checks remain in `ThreadTailGuardTests`.
