import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension EnvironmentValues {
    /// Keyboard commands for the thread on screen, when the app provides them.
    @Entry var threadCommands: ThreadCommandCenter? = nil
    /// How long a thread that draws something waits for pi before its composer says pi is
    /// starting; a blank one waits no longer than `AppLayout.blankStartingIndicatorDelay`
    /// (previews show it at once).
    @Entry var threadStartingDelay: Duration = AppLayout.startingIndicatorDelay
}

/// An agent's thread (NWThread board): an 820pt column of turns in a scroll view that follows
/// the tail, with the composer floating over its bottom edge. The store derives every row once
/// per change; this view only lays them out.
struct ThreadView: View {
    let store: NativeThreadStore
    let active: Bool
    let isFocused: Bool
    let request: NativeThreadStore.Request
    /// The thread as pi's session file holds it, shown while pi starts (local agents).
    var preview: NativeThreadStore.Preview? = nil
    /// This thread's key in the command center (see `ThreadCommandCenter`).
    var commandKey: String? = nil
    /// The empty thread's title and the composer placeholder name the agent and its folder.
    var agentName: String? = nil
    var workingDirectory: String? = nil
    /// Opens a subagent in the inspector.
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    /// Opens a subagent in the inspector with its Steer field focused (the tray's Steer).
    var steerSubagent: ((ChildRun) -> Void)? = nil
    /// The run open in the inspector; its tray row wears the selection.
    var inspectedRunID: String? = nil
    /// Opens the review pane at a file (a changed file, the changes card, an edit call).
    var review: ((String) -> Void)? = nil
    /// The models the host offers, for the composer's model picker.
    var listModels: (() async -> [PiModelCatalog.Entry])? = nil
    /// The composer's "Up next" state, when a test or preview drives it.
    var queueState: QueueStackState? = nil
    @State private var follower = NativeScrollFollower()
    /// Narrow windows drop to 16pt gutters so the column keeps its width, not its margins.
    @State private var gutter = AppLayout.gutter
    @State private var hovering = false
    @State private var wheelMonitor: Any?
    @State private var wheelIntentUntil = Date.distantPast
    /// Measured height of the floating composer: the scroll view insets by exactly this, so the
    /// thread neither hides under the card nor scrolls into blank space below the last turn.
    @State private var composerHeight: CGFloat = 120
    @State private var menuRequest: ComposerMenuRequest?
    /// The user turn the last ⌥⌘↑/↓ landed on.
    @State private var jumpedTurn: String?
    @State private var arrivals = ThreadArrivals()

