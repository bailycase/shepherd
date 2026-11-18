# Shepherd Instruments audit

Tested `nightly` commit `355a60e5104b9a3339f59de004b8b84c6dde9dd2` on 2026-11-18.

This is a partial runtime audit, not an exhaustive profile of the app. The strongest measured lead is repeated receive-buffer allocation in the host. App samples also point to SwiftUI updates and layout. Neither establishes a shipping-build regression or an end-to-end speedup. The initial audit made no product changes. The follow-up below records the changes included with this report; the remaining sections describe the original audit.

## Follow-up results

Follow-up work used `nightly` at `50d4a0381` before integration onto a newer base.

- **F1:** `RPCSession` now reuses its 64 KiB receive buffer. All 25 transport tests passed before and after. Six alternating optimized standalone trials measured median times of 159.02 ms with fresh arrays and 64.23 ms with reuse. This isolates allocation overhead, not app throughput. Short backpressure-test timings did not establish an end-to-end gain. The tradeoff is 64 KiB per open stdout stream. The buffer is released on EOF or shutdown, even if the session remains retained for late consumers.
- **F2:** The rich-thread scroll benchmark now sends reader-scroll intent before each step, matching the existing input path. Without it, tail-follow counteracted the simulated scroll. The corrected 500-line-code fixture moved 12,000 points in each direction rather than reporting 373,777 points upward. This is a measurement correction, not a product speedup. Nineteen baseline tests and the focused corrected report passed. Additional streaming diagnostics passed, but no production UI change was justified. A mixed-phase `/usr/bin/sample` capture, not Instruments, located work in SwiftUI scroll-content measurement; layout, resize and worst-step costs remain open leads.
- **F3:** All 32 mounted-budget, lifecycle and mounted-cost tests and two private memory diagnostics passed. A six-cycle pressured follow-up captured live malloc totals of 955,997,238, 1,068,174,531 and 1,070,255,859 bytes at phases 0, 3 and 6. Footprint plateaued after cycle 1. Heap code-field counts were 420, 500 and 500, while mounted counts stayed at 340. The extra objects' retaining owners were not identified. This supports bounded warming in that instrumented fixture, not a leak-free guarantee or an explanation for the earlier uninstrumented 316 MB jump. No memory-policy change was made. In the earlier uninstrumented pressured fixture, footprint increased from 1,225,411,080 to 1,541,245,448 bytes between cycles 2 and 3; that is the 316 MB jump, not the original RSS navigation range.

The F1 standalone workload used 200,000 iterations per trial, reading 512 bytes from `/dev/zero` into a 64 KiB array and copying those bytes into `Data`. One non-inlined function allocated the array per call; another reused a class property. A checksum consumed each chunk's count and first byte. Six trials alternated fresh/reused order, timed with `DispatchTime.now().uptimeNanoseconds`, compiled with `swiftc -O`. This is a recipe for repeating the mechanism comparison, not an app benchmark.

The 19 F2 baseline tests were `ThreadStreamingTests` plus `MountedSwitchTests` (6), then `RenderCostReport` plus `HiddenAgentsReport` (13). Run the reports with `SHEPHERD_PERF_REPORT=1`. The scroll correction is limited to `RenderCostReport.scrollingAndResizingRichThreads`; other thread-scroll benchmarks must validate reader intent before their numbers are used. Raw logs and private diagnostics are not independently available from this repository, so treat their figures as reported observations rather than reproducible repository-test results.

The UI and memory diagnostics used an optimized build with DEBUG probes, off-screen fixtures, and accelerated idle passes where stated. Stack logging perturbed the heap run. They are not shipping-Release or normal-timer measurements. Private diagnostics and raw captures are not part of the repository.

## Environment and method

- Apple M4 Max, 48 GiB RAM; macOS 27.0.1; Xcode and Instruments 27.0, build `27A5228h`.
- Unoptimized Dev Debug build, ad hoc signed, with a disposable bundle identifier. These are not Release timings.
- Separate scratch support, home, pi, hooks, MCP configuration and repository. Workloads used stub agents, not live model calls or installed Shepherd state.
- The app and its supervised host were profiled separately. Captures were sequential, never simultaneous. Stub agents generated the workload.
- The user approved opening the isolated app. Accessibility queries and control actions targeted its PID only. No global keyboard or mouse events were posted.
- Other work on the Mac was uncontrolled. Operator `df` checks showed free disk space falling from roughly 54 GiB to 19 GiB during the audit. We avoided another cold test build and maintained a 15 GiB reserve.

