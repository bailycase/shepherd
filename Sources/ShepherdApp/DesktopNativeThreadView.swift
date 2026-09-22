import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// Native thread per docs/design-spec (page 1, 2, 3, 8, 9). Everything here reads
// NativeTokens / NativeFonts / NativeMetrics; Terminal-mode chrome keeps Tokens.
// The composer card and its pieces live in DesktopNativeComposer.swift.

struct DesktopNativeThreadView: View {
    @ObservedObject var store: NativeThreadStore
    let active: Bool
    let isFocused: Bool
    let request: NativeThreadStore.Request
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    /// Composer placeholder before the first turn: "Message <agent>…".
    var agentName: String? = nil
    /// Opens a subagent in the side-panel inspector (RPC agents with native children).
    var inspectSubagent: ((ChildRun) -> Void)? = nil
    @ObservedObject private var appearance = AppSettings.shared
    @FocusState private var composing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var clock = NativeThreadClock()
    @State private var follower = NativeScrollFollower()
    @State private var width: CGFloat = NativeMetrics.threadMaxWidth + 2 * NativeMetrics.gutter
    @State private var hovering = false
    /// Set on send: once the echoed turn is in the tree, scroll to the tail even if the user had
    /// scrolled up.
    @State private var scrollToTurnPending = false
    @State private var wheelMonitor: Any?
    @State private var wheelIntentUntil = Date.distantPast
    /// Measured height of the floating composer. The scroll view insets by exactly this, so the
    /// thread can neither hide under the card nor scroll into blank space below the last turn.
    @State private var composerHeight: CGFloat = NativeMetrics.composerInset

    /// 32pt gutters (spec §3) once the 760pt column fits; a narrow window drops to 16 so the
    /// column keeps the width instead of the margins.
    private var gutter: CGFloat {
        width >= NativeMetrics.threadMaxWidth + 2 * NativeMetrics.gutter ? NativeMetrics.gutter : NativeMetrics.gutterCompact
    }

