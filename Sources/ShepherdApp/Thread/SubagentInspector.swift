import SwiftUI
import AppKit
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The inspector for one subagent run (Agents board): header, the run's brief, its own
/// transcript one step smaller than the thread, following live, and a Steer composer. A
/// finished run is read-only: its result, "from parent" captions, and Re-run · Fork · Copy.
struct SubagentInspector: View {
    var store: NativeThreadStore
    let runID: String
    let active: Bool
    let close: () -> Void
    /// Step to a sibling run (‹ ›); nil hides the buttons.
    var select: ((ChildRun) -> Void)? = nil
    /// Fork the finished run into a new agent; returns an error to show, nil on success.
    var fork: ((ChildRun) async -> String?)? = nil
    /// Opens a touched file in the review pane.
    var review: ((String) -> Void)? = nil
    @State private var transcript = SubagentTranscriptModel()
    @State private var siblings: [ChildRun] = []
    @State private var draft = ""
    @State private var forkError: String?
    @State private var forking = false
    @State private var copying = false
    @FocusState private var composing: Bool

    private var run: ChildRun? { store.subagents.first { $0.runID == runID } }
    private var canAct: Bool { active && store.supports("subagents") }

    var body: some View {
        let run = run
        VStack(spacing: 0) {
            header(run)
            brief(run)
            transcriptView(run)
            footerLine(run)
            if let run, run.isTerminal { finishedBar(run) } else { composer(run) }
        }
        .background(Color.nw.bgWindow)
        .task(id: FollowKey(runID: runID, active: active, startedAt: run?.startedAt)) {
            guard active else { return }
            let store = store, runID = runID
            await transcript.follow(store: store, runID: runID) { store.subagents.first { $0.runID == runID }?.isTerminal != true }
        }
        .onChange(of: SiblingKey(store: store), initial: true) {
            siblings = nativeSubagentSiblings(of: runID, in: store.subagents, turns: nativeTurns(store.displayedMessages))
        }
        .onChange(of: runID) { _, _ in
            draft = ""
            forkError = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(Self.role(run))")
    }

    private static func role(_ run: ChildRun?) -> String {
        run.map { SubagentPresentation.names($0).name } ?? "subagent"
    }

    /// Restarts the transcript follow when the run, the pane's visibility, or a re-run changes.
    private struct FollowKey: Hashable {
        var runID: String
        var active: Bool
        var startedAt: Double?
    }

    /// Siblings change only when the runs or the parent's history do; the rest of each poll
    /// leaves them alone.
    private struct SiblingKey: Equatable {
        var runs: [String]
        var messages: Int
        var provisional: Int

        @MainActor init(store: NativeThreadStore) {
            runs = store.subagents.map(\.id)
            messages = store.messages.count
            provisional = store.snapshot?.provisional.count ?? 0
        }
    }

    // MARK: Header

    private func header(_ run: ChildRun?) -> some View {
        let position = siblings.firstIndex { $0.runID == runID }
        let (meta, accent) = run.map { SubagentPresentation.inspectorMeta($0) } ?? ("no longer listed", nil)
        let role = Self.role(run)
        return NWInspectorHeader(role, position: position.flatMap { siblings.count > 1 ? "\($0 + 1) of \(siblings.count)" : nil },
                                 state: run.map(SubagentPresentation.state) ?? .idle, meta: meta, accent: accent,
                                 minHeight: AppLayout.headerHeight) {
            if let run, !run.isTerminal {
                Button(run.paused == true ? "Continue" : "Pause") {
                    Task { await store.subagentCommand(runID: runID, action: run.paused == true ? .continue : .pause) }
                }
                .buttonStyle(.nw(.secondary, size: .s))
                .disabled(!canAct)
                .help("Pause before the next model request; current tools finish normally")
                Button("Stop") { Task { await store.subagentCommand(runID: runID, action: .cancel) } }
                    .buttonStyle(.nw(.danger, size: .s))
                    .disabled(!canAct)
                    .accessibilityLabel("Stop \(role)")
                    .padding(.trailing, NW.Space.xs)
            }
            if let select, let position, siblings.count > 1 {
                Button { select(siblings[position - 1]) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.nwIcon).disabled(position == 0)
                    .accessibilityLabel("Previous subagent")
                Button { select(siblings[position + 1]) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.nwIcon).disabled(position == siblings.count - 1)
                    .accessibilityLabel("Next subagent")
            }
            NWOptionsMenu("Inspector options") {
                if let run, run.isTerminal {
                    Button("Copy Transcript") { copyTranscript() }
                    if let file = run.sessionFile {
                        Button("Show Session File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                    }
                } else {
                    Button("Refresh Transcript") { Task { await transcript.reload(store: store, runID: runID) } }
                }
            }
            Button(action: close) { Image(systemName: "xmark") }
                .buttonStyle(.nwIcon)
                .help("Close the inspector")
                .accessibilityLabel("Close inspector")
        }
    }

    // MARK: Brief

    private func brief(_ run: ChildRun?) -> some View {
        let state = run.map(SubagentPresentation.state) ?? .idle
        let result: String? = run.flatMap { run in
            guard run.isTerminal else { return nil }
            let text = state == .failed ? (run.exitReason ?? run.summary) : (run.summary ?? run.output)
            return text?.isEmpty == false ? text : nil
        }
        return NWRunBrief(goal: run?.task ?? run?.label ?? "", note: run.flatMap(SubagentPresentation.goalNote),
                          result: result, resultState: state) {
            if let run, let files = run.files, !files.isEmpty { touchedFiles(files, run: run) }
        }
    }

    private func touchedFiles(_ files: [ChildFileChange], run: ChildRun) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            ForEach(files.prefix(AppLayout.inspectorMaxFiles), id: \.path) { file in
                Button {
                    if let review { review(file.path) } else {
                        let base = run.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path, relativeTo: base).absoluteURL])
                    }
                } label: {
                    HStack(spacing: NW.Space.s) {
                        Text(file.path).foregroundStyle(Color.nw.running).lineLimit(1).truncationMode(.middle)
                        NWDiffStat(added: file.added, removed: file.removed, font: .nwMono(11))
                    }
                    .font(.nwMono(11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(review == nil ? "Reveal in Finder" : "Review this file")
                .accessibilityLabel("\(file.path), \(file.added) added, \(file.removed) removed")
            }
            if files.count > AppLayout.inspectorMaxFiles {
                Text(SubagentPresentation.moreFiles(files.count)).font(.nwMono(11)).foregroundStyle(Color.nw.textTertiary)
            }
        }
    }

    // MARK: Transcript

    private static let bottomID = "inspector-bottom"

    private func transcriptView(_ run: ChildRun?) -> some View {
        let terminal = run?.isTerminal == true
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppLayout.inspectorTurnSpacing) {
                    if transcript.turns.isEmpty, transcript.loaded {
                        Text(run == nil ? "This run is no longer listed." : "No transcript yet.")
                            .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                    }
                    let turns = transcript.turns
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        if turn.isUser {
                            // In the child's session every user message after the first is the
                            // parent (a steer or a resume); the first is the task itself.
                            UserTurn(messages: turn.messages, caption: index > 0 ? parentCaption(turn) : nil)
                        } else {
                            AgentTurn(messages: turn.messages, live: !terminal && run != nil && index == turns.count - 1)
                        }
                    }
                    if let run, !run.isTerminal {
                        WorkingRow(label: run.paused == true ? "Pause requested" : run.currentTool.map { "Running \($0)…" } ?? "Thinking…")
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(AppLayout.inspectorPadding)
                .environment(\.nwProseSize, .small)
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
            .onChange(of: transcript.tail) { _, _ in
                if transcript.following, !terminal { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
        }
    }

    /// "n earlier turns · Show all" · "Following live" (live runs only).
    private func footerLine(_ run: ChildRun?) -> some View {
        HStack(spacing: NW.Space.s) {
            if transcript.earlierCount > 0 {
                Text("\(transcript.earlierCount) earlier turn\(transcript.earlierCount == 1 ? "" : "s")").font(.nwMono(11))
                Button(transcript.loadingOlder ? "Loading…" : "Show all") { Task { await transcript.loadAll(store: store, runID: runID) } }
                    .buttonStyle(.nwLink(font: .nwSans(11)))
                    .disabled(transcript.loadingOlder)
            }
            Spacer()
            if run?.isTerminal != true { Text(transcript.following ? "Following live" : "Reading earlier output") }
        }
        .font(.nwSans(11)).foregroundStyle(Color.nw.textTertiary)
        .padding(.horizontal, AppLayout.inspectorPadding)
        .frame(minHeight: AppLayout.inspectorFooterHeight)
    }

    /// "10:58 · from parent"; the time is omitted when pi gave none.
    private func parentCaption(_ turn: NativeTurn) -> String {
        if let at = turn.messages.first?.timestamp { return "\(nativeClockText(at, meridiem: false)) · from parent" }
        return "from parent"
    }

    // MARK: Footer bars

    private func finishedBar(_ run: ChildRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NWRunActions {
                Button("Re-run") { Task { await store.subagentCommand(runID: runID, action: .resume) } }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(!canAct)
                    .accessibilityLabel("Re-run \(Self.role(run))")
                if let fork {
                    Button {
                        forking = true
                        Task { forkError = await fork(run); forking = false }
                    } label: {
                        Label(forking ? "Forking…" : "Fork", systemImage: "arrow.branch")
                    }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(!active || forking || run.sessionFile == nil)
                    .help("Fork as a new agent with this run's transcript")
                    .accessibilityLabel("Fork \(Self.role(run)) as a new agent")
                }
                Button("Copy transcript") { copyTranscript() }
                    .buttonStyle(.nw(.ghost, size: .s))
                    .disabled(transcript.messages.isEmpty || copying)
            }
            notice(forkError ?? store.notice)
        }
    }

    private func composer(_ run: ChildRun?) -> some View {
        let role = Self.role(run)
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Steer \(role) — delivered before its next turn", text: $draft, axis: .vertical)
                    .lineLimit(1...AppLayout.steerMaxLines).textFieldStyle(.plain).font(.nw(.body)).autocorrectionDisabled()
                    .foregroundStyle(nw.textPrimary).tint(nw.lantern)
                    .focused($composing)
                    .padding(EdgeInsets(top: 10, leading: NW.Space.l, bottom: NW.Space.xxs, trailing: NW.Space.l))
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { draft += "\n"; return .handled }
                        send()
                        return .handled
                    }
                    .accessibilityLabel("Steer \(role)")
                HStack(spacing: NW.Space.s) {
                    Text("to: \(role) · not the parent").font(.nwMono(11)).foregroundStyle(nw.textTertiary)
                        .lineLimit(1).padding(.horizontal, NW.Space.s)
                    Spacer(minLength: NW.Space.s)
                    Button("Steer") { send() }
                        .buttonStyle(.nw(.primary, size: .m))
                        .disabled(!canAct || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(EdgeInsets(top: NW.Space.xs, leading: NW.Space.s, bottom: NW.Space.s, trailing: NW.Space.s))
            }
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwBorder(composing ? nw.textTertiary : nw.lineStrong, radius: NW.Radius.m)
            .background {
                if composing { RoundedRectangle(cornerRadius: NW.Radius.m + 3).fill(nw.bgSelected).padding(-3) }
            }
            .contentShape(Rectangle())
            .onTapGesture { composing = true }
            .padding(EdgeInsets(top: 10, leading: NW.Space.l, bottom: NW.Space.l, trailing: NW.Space.l))
            notice(store.notice)
        }
        .overlay(alignment: .top) { NWHairline() }
    }

