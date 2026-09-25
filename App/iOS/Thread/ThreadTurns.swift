import SwiftUI
import UIKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The user's turn: one `NWUserBubble` per message, each with its time (touch has no hover, so
/// times show at rest). Messages the queue delivered together open with "From the queue · N". A
/// send pi has not read yet stands at 70%.
struct UserTurnView: View, Equatable {
    struct Bubble: Equatable {
        var text: String
        var images: Int
        var caption: String?
        var pending: Bool
    }

    let bubbles: [Bubble]
    var fromQueue: Int?

    init(turn: NativeTurn) {
        bubbles = turn.bubbles.map { bubble in
            Bubble(text: bubble.text, images: bubble.images, caption: bubble.sentAt.map { nativeClockText($0) }, pending: bubble.pending)
        }
        fromQueue = turn.fromQueue
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: MobileLayout.turnItemSpacing) {
            if let fromQueue { NWQueueDivider(count: fromQueue) }
            VStack(alignment: .trailing, spacing: MobileLayout.activitySpacing) {
                // By position: an echo and the message pi saves for it have different entries,
                // and the bubble must stay one view to settle in place (70% → 100%).
                ForEach(Array(bubbles.enumerated()), id: \.offset) { _, bubble in
                    NWUserBubble(bubble.text, attachments: Array(repeating: "Image", count: bubble.images), timestamp: bubble.caption)
                        .opacity(bubble.pending ? 0.7 : 1)
                        .nwAnimation(.hover, value: bubble.pending)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// What an agent turn can do beyond drawing itself. Closures stay out of equality: a turn
/// compares only whether each action exists.
struct AgentTurnActions {
    /// Resend the prompt that opened this turn; nil hides Retry.
    var retry: (() -> Void)?
    /// Open review at a file (the changes card, an edit line); nil hides Review.
    var review: ((String) -> Void)?
    /// Open review on all of the turn's changes (the changes card's Review).
    var reviewChanges: (() -> Void)?
    /// Open the turn's first subagent (the footer's "3 subagents").
    var subagents: (() -> Void)?
}

/// One agent turn (MobileThread board): thinking, prose, activity lines, the subagent record
/// (where they started and where they finished), notes and errors, then, once finished, the
/// changes card and the footer.
/// Everything it draws was derived once per turn change (`NativeTurnPresentation`).
struct AgentTurnView: View, Equatable {
    let thread: AgentRef
    let presentation: NativeTurnPresentation
    let live: Bool
    /// How many subagents the turn started (the footer's "3 subagents").
    var subagents = 0
    /// Timestamp (ms) of the user message that opened this turn: the footer's time and duration.
    var startedAt: Double?
    /// The live turn is between tools (`NativeThreadStore.showsThinking`): it ends in the live
    /// "Thinking…" (LiveText).
    var thinking = false
    var actions = AgentTurnActions()
    @State private var openThinking: Set<String> = []

    static func == (lhs: AgentTurnView, rhs: AgentTurnView) -> Bool {
        lhs.thread == rhs.thread && lhs.presentation == rhs.presentation && lhs.live == rhs.live
            && lhs.subagents == rhs.subagents && lhs.startedAt == rhs.startedAt && lhs.thinking == rhs.thinking
            && (lhs.actions.retry == nil) == (rhs.actions.retry == nil)
            && (lhs.actions.review == nil) == (rhs.actions.review == nil)
            && (lhs.actions.reviewChanges == nil) == (rhs.actions.reviewChanges == nil)
            && (lhs.actions.subagents == nil) == (rhs.actions.subagents == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.turnItemSpacing) {
            ForEach(presentation.items) { item in
                itemView(item)
            }
            if thinking { NWThinking.live() }
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
        case .thinking(let id, let text, let seconds, let live, _):
            live
                ? NWThinking.live()
                : NWThinking(nativeThoughtText(seconds), text: text, isExpanded: Binding(
                    get: { openThinking.contains(id) },
                    set: { if $0 { openThinking.insert(id) } else { openThinking.remove(id) } }),
                    spokenTitle: nativeThoughtSpokenText(seconds))
        case .prose(_, _, let blocks, _):
            ProseView(blocks: blocks).equatable()
        case .activity(_, let bursts):
            ActivityLinesView(bursts: bursts, review: actions.review).equatable()
        case .subagents(_, let lines):
            // Where they started, and where they finished: both open the thread's subagents.
            // Adjacent, they sit together as activity lines do.
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                ForEach(lines, id: \.title) { line in
                    NWSubagentRecordLine(title: line.title, meta: line.meta, action: actions.subagents)
                }
            }
        case .note(_, let text):
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
                .lineLimit(3).truncationMode(.tail).textSelection(.enabled)
                .padding(.leading, MobileLayout.noteIndent)
                .overlay(alignment: .leading) { Color.nw.lineStrong.frame(width: NWThreadMetrics.ruleWidth) }
        case .error(_, let text, let count, let final):
            NWTurnError(final ? nativeTurnErrorText(text, toolCalls: presentation.toolCalls) : text,
                        count: count, retry: final ? actions.retry : nil)
        case .steer(_, let text, let sentAt, let images):
            NWUserBubble(text, attachments: Array(repeating: "Image", count: images), timestamp: sentAt.map { nativeClockText($0) },
                         origin: .steered)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func changesCard(_ changes: NativeTurnChanges) -> some View {
        NWAdaptiveChangesCard(
            title: changes.title, added: changes.added, removed: changes.removed,
            files: changes.files.map {
                NWChangedFile(path: $0.path, directory: $0.directory, name: $0.name,
                              status: NWChangedFile.Status(rawValue: $0.status.rawValue) ?? .modified, added: $0.added, removed: $0.removed)
            },
            onReview: actions.reviewChanges,
            onOpen: actions.review)
    }

    /// Copy and Retry, then "2:44 PM · 3m 12s · 6 tool calls", and "3 subagents" as a link.
    private var footer: some View {
        let runs = subagents
        let meta = [nativeTurnTimeText(startedAt: startedAt, endedAt: presentation.endedAt),
                    presentation.toolCalls > 0 ? nativeCount(presentation.toolCalls, "tool call") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let copy = presentation.copyText
        return NWTurnFooter(
            meta: meta,
            link: runs == 0 || actions.subagents == nil ? nil : nativeCount(runs, "subagent"),
            onLink: actions.subagents,
            onCopy: copy.isEmpty ? nil : { UIPasteboard.general.string = copy },
            onRetry: actions.retry)
    }
}

/// Agent prose: parsed Markdown drawn by `NWAgentProse`, inline runs styled once per text
/// (`NWProseInline`). A host's files are not on this device, so its images show as chips.
struct ProseView: View, Equatable {
    let blocks: [NativeMarkdownBlock]

    var body: some View {
        NWAgentProse(Self.proseBlocks(blocks))
    }

    static func proseBlocks(_ blocks: [NativeMarkdownBlock]) -> [NWProseBlock] {
        blocks.map { block in
            switch block {
            case .heading(let level, let text): .heading(level: level, text: NWProseInline.attributed(text))
            case .paragraph(let text): .paragraph(NWProseInline.attributed(text))
            case .quote(let inner): .quote(proseBlocks(inner))
            case .code(let text, let language): .code(text, language: language)
            case .rule: .rule
            case .list(let ordered, let start, let items):
                .list(ordered: ordered, start: start, items: items.map {
                    NWProseListItem(text: NWProseInline.attributed($0.text), task: $0.task.map { $0 == .done ? .done : .open },
                                    children: proseBlocks($0.children))
                })
            case .table(let table):
                .table(NWProseTable(
                    alignments: table.alignments.map {
                        switch $0 {
                        case .none, .leading: .leading
                        case .center: .center
                        case .trailing: .trailing
                        }
                    },
                    header: table.header.map(NWProseInline.attributed),
                    rows: table.rows.map { $0.map(NWProseInline.attributed) },
                    markdown: table.source))
            case .image(let alt, let source): .image(NWProseImage(alt: alt, source: source))
            case .details(let summary, let inner): .details(summary: NWProseInline.attributed(summary), blocks: proseBlocks(inner))
            case .footnotes(let notes):
                .footnotes(notes.map { NWProseFootnote(number: $0.number, text: NWProseInline.attributed($0.text)) })
            }
        }
    }
}

/// Consecutive activity lines (MobileThread: one line per burst of work), each expanding to its
/// calls. The running call's line is the thread's live indicator (LiveText).
struct ActivityLinesView: View, Equatable {
    let bursts: [NativeActivityBurst]
    var review: ((String) -> Void)?

    static func == (lhs: ActivityLinesView, rhs: ActivityLinesView) -> Bool {
        lhs.bursts == rhs.bursts && (lhs.review == nil) == (rhs.review == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileLayout.activitySpacing) {
            ForEach(bursts) { burst in
                ActivityLineView(burst: burst, review: review).equatable()
            }
        }
    }
}

/// One burst of tool work. Expanding it shows its calls; an edit opens review at its file, any
/// other call expands to its output, and a long press offers the full output and the raw call.
struct ActivityLineView: View, Equatable {
    let burst: NativeActivityBurst
    var review: ((String) -> Void)?
    @State private var expanded = false
    @State private var expandedCalls: Set<String> = []
    @State private var sheet: ToolOutput?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: ActivityLineView, rhs: ActivityLineView) -> Bool {
        lhs.burst == rhs.burst && (lhs.review == nil) == (rhs.review == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NWActivityLine(kind: kind, label: burst.label, meta: burst.meta, status: status, isExpanded: expanded,
                           accessibilityLabel: burst.accessibilityLabel,
                           action: burst.expandable ? toggle : nil)
            if expanded {
                NWActivityCalls(burst.calls.map(row), onSelect: select, onShowAll: showOutput) { row in
                    if let call = burst.calls.first(where: { $0.id == row.id }) { menu(call) }
                }
                .padding(.vertical, NW.Space.xxs)
                .nwTransition(.disclosure)
            }
        }
        .sheet(item: $sheet) { ToolOutputSheet(output: $0) }
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

    private func toggle() {
        withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) { expanded.toggle() }
    }

    private func row(_ call: NativeActivityCall) -> NWActivityCallRow {
        let open = expandedCalls.contains(call.id)
        return NWActivityCallRow(
            id: call.id, label: call.label, detail: call.detail, isPath: call.isPath, stat: call.stat, failed: call.failed,
            output: open ? call.outputHead : [], moreLines: max(0, call.outputLineCount - call.outputHead.count),
            truncated: call.truncated, isExpanded: open,
            accessibilityLabel: [call.label, call.detail, call.stat, call.failed ? "failed" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private func select(_ id: String) {
        guard let call = burst.calls.first(where: { $0.id == id }) else { return }
        if call.kind == .edit, let path = call.path, let review {
            review(path)
        } else if call.expandable {
            withAnimation(NW.Motion.disclosure.animation(reduceMotion: reduceMotion)) {
                if expandedCalls.remove(id) == nil { expandedCalls.insert(id) }
            }
        }
    }

    private func showOutput(_ id: String) {
        guard let call = burst.calls.first(where: { $0.id == id }) else { return }
        sheet = ToolOutput(title: "\(call.name) · \(call.detail)", text: call.output, truncated: call.truncated)
    }

    @ViewBuilder private func menu(_ call: NativeActivityCall) -> some View {
        if let arguments = call.arguments {
            Button("Show Call", systemImage: "curlybraces") {
                sheet = ToolOutput(title: "\(call.name) · call", text: arguments, truncated: false)
            }
        }
        if call.kind == .edit, let path = call.path, let review {
            Button("Review \((path as NSString).lastPathComponent)", systemImage: "doc.text.magnifyingglass") { review(path) }
        }
        if !call.output.isEmpty {
            Button("Open Output", systemImage: "text.alignleft") { showOutput(call.id) }
            Button("Copy Output", systemImage: "doc.on.doc") { UIPasteboard.general.string = call.output }
        }
    }
}

/// The full output of one call, or its raw arguments.
struct ToolOutput: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let truncated: Bool
}

struct ToolOutputSheet: View {
    let output: ToolOutput
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(output.text).font(.nw(.code)).lineSpacing(NWTextStyle.code.lineSpacing).foregroundStyle(Color.nw.textSecondary)
                    .textSelection(.enabled).fixedSize().padding(MobileLayout.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom) {
                if output.truncated {
                    Text("The host clipped this output; the full text is in pi's session file.")
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).padding(MobileLayout.gutter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.nw.bgWindow)
                }
            }
            .background(Color.nw.bgWindow)
            .navigationTitle(output.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = output.text }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
