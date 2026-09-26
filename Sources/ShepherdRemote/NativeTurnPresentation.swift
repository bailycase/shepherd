import Foundation
import ShepherdProtocol

/// Where a turn's subagents show in its thread: the spawn call ids the record stands for (they
/// and the parent's bookkeeping calls leave no activity line), and the record itself ("Started
/// 3 subagents", then "3 subagents finished").
public struct NativeCardLayout: Equatable, Hashable, Sendable {
    public var callIDs: Set<String>
    public var record: NativeSubagentRecord?

    public init(callIDs: Set<String> = [], record: NativeSubagentRecord? = nil) {
        self.callIDs = callIDs
        self.record = record
    }

    public static let none = NativeCardLayout()

    /// A turn's placement as its thread records it.
    public init(_ placement: NativeSubagentPlacement?) {
        guard let placement, !placement.isEmpty else { self.init(); return }
        self.init(callIDs: Set(placement.byToolCall.keys), record: NativeSubagentRecord(placement.all))
    }
}

/// An agent turn as the thread draws it (NWThread board): thinking, prose, activity lines,
/// the subagent record (where they started and where they finished), notes and errors, then
/// the changes card and the footer. Built once per turn change; views only read it.
public struct NativeTurnPresentation: Equatable, Sendable {
    public enum Item: Equatable, Sendable, Identifiable {
        /// Thinking for one stretch of work (merged between prose), or the live block. `text` is
        /// only what the reader can read, "" when the model shared none: then the finished row is
        /// a plain "Thought for Ns" line, and it is left out when it was not timed either.
        case thinking(id: String, text: String, seconds: Double?, live: Bool, since: Double?)
        /// `openFence`: the text ends inside a fence still open (the block a reply is writing).
        case prose(id: String, text: String, blocks: [NativeMarkdownBlock], openFence: Bool)
        /// Consecutive activity lines, one per burst of work (NWThread: "one quiet line per
        /// burst"), between prose, notes, errors, steers and the subagent record. `id` follows
        /// the first burst.
        case activity(id: String, bursts: [NativeActivityBurst])
        /// The turn's subagent record: where they started, and where they finished. Both lines
        /// are one item while nothing came between them, so they sit together as activity
        /// lines do (SubagentsDone).
        case subagents(id: String, lines: [NativeSubagentRecordLine])
        case note(id: String, text: String)
        /// A failed provider request; `final` when it ended the turn.
        case error(id: String, text: String, count: Int, final: Bool)
        /// A message the user steered in, where pi read it (after the tool work before it).
        /// `sentAt` is when it was sent (ms); `images` how many it carried.
        case steer(id: String, text: String, sentAt: Double?, images: Int)
        /// A compaction where it happened, and what the agent kept.
        case compaction(NativeCompactionRow)
        /// A question pi asked, where it asked, and the user's answer (QuestionAnswered).
        case question(NativeQuestionRecordRow)

        public var id: String {
            switch self {
            case .thinking(let id, _, _, _, _), .prose(let id, _, _, _), .subagents(let id, _), .note(let id, _), .error(let id, _, _, _),
                 .steer(let id, _, _, _), .activity(let id, _): id
            case .compaction(let row): "compaction:" + row.id
            case .question(let row): "question:" + row.id
            }
        }
    }

    public var items: [Item]
    /// Files the turn edited, for the card that ends it (nil when it edited nothing).
    public var changes: NativeTurnChanges?
    /// Tool calls the reader can count: spawn calls a card replaced are not among them.
    public var toolCalls: Int
    /// The turn's prose, for Copy.
    public var copyText: String
    /// When the turn's last message landed (ms).
    public var endedAt: Double?
    /// The live turn has nothing moving (LiveText): no call running, no thinking streaming, and
    /// no reply being written. pi is between tools, so the thread ends in "Thinking…".
    public var betweenTools: Bool

    public init(items: [Item], changes: NativeTurnChanges?, toolCalls: Int, copyText: String, endedAt: Double?,
                betweenTools: Bool = false) {
        self.items = items
        self.changes = changes
        self.toolCalls = toolCalls
        self.copyText = copyText
        self.endedAt = endedAt
        self.betweenTools = betweenTools
    }
}

