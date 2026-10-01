# Performance audit, 2026-09-30

An isolated audit of the Mac app and its server, initially at `f6294e78`, in the
`Shepherd-performance-audit` worktree. The fixes were subsequently merged with `nightly`
at `e6b195c8` for PR validation. No installed app, live session, or original checkout
was changed. The native-child provider fix was handled separately in PR #169.

## Setup

Mac16,5, 48 GiB RAM, 16 logical CPUs, macOS 27.0 beta, Xcode 27.0, Swift 6.4.
Reports use optimized builds with debug counters enabled. The windows are offscreen; CPU,
instruction counts, and view counts are not displayed FPS. Other apps and independent test
runs shared this machine, so isolated timing deltas need confirmation before attributing them
to a change.

```sh
SHEPHERD_PERF_REPORT=1 SHEPHERD_BENCHMARK=1 swift test \
  -c release -j 6 -Xswiftc -DDEBUG -Xswiftc -enable-testing \
  --disable-automatic-resolution --no-parallel \
  --filter '(DataPathBenchmarks|RenderCostReport|HiddenAgentsReport|IdleCostReport|ListPerformanceReport)'
```

## Measured findings

### F1. Streamed code rendering, reduced

A growing Swift fence, about 100 lines, took 36.2 ms main-thread CPU per chunk in the baseline,
with 15 chunks 100 ms apart and the median of three samples. A separate repeat measured
37.6 ms. Ordinary streamed prose measured 6.3 ms; stats-only refresh measured 0.2 ms.

Sampling the test host showed substantial SwiftUI attributed-text and color-resolution work.
Resolving syntax colors before drawing measured 34.7 ms; resolving the inherited foreground
as well measured 34.1 ms. A single horizontal scroll view with SwiftUI text measured 34.4 ms.
These experiments were reverted.

The Mac code block now uses a selectable AppKit text field, retaining the syntax colors,
Geist Mono, text scale and Copy button. Bridging each distinct syntax color once avoids
SwiftUI resolving every attributed run. iOS keeps its existing SwiftUI text. The first native
prototype measured 19.4 ms; a repeat with the fitting layout measured 17.9 ms. The retained
version uses one horizontal scroll view so a resize across the fit boundary does not replace
the field that owns a selection. It measured 20.7 and 21.2 ms, about 41% less main-thread CPU
than the 36.2 ms baseline. The post-merge validation measured 12.8 ms, with 16.8 ms process CPU
and the same seven highlight renders. This variation is why the conservative comparison uses
21.2 ms. These reports measure CPU, not smooth displayed frame pacing.

The existing highlight budget still passed: a burst renders the growing fence at most twice,
and settlement renders the complete fence once. Tree-sitter work is already throttled and
runs off the main actor. Light/dark previews were inspected. Regression checks cover Unicode
copy to a scratch pasteboard, selection across stream and highlight updates, selection
clamping after replacement, retained field identity across resizing, and unwrapped overflow.

### F2. Bulk history restoration can stall the server queue

Baseline JSON decode and projection for a 12.8 MiB history took 81.5 ms and 9.35 ms respectively.
A single reload produced a 14.5 ms worst queue probe. A stressed server run starting 30 agents
with 4 MiB histories produced a 146.2 ms worst queue probe, with two probes over 16 ms; all were
ready in 569.1 ms. This benchmark starts sessions directly and bypasses the app's throttled,
visible-first AgentStartQueue, so it is not a literal app-launch measurement.
State reads remained nonblocking and none of 150 connection attempts was refused.

A later run after the clipping change measured 56.4 ms worst queue time and 432.6 ms until all
30 agents were ready. Post-merge validation measured 91.5 ms worst queue time. These differences
are not proof that clipping fixed startup. Scheduling and concurrent load vary, and the queue
still stalls. Off-queue JSON decoding does not remove history projection and context work
from the server queue.

### F3. Clipping copied the entire discarded output, now fixed

