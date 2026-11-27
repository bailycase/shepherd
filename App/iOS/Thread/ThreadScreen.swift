import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One agent's thread (MobileThread, iPadThread boards), on iPhone and iPad alike: the title and
/// status line, the turns, and the composer (`ThreadComposer`, Composer/) at the bottom. The
/// thread polls its host only while it is on screen and the app is active.
///
/// Hooks other tracks fill: `SubagentTraySection` (Subagents/) above the composer,
/// `SubagentHooks.list` for the footer's "N subagents" and a turn's subagent lines, `ReviewHooks.open` for the changes card
/// and edit lines, `AgentActionsMenu` (Search/) in the options menu, the windows' hooks
/// (Windows/): Open in new window, a turn's Send to… and drag, and text dropped on the composer,
/// and the terminal (Terminal/): `watchesTerminals` for what its terminals run. The thread's
/// menu (`ThreadOptionsItems`) lists the side pane's tabs: on regular width they open in the
/// pane beside the thread (`ThreadWithSidePane`), on a phone each is pushed. In iPhone Duo's
/// laptop pose the thread is an arrangement, the composer under the fold (`ThreadArrangement`).
struct ThreadScreen: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.threadTitleMaxWidth) private var titleMaxWidth
    /// False while iPad keeps this thread mounted behind the selected one (`PadDetailRoot`).
    @Environment(\.threadDetailActive) private var detailActive
    @State private var visible = false
    /// The thread's height: the composer may take a share of it (`composerMaxHeight`).
    @State private var height: CGFloat = 0
    /// The space's apps, for the header's Run (`ThreadAppsMenu`).
    @State private var apps = ThreadApps()
    /// The threads its links name, on its own host (`ThreadLinksSync`).
    @State private var threadLinks = SHThreadLinks()

    /// The poll loop's identity: another thread in the same view, a new connection, or the
    /// thread leaving the screen restarts it.
    private struct AppsKey: Equatable {
        var session: UUID?
        var space: SpaceID?
    }

    private struct RunKey: Equatable {
        var ref: AgentRef
        var session: UUID?
        var active: Bool
    }

    var body: some View {
        VerticalBars { verticalBars in content(verticalBars: verticalBars) }
    }

    @ViewBuilder private func content(verticalBars: Bool) -> some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let store = threads.store(for: ref)
        let supported = host?.supports(RemoteProtocol.nativeThreadCapability) == true
        let key = RunKey(ref: ref, session: supported && agent != nil ? host?.session : nil, active: visible && detailActive && scenePhase == .active)
        let status = ThreadTitle.Status(store: store, agent: agent)
        // Where the agent works (the branch chip); the host is named once there is more than one.
        let branch = agent.flatMap { AgentBranchLabel(agent: $0, host: hosts.hosts.count > 1 ? host?.name : nil) }
        let transcript = ThreadTranscript(ref: ref, store: store, banner: banner(host: host, agent: agent, store: store, supported: supported))
        let arranged = navigator.sidePane.arranged == ref
        // The laptop arrangement's bar names the thread alone, beside its capsule (DuoLaptop).
        // A thread another thread started names it in its title, a link where a host of this device has it (SubThreadPhone, SubThreadPad).
        let parent: ThreadTitle.Parent? = arranged ? nil : agent?.startedBy.map { started in
            // A thread keeps its id when it moves to another Mac, so the starter is looked up everywhere.
            let found = hosts.hosts.lazy.compactMap { host in host.agent(started.agentID).map { (host.id, $0.name) } }.first
            return ThreadTitle.Parent(name: found?.1 ?? started.agentTitle,
                                      open: found.map { found in { navigator.open(.thread(AgentRef(host: found.0, agent: started.agentID))) } })
        }
        let title = ThreadTitle(name: agent?.name ?? "Thread", status: status, branch: arranged ? nil : branch, parent: parent,
                                wide: sizeClass == .regular && !arranged, goalStore: store)
        // Where the bars run down the side on regular width (iPhone Duo open), the title heads the
        // thread's column, level with the side pane's tabs (DuoOpenThread, DuoOpenSidePane); else
        // it is the bar's.
        let inlineTitle = verticalBars && sizeClass == .regular
        // The pane open beside the thread has sent the sidebar away (iPhone Duo; `PadShell`), and
        // the system's toggle with it: the thread offers it back.
        // The side pane open beside the thread on an iPad: the bar's right side belongs to the pane's card, so the thread's buttons move.
        let besidePane = titleMaxWidth != nil && !verticalBars && sizeClass == .regular && !arranged
        let sidebarHidden = navigator.layout == .pad && navigator.sidePane.isOpen && navigator.padSidebarOverlays
            && navigator.padColumns == .detailOnly && navigator.sidePane.arranged != ref
        Group {
            if arranged {
                // The laptop pose (DuoLaptop): the transcript, or the terminal, above the fold; the composer under it.
                ThreadArrangement {
                    if navigator.sidePane.arrangedTerminal {
                        TerminalScreen(ref: ref, embedded: true)
                    } else {
                        transcript
                    }
                } composer: {
                    if agent != nil { composer }
                }
            } else {
                transcript
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if agent != nil {
                            composer
                                // iPad: as wide as the thread's column, a question's card too (iPadQuestion).
                                .frame(maxWidth: sizeClass == .regular ? MobileLayout.threadMaxWidth + 2 * MobileLayout.padThreadGutter : .infinity)
                                .frame(maxWidth: .infinity)
                                .background(Color.sh.bgWindow)
                        }
                    }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if inlineTitle {
                HStack(spacing: SH.Space.m) {
                    if sidebarHidden { ThreadSidebarButton() }
                    title
                }
                .padding(.horizontal, MobileLayout.padThreadGutter)
                .frame(maxWidth: .infinity, minHeight: SHPadPaneMetrics.duoHeadHeight, alignment: .leading)
                .background(Color.sh.bgWindow)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .background(Color.sh.bgWindow)
        // Thread links in its prose and its @ picker resolve on its own host (ThreadLinkA).
        .environment(\.shThreadLinks, threadLinks)
        .background { ThreadLinksSync(host: ref.host, links: threadLinks) }
        // Measured around the composer's inset, which would otherwise shrink what it measures.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // The side pane's Terminal tab dot and the menu's "1 running".
        .watchesTerminals(ref)
        .turnUndoAlert()
        // A thread takes the whole screen on iPhone (MobileThread board): no tab bar under the composer;
        // where the bars run down the side (iPhone Duo closed) the tab bar stays (DuoClosedThreadMenu).
        .toolbar(verticalBars ? .automatic : .hidden, for: .tabBar)
        .navigationTitle(agent?.name ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: inlineTitle ? .title : nil)
        .toolbar {
            // A thread kept mounted behind the selected one adds nothing to the bar.
            if detailActive {
                if sidebarHidden, !inlineTitle {
                    ToolbarItem(placement: .topBarLeading) { ThreadSidebarButton(inBar: true) }
                }
                if !inlineTitle {
                    ToolbarItem(placement: .principal) {
                        // Beside the side pane, the title keeps to the thread's column (`ThreadWithSidePane`), and the column's own
                        // buttons end its row (iPadReview, iPadThread) instead of sitting at the window's edge above the pane.
                        HStack(spacing: SH.Space.m) {
                            title
                            if besidePane, agent != nil {
                                Spacer(minLength: SH.Space.m)
                                HStack(spacing: SH.Space.xs) {
                                    barButtons(agent: agent, store: store, host: host, key: key, arranged: arranged, verticalBars: verticalBars)
                                    Menu("More", systemImage: "ellipsis") {
                                        ThreadOptionsItems(ref: ref, store: store, branch: branch, enabled: key.session != nil) { navigator.present(.review(.branch(ref))) }
                                    }
                                }
                                .labelStyle(.iconOnly)
                                .tint(Color.sh.textPrimary)
                                .padding(.horizontal, SH.Space.s)
                                .glassEffect(.regular.interactive(), in: Capsule())
                            }
                        }
                        // The bar sizes the title to what it holds, so the column's width is asked for to carry the buttons to its end.
                        .frame(minWidth: besidePane ? titleMaxWidth.map { $0 - 2 * MobileLayout.padThreadGutter } : nil,
                               maxWidth: titleMaxWidth ?? (sizeClass == .regular ? .infinity : nil), alignment: .leading)
                    }
                }
                if !besidePane || inlineTitle {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if agent != nil {
                            barButtons(agent: agent, store: store, host: host, key: key, arranged: arranged, verticalBars: verticalBars)
                        }
                    }
                    // The system's ••• menu, so it overflows with the bar's items where the bar runs
                    // down the side (iPhone Duo).
                    if agent != nil {
                        ToolbarOverflowMenu { ThreadOptionsItems(ref: ref, store: store, branch: branch, enabled: key.session != nil) { navigator.present(.review(.branch(ref))) } }
                    }
                }
            }
        }
        .onAppear {
            visible = true
            SHRenderProbe.tick("thread.appear")
        }
        .onDisappear { visible = false }
        .task(id: AppsKey(session: key.active ? key.session : nil, space: agent?.spaceID)) {
            await apps.watch(key.active && key.session != nil ? host?.connectedClient : nil, space: agent?.spaceID)
        }
        .task(id: key) {
            // Through the thread's viewers: the same thread may be on screen in another window.
            let viewers = threads.viewers(for: ref)
            guard key.active, let session = key.session, let client = host?.connectedClient else {
                viewers.rest(detached: key.session == nil)
                return
            }
            let agentID = ref.agent
            await viewers.run(connection: session) { request in try await client.nativeThread(agentID: agentID, request: request) }
        }
    }

    /// The bar's buttons ahead of the ••• menu: the side pane's, a waiting question's Stop, and the space's apps. In the bar's trailing group,
    /// or at the end of the thread column's title row beside an open side pane.
    @ViewBuilder private func barButtons(agent: Agent?, store: NativeThreadStore, host: MobileHost?, key: RunKey, arranged: Bool,
                                         verticalBars: Bool) -> some View {
        if arranged {
            // What sits above the composer in the laptop pose (DuoLaptop's capsule).
            ThreadArrangedPicker(showsTerminal: navigator.sidePane.arrangedTerminal) {
                navigator.sidePane.arrangedTerminal = $0
            }
        } else if sizeClass == .regular {
            // The side pane's one button, lit while it is open (DuoOpenSidePane).
            ThreadSidePaneButton(isOn: navigator.sidePane.isOpen) {
                withSHAnimation(.pane) { navigator.sidePane.isOpen.toggle() }
            }
        }
        // Where the bars run down the side (iPhone Duo closed) a waiting question has taken the composer's Stop; the rail
        // keeps one (DuoClosedQuestion). A phone's menu has Stop agent.
        if verticalBars, sizeClass != .regular, !store.dialogs.isEmpty {
            Button("Stop agent", systemImage: "stop.fill") { Task { await store.abort() } }
                .tint(Color.sh.textPrimary)
                .disabled(key.session == nil || !store.supports("abort"))
        }
        if !arranged, let quick = apps.apps {
            ThreadAppsMenu(apps: quick, problem: apps.problem) { item in
                Task { await apps.act(on: item, client: host?.connectedClient, space: agent?.spaceID, agent: ref.agent) }
            }
        }
    }

    /// The thread's composer, its height capped at a share of the thread.
    private var composer: some View {
        ThreadComposer(ref: ref)
            .composerTextDrop(ref)
            .environment(\.composerMaxHeight, height > 0 ? height * MobileLayout.composerShare : .infinity)
    }

    /// One short line for the states that matter; the store keeps the full reason.
    private func banner(host: MobileHost?, agent: Agent?, store: NativeThreadStore, supported: Bool) -> String? {
        guard let host else { return "This host was forgotten." }
        // Trying now (a foreground's reconnect, a retry after a drop) is not a failure; between
        // tries, and once a host refuses, it is offline. Same line either way: nothing moves.
        if host.phase == .connecting {
            return agent == nil ? "Connecting to \(host.name)…" : "Reconnecting to \(host.name) · showing the last known thread"
        }
        if !host.phase.isConnected {
            return agent == nil ? "\(host.name) is offline · connect to load this thread" : "\(host.name) is offline · showing the last known thread"
        }
        if agent == nil { return "This agent is no longer on \(host.name)." }
        if !supported { return "Update Shepherd on \(host.name) to open threads here." }
        // A stopped pi's problem is the composer's banner (`StartProblemBanner`), with Retry where the host takes it.
        return store.loadErrorLine
    }
}

