# Performance remediation status

Status: functional fixes and review follow-ups are implemented and all stated final acceptance
gates passed. The chronological log below records superseded intermediate failures honestly.
[Post-fix measurements and raw samples](after/README.md) show ~5.8× faster streaming-tail refresh
at 5,000 messages in the synthetic Release fixture, not a measured app/frame-rate or device claim.
The chronological log below preserves superseded failures and intermediate pending states;
the final acceptance results take precedence.

The source audit is pinned to `f80d01132`. This fix branch starts from newer nightly
`f52bf0cc7`, retaining #402, #404 and #405. It includes the audit's committed evidence
(`e7de8b201`). Newer changes must not be reverted to make a benchmark or test pass.
Nightly through `876c570fc` (#406–408) is integrated via reviewed server merge `93ad5359`.
Queue-boundary delivery and durable recovery staging are reconciled in storage `64fa756b`,
merged into integration as `2cef8b03`. All seven lanes and correctness follow-ups are integrated;
no active audit finding is intentionally deferred as a functional fix. Measurement coverage gaps
remain explicit below and do not establish any competitive “fastest app” claim.

## Ownership and closure ledger

Each lane writes a separate worktree. The parent reviews and commits completed changes, merges
only between integration builds, reruns the affected checks and compares optimized measurements.
A lane's report is advisory until integration validation. Overlapping labels below describe the
same path, not additional independent performance gains.

| Lane | Audit IDs | Status | Required evidence |
| --- | --- | --- | --- |
| Shared thread | IO-02, IO-03, UX-01, UX-02, UX-05 | Implemented; joined correctness and optimized fixture pass | Projection equivalence for historical changes/compaction/neighbors; bounded parser tasks; failed-send content recovery; epoch-correct revision reuse; tail-refresh benchmark |
| Server | SV-01 through SV-06; server half UX-03 | Implemented; included in final joined correctness run | Sidecar-aware transcript invalidation; ordering/failure-safe refresh; one image fetch/hash; recovery lookup scaling; durable ordered send and fair stderr including EOF |
| Storage | ST-01, ST-03 through ST-07, UX-08; source half UX-07 | Implemented; lifecycle regressions and final joined run pass | Byte-budget eviction; canceled actual Git work; ordered durable writes; batched checkout transitions; indexed/bounded queries; branch-local file updates; crash-safe image checkpoints |
| Transport | SF-01, IO-06, UX-04; protocol half IO-05 | Consumers integrated; focused parent tests passed | Bounded real parser/socket backlog without loss; nonterminal callback bounds; scoped rate-bounded hints; old/new client contracts and ownership |
| Mac | MC-01 through MC-08, ST-02; UI half UX-03/UX-07 | Implemented; renderer/reader/recovery regressions and app build pass | Prepared inline markup; inactive history budgets preserving readers; transition-safe adoption; structural/live row independence; off-main attachment/text work; lazy project rows; safe startup; light/dark previews |
| Mobile | IO-01, IO-04, IO-07, IO-08, UX-06; UI half IO-05 | Merged; parent full portable runner passed | Review byte/revision bounds and multiwindow state; progressive bounded digest publication; retained bounded iPad details; lazy pins; correct reconnect states; phone/iPad light/dark checks |
| Surfaces/extensions | SF-02 through SF-04, SV-07 | Review fixes merged; parent joined tests passed | Off-main encoding; shared image cost budget and visible reload; safe per-load asset indexing; race-free event-driven child capacity waits |
| Instrumentation/builds | OBS-01 through OBS-04, shared among parent and UI/thread/server lanes | Implemented; optimized measurements and both app builds pass | Local fixed-label interaction signposts without new data uploads; meaningful existing iOS full-display completion; ordinary Release test compilation |

ST-06: the user explicitly approved the additive `history_outcome_task` SQLite index during
normal initialization. It retains existing rows and old-binary compatibility. Only scratch
DBs may be migrated during validation; the one-time index build cost must be reported.

All assigned findings must reach a recorded disposition. A blocker or invalidated diagnosis is
not a completed fix. Physical-device tests, energy/thermal runs and competitor measurements may
require equipment that is not available; those limits must remain explicit.

## Final acceptance results

- Combined Swift selection: **4,365 tests, 486 suites passed**, including all unit targets and
  affected recovery/queue/project/storage/Mac/renderer integration suites. This is not a claim
  that every integration test in the repository ran in the final selection.
- Normal Release test build passed; no reduced harness or debug-only counters needed.
- All **57 extension test files** passed with bundled Node and isolated Shepherd environment.
  Subsequent changes do not touch extension code.
- Full mobile portable runner passed again after the final iOS-only table-map adapter, exit 0.
- Release/Python: **361 tests passed, one skipped**, exit 0. Final docs guards: **10 passed**.
  Final `git diff --check` passed. Acceptance code is `d7cd8b20`; remaining edits are this report
  and archived benchmark evidence, not app behavior.
- macOS Dev and iOS Simulator builds passed. iOS initially exposed a shared-API map adapter
  mismatch; `d7cd8b20` corrects the two call sites and the build now passes.
- Renderer 256 KiB fixture retained; cancelled-work and A→B→A/structural-filter regressions pass.
- Synthetic Release streaming-tail refresh medians: 0.326→0.076 ms (100 messages),
  2.316→0.404 ms (1,000), 10.811→1.863 ms (5,000). The full comparison preserves small
  regressions (100-agent status reports and 300-agent workspace decode), not just improvements.
- Parent inspected light/dark Mac recovery, rich prose, design picker and launch surfaces;
  phone/tablet switching/recovery/reconnect and two-scene iPad fixtures were inspected. These
  isolated render/interaction checks do not establish production frame-time or battery budgets.

**Coverage limits:** no physical-device or power-loss testing, competitive app comparison,
presented-frame latency/typing hitch trace, long-duration thermal/energy/retained-memory soak,
or measured one-time SQLite index creation cost on a representative large archive. UserDefaults
text recovery is not an fsync/power-loss journal; image bytes are explicitly not persisted.
Benchmarks use three run summaries on one M4 Max, not stable p95/p99 estimates. Full history
transport/decode still scales with history; no new delta protocol was added.

**Departures:** no supplied visual spec was intentionally changed. Pending submission/recovery
controls and temporary unstyled text during off-main parsing are disclosed behavior changes;
text is never silently truncated, uncertain sends are never automatically retried, and drafts
are not cleared on local admission refusal. TestFlight is not part of this authorized Mac merge.

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
   remaining gaps. The user subsequently authorized merging after everything is fixed and validated.
   Unresolved regressions still block merge; do not auto-merge prematurely. Mac release follows the
   authorized merge; TestFlight remains separate.

## Coordinated contracts

- `native.revisions.v1`: capability-gated replacement subscription of at most 64 visible ordinary
  threads per connection; coalesced changed-agent hints. Connection restart clears subscriptions.
  Clients aggregate visible owners and wake existing poll loops only, retaining polling fallback.
- `native.fleetDigest.v1`: capability-gated bounded Home metadata with session/revision validation;
  older hosts and oversized digest responses use explicit snapshot fallback. Preview revision zero
  must not be treated as a content freshness proof. UI consumers and contract tests are integrated.
- Cache eviction: shared-store readiness/byte estimates, with host-side visibility and per-view
  reader ownership. Unresolved sends and readers are not discarded to satisfy a budget.
- Recovery: retain the existing checkpoint JSON. Stage expensive persistence work with callback-based
  durable admission rather than introducing a blob envelope or accepting queued work before its
  checkpoint is committed. Cancellation/session/revision fencing tests are required.

- Mac follow-up `ae312f3f` merged after the extension run finished. Parent inspected light/dark
  launch and submission-row previews; source-level final review is running. The lane reports all
  2,752 selected unit tests and individually run affected integration suites passing, but a combined
  integration attempt timed out without a final result. Parent six-lane unit/affected Mac integration
  validation passed **4,067 tests/466 suites**, exit 0, in 78.3 seconds (tests, excluding build).
  This replaces—not infers success from—the timed-out worker run. Final review still found:
  multi-reader handoff can undo an explicit stop; refusal auto-restore finalizes before held
  reconciliation completes; captured text can erase its saved draft before memory-only recovery
  records settle; ordinary composer image imports remain ungated; first/oversized inline Markdown
  still falls back to main-actor parsing; row IDs are still scanned per content update. These are
  **merge blockers**, not completed audit items. Mac owns the first four fixes; mobile is checking
  its analogous persisted-draft loss; a separate render follow-up owns cold/oversize parsing and
  structural revision separation. Captured recovery must retain text-only uncertain records across
  relaunch without automatic retry or claiming unpersisted image bytes survived.
  Mac follow-up `014fca04` merged via `a26a557a`: explicit reader epoch invalidation, restore-before-
  serve ordering, capture-time text recovery, selection-aware import gating and reconciliation-
  retained refusal metadata. Parent inspected final light/dark submission renders. Review caught
  scalar-record serialization crashing outside Swift error handling and one malformed agent hiding
  valid siblings; parent fixed both with mixed malformed/rewrite/relaunch tests (`06efd038`).
  Parent combined Mac recovery/composer/reader checks passed **43 tests/8 suites**, exit 0.
  Markdown/index work remains a separate pending lane.
  Mobile recovery checkpoint `5a21659e` adds bounded text-only persisted records and real-store
  second-instance checks. It is not yet accepted: observation schedules saving asynchronously,
  and restore removes recovery before draft persistence; these ordering windows are under review.
  UserDefaults in-process reload is not evidence of fsync-grade crash durability. Parent supplied
  the already-corrected shared portable contract test (`78da05c1d` in mobile), unblocking its full
  runner. Independent frozen review additionally found stale pre-readiness admission of combined
  saved/live text, late submission updates recreating pruned host records, and unvalidated loaded
  arrays/duplicate IDs that can lose distinct text on discard/restore. All are assigned regressions
  and fixes before acceptance; oversized valid saved content must not be silently truncated.
  Parent added `captureAdmission` in `0e1b5a2a`: optional synchronous exact-payload owner admission
  after readiness and shared limits, before input clearing/dispatch. Focused tests prove refused
  post-readiness edits stay intact and owner recovery is written before capture. Eight bounds
  tests and the full **1,239-test remote unit suite** passed, exit 0. Hook is cherry-picked into
  mobile (`fcde30f37`). Final admission/pruning follow-up `2afc207b` is merged: exact combined
  budgets, saving before capture, restore-to-draft before record deletion, and deleted-thread
  resurrection fencing. Parent inspected recovered/refused phone/tablet light/dark renders and
  is rerunning the full portable runner. Worker simulator build passed. Existing UserDefaults
  supports orderly relaunch recovery, not fsync-grade crash/power-loss guarantees; images remain
  memory-only and recovered banners say they were not kept. A bounded two-reader validation and
  preservation of individually malformed legacy records are the remaining mobile checks.
  The parent post-merge full portable runner subsequently failed the held-digest reconnect check
  (`MobileFreshnessCheck:265`, full-reply count after reconnect). Root cause was a test-host reply
  sent through a descriptor reused by a new connection. `27254485` guards reply/close ownership
  under one lock and preserves unreadable saved entries. Worker reproduced 4/84 failures before
  and 0/100 after; parent full portable rerun passed, exit 0, and the parent iOS Simulator app build
  succeeded. Two real simulator scenes
  passed nine checks/theme, but only one scene runs the thread at a time; simultaneous active
  windows remain a physical-device gap. Supplied screenshots showed Home after teardown; actual
  app-window captures were requested before claiming visual coverage. A bounded 36-check rerun
  captured before Forget; parent inspected `final-window-shots-3` light/dark PNGs showing the app
  and retained failed input. Only the front scene is visible/active; simultaneous side-by-side
  rendering remains unproven. Fixture changes `bdbb67c2` await the current build before integration.

## Validation recorded so far

- Broad acceptance on `f7a3f49e`: **4,365 tests/493 suites passed**, exit 0, 85.254s test execution.
  Release compilation passed, exit 0. Checkout read duration in the broad run was 69.778ms,
  round-trip 69.832ms; the prior 6.57s total did not isolate command duration. This test correction
  is not a production speedup. The benchmark's first attempt stopped before compiling because
  the script omitted the archived fixture's `.txt` suffix; the scratch path is corrected and
  measurements/remaining build checks continue without a production-code change.

- The late-binding broad rerun completed 4,365 tests with one failed wall-clock assertion:
  checkout timeout measured 6.57s including detached-task scheduling and main-actor resumption.
  `f7a3f49e` records command execution/cleanup inside the worker, preserving the 50ms command
  timeout and 3s limit, and prints both timings. Six focused checkout tests passed at ~70ms.
  A fresh broad run must confirm command duration under load; it is not yet a final pass.

- Final joined selection at `3f03a2b5e` ran **4,364 tests/493 suites**, failing only two arguments
  of the bounded-startup test: the .5s readiness deadline was armed before scheduling the UI
  observer, so a loaded runner could correctly go directly to failure without showing Starting.
  Test-only `25353884` observes Starting first, then hides the observer and arms the unchanged
  half-second deadline. Both arguments pass focused; the exact broad selection is queued again.
  Deadline expiry, hidden failure, retained opening prompt and exactly-once late delivery assertions
  remain unchanged. No timeout was lengthened and no production startup behavior changed.
  The ordered broad rerun at `2e94a4350` again ran 4,364 tests/493 suites: one remaining issue,
  recovery bootstrap never completed for the agent-lookup budget test. The late agent-binding
  path was confirmed by a deterministic reproduction: RPC bootstrap can precede Agent/Tab
  ownership, and recovery was never retried after binding. Fix `435d61444` restores after binding
  before UI notification and removes the announcement first to fence reentrancy. The worker's
  reproduction failed before the fix; 112 tests/7 suites passed afterward. Parent integrated it,
  started fresh sequential acceptance gates on that commit. Independent review found no
  actionable issues: removal-before-restore prevents reentrant duplicate announcements and
  `restoringRecovery` guards duplicate restoration; existing readiness/durability gates remain.
  Prior Release compilation passed (exit 0, 428.85s); it will be rebuilt after the lifecycle fix,
  with isolated benchmarks and final app checks gated on the new correctness result.
  Parent also terminated three verified orphaned renderer test helpers from the earlier held-parse
  investigation (exact PIDs, owned scratch worktree, parent PID 1), clearing benchmark contamination.

- Coordinator launch fix `c55ba797b`: parent combined project/runtime/recovery selection passed
  **75 tests/3 suites**, exit 0, after the worker's repeated held-start/relaunch regressions.
- Rendering first batch `5223a9f6` integrated as `faa8a046e`: cold inline/block parse preparation
  no longer depends on cache admission, and row-ID indexes follow a structural revision instead
  of every content tick. Parent inspected rich-parts light/dark previews. The original 256 KiB
  paragraph fixture originally timed out, but the bounded diagnostic isolated a lost-wakeup race
  in the held-parse test helper, not a styling/layout stall. The original 256 KiB/1,537-run fixture
  is restored and passes without truncation; no styling speedup is claimed from this probe.
  Independent review also found a same-count interior Project filter swap could leave stale row
  indexes, and A→B→A oversized block updates could allow pending B to overwrite A. Follow-up
  `da58f6fb` fixes both and retains cancelled parse reservations until work truly exits. Both
  negative controls fail without their fixes; all 29 final focused tests passed in the worker.
  Parent integration waits for the running Release build to finish before changing source.
- Independent audit-closure pass found no other missing functional finding beyond tracked
  renderer follow-ups. It did not claim measured first-paint/energy/physical-device wins; those
  validation gaps remain explicitly open.

- Paused coordinator regression: `c55ba797b` prevents native snapshot demand from racing the
  Project admission launch; ordinary agent demand and stopped-session previews are unchanged.
  Deterministic gates prove one pi binding and one queued-operation handoff. Worker reproduced
  the prior failure, then passed four serialized regressions and 36 affected tests. Parent combined
  project/runtime/recovery tests and independent guard review are running. Diagnostic AX output
  now tolerates infinite coordinates instead of trapping while explaining a test failure.

- Equal-text unsteer attachment ownership: `9948de67` excludes the returned item from restoration
  matching, keeping remaining records' IDs/images. All four worker cases (either item,
  success/failure) and 121 queue/recovery tests passed. Parent integrated it as `a21e308e5`;
  parent queue/recovery/control selection passed **119 tests/10 suites**, exit 0.