    private var running: Bool { store.loadError == nil && store.settledRunning }
    private var turns: [NativeTurn] { nativeTurns(store.displayedMessages) }
    private var placements: [String: NativeSubagentPlacement] { nativeSubagentPlacements(store.subagents, turns: turns) }
    private var subagentActions: NativeSubagentActions {
        NativeSubagentActions(
            inspect: { run in inspectSubagent?(run) },
            command: { run, action, text, mode in Task { await store.subagentCommand(runID: run.runID, action: action, text: text, mode: mode) } },
            enabled: active && store.supports("subagents"))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: NativeMetrics.turnSpacing) {
                        notices
                        if store.olderCursor != nil {
                            Button(store.loadingOlder ? "Loading history…" : "Load older messages") {
                                Task { await store.loadOlder() }
                            }
                            .buttonStyle(NativeButtonStyle(.ghost))
                            .disabled(!active || !store.ready || store.loadingOlder)
                        }
                        if turns.isEmpty { emptyState }
                        ForEach(turns) { turn in
                            if turn.isUser {
                                NativeUserTurn(messages: turn.messages).id(turn.id)
                            } else {
                                NativeAgentTurn(messages: turn.messages, running: running, clock: clock, showTerminal: showTerminal,
                                                subagents: placements[turn.id] ?? NativeSubagentPlacement(), subagentActions: subagentActions)
                                    .id(turn.id)
                            }
                        }
                        // bb TimelineWorkingIndicator: one persistent tail row for the whole run.
                        if running, store.snapshot?.dialogs.isEmpty != false {
                            NativeWorkingRow(label: nativeWorkingLabel(store.snapshot?.provisional ?? []),
                                             elapsed: clock.runElapsed(now: clock.now))
                        }
                        Color.clear.frame(height: 1).id("native-bottom")
                    }
                    // Spec §3: the 760pt column is content width; gutters sit outside it.
                    .frame(maxWidth: NativeMetrics.threadMaxWidth)
                    .padding(.horizontal, gutter)
                    .frame(maxWidth: .infinity)
                }
                // The composer floats over the scroll view; inset the scrollable area by its real
                // height so "the bottom" is the last turn, not 180pt of nothing.
                .safeAreaPadding(.bottom, composerHeight)
                // A margin rather than padding so scrollTo(.top) leaves the 28pt above the anchored turn.
                .contentMargins(.top, NativeMetrics.threadTop, for: .scrollContent)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // Sticky follow: while stuck, content growth keeps the tail pinned without any
                // scrollTo; detaching only ever happens on user scroll intent (see observe below).
                .defaultScrollAnchor(follower.sticky ? .bottom : nil, for: .sizeChanges)
                .onScrollGeometryChange(for: ScrollProbe.self) { geometry in
                    ScrollProbe(distance: geometry.contentSize.height + geometry.contentInsets.bottom
                                    - geometry.contentOffset.y - geometry.containerSize.height,
                                content: geometry.contentSize.height, container: geometry.containerSize.height,
                                inset: geometry.contentInsets.bottom)
                } action: { old, new in
                    observe(old: old, new: new)
                    // The size-change anchor does not re-pin when the inset or the composer
                    // changes under it; while stuck, every layout change lands on the tail.
                    if follower.sticky, new.layoutDiffers(from: old), new.distance > NativeScrollFollower.threshold {
                        proxy.scrollTo("native-bottom", anchor: .bottom)
                    }
                }
                .onScrollPhaseChange { _, phase, context in
                    // Only a live finger/wheel counts. Momentum (.decelerating) and programmatic
                    // (.animating) phases are not intent; a gesture that ends at the bottom
                    // re-sticks immediately via the geometry it lands on.
                    follower.userScrolling = phase == .interacting
                    if phase == .idle {
                        let g = context.geometry
                        follower.observe(distanceFromBottom: g.contentSize.height + g.contentInsets.bottom - g.contentOffset.y - g.containerSize.height)
                    }
                }
                .onChange(of: store.snapshot) { _, snapshot in clock.observe(snapshot) }
                .onChange(of: store.sentCount) { _, _ in
                    // Sending re-attaches to the tail: the echoed turn is the last thing in the
                    // thread, and the reply streams in under it. (t3 anchors the new turn to the
                    // top instead, but that needs a viewport of blank space after it, which the
                    // user can scroll into; we keep the thread ending at its last turn.)
                    follower.jumpToLatest()
                    scrollToTurnPending = true
                }
                .onChange(of: turns.last(where: \.isUser)?.id) { _, id in
                    guard scrollToTurnPending, id != nil else { return }
                    scrollToTurnPending = false
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo("native-bottom", anchor: .bottom)
                    }
                }
                .overlay(alignment: .bottom) {
                    if follower.showsJump(running: running) {
                        Button {
                            follower.jumpToLatest()
                            proxy.scrollTo("native-bottom", anchor: .bottom)
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down")
                                .font(NativeFonts.caption).foregroundStyle(NativeTokens.textSecondary)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(NativeTokens.bgRaised, in: Capsule())
                                .overlay(Capsule().strokeBorder(NativeTokens.borderStrong, lineWidth: 1))
                                .shadow(color: NativeTokens.composerShadow, radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, composerHeight + 8)
                        .transition(.opacity)
                        .accessibilityLabel("Jump to latest")
                    }
                }
            }
            NativeComposer(store: store, clock: clock, active: active, agentName: agentName,
                           hasTurns: !turns.isEmpty, gutter: gutter, showTerminal: showTerminal, composing: $composing)
                // ⌘I opens the first live subagent (the card's own Inspect button targets a specific run).
                .background {
                    if let first = store.subagents.first(where: { !$0.isTerminal }) ?? store.subagents.first, inspectSubagent != nil {
                        Button("Inspect subagent") { inspectSubagent?(first) }
                            .keyboardShortcut("i", modifiers: .command)
                            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
        }
        .font(NativeFonts.body)
        .foregroundStyle(NativeTokens.text)
        .tint(NativeTokens.accent)
        .background(NativeTokens.bgSurface)
        .animation(.easeInOut(duration: 0.12), value: follower.showsJump(running: running))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
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
        // Let the terminal's deferred AppKit focus release finish before claiming the composer.
        .task(id: active && isFocused) {
            composing = false
            guard active && isFocused else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            composing = true
        }
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

    /// bb useStickyBottomScroll: intent is a wheel tick (350 ms window) or a live drag phase.
    /// Offset changes alone are never intent: layout shrink and the resulting offset shift
    /// arrive in separate callbacks, so "moved up without a size change" misfires on every
    /// provisional→history swap.
    private func observe(old: ScrollProbe, new: ScrollProbe) {
        let intent = Date() <= wheelIntentUntil
        // Content that fits the viewport has a negative "distance"; growth from there is
        // layout, never the user, and must not register as unseen content.
        let grew = new.content > old.content && old.distance > 0
        follower.observe(distanceFromBottom: new.distance, userIntent: intent, contentGrew: grew)
    }

    /// Wheel/trackpad events are the only user scroll intent SwiftUI does not phase for us.
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
            if !snapshot.dialogsSupported {
                quiet("Questions need the pi dialog bridge · older pi and custom TUI extensions answer in Terminal", link: true)
            }
            if snapshot.clipped { quiet("Some output is clipped", link: true) }
        }
    }

    /// Connecting, or a fresh agent with nothing said yet. An error keeps the last transcript
    /// and shows its banner in the composer instead.
    @ViewBuilder private var emptyState: some View {
        if store.snapshot == nil, store.loadError == nil {
            NativeEmptyState(title: "Starting…", caption: "Connecting to this agent’s native bridge", pulsing: true)
        } else if store.snapshot != nil {
            NativeEmptyState(title: "No messages yet", caption: "Say what the agent should do; ⇧⏎ adds a line.", pulsing: false)
        }
    }

    private func quiet(_ text: String, link: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(text).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted).textSelection(.enabled)
            if link { NativeTerminalLink(action: showTerminal) }
        }
    }
}

