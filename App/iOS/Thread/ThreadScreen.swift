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
    @State private var visible = false
    /// The thread's height: the composer may take a share of it (`composerMaxHeight`).
    @State private var height: CGFloat = 0

    /// The poll loop's identity: another thread in the same view, a new connection, or the
    /// thread leaving the screen restarts it.
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
        let key = RunKey(ref: ref, session: supported && agent != nil ? host?.session : nil, active: visible && scenePhase == .active)
        let status = ThreadTitle.Status(store: store, agent: agent)
        // Where the agent works (the branch chip); the host is named once there is more than one.
        let branch = agent.flatMap { AgentBranchLabel(agent: $0, host: hosts.hosts.count > 1 ? host?.name : nil) }
        let transcript = ThreadTranscript(ref: ref, store: store, banner: banner(host: host, agent: agent, store: store, supported: supported))
            .environment(\.openArtifact, store.supports("artifacts") || !store.artifacts.isEmpty ? { [navigator, ref] path in
                ArtifactHooks.open(thread: ref, path: path, navigator: navigator)
            } : nil)
        let arranged = navigator.sidePane.arranged == ref
        // The laptop arrangement's bar names the thread alone, beside its capsule (DuoLaptop).
        let title = ThreadTitle(name: agent?.name ?? "Thread", status: status, branch: arranged ? nil : branch,
                                wide: sizeClass == .regular && !arranged, goalStore: store)
        // Where the bars run down the side on regular width (iPhone Duo open), the title heads the
        // thread's column, level with the side pane's tabs (DuoOpenThread, DuoOpenSidePane); else
        // it is the bar's.
        let inlineTitle = verticalBars && sizeClass == .regular
        // The pane open beside the thread has sent the sidebar away (iPhone Duo; `PadShell`), and
        // the system's toggle with it: the thread offers it back.
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
                .frame(maxWidth: .infinity, minHeight: SHPadPaneMetrics.headHeight, alignment: .leading)
                .background(Color.sh.bgWindow)
                .accessibilityAddTraits(.isHeader)
            }
        }
        .background(Color.sh.bgWindow)
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
            if sidebarHidden, !inlineTitle {
                ToolbarItem(placement: .topBarLeading) { ThreadSidebarButton(inBar: true) }
            }
            if !inlineTitle {
                ToolbarItem(placement: .principal) {
                    // Beside the side pane, the title keeps to the thread's column (`ThreadWithSidePane`).
                    title.frame(maxWidth: titleMaxWidth, alignment: .leading)
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if agent != nil {
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
                    ThreadStopButton(store: store, enabled: key.session != nil)
                }
            }
            // The system's ••• menu, so it overflows with the bar's items where the bar runs
            // down the side (iPhone Duo).
            if agent != nil {
                ToolbarOverflowMenu { ThreadOptionsItems(ref: ref, store: store, branch: branch, enabled: key.session != nil) }
            }
            // New thread sits lowest in the side column and stays longest (DuoOpenThread); a
            // horizontal bar leaves it to the sidebar's row.
            if sizeClass == .regular, verticalBars {
                ToolbarItem(placement: .bottomBar) {
                    Button("New thread", systemImage: "square.and.pencil") { NewThreadHooks.open(navigator: navigator) }
                        .buttonStyle(.glassProminent)
                        .disabled(hosts.hosts.isEmpty)
                }
                .visibilityPriority(.high)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
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

    /// The thread's composer, its height capped at a share of the thread.
    private var composer: some View {
        ThreadComposer(ref: ref)
            .composerTextDrop(ref)
            .environment(\.composerMaxHeight, height > 0 ? height * MobileLayout.composerShare : .infinity)
    }

    /// One short line for the states that matter; the store keeps the full reason.
    private func banner(host: MobileHost?, agent: Agent?, store: NativeThreadStore, supported: Bool) -> String? {
        guard let host else { return "This host was forgotten." }
        if agent == nil { return host.phase.isConnected ? "This agent is no longer on \(host.name)." : nil }
        if !host.phase.isConnected { return "\(host.name) is offline · showing the last known thread" }
        if !supported { return "Update Shepherd on \(host.name) to open threads here." }
        if let error = store.loadError { return error }
        if let problem = store.startProblem { return "\(problem.title) \(problem.advice(host: host.name))" }
        if let notice = store.clipNotice { return notice.text }
        return nil
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
    /// Follows the tail until the reader drags away from it (docs/design/thread.md › Thread › Following).
    private var presentation: ComposerPresentation { navigator.composerPresentation.state(for: ref) }
    private var follower: NativeScrollFollower { presentation.scrollFollower }
    @State private var historyPaging = NativeHistoryPaging()

    private static let bottomID = "thread-bottom"

    // iOS 27.1's bottom anchor can retain a lazy stack's estimated height after a fold.
    // Use the same explicit following as macOS 27.
    private var nativeTail: Bool {
        if #available(iOS 27.1, *) { false } else { true }
    }

    var body: some View {
        @Bindable var presentation = presentation
        let rows = store.rows
        let running = store.running
        let thinking = store.showsThinking
        let liveRow = rows.last(where: \.live)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileLayout.turnSpacing) {
                    if let banner {
                        Text(banner).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.snapshot == nil && store.loadError == nil && store.startProblem == nil && store.isLive {
                        ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
                    }
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
                    }
                    if thinking, liveRow == nil { LiveWaitLine(wait: store.liveWait) }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .scrollTargetLayout()
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
                .padding(.vertical, sizeClass == .regular && !designChat ? MobileLayout.padThreadGutter : MobileLayout.gutter)
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
            .scrollPosition(id: $presentation.visibleTurn, anchor: .top)
            .onChange(of: historyEnabled) { _, _ in loadVisibleHistory() }
            .onChange(of: store.sessionKey) { _, _ in loadVisibleHistory() }
            .defaultScrollAnchor(nativeTail ? (follower.sticky ? .bottom : .top) : nil, for: .initialOffset)
            .defaultScrollAnchor(nativeTail ? (follower.sticky ? .bottom : nil) : (follower.sticky ? nil : .top), for: .sizeChanges)
            .onScrollGeometryChange(for: NativeScrollProbe.self, of: Self.probe) { old, new in
                // Insets and row wrapping can settle separately from scroll offsets.
                // While following, keep the tail above the composer through every change.
                if follow({ $0.observe(from: old, to: new, gesture: $0.userScrolling, nativeAnchor: nativeTail) }) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            .onScrollPhaseChange { old, phase, context in
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
            }
            .onChange(of: store.sentCount) { _, _ in
                // A send that goes in now re-attaches; a follow-up that waits in Up next leaves
                // the reader where they are, now and when it goes.
                guard !store.lastSendQueued else { return }
                follow { $0.sent(queued: false); return false }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
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
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
            // New output at the tail is what "unseen" means, never the content height.
            .onChange(of: rows.last) { _, _ in follow { $0.contentArrived(); return false } }
            .onChange(of: navigator.composerPresentation.state(for: ref).findRequest) { _, request in
                guard let request else { return }
                Task { await find(request.entryID, proxy: proxy) }
            }
            // Laid out in the thread's safe area, so it sits on the composer; the margin of its
            // 44pt hit area draws the capsule 8pt above it.
            .overlay(alignment: .bottom) {
                SHJumpToLatest(action: follower.showsJump(running: running) ? {
                    follow { $0.jumpToLatest(); return false }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } : nil)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var historyEnabled: Bool { store.isLive && store.ready && !store.loadingOlder && !follower.sticky }

    private func loadVisibleHistory() {
        guard historyPaging.takeRequest(session: store.sessionKey, cursor: store.olderCursor, enabled: historyEnabled) else { return }
        // ScrollViewReader jumps can leave the native position binding nil at the boundary.
        if presentation.visibleTurn == nil { presentation.visibleTurn = store.rows.first?.id }
        Task { await store.loadOlder() }
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
        withSHAnimation(.scroll) { proxy.scrollTo(row.id, anchor: .top) }
    }

    /// Applies a change to the follower, writing it back only when it changed, so a scroll frame
    /// that changes nothing redraws nothing. Returns what the change returned.
    @discardableResult
    private func follow(_ change: (inout NativeScrollFollower) -> Bool) -> Bool {
        var next = follower
        let result = change(&next)
        if next != follower { presentation.scrollFollower = next }
        return result
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
                UserTurnView(turn: row.turn).equatable()
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

/// The title and status line (MobileThread, MobileQueue, MobileQuestion, iPadThread boards). On a
/// phone, the name over "● Idle · ⧉ pi/swiftui-previews": the status word and the worktree's
/// branch, or "⌂ your checkout" in lantern when pi works in the space's own checkout.
/// On iPad, the name, the branch chip (`SHBranchChip`: the files changed, and the host when there
/// are several), and a status pill with the running turn's time, on one line.
struct ThreadTitle: View {
    struct Status: Equatable {
        var state: AgentState
        var label: String
        /// When the running turn's prompt was sent (ms); nil at rest.
        var runningSince: Double?

        @MainActor init(store: NativeThreadStore, agent: Agent?) {
            if store.loadError != nil { state = .failed; label = "Error" }
            else if store.startProblem != nil { state = .failed; label = "Can't start" }
            else if !store.dialogs.isEmpty { state = .attention; label = AgentState.attention.label }
            else if store.running { state = .running; label = AgentState.running.label }
            else if store.lastTurnFailed { state = .failed; label = AgentState.failed.label }
            else if let agent { state = AgentState(agent.status); label = state.label }
            else { state = .idle; label = AgentState.idle.label }
            runningSince = store.running && store.dialogs.isEmpty ? store.lastPromptAt : nil
        }

        func meta(now: Date) -> NativeThreadMeta {
            NativeThreadMeta(runningSince: runningSince, now: now.timeIntervalSince1970 * 1000)
        }
    }

    let name: String
    let status: Status
    var branch: AgentBranchLabel?
    /// iPad: the name, the chip and a pill on one line.
    var wide = false
    var goalTime: String? = nil
    var goalStore: NativeThreadStore? = nil

    var body: some View {
        Group {
            // Only a running turn's clock ticks, and only the iPad pill shows it.
            if wide, status.runningSince != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in pill(status.meta(now: context.date)) }
            } else if wide {
                pill(status.meta(now: .distantPast))
            } else {
                compact
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var compact: some View {
        VStack(spacing: SH.Space.xxs) {
            Text(name).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            // The branch truncates in the middle; the status word stays whole.
            HStack(spacing: SH.Space.s) {
                SHStatusDot(status.state)
                Text(status.label).fontWeight(.medium).foregroundStyle(status.state.textColor).fixedSize()
                ThreadGoalHeader(store: goalStore, time: goalTime)
                // A worktree names its branch; your own checkout says so in lantern (MobileQuestion).
                if let branch {
                    let checkout = branch.kind == .checkout
                    let tint = checkout ? Color.sh.lanternText : Color.sh.textTertiary
                    Text("·").foregroundStyle(tint)
                    Image(systemName: checkout ? "house" : "square.on.square")
                        .imageScale(.small)
                        .foregroundStyle(tint)
                    if checkout {
                        Text("your checkout").fontWeight(.medium).foregroundStyle(tint)
                    } else {
                        Text(branch.branch)
                            .font(.sh(.mono))
                            .foregroundStyle(tint)
                            .truncationMode(.middle)
                    }
                }
            }
            .font(.sh(.caption))
            .lineLimit(1)
        }
    }

    private func pill(_ meta: NativeThreadMeta) -> some View {
        HStack(spacing: SH.Space.m) {
            Text(name).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            if let branch {
                // Narrow (a half-open thread beside its pane), the host goes first, then the whole chip,
                // rather than the branch shrinking to a letter.
                let kind: SHBranchChip.Kind = branch.kind == .worktree ? .worktree : .checkout
                ViewThatFits(in: .horizontal) {
                    SHBranchChip(kind: kind, branch: branch.branch, changedFiles: branch.changedFiles, host: branch.host, showsChevron: false)
                    SHBranchChip(kind: kind, branch: branch.branch, changedFiles: branch.changedFiles, showsChevron: false)
                    Color.clear.frame(width: 0, height: 0)
                }
                .layoutPriority(-1)
            }
            SHStatusPill(status.state, label: meta.elapsed.map { "\(status.label) · \($0)" } ?? status.label)
                .fixedSize()
            ThreadGoalHeader(store: goalStore, time: goalTime)
        }
    }
}

/// Goal updates invalidate this child, not the screen or the header's other controls.
private struct ThreadGoalHeader: View {
    let store: NativeThreadStore?
    let time: String?

    var body: some View {
        if let store {
            if let goal = store.goal, goal.isActive {
                SHGoalHeaderPill(time: goal.timeLabel, clockStart: goal.clockStart)
            }
        } else if let time {
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
            button.labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
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

/// Stop while the agent waits on a question, and on regular width while it runs too (DuoOpenThread's ◎; a phone keeps it in the
/// ••• menu and the composer's corner). A question takes the composer's place, and with it the composer's Stop, so this is then
/// the one way to refuse it.
private struct ThreadStopButton: View {
    let store: NativeThreadStore
    let enabled: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if !store.dialogs.isEmpty || store.running && sizeClass == .regular {
            Button("Stop agent", systemImage: "stop.circle") { Task { await store.abort() } }
                .tint(Color.sh.failed)
                .disabled(!enabled || !store.supports("abort"))
        }
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

/// The thread's menu, in the bar's ••• (DuoClosedThreadMenu): the side pane's five tabs with what each says of its work (the
/// totals, "1 running"), then Stop agent and More… (Refresh, Open in new window, the agent actions). On a phone each tab is pushed
/// over the thread; on regular width it opens in the side pane.
private struct ThreadOptionsItems: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let branch: AgentBranchLabel?
    let enabled: Bool
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        Section {
            ForEach(PadSidePaneTab.shown(artifacts: false), id: \.self) { tab in
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
        case .files, .browser, .artifacts:
            return nil
        }
    }
}
