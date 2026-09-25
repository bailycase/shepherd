import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Whether the pointer is over one message (a turn). The turn owns it, and only what shows its
/// quiet details reads it: an agent turn's footer, or a user turn (just its bubbles). The
/// pointer crossing a thread never re-renders an agent turn's parts, other turns, or the thread.
@MainActor
@Observable
final class MessageHover {
    var hovering: Bool

    /// `hovering` seeds the state, for previews and tests.
    init(hovering: Bool = false) {
        self.hovering = hovering
    }
}

extension View {
    /// Reports the pointer entering and leaving this message to `hover`. The whole row counts:
    /// hover follows hit-testing, so without the shape the gaps between parts and the hidden
    /// details' own place would drop it, and the footer would fade away on the way to it.
    func messageHover(_ hover: MessageHover) -> some View {
        contentShape(Rectangle())
            .onHover { inside in
                if hover.hovering != inside { hover.hovering = inside }
            }
    }
}

/// The user's turn: one `NWUserBubble` per message, each with its time beneath while the turn
/// is hovered. Messages the queue delivered together open with "From the queue · N", one bubble
/// per message with the time it was sent. A send pi has not read yet stands at 70%. No speaker
/// label: shape carries the role.
struct UserTurn: View, Equatable {
    /// One bubble as the turn draws it.
    struct Bubble: Equatable {
        var text: String
        var images: Int
        /// The time: "2:41 PM", or "10:58" in a child's transcript.
        var caption: String?
        var pending: Bool
    }

    let bubbles: [Bubble]
    /// "From the queue · N" above the bubbles, when the queue delivered them.
    var fromQueue: Int?
    /// Follows the last time and always shows: "from parent" in a child's transcript.
    var note: String?
    @State private var hover: MessageHover

    /// A thread's user turn: each bubble with its own time.
    init(turn: NativeTurn, hover: MessageHover? = nil) {
        self.init(bubbles: turn.bubbles.map { bubble in
            Bubble(text: bubble.text, images: bubble.images, caption: bubble.sentAt.map { nativeClockText($0) }, pending: bubble.pending)
        }, fromQueue: turn.fromQueue, hover: hover)
    }

    /// A transcript's turn (the subagent inspector): `caption` under the last message.
    init(messages: [NativeThreadMessage], caption: String? = nil, note: String? = nil, hover: MessageHover? = nil) {
        let bubbles = messages.enumerated().map { index, message in
            Bubble(text: message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n"),
                   images: message.blocks.count { $0.kind == .unsupportedImage },
                   caption: index == messages.count - 1 ? caption : nil,
                   pending: message.status == "pending" || message.status == "queued")
        }
        self.init(bubbles: bubbles, note: note, hover: hover)
    }

    /// `hover` seeds the pointer state, for previews and tests.
    init(bubbles: [Bubble], fromQueue: Int? = nil, note: String? = nil, hover: MessageHover? = nil) {
        self.bubbles = bubbles
        self.fromQueue = fromQueue
        self.note = note
        _hover = State(initialValue: hover ?? MessageHover())
    }

    static func == (lhs: UserTurn, rhs: UserTurn) -> Bool {
        lhs.bubbles == rhs.bubbles && lhs.fromQueue == rhs.fromQueue && lhs.note == rhs.note
    }