extension EnvironmentValues {
    /// Whether this thread is the one shown: false for one iPad keeps mounted behind the selected
    /// thread (`PadDetailRoot`), which polls, watches terminals and presents nothing.
    @Entry var threadDetailActive = true
}

extension Binding where Value == Bool {
    /// Presents only while `active`: a thread kept mounted behind the selected one keeps its
    /// sheet's state but shows nothing until it is shown again.
    func whenActive(_ active: Bool) -> Binding<Bool> {
        Binding(get: { active && wrappedValue }, set: { wrappedValue = $0 })
    }
}

extension Binding {
    /// An item presented only while `active` (see `Binding<Bool>.whenActive`).
    func whenActive<Item>(_ active: Bool) -> Binding<Item?> where Value == Item? {
        Binding<Item?>(get: { active ? wrappedValue : nil }, set: { wrappedValue = $0 })
    }
}

/// The scrolling turns. It reads the store's rows, so a streamed chunk redraws only this and the
/// turn it changed. The context sheet's Largest and Show summary bring an entry into view here.
/// A design's chat (`composerDesignChat`, DesignPad/) shows it in its 360pt pane.
struct ThreadTranscript: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let banner: String?
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.composerDesignChat) private var designChat
    @Environment(\.designMarkupCanvas) private var markupCanvas
    /// A Project's coordinator or worker: its key is no agent's, so no ordinary-thread action is offered.
    @Environment(\.projectTranscript) private var projectTranscript
    /// Follows the tail until the reader drags away from it. The body reads only the parts of it that it draws
    /// (`follows`, `unseen`, `restoresTurn`, `visibleTurn`): the follower itself changes with every scroll frame.
    private var presentation: ComposerPresentation { navigator.composerPresentation.state(for: ref) }
    @State private var historyPaging = NativeHistoryPaging()
    /// Lands the transcript on its tail after layout; only a mount's first few landings run inside it (ThreadTailPin).
    @State private var tailPin = ThreadTailPin()
    /// Gets a following transcript out of a stranded scroll position, where no row is realized (ThreadTailGuard).
    @State private var tailGuard = ThreadTailGuard()
    /// Hands the bottom marker back to SwiftUI once the landings after new rows have settled (ThreadTailHold).
    @State private var tailHold = ThreadTailHold()
    /// Whether this mount has appeared: `onAppear` also fires when a screen pushed over the thread is popped, which is no mount.
    @State private var appeared = false

    private static let bottomID = NativeTranscriptPlace.bottomMarker

    // iOS 27.1's bottom anchor can retain a lazy stack's estimated height after a fold, so there the size-change anchor
    // is left to the explicit following of macOS 27, and the initial anchor and the turn kept stay as they were before
    // a following transcript mounted at its tail (ComposerPresentation.nativeTail).
    private var nativeTail: Bool { ComposerPresentation.nativeTail }

    var body: some View {
        let presentation = presentation
        let rows = store.rows
        let running = store.running
        let thinking = store.showsThinking
        let liveRow = rows.last(where: \.live)
        let tail = rows.last?.id
        ScrollViewReader { proxy in
            // Counted here, where the transcript's own state is read: the body above reads the store only.
            let _ = SHRenderProbe.tick("thread.transcript")
            // iOS 27.1 still draws from every change of the follower (ComposerPresentation.followerChanges).
            let _ = nativeTail ? 0 : presentation.followerChanges
            ScrollView {
                // The notice and the loading line sit above the lazy stack, not in it: a line joining, changing or leaving the top of a
                // lazy stack made it estimate its height again, and a following view was thrown tens of thousands of points from its
                // tail for a few frames (the host dropping and coming back).
                VStack(alignment: .leading, spacing: MobileLayout.turnSpacing) {
                    if let banner {
                        Text(banner).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let host = hosts.host(ref.host), !host.phase.isConnected {
                            // One button in one place through every try and wait, so the turns
                            // under it never shift: off while a try is under way.
                            let connecting = host.phase == .connecting
                            Button(connecting ? "Connecting…" : "Retry connection") { hosts.retry(ref.host) }
                                .buttonStyle(.sh(.secondary))
                                .disabled(connecting)
                        }
                    }
                    // These are transcript notices, independent of host and pane status.
                    if let problem = store.originsProblem {
                        Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let notice = store.clipNotice {
                        Text(notice.text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.snapshot == nil && store.loadError == nil && store.startProblem == nil && store.isLive {
                        SHBusyLabel("Loading…").frame(maxWidth: .infinity)
                    }
                    LazyVStack(alignment: .leading, spacing: MobileLayout.turnSpacing) {
                        ForEach(rows) { row in
                            // One view per row whatever it holds, so the lazy stack builds only the
                            // rows on screen.
                            VStack(spacing: 0) {
                                // Only one thing moves (LiveText): a running call's own line
                                // (MobileApproval), thinking, or the reply as it is written; between
                                // tools the live turn ends in "Thinking…".
                                turn(row, running: running, thinking: row.live && thinking)
                            }
                            .turnTransfer(row, thread: ref)
                            .id(row.id)
                            .background {
                                #if DEBUG
                                TailRowMarker(guardian: tailGuard, rowID: row.id)
                                #else
                                TailRowMarker(guardian: tailGuard)
                                #endif
                            }
                        }
                        if thinking, liveRow == nil { LiveWaitLine(wait: store.liveWait) }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .scrollTargetLayout()
                }
                .background { TailScrollFinder(guardian: tailGuard) }
                .overlay(alignment: .top) {
                    Color.clear.frame(height: MobileLayout.turnSpacing)
                        .onScrollVisibilityChange { visible in
                            historyPaging.visible = visible
                            loadVisibleHistory()
                        }
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: sizeClass == .regular ? MobileLayout.threadMaxWidth : .infinity)
                .padding(.horizontal, sizeClass == .regular && !designChat ? MobileLayout.padThreadGutter : MobileLayout.gutter)
                .padding(.vertical, tailGap)
                // iPad bubbles (iPadThread): at most 520pt, 12×16 inside.
                .environment(\.shUserBubbleMetrics, sizeClass == .regular ? .pad : .standard)
                .frame(maxWidth: .infinity)
                // Which compactions show what the agent kept: its own object, so a toggle
                // redraws only the compaction lines.
                .environment(\.compactionExpansion, store.compactions)
                .environment(\.turnErrorExpansion, store.errors)
            }
            // Open at the tail and stay pinned while it grows; only the reader's own drag
            // detaches, and sending re-attaches.
            .scrollPosition(id: Binding(get: {
                let id = presentation.position(tail: tail)
                tailGuard.noteOfferedPosition(id)
                return id
            }, set: { presentation.noteVisibleTurn($0, tail: tail) }), anchor: .top)
            #if DEBUG
            .onChange(of: banner) { _, _ in
                SHRenderProbe.scrollEvent("thread.write.L13", "thread.banner", from: tailGuard, kind: "layout")
            }
            #endif
            .onChange(of: historyEnabled) { _, _ in loadVisibleHistory() }
            .onChange(of: store.sessionKey) { old, _ in
                tailPin.reset()
                // Another session has other turns, so the one kept is gone; the first key a new store learns is the same thread's.
                if old != nil {
                    SHRenderProbe.scrollEvent("thread.write.I7", "position.newSession", from: tailGuard, kind: "binding")
                    presentation.newSession()
                }
                loadVisibleHistory()
            }
            // A reused view (the design pane's chat has no identity of its own) shows another thread, which mounts as a new transcript does.
            .onChange(of: ref) { _, _ in
                tailPin.reset()
                SHRenderProbe.scrollEvent("thread.write.I7", "position.mountRef", from: tailGuard, kind: "binding")
                presentation.mount()
            }
            .defaultScrollAnchor(nativeTail && SHRenderProbe.scrollAnchorEnabled("I2.initial") ? (presentation.restoresTurn ? .top : .bottom) : nil,
                                 for: .initialOffset)
            .defaultScrollAnchor(nativeTail
                                 ? (presentation.follows && SHRenderProbe.scrollAnchorEnabled("I2.following") ? .bottom : nil)
                                 : (!presentation.follows && SHRenderProbe.scrollAnchorEnabled("I2.detached") ? .top : nil), for: .sizeChanges)
            .onScrollGeometryChange(for: TailReading.self, of: Self.reading) { old, new in
                // Insets and row wrapping can settle separately from scroll offsets. While
                // following, keep the tail above the composer through every change. This runs
                // inside the layout pass, so it records and the pin lands after it; only a
                // mount's first few landings run here, so its first frames are already at the tail.
                #if DEBUG
                if SHRenderProbe.scrollEvents != nil {
                    if old.width != new.width || old.probe.container != new.probe.container {
                        SHRenderProbe.scrollEvent("thread.write.L12", "viewport.resized", from: tailGuard, kind: "layout")
                    }
                    if old.probe.inset != new.probe.inset {
                        SHRenderProbe.scrollEvent("thread.write.L11", "viewport.bottomInset", from: tailGuard, kind: "layout")
                        if tailGuard.traceMotion == "touching" {
                            SHRenderProbe.scrollEvent("thread.write.I8", "bottomInset.whileTouching", from: tailGuard, kind: "layout")
                        }
                    }
                }
                #endif
                let wants = follow { $0.observe(from: old.probe, to: new.probe, gesture: $0.userScrolling, nativeAnchor: nativeTail) }
                tailPin.reading(distance: NativeTailRepin.distance(of: new.probe, belowMarker: tailGap), wants: wants,
                                resized: new.resized(from: old), land: lander(proxy))
                tailGuard.suspect(standAside: { [tailPin] in tailPin.standAside($0) }, status: { [store] in
                    .init(following: presentation.scrollFollower.sticky && !presentation.scrollFollower.userScrolling, hasRows: !store.rows.isEmpty,
                          tailGap: tailGap)
                }, land: { lander(proxy, actor: "thread.write.I4")(true) })
            }
            .onScrollPhaseChange { old, phase, context in
                #if DEBUG
                tailGuard.phase = phase
                #endif
                if phase == .interacting { historyPaging.beginScroll() }
                // Only a finger on the thread is intent; momentum and programmatic scrolls are
                // not, and a drag that ends near the bottom re-sticks where it lands.
                follow { follower in
                    follower.userScrolling = phase == .interacting
                    if phase == .idle, old == .interacting || old == .decelerating {
                        follower.observe(distanceFromBottom: Self.probe(context.geometry).distance, userIntent: true)
                    }
                    return false
                }
                tailPin.reader(scrolling: phase != .idle, touching: phase == .tracking || phase == .interacting)
            }
            .onChange(of: store.sentCount) { _, _ in
                // A send that goes in now re-attaches; a follow-up in Up next leaves the reader where they are. The
                // lander goes with the ask: a screen popped over the thread leaves the pin without one (`stop()`), and the
                // send supplies its own, so it needn't wait for a scroll reading to set it again.
                guard !store.lastSendQueued else { return }
                SHRenderProbe.scrollEvent("thread.write.I6", "send.ask", from: tailGuard, target: Self.bottomID, kind: "request")
                presentation.sent(turnPresent: store.lastSendShownEarly)
                tailPin.asked(lander(proxy))
            }
            .onChange(of: rows.last(where: \.isUser)?.id) { _, id in
                // The echoed turn joins once pi takes it: land on it, unless the reader dragged
                // away meanwhile.
                guard id != nil else { return }
                let session = store.sessionKey
                Task { @MainActor in
                    await Task.yield()
                    guard !Task.isCancelled, store.isLive, store.sessionKey == session,
                          follow({ $0.userTurnArrived() }) else { return }
                    SHRenderProbe.scrollEvent("thread.write.I6", "userTurn.ask", from: tailGuard, target: id, kind: "request")
                    tailPin.asked(lander(proxy))
                }
            }
            // New output at the tail is what "unseen" means, never the content height.
            .onChange(of: rows.last) { _, row in
                SHRenderProbe.scrollEvent("thread.write.L7", "thread.tailChanged", from: tailGuard, target: row?.id, kind: "layout")
                follow { $0.contentArrived(); return false }
                tailPin.outputArrived()
            }
            .onChange(of: navigator.composerPresentation.state(for: ref).findRequest) { _, request in
                guard let request else { return }
                Task { await find(request.entryID, proxy: proxy) }
            }
            // Laid out in the thread's safe area, so it sits on the composer; the margin of its
            // 44pt hit area draws the capsule 8pt above it.
            .overlay(alignment: .bottom) {
                SHJumpToLatest(action: NativeScrollFollower.showsJump(sticky: presentation.follows, unseen: presentation.unseen, running: running) ? {
                    SHRenderProbe.scrollEvent("thread.write.I6", "jumpToLatest.ask", from: tailGuard, target: Self.bottomID, kind: "request")
                    presentation.jumpToLatest()
                    tailPin.asked(lander(proxy))
                } : nil)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                tailHold.resume()
                guard !appeared else { return }
                appeared = true
                SHRenderProbe.scrollEvent("thread.write.I7", "position.mount", from: tailGuard, kind: "binding")
                presentation.mount()
            }
            .onDisappear {
                tailHold.stop()
                tailPin.stop()
                tailGuard.stop()
                SHRenderProbe.scrollEvent("thread.write.I7", "position.leave", from: tailGuard, kind: "binding")
                presentation.leave()
            }
        }
    }

    /// What a landing leaves below the bottom marker: the thread's bottom padding. A view on its
    /// tail reads this far from the end of its content, and that is where the pin treats it as at rest.
    private var tailGap: CGFloat { sizeClass == .regular && !designChat ? MobileLayout.padThreadGutter : MobileLayout.gutter }

    private var historyEnabled: Bool { store.isLive && store.ready && !store.loadingOlder && !presentation.follows }

    private func loadVisibleHistory() {
        guard historyPaging.takeRequest(session: store.sessionKey, cursor: store.olderCursor, enabled: historyEnabled) else { return }
        // ScrollViewReader jumps can leave the native position binding nil at the boundary.
        presentation.pinHistoryTurn(store.rows.first?.id)
        Task {
            #if DEBUG
            let before = SHRenderProbe.scrollEvents != nil ? store.rows.first?.id : nil
            #endif
            await store.loadOlder()
            #if DEBUG
            if let before, store.rows.first?.id != before {
                SHRenderProbe.scrollEvent("thread.write.L6", "history.prepended", from: tailGuard, target: store.rows.first?.id, kind: "layout")
            }
            #endif
        }
    }

    /// Brings the turn holding `entryID` (a tool result, a compaction) to the top of the thread,
    /// loading older pages until it is there (the context sheet's Largest and Show summary).
    private func find(_ entryID: String, proxy: ScrollViewProxy) async {
        func holder() -> NativeThreadRow? { store.rows.first { $0.turn.messages.contains { $0.entryID == entryID } } }
        var pages = 0
        while holder() == nil, store.olderCursor != nil, pages < MobileLayout.findPageLimit {
            await store.loadOlder()
            pages += 1
        }
        guard let row = holder() else { return }
        follow { $0.beginJump(); return false }
        SHRenderProbe.scrollEvent("thread.write.I6", "find", from: tailGuard, target: row.id)
        withSHAnimation(.scroll) { proxy.scrollTo(row.id, anchor: .top) }
    }

    /// Applies a change to the follower, writing it back only when it changed, so a scroll frame
    /// that changes nothing redraws nothing. Returns what the change returned.
    @discardableResult
    private func follow(_ change: (inout NativeScrollFollower) -> Bool) -> Bool {
        let presentation = presentation
        var next = presentation.scrollFollower
        let result = change(&next)
        if next != presentation.scrollFollower { presentation.follow(next) }
        return result
    }

    private static func reading(_ geometry: ScrollGeometry) -> TailReading {
        TailReading(probe: probe(geometry), width: geometry.containerSize.width)
    }

    /// What the pin calls once the layout pass that asked is over. It holds the presentation, not
    /// the view, so a landing asked for before a remount reads the follower it was asked for.
    private func lander(_ proxy: ScrollViewProxy, actor: StaticString = "thread.write.I3") -> ThreadTailPin.Land {
        let presentation = presentation
        let store = store
        let hold = tailHold
        return { [weak tailGuard] resized in
            Self.land(proxy, presentation: presentation, resized: resized, actor: actor, guardRef: tailGuard)
            let tail = store.rows.last?.id
            guard presentation.withholdsMarker(tail: tail) else { return }
            hold.landed {
                if store.rows.last?.id == tail {
                    if !presentation.scrollFollower.userScrolling, presentation.withholdsMarker(tail: tail) {
                        SHRenderProbe.scrollEvent("thread.write.I5", "position.hold", from: tailGuard, target: Self.bottomID)
                    }
                    presentation.hold(tail: tail)
                }
            }
        }
    }

    /// Lands on the tail while the reader still follows it and has not taken hold of the thread.
    private static func land(_ proxy: ScrollViewProxy, presentation: ComposerPresentation, resized: Bool,
                             actor: StaticString, guardRef: ThreadTailGuard?) {
        let follower = presentation.scrollFollower
        guard follower.sticky, !follower.userScrolling else { return }
        SHRenderProbe.tick(resized ? "thread.tailLandingResized" : "thread.tailLanding")
        MobileSignposts.tailLanding()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        SHRenderProbe.scrollEvent(actor, "tail.land", from: guardRef, target: bottomID)
        withTransaction(transaction) { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    private static func probe(_ geometry: ScrollGeometry) -> NativeScrollProbe {
        NativeScrollProbe(content: geometry.contentSize.height, offset: geometry.contentOffset.y,
                          container: geometry.containerSize.height, insetTop: geometry.contentInsets.top,
                          insetBottom: geometry.contentInsets.bottom)
    }

    @ViewBuilder private func turn(_ row: NativeThreadRow, running: Bool, thinking: Bool) -> some View {
        if row.isUser {
            // A design's chat reads Pencil markup as the line the agent read it with (iPadDesign).
            if designChat, let counts = row.designMarkup {
                PadMarkupReadLine(counts: counts).equatable()
            } else {
                UserTurnView(turn: row.turn, host: ref.host).equatable()
            }
        } else if let presentation = row.presentation {
            // The card stands in for its call only where a canvas can apply it (iPadDesign).
            let proposals = designChat && markupCanvas != nil ? row.markupProposals : nil
            AgentTurnView(thread: ref, presentation: presentation, live: row.live,
                          subagents: store.placements[row.id]?.all.count ?? 0,
                          startedAt: row.startedAt, thinking: thinking, wait: thinking ? store.liveWait : NativeLiveWait(),
                          changes: row.changes,
                          changesBusy: row.changes?.turnID.map { TurnUndoStore.shared.busy.contains($0) } ?? false,
                          proposals: proposals,
                          actions: actions(row, running: running)) {
                if let proposals, let markupCanvas {
                    PadMarkupProposalsView(canvas: markupCanvas, proposals: proposals)
                }
            }
            .equatable()
        }
    }

    private func actions(_ row: NativeThreadRow, running: Bool) -> AgentTurnActions {
        let ref = ref
        let navigator = navigator
        var actions = AgentTurnActions()
        guard !projectTranscript else { return actions }
        if store.canRetry(row, running: running) {
            actions.retry = { [store] in Task { await store.retry(row) } }
        }
        actions.review = { path in ReviewHooks.open(thread: ref, file: path, navigator: navigator) }
        actions.reviewChanges = { ReviewHooks.open(thread: ref, file: nil, navigator: navigator) }
        if let turn = row.changes?.turnID {
            let hosts = hosts
            let threads = threads
            actions.review = { path in ReviewHooks.open(thread: ref, turn: turn, file: path, navigator: navigator) }
            actions.reviewTurn = { id in ReviewHooks.open(thread: ref, turn: id, navigator: navigator) }
            actions.undo = { id in TurnUndoStore.shared.undo(id, ref: ref, hosts: hosts, threads: threads) }
            actions.redo = { id in TurnUndoStore.shared.redo(id, ref: ref, hosts: hosts, threads: threads) }
        }
        if store.placements[row.id]?.isEmpty == false {
            actions.subagents = { navigator.open(SubagentHooks.list(thread: ref)) }
        }
        return actions
    }
}

/// The title and its status line (MobileThread, MobileQueue, MobileQuestion, iPadThread, DuoClosedThread boards): the name in 16/600, over
/// the state in words ("Idle", "Needs you" in `lantern`, "Failed" in `failed`), a dot, and the branch in mono. Centered on a phone, the
/// thread's column leading on iPad, where the host follows the branch when there are several.
struct ThreadTitle: View {
    struct Status: Equatable {
        var state: AgentState
        var label: String

        @MainActor init(store: NativeThreadStore, agent: Agent?) {
            if store.loadError != nil { state = .failed; label = "Error" }
            else if store.startProblem != nil { state = .failed; label = "Can't start" }
            else if !store.dialogs.isEmpty { state = .attention; label = AgentState.attention.label }
            else if store.running { state = .running; label = AgentState.running.label }
            else if store.lastTurnFailed { state = .failed; label = AgentState.failed.label }
            else if let agent { state = AgentState(agent.status); label = state.label }
            else { state = .idle; label = AgentState.idle.label }
        }
    }

    /// The thread that started this one: its name, and opening it where this device has it.
    struct Parent {
        var name: String
        var open: (() -> Void)?
    }

    let name: String
    let status: Status
    var branch: AgentBranchLabel?
    var parent: Parent?
    /// iPad: the title leads its column rather than centering.
    var wide = false
    var goalTime: String? = nil
    var goalStore: NativeThreadStore? = nil

    var body: some View {
        VStack(alignment: wide ? .leading : .center, spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.m) {
                // A thread another thread started names it: a link where it opens (a phone has no room, so it sits in the status line).
                if wide, let parent {
                    parentName(parent).font(.sh(.title, weight: .regular)).layoutPriority(-1)
                    Text("/").font(.sh(.title, weight: .regular)).foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                }
                Text(name).font(.sh(.title)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            }
            statusLine
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let parent, let open = parent.open { Button("Open \(parent.name)", action: open) }
        }
    }

    /// The parent's name: a link when it opens.
    @ViewBuilder private func parentName(_ parent: Parent) -> some View {
        let text = Text(parent.name).foregroundStyle(parent.open == nil ? Color.sh.textSecondary : Color.sh.running).lineLimit(1)
        if let open = parent.open {
            Button(action: open) { text }.buttonStyle(.plain)
        } else {
            text
        }
    }

    /// "Running · pi/shepherd-extensions": only the words that ask for you are colored; the dot is the board's, not a status dot.
    private var statusLine: some View {
        let asks = status.state == .attention || status.state == .failed
        return HStack(spacing: SH.Space.xs) {
            Text(status.label)
                .fontWeight(asks ? .medium : .regular)
                .foregroundStyle(asks ? status.state.textColor : Color.sh.textSecondary)
                .fixedSize()
            // The phone's title has no room for a breadcrumb: the parent leads with the sidebar's sub-thread mark instead.
            if !wide, let parent {
                Text("· ↳").foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                parentName(parent).layoutPriority(-1)
            }
            if wide { ThreadGoalHeader(store: goalStore, time: goalTime) }
            if let branch {
                Text("·").foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                Text(branch.branch).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1).truncationMode(.tail)
                if wide, let host = branch.host {
                    Text("· \(host)").foregroundStyle(Color.sh.textTertiary).lineLimit(1).layoutPriority(-1)
                }
            }
        }
        .font(.sh(.caption))
        .lineLimit(1)
    }
}

/// Goal updates invalidate this child, not the screen or the header's other controls.
private struct ThreadGoalHeader: View {
    let store: NativeThreadStore?
    let time: String?

    var body: some View {
        if let store {
            if let goal = store.goal, goal.isActive {
                Text("·").foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                SHGoalHeaderPill(time: goal.timeLabel, clockStart: goal.clockStart)
            }
        } else if let time {
            Text("·").foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
            SHGoalHeaderPill(time: time)
        }
    }
}

extension EnvironmentValues {
    /// The thread's column beside an open side pane, which its title keeps to; nil is the bar's width.
    @Entry var threadTitleMaxWidth: CGFloat? = nil
}

/// Show sidebar, while the open side pane has sent the sidebar away (DuoOpenSidePane): it slides back over the thread.
private struct ThreadSidebarButton: View {
    /// A bar's item, which the bar styles; else a glass circle by the title.
    var inBar = false
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let button = Button("Show sidebar", systemImage: "sidebar.left") { withSHAnimation(.pane) { navigator.padColumns = .all } }
            .tint(Color.sh.textPrimary)
        if inBar {
            button
        } else {
            // The board's 40pt circle (DuoOpenSidePane), not the large control's.
            button.labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                .frame(width: MobileLayout.padHeaderButton, height: MobileLayout.padHeaderButton)
        }
    }
}

/// The header's one side-pane button (DuoOpenThread, DuoOpenSidePane; the Mac's `SHSidePaneButton`): Show side pane opens it on the
/// tab it last showed; while it is open its glyph is lit in `lantern` and it hides it.
private struct ThreadSidePaneButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        let label = isOn ? "Hide side pane" : "Show side pane"
        Button(label, systemImage: "sidebar.right", action: action)
            .tint(isOn ? Color.sh.lantern : Color.sh.textPrimary)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The laptop pose's capsule (DuoLaptop): the transcript or the terminal above the composer.
private struct ThreadArrangedPicker: View {
    let showsTerminal: Bool
    let choose: (Bool) -> Void

    var body: some View {
        Button("Transcript", systemImage: "text.alignleft") { choose(false) }
            .tint(showsTerminal ? nil : Color.sh.lantern)
            .accessibilityAddTraits(showsTerminal ? [] : .isSelected)
        Button("Terminal", systemImage: "apple.terminal") { choose(true) }
            .tint(showsTerminal ? Color.sh.lantern : nil)
            .accessibilityAddTraits(showsTerminal ? .isSelected : [])
    }
}

/// Next thread (n), first in a phone's menu: the bar keeps Back, the title and ••• alone (MobileThread). Not drawn on regular width,
/// where the bar has room for the Next button itself.
private struct NextThreadItem: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let current = navigator.selectedThread.map { FleetRef(host: $0.host, agent: $0.agent) }
        let count = sizeClass == .regular ? 0 : HomeFeed.of(hosts).supervisionQueues.needingYouCount(excluding: current)
        if count > 0 {
            Section {
                Button("Next thread (\(count))", systemImage: SHGlyph.nextThread.symbolName) { navigator.openNextNeedingYou(hosts: hosts) }
            }
        }
    }
}

/// The thread's menu, in the bar's ••• (DuoClosedThreadMenu): the side pane's five tabs with what each says of its work (the
/// totals, "1 running"), then Stop agent and More… (Refresh, Open in new window, the agent actions). On a phone each tab is pushed
/// over the thread; on regular width it opens in the side pane.
private struct ThreadOptionsItems: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let branch: AgentBranchLabel?
    let enabled: Bool
    /// Opens the branch sheet (GitPhoneD's Branch).
    let openBranch: () -> Void
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NextThreadItem()
        if let branch {
            Section {
                Button(action: openBranch) {
                    Label("Branch", systemImage: SHGlyph.gitBranch.symbolName)
                    Text(BranchStatusStore.of(ref).menuDetail(branch: branch.branch))
                }
            }
        }
        Section {
            ForEach(PadSidePaneTab.allCases, id: \.self) { tab in
                Button { navigator.open(.paneScreen(tab, thread: ref)) } label: {
                    Label(tab.title, systemImage: SidePaneTabs.systemImage(tab))
                    if let detail = detail(tab) { Text(detail) }
                }
            }
        }
        Section {
            Button("Stop agent", systemImage: "stop.circle", role: .destructive) { Task { await store.abort() } }
                .disabled(!enabled || !store.running || !store.supports("abort"))
            Menu {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(fresh: true) } }
                    .disabled(!enabled)
                OpenInNewWindowButton(thread: ref)
                AgentActionsMenu(thread: ref)
            } label: {
                Label("More\u{2026}", systemImage: "ellipsis")
            }
        }
    }

    /// "+137 −16", "1 running"; nil when there is nothing to say.
    private func detail(_ tab: PadSidePaneTab) -> String? {
        switch tab {
        case .changes:
            let review = ReviewStores.shared.store(for: ref)
            if review.loaded { return "+\(review.totals.added) \u{2212}\(review.totals.removed)" }
            return branch.flatMap { $0.changedFiles > 0 ? nativeCount($0.changedFiles, "file") + " changed" : nil }
        case .terminal:
            let running = runningTerminals(ref)
            return running > 0 ? "\(running) running" : nil
        case .subagents:
            let running = store.subagents.count { nativeRunPhase($0) == .running }
            return running > 0 ? "\(running) running" : nil
        case .files, .browser:
            return nil
        }
    }
}
