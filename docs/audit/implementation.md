# Audit implementation status

This is the disposition of the 2026-10-27 audit, not a claim that every finding is fixed.
The original reports describe the baseline. This branch combines the implementation lanes
and their regression fixes into one PR targeting `nightly`.

## Implemented

- Onboarding checks imported model availability, resolves the default consistently, exposes
  imported instructions, and offers recovery when a model or login cannot start a thread.
- Mac deletion confirms; failure messages name the action; notifications account for covered
  threads. Shared commands, persistent text drafts and accessibility fixes cover common paths.
- The server persists failed outcomes, limits empty-reply retries, moves history projection off
  its queue, bounds selected decodes and tables, coalesces unsent state frames, and caps terminal replay.
- Mac views use narrower observation, cached indexes and presentations, off-main image work,
  and cheaper terminal font enumeration. Restored terminal panes demand a session when shown;
  parking an in-flight start no longer discards its binding.
- Mobile gates send during photo import, persists text drafts, preserves transcript reading
  position, reports more failures, waits for push registration acknowledgement, and supports
  keyboard steering, terminal Rename/Kill, phone comment conversations/Duplicate and iPad PDF export.
- Mobile reads stopped-thread previews without starting pi, bounds push delivery and retained
  histories, cancels abandoned reads, and parses long streaming blocks off main.
- Compatible remote additions expose agent defaults, read-only host inventories, Spaces, and
  revision-fenced per-file revert. Older clients keep their existing behavior.
- Browser screenshots and design exports encode off main; parked browser pages suspend work;
  extensions batch status and console updates. Child search tools survive parent filtering,
  an ordinary thread can ask the user directly, and less-used tools are deferred.

## Integration repairs

- An unchanged workspace snapshot still prunes stray thread stores and restates coordinator
  offline state. Equality gating must not skip reconciliation of state outside the snapshot.
- Subagent rows expose both the default Open accessibility action and the named action menu.
- The design-child test rig clears an inherited deferred-tools flag. Its scripted direct cancel
  call otherwise asks for a tool deliberately absent from the active tool list.

## Decisions and limits

- `native.preview.v1` is advertised by the mobile client only. Previews are read-only, carry no
  usable send generation, and do not wake pi. Opening the thread uses an existing non-snapshot
  request (`subagentTranscript` for the nonexistent run `wake`) to start pi, then replaces the
  preview with pi's snapshot. A dedicated activation request was not added.
- Mobile retains six off-screen histories. Draft text survives eviction; draft images are not
  persisted across app termination. Mac draft text is capped at 64 KB and excludes remote agents.
- Host inventory is read-only and exposes no credential values. MCP administration, subagent
  profile editing and provider sign-in recovery still require the Mac.
- Per-file revert requires the reviewed old revision to be HEAD and the current file to match
  the reviewed new revision. It changes the working tree, not the index.
- Agent deletion uses confirmation, not undo. Thinking-level cycling on Shift-Tab remains per
  the existing design, with an accessibility announcement.
- The exact L22 dead-tab path was not reproduced in the harness. Visible-first activation and
  the independently reproduced in-flight parking bug are covered; this is not evidence that
  every cause of a blank terminal has been eliminated.

## Remaining work

