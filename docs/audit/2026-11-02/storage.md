# Startup, persistence, Git and storage

Baseline `f80d01132`. Static mechanisms only; no timing or throughput values are inferred from
source. Before-edit Undo baselines, index isolation, authority and crash durability are constraints,
not optional work to discard for a faster benchmark.

## ST-01 · P1 · Diff caching retains complete files before display truncation

`Sources/ShepherdSessions/Changes/ChangesService.swift:373-389` parses and inserts the complete
`DiffFile`, then returns `Self.truncated(...)`. The cache at `:54,541` has a 512-entry limit,
not a byte budget. Full-file context uses `-U1000000` (`:351`). The subprocess output cap bounds
one result, not aggregate retained parsed data.

- Fix: cache the truncated result including its truncation flag; cost-bound entries or skip
  oversized values. This limits retained cost; parsing may still have a large transient peak.
- Preserve: revision/path/options identity and truthful incomplete-result metadata. Never present
  a truncated patch as complete or change actual apply/revert semantics.
- Check: large generated/tracked diffs across revisions and 10/50 reviews; verify identical
  displayed content/flags and bounded cache cost, then measure transient versus retained memory.

## ST-02 · P2 · Server storage initialization delays first window on main

`Sources/ShepherdApp/ShepherdApp.swift:49-55` constructs/starts `SessionServer.shared` synchronously
before creating the model/window. `SessionServer.swift:1030,1162-1204,1365-1486` loads/validates
state, persists startup changes, loads/prunes Changes records and cleans design state.

- Workload: many restored agents/retained Changes records or slow storage. This is not a claim
  that every restored transcript is loaded or every agent starts.
- Fix: lifecycle-worker construction/reconciliation with a lightweight loading surface.
- Preserve: exclusive ownership and reconciliation before operational requests, restoration or
  workspace writes; retain startup failure handling.
- Check: gated scratch state/turn-store reads; main must progress, no agents may start before
  successful initialization. Measure first shell and usable restoration separately.

## ST-03 · P2 · Remaining mutations encode/write whole state on the server queue

`Sources/ShepherdSessions/StateStore.swift:47-64,187-198` still persists synchronously for callers
of `SessionServer.mutateState` (`:5496`). Paths include pane binding (`:5684`), session/naming
changes (`:5446-5487`) and changed failure records (`:5388`). Bursts scale with workspace payload,
not transcript length.

- Fix: migrate compatible field mutations to existing version-fenced staging, with explicit
  completion ordering for process bindings. Do not build a second persistence subsystem.
- Preserve: revalidation after awaits; publish/acknowledge only after durable success. Never turn
  write-ahead admission into fire-and-forget or unconstrained latest-wins persistence.
- Check: gated concurrent binding/name writes; unrelated queues progress, failed writes publish
  nothing and restart restores accepted changes.

## ST-04 · P2 · Superseded review loads continue doing expensive Git work

`Sources/ShepherdApp/ShepherdViewModel+Review.swift:338-380` starts unretained loads and checks
request generation after list plus all-file diff work. `ChangesService+API.swift:9-12` provides
no cancellation bridge to dispatched work; `ChangesService.swift:393-397` parses all diffs.
Quick scope/options changes therefore leave obsolete subprocess/parse work competing with current
review and pre-prompt capture.

- Fix: cancel retained prior review tasks, check authority before starting diffs, propagate
  cancellation and bound review-job admission. Mandatory turn captures use separate semantics.
- Preserve: one revision for lists/hunks and Undo's recovery guarantees; do not cancel a required
  baseline or partially apply Undo without its recovery protocol.
- Check: gate first list and supersede repeatedly; obsolete requests must not begin diff work.
  Count subprocesses/concurrency and ensure only the newest result lands.

## ST-05 · P2 · Shared checkout results still cause one state update per agent

`CheckoutMonitor.swift:149-155` awaits separate member updates. Each changed member reaches
`SessionServer.swift:6096-6110` and whole-workspace adoption (`ShepherdViewModel.swift:1332-1373`).
One deduplicated Git read for A colocated agents can still produce A distinct snapshots and
reconciliations. `CheckoutMonitor.sync(:92)` also resolves directories by scanning agents/tabs.

- Fix: batch eligible members of one checkout result into one server mutation/broadcast.
- Preserve: normalized-directory, move/remove and stale-membership rechecks; unchanged result
  remains a no-op.
- Check: extend shared-checkout tests to count broadcasts/adoptions, not just Git reads; expect
  one changed-result publication while exercising membership races.

## ST-06 · P3 · Outcome paging lacks the task-specific index used for message paging

`ProjectHistoryStore.swift:402-406` filters JSON task/operation identity while available indexes
at `:46-61` mainly narrow scope/kind/sequence. A small LIMIT does not prevent scanning unrelated
outcomes for sparse tasks. Reads share a serial history worker.

- Fix: a partial expression index matching task/sequence; add an operation-specific variant
  only if query-plan/VM-step measurements justify it.
- Preserve: append-only identity, cursor order, owner scope, read grants and SQLite durability.
- Check: `EXPLAIN QUERY PLAN` and VM steps over 100/1,000/10,000 outcomes for sparse old tasks;
  pages/cursors must match while work stops following unrelated lifetime outcomes.

## ST-07 · P3 · File-tree updates traverse every expanded branch on main

`Sources/ShepherdApp/FileTreeModel.swift:234-253,328-359` recursively finds/applies updates across
expanded nodes. Refresh repeats traversal for expanded directories: approximately O(K×N) for
K directories and N loaded nodes. Filesystem reads are already detached and directory-bounded.

- Fix: use separator-aware ancestor paths to traverse only the matching branch; no speculative
  indexing framework is required.
- Preserve: display-path identity, symlink containment, ordering and stale expansion rejection.
- Check: count visited nodes on wide/deep synthetic trees; selection/update should follow the
  ancestor branch rather than unrelated expanded descendants.

## Measurement boundary

The [optimized synthetic-state fixture](measurements.md) encoded 30/300/3,000 agents in
0.229/1.970/19.072 ms. It does not time disk writes, contention, real project payloads or first-window
startup. At ordinary fixture sizes, JSON encoding alone is not demonstrated to be a large stall;
profile the complete persistence/startup path before a wider architectural change.

## Existing improvements and correctness corrections

Changes index hashing now uses metadata to avoid unchanged reads; the pre-prompt working-tree
capture still intentionally gates Send. October's suggestion to send first is unsafe: queue
ordering does not stop pi editing before the baseline finishes. Measure/optimize the capture,
not its removal.

#398 adds bounded FIFO/version-fenced staging for selected layout/name/worktree mutations;
it is not blanket latest-wins state.json coalescing. Changes turn saves coalesce, but Undo
checkpoints remain synchronous and mandatory. StateStore retains its SQLite connection and
skips unrelated history preparation. Indexed message history pages are bounded. Checkout reads
share normalized directories, cap concurrency/time/output and reject stale members. Equal state
snapshots and unchanged space paths avoid redundant adoption/probes. Files visible-node caching
and Equatable rows already fixed the old render-time flattening issue. Palette content search
uses bounded recent tails, not lifetime transcript indexing.

Retain `synchronous=FULL`, outbox-before-publication and process/authority fences. Staging's
bounded conflict failures are tested backpressure, not measured starvation; do not weaken the
fence without preserving concurrent state and durable acknowledgements.