    var body: some View {
        let _ = NWRenderProbe.tick("thread.view")
        let rows = store.rows
        let running = store.running
        let liveRow = rows.last(where: \.live)
        // One persistent tail row for the whole run, the last part of the streaming reply (or on
        // its own before the reply starts). A question replaces it with the composer's question
        // panel, and live thinking carries its own spinner. A pi that is starting says so in the
        // composer, never here (`NativeThreadStore.workingLabel`).
        let working = store.workingLabel
        // Until the thread has caught up since it came on screen (opening it, or the first pull
        // after switching back to the agent), whatever changes lands at once.
        let catchingUp = arrivals.catchUp.catchingUp(caughtUpAt: store.catchUp?.thread, version: store.threadVersion)
        let settled = active && !catchingUp
        let arrived = arrivals.update(rows.map(\.id), session: store.sessionKey, active: active, catchingUp: catchingUp)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    // Never animated as a whole (rows, their text, and the tail anchor change on
                    // every streamed chunk): turns that arrive make their own entrance.
                    LazyVStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
                        notices
                        if store.olderCursor != nil {
                            Button(store.loadingOlder ? "Loading history…" : "Load older messages") {
                                Task { await store.loadOlder() }
                            }
                            .buttonStyle(NWButtonStyle(.ghost, size: .s))
                            .disabled(!active || !store.ready || store.loadingOlder)
                            .nwAnimation(.content, value: store.loadingOlder)
                            .frame(maxWidth: .infinity)
                        }
                        if rows.isEmpty { emptyState }
                        ForEach(rows) { row in
                            let _ = NWRenderProbe.tick("thread.rowBuilder")
                            // One view per row whatever it holds, so the lazy stack builds only the
                            // rows on screen: a row that could be nothing would make it evaluate
                            // every row of a long thread on each streamed chunk.
                            VStack(spacing: 0) {
                                turn(row, running: running, working: row.live ? working : nil, arriving: arrived.contains(row.id),
                                     settled: settled)
                            }
                            .id(row.id)
                        }
                        if let working, liveRow == nil { WorkingRow(label: working).nwArrival(settled) }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .frame(maxWidth: AppLayout.threadMaxWidth)
                    .padding(.horizontal, gutter)
                    .frame(maxWidth: .infinity)
                }
                // The composer floats over the scroll view; inset by its real height so "the
                // bottom" is the last turn, not the space under the card.
                .safeAreaPadding(.bottom, composerHeight)
                // A margin rather than padding so scrollTo(.top) keeps the 28pt above a turn.
                .contentMargins(.top, AppLayout.threadTop, for: .scrollContent)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // While stuck, growth keeps the tail pinned without any scrollTo; detaching only
                // ever happens on user scroll intent.
                .defaultScrollAnchor(follower.sticky ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: NativeScrollProbe.self, of: Self.probe) { old, new in
                    // Intent is a wheel tick (350 ms window) or a live drag phase.
                    let gesture = Date() <= wheelIntentUntil || follower.userScrolling
                    // The size-change anchor does not re-pin when the inset or the composer
                    // changes under it; while stuck, every layout change lands on the tail.
                    if follower.observe(from: old, to: new, gesture: gesture) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onScrollPhaseChange { _, phase, context in
                    // Only a live finger/wheel counts. Momentum and programmatic phases are not
                    // intent; a gesture that ends near the bottom re-sticks from where it lands.
                    follower.userScrolling = phase == .interacting
                    if phase == .idle {
                        follower.observe(distanceFromBottom: Self.distanceFromBottom(context.geometry))
                    }
                }
                .onChange(of: store.sentCount) { _, _ in
                    // A send that goes in now re-attaches to the tail: the echoed turn is the last
                    // thing in the thread, and the reply streams in under it. A follow-up that
                    // waits in Up next leaves the reader where they are, now and when it goes.
                    let queued = store.lastSendQueued
                    follower.sent(queued: queued)
                    if !queued { jumpedTurn = nil }
                }
                .onChange(of: rows.last(where: \.isUser)?.id) { _, id in
                    guard id != nil, follower.userTurnArrived() else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                // New output at the tail is what "unseen" means, never the content height.
                .onChange(of: rows.last) { _, _ in follower.contentArrived() }
                .modifier(ThreadCommandHandler(key: commandKey, active: active) { command in
                    handle(command, proxy: proxy)
                })
                // The composer draws "Jump to latest" over the fade it lays on the thread and under
                // its card and menus, so the pill reads clearly and never covers an open menu.
                Composer(store: store, active: active, isFocused: isFocused, agentName: agentName, hasTurns: !rows.isEmpty,
                         gutter: gutter, listModels: listModels, menuRequest: menuRequest,
                         jumpToLatest: follower.showsJump(running: running) ? {
                             follower.jumpToLatest()
                             proxy.scrollTo(Self.bottomID, anchor: .bottom)
                         } : nil, queueState: queueState,
                         inspectSubagent: inspectSubagent, steerSubagent: steerSubagent, inspectedRunID: inspectedRunID)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        // The composer's menus float over the thread and fit the room above the card in it.
        .coordinateSpace(.named(Composer.threadSpace))
        // Switching back to an agent is a visibility flip: the pull that catches its thread up
        // runs none of the thread's view-attached motion (the composer gates its own).
        // Keyed on what the render drew, so only the update carrying it is touched: a hover or a
        // disclosure inside the thread later still moves.
        .transaction(value: CatchUpGate.Key(version: store.threadVersion, active: active)) {
            if catchingUp { $0.disablesAnimations = true }
        }
        // The tray's controls: it changes only when the thread is switched to or away from (and
        // when the host's support does), and redraws the tray's rows.
        .environment(\.threadActionsEnabled, active && store.supports("subagents"))
        .foregroundStyle(Color.nw.textPrimary)
        .tint(Color.nw.running)
        .background(Color.nw.bgWindow)
        .onGeometryChange(for: CGFloat.self) { AppLayout.threadGutter(width: $0.size.width) } action: { gutter = $0 }
        .onHover { hovering = $0 }
        .onAppear { installWheelMonitor() }
        .onDisappear {
            store.stop()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }
        // Hidden, the thread stops polling and keeps what it shows; shown again, it polls from
        // there (`NativeThreadStore.suspend`).
        .task(id: active) {
            guard active else { store.suspend(); return }
            await store.run(request: request, preview: preview)
        }
    }

    /// A sent message rises into the thread; a reply's parts make their own entrances.
    @ViewBuilder private func turn(_ row: NativeThreadRow, running: Bool, working: String?, arriving: Bool, settled: Bool) -> some View {
        if row.isUser {
            UserTurn(turn: row.turn)
                .equatable()
                .nwArrival(arriving, .list, edge: .bottom)
        } else if let presentation = row.presentation {
            AgentTurn(presentation: presentation, live: row.live, subagents: TurnSubagents(store.placements[row.id]),
                      subagentActions: subagentActions, startedAt: row.startedAt,
                      retry: retryAction(row, running: running), review: review, working: working, arriving: arriving,
                      settled: settled)
                .equatable()
        }
    }

    private static let bottomID = "thread-bottom"

    private var subagentActions: SubagentActions {
        SubagentActions(
            inspect: { run in inspectSubagent?(run) },
            command: { run, action, text, mode in Task { await store.subagentCommand(runID: run.runID, action: action, text: text, mode: mode) } },
            steer: steerSubagent,
            inspectedRunID: inspectedRunID)
    }

    /// Retry resends the prompt that opened a turn, once the agent is idle.
    private func retryAction(_ row: NativeThreadRow, running: Bool) -> (() -> Void)? {
        guard let text = row.promptText, !running, store.supports("send"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return { [store] in Task { await store.send(text: text) } }
    }

    private func handle(_ command: ThreadCommandCenter.Command, proxy: ScrollViewProxy) {
        switch command {
        case .modelPicker:
            menuRequest = ComposerMenuRequest(menu: .models)
        case .thinkingMenu:
            menuRequest = ComposerMenuRequest(menu: .thinking)
        case .inspectSubagent:
            if let run = store.subagents.first(where: { !$0.isTerminal }) ?? store.subagents.last { inspectSubagent?(run) }
            else { NSSound.beep() }
        case .previousTurn, .nextTurn:
            let userTurns = store.rows.filter(\.isUser).map(\.id)
            guard !userTurns.isEmpty else { NSSound.beep(); return }
            let current = jumpedTurn.flatMap(userTurns.firstIndex(of:)) ?? userTurns.count
            let target = command == .previousTurn ? max(0, current - 1) : current + 1
            guard userTurns.indices.contains(target) else {
                jumpedTurn = nil
                follower.jumpToLatest()
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                return
            }
            jumpedTurn = userTurns[target]
            follower.beginJump()
            withNWAnimation(.scroll) { proxy.scrollTo(userTurns[target], anchor: .top) }
        }
    }

    /// How far the visible bottom sits above the end of the content (`NativeScrollProbe`): 0 at
    /// the tail, negative for content that fits the viewport.
    static func distanceFromBottom(_ geometry: ScrollGeometry) -> CGFloat {
        CGFloat(probe(geometry).distance)
    }

    static func probe(_ geometry: ScrollGeometry) -> NativeScrollProbe {
        NativeScrollProbe(content: geometry.contentSize.height, offset: geometry.contentOffset.y,
                          container: geometry.containerSize.height, insetTop: geometry.contentInsets.top,
                          insetBottom: geometry.contentInsets.bottom)
    }

    /// Wheel/trackpad events are the one user scroll intent SwiftUI does not phase for us.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if hovering { wheelIntentUntil = Date().addingTimeInterval(0.35) }
            return event
        }
    }

