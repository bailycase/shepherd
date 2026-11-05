# Live profile of Shepherd Nightly, 2026-11-05

First profile of a *running, shipping* build under real use. The 2026-10-27 and 2026-11-02 audits
were static reads plus package benchmarks; both listed "device, shipping-app and soak profiling"
as unperformed. This fills that gap.

**Subject:** `Shepherd Nightly` 0.0.0-nightly.202611042039 (build 456), pid 2123, running the
user's everyday fleet (4 pi processes, several threads, a streaming thread in view) while the
user worked in it. Symbols came from the release's `Shepherd-Nightly-dSYMs.zip` (UUID matched).
Apple M4 Max, macOS 27.0.1, Xcode 27.0. Displays: 5120x1440 @ 240 Hz ("Display 2", where the
window was) and 3440x1440 @ 100 Hz.

**Method:** `sample` for 10 s and 30 s; `xctrace record --template 'Animation Hitches'` for 60 s
(hitches, potential hangs, 1 ms time profile) and `--template SwiftUI` for 30 s, attached to the
live pid. Exports were aggregated with the three scripts in this folder. No workload was scripted:
the window saw ordinary use, so counts are a sample of real behavior, not a benchmark.

## Headline numbers (60 s Animation Hitches trace)

| Metric | Value |
| --- | ---: |
| Main thread running | 19% of wall time (11.1 s of 60) |
| Process CPU (top) | 6 to 30% across samples; WindowServer 41 to 57% |
| SwiftUI/AppKit commits on main | 1963 (33/s); p50 5.8 ms, p90 11.7 ms, p99 26 ms, max 85 ms |
| Commits over the 240 Hz budget (4.17 ms) | 1377 of 1963 (70%) |
| Commits over 10 ms (the 100 Hz budget) | 485 (25%) |
| Hitches on Display 2 | 866; p50 4.2 ms, p90 12.5 ms, p99 46 ms, max 79 ms; 215 of two frames or more, 49 over 20 ms |
| Hitch cause, per Instruments | 279 "expensive app update", 3 "expensive render", 584 unlabeled |
| Potential hangs (main blocked ≥ ~35 ms) | 25 in 60 s, total 1.37 s, longest 216 ms |

So the median commit already misses a 240 Hz frame and a quarter miss a 100 Hz frame. At 33
commits/s that is a hitch every few frames, which reads as "everything feels laggy".

## Where main-thread time goes

Share of main-thread *running* samples over the full 60 s (1 ms time profile):

| Share | Work | Evidence |
| ---: | --- | --- |
| 40% | SwiftUI view-graph update and layout inside `AgentLayoutDeck.Host.layout()` → `NSHostingView.layout()` → `ViewGraphRootValueUpdater.render` | 4410 samples; 2469 of 5521 render samples carry the `Host.layout()` frame |
| 10% | SwiftUI update at `CA::Transaction::commit` → `GraphHost.flushTransactions()` | 1073 samples |
| 8% | AppKit `_findAnySubviewNeedingAutoLayoutEngine` walking the whole NSView tree each layout pass | ~770 samples across its leaf frames |
| 8% | SwiftUI hit testing with a cold cache: `AgentLayoutDeck.Container.hitTest` → `NSHostingView.hitTest` → `PlatformHitTestingManager.uncachedResult` | 924 samples |
| 2% | `NSWindow _resetDragMargins` → `NSHostingView.acceptsFirstResponder` → `FocusNavigationSequence.next()` walking every focusable item | 185 samples overall, but 14.5% of samples *inside the hang windows* |
| 1% | `ComposerTextField.Editor.keyDown` (typing) | 113 samples |

Inside the 25 potential-hang windows the mix is the same, plus the drag-margin walk (14.5%) and
the key-view-loop walk (`_recursiveGatherAllKeyViewCandidates`, `FocusBridge.firstResponderDidChange`).

Shepherd's own `body` code is cheap. The heaviest app symbols under render were `Composer.body`
(1.2%), `Color.init(light:dark:)` closures (0.6%), `ComposerTextField.sizeThatFits` (0.3%),
`ComposerControlsMinimum.sizeThatFits`, `ThreadView.turn`, `SHActivityWords.measure`,
`NativeThreadStore.derive/refresh` (0.4%), `ShepherdViewModel.adopt` (0.2%). The cost is the
*size* of the graph each commit touches, not expensive bodies. Release inlining hides the state
writes that start each commit; a Debug trace is needed to name them (see Next).

Other threads were idle: ten Ghostty `renderer` threads sat in `kevent64`, `shepherd.rpc.decode`
had 28 samples in 30 s, Sentry's hang tracker 3. Nothing off-main competes for the CPU.

