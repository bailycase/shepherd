# Pinned performance measurements — 2026-11-02

[Archived samples, compiler inputs and commands](artifacts/README.md) accompany this report.
[Full sample distributions](distributions.md) keep Debug UI separate from Release data paths.
Paths in the original run records refer to the audit machine's scratch checkout, not user runtime.

## Environment and scope
- Commit: `f80d011324d924395664c2203a46db6a18f49aef`; measurements ran 2026-11-03 UTC (local Nov 2).
- Mac16,5 / Apple M4 Max, 16 CPU cores, 48 GiB RAM; macOS 27.0.1 (26A434).
- Xcode 27.0 (27A5228h), Apple Swift 6.4 (swiftlang-6.4.0.27.1).
- Release: unchanged production sources, `-O -whole-module-optimization -enable-testing`, no DEBUG; reduced test membership, not a shipping app build.
- Debug UI: native SwiftPM Debug, real off-screen AppKit/SwiftUI windows; not app/device/frame-rate performance.
- Allowlisted child environment and scratch HOME; linked existing test isolation; no installed Shepherd, user auth, provider, model, device, focus/input, or app launch.
- Existing dependency artifacts cloned into this checkout; no new dependency/download or global-cache mutation; no engine required.

## Release results — individual samples → median (n=3 unless stated)
| Workload | Samples | Median |
|---|---|---:|
| History decode, ~1.1 MiB / 240 messages | 8.151, 7.596, 7.384 ms | 7.596 ms |
| History decode, ~4.3 MiB / 944 messages | 28.900, 28.416, 28.627 ms | 28.627 ms |
| History decode, ~12.8 MiB / 2816 messages | 84.370, 85.120, 85.544 ms | 85.120 ms |
| History projection, same three sizes | full samples in distributions.md | 0.699 / 2.903 / 8.697 ms |
| Thinking, 1000 ×77-byte chunks | 5.534, 5.526, 5.549 ms | 5.534 ms |
| Thinking, 2000 ×77-byte chunks | 13.327, 13.020, 14.061 ms | 13.327 ms |
| Thinking, 4000 ×77-byte chunks | 31.553, 30.378, 28.981 ms | 30.378 ms |
| Delta decode, 5000 events/sample | 3.440, 3.295, 3.327 µs/event | 3.327 µs/event |
| Delta handling, 0 prior tool rows; 2000 events/sample | 2.442, 2.402, 2.445 µs/event | 2.442 µs/event |
| Delta handling, 10 prior tool rows | 5.246, 5.100, 4.951 µs/event | 5.100 µs/event |
| Delta handling, 50 prior tool rows | 15.200, 15.635, 15.463 µs/event | 15.463 µs/event |
| Ready snapshot round-trip, 50 rows /182504 encoded bytes | 0.095, 0.065, 0.061 ms | 0.065 ms |
| Unchanged-revision snapshot round-trip | 0.031, 0.020, 0.039 ms | 0.031 ms |
| Stub startup, 8 agents ×~4 MiB, all ready | 108.901, 147.633, 150.376 ms | 147.633 ms |
| Stub startup, 30 agents ×~4 MiB, all ready | 276.676, 265.294, 273.333 ms | 273.333 ms |
| NativeThreadStore tail refresh, 50 turns/100 history rows | 0.326, 0.343, 0.223 ms | 0.326 ms |
| NativeThreadStore tail refresh, 500 turns/1000 history rows | 2.453, 2.316, 2.165 ms | 2.316 ms |
| NativeThreadStore tail refresh, 2500 turns/5000 history rows | 10.811, 10.953, 9.850 ms | 10.811 ms |
| State JSON encode, 30/300/3000 agents | full samples in distributions.md | 0.229 / 1.970 / 19.072 ms |
| State JSON decode, 30/300/3000 agents | full samples in distributions.md | 0.224 / 1.793 / 18.140 ms |
| Framing 100 ×1MiB frames, 1KiB fragments | 12.890, 12.641, 13.075 ms/batch | 12.890 ms/batch |
| Framing 100 ×1MiB frames, 64KiB fragments | 11.885, 11.175, 11.766 ms/batch | 11.766 ms/batch |
- Tail-refresh/state/framing scratch workloads use one unmeasured warmup, then three samples. Existing DataPathBenchmarks include first-use costs (no separate warmup).
- Status CPU medians for 60 reports/sample: 30/100/300 agents = 0.027/0.081/0.511 ms/report; state.json was not rewritten.
- Queue reload: one three-turn workload each at 4/12 MiB; worst probes 2.643/1.200 ms, 0/122 and 0/242 probes >16 ms. Not a stable tail estimate.
- Large-output projection clips 16KiB/1MiB/12MiB inputs to 16KiB; medians 0.223/0.671/0.569 µs/row (100 projections/sample).

