# Mac presentation and observation

Baseline `f80d01132`; static mechanisms, not measured frame times. Agent counts are not loaded
history counts: visit/page histories explicitly when testing retained-memory or rendering costs.

## MC-01 · P2 · Inline Markdown parsing remains on main

`Sources/ShepherdApp/Thread/ThreadMarkdown.swift:40,64` maps prose blocks into
`Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/ProseInline.swift:13,29-43`.
Cache misses invoke `AttributedString(markdown:)` during main-actor presentation. New streaming
prefixes miss even when block parsing ran off main.

- Fix: prepare changed-block inline parses off main with revision fences; preserve the previous
  presentation until ready. Keep theme-dependent work safe under an immutable theme snapshot
  or on main. Preserve links, HTML/Markdown semantics, final flush and text-scale changes.
- Check: 16/64/256 KiB growing paragraphs, tables and code-heavy answers. Separate block parsing,
  inline parsing and native layout in profiles; verify no large inline parse runs on main.

## MC-02 · P2 · Mac retains all visited loaded histories

`Sources/ShepherdApp/NativeThreadStores.swift:10,32,74` removes stores when agents disappear,
not when their histories become inactive. `NativeThreadStore.suspend` retains messages,
presentations and images; Mac does not call its existing `release()` path.

- This is retention policy, not evidence of a leak. Deeply visiting 10/50 threads grows aggregate
  loaded state; merely saving 50 agents does not load all their histories.
- Fix: inactive-history byte/recency budget while keeping stable store/deck identities.
  Preserve drafts, attachments, pending sends, other viewers and reading anchors; do not blindly
  release active readers or remount the native deck.
- Check: page, switch away, measure retained bytes/objects, revisit and verify restoration.

## MC-03 · P2 · Changed workspace snapshots still trigger fleet-wide adoption

`ShepherdViewModel.swift:739,1332-1429`, `WorkspaceView.swift:32-39,177-195` and
`ShepherdViewModel+Palette.swift:13` consume genuinely changed whole-workspace state.
Equality gating avoids identical snapshots, not repeated adoption of a burst of changed ones.
An open palette reconstructs its inventory; reconciliation runs before rendering coalesces.

- Fix: share projections keyed by displayed inputs and pace replaceable presentation state.
  First batch the concrete shared-checkout source described in ST-05.
- Preserve: notification/completion transitions, automation ordering, deletions, stale rejection
  and unchanged-snapshot thread-store reconciliation. Do not simply drop intermediate events.
- Check: changed snapshot bursts for 10/50 agents; count adoptions/derivations versus frames,
  while asserting every required event and the final state.

## MC-04 · P2 · Row-ID indexes rebuild when only streaming text changes

`Thread/ThreadView.swift:125,465-467,636-659` keys `ThreadRowIndex.update` on `threadVersion`.
That version changes for content, causing all row IDs and their set to be rebuilt when membership
and order are unchanged. One live tail therefore drives O(loaded turns) main-actor index work.

- Fix: structural identity revision distinct from content/live revision. Refresh `liveRow`
  separately even when IDs do not change: the current guard updates both (`ThreadView.swift:651-658`),
  and the waiting indicator consumes live-row state (`:174`).
- Preserve: middle replacements/reordering, prepends, filtering and reset; count/first/last are
  insufficient structural fingerprints. Structural caching must not freeze live/finished state.
- Check: extend `ThreadRowIndexTests`; tail text must not advance structural rebuild count,
  while middle replacement, prepend and reset must. Retain the existing live→finished test with
  unchanged IDs (`ThreadRowIndexTests.swift:25-28`). Test many short turns, not just one long one.

## MC-05 · P2 · Some image-preparation paths still run on main

`NewThreadModel.swift:240-245`, `ShepherdViewModel+Designs.swift:462-467`,
`Thread/ComposerAttachments.swift:49,170-183` and `Thread/ThreadImageViews.swift:72-80`
have actor-inheriting tasks that resume into synchronous file/ImageIO work. Ordinary
`ThreadInput.attach` already prepares images in a detached task; sibling paths differ.

- Fix: reuse detached preparation for new-thread/design attachments and transcript thumbnails;
  publish native image state on main. Preserve limits, ordering, errors and cancellation fences.
- Check: four large accepted images through every entry point; verify disk/thumbnail work is
  off main and cancelled or stale results never attach. Test lazy-row remounts too.

## MC-06 · P2 · Instruction editing combines whole-document styling with an LCS diff

`InstructionsEditor.swift:98-130` calls `Sources/ShepherdRemote/InstructionsText.swift:74-108`
on edits. It resets whole-document attributes and can allocate/fill a longest-common-subsequence
matrix. The two-million-line-pair cutoff bounds the quadratic branch but does not make ordinary
1,000-line edits incremental.

- Fix: debounce/revision-fence the pure changed-line diff off main; highlight edited paragraphs,
  reserving full passes for file/theme changes.
- Preserve: UTF-16 ranges, marked IME text, undo and the saved baseline.
- Check: 100/1,000/10,000 lines, including near-cutoff cases; stale diffs must not land and a
  one-line edit must not synchronously perform a full LCS.

## MC-07 · P3 · Project task lists remain eager and consume worker history in construction

`LogicalProjectPane.swift:139-182`, `ShepherdViewModel+LogicalProjects.swift:255-276` and
`LogicalProjectPaneState.swift:31` filter/group/build eager rows and read worker stores.
Store lookup may create a store simply to show activity. Hidden workers are not thereby all polling.

- Fix: one flattened lazy list, row-scoped worker observation, cached query projection and a
  lightweight fallback instead of creating history stores for optional labels.
- Preserve: group folding/order, selection, accessibility and absent-worker behavior.
- Check: 50/1,000 tasks; realized rows should follow viewport size and one worker update should
  not reconstruct every task row.

## MC-08 · P3 · Styled-text caches have entry bounds, not content-cost bounds

`Packages/ShepherdUI/.../Thread/ProseInline.swift:22-34` and
`Sources/ShepherdApp/Thread/ThreadMarkdown.swift:278-289` retain full-text keys and attributed
values for up to 4,096 inline entries/256 fences. Growing prefixes are distinct entries.
NSCache can evict; this is not proof of actual retention to the count limit.

- Fix: cost-aware admission/limits and oversize bypass, following the existing CodeText cache.
- Preserve: eviction changes recomputation only, never content/styling correctness.
- Check: stream large prefixes; inspect cache-accounted bytes and allocations, then verify final
  styling and scroll behavior after eviction.

## Existing improvements to preserve

Stable native deck identities/visibility flips, equality-based image openers, sidebar projections
excluding checkout/layout fields, cached file-tree visible nodes, Equatable file rows, detached
ordinary attachment import and code highlighting, inactive wheel-monitor removal, per-agent
activity boxes and adaptive elapsed labels are present. `SHRenderProbe` compiles out in Release.
Do not repeat October's claims that these mechanisms are absent. Remaining native row probes
support blank-thread recovery; remove them only with correctness evidence, not by counting views.
