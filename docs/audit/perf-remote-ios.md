> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a GPT-6 Astra agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# Remote protocol and iOS audit

Static, read-only audit of `Sources/ShepherdRemote`, `Sources/ShepherdProtocol`, and `App/iOS`; also read `AGENTS.md`, `docs/remote-protocol.md`, and `docs/ios/README.md`. No builds, tests, app launches, repository writes, or user-data access. One shared UI component was inspected to verify whether its caller's list is lazy. Findings are ranked by expected user impact, not measured timings. Host-side broadcast production is outside this lane: wire frequency is not claimed as measured.

## Findings

### RI-01 — Unbounded inbound push backlog and unlimited main-thread delivery batches
**Severity: high**

**Evidence:** `Sources/ShepherdRemote/RemoteHostClient.swift:99-110,1192-1201,1224-1252`. `pendingEvents` has no byte/count budget. Consecutive output is appended into one `Data`; state pushes append full states. `scheduleDelivery` hands the entire accumulated backlog to main and invokes every callback in one loop.

**User experience:** A fast terminal or busy host can make the phone stop responding, consume substantial memory, and display increasingly stale updates while UI work falls behind.

**Why:** One outstanding dispatch closure bounds closure count, not retained bytes or main-thread processing time. Output merging can produce a huge single SwiftTerm feed; alternating sessions evade merging. Reading continues while delivery is blocked.

**Smallest fix:** Account queued event bytes, suspend socket reads at a high watermark and resume below a low watermark; limit each main delivery by byte/event budget. Coalesce superseded state events where ordering allows, without dropping terminal bytes or exit ordering.

### RI-02 — Visited thread stores and their histories survive indefinitely
**Severity: high**

**Evidence:** `App/iOS/Thread/ThreadStores.swift:13-32,35-42`; `Sources/ShepherdRemote/NativeThreadStore.swift:1167-1183`; `Sources/ShepherdRemote/NativeThreadImages.swift:34-35,63-69,151-159`. Every visited agent gets a retained store; removal exists only for forgetting an entire host. Older pages prepend without a retained-history cap. Each store may additionally retain 24 MiB of image bytes after cancellation.

**User experience:** Browsing many conversations or paging far back progressively increases memory; a long-lived phone/iPad session risks jetsam. Deleted threads remain retained too.

**Why:** Per-thread bounded caches do not bound aggregate app memory, and transcript pages have no eviction at all.

**Smallest fix:** Prune deleted agents, then evict history/presentation/image data from least-recently-used nonvisible stores under an app-wide budget. Preserve drafts and scroll anchors separately; do not evict active viewers.

### RI-03 — Disconnect blocks the main actor behind socket decoding
**Severity: high**

**Evidence:** `App/iOS/Hosts/MobileHosts.swift:71-72,242-251`; `Sources/ShepherdRemote/RemoteHostClient.swift:1046-1048,1141-1168`. Main-actor disconnect calls `queue.sync`; the same queue reads and decodes frames until the socket reaches EAGAIN.

**User experience:** Backgrounding, Retry, Forget, or disconnecting a busy host can stall the interface. Multiple hosts compound the pause.

**Why:** Main must wait for all current serial transport work. A continuously readable stream can greatly extend a read handler's turn.

**Smallest fix:** Enqueue teardown asynchronously, relying on the existing attempt-generation guards to ignore old callbacks. Bound work per read-handler turn so teardown and timers cannot starve.

### RI-04 — Full workspace snapshots on the wire, no delta representation
**Severity: medium**

**Evidence:** `Sources/ShepherdProtocol/RemoteMessage.swift:951,1105-1106,1266-1268`; `Sources/ShepherdRemote/RemoteHostClient.swift:45-46,1192-1193`; `App/iOS/Hosts/MobileHosts.swift:61-63,284-290`. `stateChanged` contains an entire `ShepherdState`, decoded for every push and deep-compared/adopted on main.