/// Centred title + caption for connecting / fresh threads (F9).
struct NativeEmptyState: View {
    let title: String
    let caption: String
    let pulsing: Bool
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if pulsing { NativePulseDot() }
                Text(title).font(NativeFonts.title).foregroundStyle(NativeTokens.text)
            }
            Text(caption).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .accessibilityElement(children: .combine)
    }
}

/// 28pt tail row while the agent runs: shimmering label, or a pulsing dot under Reduce Motion.
struct NativeWorkingRow: View {
    let label: String
    /// Elapsed run time, shown muted after the label so the composer needs no status line.
    var elapsed: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                NativePulseDot()
                Text(label).font(NativeFonts.caption).foregroundStyle(NativeTokens.textTertiary)
            } else {
                NativeShimmerText(text: label)
            }
            if let elapsed {
                Text(elapsed).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit()
            }
        }
        .frame(height: NativeMetrics.workingRowHeight)
        .padding(.leading, 2)
        .accessibilityLabel(label)
    }
}

struct NativePulseDot: View {
    @State private var dim = false
    var body: some View {
        Circle().fill(NativeTokens.accent).frame(width: 6, height: 6)
            .opacity(dim ? 0.3 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { dim = true } }
    }
}

/// bb `animate-shine`: a highlight sweeps across muted text.
struct NativeShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1
    var body: some View {
        Text(text).font(NativeFonts.caption).foregroundStyle(NativeTokens.textTertiary)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, NativeTokens.text.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                }
                .mask(Text(text).font(NativeFonts.caption))
            }
            .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1.2 } }
    }
}

// MARK: Clock

/// Elapsed times the bridge does not provide: the view remembers when it first
/// saw a run, a pending dialog, or a running tool. Times before the view
/// observed them are unknown and stay hidden.
@MainActor
final class NativeThreadClock: ObservableObject {
    @Published var now = Date()
    private(set) var runStarted: Date?
    private(set) var waitStarted: Date?
    private(set) var toolStarts: [String: Date] = [:]
    private(set) var toolEnds: [String: Date] = [:]
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    func observe(_ snapshot: NativeThreadSnapshot?) {
        let now = Date()
        self.now = now
        guard let snapshot else { runStarted = nil; waitStarted = nil; return }
        if snapshot.running { runStarted = runStarted ?? now } else { runStarted = nil }
        if snapshot.dialogs.isEmpty { waitStarted = nil } else { waitStarted = waitStarted ?? now }
        for message in snapshot.provisional {
            guard let id = message.toolCallID else { continue }
            if message.status == "running" {
                toolStarts[id] = toolStarts[id] ?? now
            } else if toolStarts[id] != nil, toolEnds[id] == nil {
                toolEnds[id] = now
            }
        }
        for message in snapshot.messages {
            guard let id = message.toolCallID, toolStarts[id] != nil, toolEnds[id] == nil else { continue }
            toolEnds[id] = now
        }
    }

    func runElapsed(now: Date) -> String { nativeDurationText(now.timeIntervalSince(runStarted ?? now), live: true) }
    func waitingElapsed(now: Date) -> String { nativeDurationText(now.timeIntervalSince(waitStarted ?? now), live: true) }

    /// nil when the view never saw the tool start.
    func toolDuration(_ id: String?, now: Date) -> (text: String, live: Bool)? {
        guard let id, let start = toolStarts[id] else { return nil }
        if let end = toolEnds[id] { return (nativeDurationText(end.timeIntervalSince(start)), false) }
        return (nativeDurationText(now.timeIntervalSince(start), live: true), true)
    }
}

// MARK: Buttons and chips (page 8)

struct NativeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, destructive }
    let kind: Kind
    var size: CGFloat = 30
    init(_ kind: Kind, size: CGFloat = 30) { self.kind = kind; self.size = size }
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        // Page 8 hover states: secondary → bgHover, ghost → bgHoverStrong, primary darkens 6%.
        let lit = hovering || configuration.isPressed
        let fill: Color = switch kind {
        case .primary: NativeTokens.buttonPrimary
        case .secondary: lit ? NativeTokens.bgHover : NativeTokens.bgRaised
        case .ghost: lit ? NativeTokens.bgHoverStrong : .clear
        case .destructive: lit ? NativeTokens.dangerBg : NativeTokens.bgRaised
        }
        let label: Color = switch kind {
        case .primary: NativeTokens.buttonPrimaryLabel
        case .secondary, .ghost: NativeTokens.text
        case .destructive: NativeTokens.dangerText
        }
        configuration.label
            .font(NativeFonts.label)
            .foregroundStyle(label)
            .padding(.horizontal, 12)
            .frame(height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: size >= 32 ? Radius.md : Radius.button))
            .overlay {
                if kind == .primary, lit {
                    RoundedRectangle(cornerRadius: size >= 32 ? Radius.md : Radius.button).fill(.black.opacity(0.06))
                }
                if kind == .secondary || kind == .destructive {
                    RoundedRectangle(cornerRadius: size >= 32 ? Radius.md : Radius.button).strokeBorder(NativeTokens.borderStrong, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = isEnabled && $0 }
    }
}

