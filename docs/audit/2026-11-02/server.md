# Session and engine pipeline

Baseline `f80d01132`. Static inspection: mechanisms are code-confirmed; their latency and
memory magnitude are not measured here. Priorities are triage suggestions, not benchmark rankings.
See [methodology](methodology.md) and [field evidence](field-evidence.md).

## SV-01 · P1 · Child transcript reads block the shared server queue

`Sources/ShepherdSessions/RPCThreadState.swift:1021-1030,1345-1405` synchronously reads,
decodes and projects up to an 8 MiB child-session tail plus its user-message sidecar for each
transcript request. The inspector calls through `NativeThreadStore.subagentTranscript`
(`Sources/ShepherdApp/Thread/SubagentInspector.swift:541-552`). Paging 50 rows does not avoid
parsing all available rows; Show all repeats it. Live-child inspection can refresh at 500 ms.

- Impact: one large inspected child can delay unrelated streams, terminal output and requests.
- Smallest fix: perform the pure builder off queue, return under generation/file-binding fences;
  reuse results only while **both transcript and user-message sidecar** identities/versions remain
  unchanged. Sidecar appearance is an invalidation too: attribution reads both files, and
  `Extensions/shepherd-children.ts:1453-1460` appends the sidecar independently before dispatch.
- Preserve: ownership, partial-line handling, clipping, stale-cursor errors, generation identity
  and correct user-versus-parent attribution.
- Check: 100/1,000/10,000 rows with 1/10/50 streaming agents; count decoded bytes and server-queue
  sentinel delay. Repeated unchanged pages should not repeatedly parse the whole tail. Sidecar-only
  edits/appearance must update attribution even when transcript bytes are unchanged.

## SV-02 · P2 · History refresh still performs whole-history reconciliation

`RPCThreadState.swift:738-753,1547-1587,1635-1676` fetches all messages at completion and other
reconciliation points. Projection now runs off queue, but merge/interleave, summarized-history
indexing, deep comparisons and size-cache replacement still run on the shared queue.
`RPCThreadState+Context.swift:444` participates in summarized-history reconciliation.

- Workload: many long threads completing together; decoded/projected versions coexist. The RPC
  decode semaphore does not bound subsequent global-queue projection jobs.
- Fix: coalesce superseded refresh work, then prepare reconciliation against an immutable prior
  snapshot off queue and validate that baseline before applying it.
- Preserve: generation/sequence ordering, live persistence fences, compaction, bootstrap late
  responses; a newer failed request must not discard an older valid response.
- Check: extend `HistoryFreshnessTests`; measure projection counts, queue delay and retained memory
  with overlapping successes/failures across the agent/history matrix.

## SV-03 · P2 · Every image chunk repeats the whole-image fetch and verification

`RPCThreadState.swift:1310-1340` sends `get_image`, decodes and verifies the entire image, then
returns one chunk. `ThreadImages.swift:65-69` performs verification;
`Sources/ShepherdRemote/NativeThreadImages.swift:182-226` requests chunks sequentially.
A 2 MiB image with 256 KiB chunks therefore entails eight full-image requests/verifications.
This count is derived from code, not a measured load time.

- Fix: bounded generation-scoped verified bytes and shared in-flight reads; keep per-request
  membership/ownership checks, hash validation, offsets and invalidation.
- Check: count `get_image` and heavy work; one cold complete read should verify once. Exercise
  concurrent readers, eviction and switching. Actual inline image viewers are Mac-only today;
  ordinary mobile transcript rows display image labels.

## SV-04 · P2 · Recovery callbacks retain per-delta agent scans

`RPCThreadState.swift:2490-2491` commits into
`SessionServer.swift:8303-8330` (`checkpointAgentRecovery`), which performs repeated linear agent
lookups around `applyAgentSession` (`:5445`). Eligibility is already version-cached; these
identity scans remain even during unchanged-session streaming.

- Fix: reuse a version-fenced agent/session lookup and reconcile only when identities differ.
- Preserve: structural invalidation, extension/RPC races and synchronous recovery admission.
- Check: count agent traversals at 1/10/50 agents under fixed delta rates; traversal should follow
  identity/state changes rather than every token. Do not weaken checkpoint correctness.

## SV-05 · P2 · Image sends serialize bulk RPC data on the shared queue

`RPCThreadState+Queue.swift:555,660` → `RPCThreadState+CommandNotices.swift:48-76` →
`RPCSession.swift:258-269`: base64 conversion and NDJSON preparation precede bounded stdin
admission on the server queue. Near-limit 5 MiB batches compete with other sessions.

- Fix: prepare immutable large frames off queue inside the existing serialized input lane;
  return for bounded all-or-none admission.
- Preserve: request/generation ordering, recovery-before-delivery, Stop authority and unknown
  outcomes. Abort must not wait behind preparation; never retry a possibly delivered prompt.
- Check: concurrent maximum-size Send/Steer and unrelated streaming; measure queue occupancy,
  assert exact order and zero delivery after cancellation.

## SV-06 · P3 · stderr draining lacks a fairness budget

`RPCSession.swift:590-620` drains until EAGAIN and invokes per-line handling on the server queue
(`SessionServer.swift:7723-7728`). The 64 KiB line cap bounds a line, not work per queue turn.
A continuously noisy provider/extension could monopolize service; this is not reproduced yet.

- Fix: reuse stdout's byte-budget/yield pattern.
- Preserve: conflict detection and all final diagnostics before exit notification.
- Check: fake stderr flood plus a second responsive child; require progress before the flood
  ends, bounded work per drain and final-line delivery.

## SV-07 · P3 · Child admission still polls blocked work

`Extensions/shepherd-children.ts:1554-1557,1597-1599` wakes blocked work every 50 ms and scans
retained runs. `shepherd-workflow.ts:75` retains a separate 250 ms evaluator safety tick.
Many waiters across parents multiply wakeups without doing useful model work.

- Fix: notify capacity waiters from lifecycle events with cancellation/deadline handling.
  Establish the safety tick's necessity before removing it.
- Preserve: admission rechecks after awaits, ownership, deadlines and non-nested bounded runs.
- Check: deterministic held capacity; count idle wakeups/scans, then release and verify bounded
  admission and immediate cancellation.

## Measured boundaries

[Optimized fixtures](measurements.md) measured 1.1/4.3/12.8 MiB history decode at
7.60/28.63/85.12 ms, versus projection at 0.70/2.90/8.70 ms. Decode and projection duration
must not be presented as server/main-queue stall duration: work has already moved off queue.
The 4/12 MiB reload fixtures recorded worst queue probes of 2.643/1.200 ms and no probes above
16 ms. These are single three-turn workloads, not stable percentiles or proof for every fleet.
They support preserving existing off-queue work rather than repeating the old blocking diagnosis.

Delta handling grew from 2.44 to 15.46 µs/event with zero versus 50 prior tool rows in its fixture;
this is measured scaling at microsecond magnitude, not by itself a perceived-stall diagnosis.

## Existing improvements to preserve

Ordered, bounded RPC decoding and 1 MiB stdout read turns already exist. Snapshots have page/byte
limits and cached hashes/sizes. Restored settled agents stay dormant; background starts are
metered. `pushMessage` no longer synchronously blocks main. Revision dispatch and recovery
eligibility use indexes/caches. Child polling stops without live children. Shared shutdown
reaping replaced sequential per-child deadlines. Do not remove the remaining completion/state
refreshes without settlement-race coverage.

October SS-02 and SS-11 are partial, not untouched: projection moved off queue and routine history
images use references. The recorded 6,551-token startup context figure is a character-based
estimate, not a new measurement or actual provider token count.
