> Lane report from the 2026-10-27 audit. Static reading only (no build, no run) by a Claude (fable-5-1) agent; line numbers are from commit d28f3511c. Live confirmation of overlapping items is in [live-usage-mac-ios.md](live-usage-mac-ios.md); the cross-lane ranking is in [README.md](README.md).

# Mac app views and view model — performance audit (lane MV)

Scope: `Sources/ShepherdApp` (views, `ShepherdViewModel*`, `Thread/`, `AppLayout*`, `AgentLayoutDeck`, sidebar, palette, Changes/Diff, Files, Settings, Projects, Designs, Browser) and `Packages/ShepherdUI`. Static reading only; no build, no run. Line numbers are from the checkout at audit time.

Overall: this is one of the more performance-literate SwiftUI codebases I have read. The rules in `docs/rules.md` (Observation only, lazy stacks with one view per element, Equatable row values, the `AgentLayoutDeck` hosting-view-per-layout) are followed almost everywhere, and `ListPerformanceTests` / `ThreadStreamingTests` / `ComposerMenu*Tests` budget the hot paths. The real findings cluster around (1) the whole-state `adopt` fan-out from the server, (2) a handful of O(n) or O(n²) derivations that run per render instead of per change, and (3) the newer Projects surfaces, which have not yet had the "derive once, draw values" treatment.

---

## Findings (ranked by user impact)

### MV-01 · high · Every server broadcast replaces the whole `vm.state`, uncoalesced

**Evidence**
- `Sources/ShepherdApp/ShepherdViewModel.swift:1168-1178` — `adopt(_:)` does `state = serverState` unconditionally, then runs `checkMissingSpaces()`, `reconcileSidebarCompletions()`, `threadStores.prune`, `browsers.prune`, `notifyLocalQuestions()`, `checkouts?.sync`, `pruneReviewSessions()`, `pruneDesigns()`, `pruneFileTrees()`, `pruneSidebarPins()`, `planMounting()`, `syncFocus()`.
- `Sources/ShepherdSessions/SessionServer.swift:4764-4769` — `setAgentStatus` hops **both** `onAgentStatus` and `onStateChanged(committedState)` to main. `applyAgentStatus` (`ShepherdViewModel.swift:1252-1256`) carefully gates `state.agents[index].status` with `if old != status`, and the comment says "A repeated report must not invalidate every view that reads the workspace" — but the next callback in the same hop overwrites `state` wholesale anyway.
- `SessionServer.swift:5469-5474` — `setAgentCheckout` also broadcasts the full state; `ShepherdViewModel.swift:~718-722` asks `checkouts?.refresh(agentID, after: .seconds(1))` after every file-touching tool call, so a working agent produces roughly one whole-state adopt per second on top of status changes.
- Readers of `vm.state` that re-run on every write: `WorkspaceView.body` (builds two dictionaries over all agents/designs + an `AgentLayoutModel` per mounted tab, `WorkspaceView.swift:33-40,178-186`), `SidebarView` (via `sidebarSource`, see MV-02), `MenuStateSync` (`AppCommands.swift:69-78`, builds `sidebarShortcutRows` → `sidebarLists`), `WorkspaceHeaderView` (`RootView.swift:300-365`), `AppDialogs`, `NewThreadPage`, `CommandPaletteView` while open (MV-11).

**User experience** With N working agents you get N+ main-thread passes per second, each walking agents/tabs/spaces several times. Each pass is small, but they stack (sidebar derivation, workspace resolver, menu snapshot, Spaces stat sweep) and they all happen on the main thread while the visible thread is also streaming. On a 50–200 agent fleet this is the background hum that makes streaming feel less smooth than it should.

**Why** Observation is property-granular: assigning `state` invalidates every view that read any part of it, equal value or not. Nothing coalesces several broadcasts delivered in one run-loop turn.

**Smallest fix**
1. In `adopt`: `guard state != serverState || !didAdopt else { return }`-style gate (one `ShepherdState ==` is far cheaper than the fan-out); keep the few side-effects that must run on identical state (none appear to).
2. Pace `onStateChanged` the way `onThreadRevision` already is (`docs/rules.md` › Server concurrency: "once per display frame"): keep the latest snapshot and deliver once per frame.
3. Longer term: split `state` into separately observed slices (`agents`, `tabs`, `spaces`, `designs`, `projects`) so a status change does not invalidate layout/space readers.

