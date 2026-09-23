import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension EnvironmentValues {
    /// Keyboard commands for the thread on screen, when the app provides them.
    @Entry var threadCommands: ThreadCommandCenter? = nil
}

/// An agent's thread (NWThread board): an 820pt column of turns in a scroll view that follows
/// the tail, with the composer floating over its bottom edge. The store derives every row once
/// per change; this view only lays them out.
struct ThreadView: View {
    let store: NativeThreadStore
    let active: Bool
    let isFocused: Bool
    let request: NativeThreadStore.Request
    /// This thread's key in the command center (see `ThreadCommandCenter`).
    var commandKey: String? = nil
    /// The empty thread's title and the composer placeholder name the agent and its folder.
    var agentName: String? = nil
    var workingDirectory: String? = nil
    /// Opens a subagent in the inspector.
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    /// The run open in the inspector; its card and ledger row are highlighted.
    var inspectedRunID: String? = nil
    /// Opens the review pane at a file (a changed file, the changes card, an edit call).
    var review: ((String) -> Void)? = nil
    /// The models the host offers, for the composer's model picker.
    var listModels: (() async -> [PiModelCatalog.Entry])? = nil
    @FocusState private var composing: Bool
    @State private var follower = NativeScrollFollower()
    /// Narrow windows drop to 16pt gutters so the column keeps its width, not its margins.
    @State private var gutter = AppLayout.gutter
    @State private var hovering = false
    /// Set on send: once the echoed turn is in the tree, scroll to the tail even if the reader
    /// had scrolled up.
    @State private var scrollToTurnPending = false
    @State private var wheelMonitor: Any?
    @State private var wheelIntentUntil = Date.distantPast
    /// Measured height of the floating composer: the scroll view insets by exactly this, so the
    /// thread neither hides under the card nor scrolls into blank space below the last turn.
    @State private var composerHeight: CGFloat = 120
    @State private var modelPickerRequest = 0
    /// The user turn the last ⌥⌘↑/↓ landed on.
    @State private var jumpedTurn: String?

    private var running: Bool { store.loadError == nil && store.settledRunning }

    var body: some View {
        let rows = store.rows
        let running = running
        let liveRow = rows.last(where: \.live)
        // One persistent tail row for the whole run, the last part of the streaming reply (or on
        // its own before the reply starts). A question replaces it with the composer's question
        // panel, and live thinking carries its own spinner.
        let working = running && store.snapshot?.dialogs.isEmpty != false ? workingLabel(liveRow) : nil
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppLayout.turnSpacing) {
                        notices
                        if store.olderCursor != nil {
                            Button(store.loadingOlder ? "Loading history…" : "Load older messages") {
                                Task { await store.loadOlder() }
                            }
                            .buttonStyle(NWButtonStyle(.ghost, size: .s))
                            .disabled(!active || !store.ready || store.loadingOlder)
                            .frame(maxWidth: .infinity)
                        }
                        if rows.isEmpty { emptyState }
                        ForEach(rows) { row in
                            turn(row, running: running, working: row.live ? working : nil).id(row.id)
                        }
                        if let working, liveRow == nil { WorkingRow(label: working) }
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
                .onScrollGeometryChange(for: ScrollProbe.self) { geometry in
                    ScrollProbe(distance: Self.distanceFromBottom(geometry),
                                content: geometry.contentSize.height, container: geometry.containerSize.height,
                                inset: geometry.contentInsets.bottom)
                } action: { old, new in
                    observe(old: old, new: new)
                    // The size-change anchor does not re-pin when the inset or the composer
                    // changes under it; while stuck, every layout change lands on the tail.
                    if follower.sticky, new.layoutDiffers(from: old), new.distance > 4 {
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
                    // Sending re-attaches to the tail: the echoed turn is the last thing in the
                    // thread, and the reply streams in under it.
                    follower.jumpToLatest()
                    scrollToTurnPending = true
                    jumpedTurn = nil
                }
                .onChange(of: rows.last(where: \.isUser)?.id) { _, id in
                    guard scrollToTurnPending, id != nil else { return }
                    scrollToTurnPending = false
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .modifier(ThreadCommandHandler(key: commandKey, active: active) { command in
                    handle(command, proxy: proxy)
                })
                .overlay(alignment: .bottom) {
                    if follower.showsJump(running: running) {
                        Button {
                            follower.jumpToLatest()
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(Font.nw(.caption, weight: .medium)).foregroundStyle(Color.nw.textSecondary)
                                .padding(.horizontal, NW.Space.l).frame(height: NW.Height.controlM)
                                .background(Color.nw.bgRaised, in: Capsule())
                                .nwBorder(Color.nw.lineStrong, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, composerHeight + NW.Space.m)
                        .transition(.opacity)
                        .accessibilityLabel("Jump to latest")
                    }
                }
            }
            Composer(store: store, active: active, agentName: agentName, hasTurns: !rows.isEmpty, gutter: gutter,
                     composing: $composing, listModels: listModels, modelPickerRequest: modelPickerRequest)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .foregroundStyle(Color.nw.textPrimary)
        .tint(Color.nw.running)
        .background(Color.nw.bgWindow)
        .animation(.easeInOut(duration: NW.Motion.hover.duration), value: follower.showsJump(running: running))
        .onGeometryChange(for: CGFloat.self) { AppLayout.threadGutter(width: $0.size.width) } action: { gutter = $0 }
        .onHover { hovering = $0 }
        .onAppear { installWheelMonitor() }
        .onDisappear {
            store.stop()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil
        }
        .task(id: active) {
            guard active else { store.stop(); return }
            await store.run(request: request)
        }
        // Let any deferred AppKit focus release finish before claiming the composer.
        .task(id: active && isFocused) {
            composing = false
            guard active && isFocused else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            composing = true
        }
    }

    @ViewBuilder private func turn(_ row: NativeThreadRow, running: Bool, working: String?) -> some View {
        if row.isUser {
            UserTurn(messages: row.turn.messages, caption: row.turn.messages.first?.timestamp.map { nativeClockText($0) })
                .equatable()
        } else if let presentation = row.presentation {
            AgentTurn(presentation: presentation, live: row.live, subagents: store.placements[row.id] ?? NativeSubagentPlacement(),
                      subagentActions: subagentActions, startedAt: row.startedAt,
                      retry: retryAction(row, running: running), review: review, working: working)
                .equatable()
        }
    }

    private static let bottomID = "thread-bottom"

    /// What the tail row says: nothing under live thinking (it has its own spinner), "Working…"
    /// under a live activity line, else pi's current activity.
    private func workingLabel(_ live: NativeThreadRow?) -> String? {
        if let presentation = live?.presentation {
            if presentation.endsInLiveThinking { return nil }
            if presentation.endsInLiveActivity { return "Working…" }
        }
        return nativeWorkingLabel(store.snapshot?.provisional ?? [])
    }

    private var subagentActions: SubagentActions {
        SubagentActions(
            inspect: { run in inspectSubagent?(run) },
            command: { run, action, text, mode in Task { await store.subagentCommand(runID: run.runID, action: action, text: text, mode: mode) } },
            enabled: active && store.supports("subagents"),
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
            modelPickerRequest += 1
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
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.15)) {
                proxy.scrollTo(userTurns[target], anchor: .top)
            }
        }
    }