/// Builds a turn's presentation. Consecutive calls of one kind merge into activity lines, one per
/// burst; prose and the subagent record split them. Thinking between prose blocks folds into one "Thought for Ns" at the
/// start of its stretch, so a thinking model's per-call reasoning does not break every line
/// in two; the block still streaming stays last, live. `call` builds a call from its message
/// (the store passes a memoised one).
public func nativeTurnPresentation(
    _ messages: [NativeThreadMessage], live: Bool, cards: NativeCardLayout = .none,
    call: (NativeThreadMessage) -> NativeActivityCall = NativeActivityCall.init
) -> NativeTurnPresentation {
    enum Raw {
        case thinking(String, Double?, message: String, since: Double?)
        /// `streaming`: the text block a reply is still writing.
        case prose(String, streaming: Bool)
        case tool(NativeThreadMessage)
        case note(String)
        case error(String, Int)
        case steer(String, Double?, Int)
        case compaction(NativeCompactionRow)
        case question(NativeQuestionRecordRow)
    }

    var raw: [Raw] = []
    // When each raw item's message landed (ms), for where the subagents' finished line goes.
    var times: [Double?] = []
    for message in messages {
        defer { while times.count < raw.count { times.append(message.timestamp) } }
        if let compaction = message.compaction {
            raw.append(.compaction(NativeCompactionRow(entryID: message.entryID, compaction: compaction)))
            continue
        }
        if let question = message.question {
            raw.append(.question(NativeQuestionRecordRow(entryID: message.entryID, record: question, endedAt: message.timestamp)))
            continue
        }
        if message.role == "user" {
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            raw.append(.steer(text, message.timestamp, message.blocks.count { $0.kind == .unsupportedImage }))
            continue
        }
        if message.toolName != nil || message.role == "toolResult" {
            raw.append(.tool(message))
            continue
        }
        if message.role == "assistant", message.status == "error" {
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).last ?? "Request failed"
            if case .error(let last, let count)? = raw.last, last == text { raw[raw.count - 1] = .error(text, count + 1) }
            else { raw.append(.error(text, 1)) }
            continue
        }
        for (index, block) in message.blocks.enumerated() {
            switch block.kind {
            case .thinking:
                raw.append(.thinking(block.text, message.thinkingSeconds, message: message.entryID,
                                     since: message.status == "streaming" ? message.timestamp : nil))
            case .unsupportedImage: raw.append(.note("Image attached"))
            case .text:
                if message.role == "assistant" || message.role == "user" {
                    raw.append(.prose(block.text, streaming: message.status == "streaming" && index == message.blocks.count - 1))
                } else {
                    raw.append(.note(message.role == "custom" ? block.text : message.role.replacingOccurrences(of: "_", with: " ") + " · " + block.text))
                }
            }
        }
        if message.truncated { raw.append(.note("Output truncated")) }
        // The user stopped the run (the host's `aborted`): said quietly, never as an error.
        if message.role == "assistant", message.status == "aborted" { raw.append(.note("Stopped")) }
    }

    // The block still streaming is the turn's live thinking; everything else folds.
    var liveThinking: Raw?
    if live, case .thinking? = raw.last {
        liveThinking = raw.removeLast()
        times.removeLast()
    }
    // Only one thing moves at a time: a running call (even one the tray stands for), thinking,
    // or the reply being written. With none of them, pi is between tools.
    let callRunning = messages.contains { message in
        (message.toolName != nil || message.role == "toolResult") && message.isError != true
            && (message.status == "running" || message.status == "streaming")
    }
    var writing = false
    if case .prose? = raw.last { writing = true }
    let betweenTools = live && liveThinking == nil && !callRunning && !writing

    var items: [NativeTurnPresentation.Item] = []
    var calls: [NativeActivityCall] = []
    var toolCalls = 0
    var copy: [String] = []
    var ordinal = 0
    var placedStart = false
    var placedFinish = false
    let hasCards = !cards.callIDs.isEmpty

    func nextID(_ kind: String) -> String {
        defer { ordinal += 1 }
        return "\(kind):\(ordinal)"
    }

    /// One stretch between prose: its merged thinking first, then its lines and cards.
    var stretchThinking: [(text: String, seconds: Double?, message: String)] = []
    var stretchCalls: [NativeActivityCall] = []
    var stretchItems: [NativeTurnPresentation.Item] = []

    func flushCalls() {
        let bursts = nativeActivityBursts(stretchCalls)
        if let first = bursts.first { stretchItems.append(.activity(id: "activity:" + first.id, bursts: bursts)) }
        stretchCalls = []
    }
    func flushStretch() {
        flushCalls()
        if !stretchThinking.isEmpty {
            // The ordinal is spent either way, so leaving an empty row out moves no other id.
            let id = nextID("thinking")
            let text = stretchThinking.map(\.text).filter(nativeThinkingIsReadable).joined(separator: "\n\n")
            var seconds: Double?
            var counted: Set<String> = []
            for part in stretchThinking where counted.insert(part.message).inserted {
                if let value = part.seconds { seconds = (seconds ?? 0) + value }
            }
            if !text.isEmpty || nativeThoughtIsTimed(seconds) {
                items.append(.thinking(id: id, text: text, seconds: seconds, live: false, since: nil))
            }
        }
        items += stretchItems
        stretchThinking = []
        stretchItems = []
    }

    /// The record's lines: "Started" once, at the first spawn; "finished" once, after it.
    func placeStart() {
        guard let record = cards.record, !placedStart else { return }
        flushCalls()
        stretchItems.append(.subagents(id: "subagents:started", lines: [record.started]))
        placedStart = true
    }
    func placeFinish() {
        guard placedStart, !placedFinish, let finished = cards.record?.finished else { return }
        flushCalls()
        if case .subagents(let id, let lines)? = stretchItems.last, id == "subagents:started" {
            stretchItems[stretchItems.count - 1] = .subagents(id: id, lines: lines + [finished])
        } else {
            stretchItems.append(.subagents(id: "subagents:finished", lines: [finished]))
        }
        placedFinish = true
    }

    for (index, item) in raw.enumerated() {
        // They finished before this landed.
        if placedStart, !placedFinish, let finishedAt = cards.record?.finishedAt, let time = times[index], time > finishedAt {
            placeFinish()
        }
        switch item {
        case .thinking(let text, let seconds, let message, _):
            stretchThinking.append((text, seconds, message))
        case .tool(let message):
            toolCalls += 1
            // The record stands for the turn's children: their bookkeeping calls have no second
            // surface; unassociated calls stay visible so errors are not hidden.
            if hasCards, ["shepherd_child_wait", "shepherd_child_result"].contains(message.toolName ?? "") { continue }
            if let id = message.toolCallID, cards.callIDs.contains(id) {
                toolCalls -= 1
                // Later spawns leave no mark: the work around them stays one group.
                placeStart()
                continue
            }
            let value = call(message)
            stretchCalls.append(value)
            calls.append(value)
        case .prose(let text, let streaming):
            flushStretch()
            let parsed = nativeMarkdownParse(text, streaming: live && streaming)
            items.append(.prose(id: nextID("prose"), text: text, blocks: parsed.blocks, openFence: parsed.endsInOpenFence))
            copy.append(text)
        case .note(let text):
            flushStretch()
            items.append(.note(id: nextID("note"), text: text))
        case .error(let text, let count):
            flushStretch()
            items.append(.error(id: nextID("error"), text: text, count: count, final: false))
        case .steer(let text, let sentAt, let images):
            flushStretch()
            items.append(.steer(id: nextID("steer"), text: text, sentAt: sentAt, images: images))
        case .compaction(let row):
            flushStretch()
            items.append(.compaction(row))
        case .question(let row):
            flushStretch()
            items.append(.question(row))
        }
    }
    // Runs with no spawn call in this turn (older publishes, paged-out history) are recorded
    // at its end, as are runs that finished after its last word.
    placeStart()
    placeFinish()
    flushStretch()
    if case .thinking(let text, let seconds, _, let since)? = liveThinking {
        items.append(.thinking(id: nextID("thinking"), text: nativeThinkingIsReadable(text) ? text : "", seconds: seconds,
                               live: true, since: since))
    }
    // An error that ended a finished turn offers Retry.
    if !live, case .error(let id, let text, let count, _)? = items.last {
        items[items.count - 1] = .error(id: id, text: text, count: count, final: true)
    }
    return NativeTurnPresentation(items: items, changes: live ? nil : nativeTurnChanges(calls), toolCalls: toolCalls,
                                  // A question's record is stamped when it was answered, not when pi worked.
                                  copyText: copy.joined(separator: "\n\n"),
                                  endedAt: messages.filter { $0.question == nil }.compactMap(\.timestamp).max(),
                                  betweenTools: betweenTools)
}