**User experience:** Large fleets use more bandwidth and CPU for small changes, especially over VPN/cellular. Frequent pushes invalidate fleet consumers even when only one agent changed.

**Why:** Cost scales with total workspace size rather than mutation size. This is a wire-shape finding; actual host push/coalescing rate needs measurement.

**Smallest fix:** First coalesce superseded queued state pushes and measure their size/rate. If still material, add a capability-gated revision/delta message while retaining snapshots for initial sync and recovery.

### RI-05 — Home reads full conversation snapshots to derive small inbox digests
**Severity: medium**

**Evidence:** `App/iOS/Home/HomeFeed.swift:36-40,130-165`; `Sources/ShepherdProtocol/NativeThread.swift:5`; `Sources/ShepherdRemote/NativeThreadStore.swift:426-428`. Home polls every three seconds, asking each hot agent for `.snapshot(afterRevision:)`; changed responses are converted into `FleetDigest`. The visible thread separately polls snapshots as often as every 500 ms.

**User experience:** Watching the iPad sidebar while a conversation runs duplicates transfer/decoding work. Large active fleets consume battery and network for small row labels.

**Why:** An unchanged revision is cheap, but a changed response carries conversation data Home does not need. Home has a separate revision/digest cache from the visible thread store.

**Smallest fix:** Share already-fetched visible-thread snapshots with Home. For other agents, add a bounded digest response rather than downloading message pages solely for inbox derivation.

### RI-06 — Home serial polling lets one slow host delay every other host
**Severity: medium**

**Evidence:** `App/iOS/Home/HomeFeed.swift:125-178`; `Sources/ShepherdRemote/RemoteHostClient.swift:112,1054-1073`. The nested host/agent loops await each request serially; normal request timeout is ten seconds. `derive()` runs after the whole sweep.

**User experience:** Questions and completions on a healthy Mac can remain stale while another Mac is slow. The nominal three-second refresh becomes sum-of-RTTs plus three seconds.

**Why:** The six quiet-read cap limits count, not wall time; hot agents have no per-sweep cap. Intermediate successful digests are not published until the sweep ends.

**Smallest fix:** Run one sequential sweep per host concurrently with a small concurrency bound, and publish changed digests after each host or bounded batch. Preserve the existing single-refresh guard.

### RI-07 — Every changed thread snapshot traverses all retained history on main
**Severity: medium**

**Evidence:** `Sources/ShepherdRemote/NativeThreadStore.swift:477-568,959-987`. Derivation creates ID sets, concatenates messages, groups all turns, derives artifacts/placements, loops all rows, compares presentation keys, and rebuilds prompt strings even when only the live tail changed.

**User experience:** Long conversations become progressively choppier while streaming, particularly after loading older pages.

**Why:** Presentation caching saves much parsing but does not eliminate history-wide scans, allocations, equality checks, and row reconstruction at active polling frequency.

**Smallest fix:** Preserve unchanged completed rows and their metadata, derive only changed/live turns plus affected subagent placements, and move pure expensive derivations off main if incremental reuse is insufficient.

### RI-08 — Turn-to-Changes lookup is quadratic during history derivation
**Severity: medium**

**Evidence:** `Sources/ShepherdRemote/NativeThreadStore.swift:523-554`; `Sources/ShepherdRemote/ChangesPresentation.swift:44-47`. Every assistant row invokes `changesTurn`, which searches `turnChanges.last(where:)` by timestamp.

**User experience:** Threads with many recorded turns and Changes cards have additional streaming/refresh stalls.

**Why:** T displayed assistant turns and C recorded Changes turns incur O(T×C) comparisons on every derivation, independently of cached prose.

**Smallest fix:** Build one timestamp-to-last-ChangesTurn lookup per changed `turnChanges` array and use dictionary lookup in the row loop, retaining current last-match semantics.

### RI-09 — Changed streaming prose is reparsed in full on main
**Severity: medium**

