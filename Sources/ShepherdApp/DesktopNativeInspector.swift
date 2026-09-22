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

/// Thread on the left, inspector on the right, a drag handle between. The inspector takes 44%
/// by default (min 420) and remembers user resizing.
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

/// Everything below the header, following the run live while it runs. A terminal run is
/// read-only: RESULT block, from-parent captions, and a Re-run / Fork / Copy bar instead of
/// the steer composer.
struct NativeSubagentInspector: View {
    @ObservedObject var store: NativeThreadStore
    let runID: String
    let active: Bool
    let close: () -> Void
    /// Step to a sibling run (‹ ›); nil hides the buttons.
    var select: ((ChildRun) -> Void)? = nil
    /// Fork the finished run into a new agent; the string is an error to show, nil on success.
    var fork: ((ChildRun) async -> String?)? = nil
    @StateObject private var clock = NativeThreadClock()
    @StateObject private var transcript = NativeSubagentTranscriptModel()
    @State private var draft = ""
    @State private var forkError: String?
    @State private var forking = false
    /// Ids of the turns currently intersecting the viewport, for "turn 4 of 11".
    @State private var visibleTurns: Set<String> = []
    @State private var moreBelow = false
    @State private var userScrolling = false
    @State private var copying = false
    @FocusState private var composing: Bool

    private var run: ChildRun? { store.subagents.first { $0.runID == runID } }
    private var role: String { run?.role ?? run?.label ?? "subagent" }
    private var canAct: Bool { active && store.supports("subagents") }
    private var terminal: Bool { run?.isTerminal == true }
    private var siblings: [ChildRun] { nativeSubagentSiblings(of: runID, in: store.subagents, turns: nativeTurns(store.displayedMessages)) }