- Parent integrated macOS Dev app build: **BUILD SUCCEEDED**, exit 0; iOS Simulator app build also
  passed. These precede the pending Markdown and equal-text unsteer follow-ups and must be
  incrementally revalidated on the final commit.

- Storage final queue merge `64fa756b`: worker reports 218 runtime, 195 storage and 68 project
  control tests passed, exit 0. The held-write boundary test explicitly resumes its server-side
  continuation before shutdown; request cancellation alone cannot cancel fixture-held work.
  Parent merged storage as `2cef8b03`, preserving directory-based checkout tracking and the Mac
  lane's relocated cleanup rather than reinstating duplicate cleanup. The bounded combined run
  completed 4,440 tests/492 suites with nine issues across five tests: one recovery-index rebuild
  assertion (five reports) and four startup/project timing failures. All five passed the focused
  rerun in 4.156 seconds, exit 0. The budget test now explicitly awaits recovery bootstrap before
  measuring checkpoint lookups (servable snapshots can arrive first); its unchanged count/version
  assertions and all 11 ServerWorkBudgetTests pass, exit 0. The four other failures remain recorded
  as broad-run timeouts, not a proven production regression or a final full-tier pass.
  Independent final review found a blocking interleaving: settlement during held restorePiQueue
  staging can discard original image-bearing records/IDs before re-admission. Correction `768e7a66`
  retains restoration ownership through staging/re-admission and rejects late admission after the
  originating run settles. Worker passed 12 regressions, 163 runtime and 67 controls. The correction
  is merged. Parent combined run: 191 tests with one failing paused-relaunch/slow-start Project
  scenario (two issues); dedicated diagnosis is underway rather than accepting its old baseline
  history. Final review found authorization must start before the held clear_queue reply, and goal
  unyield must recheck after final ownership release. Both corrections require new regressions.
  `dd59178c` now captures clear authorization/ownership before RPC and rechecks goal unyield on
  final release. Worker passed eight clear-response cases, two goal cases, 177 runtime tests and
  67 control tests; parent merged it and is rerunning combined queue/recovery checks. Final review
  cleared cancellation/goal fixes but found identical-text steers with different images could match
  the wrong original after unsteer; ownership matching is being corrected with an image/ID regression.
  The prior failing test run is retained, not rewritten as green.

