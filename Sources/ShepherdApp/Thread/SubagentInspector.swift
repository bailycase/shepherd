import SwiftUI
import AppKit
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The inspector for one subagent run (Agents board): header, the run's brief, its own
/// transcript one step smaller than the thread, following live, and a Steer composer. A
/// finished run is read-only: its result, "from parent" captions, and Re-run · Fork · Copy.
///
/// Inspecting another run swaps the run in place, whichever path chose it (‹ ›, a card, a
/// strip step, the palette): a sibling nudges in from the side it sits on in spawn order, any
/// other run cross-fades.
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
    /// Focus the Steer field (the tray's Steer asked for it); `steerFocused` says it took it.
    var focusSteer = false
    var steerFocused: () -> Void = {}
    @State private var shown = ShownRun()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The run on screen before `runID` changed; not observed, so remembering it never renders.
    private final class ShownRun {
        var runID: String?
    }

    var body: some View {
        let arrival = arrival
        let edge = arrival?.edge
        ZStack {
            SubagentRunInspector(store: store, runID: runID, siblings: arrival?.siblings ?? [], active: active, close: close,
                                 select: select, fork: fork, review: review, focusSteer: focusSteer, steerFocused: steerFocused)
                .id(runID)
                .transition(.asymmetric(insertion: (edge.map { NW.Motion.list.transition(reduceMotion: reduceMotion, edge: $0) }) ?? .opacity,
                                        removal: .opacity))
        }
        .nwAnimation(edge == nil ? .content : .list, value: runID)
        .onChange(of: runID, initial: true) { _, id in shown.runID = id }
    }

    /// Read only as a run comes on screen, so the store's polls never re-render this view: its
    /// siblings (it opens with its "2 of 3" and ‹ › in place), and the side it arrives from,
    /// trailing for a later sibling of the run it replaces, leading for an earlier one, nil for
    /// any other run.
    private var arrival: (siblings: [ChildRun], edge: Edge?)? {
        guard shown.runID != runID else { return nil }
        let siblings = nativeSubagentSiblings(of: runID, in: store.subagents, turns: nativeTurns(store.displayedMessages))
        guard let previous = shown.runID, let from = siblings.firstIndex(where: { $0.runID == previous }),
              let to = siblings.firstIndex(where: { $0.runID == runID }) else { return (siblings, nil) }
        return (siblings, to > from ? .trailing : .leading)
    }
}

/// One run's inspector; `SubagentInspector` keys it by run, so each run starts fresh (its
/// transcript, draft, and scroll position).
private struct SubagentRunInspector: View {
    var store: NativeThreadStore
    let runID: String
    let active: Bool
    let close: () -> Void
    var select: ((ChildRun) -> Void)?
    var fork: ((ChildRun) async -> String?)?
    var review: ((String) -> Void)?
    let focusSteer: Bool
    let steerFocused: () -> Void
    @State private var transcript = SubagentTranscriptModel()
    @State private var siblings: [ChildRun]
    @State private var draft = ""
    @State private var forkError: String?
    @State private var forking = false
    @State private var copying = false
    @FocusState private var composing: Bool

    init(store: NativeThreadStore, runID: String, siblings: [ChildRun], active: Bool, close: @escaping () -> Void,
         select: ((ChildRun) -> Void)?, fork: ((ChildRun) async -> String?)?, review: ((String) -> Void)?,
         focusSteer: Bool, steerFocused: @escaping () -> Void) {
        self.focusSteer = focusSteer
        self.steerFocused = steerFocused
        self.store = store
        self.runID = runID
        self.active = active
        self.close = close
        self.select = select
        self.fork = fork
        self.review = review
        _siblings = State(initialValue: siblings)
    }

    private var run: ChildRun? { store.subagents.first { $0.runID == runID } }
    private var canAct: Bool { active && store.supports("subagents") }