    var body: some View {
        VStack(spacing: 0) {
            header
            goal
            if terminal, run != nil { result }
            NativeTokens.border.frame(height: 1)
            transcriptView
            if terminal { turnLine } else { liveTranscriptFooter }
            if terminal { terminalBar } else { composer }
        }
        .font(NativeFonts.body)
        .foregroundStyle(NativeTokens.text)
        .background(NativeTokens.bgSurface)
        .task(id: "\(runID):\(active):\(run?.startedAt ?? 0)") {
            guard active else { return }
            await transcript.follow(store: store, runID: runID) { run?.isTerminal != true }
        }
        .onChange(of: store.snapshot) { _, snapshot in clock.observe(snapshot) }
        .onChange(of: runID) { _, _ in
            draft = ""
            forkError = nil
            visibleTurns = []
            moreBelow = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(role)")
    }

    // MARK: Header

    private var header: some View {
        let state = run.map(nativeSubagentState) ?? .done
        let siblings = siblings
        let position = siblings.firstIndex { $0.runID == runID }
        // Two rows: identity + controls, then the metadata across the full panel width so it
        // is not squeezed between the role and the buttons.
        return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            NativeBranchGlyph(color: nativeSubagentColor(state))
            HStack(spacing: 6) {
                Text(role).font(NativeFonts.label).foregroundStyle(NativeTokens.text).lineLimit(1)
                if let position, siblings.count > 1 {
                    Text("· \(position + 1) of \(siblings.count)").font(NativeFonts.label).foregroundStyle(NativeTokens.textMuted).monospacedDigit()
                }
                if let run, run.isTerminal {
                    Text(stateWord(run)).font(NativeFonts.micro).foregroundStyle(state == .done ? NativeTokens.successText : NativeTokens.dangerText)
                    if let ended = run.endedAt {
                        Text(nativeClockText(ended, meridiem: false)).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if let select, let position, siblings.count > 1 {
                    Button { select(siblings[position - 1]) } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(NativeGhostIconStyle(size: NativeMetrics.subagentCardButton))
                        .disabled(position == 0)
                        .help("Previous subagent")
                        .accessibilityLabel("Previous subagent")
                    Button { select(siblings[position + 1]) } label: { Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium)) }
                        .buttonStyle(NativeGhostIconStyle(size: NativeMetrics.subagentCardButton))
                        .disabled(position == siblings.count - 1)
                        .help("Next subagent")
                        .accessibilityLabel("Next subagent")
                }
                if let run, !run.isTerminal {
                    Button(run.paused == true ? "Continue" : "Pause") {
                        Task { await store.subagentCommand(runID: runID, action: run.paused == true ? .continue : .pause) }
                    }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(!canAct)
                    .help("Pause before the next model request; current tools finish normally")
                    .accessibilityLabel("\(run.paused == true ? "Continue" : "Pause") \(role)")
                    Button("Stop") { Task { await store.subagentCommand(runID: runID, action: .cancel) } }
                        .buttonStyle(NativeButtonStyle(.destructive, size: NativeMetrics.subagentCardButton))
                        .disabled(!canAct)
                        .help("Abort and terminate \(role)")
                        .accessibilityLabel("Stop \(role)")
                }
                Menu {
                    if let run, run.isTerminal {
                        Button("Copy transcript") { copyTranscript() }
                        if let file = run.sessionFile {
                            Button("Open session file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                        }
                        Button("Re-run") { Task { await store.subagentCommand(runID: runID, action: .resume) } }.disabled(!canAct)
                    } else {
                        if let file = run?.sessionFile {
                            Button("Copy session file path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(file, forType: .string)
                            }
                        }
                        Button("Refresh transcript") { Task { await transcript.reload(store: store, runID: runID) } }
                    }
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
        if !meta.isEmpty {
            Text(meta).font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 22).help(meta)
        }
        }
        .padding(.horizontal, NativeMetrics.subagentCardPadding)
        .padding(.vertical, 10)
        .frame(minHeight: NativeMetrics.inspectorHeaderHeight)
        .frame(maxWidth: .infinity)
    }

    /// "background · claude-fable-5-1 · thinking high · 78 turns …"
    private var meta: String {
        guard let run else { return "no longer listed" }
        var parts: [String] = []
        if let context = run.context { parts.append(context) }
        if let model = run.model { parts.append(nativeModelShortName(model)) }
        if let thinking = run.thinking, thinking != "off", !run.isTerminal { parts.append("thinking \(thinking)") }
        let counters = nativeSubagentCounters(run)
        if !counters.isEmpty { parts.append(counters) }
        return parts.joined(separator: " · ")
    }

    /// "done" / "failed" / "stopped" for the terminal header.
    private func stateWord(_ run: ChildRun) -> String {
        run.state == "complete" ? "done" : run.state
    }

    private var transcriptText: String {
        transcript.messages.compactMap { message -> String? in
            if let tool = message.toolName { return "[\(tool)] " + message.blocks.map(\.text).joined(separator: "\n") }
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            return text.isEmpty ? nil : "\(message.role): \(text)"
        }.joined(separator: "\n\n")
    }

    private func copyTranscript() {
        guard !copying else { return }
        copying = true
        let target = runID
        Task {
            await transcript.loadAll(store: store, runID: target)
            defer { copying = false }
            guard target == runID else { return }
            guard transcript.earlierCount == 0 else {
                forkError = "Couldn't load the full transcript. Nothing was copied."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcriptText, forType: .string)
        }
    }

    // MARK: Result (terminal runs)

    private var result: some View {
        let run = run!
        return VStack(alignment: .leading, spacing: 6) {
            Text("RESULT").font(NativeFonts.section).tracking(0.6)
                .foregroundStyle(run.state == "failed" ? NativeTokens.dangerText : NativeTokens.successText)
            if let summary = run.summary ?? run.output, !summary.isEmpty {
                Text(NativeProse.inline(summary)).font(NativeFonts.bodySmall).lineSpacing(NativeFonts.bodySmallLeading)
                    .foregroundStyle(NativeTokens.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } else if let reason = run.exitReason {
                Text(reason).font(NativeFonts.bodySmall).foregroundStyle(NativeTokens.dangerText).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let files = run.files, !files.isEmpty {
                NativeFlow(spacing: 10) {
                    ForEach(files, id: \.path) { file in
                        Button {
                            let url = URL(fileURLWithPath: file.path, relativeTo: run.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }).absoluteURL
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            (Text(file.path).foregroundStyle(NativeTokens.accentText)
                             + Text(" +\(file.added)").foregroundStyle(NativeTokens.successText)
                             + Text(" −\(file.removed)").foregroundStyle(NativeTokens.dangerText))
                                .font(NativeFonts.micro).monospacedDigit().lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal \(file.path) in Finder, \(file.added) added, \(file.removed) removed")
                    }
                }
            }
        }
        .padding(NativeMetrics.inspectorGoalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTokens.bgMuted)
        .overlay(alignment: .bottom) { NativeTokens.borderSubtle.frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Result")
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
                    if terminal, transcript.earlierCount > 0 {
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
                    let turns = nativeTurns(transcript.messages)
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        if turn.isUser {
                            // In the child's session every user message after the first is the
                            // parent (a steer or the resume text); the first is the task itself.
                            let fromParent = terminal && index > 0
                            NativeUserTurn(messages: turn.messages, caption: fromParent ? parentCaption(turn) : nil).id(turn.id)
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    if visible { visibleTurns.insert(turn.id) } else { visibleTurns.remove(turn.id) }
                                }
                        } else {
                            NativeAgentTurn(messages: turn.messages, running: run?.isTerminal == false, clock: clock, showTerminal: nil).id(turn.id)
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    if visible { visibleTurns.insert(turn.id) } else { visibleTurns.remove(turn.id) }
                                }
                        }
                    }
                    if let run, !run.isTerminal {
                        NativeWorkingRow(label: run.paused == true ? "Pause requested" : run.currentTool.map { "Running \($0)…" } ?? "Thinking…")
                    }
                    Color.clear.frame(height: 1).id("inspector-bottom")
                }
                .padding(.horizontal, NativeMetrics.subagentCardPadding)
                .padding(.vertical, NativeMetrics.subagentCardPadding)
            }
            // Content that fits sits at the top (the board shows the first rows under GOAL);
            // a long transcript still opens at the tail and follows live from there.
            .defaultScrollAnchor(terminal ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(transcript.following && !terminal ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height > 4
            } action: { _, below in
                moreBelow = below
                if !below { transcript.setFollowing(true) }
                else if userScrolling { transcript.setFollowing(false) }
            }
            .onScrollPhaseChange { _, phase in userScrolling = phase == .interacting || phase == .decelerating }
            .onChange(of: transcript.messages)  { _, _ in
                if transcript.following, !terminal { proxy.scrollTo("inspector-bottom", anchor: .bottom) }
            }
        }
    }

    private var liveTranscriptFooter: some View {
        HStack(spacing: 6) {
            if transcript.earlierCount > 0 {
                Text("\(transcript.earlierCount) earlier messages")
                Button(transcript.loadingOlder ? "Loading…" : "Show all") {
                    Task { await transcript.loadAll(store: store, runID: runID) }
                }
                .buttonStyle(.plain).foregroundStyle(NativeTokens.accentText)
                .disabled(transcript.loadingOlder)
            }
            Spacer()
            Text(transcript.following ? "Following live" : "Reading earlier output")
        }
        .font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
        .padding(.horizontal, NativeMetrics.subagentCardPadding)
        .frame(height: NativeMetrics.statusLineHeight)
    }

    /// "10:58 · from parent" under a steer bubble; the time is omitted when pi gave none.
    private func parentCaption(_ turn: NativeTurn) -> String {
        if let at = turn.messages.first?.timestamp { return "\(nativeClockText(at, meridiem: false)) · from parent" }
        return "from parent"
    }

    // MARK: Terminal footer + bar

    /// "turn 4 of 11" (the topmost turn in the viewport) · "Scroll for the rest".
    private var turnLine: some View {
        let turns = nativeTurns(transcript.messages)
        let top = turns.firstIndex { visibleTurns.contains($0.id) }
        return HStack {
            if let top { Text("turn \(top + 1) of \(turns.count)").monospacedDigit() }
            Spacer()
            if moreBelow { Text("Scroll for the rest") }
        }
        .font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
        .padding(.horizontal, NativeMetrics.subagentCardPadding)
        .frame(height: NativeMetrics.statusLineHeight)
        .accessibilityElement(children: .combine)
    }

    private var terminalBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("Re-run") { Task { await store.subagentCommand(runID: runID, action: .resume) } }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(!canAct)
                    .help("Resume \(role) with its original task")
                    .accessibilityLabel("Re-run \(role)")
                if let fork, let run {
                    Button(forking ? "Forking…" : "Fork as new agent") {
                        forking = true
                        Task { forkError = await fork(run); forking = false }
                    }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(!active || forking || run.sessionFile == nil)
                    .help("Start a new agent that continues this transcript")
                    .accessibilityLabel("Fork \(role) as new agent")
                }
                Button("Copy transcript") { copyTranscript() }
                    .buttonStyle(NativeButtonStyle(.secondary, size: NativeMetrics.subagentCardButton))
                    .disabled(transcript.messages.isEmpty || copying)
                    .accessibilityLabel("Copy \(role) transcript")
                Spacer(minLength: 8)
                Text("kept with the thread").font(NativeFonts.micro).foregroundStyle(NativeTokens.textMuted)
            }
            if let notice = forkError ?? store.notice {
                Text(notice).font(NativeFonts.caption).foregroundStyle(NativeTokens.textMuted)
            }
        }
        .padding(NativeMetrics.subagentCardPadding)
        .overlay(alignment: .top) { NativeTokens.border.frame(height: 1) }
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
        let target = runID
        Task {
            await store.subagentCommand(runID: target, action: .message, text: text, mode: .steer)
            if target == runID, store.notice == nil, draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
        }
    }
}