    @ViewBuilder private func notice(_ text: String?) -> some View {
        if let text {
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .padding(.horizontal, NW.Space.l).padding(.bottom, NW.Space.m)
        }
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
/// Turns are grouped once per change, and views watch `tail`, not the whole array.
@MainActor @Observable
final class SubagentTranscriptModel {
    /// What a follower needs to know changed: the count and the newest entry.
    struct Tail: Equatable {
        var count = 0
        var lastEntryID: String?
    }

    private(set) var messages: [NativeThreadMessage] = []
    private(set) var turns: [NativeTurn] = []
    private(set) var tail = Tail()
    private(set) var earlierCount = 0
    private(set) var loaded = false
    private(set) var loadingOlder = false
    /// Set while the newest page is at the tail; "Show all" keeps the reader's place instead.
    private(set) var following = true
    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private var runID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var reloadTicket = UUID()

    func setFollowing(_ value: Bool) {
        if following != value { following = value }
    }

    func follow(store: NativeThreadStore, runID: String, live: @escaping () -> Bool) async {
        reset(runID: runID)
        let epoch = generation
        // The thread must be connected first: the transcript request carries its session id.
        while !Task.isCancelled, !store.ready { try? await Task.sleep(for: .milliseconds(100)) }
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
            // A refusal is an answer; a thread that is reconnecting is not.
            if generation == epoch, self.runID == runID, store.ready { setLoaded() }
            return
        }
        guard !Task.isCancelled, generation == epoch, reloadTicket == ticket, self.runID == runID else { return }
        let spliced = Self.splice(messages, newest: page)
        setMessages(spliced.messages)
        if spliced.replaced {
            olderCursor = page.olderCursor
            setEarlierCount(page.earlierCount)
        }
        if page.olderCursor == nil { setEarlierCount(0); olderCursor = nil }
        setLoaded()
    }

    /// Keeps older pages the reader already loaded: the fresh newest page replaces everything
    /// from its first entry on. With no overlap the page replaces the whole transcript.
    nonisolated static func splice(_ current: [NativeThreadMessage], newest page: NativeSubagentTranscript) -> (messages: [NativeThreadMessage], replaced: Bool) {
        if let first = page.messages.first, let overlap = current.firstIndex(where: { $0.entryID == first.entryID }) {
            return (Array(current[..<overlap]) + page.messages, false)
        }
        return (page.messages, true)
    }

    /// Pages backwards until the first entry.
    func loadAll(store: NativeThreadStore, runID: String) async {
        guard !loadingOlder else { return }
        let epoch = generation
        loadingOlder = true
        setFollowing(false)
        defer { if generation == epoch { loadingOlder = false } }
        while !Task.isCancelled, let cursor = olderCursor, self.runID == runID, generation == epoch {
            guard let page = await store.subagentTranscript(runID: runID, beforeEntryID: cursor),
                  !Task.isCancelled, generation == epoch, self.runID == runID else { break }
            guard page.olderCursor != cursor else { break }
            let ids = Set(messages.map(\.entryID))
            setMessages(page.messages.filter { !ids.contains($0.entryID) } + messages)
            olderCursor = page.olderCursor
            setEarlierCount(page.earlierCount)
        }
    }

    private func setMessages(_ value: [NativeThreadMessage]) {
        guard value != messages else { return }
        messages = value
        turns = nativeTurns(value)
        let next = Tail(count: value.count, lastEntryID: value.last?.entryID)
        if next != tail { tail = next }
    }

    private func setEarlierCount(_ value: Int) {
        if earlierCount != value { earlierCount = value }
    }

    private func setLoaded() {
        if !loaded { loaded = true }
    }

    private func reset(runID: String) {
        self.runID = runID
        generation = UUID()
        loadingOlder = false
        setMessages([])
        setEarlierCount(0)
        olderCursor = nil
        loaded = false
        setFollowing(true)
    }
}