- Full Release/Python run: **361 tests, one skipped, exit 0** after correcting the design-index
  guard to exempt explicitly Removed surfaces with a required departures.md record. The first
  run failed only on historical PaneArtifacts/PaneArtifactEdit entries, unchanged on nightly;
  active surfaces still require a resolvable spec and all linked files still must exist.
  Logs: `release-python.log`, `release-python-corrected.log`.

- Parent upstream-queue integration run passed **221 tests/16 suites**, exit 0.
- Before merging the Mac batch, parent ran the refused-Send and six project-question routes on
  `4ef9a8d4a`: refused-Send passed; both project-text cases passed; four pane-option/pane-text
  cases timed out. Mac's disabled-Send failure is therefore not reproduced on integration.
  Pane failures also reproduce on server-only `93ad5359`, without new shared-thread or Mac UI
  changes (same four failing cases). Root cause was a stale AX selector: native pane labels the
  field “Something else”, Project card “Say anything”. Test-only correction `ca8043431` preserves
  all delivery/rejection/draft assertions and checks both fields disappear; all six routes passed
  in the worker. Parent inspected light/dark rejection PNGs and independently reran both tests
  (including all six pane variants) on integration: passed, exit 0.
  Full logs `pre-mac-logical-project.log`, `server/nightly-merge/pre-thread-pane-baseline.log`,
  and `pane-question/` contain baseline, AX evidence and fix results.

