# Performance remediation status

Status: implementation and validation in progress. No claim of completion or speedup yet.

The source audit is pinned to `f80d01132`. This fix branch starts from newer nightly
`f52bf0cc7`, retaining #402, #404 and #405. It includes the audit's committed evidence
(`e7de8b201`). Newer changes must not be reverted to make a benchmark or test pass.

## Ownership and closure ledger

Each lane writes a separate worktree. The parent reviews and commits completed changes, merges
only between integration builds, reruns the affected checks and compares optimized measurements.
A lane's report is advisory until integration validation. Overlapping labels below describe the
same path, not additional independent performance gains.

| Lane | Audit IDs | Status | Required evidence |
| --- | --- | --- | --- |
| Shared thread | IO-02, IO-03, UX-01, UX-02, UX-05 | First batch merged; four review blockers and UI consumers pending | Projection equivalence for historical changes/compaction/neighbors; bounded parser tasks; failed-send content recovery; epoch-correct revision reuse; tail-refresh benchmark |
| Server | SV-01 through SV-06; server half UX-03 | Merged; parent 248-test integration run passed | Sidecar-aware transcript invalidation; ordering/failure-safe refresh; one image fetch/hash; recovery lookup scaling; durable ordered send and fair stderr including EOF |
| Storage | ST-01, ST-03 through ST-07, UX-08; source half UX-07 | In progress | Byte-budget eviction; canceled actual Git work; ordered durable writes; batched checkout transitions; indexed/bounded queries; branch-local file updates; crash-safe image checkpoints |
| Transport | SF-01, IO-06, UX-04; protocol half IO-05 | Merged; parent tests running, consumers pending | Bounded real parser/socket backlog without loss; nonterminal callback bounds; scoped rate-bounded hints; old/new client contracts and ownership |
| Mac | MC-01 through MC-08, ST-02; UI half UX-03/UX-07 | In progress | Prepared inline markup; inactive history budgets preserving readers; transition-safe adoption; structural/live row independence; off-main attachment/text work; lazy project rows; safe startup; light/dark previews |
| Mobile | IO-01, IO-04, IO-07, IO-08, UX-06; UI half IO-05 | In progress | Review byte/revision bounds and multiwindow state; progressive bounded digest publication; retained bounded iPad details; lazy pins; correct reconnect states; phone/iPad light/dark checks |
| Surfaces/extensions | SF-02 through SF-04, SV-07 | Review fixes merged; parent joined tests running | Off-main encoding; shared image cost budget and visible reload; safe per-load asset indexing; race-free event-driven child capacity waits |
| Instrumentation/builds | OBS-01 through OBS-04, shared among parent and UI/thread/server lanes | In progress | Local fixed-label interaction signposts without new data uploads; meaningful existing iOS full-display completion; ordinary Release test compilation |

ST-06: the user explicitly approved the additive `history_outcome_task` SQLite index during
normal initialization. It retains existing rows and old-binary compatibility. Only scratch
DBs may be migrated during validation; the one-time index build cost must be reported.

All assigned findings must reach a recorded disposition. A blocker or invalidated diagnosis is
not a completed fix. Physical-device tests, energy/thermal runs and competitor measurements may
require equipment that is not available; those limits must remain explicit.

## Integration validation plan

1. Focused tests in each lane, preserving full commands and exit codes. Test work must remain
   local, scratch-isolated, without focus/input or production credentials/data.
2. Review source/contracts and run a separate correctness review for durable sending, incremental
   derivation, persistence and transport acknowledgements before calling them complete.
3. After all merges, run applicable Swift unit/integration tests, protocol/portable iOS checks,
   pinned-runtime extension tests, affected light/dark previews and both app builds. Investigate
   failures; compare suspected baseline issues against the pinned starting commit rather than
   weakening tests.
4. Repeat the recorded optimized data paths on an idle machine, with matched fixture/compiler
   settings. Keep Debug offscreen UI results separate. Report samples/ranges and work counts;
   do not turn three runs into stable p95/p99 claims.
