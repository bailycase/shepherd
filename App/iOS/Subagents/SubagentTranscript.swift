import SwiftUI
import UIKit
import Observation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// One run's transcript (`subagentTranscript`), paged newest first: the newest page reloads on the
/// thread's cadence while the run lives and keeps the older pages already read in. Turns and
/// their presentation are derived once per change; views read them.
@MainActor
@Observable
final class SubagentTranscriptModel {
    struct Turn: Identifiable, Equatable {
        var id: String
        /// A user turn: the task (the first), then the parent's steers and resumes, or the
        /// user's own messages.
        var user: [String]
        var userTime: Double?
        /// Captioned "from parent": every user turn but the ones the user wrote.
        var fromParent = false
        /// An agent turn's items.
        var presentation: NativeTurnPresentation?
        var live: Bool
    }

    private(set) var messages: [NativeThreadMessage] = []
    private(set) var turns: [Turn] = []
    private(set) var earlierCount = 0
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var loading = false
    private(set) var loadingOlder = false
    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private var runID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var live = false
    /// The liveness the turns were last derived with: a run that stops without another message
    /// still redraws its last turn settled.
    @ObservationIgnored private var derivedLive = false
    /// Older pages read in by "Show all" land this many at a time, so a long run is regrouped a
    /// few times, not once per page.
    static let loadAllBatch = 4
    /// Each agent turn's presentation, kept while its messages and liveness stand.
    @ObservationIgnored private var presentations: [String: (messages: [NativeThreadMessage], live: Bool, value: NativeTurnPresentation)] = [:]

    /// Follows `runID` until the task ends: a first page once the thread is ready, then a reload
    /// per poll interval while `isLive()` holds, and one more after it stops.
    func follow(store: NativeThreadStore, runID: String, isLive: @escaping () -> Bool) async {
        if self.runID != runID { reset(runID) }
        let epoch = generation
        // The request carries the thread's session: wait for it.
        while !Task.isCancelled, !store.ready { try? await Task.sleep(for: .milliseconds(100)) }
        guard !Task.isCancelled, generation == epoch else { return }
        live = isLive()
        await reload(store: store)
        while !Task.isCancelled, generation == epoch, live {
            try? await Task.sleep(for: store.pollInterval)
            guard !Task.isCancelled, generation == epoch else { return }
            live = isLive()
            await reload(store: store)
        }
    }

    func reload(store: NativeThreadStore) async {
        guard let runID else { return }
        guard !loading else { return }
        let epoch = generation
        loading = true
        defer { if generation == epoch { loading = false } }
        guard let page = await store.subagentTranscript(runID: runID) else {
            if generation == epoch { loadError = "Couldn't load this transcript. Try again." }
            return
        }
        guard generation == epoch, self.runID == runID else { return }
        loadError = nil
        let spliced = nativeTranscriptSplice(messages, newest: page)
        if spliced.replaced {
            olderCursor = page.olderCursor
            setEarlier(page.earlierCount)
        }
        if page.olderCursor == nil {
            olderCursor = nil
            setEarlier(0)
        }
        setMessages(spliced.messages)
        if !loaded { loaded = true }
    }

    /// Pages back to the first entry ("Show all").
    func loadAll(store: NativeThreadStore) async {
        guard !loadingOlder, let runID else { return }
        let epoch = generation
        loadingOlder = true
        defer { if generation == epoch { loadingOlder = false } }
        // Pages wait here and land together: the newest page may be reloaded meanwhile, so they
        // are prepended to what the model holds when they land.
        var batch: [NativeSubagentTranscript] = []
        func land() {
            guard let last = batch.last else { return }
            setMessages(batch.reduce(messages) { nativeTranscriptPrepend($0, older: $1) })
            setEarlier(last.earlierCount)
            batch = []
        }
        while !Task.isCancelled, let cursor = olderCursor, generation == epoch {
            guard let page = await store.subagentTranscript(runID: runID, beforeEntryID: cursor), generation == epoch,
                  page.olderCursor != cursor else { break }
            batch.append(page)
            olderCursor = page.olderCursor
            if batch.count == Self.loadAllBatch { land() }
        }
        if generation == epoch { land() }
    }

