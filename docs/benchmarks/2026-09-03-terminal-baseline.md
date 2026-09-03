# Terminal baseline, 2026-09-03

Commit `6391161` on `nightly`. Apple M4 Max, 48 GB, Swift 6.3, release build.

```bash
SHEPHERD_BENCH=1 swift test -c release -Xswiftc -enable-testing \
    --filter TerminalBenchmarkTests 2>&1 | grep BENCH
```

`Tests/ShepherdSessionsTests/TerminalBenchmarkTests.swift` prints one line per measurement. Debug builds run SwiftTerm roughly 10x slower; compare release to release only.

## Host side (measured)

| Measurement | Value | Reading |
| --- | --- | --- |
| `screen.feed.80x24` | 53.4 MiB/s | SwiftTerm parse of TUI-style repaint output |
| `screen.feed.200x60` | 48.9 MiB/s | same, large grid |
| `screen.snapshot.80x24` | 4.3 ms, 126 KB | attach snapshot with 2,000 scrollback lines |
| `screen.snapshot.200x60` | 9.5 ms, 252 KB | same, large grid |
| `state.update.10agents` | 0.23 ms | validate + encode + atomic write of `state.json` |
| `state.update.50agents` | 0.54 ms | |
| `state.update.200agents` | 1.83 ms | |
| `host.memory.perSession` | 6.7 MiB | PTY + SessionScreen with full scrollback, per live session |

## What the numbers say about items A2 and A4

**A2 (skip unchanged status persist, skip no-op resize).** A status write costs under 2 ms even at 200 agents, and the status extension already suppresses repeated statuses before they reach the socket. Expected desktop gain is not measurable in normal use. It stays worthwhile only as a guard against reconnect storms, and because it is a one-line change with a test.

**A2 no-op resize.** Cost is a `SIGWINCH` repaint by pi, not host CPU. Local-only use never hits it after the remote-grid fix in `df94b25`; keep it small or drop it.

**A4 (cold-park hidden surfaces).** The host model is 6.7 MiB per session and a snapshot restore is under 10 ms, so parking a Ghostty surface and restoring from the host snapshot is cheap on the host side. The gain depends on the Ghostty surface cost, which this harness cannot measure.

## In-app (measured, Release build of `Shepherd (Dev)`)

`swift test` has no AppKit window, so Ghostty cost was measured by launching the app with `SHEPHERD_SUPPORT_DIR` pointed at a seeded `state.json` of N global shells whose `restoreCommand` prints 2,100 styled lines. Global shells are always mounted, so all N panes have live Ghostty surfaces with one visible. Footprint read with `footprint -p <pid>` 30 s after launch, two runs each.

| Mounted panes | Footprint | Per pane (from slope) |
| --- | --- | --- |
| 1 | 278 MB | |
| 10 | 389 MB | |
| 30 | 670 MB | 15.6 MB (10 to 30) |
| 60 | 1,146 MB | 15.9 MB (30 to 60) |

One run at N=10 read 168 MB, likely a window-size race at launch; discarded. Steady cost is about 16 MB per mounted pane, of which 6.7 MB is the host model. So a parked Ghostty surface frees about 9 MB per pane.

Hidden-pane CPU: 30 shells, one visible, `yes` flooding a hidden pane. Process CPU 158 to 166 percent. `ps -M` shows two hot threads: one at 97 percent (`shepherd.pty`, SwiftTerm `Terminal.feed`, dominated by `scroll`) and one at 57 percent (libghostty `in-memory-output`, `terminal.Terminal.print`). Idle 30-pane CPU is 0.3 to 0.5 percent.

## After cold parking (same procedure, `parkDelay` 30 s, hot set 4)

| Mounted panes | Before park (25 s) | After park (55 s) |
| --- | --- | --- |
| 30 | 979 MB | 691 MB |
| 60 | 1,754 MB | 912 MB |

Flood in a hidden pane, 30 panes: process CPU 163 percent before parking, 101 percent after. The remaining core is host-side SwiftTerm parsing, which stays live by design.

## Decision on A4

Hidden Ghostty parsing costs about 0.6 cores per flooding hidden pane, and each mounted pane holds about 9 MB of surface memory. Cold-parking hidden surfaces removes both, at the cost of a sub-10 ms snapshot restore on reveal. That is worth doing once agent counts reach 10 or more, so A4 proceeds. SwiftTerm on the host is the larger CPU share and cannot be parked; it is the F2 concern and a separate item.

## Queue fairness (F2)

Not measured yet. `screen.feed` at 50 MiB/s means a 256 KiB PTY read holds the server queue about 5 ms. Snapshots hold it under 10 ms. Neither is a stall on its own; the risk is many sessions flooding at once. Revisit only if in-app profiling shows queue wait.
