# Field evidence and measurement gaps

Audit baseline: `f80d01132` (nightly, including #398). Queries were made on 2026-11-02
against the preceding seven days. These are sampled, budgeted reports from several deployed
versions, not a benchmark of that commit. No user identifiers, transcript content, replay
content or credentials are included here.

## Observed spans

Durations below are milliseconds. Counts are reported spans, not unique users or sessions.
The small sample sizes and mixed releases make the tail percentiles reproduction clues,
not release comparisons or reliable population estimates.

| Project / operation | Count | p50 | p95 |
| --- | ---: | ---: | ---: |
| Mac: `shepherd.agent.start` | 23 | 668.0 | 9,817.9 |
| Mac: `shepherd.history.refresh` | 103 | 51.2 | 1,283.6 |
| Mac: `shepherd.model.response` | 159 | 5,468.3 | 29,576.5 |
| iOS: `ui.action` | 126 | 96.2 | 2,751.1 |

Model response time is not app UI overhead. An automatic `ui.action` span is not necessarily
touch-to-next-frame latency. Neither should become a claim about app speed without checking
its start/end semantics.

Release breakdown illustrates why the pooled numbers must not be attributed to latest nightly:

| Release suffix | Operation | Count | p50 ms | p95 ms |
| --- | --- | ---: | ---: | ---: |
| Mac `202610281753+406` | history refresh | 57 | 38.8 | 724.1 |
| Mac `202610281753+406` | agent start | 9 | 727.9 | 14,171.5 |
| Mac `202611021947+430` | history refresh | 6 | 258.9 | 833.6 |
| Mac `202611021947+430` | agent start | 3 | 619.8 | 833.7 |
| Mac `202611022342+434` | history refresh | 1 | 48.3 | 48.3 |
| iOS `0.1.0+424` | UI action | 37 | 88.6 | 2,325.7 |
| iOS `0.1.0+429` | UI action | 5 | 132.0 | 1,565.9 |

Source dashboards:
- [Mac span aggregates](https://zenixbyte.sentry.io/explore/traces/?project=4512255745196032&statsPeriod=7d&mode=aggregate)
- [iOS span aggregates](https://zenixbyte.sentry.io/explore/traces/?project=4512329317679104&statsPeriod=7d&mode=aggregate)

Query fields: `span.op`, `count()`, `p50(span.duration)`, `p95(span.duration)`;
release breakdown adds `release`. These links use a relative window, so reopening them later
will not reproduce the historical numbers above.

## Observed resource gauges

The same seven-day window returned 479 samples per metric. Memory values below are MiB
(bytes divided by 1,048,576); RSS and physical footprint are different measures.

| Gauge | p50 | p95 | Maximum |
| --- | ---: | ---: | ---: |
| App RSS, MiB | 467.6 | 1,049.4 | 1,952.4 |
| App footprint, MiB | 476.5 | 1,432.7 | 1,946.2 |
| Combined pi RSS, MiB | 446.2 | 3,186.6 | 3,475.3 |
| pi process count | 7 | 21 | 43 |
| Total sessions | 9 | 29 | 52 |

[Resource metric dashboard](https://zenixbyte.sentry.io/explore/metrics/?project=4512255745196032&statsPeriod=7d).
Query: gauge names `shepherd.app.rss_bytes`, `shepherd.app.footprint_bytes`,
`shepherd.pi.rss_bytes`, `shepherd.pi.count`, `shepherd.sessions.total`; aggregates
`count(value)`, `min(value)`, `p50(value)`, `p95(value)`, `max(value)`.

These are mixed workloads and releases, not idle baselines. The maxima and percentiles
are not paired samples: do not sum them or divide pi RSS percentiles by process-count
percentiles to invent per-process memory. Long-running reporting sessions contribute more
samples. Memory deserves a controlled budget test, but these aggregates alone prove no leak.

## Observed hangs

### FIELD-01: iOS main-thread hangs need a reproducible interaction

[SHEPHERD-IOS-1](https://zenixbyte.sentry.io/issues/SHEPHERD-IOS-1) contains three reported
fatal fully-blocked hangs in the queried week. The latest inspected event was on build 424,
on a physical iPhone, with at least two seconds of main-thread blockage. Its sampled main
stack runs through UIKit/Core Animation layout and glass/view-update internals. It does not
identify a Shepherd function responsible for the stall.

This is evidence of a real hang, not proof that glass effects or a particular view caused it.
Reproduce navigation, keyboard appearance, streaming and layout transitions on hardware,
with Time Profiler/hang traces and frame metrics. Do not disable a visual effect merely
because its framework appeared in one sampled stack.

### FIELD-02: Mac input-context initialization appears in a reported hang

[SHEPHERD-MACOS-1](https://zenixbyte.sentry.io/issues/SHEPHERD-MACOS-1) has one event in the
queried week (five over its full lifetime). The latest inspected event is from build 406.
Its main stack is in AppKit text-input/remote-view initialization and synchronous XPC service
bootstrap. The app entry point is not a causal diagnosis.

Test first composer focus, text-input service initialization, input-method changes and the
same interactions after warmup. Separate OS service startup from Shepherd's own synchronous
work. This event predates the audit baseline and cannot establish a current regression.

## Observability findings

### OBS-01: Mac telemetry does not establish interactive frame performance

`Sources/ShepherdApp/ShepherdDiagnostics.swift:89-95,312-349` defines a small operation allowlist,
disables automatic performance tracing, and sets the hang threshold to five seconds. This
preserves privacy and reporting bounds, but sub-second stalls can be painful without appearing
as hangs. There are no explicit typing-to-display, thread-switch-to-usable or first-content
operations in that allowlist.

Recommendation: start with local Instruments/signposts at those interaction boundaries, not
more uploaded project data. Record frame/hitch metrics while streaming and switching. If new
aggregate telemetry is later added, retain consent, fixed labels, sampling and spend limits.

### OBS-02: iOS full-display tracing lacks an explicit app readiness signal

`App/iOS/App/MobileDiagnostics.swift:51-60` enables time-to-full-display tracing and profiling.
A source search found no app call to `reportFullyDisplayed` or equivalent explicit completion.
SDK timing alone therefore does not prove that a restored thread has usable history and a
ready composer. The seven-day returned span categories did not include startup/display spans;
that absence is not proof that no instrumentation exists.

Recommendation: verify the installed SDK's semantics, then define usable-content readiness
for each audited route. Measure cached content and live readiness separately. Benchmark with
production diagnostics both enabled and disabled; a local build without a DSN is not an
instrumentation-equivalent TestFlight build.

### OBS-03: existing durations cover different portions of the interaction

`RPCThreadState.refreshMessages` starts its history timer at request initiation and finishes
through refresh completion (`Sources/ShepherdSessions/RPCThreadState.swift:1547-1556`). The
agent-start timer ends at `onServable` (`SessionServer.swift:7691-7713`). Neither is a measured
first visible frame or end-to-end Send-to-first-token metric.

Record separate phases: input accepted, undo baseline prepared, pi request dispatched, provider
first token, decoded update ready, and first rendered content. Keep provider/network latency
separate from controllable app overhead. Preserve the before-edit snapshot guarantee while
examining Send latency.

### OBS-04: the standard Release benchmark build is blocked by unrelated tests

The measurement lane's native Release test build failed after 261 seconds before any benchmark
ran. `ChangesEngineTests.swift:350` references `ChangesGit.runs`, declared inside `#if DEBUG`
in `Sources/ShepherdSessions/Changes/ChangesGit.swift:20`. `ResponseTimingTests.swift:208`
references `RPCThreadState.bytesOfLastSnapshot`, also debug-only (`RPCThreadState.swift:216-226`).
Filtering the executed suite does not exclude unrelated files from test-target compilation.

This is a reproducibility defect in the test setup, not a failed Release app build or runtime
regression. A scratch target-membership reduction subsequently built and ran the optimized
measurements successfully, with unchanged production sources/optimization flags and no DEBUG define.
See [measurements](measurements.md) and archived compiler inputs. A durable fix should isolate
debug-counter tests or guard their compilation, rather than define `DEBUG` in Release to make
the benchmark command compile.