    @ViewBuilder private var notices: some View {
        if store.session != nil {
            if !store.ready, store.loadError == nil, !store.starting, !store.previewing {
                quiet("Last known thread · refreshing before enabling actions")
            }
            if !store.dialogsSupported { quiet("This host's pi cannot answer questions here · update Shepherd on the host") }
            if store.clipped { quiet("Some earlier output is clipped") }
        }
    }

    /// An agent with nothing said yet. A new one is known to be empty from the start, so its
    /// framed state shows while pi boots. While the history is not known yet (connecting, or pi
    /// still starting with no session file to read) the thread stays blank and the composer says
    /// pi is starting; an error keeps the last transcript and shows its banner there instead.
    @ViewBuilder private var emptyState: some View {
        if store.session != nil {
            NWEmptyState(
                Text("New agent in \(Text(abbreviatedPath).font(Font.nwMono(AppLayout.emptyThreadPathSize, .medium)))"),
                message: "Describe the task. Drop or paste images to attach them, or type / for commands.",
                showsMark: false, framed: true
            )
            .padding(.top, AppLayout.emptyThreadTop)
            // Fades in when pi's history arrives empty; a thread known to be empty just shows it.
            .nwArrival(arrivals.startedLoading)
        }
    }

    private var abbreviatedPath: String {
        guard let workingDirectory else { return agentName ?? "this folder" }
        return (workingDirectory as NSString).abbreviatingWithTildeInPath
    }