/// "Model overloaded — the turn stopped after 6 tool calls." for a turn that ended on an error.
public func nativeTurnErrorText(_ text: String, toolCalls: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard toolCalls > 0 else { return trimmed }
    return "\(trimmed) — the turn stopped after \(nativeCount(toolCalls, "tool call"))."
}

/// Thinking a reader can read: anything but whitespace.
public func nativeThinkingIsReadable(_ text: String) -> Bool {
    text.contains { !$0.isWhitespace }
}

/// Thinking timed at half a second or more, long enough to say how long.
public func nativeThoughtIsTimed(_ seconds: Double?) -> Bool {
    (seconds ?? 0) >= 0.5
}

/// "Thought for 4s", "Thought for 1m 04s", or "Thought" when it was shorter than half a
/// second or the host never timed it.
public func nativeThoughtText(_ seconds: Double?) -> String {
    guard let seconds, nativeThoughtIsTimed(seconds) else { return "Thought" }
    return "Thought for " + (seconds < 60 ? "\(Int(seconds.rounded()))s" : nativeDurationText(seconds))
}

/// `nativeThoughtText` as VoiceOver says it: "Thought for 4 seconds", "Thought for 1 minute
/// 4 seconds".
public func nativeThoughtSpokenText(_ seconds: Double?) -> String {
    guard let seconds, nativeThoughtIsTimed(seconds) else { return "Thought" }
    func unit(_ count: Int, _ name: String) -> String { "\(count) \(name)" + (count == 1 ? "" : "s") }
    if seconds < 60 { return "Thought for " + unit(Int(seconds.rounded()), "second") }
    let whole = Int(seconds)
    let parts = whole < 3600
        ? [unit(whole / 60, "minute"), whole % 60 > 0 ? unit(whole % 60, "second") : nil]
        : [unit(whole / 3600, "hour"), (whole % 3600) / 60 > 0 ? unit((whole % 3600) / 60, "minute") : nil]
    return "Thought for " + parts.compactMap { $0 }.joined(separator: " ")
}