---

### MV-02 · medium · Sidebar derivation cache is keyed on whole `ShepherdState` copies (layouts, checkouts and all)

**Evidence**
- `Sources/ShepherdApp/ShepherdViewModel+Navigation.swift:69-91` — `sidebarSource` builds a `SidebarSource` containing `presentationState(state, …)` (a copied, mutated `ShepherdState`) **plus one more per remote host**, then `sidebarLists` compares `cached.source == source`.
- `SidebarModel.swift:162-172` — `presentationState` copies the full state and rewrites `agents[i].status` (triggering a COW copy of the agents array whenever any child is live).
- `SidebarCompletions.swift:64-67` — `reconcileSidebarCompletions()` builds `sidebarSource` **again** on every adopt; the sidebar body builds it a third time.
- The source embeds `Agent.checkout` and `Tab.layout`, so a changed-files count (MV-01) or a pane divider drag (`sessions.onTabLayoutChanged` → `state.tabs[index].layout`, `ShepherdViewModel.swift:796-800`) invalidates the cache and re-runs `SidebarDerivation.lists` even though no row shows those fields.

**User experience** Sidebar rows are rebuilt (then Equatable-filtered) for things the sidebar does not display. Cost is O(agents + hosts×agents) per broadcast, 2–3×.

**Smallest fix** Project only the fields the derivation reads into `SidebarSource` (id, name, status, spaceID, designID, lastActiveAt, worktree flags, automation, waitingOn) instead of the whole `ShepherdState`; build it once per adopt and store it, letting `reconcileSidebarCompletions` and `sidebarLists` share it.

---

### MV-03 · medium · `mountedTabs` / `terminalTabs` / `isProjectWorker` are quadratic and run per render