Message projection, delivery origins, and question records used `Array(text.utf8)` to clip
text. For oversized output that copied the entire input before retaining at most 16 KiB.
They now share the existing clipping helper, which slices the UTF-8 view at the budget and
backs up over continuation bytes. It copies only the retained prefix. Budgets, truncation
flags, and UTF-8 scalar boundaries are unchanged.

The new `largeOutputProjection` report isolates projection from JSON decoding. Each result
is the median of five samples of 100 projections.

| Input | Before | After, first run | After, validation run |
| --- | ---: | ---: | ---: |
| 16 KiB | 0.342 µs | 0.123 µs | 0.141 µs |
| 1 MiB | 13.471 µs | 0.476 µs | 0.580 µs |
| 12 MiB | 155.297 µs | 0.494 µs | 0.471 µs |

The 12 MiB case is about 330 times cheaper. This is a projection result, not a claim that the
whole app is 330 times faster. A paired optimized helper check also compared both algorithms
in one process and confirmed equal output for every byte budget across short Unicode inputs.

```sh
SHEPHERD_BENCHMARK=1 swift test \
  -c release -j 6 -Xswiftc -DDEBUG -Xswiftc -enable-testing \
  --disable-automatic-resolution --no-parallel \
  --filter '(UnitTests|NativeThreadTests|DataPathBenchmarks)'
```

### F4. Several existing protections are working

- A restored 12-agent workspace produced zero idle animation-clock frames over four seconds;
  median main-thread CPU was 0.3 ms.
- Hidden workspace participation stayed at 73 views, five tracking areas, and 284 layers with
  zero, ten, or thirty hidden agents. Hidden-agent status updates built no layout bodies.
- Status reports for 30, 100, and 300 agents cost 0.016, 0.022, and 0.029 ms and did not rewrite
  `state.json`.
- Scrolling a 50-turn thread cost 6.61 ms per upward step and 5.56 ms per downward step on
  average. These offscreen timings do not establish visible frame pacing.

Palette cancellation, hidden wheel monitors, thumbnail demand, and terminal-parser
backpressure remain candidates, not confirmed bottlenecks or completed fixes.

## Validation

- All 2,870 unit tests passed in the optimized counter-enabled build.
- All 38 `NativeThreadTests` and seven `DataPathBenchmarks` passed, for 2,915 selected tests total.
- Projection boundary coverage now checks every split position within two-, three-, and
  four-byte Unicode scalars. Existing multi-block, delivery-origin, oversized-send, and
  clipped-history checks remain intact.
- The post-merge Dev Xcode build succeeded with resolved dependency versions preserved.
- Before the native-renderer change, a separately identified Dev app ran with 12 scratch
  agents and a 4.7 MiB local history. Stub pi received twelve each of `get_state`, `get_messages`, and `get_session_stats`.
  All launch directories and pi homes were inside scratch paths. The environment had no API
  key variables; no managed-provider configuration existed. No real model request was made.
- The app had an onscreen 1440 by 900 window. Window capture was unavailable, so this run
  verifies launch and RPC startup, not visual correctness or displayed smoothness. The app
  was stopped and its pane closed afterward.
- Post-merge validation passed 3,036 selected tests: all 2,983 unit tests, 38 native-thread tests,
  seven data-path benchmarks, seven app checks/reports, and one prose preview. The light/dark
  preview images were inspected. The 12 MiB projection measured 0.467 µs/row.
- An expanded scrolling-suite run was stopped after Vision OCR repeatedly failed to create its
  compute operation on this macOS 27 beta. A standalone Vision request drawing "Jump to latest"
  reproduced the same `e5rtError` without Shepherd code. No test assertions were relaxed; this
  broader OCR-based validation remains blocked locally.
- `git diff --check` passed. DESIGN.md records the Mac's native selectable-code implementation.

The baseline, targeted reports, sampled stack, validation logs, and scratch app are under
`/tmp/shepherd-perf-audit/` on the audit machine. This report retains their useful conclusions;
the temporary artifacts are not repository inputs.