- Storage final staging checkpoint `b6316066`: lane reports 205 runtime tests/15 suites, 163
  storage tests/15 suites, and 67 isolated ProjectExecution/ThreadEvent tests/2 suites, all exit 0.
  Index workload counts are 37 VM steps at 100/1k/10k rows versus scans of 871/8,971/89,971
  steps, not elapsed-time measurements. Parent checkpointed the clean stopped boundary; storage
  awaits the server/#408 merge and integrated validation. Final independent review found three
  additional blockers: duplicate operation waiters lost during staged-admission reset, session/name
  authority not rechecked at actual persistence commit, and canceled remote reviews continuing to
  request files. The worker resumed to fix all three with held-operation/reply regressions; remote
  Changes reads may become cancellable, but Undo/Redo/Revert mutations must still await outcomes.
  Follow-up `4f4ec3f9` passed 98 tests/9 suites in the worker. Parent initiated `93ad5359` merge;
  storage is resolving the Queue.swift semantic joins and rerunning held-stage/deadline tests.
  Its first boundary merge run stalled over 2.5 hours. Parent sampled the verified storage test
  helper, then terminated only the two exact owned test processes. This is a failed/hung run,
  not a pass; diagnosis and bounded focused reruns are required. Sample: `storage/hang/`.

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
  the original four issues; the overflow-safe accounting follow-up `578b24e4` passed 17 focused
  tests in a parent-run check, exit 0. Both follow-ups are merged; the parent remote/protocol run
  passed **1,904 tests/186 suites**, exit 0. Composer image/persistence recovery and validated
  connection-epoch wiring remain pending.