/// Round 28pt icon button; Send and Stop.
struct NativeIconButtonStyle: ButtonStyle {
    let fill: Color
    let label: Color
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(label)
            .frame(width: NativeMetrics.iconButton, height: NativeMetrics.iconButton)
            .background(fill, in: Circle())
            .overlay { if hovering || configuration.isPressed { Circle().fill(.black.opacity(0.06)) } }
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Circle())
            .onHover { hovering = isEnabled && $0 }
    }
}

/// Ghost 28pt icon button for the turn footer and tool rows.
struct NativeGhostIconStyle: ButtonStyle {
    var size: CGFloat = NativeMetrics.iconButton
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(NativeTokens.textTertiary)
            .frame(width: size, height: size)
            .background(hovering || configuration.isPressed ? NativeTokens.bgHoverStrong : .clear, in: RoundedRectangle(cornerRadius: Radius.button))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct NativeChip: View {
    let text: String
    var menu = false
    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(NativeFonts.caption)
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(NativeTokens.textMuted) }
        }
        .foregroundStyle(NativeTokens.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(NativeTokens.bgHover, in: RoundedRectangle(cornerRadius: Radius.sm))
        .lineLimit(1)
    }
}

/// Accent spinner; a pulsing dot under Reduce Motion.
struct NativeSpinner: View {
    var color: Color = NativeTokens.accent
    var size: CGFloat = 12
    @State private var spinning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().fill(color).frame(width: size / 2, height: size / 2)
                .opacity(spinning ? 0.3 : 1)
                .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { spinning = true } }
        } else {
            Circle().trim(from: 0.15, to: 1)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spinning = true } }
        }
    }
}

/// The one way out of native mode from inside the thread: plain accent text.
struct NativeTerminalLink: View {
    var title = "Terminal"
    /// nil (RPC agents) renders nothing: the surrounding message stands on its own.
    let action: (() -> Void)?
    var color: Color = NativeTokens.accentText
    var body: some View {
        if let action {
            Button(title, action: action).buttonStyle(.plain).font(NativeFonts.caption).foregroundStyle(color)
        }
    }
}

// MARK: Header pieces (page 1, 8)

struct NativeAgentStatusPill: View {
    let pill: NativeAgentPill
    var elapsed: String?

