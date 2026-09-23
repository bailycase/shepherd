import SwiftUI
import AppKit
import ShepherdCore
import ShepherdDesign
import ShepherdProtocol
import ShepherdRemote

/// The inspector for one subagent run (spec §10): header, Goal strip, the run's own transcript
/// one step smaller than the thread, following live, and a Steer composer. A finished run is
/// read-only: a Result block, "from parent" captions, and Re-run / Fork / Copy instead.
struct SubagentInspector: View {
    @ObservedObject var store: NativeThreadStore
    let runID: String
    let active: Bool
    let close: () -> Void
    /// Step to a sibling run (‹ ›); nil hides the buttons.
    var select: ((ChildRun) -> Void)? = nil
    /// Fork the finished run into a new agent; returns an error to show, nil on success.
    var fork: ((ChildRun) async -> String?)? = nil
    /// Opens a touched file in the review pane.
    var review: ((String) -> Void)? = nil
    @StateObject private var transcript = SubagentTranscriptModel()
    @State private var draft = ""
    @State private var forkError: String?
    @State private var forking = false
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
            if terminal, let run { result(run) }
            Tokens.border.frame(height: 1)
            transcriptView
            footerLine
            if terminal { terminalBar } else { composer }
        }
        .background(Tokens.bgSurface)
        .task(id: "\(runID):\(active):\(run?.startedAt ?? 0)") {
            guard active else { return }
            await transcript.follow(store: store, runID: runID) { run?.isTerminal != true }
        }
        .onChange(of: runID) { _, _ in
            draft = ""
            forkError = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(role)")
    }

    // MARK: Header

    private var header: some View {
        let state = run.map(nativeSubagentState) ?? .done
        let siblings = siblings
        let position = siblings.firstIndex { $0.runID == runID }
        return HStack(spacing: 10) {
            BranchGlyph(SubagentStyle.color(state))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(role).font(Fonts.labelStrong).foregroundStyle(Tokens.text).lineLimit(1)
                    if let position, siblings.count > 1 {
                        Text("\(position + 1) of \(siblings.count)").font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit()
                    }
                    if let run, run.isTerminal {
                        Text(run.state == "complete" ? "done" : run.state).font(Fonts.micro)
                            .foregroundStyle(state == .done ? Tokens.successText : Tokens.dangerText)
                    }
                }
                Text(meta).font(Fonts.micro).foregroundStyle(Tokens.textMuted).lineLimit(1).truncationMode(.tail).help(meta)
            }
            Spacer(minLength: 8)
            if let select, let position, siblings.count > 1 {
                HStack(spacing: 2) {
                    Button { select(siblings[position - 1]) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(IconButtonStyle(bordered: false)).disabled(position == 0)
                        .accessibilityLabel("Previous subagent")
                    Button { select(siblings[position + 1]) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(IconButtonStyle(bordered: false)).disabled(position == siblings.count - 1)
                        .accessibilityLabel("Next subagent")
                }
            }
            if let run, !run.isTerminal {
                Button(run.paused == true ? "Continue" : "Pause") {
                    Task { await store.subagentCommand(runID: runID, action: run.paused == true ? .continue : .pause) }
                }
                .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                .disabled(!canAct)
                Button("Stop") { Task { await store.subagentCommand(runID: runID, action: .cancel) } }
                    .buttonStyle(ShepherdButtonStyle(.destructive, size: .small))
                    .disabled(!canAct)
                    .accessibilityLabel("Stop \(role)")
            }
            Menu {
                if let run, run.isTerminal {
                    Button("Copy Transcript") { copyTranscript() }
                    if let file = run.sessionFile {
                        Button("Show Session File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                    }
                } else {
                    Button("Refresh Transcript") { Task { await transcript.reload(store: store, runID: runID) } }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(Tokens.text)
                    .frame(width: Metrics.buttonSmall, height: Metrics.buttonSmall)
                    .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.button))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button).strokeBorder(Tokens.borderStrong, lineWidth: 1))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Inspector options")
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(IconButtonStyle(bordered: false))
                .help("Close the inspector")
                .accessibilityLabel("Close inspector")
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.headerHeight)
        .overlay(alignment: .bottom) { Tokens.border.frame(height: 1) }
    }

    /// "background · claude-fable-5-1 · thinking high · 78 turns · 82 tools · 922k tok"
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

    // MARK: Goal and result

    private var goal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Goal").sectionStyle()
                Spacer()
                if let run {
                    Text(stepText(run)).font(Fonts.micro).foregroundStyle(Tokens.textMuted).monospacedDigit()
                }
            }
            Text(run?.task ?? run?.label ?? "").font(Fonts.bodySmall).lineSpacing(Fonts.bodySmallLeading)
                .foregroundStyle(Tokens.text).textSelection(.enabled)
                .lineLimit(6).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Tokens.bgMuted)
        .accessibilityElement(children: .combine)
    }

    private func stepText(_ run: ChildRun) -> String {
        var parts: [String] = []
        if let step = run.step { parts.append("step \(step.index) / \(step.total)") }
        if let percent = run.contextPercent { parts.append("\(Int(percent.rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private func result(_ run: ChildRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Result").sectionStyle().foregroundStyle(run.state == "complete" ? Tokens.successText : Tokens.dangerText)
            if let summary = run.summary ?? run.output, !summary.isEmpty {
                Text(Prose.inline(summary)).font(Fonts.bodySmall).lineSpacing(Fonts.bodySmallLeading)
                    .foregroundStyle(Tokens.text).textSelection(.enabled).lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let reason = run.exitReason {
                Text(reason).font(Fonts.bodySmall).foregroundStyle(Tokens.dangerText).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let files = run.files, !files.isEmpty {
                FlowLayout(spacing: 12) {
                    ForEach(files, id: \.path) { file in
                        Button {
                            if let review { review(file.path) } else {
                                let url = URL(fileURLWithPath: file.path, relativeTo: run.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }).absoluteURL
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(file.path).font(Fonts.micro).foregroundStyle(Tokens.accentText).lineLimit(1)
                                DiffStat(added: file.added, removed: file.removed)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(review == nil ? "Reveal in Finder" : "Review this file")
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.bgMuted)
        .overlay(alignment: .top) { Tokens.borderSubtle.frame(height: 1) }
    }

    // MARK: Transcript

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if transcript.messages.isEmpty, transcript.loaded {
                        Text(run == nil ? "This run is no longer listed." : "No transcript yet.").font(Fonts.caption).foregroundStyle(Tokens.textMuted)
                    }
                    let turns = nativeTurns(transcript.messages)
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        if turn.isUser {
                            // In the child's session every user message after the first is the
                            // parent (a steer or a resume); the first is the task itself.
                            UserTurn(messages: turn.messages, caption: index > 0 ? parentCaption(turn) : nil, small: true).id(turn.id)
                        } else {
                            AgentTurn(messages: turn.messages, live: run?.isTerminal == false && index == turns.count - 1, small: true).id(turn.id)
                        }
                    }
                    if let run, !run.isTerminal {
                        WorkingRow(label: run.paused == true ? "Pause requested" : run.currentTool.map { "Running \($0)…" } ?? "Thinking…")
                    }
                    Color.clear.frame(height: 1).id("inspector-bottom")
                }
                .padding(14)
            }
            .defaultScrollAnchor(terminal ? .top : .bottom, for: .initialOffset)
            .defaultScrollAnchor(transcript.following && !terminal ? .bottom : nil, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ThreadView.distanceFromBottom(geometry) > NativeScrollFollower.threshold
            } action: { _, below in
                if !below { transcript.setFollowing(true) }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { transcript.setFollowing(false) }
            }
            .onChange(of: transcript.messages) { _, _ in
                if transcript.following, !terminal { proxy.scrollTo("inspector-bottom", anchor: .bottom) }
            }
        }
    }

    /// "n earlier turns · Show all" · "Following live" (live) or the turn count (finished).
    private var footerLine: some View {
        HStack(spacing: 6) {
            if transcript.earlierCount > 0 {
                Text("\(transcript.earlierCount) earlier turn\(transcript.earlierCount == 1 ? "" : "s")")
                Button(transcript.loadingOlder ? "Loading…" : "Show all") { Task { await transcript.loadAll(store: store, runID: runID) } }
                    .buttonStyle(LinkButtonStyle(font: Fonts.micro))
                    .disabled(transcript.loadingOlder)
            }
            Spacer()
            if !terminal { Text(transcript.following ? "Following live" : "Reading earlier output") }
        }
        .font(Fonts.micro).foregroundStyle(Tokens.textMuted)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    /// "10:58 · from parent"; the time is omitted when pi gave none.
    private func parentCaption(_ turn: NativeTurn) -> String {
        if let at = turn.messages.first?.timestamp { return "\(nativeClockText(at, meridiem: false)) · from parent" }
        return "from parent"
    }

    // MARK: Footer bars

    private var terminalBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("Re-run") { Task { await store.subagentCommand(runID: runID, action: .resume) } }
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                    .disabled(!canAct)
                    .accessibilityLabel("Re-run \(role)")
                if let fork, let run {
                    Button(forking ? "Forking…" : "Fork as new agent") {
                        forking = true
                        Task { forkError = await fork(run); forking = false }
                    }
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                    .disabled(!active || forking || run.sessionFile == nil)
                }
                Button("Copy transcript") { copyTranscript() }
                    .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                    .disabled(transcript.messages.isEmpty || copying)
                Spacer(minLength: 8)
                Text("kept with the thread").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
            }
            if let notice = forkError ?? store.notice {
                Text(notice).font(Fonts.caption).foregroundStyle(Tokens.textMuted)
            }
        }
        .padding(14)
        .overlay(alignment: .top) { Tokens.border.frame(height: 1) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Steer \(role) — delivered before its next turn", text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).font(Fonts.bodySmall).autocorrectionDisabled()
                .focused($composing)
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 6, trailing: 14))
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { draft += "\n"; return .handled }
                    send()
                    return .handled
                }
                .accessibilityLabel("Message to \(role)")
            HStack {
                Text("to: \(role) · not the parent").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                Spacer()
                Button("Steer") { send() }
                    .buttonStyle(ShepherdButtonStyle(.primary, size: .small))
                    .disabled(!canAct || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 8))
            if let notice = store.notice {
                Text(notice).font(Fonts.caption).foregroundStyle(Tokens.textMuted).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .background(Tokens.bgRaised, in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl).strokeBorder(composing ? Tokens.accent : Tokens.borderStrong, lineWidth: 1))
        .background(RoundedRectangle(cornerRadius: Radius.xl + 3).fill(composing ? Tokens.focusRing : .clear).padding(-3))
        .padding(12)
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
            let text = transcript.messages.compactMap { message -> String? in
                if let tool = message.toolName { return "[\(tool)] " + message.blocks.map(\.text).joined(separator: "\n") }
                let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                return text.isEmpty ? nil : "\(message.role): \(text)"
            }.joined(separator: "\n\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}

/// Pages of one child's transcript. Reloads on the store's cadence while the run lives; a
/// reload keeps everything already paged in (older pages are fetched only on "Show all").
@MainActor
final class SubagentTranscriptModel: ObservableObject {
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
