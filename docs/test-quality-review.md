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
No production code changes are part of this batch.

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

## Product bug exposed, not fixed here

**TQ1. Instruction Undo can modify the newly selected file's draft.** The real Settings page
starts with two empty documents. Editing and deleting text in AGENTS.md creates an undoable
change. After selecting APPEND_SYSTEM.md, Undo changes its model draft to the old text even
though the new editor remains empty. The previous fixture applied its own document identity
and did not establish an effective undo operation. The replacement test runs with a named
`withKnownIssue` and `.bug` trait. This must not be described as corrected by test cleanup.
The test makes no disk save; the observed fault is in the destination draft.

## Validation

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

## Remaining review work

The first-pass reports identify candidates, not permission to delete whole suites:

1. Replace the ordinary composer attachment acknowledgement test's hand-written cleanup with
   the real submit path, delayed acceptance, later attachment, and refusal outcomes.
2. Make iOS simulator readiness timeouts fail rather than print READY after a missed condition.
3. Strengthen design sandbox Google Fonts allowlists and independently inspect exported PDF
   content/order, not only page count or expectations computed by the same paginator.
4. Check remote design downloads with independently known digests and corrupt/stale chunks.
   Investigate ignored inline-cache-store failure before deciding its intended contract.
5. Isolate inherited Git configuration/environment at test-process startup; extend repository
   preservation observations to metadata bytes, symlinks, and executable modes.
6. Replace launcher shell-fragment checks only after independent executed pin/refusal inputs
   cover the same contract. Keep shipping identity and workflow configuration checks where
   configuration itself is the contract.
7. Add positive rendering controls to upper-only budgets without changing ceilings. Correct
   divider endpoint expectations and nonempty input rejection fixtures.
8. Consolidate shared duration tests and redundant vendored-resource marker checks while keeping
   independent checksums, interoperability fixtures, and actual runtime execution.
9. Review remaining bodies in lifecycle, design storage, worktree/commit, remote transport,
   settings/sync, preview, and extension suites. The inventory is broader than the deep review.

Keep the scope explicit as each batch lands. A passing suite with known issues is not proof that
all product bugs or all test-quality defects have been resolved.
