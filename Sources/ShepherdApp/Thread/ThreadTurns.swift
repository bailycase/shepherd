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

/// One agent turn (NWThread board): thinking, prose, activity lines, the subagent record (where
/// they started and where they finished), then, once it has finished, the changes card and the
/// footer (shown while
/// the turn is hovered). Everything it shows was derived once per turn change
/// (`NativeTurnPresentation`), and it redraws only when that, its placement, or its flags
/// change; hovering redraws only the footer.
struct AgentTurn: View, Equatable {
    let presentation: NativeTurnPresentation
    /// True while this turn is the one streaming.
    let live: Bool
    var subagents = TurnSubagents()
    var subagentActions: SubagentActions? = nil
    /// Timestamp (ms) of the user message that opened this turn: the footer's time and duration.
    var startedAt: Double? = nil
    /// Resend the prompt that opened this turn; nil hides Retry.
    var retry: (() -> Void)? = nil
    /// Opens the review pane at a file.
    var review: ((String) -> Void)? = nil
    /// The turn the host recorded (its "Edited N files" card, with Undo and Redo).
    var recordedTurn: ChangesTurn? = nil
    var turnActions: TurnChangesActions? = nil
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
    init(presentation: NativeTurnPresentation, live: Bool, subagents: TurnSubagents = TurnSubagents(),
         subagentActions: SubagentActions? = nil, startedAt: Double? = nil, retry: (() -> Void)? = nil, review: ((String) -> Void)? = nil,
         recordedTurn: ChangesTurn? = nil, turnActions: TurnChangesActions? = nil,
         thinking: Bool = false, arriving: Bool = false, settled: Bool = true, hover: MessageHover? = nil) {
        self.presentation = presentation
        self.live = live
        self.subagents = subagents
        self.subagentActions = subagentActions
        self.startedAt = startedAt
        self.retry = retry
        self.review = review
        self.recordedTurn = recordedTurn
        self.turnActions = turnActions
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
            && lhs.startedAt == rhs.startedAt && lhs.thinking == rhs.thinking && lhs.recordedTurn == rhs.recordedTurn
            && (lhs.turnActions == nil) == (rhs.turnActions == nil)
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
                case .thinking(_, _, _, _, true, _):
                    itemView(item)
                default:
                    itemView(item).nwArrival(entering, Self.entrance(item), edge: .bottom)
                }
            }
            // Between tools the turn ends in "Thinking…", which passes from the thread's tail into
            // the reply unchanged: it never enters.
            if thinking { NWThinking.live() }
            if !live, !presentation.items.isEmpty {
                Group {
                    if let changes = cardChanges { changesCard(changes) }
                    if !presentation.endsInError { footer }
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
        if case .error(_, _, _, false) = item { return .list }
        return .content
    }

    @ViewBuilder private func itemView(_ item: NativeTurnPresentation.Item) -> some View {
        switch item {
        case .thinking(let id, _, let blocks, let seconds, let live, _):
            ThinkingRow(seconds: seconds, blocks: blocks, live: live, isExpanded: openThinking.contains(id)) {
                if openThinking.remove(id) == nil { openThinking.insert(id) }
            }
            .equatable()
        case .prose(_, _, let blocks, let openFence):
            // The fence a streaming reply is writing is colored as it grows, not on every chunk.
            Prose(blocks: blocks, writingFence: live && openFence).equatable()
        case .activity(_, let bursts):
            ActivityLinesView(bursts: bursts, review: review).equatable()
        case .subagents(_, let lines):
            // Where they started, and where they finished: both open the first run in the
            // inspector, whose ‹ › browse the rest. Adjacent, they sit together as activity
            // lines do.
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                ForEach(lines, id: \.title) { line in
                    NWSubagentRecordLine(title: line.title, meta: line.meta, action: openFirstRun)
                }
            }
        case .note(_, let text):
            Text(text).font(Font.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .lineLimit(3).truncationMode(.tail).help(text).textSelection(.enabled)
                .padding(.leading, AppLayout.noteIndent)
                .overlay(alignment: .leading) { Color.nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
                .frame(maxWidth: AppLayout.proseMaxWidth, alignment: .leading)
        case .error(_, let error, let final, let folded):
            // Every column's width, not the prose measure (ThreadError).
            TurnErrorItem(error: error, folded: folded, retry: final ? retry : nil)
        case .retrying(_, let line):
            RetryLineItem(line: line)
        case .steer(_, let text, let sentAt, let images):
            // Where pi read it, inside the turn it steered.
            SteeredBubble(text: text, images: images, time: sentAt.map { nativeClockText($0) }, hover: hover)
        case .compaction(let row):
            CompactionItem(row: row)
        case .question(let row):
            // Where pi asked, and the answer as the user's bubble.
            QuestionRecordItem(row: row, hover: hover)
        }
    }

    /// The card the turn ends with: the host's record of it when there is one (its files as the
    /// repository saw them), else the files the turn's edit calls named.
    private var cardChanges: NativeTurnChanges? {
        if let recordedTurn { return NativeTurnChanges(turn: recordedTurn) }
        return presentation.changes
    }

    /// Opens the turn's first subagent; nil while nothing can open it.
    private var openFirstRun: (() -> Void)? {
        guard let subagentActions, let first = subagents.first else { return nil }
        return { subagentActions.inspect(first) }
    }

    private func changesCard(_ changes: NativeTurnChanges) -> some View {
        TurnChangesCard(changes: changes, actions: turnActions, review: review)
    }

    /// Copy and retry, then "2:44 PM · 3m 12s · 23 tool calls" and "3 subagents" as a link to
    /// the first run.
    private var footer: some View {
        let meta = [nativeTurnTimeText(startedAt: startedAt, endedAt: presentation.endedAt),
                    presentation.toolCalls > 0 ? nativeCount(presentation.toolCalls, "tool call") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let copy = presentation.copyText
        return TurnFooter(
            hover: hover,
            meta: meta,
            link: subagents.count == 0 || subagentActions == nil ? nil : nativeCount(subagents.count, "subagent"),
            onLink: openFirstRun,
            onCopy: copy.isEmpty ? nil : {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            },
            onRetry: retry)
    }
}

/// A turn's subagents as the turn needs them: how many, and the first spawned (what the record
/// and the footer's "3 subagents" open). Compared by the first run's id alone, so a poll that
/// moves a live run redraws the tray, never the turn.
struct TurnSubagents: Equatable {
    var count = 0
    var first: ChildRun?

    init(_ placement: NativeSubagentPlacement? = nil) {
        let all = placement?.all ?? []
        count = all.count
        first = all.min { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
    }

    static func == (a: TurnSubagents, b: TurnSubagents) -> Bool {
        a.count == b.count && a.first?.runID == b.first?.runID
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

/// A question pi asked, where it asked, with the answer's time while the turn is hovered, like
/// every bubble's. It reads the turn's hover itself.
private struct QuestionRecordItem: View {
    let row: NativeQuestionRecordRow
    let hover: MessageHover

    var body: some View {
        NWQuestionRecord(question: row.question, title: row.title, text: row.text, answered: row.answered,
                         timestamp: row.caption(), revealed: hover.hovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.accessibilityLabel)
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

/// What a changes card can do (ChangesCard): open the Changes pane on the turn (at a file), and
/// undo or redo the turn. Undo and Redo answer with why they refused, or nil.
struct TurnChangesActions {
    var review: (_ turnID: UUID?, _ path: String?) -> Void
    var undo: (UUID) async -> String?
    var redo: (UUID) async -> String?
}

/// The "Edited N files" card with its own Undo and Redo state: busy while one runs, and the
/// refusal under the card until the next try.
private struct TurnChangesCard: View {
    let changes: NativeTurnChanges
    let actions: TurnChangesActions?
    let review: ((String) -> Void)?
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        let turnID = changes.turnID
        NWChangesCard(
            title: changes.title, added: changes.added, removed: changes.removed,
            files: changes.files.map {
                NWChangedFile(path: $0.path, directory: $0.directory, name: $0.name,
                              status: NWChangedFile.Status(rawValue: $0.status.rawValue) ?? .modified, added: $0.added, removed: $0.removed)
            },
            total: changes.fileCount, phase: changes.undone ? .undone : .edited, busy: busy, notice: notice,
            onReview: reviewAction(turnID: turnID),
            onOpen: openAction(turnID: turnID),
            onUndo: turnID.flatMap { id in changes.canUndo && !changes.undone ? actions.map { actions in { run { await actions.undo(id) } } } : nil },
            onRedo: turnID.flatMap { id in changes.canRedo && changes.undone ? actions.map { actions in { run { await actions.redo(id) } } } : nil })
    }

    private func reviewAction(turnID: UUID?) -> (() -> Void)? {
        if let actions { return { actions.review(turnID, nil) } }
        return review.flatMap { review in changes.files.first.map { file in { review(file.path) } } }
    }

    private func openAction(turnID: UUID?) -> ((String) -> Void)? {
        if let actions { return { actions.review(turnID, $0) } }
        return review
    }

    private func run(_ work: @escaping () async -> String?) {
        guard !busy else { return }
        busy = true
        notice = nil
        Task {
            let refusal = await work()
            busy = false
            notice = refusal
        }
    }
}
