# Perceived speed and interaction critical paths

Baseline `f80d01132`; code inspection, not runtime interaction measurements. These observations
overlap subsystem reports and must not be counted as additional independent bottlenecks.
Targets are proposals, not achieved timings or approved design changes.

## UX-01 · P1 · Loaded-history derivation competes with typing and scrolling

See IO-02 and MC-04. `NativeThreadStore.swift:492-581,1070-1078` does whole-history grouping,
comparisons and row derivation on main for changed pulls. Prompt text joins and
`NativeMarkupProposals` JSON parsing also recur outside cached presentation values.

The Mac can react to revisions at roughly a 33 ms minimum spacing; mobile running polls are
500 ms. These are scheduling constants, not delivered frame rates. Preserve neighboring-row
semantics when reusing a prefix: comments, retries, repeated errors, compaction boundaries,
aliases and subagent placement can change outside the last visible answer.

Validation: 200 tail-changing fixture snapshots at 100/1,000/10,000 loaded messages; record
main-thread time and historical rows visited, plus typing/scroll traces. A proposed 4 ms
per-pull budget at the reference 1,000-message fixture needs baseline measurement before adoption.

## UX-02 · P1 · The composer retains sent text while admission waits

`RPCThreadState+Queue.swift:525-586` creates a pending row before the pre-prompt snapshot;
`SessionServer.swift:7733-7736` invokes the Changes fence. The same capture queue may still be
settling the previous turn (`ChangesService+Turns.swift:169-177,226-243`).
`NativeThreadStore.swift:1836-1845` clears the draft on `.accepted`, not initial input.
The composer can therefore retain text already represented by a pending bubble while Git/RPC
admission proceeds. No current duration is established.

- Candidate UX improvement: move text/attachments/references into a local sending record promptly,
  without falsely reporting provider acceptance. Keep the outstanding operation outcome-tracked.
- Preserve: refusals must leave submitted content recoverable; restoring a failed send must not
  overwrite a newly typed draft. If new text exists, retain a separate retryable failed record.
- Real latency still needs capture profiling. Do not send before the Undo baseline can exclude
  the agent's first edit.
- Check: gate `beforePrompt`; measure draft/pending feedback, then refuse and verify all content
  survives. Proposed feedback target: 100 ms, not a promise that Send has completed.

## UX-03 · P1 · Image reveal repeats work at two stages

SV-03 identifies repeated full-image fetch/hash per chunk; MC-05 identifies main-actor thumbnail
creation and potential re-creation on lazy-row remount. These are one image critical path, not
separate claims of measured user delay. Ordinary mobile rows currently display image counts.

Check a cold 2 MiB local image: expected post-fix full-image request count is one, not eight.
Inspect main-thread work while scrolling many image rows. A 300 ms thumbnail-reveal budget is a
candidate reference target, subject to hardware/workload definition.

## UX-04 · P2 · Mobile thread freshness is limited by polling cadence

`NativeThreadStore.swift:441-444` polls every 500 ms while running and two seconds while idle.
The remote message set has no native-thread revision hint equivalent to the Mac in-process
watcher (`ShepherdViewModel.swift:782-795`). A changed response can contain a recent page up to
240 KiB; two full pages/second is an arithmetic transfer envelope, not measured traffic.

- Candidate fix: capability-gated, subscription-scoped, rate-bounded revision hints that trigger
  existing pulls. Keep fallback polling. A tail-delta protocol is a larger separate decision.
- Preserve: protocol codec/ownership contracts, reconnect epochs, older hosts and background
  lifecycle. Hints must not create unbounded callbacks or wake idle pi unnecessarily.
- Check: host revision to visible client update and bytes/minute under controlled latency.
  Proposed stream-cadence target: 250 ms; do not confuse cadence with end-to-end response time.

## UX-05 · P2 · Warm switches/actions force fresh snapshots

`NativeThreadStore.swift:832` pulls fresh when run resumes; `:1894-1895` resets readiness and
refreshes fresh after actions. This bypasses unchanged-revision handling. iPad additionally
remounts its detail (IO-07). Cached content can display promptly while still paying redundant
transport/encoding/derivation at the interaction boundary.

- Candidate fix: resume with a known revision only inside a validated connection/session epoch;
  retain full bootstrap on restart/stale identity. Evaluate which successful actions genuinely
  require a readiness reset instead of removing all resets blindly.
- Preserve: state/generation changes, compaction, changed supported actions, concurrent viewers
  and the ready-to-send contract.
- Check: 50 switches among unchanged agents; count snapshots/encodes and verify restart/action
  races still refresh correctly. Measure cached-content and live-readiness times separately.

## UX-06 · P2 · Normal mobile reconnect looks like failure

`App/iOS/Hosts/MobileHosts.swift:233-239` reconnects after foregrounding.
`RemoteHostRecord.swift:93` considers only `.connected` connected;
`ThreadScreen.swift:179-181,229-236` shows an offline banner and Retry while connecting.
Removing the banner later may also disturb a reader away from the tail.

- Candidate fix: distinguish connecting from failed/offline and preserve scroll position.
  A short grace period and "Reconnecting…" copy are design proposals, not implemented changes.
  They depart from the current offline-only spec and require product approval.
- Check: quick `.connecting → .connected`, delayed connections and genuine failure. Never hide
  a persistent failure or imply completion while still reconnecting.

## UX-07 · P2 · Bursts of real state changes still produce repeated adoption

See MC-03/ST-05. Equality gates do not merge changed snapshots. Batch the concrete checkout
fan-out first; if broader pacing is justified, separate transition-dependent events from
replaceable presentation snapshots. Preserve unchanged-snapshot store reconciliation, completion
notifications and automation ordering. Count main jobs/adoption time under a deterministic fleet
trace before and after; do not infer contention merely from a loop in source.

## UX-08 · P3 · Recovery checkpoints encode image-bearing queues synchronously

`Sources/ShepherdSessions/AgentRecoveryStore.swift:49-58` compares and atomically writes JSON
including base64 images, called through `SessionServer.swift:7647-7654` before send commitment.
A large image queue or its edits can occupy the shared server queue before pending feedback.

- Candidate fix: prepare/store bounded content-addressed blobs once, then durably checkpoint
  references. This is more involved than simply dispatching the current write asynchronously.
- Preserve: blob and checkpoint durability before admission/acceptance, crash recovery, orphan
  cleanup, generation fences and cancellation/outcome semantics.
- Check: 0/1/5 MiB queues; measure checkpoint work and another thread's request delay, then crash
  at every admission boundary and verify exactly-once recovery behavior.

## Positive paths

Pending echoes precede the Git fence. Hidden threads keep cached rows, thumbnails reserve their
geometry, and draft persistence is debounced. Composer styling skips unchanged work; inactive
Mac wheel monitors are removed. Mobile previews avoid idle process startup and don't cover cached
content with a startup spinner. These improvements should remain regression fixtures, not be
reintroduced as new findings. A fast-looking interface must still reflect real operation state.
