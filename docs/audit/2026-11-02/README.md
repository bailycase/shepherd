# Shepherd performance audit — 2026-11-02

**Pinned baseline:** `f80d011324d924395664c2203a46db6a18f49aef`, nightly including #398.
For the follow-up fix branch, see [implementation and validation status](implementation.md).
The measurements and findings below preserve the pre-fix baseline.

**Status:** source review, field evidence, bounded local benchmarks and correctness cross-check
complete. Physical-device, shipping-app and soak profiling remain unperformed. This is an audit,
not an implementation or a claim of complete platform testing.

## Executive assessment

The remaining opportunities are not primarily Swift syntax or individual view polish. They are
repeated work, incomplete resource budgets and expensive work crossing interactive queue boundaries.
Several October fixes are present and must not be reimplemented: cached checkout reads, guarded
persistence staging, off-main streaming parsing, stable Mac decks, bounded RPC reads, quiet mobile
previews, deferred tools and shared canvas image caching.

There is a credible path to a much more responsive product without replacing the architecture:
reuse unchanged history, stop obsolete work, budget retained bytes, and carry backpressure to the
actual consumer. A blanket delta-protocol rewrite or lowering durability is not the first step.
No competitor comparison was run; "fastest macOS/iOS AI app" is an objective, not an audit result.

## Evidence we have

- Six independent subsystem/interaction reviews traced current source. Their 42 labeled observations
  overlap; they are not 42 distinct measured bottlenecks.
- Cross-checks covered the high-impact mechanisms and instrumentation boundaries. An additional
  adversarial review of eight claim groups found two missing fix constraints, now included:
  row-index optimization must still update live status, and transcript caching must invalidate
  on user-message sidecar changes. It found no contradiction in the scoped core mechanisms.
- Seven-day Sentry aggregates provide deployed-behavior clues across mixed versions: 103 Mac history
  refresh spans, 23 startup spans, 126 iOS UI-action spans; three reported fatal iOS hangs and one
  Mac hang in that window. Their latest inspected stacks do not prove an app-level root cause.
- 479 resource samples include fleets up to 43 pi processes and 52 sessions. That supports auditing
  large fleets, but does not mean all were simultaneously streaming. App physical footprint p95
  was about 1,433 MiB across these mixed workloads; that is neither idle memory nor proof of a leak.
- The normal Release test build failed before measurement because unrelated tests reference
  DEBUG-only counters. A reduced-target Release harness then measured unchanged optimized production
  sources. Debug offscreen UI runs are reported separately; executed benchmark/check processes passed.
  No real model, installed app or physical device was used.

See [field evidence](field-evidence.md) for exact counts, source queries, release caveats and
Sentry dashboard links. See [methodology](methodology.md) for workload coverage and proposed budgets.

## Strongest local measurements

Apple M4 Max, 48 GiB, macOS 27.0.1, Swift 6.4. Three samples per entry; medians, not stable tail
percentiles. Release here means optimized modules, not a shipping app build.

| Workload | Smaller fixture | Larger fixture | Supported conclusion |
| --- | ---: | ---: | --- |
| Release tail-only store refresh | 100 loaded messages: **0.326 ms** | 1,000: **2.316 ms**; 5,000: **10.811 ms** | Unchanged older history still increases refresh/merge/derive cost. No views, network or provider in this fixture. |
| Release history JSON decode | 1.1 MiB: **7.60 ms** | 4.3 MiB: **28.63 ms**; 12.8 MiB: **85.12 ms** | Decode cost dominates projection here; this does not mean main was blocked for those durations. |
| Release delta handling | No prior tool rows: **2.44 µs/event** | 50 prior tool rows: **15.46 µs/event** | Per-event work grows with the retained tool-row fixture. It is still a microsecond-scale measurement. |
| Debug offscreen view update | 50 turns: **14.4 ms** | 500 turns: **33.2 ms** | Loaded-history update work merits profiling, even though initial row construction was bounded. Not a shipping frame-rate result. |

[Measurements](measurements.md), [all samples](distributions.md), and
[archived inputs/commands](artifacts/README.md) include stub startup, queue probes, state JSON,
framing, view/palette results and exclusions. The best-supported next target is **less work per
unchanged-history update**, not an established speedup from any unimplemented fix.

## Prioritized work packages

Priorities below combine measurements where available with user exposure, static mechanisms and
correctness risk. They are **not** an estimate of saved milliseconds. Validate a focused
before/after workload for each package; most retention/backpressure findings remain unmeasured.