    /// How far the visible bottom sits above the end of the content. `containerSize` is the
    /// viewport minus both insets (the top margin and the composer's safe area), and the offset
    /// runs from `-top` to `content + bottom - frame`, so at the tail this is exactly 0.
    /// Content that fits the viewport reads negative.
    static func distanceFromBottom(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height - geometry.contentInsets.top
    }

    private struct ScrollProbe: Equatable {
        var distance: CGFloat
        var content: CGFloat
        var container: CGFloat
        /// Bottom content inset (the floating composer); a change here is layout, not the user.
        var inset: CGFloat
        func layoutDiffers(from other: ScrollProbe) -> Bool {
            content != other.content || container != other.container || inset != other.inset
        }
    }

    /// Intent is a wheel tick (350 ms window) or a live drag phase. Offset changes alone are
    /// never intent: layout shrink and the resulting offset shift arrive in separate
    /// callbacks, so "moved up without a size change" misfires on every provisional→history
    /// swap.
    private func observe(old: ScrollProbe, new: ScrollProbe) {
        let gesture = Date() <= wheelIntentUntil || follower.userScrolling
        let intent = gesture && new.distance > old.distance && !new.layoutDiffers(from: old)
        // Content that fits the viewport has a negative distance; growth from there is layout.
        let grew = new.content > old.content && old.distance > 0
        follower.observe(distanceFromBottom: new.distance, userIntent: intent, contentGrew: grew)
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
        if let snapshot = store.snapshot {
            if !store.ready, store.loadError == nil { quiet("Last known thread · refreshing before enabling actions") }
            if !snapshot.dialogsSupported { quiet("This host's pi cannot answer questions here · update Shepherd on the host") }
            if snapshot.clipped { quiet("Some earlier output is clipped") }
        }
    }

    /// Connecting, or a fresh agent with nothing said yet. An error keeps the last transcript and
    /// shows its banner above the composer instead.
    @ViewBuilder private var emptyState: some View {
        if store.snapshot == nil, store.loadError == nil {
            HStack(spacing: 10) {
                ProgressView().progressViewStyle(.nwSpinner(size: 14))
                Text("Starting pi…").font(Font.nw(.body)).foregroundStyle(Color.nw.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 120)
        } else if store.snapshot != nil {
            NWEmptyState(
                Text("New agent in \(Text(abbreviatedPath).font(Font.nwMono(15, .medium)))"),
                message: "Describe the task. Drop or paste images to attach them, or type / for commands.",
                showsMark: false, framed: true
            )
            .padding(.top, 80)
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