## SwiftUI template (30 s)

305k attribute updates (10k/s), 968 ms attributed. Top costs by node:

| Total | Count | Node |
| ---: | ---: | --- |
| 225 ms | 438 | `Layout: UnaryChildGeometry<_FrameLayout>` (0.5 ms each: one `.frame()` whose subtree is the thread page) |
| 83 ms | 1872 | `Text Content` |
| 73 ms | 727 | `Layout: RootGeometry` (24 root relayouts/s) |
| 45 ms | 589 | `DynamicContainerInfo<DynamicLayoutViewAdaptor>` |
| 34 ms | 1743 | `View List BaseViewList.Init` |
| 28 ms | 90 | `LazySubviewPlacements<LazyVStackLayout>` |
| 25 ms | 43151 | `DisplayList Item: PairPreferenceCombiner<DisplayList.Key>` |
| 17 ms | 7340 | `UpdateFilter<SHElapsedSchedule, Text>` (245 re-evaluations/s of elapsed-time `TimelineView`s; cheap each, but they ride every commit) |

View bodies re-run per 30 s: `HelpView.body` 589, `QuestionBranchMenu.body` 318. `HelpView`
re-evaluating ~20 times a second while nothing about help changes is a cheap tell that whole-state
invalidation (MV-01 in the October audit) is still live.

## Findings

**P1 · Commits are too frequent and too wide.** 33 commits/s, each a full `NSHostingView` layout
and graph update of the visible thread page (40% + 10% of main). This is the October audit's
MV-01 ("every server broadcast replaces the whole `vm.state`") measured live. Coalescing to one
commit per display frame and narrowing what each commit invalidates is the lever that moves
every number above. Its validation is "commits/s" and "commit p90" in this same trace template.

**P2 · AppKit per-layout walks scale with the NSView tree.** `_findAnySubviewNeedingAutoLayoutEngine`
(8%) walks every NSView under the window each layout pass; `_resetDragMargins` (hidden title
bar: `.windowStyle(.hiddenTitleBar)` in `ShepherdApp.swift:118`) asks each `NSHostingView` for
`acceptsFirstResponder`, which SwiftUI answers by enumerating every focusable item in its graph.
Each mounted `AgentLayoutDeck.Host` (one per retained tab) multiplies both. Candidates: cap or
shrink retained hosts, keep hidden hosts out of the title-bar region's opaque-region query, or
override `acceptsFirstResponder` on `Host` with a cheap answer if focus behavior allows. Measure
the walk's share before and after.

**P3 · Hit testing is uncached under streaming.** 8% of main is `PlatformHitTestingManager`
rebuilding its responder cache because the graph changed since the last mouse move. Fixing P1
reduces this for free; `.allowsHitTesting(false)` on purely decorative streaming subtrees also
shrinks the responder set.

**P4 · WindowServer at 41 to 57% CPU** is the compositor cost of a 5120x1440 @ 240 Hz display
plus a 100 Hz one. This trace cannot attribute it to Shepherd (sampling WindowServer needs root).
A quick user check: set Display 2 to 120 Hz for a minute and see whether "laggy" changes. If it
does, the fix is fewer layers (Ghostty/WebKit surfaces per hidden tab), not SwiftUI.

**P5 · Potential hangs of 36 to 216 ms** are P1 commits stacking with P2 walks, not a blocked
queue: no `.sync` or socket wait appeared on main.

## Sentry, same week