- Parent pinned-Node child extension run: 36/37 passed; the broad real-Pi lifecycle case timed out
  waiting for an inspector reply with zero active test timers. The focused real-Pi lifecycle file
  rerun passed all 14 tests, exit 0; root cause/baseline classification remain unproven. Final full
  pinned-runtime run later exposed four failing files (53/57 passed). Root causes were missing
  empty-queue acknowledgements in the shared fixture (12-second waits per turn) and inspector
  watchers closing/reopening across live/idle transitions, losing notifications. Fix `5f482420`
  preserves watcher lifetime through parent shutdown and explicitly acknowledges fixture boundaries;
  deterministic lifecycle/cleanup regressions fail on old code. Worker reruns passed all four files
  plus shared consumers; parent full rerun passed **57/57 files**, exit 0, with inherited Shepherd
  flags cleared. This run includes queue-boundary integration through #408.
- Parent's first transport/surfaces run: 172 tests, one failing capability-enumeration test/two
  issues. New capability constants were missing from its exhaustive expected list; corrected in
  `c641bde80` with stable-string assertions. The joined four-lane run now includes all remote and
  protocol unit tests, plus transport/design integration regressions. Its first build failed to link
  stale dependent objects referencing the old three-argument `NativeThreadStore.run` signature.
  Integration-local dependent target object caches were invalidated; the cached build plan also
  needed regeneration to recreate missing output maps. The replanned four-lane run passed **1,985
  tests/196 suites**, exit 0. Neither failed build reached tests. This result precedes `c3f131aa`
  and the still-unmerged Mac/mobile/storage consumers; it is not final-branch validation.
  The subsequent full unit run passed **3,992 tests/451 suites**, exit 0, on that same code.