Time Profiler exports use 1 ms sample weights. Percentages below describe sampled on-CPU stacks, not elapsed time. Inclusive stacks overlap. SwiftUI update intervals also overlap and must not be added into a CPU percentage or counted as presented frames.

## Initial audit findings and recommended order

### F1. Investigate the host's per-drain receive buffer first

At the audited commit `355a60e5104b9a3339f59de004b8b84c6dde9dd2`, `Sources/ShepherdSessions/RPCSession.swift:544` created a zero-filled 64 KiB byte array each time `drainStdout` ran.

| Recording | Host CPU samples | Samples including array initialization and drain work |
| --- | ---: | ---: |
| Exploratory eight-agent run, requested 15 s | 769 | 251, or 32.6% |
| Follow-up eight-agent run, requested 10 s | 462 | 157, or 34.0% |

The first trace contains 685 samples with `drainStdout`, 404 with `feedStdout`, and 393 with `receiveRecord`. Those counts overlap. Its 251 buffer-related samples represent about 251 ms of sampled CPU, not 32.6% of the recording's wall time.

The follow-up verified eight agents, a selected seeded transcript, and an advancing live request before capture. It did not verify every agent's stream throughout recording. The exploratory run did not fully validate workload setup.

Recommendation: reproduce this stack on an optimized, isolated build and measure drain frequency before changing it. If it persists, evaluate reusing the existing session's receive buffer. Do not introduce a buffer pool or change queue ownership on this evidence. No improvement percentage has been measured.

### F2. Focus app investigation on transcript updates and layout

The exploratory app Time Profiler recording contained 894 CPU samples, including 808 on the main thread:

- `AG::Subgraph::update` appeared in 494 of all 894 samples, or 55.3%.
- NSView subtree layout appeared in 179 of 808 main-thread samples, or 22.2%.
- `NativeThreadStore.refresh` appeared in 50 of 894 samples; `derive` in 33.

A separate SwiftUI recording contained 150,691 update rows: 2,008 View Body Updates, 148,606 Other Updates and 77 Representable Updates. Body descriptions included `SHCodeBlock.body` 217 times, `SHProseBlockView.body` 150 times and `PlatformSelectableTextChildView.body` 125 times.

A later 25 s mixed-navigation recording captured six heading-verified switches between two seeded threads, followed by populated Changes and Files views, Automations and Search. It contained 3,446 app CPU samples, including 3,198 on the main thread. Of those main-thread samples, 926 included `AG::Subgraph::update`, or 29.0%, and 901 included NSView subtree layout, or 28.2%. The sample timestamp span was 22.57 s. The stacks overlap and do not isolate individual actions.

This locates work; it does not establish unnecessary invalidation. The recordings are separate, the initial selected streaming target was not verified, and no presented-frame rate was measured. The one/eight-agent follow-up app captures contained only 16 and 12 samples, too few to explain the difference.

Recommendation: capture a verified visible live reply and repeated thread switches, correlate existing thread signposts with body updates and hitches, then identify the view or state change responsible. Do not rewrite the list or remove `AnyView` based on these aggregate counts. Source review rejected a blanket claim that the project's `AnyView` sites defeat diffing.

### F3. Memory numbers are a baseline, not evidence of a leak

During a mixed navigation run, 19 targeted `ps` samples per process reported:

| Process | RSS range |
| --- | ---: |
| App | 268,048 to 362,608 KiB |
| Host | 63,904 to 74,160 KiB |

These are operating-system RSS samples, not Instruments allocation data or physical footprint. Activity Monitor was attached during sampling. Search obstructed some navigation, and opening Settings coincided with the largest app step. Sampling intervals were irregular. This is a perturbed navigation baseline, not retained growth after returning to the same state.

Allocations and Leaks recordings were saved, but no usable allocation or leak metrics were extracted. Their absence from the exported table inventory does not prove zero leaks or that the instruments recorded no data.