| Findings | Remaining behavior |
| --- | --- |
| SS-01, SS-02 | Send still waits for a working-tree snapshot. History projection moved off queue, but whole-history fetching/rebuilding and on-queue reconciliation remain. |
| SS-06, SS-09, RI-04 | Fewer sizing encodes and coalesced frames do not remove full-state encoding, persistence, transfer or decoding. No delta protocol. |
| SS-08, RI-01 | Replay is capped at 500 lines, not bytes. A slow client can still overflow the host's 2 MiB reply queue and disconnect. Client pause/delivery thresholds count output bytes, not every event, and allow whole-event overshoot. End-to-end slow-reader validation remains needed. |
| SS-10, SS-11 | Terminal parsing/reflow stays on the server queue. Decode concurrency is bounded, but retained raw records, image hashing and projection are not all covered by that bound. |
| SS-12, SS-14, SS-18 | Synchronous recovery checkpoint writes and server-queue `forkpty` remain. Turn-end refresh deduplication was reverted because the second refresh is a safety net. |
| MV-01, MV-10, MV-11, MV-17 | Changed snapshots still fan out without frame pacing; composer-wide draft observation, palette rebuilding, per-row probes and per-thread wheel monitors remain. |
| MV-12, MV-14, UM-26 | Whole-document instruction restyling, the turn-presentation memo's clear-all threshold, and idle timeline refreshes remain. There is no MV-26 finding; the timeline label is UM-26. |
| RI-07, RI-11, RI-13 | Full-history main-actor derivation and iPad detail remounting remain. Deleted terminal-session pruning still depends on a mounted terminal screen rather than host-state adoption. |
| RI-02, RI-12, RI-15 | Six retained histories is a count bound, not a byte/page budget. Pinned rows remain eager; Show all/Copy still accumulates entire child transcripts. |
| FP-02, FP-05, FP-07, FP-16 | Inventories are not administration. MCP recovery, Spaces/profile editing and provider recovery still require the Mac. |
| FP-10, FP-11, FP-18 | Phone Duplicate is implemented, but Tweak, interactive Play and mobile sidebar organization controls remain absent. |
| FP-03, FP-12, FP-13, FP-14, FP-15, FP-17, FP-20 | Agent-browser parity/inspection, design import/delete and structured references, Files attachments, the iPad command inventory and per-host skills scope remain open. |
| SE-07, SE-09, SE-16 | Volatile prompt facts and per-turn socket reads remain; terminal readiness still polls at 10 ms; asset fallback enumeration and `no-store` responses remain. |
| SE-18, SE-21 | Whole-card serialization/new report sockets and inactive-page input IPC remain. |
| L6, L10, L21 | No Command-K search-field accessibility fix or New project sheet fix is established. Font enumeration improved, but the broader Settings memory growth is not closed. |

The larger mechanisms above were not silently replaced by broad refactors. They remain review
items, not accepted scope reductions. The PR stays draft until the remaining work is addressed
or explicitly accepted.

## Validation

Local logs and final preview renders are under `/tmp/shepherd-audit/`; they are not committed.
Tests use scratch isolation, not the installed app's state.

- Final unit/regression selection: 3,839 tests. All 3,835 unit tests and the three repaired
  regression cases passed. The queued-message handoff case failed with two issues and also
  failed on the unchanged `origin/nightly` baseline.
- The earlier full integration selection ran 2,537 tests and failed with 66 issues, including
  two known issues. This was not a clean full-tier run. Focused reruns cleared many failures
  and identified the three repaired regressions above.
- The first focused extraction missed parameterized failures. A separate final run covered
  those cases: seven tests in six suites, with only the two Settings cross-fade assertions
  failing. Both assertions also fail on nightly. Startup, question, ownership and resize
  cases passed that rerun.
- Other focused failures reproduced on nightly: missing-provider startup after onboarding,
  browser opening, remote Browser tabs, imported-session adoption, sidebar motion, hello
  capabilities, worktree-base menu keyboard control, and the subagent tab accessibility count.
  Their presence is not a claim that they are harmless or resolved.
- Final Mac Dev and iOS Simulator app builds succeeded. The full iOS checker passed, including
  host previews, cancellation and backpressure.
- Five final preview tests passed, producing 18 light/dark PNGs. Inspected subagent trays,
  imported instructions, import recovery/completion, deletion confirmation and action errors.
  This is not visual or interaction verification of every changed mobile surface.
- Release/Python validation previously passed 361 tests with one skipped. Final docs guards
  passed all 10 tests.
- All 56 extension test files passed with the pinned Node 24.21.0 and pinned pi package,
  with inherited Shepherd/PI flags removed. The earlier OAuth failure came from system Node 26.5.0's
  unsupported TypeScript transform mode; its 21 cases pass with the pinned runtime.

No post-fix full live Mac/iPhone/iPad audit or optimized performance benchmark was run.
The original live observations remain baseline measurements, not measured improvements
for every change. PR CI targets `master`, not `nightly`; a draft prevents this incomplete
closure from entering the ready-PR auto-merge path.