    var body: some View {
        let (fill, text): (Color, Color) = switch pill {
        case .idle: (NativeTokens.successBg, NativeTokens.successText)
        case .running: (NativeTokens.accentBg, NativeTokens.accentText)
        case .needsApproval: (NativeTokens.warningBg, NativeTokens.warningText)
        case .error: (NativeTokens.dangerBg, NativeTokens.dangerText)
        case .stopped: (NativeTokens.bgBubble, NativeTokens.textSecondary)
        }
        HStack(spacing: 5) {
            if pill == .running { NativeSpinner(color: NativeTokens.accent, size: 10) } else {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            Text(pill.label + (elapsed.map { " · \($0)" } ?? "")).font(NativeFonts.caption)
        }
        .foregroundStyle(text)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(fill, in: Capsule())
        .accessibilityLabel("Status: \(pill.label)")
    }

    private var dot: Color {
        switch pill {
        case .idle: NativeTokens.success
        case .running: NativeTokens.accent
        case .needsApproval: NativeTokens.warning
        case .error: NativeTokens.danger
        case .stopped: NativeTokens.textMuted
        }
    }
}

struct NativeModeSwitch: View {
    @Binding var native: Bool
    var body: some View {
        HStack(spacing: 2) {
            segment("Terminal", selected: !native) { native = false }
            segment("Native", selected: native) { native = true }
        }
        .padding(2)
        .background(NativeTokens.bgTrack, in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent presentation")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(selected ? NativeFonts.captionMedium : NativeFonts.caption)
                .foregroundStyle(selected ? NativeTokens.text : NativeTokens.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Radius.sm).fill(NativeTokens.bgRaised)
                            .shadow(color: NativeTokens.thumbShadow, radius: 2, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 52pt header: breadcrumb · pill · spacer · turn count · ModeSwitch · options.
struct NativeThreadHeader: View {
    @ObservedObject var store: NativeThreadStore
    let project: String
    let title: String
    @Binding var native: Bool
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    /// Header-local run clock: "Running · 1m 12s" counts from when this view first saw the run.
    @StateObject private var clock = NativeThreadClock()
    @State private var wide = true
    /// Recounted only when the message list changes length, not on every poll.
    @State private var turnCount = 0

    var body: some View {
        let snapshot = store.snapshot
        // settledRunning holds through tool gaps (F6) so the pill does not flip per poll.
        let pill = nativeAgentPill(running: store.settledRunning, awaitingAnswer: snapshot?.dialogs.isEmpty == false,
                                   error: store.loadError != nil)
        HStack(spacing: 8) {
            Text(project).font(NativeFonts.label).foregroundStyle(NativeTokens.textTertiary).lineLimit(1).fixedSize()
            Text("/").font(NativeFonts.labelRegular).foregroundStyle(NativeTokens.textDisabled)
            // Title gives way last: the pill, count and switch keep their size, the title truncates.
            Text(title).font(NativeFonts.title).foregroundStyle(NativeTokens.text).lineLimit(1).truncationMode(.tail)
                .layoutPriority(-1)
            NativeAgentStatusPill(pill: pill, elapsed: pill == .running ? clock.runElapsed(now: clock.now) : nil)
                .fixedSize()
            Spacer(minLength: 12)
            // Context size comes from pi's session stats (RPC agents only); the terminal bridge has none.
            if let ctx = snapshot?.stats?.contextTokens, wide {
                Text("\(nativeTokenCount(ctx)) ctx").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).fixedSize()
                    .help(nativeContextTooltip(snapshot?.stats))
                    .accessibilityLabel("Context \(nativeTokenCount(ctx)) tokens")
            }
            // The turn count is exact only once the whole history is loaded, and it yields to the
            // title when the header is narrow.
            if store.olderCursor == nil, store.snapshot != nil, wide {
                Text("\(turnCount) turn\(turnCount == 1 ? "" : "s")").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).fixedSize()
            }
            // An RPC agent has no terminal to switch to (D2).
            if showTerminal != nil { NativeModeSwitch(native: $native).fixedSize() }
            Menu {
                Button("Refresh thread") { Task { await store.refresh(fresh: true) } }
                if store.olderCursor != nil {
                    Button("Load older messages") { Task { await store.loadOlder() } }
                }
                Divider()
                if let showTerminal { Button("Show Terminal") { showTerminal() } }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(NativeTokens.textSecondary)
                    .frame(width: NativeMetrics.iconButton, height: NativeMetrics.iconButton)
                    .background(NativeTokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.button))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(NativeTokens.borderStrong, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Thread options")
        }
        .onChange(of: snapshot?.running, initial: true) { _, _ in clock.observe(snapshot) }
        .onChange(of: store.messages.count, initial: true) { _, _ in turnCount = store.messages.count { $0.role == "user" } }
        .onGeometryChange(for: Bool.self) { $0.size.width >= NativeMetrics.threadMaxWidth } action: { wide = $0 }
        .padding(.horizontal, NativeMetrics.headerPadding)
        .frame(height: NativeMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(NativeTokens.bgSurface)
        .overlay(alignment: .bottom) { NativeTokens.border.frame(height: 1) }
    }
}

// MARK: Turns (page 8, §4)

struct NativeUserTurn: View {
    let messages: [NativeThreadMessage]
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(messages, id: \.entryID) { message in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                        if block.kind == .unsupportedImage {
                            Text("Image").font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                        } else {
                            Text(block.text).font(NativeFonts.bodySmall).lineSpacing(NativeFonts.bodySmallLeading).textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(NativeTokens.bgBubble, in: UnevenRoundedRectangle(topLeadingRadius: Radius.xl, bottomLeadingRadius: Radius.xl,
                                                                              bottomTrailingRadius: Radius.xs, topTrailingRadius: Radius.xl))
                .frame(maxWidth: NativeMetrics.userMaxWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("You")
    }
}

struct NativeAgentTurn: View {
    let messages: [NativeThreadMessage]
    let running: Bool
    @ObservedObject var clock: NativeThreadClock
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    /// Subagent cards for this turn, keyed by the spawn call they replace.
    var subagents = NativeSubagentPlacement()
    var subagentActions: NativeSubagentActions? = nil

    @State private var hovering = false

    var body: some View {
        let items = nativeTurnItems(messages)
        let streaming = running && messages.contains { $0.status == "streaming" || $0.status == "running" }
        VStack(alignment: .leading, spacing: NativeMetrics.blockSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                switch item {
                case .thinking(let text):
                    // The working row at the tail carries "Thinking…" (F2); here it is a disclosure only.
                    NativeThinkingDisclosure(text: text)
                case .prose(let text):
                    NativeProse(text: text)
                case .tools(let group):
                    NativeToolGroup(messages: group, clock: clock, showTerminal: showTerminal,
                                    subagents: subagents, subagentActions: subagentActions)
                case .note(let text):
                    HStack(spacing: 8) {
                        Text(text).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                        NativeTerminalLink(action: showTerminal)
                    }
                }
            }
            // Runs with no spawn row in this turn render after it. In strip mode the group already
            // folded them into the strip, unless there was no spawn row to fold them into.
            if let subagentActions, !subagents.trailing.isEmpty,
               subagents.byToolCall.isEmpty || subagents.all.count <= NativeRunsStripSummary.collapseThreshold {
                NativeSubagentStack(runs: subagents.byToolCall.isEmpty ? subagents.all : subagents.trailing, clock: clock, actions: subagentActions)
            }
            if !streaming {
                // Spawn rows the cards replaced are not tool calls the reader can see.
                NativeTurnFooter(messages: messages.filter { $0.toolCallID.map { subagents.byToolCall[$0] == nil } ?? true })
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // bb MessageActionBar: a ghost Copy at the turn's top-right on hover, completed turns only (F10).
        .overlay(alignment: .topTrailing) {
            if hovering, !streaming, !prose.isEmpty {
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(NativeGhostIconStyle(size: 24))
                    .help("Copy this reply as Markdown")
                    .accessibilityLabel("Copy reply")
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent")
    }

    private var prose: String {
        messages.filter { $0.toolName == nil && $0.role != "toolResult" }
            .flatMap(\.blocks).filter { $0.kind == .text }.map(\.text).joined(separator: "\n\n")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prose, forType: .string)
    }
}

struct NativeThinkingDisclosure: View {
    let text: String
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(NativeTokens.textMuted).frame(width: 12)
                    // The bridge carries no thinking duration, so the caption stays "Thought".
                    Text("Thought").font(NativeFonts.caption).italic().foregroundStyle(NativeTokens.textTertiary)
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thought")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text(text).font(NativeFonts.bodySmall).italic().lineSpacing(NativeFonts.bodySmallLeading)
                    .foregroundStyle(NativeTokens.textTertiary).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { NativeTokens.border.frame(width: 2) }
                    .frame(maxWidth: NativeMetrics.proseMaxWidth, alignment: .leading)
            }
        }
    }
}

/// Copy + "N tool calls". The bridge has no timestamps or turn durations and no
/// retry action, so those spec slots stay empty rather than showing fake values.
struct NativeTurnFooter: View {
    let messages: [NativeThreadMessage]
    var body: some View {
        let tools = messages.count { $0.toolName != nil || $0.role == "toolResult" }
        let prose = messages.flatMap(\.blocks).filter { $0.kind == .text }.map(\.text)
        HStack(spacing: 4) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prose.joined(separator: "\n\n"), forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(NativeGhostIconStyle())
            .help("Copy the agent’s reply")
            .accessibilityLabel("Copy reply")
            if tools > 0 {
                Text("\(tools) tool call\(tools == 1 ? "" : "s")").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).padding(.leading, 4)
            }
        }
    }
}

struct NativeProse: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: NativeMetrics.blockSpacing) {
            NativeMarkdownBlocks(blocks: nativeMarkdownBlocks(text))
        }
        .frame(maxWidth: NativeMetrics.proseMaxWidth, alignment: .leading)
    }