Recommendation: measure repeated long-history switches with a return-to-baseline phase, live allocations and physical footprint. Cover the existing mounted-thread release and restore behavior before changing retention policy.

## Workload validation and rejected comparisons

Follow-up runs used fresh scratch state and an explicit `STUB_PI_STRESS=150,200,600,30` in the stub launcher. Remote state confirmed exactly one or eight created agents. Agent 0's snapshot revision advanced from 11 to 31 in the one-agent run and 76 to 136 in the eight-agent run. Accessibility inspection found the selected `stress agent 0` heading and seeded turn content.

This verifies pre-capture state, not continuous visible rendering or all eight agents streaming. The latest history page contained 50 messages; the configured 150-turn seed was not independently counted in full.

Each condition had one 10 s app capture followed by one 10 s host capture. The one-agent host had 70 samples; the eight-agent host had 462. These are not repeated, phase-aligned measurements, so they do not establish scaling.

An earlier three-window comparison produced only 9/10/9 and 21/17/7 app samples. Its selection and workload were not validated. It is excluded from performance comparisons. Numeric exports and logs remain, but the user approved deletion of those invalid raw traces.

## Coverage

A source inventory covered the major app areas. Runtime coverage is narrower. Opening a control is not a performance benchmark.

| Area | Runtime evidence | Remaining gap |
| --- | --- | --- |
| Host RPC and thread data | Time Profiler, exploratory and validated fixtures | Optimized confirmation, per-message latency and queue depth |
| Transcript, markdown and code blocks | Time Profiler, SwiftUI, selected seeded transcript | Verified continuous tail rendering, frame pacing |
| Thread count and hidden threads | Exact one/eight-agent state checks; six verified thread switches during mixed CPU capture | Controlled scaling, per-switch latency, retention soak |
| Idle app and host | Short Time Profiler captures; app SwiftUI and idle hitch recording | Longer wakeup/CPU baseline; idle hitches do not measure scrolling |
| Search | Accessibility navigation attempted and confirmed | Search latency at realistic result counts |
| Settings | Appearance settings confirmed through accessibility | Other settings pages and large lists |
| Side pane | Shown; hide action not exercised | Per-pane render and interaction timings |
| Terminal | A `sh` terminal tab was observed present; no output exercised | Output flood, Ghostty rendering and replay cost |
| Browser | Navigation attempt remained in the command palette; not confirmed | Local-page workload, WebKit process and memory cost |
| Changes and Files | One modified line shown in Changes; `example.txt` listed in Files, not opened | Large diff/editor workloads and per-area timings |
| Automations | Page heading confirmed during mixed CPU capture | Large list and active-run workload |
| Designs | Source inventory and existing performance-test recipes | Live board/canvas rendering, WebKit memory |
| Spaces, Projects, sidebar lists | Source inventory and existing report recipes | Large-state body counts, switching and adoption timings |
| Composer and menus | Existing benchmark recipes identified | Keystroke, picker and attachment measurements |
| Launch and restore | Existing launch/thread signposts identified | Cold launch and first presented frame |
| Fleet, remote client and iOS | Architecture and test inventory only | Device/network/rendering measurements |
| Hooks, MCP and real model execution | Source inventory only | Controlled service workloads; no credentials used |
| GitHub Issues & PRs | Not exercised against a live service | Safe fixture-based UI and request measurements |

Existing reports worth running next include `RenderCostReport`, `HiddenAgentsReport`, `ListPerformanceReport`, `ChangesScrollFrameReport`, `ComposerMenuBenchmarkTests`, `DataPathBenchmarks` and `TerminalBenchmarks`. They were not run in this audit. Off-screen test results must remain distinct from app Instruments results.

## Metrics available and actually obtained