| Rank | Work package | Findings | Why it matters / first bounded change |
| ---: | --- | --- | --- |
| 1 | Main-thread history work | IO-02/03, MC-01/04, UX-01 | Reuse unchanged rows/turns; separate row-structure revisions from streamed text. Cover cold/final Markdown, not just streaming block parsing. |
| 2 | Retained-memory budgets | IO-01, ST-01, MC-02/08, SF-03 | Review revisions, full diffs, visited Mac histories and thumbnail/text caches need cost bounds, not only entry counts. Preserve drafts and reader state separately. |
| 3 | End-to-end output flow control | SF-01, IO-06 | Account through parser consumption and nonterminal push delivery, not just the socket-to-main hop. Bound backlog without losing output or stranding exits. |
| 4 | Child inspector isolation | SV-01 | Move full-tail transcript parsing off the shared server queue and avoid repeating it for unchanged pages. |
| 5 | Image critical paths | SV-03, MC-05, SF-02, UX-03 | Verify/fetch once per image, not per chunk; offload remaining attachment, thumbnail and agent-design encoders. |
| 6 | Startup and durable-state scheduling | ST-02/03, UX-08 | Keep first-window work lightweight; extend existing guarded staging rather than dropping write-ahead guarantees. |
| 7 | Cancel obsolete review work | ST-04 | Prevent superseded scope/options requests from spawning full Git diff/parsing work. Keep required turn snapshots separate. |
| 8 | Batch fleet state at its source | ST-05, MC-03, UX-07 | One shared-checkout result should publish one eligible-member update, not one whole workspace per agent. |
| 9 | Mobile freshness and warm switching | IO-04/05/07/08, UX-04/05 | Publish partial host progress, avoid unnecessary fresh snapshots, bound eager pins. Measure before introducing hints/digests or retained iPad hosts. |
| 10 | Editing, indexing and idle work | MC-06/07, ST-06/07, SV-04/06/07, SF-04 | Remove main-thread LCS, broad tree walks, sparse-history scans and polling/redundant lookup work where profiles support it. |

Send feedback and reconnect presentation (UX-02/06) are additional product decisions. They can
improve perceived speed but do not make Git, transport or provider work complete earlier.

## Implementation sequence

1. **Extend the recorded baselines.** Keep the optimized fixtures and samples; repair normal Release
   benchmark compilation before making it a routine gate. Add local interaction signposts and
   shipping/device traces before changing timing-sensitive code. Separate provider latency from app overhead.
2. **Remove redundant work with existing primitives.** Start with structural row invalidation,
   repeated image fetches, stale review jobs and batched checkout updates. Use deterministic
   correctness tests plus counters; compare optimized timing distributions where available.
3. **Enforce memory/queue ownership.** Add byte-accounted retention and parser-consumption backpressure,
   testing teardown, multiple viewers and memory pressure. A faster steady state that loses user
   content or drops terminal bytes is a regression.
4. **Address remaining UI-critical work.** Extend existing detached parsers/preparation paths and
   move safe reconciliation/staging work off interactive queues with stale-result fences.
5. **Only then enlarge protocols/architecture if measurements justify it.** Capability-gated revision
   hints or fleet digests can improve mobile behavior. A whole state/history delta protocol needs
   stronger evidence and a compatibility/recovery design, not just an intuition that less JSON wins.

## Reports

- [Session/engine pipeline](server.md): SV-01–07
- [Mac rendering/observation](mac.md): MC-01–08
- [iPhone/iPad](mobile.md): IO-01–08
- [Terminal/browser/design/extensions](surfaces.md): SF-01–04
- [Startup/storage/Git](storage.md): ST-01–07
- [Interaction critical paths](interactions.md): UX-01–08, overlapping subsystem findings
- [Field evidence and observability](field-evidence.md): FIELD-01–02, OBS-01–04
- [Methodology and proposed budgets](methodology.md)
- [Local measurements](measurements.md), [full distributions](distributions.md) and
  [reproduction artifacts](artifacts/README.md)

## Coverage and remaining work

| Area | Completed | Still required |
| --- | --- | --- |
| Current code | Six subsystem/interaction lanes; eight high-impact claim groups independently checked | Revalidate against newer commits before implementation |
| Mac data paths | Optimized decode, stream, store, JSON, framing and stub-start fixtures | Shipping app cold/warm launch, input-to-presentation and real repository Send traces |
| Mac UI | Three Debug offscreen thread/palette runs; bounded initial row counts | Release visual/hitch profiling during typing, paging, switching and scrolling |
| iPhone/iPad | Source review, field aggregates, shared thread-store correctness check on Mac modules | Physical iPhone/iPad tests, multiple windows, constrained networks, background/reconnect and thermal profiling |
| Memory/energy | Retention mechanisms and mixed-release field gauges | Controlled idle baseline, large-diff/image cache soaks, parser-backlog plateau and energy measurements |
| Comparisons | Pinned baseline and reproducible workload records | Before/after fixes and fair competitor workloads; no fastest-app ranking yet |

Documentation guards passed **10/10**. All actual benchmark/check processes exited successfully;
the full Release test build failed on test-only DEBUG references, not on production compilation.
No production changes or release were made. The measurement worktree retains only the recorded
benchmark instrumentation patch; the report branch contains documentation and archived evidence.

## Non-negotiable constraints

Keep Undo snapshots before agent edits, durable admission before acceptance, ordered streams,
exactly-once outcome tracking, stable view/session identities, ownership boundaries, accessibility,
drafts and reader position. Do not hide failures to hit latency goals. No product fixes, release
configuration changes, real-model calls or competitor tests are part of this audit.
