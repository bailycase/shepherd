import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The user's turn: one `NWUserBubble` per message, the time beneath the last. A follow-up
/// sent while the agent ran is queued until the turn ends. No speaker label: shape carries
/// the role.
struct UserTurn: View, Equatable {
    let messages: [NativeThreadMessage]
    /// "2:41 PM"; "10:58 · from parent" in a child's transcript.
    var caption: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: AppLayout.activitySpacing) {
            ForEach(Array(messages.enumerated()), id: \.element.entryID) { index, message in
                let images = message.blocks.count { $0.kind == .unsupportedImage }
                NWUserBubble(message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n"),
                             attachments: Array(repeating: "Image", count: images),
                             timestamp: index == messages.count - 1 ? caption : nil,
                             isQueued: message.status == "queued")
                    .opacity(message.status == "pending" ? 0.7 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// One agent turn (NWThread board): thinking, prose, activity lines, subagent cards where their
/// spawn calls were, then, once it has finished, the changes card and the footer. Everything
/// it shows was derived once per turn change (`NativeTurnPresentation`), and it redraws only
/// when that, its placement, or its flags change.
struct AgentTurn: View, Equatable {
    let presentation: NativeTurnPresentation
    /// True while this turn is the one streaming.
    let live: Bool
    var subagents = NativeSubagentPlacement()
    var subagentActions: SubagentActions? = nil
    /// Timestamp (ms) of the user message that opened this turn: the footer's time and duration.
    var startedAt: Double? = nil
    /// Resend the prompt that opened this turn; nil hides Retry.
    var retry: (() -> Void)? = nil
    /// Opens the review pane at a file.
    var review: ((String) -> Void)? = nil
    /// The streaming turn's tail row ("Working…"): the last of its parts.
    var working: String? = nil
    @State private var openThinking: Set<String> = []

    init(presentation: NativeTurnPresentation, live: Bool, subagents: NativeSubagentPlacement = NativeSubagentPlacement(),
         subagentActions: SubagentActions? = nil, startedAt: Double? = nil, retry: (() -> Void)? = nil, review: ((String) -> Void)? = nil,
         working: String? = nil) {
        self.presentation = presentation
        self.live = live
        self.subagents = subagents
        self.subagentActions = subagentActions
        self.startedAt = startedAt
        self.retry = retry
        self.review = review
        self.working = working
    }

    /// A transcript with no store behind it (the subagent inspector): the presentation is
    /// memoised per turn.
    init(messages: [NativeThreadMessage], live: Bool) {
        self.init(presentation: TurnPresentationMemo.presentation(messages, live: live), live: live)
    }

    static func == (lhs: AgentTurn, rhs: AgentTurn) -> Bool {
        lhs.presentation == rhs.presentation && lhs.live == rhs.live && lhs.subagents == rhs.subagents
            && lhs.startedAt == rhs.startedAt && lhs.working == rhs.working
            && (lhs.retry == nil) == (rhs.retry == nil) && (lhs.review == nil) == (rhs.review == nil)
            && (lhs.subagentActions == nil) == (rhs.subagentActions == nil)
            && lhs.subagentActions?.enabled == rhs.subagentActions?.enabled
            && lhs.subagentActions?.inspectedRunID == rhs.subagentActions?.inspectedRunID
    }

    /// Consecutive activity lines sit 6pt apart; everything else 14pt.
    private enum Part: Identifiable {
        case item(NativeTurnPresentation.Item)
        case activity([NativeActivityBurst])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .activity(let bursts): "lines:" + (bursts.first?.id ?? "")
            }
        }
    }

    private var parts: [Part] {
        var parts: [Part] = []
        for item in presentation.items {
            if case .activity(let burst) = item {
                if case .activity(let bursts)? = parts.last { parts[parts.count - 1] = .activity(bursts + [burst]) }
                else { parts.append(.activity([burst])) }
            } else {
                parts.append(.item(item))
            }
        }
        return parts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.turnItemSpacing) {
            ForEach(parts) { part in
                switch part {
                case .activity(let bursts):
                    VStack(alignment: .leading, spacing: AppLayout.activitySpacing) {
                        ForEach(bursts) { burst in
                            ActivityLineView(burst: burst, review: review).equatable()
                        }
                    }
                case .item(let item):
                    itemView(item)
                }
            }
            // Runs with no spawn row in this turn render after it; a folded group already
            // placed them in its strip or ledger unless there was no spawn row to fold into.
            if let subagentActions, !subagents.trailing.isEmpty,
               subagents.byToolCall.isEmpty || !NativeCardLayout(subagents).folds {
                SubagentStack(runs: subagents.byToolCall.isEmpty ? subagents.all : subagents.trailing, actions: subagentActions)
            }
            if let working { WorkingRow(label: working) }
            if !live, !presentation.items.isEmpty {
                if let changes = presentation.changes { changesCard(changes) }
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func itemView(_ item: NativeTurnPresentation.Item) -> some View {
        switch item {
        case .thinking(let id, let text, let seconds, let live, let since):
            // One view for live and finished thinking, so "Thinking…" settles into "Thought
            // for Ns" in place.
            live
                ? NWThinking(liveSince: since.map { Date(timeIntervalSince1970: $0 / 1000) }, seconds: seconds)
                : NWThinking(nativeThoughtText(seconds), text: text, isExpanded: Binding(
                    get: { openThinking.contains(id) },
                    set: { if $0 { openThinking.insert(id) } else { openThinking.remove(id) } }))
        case .prose(_, _, let blocks):
            Prose(blocks: blocks).equatable()
        case .activity(let burst):
            ActivityLineView(burst: burst, review: review).equatable()
        case .subagents(_, let callIDs, let all):
            if let subagentActions {
                SubagentStack(runs: all ? subagents.all : callIDs.flatMap { subagents.byToolCall[$0] ?? [] },
                              turnLive: subagents.all.contains { !$0.isTerminal }, actions: subagentActions)
            }
        case .note(_, let text):
            Text(text).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .lineLimit(3).truncationMode(.tail).help(text).textSelection(.enabled)
                .padding(.leading, AppLayout.noteIndent)
                .overlay(alignment: .leading) { Color.nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
                .frame(maxWidth: AppLayout.proseMaxWidth, alignment: .leading)
        case .error(_, let text, let count, let final):
            NWTurnError(final ? nativeTurnErrorText(text, toolCalls: presentation.toolCalls) : text,
                        count: count, retry: final ? retry : nil)
                .frame(maxWidth: AppLayout.proseMaxWidth, alignment: .leading)
        }
    }

    private func changesCard(_ changes: NativeTurnChanges) -> some View {
        NWChangesCard(
            title: changes.title, added: changes.added, removed: changes.removed,
            files: changes.files.map {
                NWChangedFile(path: $0.path, directory: $0.directory, name: $0.name,
                              status: NWChangedFile.Status(rawValue: $0.status.rawValue) ?? .modified, added: $0.added, removed: $0.removed)
            },
            onReview: review.flatMap { review in changes.files.first.map { file in { review(file.path) } } },
            onOpen: review)
    }

    /// Copy and retry, then "2:44 PM · 3m 12s · 23 tool calls" and "3 subagents" as a link to
    /// the first run.
    private var footer: some View {
        let ordered = subagents.all.sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        let meta = [nativeTurnTimeText(startedAt: startedAt, endedAt: presentation.endedAt),
                    presentation.toolCalls > 0 ? nativeCount(presentation.toolCalls, "tool call") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let copy = presentation.copyText
        return NWTurnFooter(
            meta: meta,
            link: ordered.isEmpty || subagentActions == nil ? nil : nativeCount(ordered.count, "subagent"),
            onLink: ordered.first.flatMap { first in subagentActions.map { actions in { actions.inspect(first) } } },
            onCopy: copy.isEmpty ? nil : {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            },
            onRetry: retry)
    }
}

/// Presentations for transcripts built outside a store (the subagent inspector), keyed by the
/// turn's first entry so a live child turn is rebuilt only when its messages change.
@MainActor
enum TurnPresentationMemo {
    private static var entries: [String: (messages: [NativeThreadMessage], live: Bool, value: NativeTurnPresentation)] = [:]

    static func presentation(_ messages: [NativeThreadMessage], live: Bool) -> NativeTurnPresentation {
        let key = messages.first?.entryID ?? ""
        if let entry = entries[key], entry.live == live, entry.messages == messages { return entry.value }
        let value = nativeTurnPresentation(messages, live: live)
        if entries.count > 128 { entries.removeAll(keepingCapacity: true) }
        entries[key] = (messages, live, value)
        return value
    }
}

/// The tail row while the agent runs.
struct WorkingRow: View {
    let label: String

    var body: some View {
        NWWorkingRow(label)
    }
}