| Question | Instrument or existing source | Audit result |
| --- | --- | --- |
| Where is CPU spent? | Time Profiler, `time-profile` | App/host sample counts and stacks extracted |
| Which SwiftUI views update? | SwiftUI, `swiftui-updates` | Body/update counts extracted; no causal invalidation finding |
| Are frames late? | Animation Hitches, Hangs, Core Animation | Idle recording only; no active hitch rate established |
| What memory remains? | Allocations, VM Tracker, Leaks; targeted OS sampling | RSS baseline only; no leak or retained-growth result |
| CPU, threads, wakeups over time | Activity Monitor | 65 s recording saved; no target-filtered Instruments metrics extracted |
| Which file operations cost time? | File Activity, filesystem/disk instruments | Capture failed finalization; no usable result |
| Do actors or tasks wait? | Swift Concurrency, GCD/thread instruments | Recording saved; no quantitative contention analysis |
| How long do app operations take? | Existing `OSSignposter` intervals | Inventory only; no latency distributions extracted |
| How does launch break down? | App Launch, dyld, launch signposts | Not recorded |
| What costs energy? | Power Profiler, thermal state, wakeups | Not measured; Mac support must be verified |
| Is transport slow? | Network Connections, CPU stacks, existing RPC signposts | No transport latency/throughput result; HTTP Traffic does not cover raw `host.sock` traffic |
| Is GPU rendering the bottleneck? | Metal System Trace, render/hitch instruments | Conditional follow-up for Ghostty/WebKit; not measured |

Existing signposts cover launch, thread show/restore, markdown preparation, thread derive/merge/refresh, RPC dispatch/decode/admission and state staging. They mark code execution, not necessarily presentation on screen. Missing measurements include socket message size/latency, server queue wait, terminal rendering and browser/design work. Check whether existing trace data answers each question before adding instrumentation.

## Reproduction and evidence

The audited app was built with:

```sh
xcodebuild -project Shepherd.xcodeproj \
  -scheme 'Shepherd (Dev)' -destination 'platform=macOS' \
  -derivedDataPath /tmp/shepherd-audit-dd \
  -onlyUsePackageVersionsFromResolvedFile \
  PRODUCT_BUNDLE_IDENTIFIER=com.shepherd.audit.runtime355a60e51 build
```

The exact pinned engine was staged offline using a copied download cache. Launches after the first attempt used `env -i` and explicit scratch paths. The app's own supervised host, not the installed host, owned the checked listener port.

Local evidence is retained under `/tmp/shepherd-audit-results/`:

- `runtime.md`, `runtime-review.md`, `evidence-review.md`: measurements and independent checks.
- `coverage.md`, `coverage-review.md`, `metrics.md`: source inventory and corrections. These are not measured findings.
- `run-validated1.sh`, `run-validated8.sh`, validation logs, targeted XML exports and `traces/validated{1,8}-{app,host}.trace`.
- Exploratory app/host Time Profiler and SwiftUI traces, exports and capture logs.
- `run-breadth.sh`, accessibility action logs and `breadth-samples.log`.
- `run-navigation.sh`, `nav2-actions.log`, per-action AX snapshots, `nav2-time.xml` and `traces/nav2-time.trace`.
- `cleanup.txt`: approved artifact removals.

Do not run `scripts/perf/stress.sh` unchanged. It contains pattern-based process termination, broad deletion, a fixed listener port and window scripting. The audit used private scratch drivers with owned-PID cleanup instead. Validate actual state and selected content before each recording; preserve distinct logs for each condition.

The first host capture inherited the agent environment. Its trace and metadata were removed with user approval rather than distributed. The incomplete File Activity trace and invalid comparison traces were also removed. Raw captures are local diagnostic artifacts, not repository fixtures.

## Initial audit validation and cleanup

An independent worker recomputed sample counts and checked navigation evidence. The final report incorporates its corrections, including the 157-sample joint buffer/drain count and the unconfirmed Browser navigation. Seven repository documentation guards passed, and whitespace checks passed. Those guards enforce documentation structure; they do not verify this report's measurements. No Swift test suite was run during the initial profiling pass.

All audit worker threads and the check-in automation were deleted. Owned profiling app and host processes stopped. The audit checkout, build and useful local evidence remain under `/tmp` for reproduction. The initial profiling pass produced only this writeup; the follow-up code and test changes are described above.

## Limits

No Release performance improvement, leak-free result, smooth-frame guarantee or exhaustive app coverage is established. Real-model execution, remote devices and iOS remain untested. A controlled optimized follow-up is required before prioritizing product changes from these samples.