    /// The whole transcript as text, once every page is in; nil when a page failed to load.
    func copyText(store: NativeThreadStore) async -> String? {
        await loadAll(store: store)
        guard loaded, loadError == nil, olderCursor == nil else { return nil }
        return nativeTranscriptText(messages)
    }

    private func setMessages(_ value: [NativeThreadMessage]) {
        guard value != messages || live != derivedLive else { return }
        messages = value
        derivedLive = live
        let grouped = nativeTurns(value)
        let lastAgent = grouped.lastIndex { !$0.isUser }
        var next: [Turn] = []
        for (index, turn) in grouped.enumerated() {
            if turn.isUser {
                let text = turn.messages.map { $0.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n") }
                next.append(Turn(id: turn.id, user: text, userTime: turn.messages.first?.timestamp,
                                 fromParent: !nativeTranscriptTurnIsTheUsers(turn.messages), presentation: nil, live: false))
            } else {
                let isLive = live && index == lastAgent
                let presentation: NativeTurnPresentation
                if let cached = presentations[turn.id], cached.live == isLive, cached.messages == turn.messages {
                    presentation = cached.value
                } else {
                    // Never live thinking: a transcript holds finished messages, and the run's
                    // own tail says what moves (`nativeRunLive`).
                    presentation = nativeTurnPresentation(turn.messages, live: false)
                    presentations[turn.id] = (turn.messages, isLive, presentation)
                }
                next.append(Turn(id: turn.id, user: [], userTime: nil, presentation: presentation, live: isLive))
            }
        }
        if next != turns { turns = next }
    }

    private func setEarlier(_ value: Int) {
        if earlierCount != value { earlierCount = value }
    }

    private func reset(_ runID: String) {
        self.runID = runID
        generation = UUID()
        olderCursor = nil
        messages = []
        turns = []
        derivedLive = false
        presentations = [:]
        earlierCount = 0
        loaded = false
        loadError = nil
        loading = false
        loadingOlder = false
    }
}

/// The transcript's turns, one step smaller than the thread's prose: the parent's messages as
/// bubbles captioned "from parent" (the user's own are not), then each agent turn's thinking,
/// prose and tool lines.
struct SubagentTranscriptList: View {
    let model: SubagentTranscriptModel
    /// What the run is doing now (LiveText): its call in flight; nil between calls.
    let live: NativeActivityBurst?
    let emptyText: String
    /// Draw the first message from the parent, the task (the iPhone's goal box already shows it).
    var showsTask = true

    var body: some View {
        let turns = model.turns
        LazyVStack(alignment: .leading, spacing: MobileLayout.turnItemSpacing) {
            if !model.loaded, model.loadError == nil {
                Text("Loading transcript…").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            if turns.isEmpty, model.loaded, model.loadError == nil {
                Text(emptyText).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
            }
            ForEach(!showsTask && turns.first?.presentation == nil ? Array(turns.dropFirst()) : turns) { turn in
                VStack(alignment: .leading, spacing: 0) {
                    SubagentTurnView(turn: turn).equatable()
                }
            }
            // It continues the last turn: under its lines at their spacing (MobileSubagent).
            if let live {
                SubagentActivityLine(burst: live)
                    .padding(.top, Self.endsInLines(turns.last) ? MobileLayout.activitySpacing - MobileLayout.turnItemSpacing : 0)
            }
        }
        .environment(\.shProseSize, .small)
    }

    private static func endsInLines(_ turn: SubagentTranscriptModel.Turn?) -> Bool {
        if case .activity? = turn?.presentation?.items.last { return true }
        return false
    }
}

/// One transcript turn.
struct SubagentTurnView: View, Equatable {
    let turn: SubagentTranscriptModel.Turn