5. Exercise actual app/simulator behavior only through isolated fixtures/dev installations that
   do not touch the running app or user's runtime data. State device-level gaps plainly.
6. One PR into `nightly`, with per-finding closure, real validation, design departures and any
   remaining gaps. Opening the PR does not authorize auto-merge or a new release.

## Coordinated contracts

- `native.revisions.v1`: capability-gated replacement subscription of at most 64 visible ordinary
  threads per connection; coalesced changed-agent hints. Connection restart clears subscriptions.
  Clients aggregate visible owners and wake existing poll loops only, retaining polling fallback.
- `native.fleetDigest.v1`: capability-gated bounded Home metadata with session/revision validation;
  older hosts and oversized digest responses use explicit snapshot fallback. Preview revision zero
  must not be treated as a content freshness proof. UI integration and contract tests are pending.
- Cache eviction: shared-store readiness/byte estimates, with host-side visibility and per-view
  reader ownership. Unresolved sends and readers are not discarded to satisfy a budget.
- Recovery: retain the existing checkpoint JSON. Stage expensive persistence work with callback-based
  durable admission rather than introducing a blob envelope or accepting queued work before its
  checkpoint is committed. Cancellation/session/revision fencing tests are required.

## Validation recorded so far

- Parent: ordinary `swift test --build-system native -c release -j 2` now builds all test targets
  successfully. `ResponseTimingTests/lateMarksUpdateAlreadyProjectedHistory` and
  `ChangesEngineTests/aDirectoryOutsideGitHasNothingToCompare` passed (2 tests, 2 suites).
  Only DEBUG-only counter assertions/tests were gated; production optimization flags and
  behavioral coverage were not replaced with a reduced harness. Debug counter checks still
  need their final integrated run. Commit `3719b3c9`.
- Parent baseline Release unit run before any performance lane merge: 3,974 tests/449 suites,
  exit 1, one failure in `aCancelledFetchInTheLineLeavesItAndNeverTakesAPlace`'s `<0.25s`
  scheduling assertion. This is a baseline failure, not a lane regression. Deterministic held-fetch
  cancellation coverage is being added instead of weakening the assertion's intended behavior.
- Server lane: 242 tests/17 suites and 10 docs guards reported green; commit `4f80977f`.
  Independent review found a preparation-completion lifetime gap for steering on process exit,
  plus a fleet-wide cache-budget gap despite bounded individual threads. Both are fixed in
  `c8df50ad` and merged into integration. Expanded safety checks passed 248 tests/19 suites and
  ten docs guards. A second independent review of the follow-up found no actionable regressions.
  Parent independently reran that selection on integration: all 248 tests/19 suites passed, exit 0.
  The process-wide 64 MiB/256-entry cache and 128 MiB worker reservations bound payload/storage costs, not total RSS.
  The earlier ~2.34 GiB 100-thread figure was capacity arithmetic, not measured retention.
- Surfaces lane: 58 Swift tests and 24 pinned-runtime Node tests reported green; commit
  `c86e4eda`. Independent review found whole-row demand-key mismatch, missing New Thread picker
  teardown, and an empty-snapshot revision-watermark gap. All three require targeted fixes/tests
  before acceptance. Corrected in `e01263f95` (27 focused tests, four real-window picker cases,
  three preview tests passed in separate runs). The unrelated timing-dependent image suite is
  repaired with controlled host continuations in `ab1aecec`. Both are merged into integration.
  Parent inspected old/new picker light/dark PNGs; layouts remain coherent. One combined
  preview/exit-test run timed out in the lane; separate reruns passed. Parent joined correctness
  tests are running without mixing preview tests into process-exit suites.
- Storage first batch: 157 tests/15 suites passed; committed as `43c53ae1`. Server prerequisite
  `4f80977f` merged into that lane as `c1570a02`, preserving staged ordinary session updates but
  synchronous session-identity durability at recovery admission. Same-thread stale session-intent
  fencing and full callback-based recovery staging remain in progress. Independent review of the
  frozen commit additionally found missing staged-pane ownership fencing, uncancelled tasks on
  ordinary review removal, and no-op metadata reports saturating the admission queue and dropping
  later real updates. Review-fix checks passed 91 tests/four suites before the recovery draft.
  Draft recovery staging and fixes checkpointed as `85fa2223`; server follow-up `c8df50ad` merged
  cleanly into the lane. Compilation, full joined validation and recovery correctness review remain
  required; the draft checkpoint is not a claim that UX-08 is complete.