    /// Inline Markdown with code runs on `bgHover` in the code face (page 8). A per-run
    /// border is not expressible inside `Text`; the fill alone marks the span.
    static func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = NativeFonts.code
            attributed[run.range].backgroundColor = NativeTokens.bgHover
        }
        return attributed
    }
}

/// Block-level Markdown on the spec's ramp (F7): headings 15/600, lists with an 18pt marker
/// column, quotes on a 2pt rule, fenced code in NativeCodeBlock. One nesting level.
struct NativeMarkdownBlocks: View {
    let blocks: [NativeMarkdownBlock]
    var nested = false

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(_, let text):
                Text(NativeProse.inline(text)).font(NativeFonts.title).lineSpacing(3).textSelection(.enabled)
                    .padding(.top, nested ? 0 : 6)
            case .paragraph(let text):
                Text(NativeProse.inline(text)).font(nested ? NativeFonts.bodySmall : NativeFonts.body)
                    .lineSpacing(nested ? NativeFonts.bodySmallLeading : NativeFonts.bodyLeading).textSelection(.enabled)
            case .quote(let text):
                Text(NativeProse.inline(text)).font(NativeFonts.body).lineSpacing(NativeFonts.bodyLeading).italic()
                    .foregroundStyle(NativeTokens.textSecondary).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { NativeTokens.border.frame(width: 2) }
            case .code(let text):
                NativeCodeBlock(text: text)
            case .rule:
                NativeTokens.border.frame(height: 1).padding(.vertical, 4)
            case .list(let ordered, let start, let items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(ordered ? "\(start + index)." : "•")
                                .font(nested ? NativeFonts.bodySmall : NativeFonts.body).foregroundStyle(NativeTokens.textTertiary)
                                .monospacedDigit()
                                .frame(width: NativeMetrics.listMarker, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(NativeProse.inline(item.text)).font(nested ? NativeFonts.bodySmall : NativeFonts.body)
                                    .lineSpacing(nested ? NativeFonts.bodySmallLeading : NativeFonts.bodyLeading).textSelection(.enabled)
                                NativeMarkdownBlocks(blocks: item.children, nested: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct NativeCodeBlock: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("code").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.plain).font(NativeFonts.micro).foregroundStyle(NativeTokens.textTertiary)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .overlay(alignment: .bottom) { NativeTokens.borderSubtle.frame(height: 1) }
            ScrollView(.horizontal) {
                Text(text.trimmingCharacters(in: .newlines)).font(NativeFonts.code).lineSpacing(3).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTokens.bgMuted, in: RoundedRectangle(cornerRadius: Radius.xs))
        .overlay(RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(NativeTokens.border, lineWidth: 1))
    }
}

// MARK: Tool rows (page 3, §5)

struct NativeToolGroup: View {
    let messages: [NativeThreadMessage]
    @ObservedObject var clock: NativeThreadClock
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    /// Subagent cards replace their spawning shepherd_child_start rows.
    var subagents = NativeSubagentPlacement()
    var subagentActions: NativeSubagentActions? = nil

