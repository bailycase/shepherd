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
| Shared thread | IO-02, IO-03, UX-01, UX-02, UX-05 | In progress | Projection equivalence for historical changes/compaction/neighbors; bounded parser tasks; failed-send content recovery; epoch-correct revision reuse; tail-refresh benchmark |
| Server | SV-01 through SV-06; server half UX-03 | Implemented in lane; independent review pending | Sidecar-aware transcript invalidation; ordering/failure-safe refresh; one image fetch/hash; recovery lookup scaling; durable ordered send and fair stderr including EOF |
| Storage | ST-01, ST-03 through ST-07, UX-08; source half UX-07 | In progress | Byte-budget eviction; canceled actual Git work; ordered durable writes; batched checkout transitions; indexed/bounded queries; branch-local file updates; crash-safe image checkpoints |
| Transport | SF-01, IO-06, UX-04; protocol half IO-05 | In progress | Bounded real parser/socket backlog without loss; nonterminal callback bounds; scoped rate-bounded hints; old/new client contracts and ownership |
| Mac | MC-01 through MC-08, ST-02; UI half UX-03/UX-07 | In progress | Prepared inline markup; inactive history budgets preserving readers; transition-safe adoption; structural/live row independence; off-main attachment/text work; lazy project rows; safe startup; light/dark previews |
| Mobile | IO-01, IO-04, IO-07, IO-08, UX-06; UI half IO-05 | In progress | Review byte/revision bounds and multiwindow state; progressive bounded digest publication; retained bounded iPad details; lazy pins; correct reconnect states; phone/iPad light/dark checks |
| Surfaces/extensions | SF-02 through SF-04, SV-07 | In progress | Off-main encoding; shared image cost budget and visible reload; safe per-load asset indexing; race-free event-driven child capacity waits |
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

## Validation recorded so far

- Parent: ordinary `swift test --build-system native -c release -j 2` now builds all test targets
  successfully. `ResponseTimingTests/lateMarksUpdateAlreadyProjectedHistory` and
  `ChangesEngineTests/aDirectoryOutsideGitHasNothingToCompare` passed (2 tests, 2 suites).
  Only DEBUG-only counter assertions/tests were gated; production optimization flags and
  behavioral coverage were not replaced with a reduced harness. Debug counter checks still
  need their final integrated run. Commit `3719b3c9`.
- Server lane: 242 tests/17 suites and 10 docs guards reported green; commit `4f80977f`.
  Independent review and parent integration tests remain pending. These are not final-branch results.
- Mobile lane: simulator build and new portable checks reported successful; remaining renders,
  full portable-script repair and integrated digest protocol work are still pending.

Full run logs will be retained under `/tmp/shepherd-perf-fixes`. Lasting evidence and final
results will be summarized here before opening the PR. Build concurrency and disk use are bounded;
workers must pause new builds when shared free space falls below 10 GiB, without deleting files.