- Transport lane: 175 tests/15 suites plus four metadata/reconnect tests reported green, along
  with targeted portable connection/backpressure/thread checks; commit `7138437a`.
  Independent review requires three fixes before acceptance: union optional board/comment
  invalidations when coalescing, fence captured callback batches before delivery after reconnect,
  and make fleet-digest reads cancellable without a later connection-tearing timeout. All three
  are fixed in `0f0250b1`; 76 Swift tests and real-socket portable regressions passed in the lane.
  Parent inspected the generation guard, invalidation union and cancellable request changes.
  Transport is merged after the prior build finished. Parent joined correctness tests are running;
  Mac/mobile digest/hint consumers remain pending.
- Shared thread `e85914ee` merged: lane reports 254 focused tests and 20 image tests passed.
  At 100/1k/10k-history sizes, 200 streaming tail updates rebuild 1,000 messages/rows; incoming
  comparisons remain linear. This is a work-count result, not a timing/frame-rate claim. Independent
  review found four blockers: `outcome_unknown` incorrectly restorable as a definite failure;
  unbounded failed/uncertain submissions with no disposal path; parser slots freed before canceled
  synchronous work actually finishes; and duplicate subagent ownership across preserved-prefix
  boundaries. Follow-up `c3f131aa` addresses all four; 260 focused and 16 targeted tests passed
  in the lane, with independent re-review and integration pending. Admission now caps captured
  records at eight/16 MiB of accounted payload before clearing or sending; explicit disposal is
  allowed only for settled failed/uncertain records and performs no remote action. Re-review cleared
  the original four issues but requires overflow-safe payload accounting, now being added. Composer
  image/persistence recovery and validated connection-epoch wiring remain pending.
- Parent's first transport/surfaces run: 172 tests, one failing capability-enumeration test/two
  issues. New capability constants were missing from its exhaustive expected list; corrected in
  `c641bde80` with stable-string assertions. The joined four-lane run now includes all remote and
  protocol unit tests, plus transport/design integration regressions. Its first build failed to link
  stale dependent objects referencing the old three-argument `NativeThreadStore.run` signature.
  Integration-local dependent target object caches were invalidated; the cached build plan also
  needed regeneration to recreate missing output maps. The replanned four-lane run passed **1,985
  tests/196 suites**, exit 0. Neither failed build reached tests. This result precedes `c3f131aa`
  and the still-unmerged Mac/mobile/storage consumers; it is not final-branch validation.
- Mobile first batch committed `ea0bf14a`; entire portable runner passed after moving the
  Foundation-only host presentation extension into the shared portable source list. Transport
  prerequisite merged cleanly into that lane. Simulator build and new portable checks reported
  successful. Independent review found payloads retained outside `diffCache`, a queued task able
  to capture its epoch after `shed()`, and launch completion emitted before diagnostics startup.
  Corrections and digest consumers checkpointed in `cceb03f4`; current integration prerequisites
  merged cleanly into the mobile lane. Entire portable runner passes at that checkpoint, but the
  actual-store simulator retention fixture is not yet run. Review fixes, fresh-install readiness,
  multiwindow-close rerun, final renders and shared-store hint/connection/composer wiring remain
  validation gates. Independent follow-up review found two additional byte-budget holes: legacy
  whole-diff replies do not notify retention after growing offscreen, and old row caches keep text
  payloads after backing-revision eviction. Both are assigned actual-store regression tests and
  fixes before the mobile lane can satisfy its budget claim.

Full run logs will be retained under `/tmp/shepherd-perf-fixes`. Lasting evidence and final
results will be summarized here before opening the PR. Build concurrency and disk use are bounded;
workers must pause new builds when shared free space falls below 10 GiB, without deleting files.