`zenixbyte/shepherd-macos`, 7 days: `transcript.rows` p50 **26,600** (max 48k), app footprint
p50 **1.6 GB** (max 3.2 GB), `history.refresh` p95 784 ms (max 14 s). Two App Hanging issues from
build 443 ([SHEPHERD-MACOS-D](https://zenixbyte.sentry.io/issues/SHEPHERD-MACOS-D),
[-E](https://zenixbyte.sentry.io/issues/SHEPHERD-MACOS-E)) share one main-thread stack:
`ScrollViewLayoutComputer → ForEach → SizeFittingState` sizing nested stacks, with 31k rows
retained and 10 pi processes. MV-01's gate (`adopt` returns on an equal snapshot) is already in
the code, so the commits above are real streaming updates, each too wide.

## Stress run, Debug build, no model

`scripts/perf/stress.sh` launches the Dev app on the stub engine (`STUB_PI_STRESS` in
`Tests/ShepherdTestSupport/Resources/stub-pi.py`: 150 seeded turns, then markdown replies of 600
chunks at 30 ms), creates 8 agents over the remote listener, and records the SwiftUI and
Animation Hitches templates. Same Mac; window 1600×1000. Three runs of the same workload:

| Run | SwiftUI updates / 20 s | SwiftUI ms / 20 s | Potential hangs / 30 s (>100 ms) |
| --- | ---: | ---: | ---: |
| baseline | 1.40 M | 9,895 | 83 (78, max 1.1 s) |
| `Equatable` (identity) on the class-typed environment values | 1.12 M | 11,093 | 118 (107) |
| `ThreadView.eagerRows` 30 → 5 | 2.79 M | (not parsed, 15 GB export) | 339 (53, max 468 ms) |
| **live row split** (`listRows` + `liveRow`, shipped) | 1.01 M | **4,595** | **44 (3, max 264 ms)** |

Run-to-run noise is about ±30% on these counts, so the first change did nothing measurable and
the second made it clearly worse (fewer eager rows means more `LazyVStack` churn per chunk).
Both were reverted. Baseline hot nodes (ms per 20 s, count):

| ms | count | node |
| ---: | ---: | --- |
| 1,907 | 435 | `Layout: UnaryChildGeometry<_FrameLayout>`: the transcript's `.frame(maxWidth:)`, 4.4 ms per relayout |
| 843 | 45k | `Text Content` |
| 733 | 212k | `EnvironmentWriter: NativeCompactionExpansion?` (and 367 ms `MergedEnvironment`): the environment re-flows through every row per commit |
| 368 | 4.4k | `ForEachChild<ArraySlice<NativeThreadRow>>` |
| 240 | 4.1k | `PlatformViewChild<SHNativeCodeText>` (code-block representables re-updated) |
| 158 | 4.1k | `PlatformViewChild<ThreadTailGuard.RowProbe>` (one representable per row) |

`ThreadView.body` itself runs 6×/s (170 ms per 20 s) and `SHProseBlocks.body` 617×; bodies are
not the cost. `External: UInt32`, the top root cause in both traces, is SwiftUI's own
per-transaction `ForEachState.Evictor` seed and is not actionable.

**Conclusion and fix.** Every streamed chunk replaced `NativeThreadStore.rows`, which re-ran
`ThreadView.body`, re-flowed the environment into every row, and relayouted the transcript frame
with its 30 eager turns. Cheap knobs did not help. The fix (the November audit's work package 1)
is in this branch: the store keeps `rows` (iOS and the lookups read it) and adds `listRows`, the
same list with the streaming reply as a content-less shell, plus `liveRow`, the reply's content.
The Mac transcript iterates `listRows`; the shell's view (`ThreadView.LiveRow`) reads `liveRow`
itself, so a chunk invalidates one row. On the stress workload that halves SwiftUI's main-thread
time, removes the environment fan-out from the profile, and cuts potential hangs over 100 ms
from 78 to 3 per 30 s. `ThreadStreamingTests` now asserts the live row redraws once per adopted
revision and the thread body at most once. What remains is the transcript stack's own relayout
(`_FrameLayout`, 1.9 s per 20 s at 1.2 ms a pass), which is the live row growing.

## Next

1. Work package 1 as above, in `NativeThreadStore` and `ThreadView` (both Mac and iOS read the store).
2. For the shipping app's P2 (AppKit walks over retained `AgentLayoutDeck.Host`s): count hosts
   and NSViews in a real window; `SHRenderProbe` already ticks `deck.layout` / `deck.hiddenLayout`.
3. Bound retained transcript rows (Sentry p50 26k) so history work stops growing with session age.

Notes for whoever repeats this: `xctrace --launch` refuses a path when several `Shepherd.app`
bundles exist on disk; attach by pid. A Release config built under the Dev scheme needs
`codesign --force --deep -s -` to load its frameworks. `xctrace record` refuses to overwrite an
existing `.trace`. The first potential hang after attaching (~2 s) is the attach pause itself.

## Reproducing the aggregation

```bash
sample <pid> 30 -file s.txt                           # then symbolicate with atos and the release dSYM
xctrace symbolicate --input t.trace --dsym "Shepherd Nightly.app.dSYM"
xctrace export --input t.trace --xpath "/trace-toc/run[@number='1']/data/table[@schema='time-profile']" > time-profile.xml
xctrace export --input t.trace --xpath "/trace-toc/run[@number='1']/data/table[@schema='potential-hangs']" > potential-hangs.xml
python3 scripts/perf/time_profile.py hangs             # omit `hangs` for the whole trace
```

The scripts are `scripts/perf/time_profile.py` (main-thread frames, optionally inside hang
windows), `scripts/perf/summarize_traces.py` (a stress run's pair of traces), `scripts/perf/stress.sh`
and `scripts/perf/remote_drive.py`. Traces and raw exports stayed in `/tmp/shepherd-perf/`.