**Evidence**
- `Sources/ShepherdApp/WorkspaceSelection.swift:97-107` — `mountedTabs` runs `state.agents.filter { isProjectCoordinator || isProjectWorker($0.id) }` then, per tab, `state.agents.contains { … }`.
- `Sources/ShepherdCore/ProjectRuntime.swift:193-197` — `isProjectWorker(id)` scans `projects × tasks`, `projectExecutions`, then `agents` again — per call.
- `WorkspaceSelection.swift:86-90` — `terminalTabs(in:)` is tabs × leaves × `primaryAgent(…, agents: state.agents)` (another linear scan).
- Called from `WorkspaceView.body` (`vm.mountedTabs`, `vm.activeTabID` → a fresh `WorkspaceSelection` each: `ShepherdViewModel+Workspace.swift:13-24,113-118`), from `noteActiveTabForParking` (`+Workspace.swift:69-79`) and `syncParkSweepTimer`/`sweepColdPanes` (`:82-104`, every 5 s while any terminal layout is hidden).
- `SidebarProjectsModel.swift:385,440` and `SidebarModel.swift:216,241` call `isSidebarThread`/`isProjectWorker` per agent inside derivations (cached by MV-02's key, so only on source change).

**User experience** With A agents, T tabs and P project tasks every `WorkspaceView` evaluation costs ≈ A×(P+A) + T×A. At 200 agents that is tens of thousands of comparisons per broadcast (MV-01), on the main thread.

**Smallest fix** Add `ShepherdState.projectWorkerIDs: Set<AgentID>` (and an `agentsByID` index) computed once per state; make `isProjectWorker` a set lookup. Cache `WorkspaceSelection` on the view model keyed on `(state, selection, parked, pending)` like `sidebarListsCache`.

---

### MV-04 · medium · `ThreadImageOpener` gets a new `UUID` every thread render → every on-screen image view re-renders per streamed chunk

**Evidence**
- `Sources/ShepherdApp/Thread/ThreadView.swift:329-338` — `.transformEnvironment(\.viewImages) { opener = ThreadImageOpener { … } }` inside `body`.
- `Sources/ShepherdApp/Thread/ThreadImageViews.swift:20-26` — `struct ThreadImageOpener: Equatable { let id = UUID() … == by id }`.
- Readers: `SentImages` (`:133`) and `ReceivedImages` (`:154`) via `@Environment(\.viewImages)`; `ThreadImageThumb` (`:95-125`) is then re-initialised with a new `open` closure.

**User experience** A thread with pictures on screen re-evaluates every image row (and rebuilds `Image(nsImage:)`) on every streamed chunk and every scroll-driven `ThreadView` render. Not catastrophic (lazy, `@State` keeps the decoded image) but it defeats the carefully Equatable rows around it.

**Smallest fix** Hold the opener in `@State` (or on `ThreadInput`, which is already per-agent) and update its captured `present/images` via a small `@Observable` box; or make `==` compare `store === store` and `images === images` instead of a fresh UUID.

---

### MV-05 · medium · `ThreadView.body` does O(rows) work on every render (every streamed chunk)

**Evidence** (`Sources/ShepherdApp/Thread/ThreadView.swift`)
- `:400` `tailGuard.rowIDs = Set(store.rows.map(\.id))` in `keepTail`, called from `body` (`:125`) on **every** render.
- `:120` `arrivals.update(rows.map(\.id), …)` — allocates an ID array per render; inside, `ids.lastIndex(of:)` (`:447`).
- `:113` `rows.last(where: \.live)` — linear from the end when nothing is live (every idle render).
- `:235` `.onChange(of: rows.last)` — SwiftUI compares the whole `NativeThreadRow` (its `turn.messages` with tool outputs and its parsed `presentation`) each render; for a long live turn that is a deep string compare per chunk.
- `:105-106` project threads additionally `store.rows.filter { … }` per render.

**User experience** For a 1–2k-row thread streaming at 20–30 chunks/s this is tens of thousands of String hashes per second plus a deep struct compare, all on the main thread alongside layout. It is the kind of hidden constant that shows up as dropped frames only on long threads.

**Smallest fix** Have the store publish `rowIDs: [String]` / `rowIDSet` once per change (it already derives rows once per change), pass those to `arrivals` and `tailGuard`; key `.onChange` on `store.threadVersion` (already exists, `:118`) or `rows.last?.id` + `store.threadVersion` rather than the row value; track `liveRowID` in the store.

---

### MV-06 · medium · Project "Threads" pane: non-lazy list, filtering in body, reads every worker store in body

**Evidence**
- `Sources/ShepherdApp/LogicalProjectPane.swift:139-176` — `threads` computes `presentation.visibleRows(query:groups:)` in `body`, then `ForEach(ProjectTaskGroup.allCases) { groupView(group, rows: shown.filter { $0.group == group }) }` (4 extra passes), inside a plain `VStack`. Rows (`SHLeadThreadRow`) are not Equatable and take a closure.
- `:163-166` — per working row the body calls `vm.workerActivity(row.workerAgentID, home:)` and `vm.workerStarted(…)`.
- `Sources/ShepherdApp/ShepherdViewModel+LogicalProjects.swift:235-255` — those read `projectWorkerStore(home, agent).rows.last { … }` — i.e. the pane observes **every worker's `rows`**, so each streamed chunk of any worker re-renders the whole pane; `.rows.last { … }` is itself O(rows) per row per render. `projectWorkerStore` also *creates* a `NativeThreadStore` for any worker the pane lists (`threadStores.store(for:)`) as a side-effect of rendering.
- `LogicalProjectPaneState.swift:31-39` — `visibleRows` lowercases three strings per row per word per render.
- `LogicalProjectPane.swift:178-184` — `age()` bakes `Date()` into the row text; it goes stale until something else re-renders (no `SHElapsedText`).

**User experience** A Project with several working threads redraws its entire task list dozens of times a second, with O(tasks × rows) work per redraw. Visible as a warm CPU and a sluggish pane while workers stream.

**Smallest fix** Move `visibleRows`, grouping and the per-worker "activity"/"started" strings into a derived `ProjectPaneRows` value the view model recomputes on worker `threadVersion` changes (and keeps in `@ObservationIgnored` cache like `automationsPageCache`); make the row value Equatable and the list a `LazyVStack`; use `SHElapsedText` for ages. Do not create stores from `body`.

---

### MV-07 · medium · Project page rebuilds `ProjectPagePresentation` (and AnyView cards) on every render

**Evidence**
- `Sources/ShepherdApp/LogicalProjectPage.swift:18-20` — `let presentation = ProjectPagePresentation(project)` in `body`, passed to the toolbar, conversation and pane; the page body depends on `vm.selectedLogicalProject`, `vm.logicalProjects`, `vm.logicalProjectPane*` (five ephemeral toggles) so each toggle rebuilds it.
- `Sources/ShepherdApp/ShepherdViewModel+LogicalProjects.swift:138-148` — `sidebarLogicalProjects` builds a `ProjectPagePresentation` per Project on every **sidebar** body; `ShepherdViewModel+SidebarProjects.swift:55` builds another for the selected one.
- `Sources/ShepherdApp/LogicalProjectConversation.swift:139-140,160-162` and `Thread/ProjectComposerSend.swift:22-24,164` — `AnyView` for task/proposal cards and the empty state/dock (type-erased, so SwiftUI cannot diff structurally).

**User experience** Projects pages feel heavier than threads: every toggle in the pane header and every sidebar redraw re-derives task groups/counters.

**Smallest fix** Cache `ProjectPagePresentation` per `(ref, project.revision)` on the view model (`projectPresentationCache`), read it from the sidebar and page; replace the `AnyView` closures with a small enum view (`ProjectCardView`) or a generic parameter.

---

### MV-08 · medium · Files tab walks and filters the whole tree in `body`, twice

**Evidence**
- `Sources/ShepherdApp/FilesTab.swift:803-806` — `let visible = model.visibleNodes()` inside `LazyVStack` builder; `:888-893` `footerText` calls `model.visibleNodes()` **again** and filters it twice more.
- `FileTreeModel.swift:360-379` — recursive walk with `node.name.lowercased().contains(filter)` per node.
- `FilesTab.swift:828-842` — `FileTreeRow` is not Equatable, takes `isSelected: model.selectedPath == item.node.id` and a fresh closure, so selecting a file rebuilds every realized row.

**User experience** Typing in "Filter files" over a few expanded folders of a large repo (`maxDirectoryEntries` per dir, but many dirs) does two full walks and ~3 lowercases per node per keystroke; selection taps re-render every visible row.

**Smallest fix** Keep `visible: [(FileNode, Int)]` and `visibleCounts` on `FileTreeModel`, recomputed in the places that already mutate `root`/`filter` (`toggle`, `refresh`, `filter.didSet`); lowercase names once at load; make `FileTreeRow: Equatable` and give it `selected: Bool` + a stable action.

---

### MV-09 · medium · Dropped/pasted images are read and decoded on the main actor, twice

**Evidence**
- `Sources/ShepherdApp/Thread/ComposerAttachments.swift:208-216` — `ImageAttachment(url:)` does `Data(contentsOf:)`, `NSBitmapImageRep(data:)` for the guard, `NSBitmapImageRep(data:)` again for pixels, and `NSImage(data:)` for the thumbnail.
- Called from `ThreadInput.add(urls:…)` (`:125-134`) which is `@MainActor`, after `AppImageDrop.resolve` (`:105-108`) returns. Same path from `NewThreadModel.swift:250`.
- Similar: `Thread/QueueStack.swift:242` decodes `NSImage(data:)` for queued thumbnails inside `derive()` on main; `LogicalProjectPaneTabs.swift:108` decodes `NSImage(data:)` in `body`.

**User experience** Dropping a few screenshots freezes the composer for the decode time (2000 px × 2 decodes each). Visible hitch on an otherwise snappy composer.

**Smallest fix** Build `ImageAttachment`s in `Task.detached` (they are value types; `NativeImage` is `Sendable`), then `attachments.add` on main; decode once (`CGImageSourceCreateThumbnailAtIndex` as `ImageViewerHost.swift:82-85` already does) and keep the pixel size from the same source.

---

### MV-10 · medium-low · The whole `Composer.body` re-evaluates on every keystroke

**Evidence**
- `Sources/ShepherdApp/Thread/Composer.swift:240-258` — `commands` (filters `store.commands` by `AppSettings.shared.skillsInSlashMenu`), `loginQuery`, `commandQuery` all read `store.draft`; `openMenu`, `mentionShown`, `menuOpen`, `accessories` read them again.
- `:317-321` — `body` starts with `let query = commandQuery` and `slash.update(query:commands:)`, so the 1,700-line composer (banners, dock, queue stack, question dock, three overlays, eight `shAnimation` keys) is rebuilt per character. `ComposerMenuBenchmarkTests` budget this, so the cost is known, but the structure makes it scale with every new accessory added.

**User experience** Typing is currently fine on a normal thread; the risk is cumulative — each new banner/dock adds to per-keystroke cost.

**Smallest fix** Move the draft-derived state (`commandQuery`, `loginQuery`, `commandMatches`) into the existing `slash` model updated from `.onChange(of: store.draft)`, and read it from a small child (`ComposerMenus`) so only that child depends on `store.draft`.

---

### MV-11 · medium-low · Command palette items are rebuilt from scratch on every view-model change while open, with O(n²) lookups

**Evidence**
- `Sources/ShepherdApp/CommandPaletteView.swift:20` — `items: vm.paletteItems` in `body`.
- `Sources/ShepherdApp/ShepherdViewModel+Palette.swift:13-139` — reads `state`, `statusSince`, `failedTurns`, `childRuns`, `remoteHosts.connections`, `localRecentsOrder` (→ `sidebarLists`), `terminalPanels`, `visibleThread?.store` …; `:117-125` loops `localRecentsOrder` and does `state.agents.first(where:)` per id; `:91-93` same per child-run parent; `ShepherdViewModel.swift:284-288` `remoteChildren` rebuilds a dictionary per read.
- `PaletteCard` then `.onChange(of: items) { refreshResults() }` (`CommandPaletteView.swift:98`) → `PaletteSearch.filter` + `PaletteEntry.entries` again.

**User experience** With the palette open on a busy fleet, every status/checkout broadcast (MV-01) rebuilds and re-ranks the list; typing competes with that.

**Smallest fix** Index `state.agents` by id once per adopt (`agentsByID`, reused by MV-03) and cache `paletteItems` keyed on a small `PaletteInputs` struct, the pattern `automationsPageCache`/`hostsPageCache` already use.

---

### MV-12 · medium-low · Instructions editor restyles the whole document and recompiles a regex per line on every keystroke

**Evidence**
- `Sources/ShepherdApp/InstructionsEditor.swift:87-96` — `textDidChange` → `restyle` on each edit; `:98-118` `setAttributes` over the full storage, then per line `InstructionsText.highlight(line:)` and `try? NSRegularExpression(pattern: "\\*\\*[^*]+\\*\\*")` compiled **inside the per-line loop**; `:119` `InstructionsText.changedLines(saved:draft:)` diffs the full saved vs draft text per keystroke; `:69` `textView.string != text` full compare per `updateNSView`.

**User experience** Typing in a long AGENTS.md (several hundred lines, project mode) lags per keystroke; grows linearly with file length.

**Smallest fix** Hoist the regex to a `static let`; restyle only the edited paragraph range (`editedRange` from `NSTextStorageDelegate`) and debounce `changedLines` (e.g. 150 ms) — the tint of changed lines does not need to be exact mid-keystroke.

---

### MV-13 · low · `checkMissingSpaces()` stats every space folder on every adopt

**Evidence** `Sources/ShepherdApp/ShepherdViewModel+Spaces.swift:106-122`, called from `adopt` at `ShepherdViewModel.swift:1179`. Off-main and coalesced (`running/again`), but it runs a `FileManager` pass for every status/checkout broadcast (MV-01), not just when `state.spaces` changed.

**Fix** Guard with `spaces.map(\.path) != lastCheckedPaths` (and keep the existing on-activate path for folders that come back).

---

### MV-14 · low · Caches that `removeAll` at a threshold thrash during streaming

**Evidence**
- `Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/ProseInline.swift:20-29` — keyed by full paragraph text; every streamed chunk of the live paragraph inserts a new key, so a long reply fills 4,096 entries and the cache then drops **everything** (including finished turns, which get re-styled when scrolled back).
- `Sources/ShepherdApp/Thread/ThreadMarkdown.swift:263-266` — `CodeHighlightCache` same pattern at 256 (each throttled render of a growing fence is a new key).
- `Sources/ShepherdApp/Thread/ThreadTurns.swift:421-427` — `TurnPresentationMemo` at 128.

**Fix** Use `NSCache` (count/cost limits, LRU-ish) or skip caching when `writingFence`/live; cheap and removes the cliff.

---

### MV-15 · low · `AgentTurn.planCallID` recomputed per activity item

**Evidence** `Sources/ShepherdApp/Thread/ThreadTurns.swift:234-240,275` — computed property walks `presentation.items.reversed()` + nested calls; called inside the `ForEach` for each `.activity` item (`:208`, `:259`) → O(items²) per Project-thread turn render.

**Fix** `let planCallID = planCallID` once at the top of `body`.

---

### MV-16 · low · `nativeClockText` allocates `Locale` + `Calendar` per call

**Evidence** `Sources/ShepherdRemote/NativeThreadPresentation.swift:521-528` (owned by another lane, but called from views here): `UserTurn.init(turn:)` calls it per bubble (`Thread/ThreadTurns.swift:63-70`) every time `ThreadView.turn(_:)` builds a realized row, i.e. per render; `AgentTurn.turnFooter` per footer render (`:337`).

**Fix** `static let clockStyle = Date.VerbatimFormatStyle(...)` and `date.formatted(Self.clockStyle)`.

---

### MV-17 · low · Per-row AppKit probes and per-thread event monitors

**Evidence**
- `Sources/ShepherdApp/Thread/ThreadView.swift:143-146` — every thread row hosts an `NSViewRepresentable` (`ThreadTailGuard.RowProbe`) in its background, plus `ThreadRowLayer` adds an `onPreferenceChange` per row (`:707-717`).
- `:507-517` — one `NSEvent.addLocalMonitorForEvents(.scrollWheel)` per mounted `ThreadView` (installed in `onAppear`; hidden deck hosts have appeared too), so every wheel event runs N closures.

**User experience** Realizing a row is heavier than a pure SwiftUI row; dozens of mounted threads each inspect every wheel tick. Both are small today.

**Fix** One app-level wheel monitor that routes to the thread under the pointer; replace `RowProbe` with `onGeometryChange` on the row where macOS 26+ allows it (the guard already uses `onScrollTargetVisibilityChange`).

---

### MV-18 · low · Sidebar rows observe the whole `sidebarActivitySamples` dictionary

**Evidence** `Sources/ShepherdApp/SidebarView.swift:131-137` — `accessory(_:)` reads `vm.sidebarActivitySamples[id]` in `body`; `recordSidebarActivity` writes the dictionary on every tool completion of any agent (`SidebarActivity.swift:109-115`). Observation is per-property, so every realized *working* row re-evaluates on any agent's tool call (the `SHSidebarRow` Equatable gate then drops most).

**Fix** Put the samples into `SidebarListRow.accessory` during derivation (they already flow through `sidebarSource`→cache) or hold a per-agent `@Observable` sample box.

---

### MV-19 · low · `sidebarLogicalProjects` rebuilt per sidebar body

Covered by MV-07; listed separately because it is on the sidebar's hot path (`ShepherdViewModel+LogicalProjects.swift:138-148`, read from `SidebarActivity.swift:78-80` and `ShepherdViewModel+SidebarProjects.swift:49-58`).

---

### MV-20 · low · `ForEach(lines, id: \.title)` for subagent record lines

`Sources/ShepherdApp/Thread/ThreadTurns.swift:289` — identity by title; two identical titles in one turn ("Started 1 subagent" twice) collide and SwiftUI will warn/reuse. Quality, not perf. Use the index or an id from the presentation.

---

## Already good (do not re-fix)

- **Switching is a visibility flip**: `AgentLayoutDeck` (`AgentLayoutDeck.swift`) gives each layout its own `NSHostingView`, flips `isHidden`, never rekeys; `AgentLayoutModel.Resolver` resolves plain Equatable values once per workspace pass; hidden layouts keep a frozen size during live resize; launch mounts two per run-loop turn (`drainPendingMounts`).
- **Thread**: `LazyVStack` with exactly one `ThreadRowLayer` per row; `UserTurn`/`AgentTurn`/`Prose`/`ThinkingRow`/`ActivityLinesView` are `Equatable` with value inputs; rows derived once per change in the store; `MessageHover` per turn so hover never re-renders parts; `ComposerInset` as a reference so composer growth never rebuilds rows; `CatchUpGate`/`ThreadArrivals` as references read in `body`; `.task(id: active)` suspends hidden stores.
- **Streaming code blocks**: tree-sitter runs `Task.detached`, throttled to 250 ms and only complete lines (`CodeHighlightThrottle`), cancellable, cached.
- **Inline markdown** styled once per text (`SHProseInline` cache); fenced code size via `CodeText.Cache` with `NSCache` limits.
- **Sidebar**: one derivation per change (`sidebarListsCache`/`sidebarTreeCache`), lazy list, `SidebarItemView: Equatable`, hover in the row, tap rows without `Button` focus rings; budgets in `ListPerformanceTests`.
- **Palette**: lazy results, `PaletteResults` built once per query/scope, highlight moves without re-filtering, transcript search debounced 250 ms and off-main.
- **Diff review**: `rowCache` per file keyed on layout/reveal/highlight, `DiffFileSection: Equatable`, pinned-header check only flips a Bool, highlights off-main.
- **Pages**: `automationsPageCache`, `hostsPageCache`, `designsPageCache`, `designSystemPageCache` keyed on inputs.
- **Timers**: `childSweepTimer` only while child rows exist; `parkSweepTimer` only while a terminal layout is hidden and unparked; `SHElapsedSchedule` ticks only when the text changes; shimmer/spin/glow are `CALayer` animations, `SHPulse` pauses off-screen and under `shMotionPaused`; diagnostics sampling is budgeted (`DiagnosticsSamplingBudget`).
- **Git**: `CheckoutMonitor` coalesces per agent, max 4 concurrent, `--no-optional-locks`, off-main.
- **ChildRuns**: identical republishes go to `_childRuns` (unobserved storage); menus read a `MenuState` snapshot applied field-by-field.
- **Bounded buffers**: browser console (`maxLines`), diagnostics samples (10), terminal `buffered` only during an attach attempt, `SHProseInline`/highlight caches capped (see MV-14 for the cliff).
- **No `ObservableObject`/`@Published`** anywhere in scope; `AnyView` confined to Project cards and the design-system reference page.
- Sidebar/right-pane width drags write defaults once on release, not per frame.

## Needs runtime confirmation

1. **Broadcast rate**: how many `onStateChanged` deliveries per second reach `adopt` with 10/50 working agents (MV-01). Instrument `adopt` with `SHRenderProbe.tick("vm.adopt")` and read it in `RenderCostReport`.
2. Whether SwiftUI actually re-runs `WorkspaceView.body` on an equal-value `state` assignment under the current Observation runtime (expected yes; MV-01 fix is cheap either way).
3. `SentImages`/`ReceivedImages` re-render count per streamed chunk (MV-04) — add a probe and extend `ThreadStreamingTests` with an image-bearing turn.
4. Project pane re-render rate with two streaming workers (MV-06) — no `ListPerformanceTests` budget exists for `LogicalProjectPane`.
5. Main-thread stall when dropping 3–5 large screenshots (MV-09) — Instruments "Hangs".
6. Whether `onAppear` fires for `ThreadView`s inside hidden deck hosts (MV-17 wheel monitors); and the `ThreadTailGuard` repair-loop frequency on macOS 27 (`thread.tailRepair` probe).
7. `SHProseInline` cache memory during a 500 KB streamed reply (MV-14).
8. `NativeThreadStore` poll/pull cadence and the size of each snapshot it decodes — owned by the ShepherdRemote lane, but it is what drives every finding above in the thread.
9. Design canvases: number of live `WKWebView`s and snapshot memory with 5 live boards + N snapshot boards (`DesignHost.swift`), and `DesignScreenModel.refresh()` cost per `onDesignRevision` while an agent draws.
10. Files tab with a directory at `maxDirectoryEntries` expanded 3–4 levels deep: keystroke latency in the filter field (MV-08).
