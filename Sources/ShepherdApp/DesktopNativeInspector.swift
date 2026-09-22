import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The side-panel inspector for one native subagent run (docs/design-spec/subagents-with-inspector.png):
// header · GOAL block · the child's transcript rendered with the thread's own components ·
// its own steer composer. Read-mostly; steering and stopping go to the children extension.

/// Which run an RPC agent's workspace is inspecting. Device-local view state; the panel width
/// is remembered across launches, the selection is not.
@MainActor @Observable
final class NativeInspectorState {
    static let widthKey = "shepherd.subagentInspectorWidth"
    var runByAgent: [AgentID: String] = [:]
    var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.widthKey)
        width = saved >= NativeMetrics.inspectorMinWidth ? CGFloat(saved) : 0
    }

    func toggle(agentID: AgentID, runID: String) {
        if runByAgent[agentID] == runID { runByAgent.removeValue(forKey: agentID) } else { runByAgent[agentID] = runID }
    }
}

/// Thread on the left, inspector on the right, a drag handle between. The inspector takes 60%
/// by default (min 420) and remembers its width.
struct NativeInspectorSplit<Thread: View, Inspector: View>: View {
    @Bindable var state: NativeInspectorState
    let showInspector: Bool
    @ViewBuilder let thread: () -> Thread
    @ViewBuilder let inspector: () -> Inspector
    @State private var liveWidth: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let stored = state.width > 0 ? state.width : (total * NativeMetrics.inspectorDefaultFraction).rounded()
            let width = min(max(liveWidth ?? stored, NativeMetrics.inspectorMinWidth), max(NativeMetrics.inspectorMinWidth, total - NativeMetrics.inspectorMinWidth))
            HStack(spacing: 0) {
                thread().frame(width: showInspector ? total - width - 1 : total)
                if showInspector {
                    NativeTokens.border.frame(width: 1)
                        .overlay {
                            Color.clear.frame(width: 9).contentShape(Rectangle())
                                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("inspector-split"))
                                    .onChanged { liveWidth = total - $0.location.x }
                                    .onEnded { _ in
                                        if let liveWidth { state.width = min(max(liveWidth, NativeMetrics.inspectorMinWidth), total - NativeMetrics.inspectorMinWidth) }
                                        liveWidth = nil
                                    })
                        }
                        .zIndex(1)
                        .accessibilityLabel("Resize inspector")
                    inspector().frame(width: width)
                }
            }
        }
        .coordinateSpace(name: "inspector-split")
    }
}

/// Everything below the header, following the run live while it runs.
struct NativeSubagentInspector: View {
    @ObservedObject var store: NativeThreadStore
    let runID: String
    let active: Bool
    let close: () -> Void
    @StateObject private var clock = NativeThreadClock()
    @StateObject private var transcript = NativeSubagentTranscriptModel()
    @State private var draft = ""
    @FocusState private var composing: Bool

    private var run: ChildRun? { store.subagents.first { $0.runID == runID } }
    private var role: String { run?.role ?? run?.label ?? "subagent" }
    private var canAct: Bool { active && store.supports("subagents") }