**Evidence:** `Sources/ShepherdRemote/NativeThreadStore.swift:538-548,733-753`; `Sources/ShepherdRemote/NativeMarkdown.swift:92`. Text cache hits require exact text equality; each growth calls `nativeMarkdownParse(text, streaming:)` or `nativeThinkingBlocks(text)` synchronously from the main-actor store.

**User experience:** A long flowing answer or thinking block can hitch input and scrolling even when old turns are cached.

**Why:** The growing block is reprocessed from the beginning each changed poll. Repeated prefix parsing has cumulative superlinear cost across a long stream.

**Smallest fix:** Parse changed text off main and publish only if its generation/text still matches. If profiling warrants it, retain completed blocks and reparse only the unfinished trailing block.

### RI-10 — Terminal activity polling is duplicated by thread and terminal views
**Severity: medium**

**Evidence:** `App/iOS/Thread/ThreadScreen.swift:109`; `App/iOS/Terminal/TerminalActivityWatch.swift:25-30`; `App/iOS/Terminal/TerminalScreen.swift:86-89`; `App/iOS/Terminal/MobileTerminals.swift:65-80`. Both surfaces independently invoke the same unshared two-second polling loop.

**User experience:** Opening the terminal beside a thread on iPad doubles activity requests; multiple windows can multiply them further. Battery and host query work increase without fresher information.

**Why:** Unlike native-thread viewers, activity watchers have no per-agent shared loop or holder count.

**Smallest fix:** Share one activity watcher per agent/client session, reference-count visible consumers, and stop it with the last consumer.

### RI-11 — iPad thread switching intentionally remounts the detail tree
**Severity: medium**

**Evidence:** `App/iOS/App/PadShell.swift:138-143`. The selected thread is rendered as `ThreadWithSidePane(ref: ref).id(ref)`. Lines 37-58 and 154-159 also switch between arranged/split and different split-style bodies.

**User experience:** Switching threads recreates views and restarts visibility-bound work instead of a visibility flip. Rotation/style transitions can reconstruct columns and refocus the composer (explicit workaround at lines 61-69).

**Why:** Retaining the backing store is not retaining the view hierarchy; row/layout construction and task startup still recur. This conflicts with the repository's switching-is-a-visibility-flip rule.

**Smallest fix:** Keep a bounded deck of mounted thread hosts for recently visible agents and switch visibility; keep polling/focus gated by actual visibility. Preserve the existing shared data stores rather than creating duplicate stores.

### RI-12 — Home's Working/Done/Pinned sections eagerly construct all rows
**Severity: medium**

**Evidence:** `App/iOS/Home/HomeScreen.swift:85-107`. Each unbounded group is one `SHListCard`. Verified implementation: `Packages/ShepherdUI/Sources/ShepherdUI/Components/Fleet/FleetParts.swift:396-409` uses `VStack` and enumerates every subview.

**User experience:** Large Working/Done/Pinned groups slow opening and updating Home, including rows far offscreen.

**Why:** A lazy outer scroll stack cannot virtualize rows inside an eager card. Needs you and Recents have explicit preview caps; these three groups do not.

**Smallest fix:** Apply the existing preview-plus-See-all pattern to these groups, or render the full group as direct rows of a lazy stack with equivalent section styling.

### RI-13 — Cached terminal UIViews are retained for every visited live session
**Severity: medium**

**Evidence:** `App/iOS/Terminal/MobileTerminals.swift:99-107,135-141,207-208,245-255,314-320`; `App/iOS/Terminal/TerminalScreen.swift:82-84`. Sessions retain SwiftTerm surfaces after detach; release occurs only when pruned/deleted or host forgotten. Pruning is driven by a terminal screen's state observation.

**User experience:** Visiting many still-live terminals accumulates terminal view/buffer memory even though only one tab is displayed. Host-side deletion while no terminal screen is mounted can leave surfaces retained until a later visit.

**Why:** The lifetime cache optimizes revisit latency without a memory ceiling. A one-second attachment grace is not view eviction.