- Mac first batch checkpointed `0ef3ade8` (31 files); integration and `c3f131aa` prerequisites
  merged cleanly into its lane. Nine focused unit suites passed before prerequisites. Independent
  review found three blockers: visible-reader retention tied to replaceable polling ownership;
  async file preparations without draft-generation/pending-send fences; and Dock reopening only
  installed after model readiness. Fixes and deterministic regressions are assigned, including
  remaining-reader polling after another window closes. Consumer wiring, post-merge integration
  tests and previews are pending.
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
  payloads after backing-revision eviction. Follow-up fixes and composer recovery checkpointed as
  `5239ed67`; shared recovery APIs and overflow guard through `578b24e4` merged cleanly into mobile.
  Discard UI, mobile simulator compilation and light/dark renders passed in the lane. All mobile
  changes through `8ae34412` are merged. Parent inspected recovery/offline/Home/Review iPhone and
  recovery/switching/running/reconnecting iPad light/dark renders. Full portable validation passed
  on integration, exit 0, with old send assertions updated to check captured/uncertain records,
  edited drafts and exact late acknowledgements rather than blocking the composer until receipt.

Full run logs will be retained under `/tmp/shepherd-perf-fixes`. Lasting evidence and final
results will be summarized here before opening the PR. Build concurrency and disk use are bounded;
workers must pause new builds when shared free space falls below 10 GiB, without deleting files.