/// Left-to-right wrapping row for the RESULT block's file links.
struct NativeFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, place(in: bounds.width, subviews: subviews).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + 4; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
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
    @Published private(set) var following = true
    private var olderCursor: String?
    private var runID: String?
    private var generation = UUID()
    private var reloadTicket = UUID()

    func setFollowing(_ value: Bool) { following = value }

    func follow(store: NativeThreadStore, runID: String, live: @escaping () -> Bool) async {
        reset(runID: runID)
        let epoch = generation
        // The thread must be connected first: the transcript request carries its session id.
        while !Task.isCancelled, store.snapshot == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard !Task.isCancelled, generation == epoch else { return }
        await reload(store: store, runID: runID)
        while !Task.isCancelled, generation == epoch {
            try? await Task.sleep(for: store.pollInterval)
            guard !Task.isCancelled, generation == epoch else { return }
            await reload(store: store, runID: runID)
            if !live() { break }
        }
    }

    func reload(store: NativeThreadStore, runID: String) async {
        let epoch = generation
        let ticket = UUID()
        reloadTicket = ticket
        guard let page = await store.subagentTranscript(runID: runID) else {
            if generation == epoch, self.runID == runID { loaded = true }
            return
        }
        guard !Task.isCancelled, generation == epoch, reloadTicket == ticket, self.runID == runID else { return }
        // Keep older pages the reader already loaded: splice the fresh newest page over its overlap.
        if let first = page.messages.first, let overlap = messages.firstIndex(where: { $0.entryID == first.entryID }) {
            messages = Array(messages[..<overlap]) + page.messages
        } else {
            messages = page.messages
            olderCursor = page.olderCursor
            earlierCount = page.earlierCount
        }
        if page.olderCursor == nil { earlierCount = 0; olderCursor = nil }
        loaded = true
    }

    /// Pages backwards until the first entry.
    func loadAll(store: NativeThreadStore, runID: String) async {
        guard !loadingOlder else { return }
        let epoch = generation
        loadingOlder = true
        following = false
        defer { if generation == epoch { loadingOlder = false } }
        while !Task.isCancelled, let cursor = olderCursor, self.runID == runID, generation == epoch {
            guard let page = await store.subagentTranscript(runID: runID, beforeEntryID: cursor),
                  !Task.isCancelled, generation == epoch, self.runID == runID else { break }
            guard page.olderCursor != cursor else { break }
            let ids = Set(messages.map(\.entryID))
            messages = page.messages.filter { !ids.contains($0.entryID) } + messages
            olderCursor = page.olderCursor
            earlierCount = page.earlierCount
        }
    }

    private func reset(runID: String) {
        self.runID = runID
        generation = UUID()
        loadingOlder = false
        messages = []
        earlierCount = 0
        olderCursor = nil
        loaded = false
        following = true
    }
}