    var body: some View {
        // 40pt fits pi's builtins (read/edit/bash/grep); longer extension tool names widen the
        // column for the whole group, capped so a silly name cannot eat the preview.
        let longest = messages.compactMap(\.toolName).map(\.count).max() ?? 4
        let nameWidth = min(120, max(40, CGFloat(longest) * 7.6 + 4))
        let segments = subagentActions == nil ? [NativeToolSegment.rows(messages)] : nativeToolSegments(messages, placement: subagents)
        VStack(alignment: .leading, spacing: NativeMetrics.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .rows(let rows): rowGroup(rows, nameWidth: nameWidth)
                case .subagents(let runs):
                    if let subagentActions {
                        NativeSubagentStack(runs: runs, turnLive: subagents.all.contains { !$0.isTerminal }, clock: clock, actions: subagentActions)
                    }
                }
            }
        }
    }

    private func rowGroup(_ rows: [NativeThreadMessage], nameWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.entryID) { index, message in
                if index > 0 { NativeTokens.borderSubtle.frame(height: 1) }
                NativeToolRowView(row: NativeToolRow(message), nameColumnWidth: nameWidth,
                                  duration: clock.toolDuration(message.toolCallID, now: clock.now), showTerminal: showTerminal)
            }
        }
        .background(NativeTokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(NativeTokens.border, lineWidth: 1))
    }
}

struct NativeToolRowView: View {
    let row: NativeToolRow
    /// Shared by every row in a group so previews align.
    var nameColumnWidth: CGFloat = 40
    let duration: (text: String, live: Bool)?
    /// nil for RPC agents: there is no terminal to show, so every handoff link is hidden.
    let showTerminal: (() -> Void)?
    @State private var expanded = false
    @State private var showCall = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxLines = 12

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if NSEvent.modifierFlags.contains(.option), row.arguments != nil { showCall = true; return }
                guard row.expandable else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    glyph.frame(width: 14, height: 14)
                    // Wide enough for pi's builtins and the common extension tools (subagent,
                    // lumen_review); anything longer truncates rather than pushing the preview.
                    Text(row.name).font(NativeFonts.code).foregroundStyle(NativeTokens.textTertiary)
                        .frame(width: nameColumnWidth, alignment: .leading).lineLimit(1).truncationMode(.middle)
                    (Text(row.preview).foregroundStyle(NativeTokens.text) + Text(row.previewSuffix ?? "").foregroundStyle(NativeTokens.textMuted))
                        .font(NativeFonts.code).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        if let diff = row.diff {
                            (Text("+\(diff.added)").foregroundStyle(NativeTokens.successText) + Text(" ") + Text("−\(diff.removed)").foregroundStyle(NativeTokens.dangerText))
                                .font(NativeFonts.micro)
                        }
                        ForEach(Array(row.results.enumerated()), id: \.offset) { _, result in
                            Text(result.text).font(NativeFonts.micro).foregroundStyle(tone(result.tone)).lineLimit(1)
                        }
                        if row.state == .running, row.results.isEmpty {
                            Text("running").font(NativeFonts.micro).foregroundStyle(NativeTokens.accentText)
                        }
                        if let duration {
                            Text(duration.text).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit()
                        }
                        if row.expandable {
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                                .rotationEffect(.degrees(expanded ? 180 : 0)).foregroundStyle(NativeTokens.textMuted).frame(width: 12)
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 12)
                .frame(height: NativeMetrics.toolRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A row with nothing to expand and no call to show is not a control (spec §7).
            .disabled(!row.expandable && row.arguments == nil)
            .contextMenu {
                if row.arguments != nil { Button("Show call") { showCall = true } }
            }
            // Rows with nothing to expand are not controls: no hover fill (F8).
            .onHover { hovering = $0 && row.expandable }
            .popover(isPresented: $showCall) {
                ScrollView {
                    Text(row.arguments ?? "").font(NativeFonts.output).textSelection(.enabled).padding(12)
                }
                .frame(width: 420, height: 240)
            }
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.expandable ? (expanded ? "Expanded" : "Collapsed") : "")
            .accessibilityHint(row.arguments != nil ? "Option-click or right-click shows the raw call" : "")
            if expanded {
                let lines = row.output.split(separator: "\n", omittingEmptySubsequences: false)
                // A running row streams its tail (last 12 lines); a finished one shows its head.
                let live = row.state == .running
                let shown = live ? lines.suffix(Self.maxLines) : lines.prefix(Self.maxLines)
                VStack(alignment: .leading, spacing: 6) {
                    if live, lines.count > Self.maxLines {
                        Text("… \(lines.count - Self.maxLines) earlier lines").font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                    }
                    Text(shown.joined(separator: "\n"))
                        .font(NativeFonts.output).lineSpacing(NativeFonts.outputLeading)
                        .foregroundStyle(NativeTokens.textSecondary).textSelection(.enabled)
                        .animation(nil, value: row.output)
                    if !live, lines.count > Self.maxLines || row.truncated {
                        if showTerminal != nil {
                            NativeTerminalLink(title: lines.count > Self.maxLines ? "… \(lines.count - Self.maxLines) more lines" : "… more in Terminal",
                                               action: showTerminal,
                                               color: row.state == .failed ? NativeTokens.dangerText : NativeTokens.accentText)
                        } else {
                            // RPC agents have no terminal to open; say so plainly.
                            Text(lines.count > Self.maxLines ? "… \(lines.count - Self.maxLines) more lines · output truncated" : "Output truncated")
                                .font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 4, leading: NativeMetrics.toolOutputIndent, bottom: 12, trailing: 12))
            }
        }
        .background(expanded ? (row.state == .failed ? NativeTokens.dangerBg : NativeTokens.bgMuted) : hovering ? NativeTokens.bgHover : .clear)
    }

    @ViewBuilder private var glyph: some View {
        switch row.state {
        // Spec §5: 14pt status glyph, regular/medium weight, never filled.
        case .running: NativeSpinner(color: NativeTokens.accent, size: 14)
        case .done: Image(systemName: "checkmark").font(.system(size: 12, weight: .regular)).foregroundStyle(NativeTokens.success)
        case .failed: Image(systemName: "xmark").font(.system(size: 12, weight: .regular)).foregroundStyle(NativeTokens.danger)
        }
    }

    private func tone(_ tone: NativeToolRow.Tone) -> Color {
        // On an expanded failed row the background is dangerBg, where only dangerText or
        // neutral text is allowed (page 7); success green never sits on it.
        let onDanger = expanded && row.state == .failed
        return switch tone {
        case .success: onDanger ? NativeTokens.textSecondary : NativeTokens.successText
        case .danger: NativeTokens.dangerText
        case .muted: NativeTokens.textMuted
        }
    }
}

