# Performance audit methodology

## Scope and baseline

Pinned source: `f80d01132`, including the streaming/workspace fixes in #398. The October audit
is a source of regression scenarios, not a list of defects assumed to remain. This audit
examines macOS, iPhone and iPad, including server, engine, remote transport, native surfaces,
SwiftUI presentation, Git/storage and background activity.

Audit work is isolated from installed Shepherd state. Static readers share one checkout;
benchmarks use a separate checkout and run serially. No live paid model calls, production
mutations, test input injection, releases or changes to product behavior are part of this audit.
Field telemetry is read-only and documented without user identifiers or project content.

## What "fastest" must mean

Provider latency and token throughput are not app speed. Measure these boundaries separately:

1. Launch requested to an interactive shell, then to usable restored content.
2. Key event to updated composer display while one or many agents stream.
3. Send accepted to queued feedback, undo baseline ready and request dispatch.
4. Provider first token to the first visible content update.
5. Thread selected to cached content, then to live send readiness.
6. Remote event received to rendered content, with network delay recorded separately.
7. Stop requested to local acknowledgement and to actual provider/process stop.
8. Idle and active CPU, physical footprint, process count and energy over a defined workload.

A fast blank window is not fast startup. A rendered spinner is not usable restored history.
A stopped animation is not cancelled work. Moving work off main can improve responsiveness
without reducing total CPU or memory; record those outcomes separately.

No competitor binaries are exercised in this audit. A "fastest app" claim would require
matching hardware, OS, model/provider, prompts, caches, repository, history and network conditions
against named competitors. No ranking is inferred from source review or microbenchmarks.

## Workload matrix

The rows below define the desired coverage. The final report must state which actually ran.
They are not an assertion of completed testing.

| Dimension | Scenarios |
| --- | --- |
| Fleet | 1, 10 and 50 agents; one foreground stream and several background streams |
| History | 100, 1,000 and 10,000 messages; short text, long code, tool-heavy and image-heavy variants |
| Streaming | Small frequent deltas; large bursts; long reasoning; repeated tool calls |
| Repository | Clean small repo; large tracked tree; dirty tree; many ignored/untracked files; branch switch |
| Navigation | Warm switch; first visit; return after eviction; keyboard appearance; narrow/wide iPad layout |
| Memory | Repeated open/close/switch cycles; inactive history eviction; image decode; child transcript expansion |
| Transport | Normal LAN; latency/bandwidth limits; interrupted connection; stalled consumer with busy output |
| Lifecycle | Cold start; warm start; restore many saved threads; background/foreground; host unavailable |
| Surfaces | Agent only; terminal burst/resize; browser; design boards; parked versus visible |
| Diagnostics | Same production-equivalent workload with diagnostics enabled and disabled |

Use deterministic fixtures to isolate app cost. Real provider trials, if separately authorized,
should verify behavior and transport rather than replace the deterministic workload.

## Measurement rules

- Record commit, compiler, configuration, architecture, OS, hardware, workload and command.
  Keep build time out of runtime timing. Optimized release data is primary; label debug-only data.
- Measure cold and warm paths separately. A warmup is not a measured sample.
- For this bounded first pass, record up to three measured repetitions plus warmup per workload.
  Publish individual values and medians/ranges. Do not manufacture p95/p99 from three repeats.
- Tail-latency claims need a follow-up interaction sample large enough to estimate the percentile,
  with sample count and distribution included. Pooled telemetry across different versions is
  not a before/after experiment.
- Keep builds, simulators and competing benchmark lanes from running concurrently. Record
  thermal/load limitations; the machine is also hosting the audit and its normal applications.
- A macOS data-path test does not measure SwiftUI frame timing. A simulated iPhone does not
  establish hardware memory pressure, energy, ProMotion behavior or thermal performance.
- Report app RSS and physical footprint separately from engine/terminal/descendant memory.
  Use retained-memory plateaus and pressure behavior, not only peak RSS, to investigate leaks.
- For network throughput, report backlog, delivery latency, bytes and disconnects at both ends.
  A client-side limit is not proof of end-to-end backpressure.
- Inspect safety and isolation before running a test. Preserve full logs and exit status, including
  failed builds and excluded measurements. Do not silently retry until a result looks good.

## Proposed acceptance budgets

These are review targets, not measured results or newly imposed product requirements.
Hardware classes and fixture sizes must accompany any eventual pass/fail threshold.

| Interaction | Proposed target |
| --- | --- |
| Typing during streaming | No app-attributable multi-frame stalls; inspect 60 Hz and 120 Hz traces separately |
| Immediate command feedback | Within 100 ms for Send, Stop and navigation, without claiming completion early |
| Warm thread switch | Usable cached content within 100 ms on the agreed reference fixture |
| Rendering | Stay within the display's frame interval: 16.67 ms at 60 Hz, 8.33 ms at 120 Hz; the app gets only part of that budget |
| Inactive retained state | Explicit byte bounds and observable release/eviction, preserving drafts and restoration |
| Slow remote consumer | No unbounded backlog, silent data loss or incidental connection loss within the specified throughput envelope |
| Idle | No work proportional to every history row or hidden surface on a recurring timer |

Cold launch, first agent startup and large-repository Send budgets should be set after measuring
the current critical paths. Arbitrary absolute thresholds would encourage skipping restoration,
recovery or the before-edit undo snapshot instead of making those paths efficient.

## Finding format and ranking

Every finding names a stable ID, source location, mechanism, affected workload, smallest safe
change, correctness constraints and a falsifiable check. Evidence categories:

- **Measured:** local reproducible experiment with recorded setup and samples.
- **Field-observed:** sampled deployed behavior, with release and attribution limits.
- **Code-confirmed:** a traced mechanism whose cost exists, without an established user-visible magnitude.
- **Hypothesis:** a plausible bottleneck needing a profile before implementation.

Rank frequent user-blocking paths and failure-inducing resource growth above speculative
micro-optimizations. Prefer removing redundant work to a new cache, scheduler or protocol.
Do not trade away Undo, durability, session ordering, cancellation, security, accessibility or
reader position for a benchmark score.
