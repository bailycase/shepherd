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

## In-app measurement still needed for A4

`swift test` has no AppKit window, so the Ghostty surface, its scrollback, and hidden-pane parsing are measured in the running app:

1. Build `Shepherd (Dev)`, create N agents (10 and 30), let each print 2,000 lines.
2. Record footprint: `footprint -p <pid>` or Xcode Memory gauge, before and after. Divide the delta by N and subtract 6.7 MiB to get Ghostty cost per pane.
3. With one agent visible and the rest hidden, run `yes | head -c 50M` in a hidden pane and read `sample <pid> 5` for time in libghostty parsing.

Record results here before starting A4. If Ghostty is under about 10 MiB per pane and hidden parsing is under a few percent CPU, A4 is not worth its mounting-rule risk.

## Queue fairness (F2)

Not measured yet. `screen.feed` at 50 MiB/s means a 256 KiB PTY read holds the server queue about 5 ms. Snapshots hold it under 10 ms. Neither is a stall on its own; the risk is many sessions flooding at once. Revisit only if in-app profiling shows queue wait.
