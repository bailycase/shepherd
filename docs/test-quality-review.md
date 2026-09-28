# Test quality review

Started 2026-09-28 from `316b04a9`, on `test/suite-quality`.

## Scope and standard

The goal is fault detection, not a target test count. Keep mandatory protocol round trips,
server mutations, security, data preservation, accessibility, and rendering budgets described
in AGENTS.md. Remove duplicate assertions only when another test protects the same behavior.
Prefer real observable results to source-string checks or fixtures that reproduce the fix.

This is a first pass, not a completed body-level review of every test. All test domains were
inventoried. Reviewers examined selected server/protocol, app/terminal, client/design, iOS,
preview, extension, and release tests. Entire files not read receive no keep/delete verdict.
The initial batch changed tests only. Follow-up work fixes concrete product bugs those tests
exposed, without expanding public APIs.

## First cleanup batch

| Area | Change | Meaningful failure |
| --- | --- | --- |
| Release publication | Fake GitHub requires the archive and honors the actual draft flag; execute refusal after missing archive instead of checking shell statement order | Failed required upload must not make a release public |
| CLI import | Load a nonempty saved workspace; assert existing agent and layout survive merge | Import silently discards existing conversations |
| Workspace mount order | Pending layouts include both projects with the selected project second in stable order; drain oracle uses requested IDs rather than actual output | Selected-project priority disappears or drained layouts never mount |
| Instruction editor | Mount real Settings composition, prove source Undo changes text, switch equal-content documents, then Undo | Old editor Undo changes the destination draft |
| Scrolling observations | Capture and OCR failures record test issues; inject an empty model catalog | Broken observation incorrectly proves the jump pill is absent; unrelated catalog work contaminates scroll tests |
| Queued images | Unexpected request kind records an issue instead of returning successfully | Wrong request bypasses all image assertions |
| Binary patches | Write literal binary bytes and compare the applied clone bytes | Empty or corrupted file passes an existence-only check |
| Canvas label visibility | Board itself is entirely outside the viewport, with an adjacent fully offscreen control | Dropping label expansion still passes because the original board was partly visible |
| Process termination | Await installed TERM handlers and require their distinctive normal exit | Immediate SIGKILL passes a test named SIGTERM |
| Redundancy | Remove standalone stable-order case, two status cases already in the complete table, and image-limit constant assertion covered by real boundary/output tests | No unique behavior removed |

## Product bugs exposed

**TQ1. Instruction Undo can modify the newly selected file's draft.** The real Settings page
starts with two empty documents. Editing and deleting text in AGENTS.md creates an undoable
change. After selecting APPEND_SYSTEM.md, Undo changes its model draft to the old text even
though the new editor remains empty. The previous fixture applied its own document identity
and did not establish an effective undo operation. Fixed by a document-owned native UndoManager
and binding captures for the specific file/host. The regression now runs without a known-issue
wrapper and also verifies destination Undo/Redo still works and old callbacks target the old
file. The test makes no disk save; the observed fault was in the destination draft.

**TQ2. Remote design sync accepted inconsistent transport results.** Executed regressions
showed corrupt inline data advancing the index and losing the last good file; a chunk with
incorrect SHA metadata and a three-byte transfer claiming four bytes also reported success.
Sync now refuses failed inline storage before publishing paths/index, rejects chunk digest
mismatch, and requires the final declared length. Invalid partial transfers are discarded.
This is not a promise of whole-sync transactional rollback.

## Initial validation

- Focused Swift run: 118 tests reported across affected targets, with the one newly demonstrated
  instruction-Undo known issue. This includes scroll, image, queue, mount, CLI, status, canvas,
  and binary-patch checks. Both strengthened process-termination tests also passed.
- All 163 Python release tests passed, including the 10 publication tests.
- Isolated fault checks: removing selected-project mount priority and removing board-label
  visibility expansion each fail the intended strengthened assertion. Main checkout unchanged.
- Isolated publication shell fault: ignoring the required upload failure fails the new refusal
  check. A first malformed injection only altered a quoted argument and was rejected as invalid
  evidence; the corrected shell mutation was executed and detected.
- Swift fault-copy test discovery initially failed to locate Sparkle. Adding a symlink inside
  that disposable build's PackageFrameworks directory allowed the checks to run. This was test
  environment repair, not evidence that a mutation was detected.
- No whole-suite, iOS simulator, or visual acceptance claim follows from these focused checks.

## Follow-up implementation

The first-pass candidates below have been addressed or deliberately retained with a reason.
Final combined validation is recorded below.