    var body: some View {
        VStack(spacing: 0) {
            header
            goal
            NativeTokens.border.frame(height: 1)
            transcriptView
            composer
        }
        .font(NativeFonts.body)
        .foregroundStyle(NativeTokens.text)
        .background(NativeTokens.bgSurface)
        .task(id: "\(runID):\(active)") {
            guard active else { return }
            await transcript.follow(store: store, runID: runID) { run?.isTerminal != true }
        }
        .onChange(of: store.snapshot) { _, snapshot in clock.observe(snapshot) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(role)")
    }

    // MARK: Header

    private var header: some View {
        let state = run.map(nativeSubagentState) ?? .done
        return HStack(alignment: .top, spacing: 8) {
            NativeBranchGlyph(color: nativeSubagentColor(state)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(role).font(NativeFonts.label).foregroundStyle(NativeTokens.text).lineLimit(1)
                Text(meta).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let run, !run.isTerminal {
                    Button("Stop") { Task { await store.subagentCommand(runID: runID, action: .cancel) } }
                        .buttonStyle(NativeButtonStyle(.destructive, size: NativeMetrics.subagentCardButton))
                        .disabled(!canAct)
                        .help("Abort and terminate \(role)")
                        .accessibilityLabel("Stop \(role)")
                }
                Menu {
                    if let run, run.isTerminal {
                        Button("Resume with original task") { Task { await store.subagentCommand(runID: runID, action: .resume) } }.disabled(!canAct)
                    }
                    if let file = run?.sessionFile {
                        Button("Copy session file path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file, forType: .string)
                        }
                    }
                    Button("Refresh transcript") { Task { await transcript.reload(store: store, runID: runID) } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(NativeTokens.textSecondary)
                        .frame(width: NativeMetrics.subagentCardButton, height: NativeMetrics.subagentCardButton)
                        .background(NativeTokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.button))
                        .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(NativeTokens.borderStrong, lineWidth: 1))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Inspector options")
                Button { close() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(NativeGhostIconStyle(size: NativeMetrics.subagentCardButton))
                .keyboardShortcut("i", modifiers: .command)
                .help("Close the inspector (⌘I)")
                .accessibilityLabel("Close inspector")
            }
        }
        .padding(.horizontal, NativeMetrics.subagentCardPadding)
        .frame(height: NativeMetrics.inspectorHeaderHeight)
        .frame(maxWidth: .infinity)
    }

    /// "background · claude-fable-5-1 · thinking high · 78 turns …"
    private var meta: String {
        guard let run else { return "no longer listed" }
        var parts: [String] = []
        if let context = run.context { parts.append(context) }
        if let model = run.model { parts.append(nativeModelShortName(model)) }
        if let thinking = run.thinking, thinking != "off" { parts.append("thinking \(thinking)") }
        let counters = nativeSubagentCounters(run)
        if !counters.isEmpty { parts.append(counters) }
        return parts.joined(separator: " · ")
    }

    // MARK: Goal

    private var goal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GOAL").font(NativeFonts.section).tracking(0.6).foregroundStyle(NativeTokens.textTertiary)
                Spacer()
                if let run {
                    Text(stepText(run)).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit()
                }
            }
            Text(run?.task ?? run?.label ?? "").font(NativeFonts.bodySmall).lineSpacing(NativeFonts.bodySmallLeading)
                .foregroundStyle(NativeTokens.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(NativeMetrics.inspectorGoalPadding)
        .frame(maxWidth: .infinity)
        .background(NativeTokens.bgMuted)
        .accessibilityElement(children: .combine)
    }

    /// "step 1 / 1 · 62%": the step when part of a workflow, the child's context fill when known.
    private func stepText(_ run: ChildRun) -> String {
        var parts: [String] = []
        if let step = run.step { parts.append("step \(step.index) / \(step.total)") }
        if let percent = run.contextPercent { parts.append("\(Int(percent.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    // MARK: Transcript

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NativeMetrics.turnSpacing) {
                    if transcript.earlierCount > 0 {
                        HStack(spacing: 6) {
                            Text("\(transcript.earlierCount) earlier turn\(transcript.earlierCount == 1 ? "" : "s")").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
                            Button(transcript.loadingOlder ? "Loading…" : "Show all") { Task { await transcript.loadAll(store: store, runID: runID) } }
                                .buttonStyle(.plain).font(NativeFonts.caption).foregroundStyle(NativeTokens.accentText)
                                .disabled(transcript.loadingOlder)
                                .accessibilityLabel("Show all earlier turns")
                        }
                    }
                    if transcript.messages.isEmpty, transcript.loaded {
                        Text(run == nil ? "This run is no longer listed." : "No transcript yet.").font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
                    }
                    ForEach(nativeTurns(transcript.messages)) { turn in
                        if turn.isUser {
                            NativeUserTurn(messages: turn.messages).id(turn.id)
                        } else {
                            NativeAgentTurn(messages: turn.messages, running: run?.isTerminal == false, clock: clock, showTerminal: nil).id(turn.id)
                        }
                    }
                    if let run, !run.isTerminal {
                        NativeWorkingRow(label: run.currentTool.map { "Running \($0)…" } ?? "Thinking…")
                    }
                    Color.clear.frame(height: 1).id("inspector-bottom")
                }
                .padding(.horizontal, NativeMetrics.subagentCardPadding)
                .padding(.vertical, NativeMetrics.subagentCardPadding)
            }
            // Content that fits sits at the top (the board shows the first rows under GOAL);
            // a long transcript still opens at the tail and follows live from there.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(transcript.following ? .bottom : nil, for: .sizeChanges)
            .onChange(of: transcript.messages.count) { _, _ in
                if transcript.following { proxy.scrollTo("inspector-bottom", anchor: .bottom) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if run?.isTerminal == false {
                Text("Following live").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
                    .padding(.horizontal, NativeMetrics.subagentCardPadding).padding(.bottom, 6)
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        let live = run?.isTerminal == false
        return VStack(alignment: .leading, spacing: 10) {
            TextField(live ? "Steer \(role) — delivered before its next turn" : "Reply to \(role) — resumes its session", text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).font(NativeFonts.bodySmall).autocorrectionDisabled()
                .focused($composing)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { draft += "\n"; return .handled }
                    send()
                    return .handled
                }
                .accessibilityLabel("Message to \(role)")
            HStack {
                Text("to: \(role) · not the parent").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
                Spacer()
                Button(live ? "Steer" : "Reply") { send() }
                    .buttonStyle(NativeButtonStyle(.primary, size: NativeMetrics.subagentCardButton))
                    .disabled(!canAct || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(live ? "Steer \(role)" : "Reply to \(role)")
            }
            if let notice = store.notice {
                Text(notice).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(NativeTokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(composing ? NativeTokens.accent : NativeTokens.borderStrong, lineWidth: 1))
        .padding(NativeMetrics.subagentCardPadding)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAct, !text.isEmpty else { return }
        draft = ""
        Task { await store.subagentCommand(runID: runID, action: .message, text: text, mode: .steer) }
    }
}

/// Pages of one child's transcript. Reloads on the store's cadence while the run lives; a
/// reload keeps everything already paged in (older pages are re-fetched only on "Show all").
@MainActor
final class NativeSubagentTranscriptModel: ObservableObject {
    @Published private(set) var messages: [NativeThreadMessage] = []
    @Published private(set) var earlierCount = 0
    @Published private(set) var loaded = false
    @Published private(set) var loadingOlder = false
    /// Set while the newest page is at the tail; "Show all" keeps the reader's place instead.
    private(set) var following = true
    private var olderCursor: String?
    private var runID: String?

    func follow(store: NativeThreadStore, runID: String, live: @escaping () -> Bool) async {
        if self.runID != runID { reset(runID: runID) }
        // The thread must be connected first: the transcript request carries its session id.
        while !Task.isCancelled, store.snapshot == nil { try? await Task.sleep(for: .milliseconds(100)) }
        await reload(store: store, runID: runID)
        while !Task.isCancelled {
            try? await Task.sleep(for: store.pollInterval)
            guard !Task.isCancelled else { return }
            await reload(store: store, runID: runID)
            if !live() { break }
        }
    }

    func reload(store: NativeThreadStore, runID: String) async {
        guard let page = await store.subagentTranscript(runID: runID) else { loaded = true; return }
        guard self.runID == runID else { return }
        // Keep older pages the reader already loaded: splice the fresh newest page over its overlap.
        if let first = page.messages.first, let overlap = messages.firstIndex(where: { $0.entryID == first.entryID }) {
            messages = Array(messages[..<overlap]) + page.messages
        } else {
            messages = page.messages
            olderCursor = page.olderCursor
            earlierCount = page.earlierCount
        }
        if page.olderCursor == nil { earlierCount = 0 }
        loaded = true
    }

    /// Pages backwards until the first entry.
    func loadAll(store: NativeThreadStore, runID: String) async {
        guard !loadingOlder else { return }
        loadingOlder = true
        following = false
        defer { loadingOlder = false }
        while let cursor = olderCursor, self.runID == runID {
            guard let page = await store.subagentTranscript(runID: runID, beforeEntryID: cursor) else { break }
            let ids = Set(messages.map(\.entryID))
            messages = page.messages.filter { !ids.contains($0.entryID) } + messages
            olderCursor = page.olderCursor
            earlierCount = page.earlierCount
        }
    }

    private func reset(runID: String) {
        self.runID = runID
        messages = []
        earlierCount = 0
        olderCursor = nil
        loaded = false
        following = true
    }
}