    var body: some View {
        let _ = NWRenderProbe.tick("thread.userTurn")
        VStack(alignment: .trailing, spacing: AppLayout.blockSpacing) {
            if let fromQueue { NWQueueDivider(count: fromQueue) }
            VStack(alignment: .trailing, spacing: AppLayout.activitySpacing) {
                // By position, not entry: an echo and the message pi saves for it have different
                // entries, and the bubble must stay one view to settle in place (70% → 100%).
                ForEach(Array(bubbles.enumerated()), id: \.offset) { index, bubble in
                    let last = index == bubbles.count - 1
                    NWUserBubble(bubble.text, attachments: Array(repeating: "Image", count: bubble.images),
                                 timestamp: bubble.caption, note: last ? note : nil, revealed: hover.hovering)
                        .opacity(bubble.pending ? 0.7 : 1)
                        .nwAnimation(.hover, value: bubble.pending)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .messageHover(hover)
    }
}

/// One agent turn (NWThread board): thinking, prose, activity lines, subagent cards where their
/// spawn calls were, then, once it has finished, the changes card and the footer (shown while
/// the turn is hovered). Everything it shows was derived once per turn change
/// (`NativeTurnPresentation`), and it redraws only when that, its placement, or its flags
/// change; hovering redraws only the footer.
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
    /// The live turn is between tools (`NativeThreadStore.showsThinking`): it ends in the live
    /// "Thinking…" (LiveText).
    var thinking = false
    /// The turn just arrived in a thread on screen: its first parts make their entrance too.
    /// Read only when the turn is created; not part of equality.
    var arriving = false
    /// The thread is on screen and caught up: parts that stream in make their entrance. False
    /// while it loads, so what a catch-up brings is simply there. Not part of equality.
    var settled = true
    @State private var openThinking: Set<String> = []
    @State private var shown = TurnShown()
    @State private var hover: MessageHover

    /// `hover` seeds the pointer state, for previews and tests.
    init(presentation: NativeTurnPresentation, live: Bool, subagents: NativeSubagentPlacement = NativeSubagentPlacement(),
         subagentActions: SubagentActions? = nil, startedAt: Double? = nil, retry: (() -> Void)? = nil, review: ((String) -> Void)? = nil,
         thinking: Bool = false, arriving: Bool = false, settled: Bool = true, hover: MessageHover? = nil) {
        self.presentation = presentation
        self.live = live
        self.subagents = subagents
        self.subagentActions = subagentActions
        self.startedAt = startedAt
        self.retry = retry
        self.review = review
        self.thinking = thinking
        self.arriving = arriving
        self.settled = settled
        _hover = State(initialValue: hover ?? MessageHover())
    }

    /// A transcript with no store behind it (the subagent inspector): the presentation is
    /// memoised per turn. Its thinking is never live: a transcript holds finished messages, and
    /// the run's own tail says what moves (`RunLiveTail`).
    init(messages: [NativeThreadMessage], live: Bool) {
        self.init(presentation: TurnPresentationMemo.presentation(messages, live: false), live: live)
    }

    static func == (lhs: AgentTurn, rhs: AgentTurn) -> Bool {
        lhs.presentation == rhs.presentation && lhs.live == rhs.live && lhs.subagents == rhs.subagents
            && lhs.startedAt == rhs.startedAt && lhs.thinking == rhs.thinking
            && (lhs.retry == nil) == (rhs.retry == nil) && (lhs.review == nil) == (rhs.review == nil)
            && (lhs.subagentActions == nil) == (rhs.subagentActions == nil)
            && lhs.subagentActions?.inspectedRunID == rhs.subagentActions?.inspectedRunID
    }

    /// Parts that stream in once the turn is on screen (activity lines, prose, cards, notes,
    /// errors) fade in, and the changes card and footer that end it rise into place. Text inside
    /// a part, and the parts a turn opens or scrolls back in with, appear at once.
    var body: some View {
        let _ = NWRenderProbe.tick("thread.agentTurn")
        let entering = (shown.appeared || arriving) && settled
        VStack(alignment: .leading, spacing: AppLayout.turnItemSpacing) {
            ForEach(presentation.items) { item in
                // Activity lines make their own entrances as they stream in. Live thinking
                // carries on the thread's live line, so it never enters.
                switch item {
                case .activity(_, let bursts):
                    ActivityLinesView(bursts: bursts, review: review, entering: entering).equatable()
                case .thinking(_, _, _, true, _):
                    itemView(item)
                default:
                    itemView(item).nwArrival(entering, Self.entrance(item), edge: .bottom)
                }
            }
            // Runs with no spawn row in this turn render after it; a folded group already
            // placed them in its strip or ledger unless there was no spawn row to fold into.
            if let subagentActions, !subagents.trailing.isEmpty,
               subagents.byToolCall.isEmpty || !NativeCardLayout(subagents).folds {
                SubagentStack(runs: subagents.byToolCall.isEmpty ? subagents.all : subagents.trailing, actions: subagentActions)
                    .nwArrival(entering)
            }
            // Between tools the turn ends in "Thinking…", which passes from the thread's tail into
            // the reply unchanged: it never enters.
            if thinking { NWThinking.live() }
            if !live, !presentation.items.isEmpty {
                Group {
                    if let changes = presentation.changes { changesCard(changes) }
                    footer
                }
                .nwArrival(entering, .list, edge: .bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .messageHover(hover)
        .accessibilityElement(children: .contain)
        .onAppear { shown.appeared = true }
    }

    /// A failed request rises in like a row; everything else streaming in just fades.
    private static func entrance(_ item: NativeTurnPresentation.Item) -> NW.Motion {
        if case .error = item { return .list }
        return .content
    }

    @ViewBuilder private func itemView(_ item: NativeTurnPresentation.Item) -> some View {
        switch item {
        case .thinking(let id, let text, let seconds, let live, _):
            // One view for live and finished thinking, so "Thinking…" settles into "Thought
            // for Ns" in place.
            live
                ? NWThinking.live()
                : NWThinking(nativeThoughtText(seconds), text: text, isExpanded: Binding(
                    get: { openThinking.contains(id) },
                    set: { if $0 { openThinking.insert(id) } else { openThinking.remove(id) } }))
        case .prose(_, _, let blocks, let openFence):
            // The fence a streaming reply is writing is colored as it grows, not on every chunk.
            Prose(blocks: blocks, writingFence: live && openFence).equatable()
        case .activity(_, let bursts):
            ActivityLinesView(bursts: bursts, review: review).equatable()
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
        case .steer(_, let text, let sentAt, let images):
            // Where pi read it, inside the turn it steered.
            SteeredBubble(text: text, images: images, time: sentAt.map { nativeClockText($0) }, hover: hover)
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
        return TurnFooter(
            hover: hover,
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

/// A message steered into the turn, where pi read it: "Steered" and a running line, and its time
/// while the turn is hovered. It reads the turn's hover itself, as the footer does.
private struct SteeredBubble: View {
    let text: String
    let images: Int
    let time: String?
    let hover: MessageHover

    var body: some View {
        NWUserBubble(text, attachments: Array(repeating: "Image", count: images), timestamp: time, revealed: hover.hovering,
                     origin: .steered)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The turn's footer, reading the turn's hover itself: the pointer entering or leaving a turn
/// re-renders only this.
private struct TurnFooter: View {
    let hover: MessageHover
    let meta: String
    let link: String?
    let onLink: (() -> Void)?
    let onCopy: (() -> Void)?
    let onRetry: (() -> Void)?

    var body: some View {
        NWTurnFooter(meta: meta, link: link, onLink: onLink, onCopy: onCopy, onRetry: onRetry, revealed: hover.hovering)
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

/// Whether a turn has been on screen, read by its parts as they are created. A reference, so
/// noting the first appearance never re-renders the turn.
@MainActor
final class TurnShown {
    var appeared = false
}
