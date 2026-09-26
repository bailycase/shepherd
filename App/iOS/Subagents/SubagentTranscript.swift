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
    private(set) var loadingOlder = false
    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private var runID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var live = false
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
        let epoch = generation
        guard let page = await store.subagentTranscript(runID: runID) else {
            if generation == epoch, store.ready, !loaded { loaded = true }
            return
        }
        guard generation == epoch, self.runID == runID else { return }
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
        while !Task.isCancelled, let cursor = olderCursor, generation == epoch {
            guard let page = await store.subagentTranscript(runID: runID, beforeEntryID: cursor), generation == epoch,
                  page.olderCursor != cursor else { break }
            setMessages(nativeTranscriptPrepend(messages, older: page))
            olderCursor = page.olderCursor
            setEarlier(page.earlierCount)
        }
    }

    /// The whole transcript as text, once every page is in; nil when a page failed to load.
    func copyText(store: NativeThreadStore) async -> String? {
        await loadAll(store: store)
        guard olderCursor == nil else { return nil }
        return nativeTranscriptText(messages)
    }

    private func setMessages(_ value: [NativeThreadMessage]) {
        guard value != messages else { return }
        messages = value
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
        presentations = [:]
        earlierCount = 0
        loaded = false
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
            if turns.isEmpty, model.loaded {
                Text(emptyText).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
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
        .environment(\.nwProseSize, .small)
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
                    SubagentTurnItem(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .trailing, spacing: MobileLayout.activitySpacing) {
                ForEach(Array(turn.user.enumerated()), id: \.offset) { _, text in
                    NWUserBubble(text, timestamp: turn.userTime.map { nativeClockText($0, meridiem: false) }, note: turn.fromParent ? "from parent" : nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// One item of a transcript turn.
private struct SubagentTurnItem: View {
    let item: NativeTurnPresentation.Item
    @State private var openThinking = false

    var body: some View {
        switch item {
        case .thinking(_, _, let blocks, let seconds, let live, _):
            ThinkingRow(seconds: seconds, blocks: blocks, live: live, isExpanded: openThinking) { openThinking.toggle() }
                .equatable()
        case .prose(_, _, let blocks, _):
            NWAgentProse(ProseView.proseBlocks(blocks))
        case .activity(_, let bursts):
            VStack(alignment: .leading, spacing: MobileLayout.activitySpacing) {
                ForEach(bursts) { burst in
                    SubagentActivityLine(burst: burst)
                }
            }
        case .subagents:
            EmptyView()
        case .note(_, let text):
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(3)
        case .error(_, let text, let count, _):
            NWTurnError(text, count: count)
        case .steer(_, let text, let sentAt, _):
            NWUserBubble(text, timestamp: sentAt.map { nativeClockText($0, meridiem: false) }, note: "from parent", origin: .steered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .compaction(let row):
            CompactionItem(row: row)
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
            NWActivityLine(kind: kind, label: burst.label, meta: burst.meta, status: status, isExpanded: expanded,
                           accessibilityLabel: burst.accessibilityLabel,
                           action: burst.expandable ? { withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { expanded.toggle() } } : nil)
            if expanded {
                NWActivityCalls(burst.calls.map { call in
                    NWActivityCallRow(id: call.id, label: call.label, detail: call.detail, isPath: call.isPath, stat: call.stat,
                                      failed: call.failed, output: [], moreLines: 0, truncated: call.truncated, isExpanded: false,
                                      accessibilityLabel: [call.label, call.detail, call.stat].compactMap { $0 }.joined(separator: ", "))
                }, onSelect: { _ in }, onShowAll: { _ in })
                .padding(.vertical, NW.Space.xxs)
            }
        }
    }

    private var kind: NWActivityLine.Kind {
        switch burst.kind {
        case .explore: .explore
        case .edit: .edit
        case .run: .run
        case .subagents: .subagents
        case .other: .other
        }
    }

    private var status: NWActivityLine.Status {
        switch burst.state {
        case .done: .done
        case .failed: .failed
        case .running: .live(since: burst.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }, tail: burst.tail)
        }
    }
}