1. Replaced hand-written attachment acknowledgement cleanup with the real composer command
   path, delayed success/refusal, and a later attachment. Request bytes and retained images
   are checked independently; the old unit test was removed.
2. iOS fixture readiness now fails with a named condition instead of continuing to READY.
   Assertions require actual visible proposals, target identities, expected recognized text,
   and the independent live-view cap. Preview capture/OCR errors propagate and readiness needs
   positive loaded-content evidence. The standalone ThreadStoreCheck stays: it protects unique
   gated acknowledgement/history races, so wholesale deletion would lose coverage.
3. Sandbox tests parse independent CSP rules, exercise both font policies, and require real
   violation events with permitted local controls. PDF tests extract ordered unique paragraphs,
   rasterize a drawing across a hand-calculated page cut, and merge distinguishable inputs.
4. Remote download tests use independent SHA-256 vectors and scripted corrupt, stale, changed,
   truncated and wrong-offset responses. TQ2 fixes the three demonstrated missing checks.
   Existing changed-only, resume, forget and cache-eviction contracts remain.
5. Test startup clears inherited Git controls and installs scratch configuration/templates.
   A hostile child environment check executes the actual C isolation constructor. Repository
   preservation now includes non-object metadata bytes, symlinks, and executable modes, with
   deliberate scratch mutations proving the observation detects them.
6. Removed redundant launcher fragments after independent execution cases covered pins,
   refused commands, restored shell environments, startup isolation and missing engine files.
   Shipping identity/workflow checks remain where configuration itself is the contract.
   Signing now compiles a non-executable unsigned native addon and verifies its signature;
   removing addon discovery in an isolated copy fails that check.
7. Added nonempty/positive controls to rendering budgets without increasing ceilings, exact
   pane-span endpoint checks, and a usable item provider for unavailable-input rejection.
8. Consolidated duration tests and removed resource-marker and self-comparison assertions.
   Independent checksums, interpolation limits, token completeness, and real runtime boot tests
   remain. Extension tests now check retained fork content, exact cwd, actual stopped-child
   outcome, and a bounded asynchronous workflow-key readiness condition.
9. Additional review strengthened client remove/Undo state, pending recovery receipts,
   suggestion text/identity, image payloads, newest retained records, deterministic mutation
   orders and no-op disk preservation. Backlog teardown releases held queues and untransferred
   sockets on setup failure. No deletion is justified for unreviewed test bodies.

## Limits and deliberately retained coverage

This work completes the concrete cleanup candidates above, not an exhaustive assertion-by-
assertion audit of the repository. Review depth is recorded rather than inferred from passing
execution. Unreviewed bodies remain in lifecycle, design storage, worktree/commit, remote
transport and other domains. InstructionsModel's yield-based test readiness, optional splitter
unit-tier relocation, more late-provider/session-change scenarios, and end-to-end uncertain
remote commit recovery remain follow-up candidates, not demonstrated product defects.

The shared-store standalone executable remains because its unique gated races have not all
been duplicated by Swift Testing. Optional duration/menu consolidation was done only where
behavioral coverage remained equivalent. No new framework, test-count target, changed render
ceiling, discarded wire case, rewritten golden, or disabled regression was introduced.

## Combined validation

- `CI=true swift test --no-parallel`: 4,045 tests reported across 463 suites, no failures.
  Existing timing-sensitive, preview and external-service opt-ins remain gated. This run used
  the integrated tree before the final timing-only highlighting-fixture follow-ups; those
  follow-ups preserve the original bounds and have separate focused/repetition checks.
- 109 Node extension tests and 162 Python release tests passed.
- Mac Dev build and scratch launch passed. Instruction-editor previews were inspected in both
  appearances. The iOS simulator build passed; iPad markup/reply/panning/comment fixtures passed
  light and dark, plus dark offline-host/New-thread controls. Readiness timeout, cancellation
  and explicit assertion failure were executed and correctly exit without READY.
- Focused settings readiness previews passed in both appearances. These captures are evidence
  for the inspected surfaces, not a visual certification of the entire app.
- The code-highlight burst fixture initially exceeded its unchanged ceiling under load: fifteen
  forced layouts stretched one intended burst across throttle intervals. It now delivers the
  burst without those layouts and waits on actual completed highlighting. A deterministic
  per-invocation source suffix prevents a repeated test from reusing cached output. Three
  repetitions and the full ListPerformance suite passed with the original limits.
- PR CI is the final cross-machine check; see the pull request for its current result.

A passing suite with known issues is not proof that all product bugs or all test-quality defects
have been resolved. No exhaustive test-body review or whole-repository mutation score is claimed.
