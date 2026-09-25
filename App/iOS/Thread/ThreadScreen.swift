import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One agent's thread (MobileThread, iPadThread boards), on iPhone and iPad alike: the title and
/// status line, the turns, and the composer (`ThreadComposer`, Composer/) at the bottom. The
/// thread polls its host only while it is on screen and the app is active.
///
/// Hooks other tracks fill: `SubagentCards` (Subagents/) where a turn spawned children,
/// `SubagentHooks.list` for the footer's "N subagents", `ReviewHooks.open` for the changes card
/// and edit lines, and `AgentActionsMenu` (Search/) in the options menu.
struct ThreadScreen: View {
    let ref: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var visible = false
    /// The thread's height: the composer may take a share of it (`composerMaxHeight`).
    @State private var height: CGFloat = 0

    /// The poll loop's identity: a new connection, or the thread leaving the screen, restarts it.
    private struct RunKey: Equatable {
        var session: UUID?
        var active: Bool
    }

    var body: some View {
        let host = hosts.host(ref.host)
        let agent = host?.agent(ref.agent)
        let store = threads.store(for: ref)
        let supported = host?.supports(RemoteProtocol.nativeThreadCapability) == true
        let key = RunKey(session: supported && agent != nil ? host?.session : nil, active: visible && scenePhase == .active)
        let status = ThreadTitle.Status(store: store, agent: agent)
        ThreadTranscript(ref: ref, store: store, banner: banner(host: host, agent: agent, store: store, supported: supported))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if agent != nil {
                    ThreadComposer(ref: ref)
                        .environment(\.composerMaxHeight, height > 0 ? height * MobileLayout.composerShare : .infinity)
                        .frame(maxWidth: sizeClass == .regular ? MobileLayout.threadMaxWidth + 2 * MobileLayout.gutter : .infinity)
                        .frame(maxWidth: .infinity)
                        .background(Color.nw.bgWindow)
                }
            }
            .background(Color.nw.bgWindow)
            // Measured around the composer's inset, which would otherwise shrink what it measures.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            // A thread takes the whole screen on iPhone (MobileThread board): no tab bar under the composer.
            .toolbar(.hidden, for: .tabBar)
            .navigationTitle(agent?.name ?? "Thread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ThreadTitle(name: agent?.name ?? "Thread", status: status, wide: sizeClass == .regular)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if sizeClass == .regular {
                        ThreadCounters(status: status)
                    }
                    if agent != nil {
                        ThreadStopButton(store: store, enabled: key.session != nil)
                        ThreadOptionsMenu(ref: ref, store: store, enabled: key.session != nil)
                    }
                }
            }
            .onAppear { visible = true }
            .onDisappear { visible = false }
            .task(id: key) {
                guard key.active, key.session != nil, let client = host?.connectedClient else {
                    if key.session == nil { store.stop() } else { store.suspend() }
                    return
                }
                let agentID = ref.agent
                await store.run { request in try await client.nativeThread(agentID: agentID, request: request) }
            }
    }

    /// One short line for the states that matter; the store keeps the full reason.
    private func banner(host: MobileHost?, agent: Agent?, store: NativeThreadStore, supported: Bool) -> String? {
        guard let host else { return "This host was forgotten." }
        if agent == nil { return host.phase.isConnected ? "This agent is no longer on \(host.name)." : nil }
        if !host.phase.isConnected { return "\(host.name) is offline · showing the last known thread" }
        if !supported { return "Update Shepherd on \(host.name) to open threads here." }
        if let error = store.loadError { return error }
        if store.clipped { return "Some output is clipped · the full thread is on \(host.name)" }
        return nil
    }
}

/// The scrolling turns. It reads the store's rows, so a streamed chunk redraws only this and the
/// turn it changed.
private struct ThreadTranscript: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let banner: String?
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var nearBottom = true

    private static let bottomID = "thread-bottom"

    var body: some View {
        let rows = store.rows
        let running = store.running
        let working = store.workingLabel
        let liveRow = rows.last(where: \.live)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MobileLayout.turnSpacing) {
                    if let banner {
                        Text(banner).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.olderCursor != nil {
                        Button(store.loadingOlder ? "Loading history…" : "Load older messages") {
                            Task { await store.loadOlder() }
                        }
                        .buttonStyle(.nw(.ghost, size: .s))
                        .disabled(!store.isLive || !store.ready || store.loadingOlder)
                        .frame(maxWidth: .infinity)
                    } else if store.snapshot == nil && store.loadError == nil && store.isLive {
                        ProgressView().progressViewStyle(NWSpinnerStyle()).frame(maxWidth: .infinity)
                    }
                    ForEach(rows) { row in
                        // One view per row whatever it holds, so the lazy stack builds only the
                        // rows on screen.
                        VStack(spacing: 0) {
                            // A running call is live on its own line (MobileApproval board): no
                            // "Working…" under it.
                            turn(row, running: running, working: row.live && row.presentation?.endsInLiveActivity != true ? working : nil)
                        }
                        .id(row.id)
                    }
                    if let working, liveRow == nil { NWWorkingRow(working) }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .frame(maxWidth: sizeClass == .regular ? MobileLayout.threadMaxWidth : .infinity)
                .padding(.horizontal, MobileLayout.gutter)
                .padding(.vertical, MobileLayout.gutter)
                .frame(maxWidth: .infinity)
            }
            // Open at the tail and stay pinned while streamed text grows; scrolling up detaches.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(nearBottom ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height - geometry.contentInsets.top < 120
            } action: { _, value in
                if nearBottom != value { nearBottom = value }
            }
            .onChange(of: store.sentCount) { _, _ in
                nearBottom = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder private func turn(_ row: NativeThreadRow, running: Bool, working: String?) -> some View {
        if row.isUser {
            UserTurnView(turn: row.turn).equatable()
        } else if let presentation = row.presentation {
            AgentTurnView(thread: ref, presentation: presentation, live: row.live,
                          subagents: store.placements[row.id] ?? NativeSubagentPlacement(),
                          startedAt: row.startedAt, working: working,
                          actions: actions(row, running: running))
                .equatable()
        }
    }

    private func actions(_ row: NativeThreadRow, running: Bool) -> AgentTurnActions {
        let ref = ref
        let navigator = navigator
        var actions = AgentTurnActions()
        if let text = row.promptText, !running, store.supports("send"),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actions.retry = { [store] in Task { await store.send(text: text) } }
        }
        actions.review = { path in ReviewHooks.open(thread: ref, file: path, navigator: navigator) }
        actions.reviewChanges = { ReviewHooks.open(thread: ref, file: nil, navigator: navigator) }
        if store.placements[row.id]?.isEmpty == false {
            actions.subagents = { navigator.open(SubagentHooks.list(thread: ref)) }
        }
        return actions
    }
}