// MARK: Question records (QuestionAnswered)

/// A question pi asked, as the thread keeps it where pi asked: one line, "Agent asked:" and the
/// question, then the answer as the user's bubble (the option's title, Yes or No, or the text
/// the user typed) with "2:51 PM · answered" under it. A question nobody answered (dismissed, or
/// its timeout passed) is the line alone, ending "· not answered".
public struct NativeQuestionRecordRow: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var question: String
    /// The answer's title, in semibold: the chosen option's title, or Yes or No.
    public var title: String?
    /// Text under the title, or the typed answer on its own.
    public var text: String?
    public var answered: Bool
    /// When it was answered (ms).
    public var answeredAt: Double?

    public init(id: String, question: String, title: String? = nil, text: String? = nil, answered: Bool, answeredAt: Double? = nil) {
        self.id = id
        self.question = question
        self.title = title
        self.text = text
        self.answered = answered
        self.answeredAt = answeredAt
    }

    public init(entryID: String, record: NativeQuestionRecord, endedAt: Double?) {
        let question = record.question.trimmingCharacters(in: .whitespacesAndNewlines)
        var title: String?
        var text: String?
        let answered = record.outcome == .answered
        if answered {
            switch record.kind {
            case .select:
                title = record.answer.flatMap { NativeQuestionOption.options([$0]).first?.title }
            case .confirm:
                title = record.confirmed.map { $0 ? NativeConfirmAnswers.yes : NativeConfirmAnswers.no }
            case .input, .editor, nil:
                text = record.answer
            }
            // An empty field sent is still an answer.
            if title == nil, (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "An empty answer" }
        }
        self.init(id: entryID, question: question.isEmpty ? "A question" : question, title: title, text: text,
                  answered: answered, answeredAt: answered ? endedAt : nil)
    }

    /// "2:51 PM · answered", shown under the bubble like every bubble's time.
    public func caption(timeZone: TimeZone = .current) -> String? {
        guard answered else { return nil }
        return answeredAt.map { nativeClockText($0, timeZone: timeZone) + " · answered" } ?? "answered"
    }

    /// What VoiceOver reads for the whole record.
    public var accessibilityLabel: String {
        let answer = [title, text].compactMap { $0 }.joined(separator: ", ")
        return answered ? "Agent asked: \(question), you answered: \(answer)" : "Agent asked: \(question), not answered"
    }
}