**Smallest fix:** Retain surfaces for active viewers and a small LRU of recently used terminals; release older detached surfaces under memory pressure and reconstruct from the existing host replay on revisit. Move deleted-session pruning to host state adoption.

### RI-14 — Cancelled read requests remain pending and can disconnect an otherwise useful connection
**Severity: medium**

**Evidence:** `Sources/ShepherdRemote/RemoteHostClient.swift:1054-1074`. `request` uses a checked continuation with no task cancellation handler. The timeout always tears down the whole connection if that ID remains pending.

**User experience:** Leaving a screen does not stop its outstanding read. A slow abandoned image/history/query can later disconnect all other screens on that host.

**Why:** View task cancellation does not cancel the transport continuation or its disconnect-on-timeout policy. Upper-level cancellation checks only run after the reply arrives.

**Smallest fix:** Add cancellation handling for read-only requests to remove/resume their waiter promptly and ignore a late reply without disconnecting. Keep mutation outcome/acknowledgement tracking distinct so cancellation cannot imply a mutation did not happen.

### RI-15 — Subagent “Show all” repeatedly rebuilds the growing transcript
**Severity: medium**

**Evidence:** `App/iOS/Subagents/SubagentTranscript.swift:77-95,100-127`. `loadAll` requests pages until the oldest cursor, prepends messages and calls `setMessages` for every page; `setMessages` regroups and traverses the entire accumulated transcript. Copy also calls `loadAll`.

**User experience:** Showing or copying a large child run can take many round trips, consume substantial memory, and repeatedly stall the UI during loading.

**Why:** Retained data grows without a byte/page budget; repeated full regrouping yields quadratic aggregate work in the number of similar-sized pages.

**Smallest fix:** Batch page accumulation and publish derivation once per bounded batch. Page the visible transcript rather than loading everything; for Copy, use a bounded/off-main text accumulation path and disclose oversized transcripts.

### RI-16 — Project image previews create images in SwiftUI rendering
**Severity: medium**

**Evidence:** `App/iOS/Projects/ProjectFilesScreen.swift:79-84,94-108`. Preview state stores raw `Data`, and `previewView` executes `UIImage(data:)` while constructing the view.

**User experience:** Opening an image or unrelated view invalidations can repeat image setup; large images can cause a first-display hitch and unnecessary decoded memory.

**Why:** There is no cached prepared/downsampled image sized to the preview. `UIImage(data:)` may defer bitmap decoding until display, so exact main-thread decode time requires runtime confirmation, but image construction in rendering is definite.

**Smallest fix:** Prepare/downsample once off main when the file arrives, store the prepared preview value, and render it without decoding in `body`.

### RI-17 — Subagent final liveness can stay stale when message text does not change
**Severity: low**

**Evidence:** `App/iOS/Subagents/SubagentTranscript.swift:46-53,100-115`. The loop sets `live = isLive()` and reloads once when the run ends. `setMessages` immediately returns if the fetched messages equal the previous messages, before updating derived `Turn.live`.

**User experience:** The last transcript turn may retain its live styling after a run ends without another message mutation (for example, a stopped run).

**Why:** The derivation guard considers message equality but ignores liveness, even though liveness is an input to the derived rows and presentation cache key.

**Smallest fix:** Track the liveness used by the last derivation and rebuild when either messages or that value changes. Add a check where identical messages transition from live to stopped.

### RI-18 — Partial NDJSON frames repeatedly rescan their entire prefix
**Severity: low**

**Evidence:** `Sources/ShepherdProtocol/Framing.swift:42-59`. Every append starts `buffer.firstIndex(of: LF)` at the beginning; the client receives at most 64 KiB per read (`Sources/ShepherdRemote/RemoteHostClient.swift:1143-1148`).

**User experience:** Large state/image frames arriving in many small network fragments incur extra transport CPU and can delay other requests on that serial queue.