## Debug off-screen UI — three independent process runs
| Workload | Individual workload values | Median |
|---|---|---:|
| Thread open, 50 turns | 113.1, 103.2, 125.1 ms | 113.1 ms |
| Thread open, 500 turns | 118.1, 128.5, 131.2 ms | 128.5 ms |
| Store refresh, 50 turns; mean of ten tail updates/run | 1.2, 1.3, 1.3 ms | 1.3 ms |
| Store refresh, 500 turns; mean of ten tail updates/run | 10.6, 10.8, 11.0 ms | 10.8 ms |
| View update, 50 turns; mean of ten updates/run | 13.9, 14.4, 14.6 ms | 14.4 ms |
| View update, 500 turns; mean of ten updates/run | 33.2, 32.7, 35.2 ms | 33.2 ms |
| Palette open, 40 results | 25.3, 21.6, 15.3 ms | 21.6 ms |
| Palette open, 1000 results | 30.4, 38.9, 40.1 ms | 38.9 ms |
- Thread initial `thread.rowBuilder` = 80 for both sizes in all runs; palette open `palette.row` = 10/14 at 40/1000 results. Initial construction stays bounded in these fixtures.
- Full scroll/render counts and individual workload outputs are retained in `distributions.md` and `debug-lists-{1,2,3}/full.log`.

## Supported conclusions and limitations
- Historical JSON decode dominates projection here; both increase approximately with bytes. This is not model/network/startup latency attribution.
- Tail-only store refresh scales with retained history despite unchanged older messages; this measures refresh/merge/derive together, not an isolated derive function.
- Prior tool rows increase per-delta handling cost; Debug view-update costs also increase with loaded thread history despite bounded initial row construction.
- Framing remained inexpensive relative to history decode in these synthetic fixtures; JSON framing samples exclude JSON parsing and transport.
- Snapshot fixture repeats an already-ready revision; its “fresh” request does not establish uncached changed-revision build cost.
- Relaunch means Python stub processes/history readiness, not the actual pinned engine, restored app, paid model, or network providers.
- Existing relaunch `connectsRefused` reads before its detached connector finishes; raw zeros are retained but excluded from success-rate conclusions.
- n=3 supports medians/ranges only, not stable p95/p99. Existing within-workload scroll/probe quantiles are descriptive only.
- No memory/idle baseline, sustained soak, image-hydration, large-diff-retention, or downstream Ghostty-parser backlog measurement. No iOS simulator/device run or competitor ranking.
- Local no-DSN diagnostics differ from production. Mixed-release Sentry spans/gauges cannot be pooled with these pinned measurements or establish causality.

## Checks, build cost, and artifacts
- Normal Release test build failed after 261.408 s: ChangesEngineTests references DEBUG-only ChangesGit.runs; ResponseTimingTests references DEBUG-only RPCThreadState.bytesOfLastSnapshot. Infrastructure finding, not product performance failure.
- Reduced Release build 393.31 s (396.058 s command incl tests); Debug build 161.28 s (169.083 s command incl tests). Build time excluded from workload samples.
- Remaining Release server commands: 5.569/3.242/3.336 s; Debug repeat commands: 6.520/6.478 s. Standalone compile/run: 1.314/0.708 s.
- Existing mobile `ThreadStoreCheck.swift` passed against Release Mac modules (correctness only); compile/run 2.339/1.039 s. A log-directory/binary naming collision was caught before launch; retained in mobile-thread-wrapper-error.txt.
- All actual benchmark/check processes exited 0; initial full Release build exited 1. No timeout or flaky retry. `git diff --check` passed.
- Only checkout edit: DataPathBenchmarks.swift caps 5/15 repetitions at 3 and prints raw samples; no production edits or commits. See benchmark-instrumentation.diff.
- Scratch root: `/tmp/shepherd-perf-2026-11-02`; archived distributions: `distributions.md`, machine-readable `artifacts/measurements.json`; environment: `artifacts/environment.json`.
- Every run retained `command.json`, `result.json` (exit/elapsed), `full.log` in scratch. Commands/results are also archived under `artifacts/runs`; compiler flags/source lists under `artifacts/release-compiler-inputs.json`. Full logs remain local only.
- Reproducible harness: `reduced-release/Package.swift`, `selection.json`, copied benchmark/support sources, `ExtraDataPaths.swift`, and `run.py`; original production sources resolve to pinned checkout.
- Unmeasured follow-ups have existing anchors: NativeThreadTests/aSubagentTranscriptPagesFromItsSessionFile; ResourceDiagnosticsTests/serverCountersAndLifecycleDurationsFollowTheOwnedSession; OutputDeliveryTests/aStalledRendererBackpressuresTheChildWithoutLosingBytes. These are correctness/counter anchors, not supplied timings.
