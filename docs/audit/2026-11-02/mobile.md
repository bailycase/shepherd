# iPhone and iPad performance

Baseline `f80d01132`. Static mechanisms below are verified in source; frame latency, energy,
thermal throttling and jetsam risk require device measurements. No simulator result establishes
those hardware outcomes. Paths are relative to the repository root.

## IO-01 · P1 · Review revisions and per-agent review stores accumulate

`App/iOS/Review/ReviewStore.swift:14,145,281,296,522` keeps a `diffCache` across revisions.
`resetFiles` resets displayed data but not this historical cache. App-lifetime `ReviewStores`
also retains visited agents' prepared text/row caches. Forgetting a host explicitly clears its
stores/caches (`:17-20,184-196`); ordinary revision changes/navigation do not. One agent reviewing
many large revisions can accumulate data; visiting 10/50 agents multiplies stores.

- Fix: bound historical revision bytes and offscreen review retention; retain user review state
  separately from reloadable heavy data.
- Preserve: comments, drafts, viewed/fold state, revision/options fences, multiwindow viewers and
  rejection of late results after eviction.
- Check: fixed-size diffs over increasing revisions/store counts; cache cost must plateau and
  revisiting must restore comments/state. Measure actual device footprint independently.

## IO-02 · P2 · Streaming tail changes still derive all loaded history on main

`Sources/ShepherdRemote/NativeThreadStore.swift:492-585,1073-1093` and
`NativeThreadPresentation.swift:388` rebuild ID sets, displayed messages, turns and rows,
with whole-collection comparisons. Presentation caches avoid repeated block parsing, not
these traversals. This shared mechanism also affects Mac (UX-01).

- Fix: retain unchanged turn/row prefixes, rebuild the affected suffix, and cache prompt joins
  and markup proposals. First-difference detection and historical metadata must remain correct.
- Preserve: steer boundaries, optimistic aliases, compaction, subagent placement, Changes cards,
  retry identity, comment-answer boundaries, error folding and older-page splices.
- Check: 100/1,000/10,000 loaded messages, tail-only updates; count visits and main-thread time.
  Compare output to the full derivation for adversarial historical changes and neighboring rows.
- Measurement support: the optimized Mac-hosted shared-store fixture measured **0.326 / 2.316 /
  10.811 ms** for tail refresh at 100/1,000/5,000 history messages (three samples each). This
  includes refresh/merge/derive, excludes views/network, and is not an iPhone/iPad timing.
  See [measurements](measurements.md).

## IO-03 · P2 · Cold, replacement and final Markdown parsing remain synchronous

`NativeThreadStore.swift:747-783` only offloads qualifying large streaming appends. Cold misses,
replacements and final prose can parse on main. Opening/paging/revisiting long answers therefore
bypasses the recent streaming improvement.

- Fix: extend the existing bounded detached parser to these cases, retaining a safe prior
  presentation/placeholder until a fenced result is available.
- Preserve: final fence semantics; session/text/token validation; cancellation and released-store
  identity. Released histories must not be repopulated by late tasks.
- Check: cold-load, replace and finalize oversized Markdown; assert off-main work and exact final
  output, then inspect main-thread slices on physical hardware.

## IO-04 · P2 · Home publishes a host only after its whole sequential sweep

`App/iOS/Home/HomeFeed.swift:134-138,146-207` sweeps hosts concurrently, but awaits agents in one
host sequentially and publishes after the sweep. A slow later agent hides an already-fetched
question/completion from that same host. Cadence is work duration plus the configured pause.

- Fix: publish changed digests in small bounded batches within the sweep.
- Preserve: one sweep/host, generation checks, cancellation and preview-only quiet reads.
- Check: an early changed digest followed by a gated response; early Home content must publish
  before the later response is released, and another host must remain independent.

## IO-05 · P2 · Home downloads changed conversation pages to derive small digests

`HomeFeed.swift:159-176,190-197` → `Sources/ShepherdRemote/Fleet.swift:115-151` requests changed
snapshots for nonvisible hot agents, decodes their page content, then derives a small summary.
This is bounded recent-page transfer, not every agent's complete 10,000-message history.

- Fix: use existing host metadata where sufficient. If necessary, add a bounded capability-gated
  digest response with older-host fallback; do not begin with a whole state-delta rewrite.
- Preserve: questions, session identity, completion evidence, subagent liveness and quiet previews.
- Check: identical 1/10/50-agent traces; compare Home output and transferred/decoded bytes.
  Assert no idle pi starts and no duplicate visible-thread fetches.

## IO-06 · P2 · Non-output pushes evade backlog and delivery accounting

`Sources/ShepherdRemote/RemoteHostClient.swift:1347-1409` accounts `.output` bytes, while default
events append without equivalent bounds. Nonterminal mission/design/project traffic can form a
large retained backlog and one large main-thread callback batch. Mission live snapshots are
paced at 500 ms (`Sources/ShepherdApp/MissionController+Remote.swift:99-110`), not eliminated.

- Fix: add event-count and content-cost bounds; coalesce replaceable hints/live snapshots by
  identity where ordering permits.
- Preserve: lossless ordered terminal output/exits, command-like browser-drive events and balanced
  read-source suspension. This does not by itself fix downstream parser backpressure (SF-01).
- Check: extend `RemoteClientBackpressureCheck` with non-output-only floods and blocked delivery;
  require bounded batches/backlog and correct final state.

## IO-07 · P2 · iPad selection remounts the entire detail

`App/iOS/App/PadShell.swift:142` uses `.id(ref)`; switching re-creates the detail and restarts
`ThreadScreen.swift:159-168` / `NativeThreadStore.swift:829-832` tasks despite retained stores.

- Fix: explore a bounded set of recent mounted detail hosts with visibility-based activation.
  Simply removing `.id(ref)` risks reusing another thread's local state.
- Preserve: per-thread drafts/scroll, actual visibility, focus/accessibility, multiple viewers,
  terminal identities and a mounted-view memory budget.
- Check: repeated switches across 10/50 agents; count mounts, fresh requests and terminal replays,
  verify no hidden polling, and measure on a physical iPad.

## IO-08 · P2 · Pinned Home cards are eager

`App/iOS/Home/HomeScreen.swift:108-115` supplies all pinned rows to the eager card in
`Packages/ShepherdUI/Sources/ShepherdUI/Components/Fleet/FleetParts.swift:396-409`.
Working/Done preview caps do not cover pins.

- Fix: a genuinely lazy pinned section, or an explicitly approved bounded preview/See-all design.
- Preserve: order, attention actions, host identity, accessibility and access to every pin.
- Check: 1/10/50 pins at a fixed viewport; realized rows should be viewport/preview-bounded.

## Existing improvements to preserve

Six offscreen histories plus visible viewers replace indefinite visited-history retention, though
this remains a count bound rather than a global byte budget. Background disconnect, capped
reconnect backoff, cancellation of read waiters, shared terminal activity holders and grace-period
surface release exist. Host sweeps are concurrent, visible snapshots are shared, previews avoid
waking idle pi, and quiet reads are bounded. Changes lookup uses a dictionary. Large streaming
append parsing is coalesced off main. File previews prepare thumbnails off main and framing scans
only new bytes. Working/Done lists are capped. Show all transcripts still load all pages, merely
batching derivation every four pages. No claim that all output is end-to-end backpressured follows
from the client's 4/1 MiB thresholds.