**Why:** For a newline-free partial frame, previously checked bytes are searched again on every append. The 1 MiB cap bounds memory but not repeated prefix scanning; unfavorable fragmentation yields quadratic scan work in fragment count.

**Smallest fix:** Retain a scan offset for the already-inspected prefix, reset/adjust it after consuming a complete frame, and keep the existing strict size validation.

## Already good — preserve these

- Transport JSON decoding already happens on the client queue, not directly in SwiftUI. Outbound queue bytes are capped at 8 MiB (`RemoteHostClient.swift:113,1087-1094`). This is not a claim that all socket queues lack bounds.
- Inbound frame assembly enforces a 1 MiB maximum and clears invalid partial buffers (`Framing.swift:46-60`). Image metadata, dimensions, MIME types and chunk ordering are validated before caching (`NativeThreadImages.swift:164-236`).
- Thread polling uses revisions, unchanged replies, slower idle intervals, and shared visible-thread viewers. Presentation and prose caches already avoid reparsing unchanged historical content. Do not replace these with blanket whole-thread refreshes.
- Home is a shared derived model, not a full fleet derivation in every row body. `SidebarThreads.groups` caches model/state results (`App/iOS/Home/SidebarThreads.swift:49-57`). The iPad sidebar uses a real `LazyVStack` with stable row IDs (`PadSidebar.swift:31-32,81-103`).
- Hosts disconnect in the background; connection setup has a cancellable resolver/socket lifecycle; authentication/protocol refusals do not blindly retry. Exponential retry is capped at 30 seconds (`RemoteHostRecord.swift:112-130`).
- Terminal resize is debounced 120 ms and detach has a one-second remount grace. Surface retention avoids recreating SwiftTerm on every small remount. Preserve those protections while adding an aggregate memory budget.
- Native thread image fetches have per-thread LRU byte bounds, four active slots, shared in-flight fetches, and cancellation. Image-send preparation already runs detached (`RemoteHostClient+Images.swift:10`).
- No evidence warrants calling every `id: \\.self`, GeometryReader, or sleeping holder task a defect. Enum/string IDs and cancellation-wait tasks are not equivalent to unstable identity or battery-draining polling.

## Needs runtime confirmation

1. Measure host state push frequency and encoded size for representative 10/100/1,000-agent workspaces; inspect host-side coalescing separately. Determine whether state snapshots approach the framing cap before designing a delta protocol.
2. Stress terminal output with a busy main thread; record pending event bytes, longest delivery callback, SwiftTerm feed time, and disconnect latency. Verify whether continuous readability starves queued teardown in practice.
3. Measure device RSS after visiting many threads/terminals, paging history, viewing images, then closing/deleting those threads. Include memory-warning handling elsewhere in the product before setting eviction budgets.
4. Profile changed-tail derivation and Markdown parsing with long conversations and many recorded Changes turns; separate parsing from SwiftUI layout cost.
5. Count activity and native snapshot requests with thread + terminal + sidebar visible and the same thread in two iPad windows. Check hidden NavigationStack destinations stop their visibility-bound work.
6. Record body/task mount counts, keyboard focus, scroll retention and attach/replay frequency when switching iPad threads, resizing columns, rotating and entering/exiting the fold arrangement.
7. Measure energy/network under a disconnected VPN and many configured hosts. Backoff has no jitter; synchronized retries may matter at fleet scale, but that alone is not ranked as a demonstrated defect here.
8. Validate first-image display on device with large but allowed project images; quantify actual decode thread, allocation size and repeated redraw work.
9. Reproduce RI-17 with identical final transcript data and a live-to-stopped transition; inspect whether another parent-driven invalidation happens to mask the stale turn.

## Scope limits

This is a static audit, not an exhaustive line-by-line proof of every iOS feature or a benchmark. No runtime observations are asserted. TLS absence is documented as a trusted-LAN/VPN boundary, not newly reported as a performance regression. Server-side emission scheduling, the widgets extension outside `App/iOS`, and the platform implementation of SwiftTerm require their own lanes/runtime checks.