    var body: some View {
        if let presentation = turn.presentation {
            VStack(alignment: .leading, spacing: MobileLayout.turnItemSpacing) {
                ForEach(presentation.items) { item in
                    SubagentTurnItem(item: item, live: turn.live)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .trailing, spacing: MobileLayout.activitySpacing) {
                ForEach(Array(turn.user.enumerated()), id: \.offset) { _, text in
                    SHUserBubble(text, timestamp: turn.userTime.map { nativeClockText($0, meridiem: false) }, note: turn.fromParent ? "from parent" : nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// One item of a transcript turn.
private struct SubagentTurnItem: View {
    let item: NativeTurnPresentation.Item
    let live: Bool
    @State private var openThinking = false

    var body: some View {
        switch item {
        case .thinking(_, _, let blocks, let seconds, let live, let since):
            ThinkingRow(seconds: seconds, blocks: blocks, live: live, since: since, isExpanded: openThinking) { openThinking.toggle() }
                .equatable()
        case .prose(_, _, let blocks, let openFence):
            SHAgentProse(ProseView.proseBlocks(blocks), writingFence: live && openFence)
        case .activity(_, let bursts):
            VStack(alignment: .leading, spacing: MobileLayout.activitySpacing) {
                ForEach(bursts) { burst in
                    SubagentActivityLine(burst: burst)
                }
            }
        case .subagents:
            EmptyView()
        case .goalRecord(_, let text):
            GoalRecordLine(text: text)
        case .artifact(_, let artifact):
            // A subagent's transcript has no pane beside it: the card names the file and draws no Open.
            ArtifactCardItem(artifact: artifact)
        case .images(_, let images):
            // The phone and the iPad do not draw a thread's images yet: how many, as the note it replaced said.
            Text(images.count == 1 ? "Image attached" : "\(images.count) images attached").font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
        case .note(_, let text):
            Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(3)
        case .error(_, let error, _, let folded):
            TurnErrorItem(error: error, folded: folded)
        case .retrying(_, let line):
            RetryLineItem(line: line)
        case .steer(_, let text, let sentAt, _):
            SHUserBubble(text, timestamp: sentAt.map { nativeClockText($0, meridiem: false) }, note: "from parent", origin: .steered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .compaction(let row):
            CompactionItem(row: row)
        case .question(let row):
            QuestionRecordView(row: row)
        }
    }
}

/// One burst of the child's tool work; a finished burst expands to its calls.
struct SubagentActivityLine: View {
    let burst: NativeActivityBurst
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SHActivityLine(kind: kind, label: burst.label, meta: burst.meta, status: status, isExpanded: expanded,
                           accessibilityLabel: burst.accessibilityLabel,
                           action: burst.expandable ? { withAnimation(SH.Motion.disclosure.animation(reduceMotion: reduceMotion)) { expanded.toggle() } } : nil,
                           received: burst.received)
            if expanded {
                SHActivityCalls(burst.calls.map { call in
                    SHActivityCallRow(id: call.id, label: call.label, detail: call.detail, isPath: call.isPath, stat: call.stat,
                                      failed: call.failed, output: [], moreLines: 0, truncated: call.truncated, isExpanded: false,
                                      accessibilityLabel: [call.label, call.detail, call.stat].compactMap { $0 }.joined(separator: ", "))
                }, onSelect: { _ in }, onShowAll: { _ in })
                .padding(.vertical, SH.Space.xxs)
            }
        }
    }

    private var kind: SHActivityLine.Kind {
        switch burst.kind {
        case .explore: .explore
        case .edit where burst.artifact != nil: .artifact
        case .edit: .edit
        case .run: .run
        case .subagents: .subagents
        case .drew: burst.isBoardUpdate ? .edit : .drew
        case .checked: .checked
        case .lookedAt: .lookedAtDesign
        case .browser: .browser
        case .other: .other
        }
    }

    private var status: SHActivityLine.Status {
        switch burst.state {
        case .done: .done
        case .failed: .failed
        case .running: .live(since: burst.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, tail: burst.tail)
        }
    }
}