    private func quiet(_ text: String) -> some View {
        Text(text).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary).textSelection(.enabled)
    }
}

/// Tells a view whether the render it is in draws a catch-up: what a thread brought back from
/// while it was away (or loading), which lands without motion. The store marks where it caught
/// up (`NativeThreadStore.catchUp`, with its content version then) in the same update as the
/// pull, so catching up takes no pass of its own; this remembers the version the view last
/// drew, so the render showing those changes, and only it, counts as the catch-up. A thread
/// that came back unchanged is caught up at once. Read in `body`, and a reference, so keeping
/// it current never re-renders the view.
@MainActor
final class CatchUpGate {
    private var drawn = Int.min

    /// What a view keys its `transaction(value:)` on, so that only the update in which it drew
    /// a catch-up (or flipped on screen) is touched, never its subviews' later updates.
    struct Key: Equatable {
        let version: Int
        let active: Bool
    }

    /// `caughtUpAt` is the version the store had when it caught up (nil until then), and
    /// `version` its version now.
    func catchingUp(caughtUpAt: Int?, version: Int) -> Bool {
        defer { drawn = version }
        guard let caughtUpAt else { return true }
        return caughtUpAt > drawn
    }
}

/// Which turns arrived at a thread's tail with its latest change, so they (and only they) make
/// an entrance. Loading is instant: opening the thread, the first pull after it comes back on
/// screen (an agent switched back to catches up at once), a page of older history, and a
/// window or session swapped out from under the view. Read in `body`, and a reference, so
/// keeping it current never re-renders the thread; the same rows always answer the same set.
@MainActor
final class ThreadArrivals {
    /// Whether the thread's latest render showed a catch-up (see `CatchUpGate`).
    let catchUp = CatchUpGate()
    /// The thread is on screen and caught up: turns appended at its tail arrive.
    private(set) var armed = false
    /// The first rows this saw were still loading (pi's history not known yet).
    private(set) var startedLoading = false
    private var seen = false
    private var signature: Signature?
    private var arrived: Set<String> = []

    private struct Signature: Equatable {
        var session: String?
        var count: Int
        var first: String?
        var last: String?
    }

    /// The rows in `ids` that arrived with this change. `session` names the snapshot's pi
    /// session (nil before the first one), `active` is whether the thread is on screen (a hidden
    /// thread stops polling), and `catchingUp` whether this render shows a catch-up.
    func update(_ ids: [String], session: String?, active: Bool, catchingUp: Bool) -> Set<String> {
        if !seen {
            seen = true
            startedLoading = session == nil
        }
        armed = active && !catchingUp && session != nil
        let next = Signature(session: session, count: ids.count, first: ids.first, last: ids.last)
        let previous = signature
        guard armed, let previous else {
            signature = next
            arrived = []
            return arrived
        }
        guard next != previous else { return arrived }
        signature = next
        if previous.session != session {
            arrived = []
        } else if let last = previous.last, let index = ids.lastIndex(of: last) {
            arrived = Set(ids[(index + 1)...])
        } else {
            // An empty thread's first turns arrive; a different window does not.
            arrived = previous.last == nil ? Set(ids) : []
        }
        return arrived
    }
}

/// Watches the command center in its own view, so a command sent to another thread never
/// re-evaluates this thread's body.
private struct ThreadCommandHandler: ViewModifier {
    let key: String?
    let active: Bool
    let handle: (ThreadCommandCenter.Command) -> Void
    @Environment(\.threadCommands) private var commands

    func body(content: Content) -> some View {
        content.onChange(of: commands?.request) { _, request in
            guard let request, request.thread == key, active else { return }
            handle(request.command)
        }
    }
}