    var body: some View {
        let run = run
        VStack(spacing: 0) {
            header(run)
            brief(run)
            transcriptView(run)
            footerLine(run)
            if let run, run.isTerminal { finishedBar(run).nwTransition(.content) } else { composer(run).nwTransition(.content) }
        }
        .background(Color.nw.bgWindow)
        // The run's own milestones (paused, needing you, finishing with its result and actions)
        // and a notice under the footer reshape the column; the transcript's growth does not.
        .nwAnimation(.disclosure, value: Phase(run: run, notice: forkError ?? store.notice))
        .task(id: FollowKey(runID: runID, active: active, startedAt: run?.startedAt)) {
            guard active else { return }
            let store = store, runID = runID
            await transcript.follow(store: store, runID: runID) { store.subagents.first { $0.runID == runID }?.isTerminal != true }
        }
        .onChange(of: SiblingKey(store: store)) {
            siblings = nativeSubagentSiblings(of: runID, in: store.subagents, turns: nativeTurns(store.displayedMessages))
        }
        // The tray's Steer opened it: its Steer field takes the keyboard, once.
        .task(id: focusSteer) {
            guard focusSteer else { return }
            await Task.yield()
            composing = true
            steerFocused()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(Self.role(run))")
    }

    /// What reshapes the inspector's column.
    private struct Phase: Equatable {
        var state: AgentState?
        var paused: Bool
        var finished: Bool
        var notice: String?

        init(run: ChildRun?, notice: String?) {
            state = run.map(SubagentPresentation.state)
            paused = run?.paused == true
            finished = run?.isTerminal == true
            self.notice = notice
        }
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
        .nwAnimation(.content, value: siblings.map(\.runID))
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
                        Group {
                            if turn.isUser {
                                // The first user message is the task; later ones are the parent's
                                // steers and resumes, or the user's own.
                                UserTurn(messages: turn.messages, caption: index > 0 ? parentTime(turn) : nil,
                                         note: index > 0 && !transcript.usersTurns.contains(turn.id) ? "from parent" : nil)
                            } else {
                                AgentTurn(messages: turn.messages, live: !terminal && run != nil && index == turns.count - 1)
                            }
                        }
                        // A turn that arrived while the transcript follows fades in where it
                        // lands: the transcript's layout, and so following the tail, changes at once.
                        .nwRunArrival(transcript.arrived.contains(turn.id))
                    }
                    // What the run is doing now (LiveText): its call in flight. It continues the
                    // last turn: under its lines at their spacing, as the thread's live line does
                    // (Subagents). Between calls nothing shows.
                    if let live = run.flatMap(nativeRunLive) {
                        RunLiveTail(burst: live).equatable()
                            .padding(.top, RunLiveTail.gap(after: turns.last) - AppLayout.inspectorTurnSpacing)
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
                    .nwContentTransition(.numeric())
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
        .nwAnimation(.content, value: FooterState(earlier: transcript.earlierCount, loading: transcript.loadingOlder,
                                                  following: transcript.following))
    }

    private struct FooterState: Equatable {
        var earlier: Int
        var loading: Bool
        var following: Bool
    }

    /// "10:58", before "from parent"; nil when pi gave no time.
    private func parentTime(_ turn: NativeTurn) -> String? {
        turn.messages.first?.timestamp.map { nativeClockText($0, meridiem: false) }
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
                    .nwAnimation(.content, value: forking)
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
                    .padding(EdgeInsets(top: AppLayout.steerTopInset, leading: NW.Space.l, bottom: NW.Space.xxs, trailing: NW.Space.l))
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
                if composing {
                    RoundedRectangle(cornerRadius: NW.Radius.m + NWComposerMetrics.focusRing).fill(nw.bgSelected)
                        .padding(-NWComposerMetrics.focusRing)
                }
            }
            .nwAnimation(.hover, value: composing)
            .contentShape(Rectangle())
            .onTapGesture { composing = true }
            .padding(EdgeInsets(top: AppLayout.steerTopInset, leading: NW.Space.l, bottom: NW.Space.l, trailing: NW.Space.l))
            notice(store.notice)
        }
        .overlay(alignment: .top) { NWHairline() }
    }

    @ViewBuilder private func notice(_ text: String?) -> some View {
        if let text {
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .padding(.horizontal, NW.Space.l).padding(.bottom, NW.Space.m)
                .nwTransition(.disclosure)
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
    /// The user turns the user wrote, which are not "from parent".
    private(set) var usersTurns: Set<String> = []
    private(set) var tail = Tail()
    private(set) var earlierCount = 0
    private(set) var loaded = false
    private(set) var loadingOlder = false
    /// Set while the newest page is at the tail; "Show all" keeps the reader's place instead.
    private(set) var following = true
    /// The turns the latest reload added to a transcript already showing turns: they fade in
    /// where they land. The first turns to show ("No transcript yet" giving way) land at once.
    private(set) var arrived: Set<String> = []
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
        setMessages(spliced.messages, marksArrivals: loaded && !messages.isEmpty)
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

    private func setMessages(_ value: [NativeThreadMessage], marksArrivals: Bool = false) {
        guard value != messages else { return }
        let before = Set(turns.map(\.id))
        messages = value
        turns = nativeTurns(value)
        let users = Set(turns.filter { $0.isUser && nativeTranscriptTurnIsTheUsers($0.messages) }.map(\.id))
        if users != usersTurns { usersTurns = users }
        let next = Tail(count: value.count, lastEntryID: value.last?.entryID)
        if next != tail { tail = next }
        // A live reload marks the turns it adds (and keeps the last marks when it adds none);
        // a reset or older pages clear them.
        if marksArrivals {
            let added = Set(turns.map(\.id)).subtracting(before)
            if !added.isEmpty, added != arrived { arrived = added }
        } else if !arrived.isEmpty {
            arrived = []
        }
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

/// The end of a live run's transcript: its call in flight, as the thread's live line. Nothing
/// shows between calls, and nothing spins.
struct RunLiveTail: View, Equatable {
    let burst: NativeActivityBurst

    /// The space above it: an activity line's under the run's lines, a turn part's under its
    /// prose or thinking, and a turn's under a message from the parent.
    static func gap(after turn: NativeTurn?) -> CGFloat {
        guard let turn, !turn.isUser else { return AppLayout.inspectorTurnSpacing }
        if case .activity? = TurnPresentationMemo.presentation(turn.messages, live: false).items.last {
            return AppLayout.activitySpacing
        }
        return AppLayout.turnItemSpacing
    }

    var body: some View {
        ActivityLineView(burst: burst).equatable()
    }
}
