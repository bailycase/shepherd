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
        /// only what the reader can read, normalized, "" when the model shared none: then the
        /// finished row is a plain "Thought for Ns" line, and it is left out when it was not
        /// timed either. `blocks` is finished text parsed as Markdown (reasoning summaries are
        /// Markdown: "**Inspecting SSH config**"); live thinking is never parsed, since it shows
        /// no text.
        case thinking(id: String, text: String, blocks: [NativeMarkdownBlock], seconds: Double?, live: Bool, since: Double?)
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
        /// A failed request to the model, pi's automatic retries of it merged in. `final` when it
        /// ended the turn (it offers Retry); `folded` when it shows as one line: pi retried it
        /// and the turn went on, or the next turn failed the same way (the store folds those).
        case error(id: String, error: NativeTurnError, final: Bool, folded: Bool)
        /// pi retrying the request that just failed, at the end of the live turn.
        case retrying(id: String, line: NativeRetryLine)
        /// A message the user steered in, where pi read it (after the tool work before it).
        /// `sentAt` is when it was sent (ms); `images` how many it carried.
        case steer(id: String, text: String, sentAt: Double?, images: Int)
        /// A compaction where it happened, and what the agent kept.
        case compaction(NativeCompactionRow)
        /// A question pi asked, where it asked, and the user's answer (QuestionAnswered).
        case question(NativeQuestionRecordRow)

        public var id: String {
            switch self {
            case .thinking(let id, _, _, _, _, _), .prose(let id, _, _, _), .subagents(let id, _), .note(let id, _), .error(let id, _, _, _),
                 .steer(let id, _, _, _), .activity(let id, _), .retrying(let id, _): id
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

    /// The turn ended in a failed request: its error card carries Retry and Copy, so the turn
    /// has no footer (ThreadError).
    public var endsInError: Bool {
        if case .error? = items.last { return true }
        return false
    }

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
/// and `thinking` parses a stretch's finished thinking (the store passes memoised ones, so a
/// reply streaming under a thought never parses it again). `errors` says where the agent runs
/// and whether pi is retrying, for the turn's errors.
public func nativeTurnPresentation(
    _ messages: [NativeThreadMessage], live: Bool, cards: NativeCardLayout = .none,
    errors: NativeTurnErrorContext = NativeTurnErrorContext(),
    call: (NativeThreadMessage) -> NativeActivityCall = NativeActivityCall.init,
    thinking: (String) -> [NativeMarkdownBlock] = nativeThinkingBlocks
) -> NativeTurnPresentation {
    enum Raw {
        case thinking(String, Double?, message: String, since: Double?)
        /// `streaming`: the text block a reply is still writing.
        case prose(String, streaming: Bool)
        case tool(NativeThreadMessage)
        case note(String)
        /// Consecutive failed requests: pi's automatic retries of one.
        case error([NativeThreadMessage])
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
            if case .error(let tries)? = raw.last { raw[raw.count - 1] = .error(tries + [message]) }
            else { raw.append(.error([message])) }
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
            let text = RPCContentBlock.normalizedThinking(stretchThinking.map(\.text).filter(nativeThinkingIsReadable).joined(separator: "\n\n"))
            var seconds: Double?
            var counted: Set<String> = []
            for part in stretchThinking where counted.insert(part.message).inserted {
                if let value = part.seconds { seconds = (seconds ?? 0) + value }
            }
            if !text.isEmpty || nativeThoughtIsTimed(seconds) {
                items.append(.thinking(id: id, text: text, blocks: text.isEmpty ? [] : thinking(text), seconds: seconds, live: false, since: nil))
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
        case .error(let tries):
            flushStretch()
            items.append(.error(id: nextID("error"), error: errors.error(tries), final: false, folded: true))
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
        items.append(.thinking(id: nextID("thinking"), text: RPCContentBlock.normalizedThinking(text), blocks: [], seconds: seconds,
                               live: true, since: since))
    }
    // An error the turn ends with shows in full: with Retry once the turn is over, as the
    // retry line while pi retries it. One the turn went on from was retried: it folds.
    if case .error(let id, let error, _, _)? = items.last {
        if !live {
            items[items.count - 1] = .error(id: id, error: error, final: true, folded: false)
        } else if let retry = errors.retry {
            items[items.count - 1] = .retrying(id: id, line: NativeRetryLine(
                title: error.title, glyph: error.kind == .timeout ? "hourglass" : "arrow.clockwise",
                attempt: retry.attempt, maxAttempts: retry.maxAttempts, retryAt: retry.retryAt))
        } else {
            items[items.count - 1] = .error(id: id, error: error, final: false, folded: false)
        }
    }
    // A failed request, or pi retrying it, is what the live turn ends in: nothing else moves.
    var endsInError = false
    switch items.last {
    case .error?, .retrying?: endsInError = true
    default: break
    }
    return NativeTurnPresentation(items: items, changes: live ? nil : nativeTurnChanges(calls), toolCalls: toolCalls,
                                  // A question's record is stamped when it was answered, not when pi worked.
                                  copyText: copy.joined(separator: "\n\n"),
                                  endedAt: messages.filter { $0.question == nil }.compactMap(\.timestamp).max(),
                                  betweenTools: betweenTools && !endsInError)
}

/// What a turn's errors need beyond its messages: the machine the agent runs on (Details'
/// Host, and whom a network error failed from) and pi's retry in progress.
public struct NativeTurnErrorContext: Equatable, Hashable, Sendable {
    public var host: String?
    public var retry: NativeThreadRetry?
    public var timeZone: TimeZone

    public init(host: String? = nil, retry: NativeThreadRetry? = nil, timeZone: TimeZone = .current) {
        self.host = host
        self.retry = retry
        self.timeZone = timeZone
    }

    /// The error a run of failed tries shows: the last one's, and how many there were.
    func error(_ tries: [NativeThreadMessage]) -> NativeTurnError {
        let last = tries.last
        let text = last?.blocks.filter { $0.kind == .text }.map(\.text).last ?? ""
        return NativeTurnError(id: last?.entryID ?? "", text: text, provider: last?.provider, model: last?.model, host: host, attempts: tries.count,
                               firstAt: tries.first?.timestamp, at: last?.timestamp, timeZone: timeZone)
    }
}

/// A stretch's thinking as the expanded row draws it: normalized (no gap where an empty
/// summary part was), then parsed as Markdown.
public func nativeThinkingBlocks(_ text: String) -> [NativeMarkdownBlock] {
    nativeMarkdownBlocks(RPCContentBlock.normalizedThinking(text))
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