// MARK: RPC composer pieces (v2)

func nativeModelShortName(_ model: String) -> String {
    guard let slash = model.firstIndex(of: "/") else { return model }
    return String(model[model.index(after: slash)...])
}

/// "42k" / "1.2M" for the header ctx count.
func nativeTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
    if tokens >= 1_000 { return "\(tokens / 1_000)k" }
    return "\(tokens)"
}

func nativeContextTooltip(_ stats: NativeThreadStats?) -> String {
    guard let stats else { return "" }
    var parts: [String] = []
    if let tokens = stats.contextTokens {
        var line = "\(tokens) context tokens"
        if let window = stats.contextWindow { line += " of \(nativeTokenCount(window))" }
        if let percent = stats.contextPercent { line += " (\(Int(percent.rounded()))%)" }
        parts.append(line)
    }
    if let total = stats.totalTokens { parts.append("\(nativeTokenCount(total)) tokens this session") }
    if let cost = stats.cost { parts.append(String(format: "$%.2f", cost)) }
    return parts.joined(separator: " · ")
}

/// A resized image waiting in the composer. `data` is the bytes pi will receive.
// MARK: Shared helpers

/// Prefer the action's command/path; saved results without arguments show their first output line.
func desktopNativeToolPreview(_ message: NativeThreadMessage) -> String? {
    let row = NativeToolRow(message)
    let text = row.preview.isEmpty ? (message.argumentsText?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") : row.preview
    return text.isEmpty ? nil : String(text.prefix(120))
}

/// Only fenced code and inline Markdown; unsupported block syntax stays readable as source.
func desktopNativeMarkdown(_ text: String) -> [(code: Bool, text: String)] {
    var result: [(code: Bool, text: String)] = []
    var fence: String?
    var lines: [String] = []
    for line in text.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker = String(trimmed.prefix(while: { $0 == "`" }))
        let opens = fence == nil && marker.count >= 3
        let closes = fence.map { marker.count >= $0.count && trimmed == marker } ?? false
        if opens || closes {
            if !lines.isEmpty { result.append((fence != nil, lines.joined(separator: "\n"))) }
            lines = []
            fence = opens ? marker : nil
        } else { lines.append(line) }
    }
    if !lines.isEmpty { result.append((fence != nil, lines.joined(separator: "\n"))) }
    return result
}