/// The title and status line (MobileThread, MobileApproval, iPadThread boards). On a phone,
/// the name over "Idle · 17 turns · 42k", or "Running · 21s" while a turn runs. On iPad, the name
/// and a status pill on one line, with the counters ("17 turns · 42k ctx") trailing
/// (`ThreadCounters`).
struct ThreadTitle: View {
    struct Status: Equatable {
        var state: AgentState
        var label: String
        /// Exact only once the whole history is loaded.
        var turns: Int?
        var contextTokens: Int?
        /// When the running turn's prompt was sent (ms); nil at rest.
        var runningSince: Double?

        @MainActor init(store: NativeThreadStore, agent: Agent?) {
            if store.loadError != nil { state = .failed; label = "Error" }
            else if !store.dialogs.isEmpty { state = .attention; label = AgentState.attention.label }
            else if store.running { state = .running; label = AgentState.running.label }
            else if let agent { state = AgentState(agent.status); label = state.label }
            else { state = .idle; label = AgentState.idle.label }
            turns = store.olderCursor == nil && store.snapshot != nil ? store.userTurnCount : nil
            contextTokens = store.stats?.contextTokens
            runningSince = store.running && store.dialogs.isEmpty ? store.lastPromptAt : nil
        }

        func meta(now: Date) -> NativeThreadMeta {
            NativeThreadMeta(turns: turns, contextTokens: contextTokens, runningSince: runningSince,
                             now: now.timeIntervalSince1970 * 1000)
        }
    }

    let name: String
    let status: Status
    /// iPad: the name and a pill on one line.
    var wide = false

    var body: some View {
        Group {
            // Only a running turn's clock ticks.
            if status.runningSince != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in content(status.meta(now: context.date)) }
            } else {
                content(status.meta(now: .distantPast))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func content(_ meta: NativeThreadMeta) -> some View {
        if wide { pill(meta) } else { compact(meta) }
    }

    private func compact(_ meta: NativeThreadMeta) -> some View {
        VStack(spacing: NW.Space.xxs) {
            Text(name).font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
            // The whole line when it fits; otherwise the counters go (a large text size would
            // only show them as "1…"), then the running clock, and the status word stays whole.
            ViewThatFits(in: .horizontal) {
                statusLine(meta.compact).fixedSize()
                statusLine(meta.elapsed.map { [$0] } ?? []).fixedSize()
                statusLine([]).fixedSize(horizontal: false, vertical: true)
            }
            .font(.nw(.caption))
            .lineLimit(1)
        }
    }

    private func statusLine(_ parts: [String]) -> some View {
        HStack(spacing: NW.Space.s) {
            NWStatusDot(status.state)
            Text(status.label).fontWeight(.medium).foregroundStyle(status.state.textColor)
            ForEach(parts, id: \.self) { part in
                Text("· " + part).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
            }
        }
    }

    private func pill(_ meta: NativeThreadMeta) -> some View {
        HStack(spacing: NW.Space.m) {
            Text(name).font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
            NWStatusPill(status.state, label: meta.elapsed.map { "\(status.label) · \($0)" } ?? status.label)
                .fixedSize()
        }
    }
}

/// iPad's trailing counters: "17 turns · 42k ctx".
struct ThreadCounters: View {
    let status: ThreadTitle.Status

    var body: some View {
        let counters = status.meta(now: .distantPast).counters
        if !counters.isEmpty {
            Text(counters.joined(separator: " · "))
                .font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
                .fixedSize()
                .accessibilityLabel(counters.joined(separator: ", "))
        }
    }
}

/// Stop, while the agent runs or waits on a question.
private struct ThreadStopButton: View {
    let store: NativeThreadStore
    let enabled: Bool

    var body: some View {
        if store.running || !store.dialogs.isEmpty {
            Button("Stop", systemImage: "stop.fill") { Task { await store.abort() } }
                .tint(Color.nw.failed)
                .disabled(!enabled || !store.supports("abort"))
                .accessibilityLabel("Stop agent")
        }
    }
}

/// The thread's options: refresh, subagents, and the agent actions (Search/).
private struct ThreadOptionsMenu: View {
    let ref: AgentRef
    let store: NativeThreadStore
    let enabled: Bool
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh(fresh: true) } }
                .disabled(!enabled)
            if store.hasSubagents {
                Button("Subagents", systemImage: "person.2") { navigator.open(SubagentHooks.list(thread: ref)) }
            }
            AgentActionsMenu(thread: ref)
        } label: {
            Label("Thread options", systemImage: "ellipsis")
        }
    }
}
