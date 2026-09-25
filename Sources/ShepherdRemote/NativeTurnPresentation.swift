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
        /// Thinking for one stretch of work (merged between prose), or the live block.
        case thinking(id: String, text: String, seconds: Double?, live: Bool, since: Double?)
        /// `openFence`: the text ends inside a fence still open (the block a reply is writing).
        case prose(id: String, text: String, blocks: [NativeMarkdownBlock], openFence: Bool)
        /// A stretch of tool work: its lines, folded into one summary line once there are two.
        case work(NativeWorkGroup)
        /// A line of the turn's subagent record: where they started, or where they finished.
        case subagents(id: String, line: NativeSubagentRecordLine, finished: Bool)
        case note(id: String, text: String)
        /// A failed provider request; `final` when it ended the turn.
        case error(id: String, text: String, count: Int, final: Bool)
        /// A message the user steered in, where pi read it (after the tool work before it).
        /// `sentAt` is when it was sent (ms); `images` how many it carried.
        case steer(id: String, text: String, sentAt: Double?, images: Int)

        public var id: String {
            switch self {
            case .thinking(let id, _, _, _, _), .prose(let id, _, _, _), .subagents(let id, _, _), .note(let id, _), .error(let id, _, _, _),
                 .steer(let id, _, _, _): id
            case .work(let group): "work:" + group.id
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

    public init(items: [Item], changes: NativeTurnChanges?, toolCalls: Int, copyText: String, endedAt: Double?) {
        self.items = items
        self.changes = changes
        self.toolCalls = toolCalls
        self.copyText = copyText
        self.endedAt = endedAt
    }

    /// The last item is live thinking (the view shows it in place of the working row).
    public var endsInLiveThinking: Bool {
        if case .thinking(_, _, _, true, _)? = items.last { return true }
        return false
    }

    /// The last item is work with a running call.
    public var endsInLiveActivity: Bool {
        if case .work(let group)? = items.last { return group.isLive }
        return false
    }
}

/// Builds a turn's presentation. Consecutive calls of one kind merge into activity lines, and a
/// stretch's lines form one work group; prose and cards split them. Thinking between prose blocks folds into one "Thought for Ns" at the
/// start of its stretch, so a thinking model's per-call reasoning does not break every line
/// in two; the block still streaming stays last, live. `call` builds a call from its message
/// (the store passes a memoised one).
public func nativeTurnPresentation(
    _ messages: [NativeThreadMessage], live: Bool, cards: NativeCardLayout = .none,
    call: (NativeThreadMessage) -> NativeActivityCall = NativeActivityCall.init
) -> NativeTurnPresentation {
    enum Raw {
        case thinking(String, Double?, message: String, since: Double?)
        case prose(String)
        case tool(NativeThreadMessage)
        case note(String)
        case error(String, Int)
        case steer(String, Double?, Int)
    }

    var raw: [Raw] = []
    // When each raw item's message landed (ms), for where the subagents' finished line goes.
    var times: [Double?] = []
    for message in messages {
        defer { while times.count < raw.count { times.append(message.timestamp) } }
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
        for block in message.blocks {
            switch block.kind {
            case .thinking:
                raw.append(.thinking(block.text, message.thinkingSeconds, message: message.entryID,
                                     since: message.status == "streaming" ? message.timestamp : nil))
            case .unsupportedImage: raw.append(.note("Image attached"))
            case .text:
                if message.role == "assistant" || message.role == "user" {
                    raw.append(.prose(block.text))
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
        guard !stretchCalls.isEmpty else { return }
        if let group = nativeWorkGroup(stretchCalls) { stretchItems.append(.work(group)) }
        stretchCalls = []
    }
    func flushStretch() {
        flushCalls()
        if !stretchThinking.isEmpty {
            let text = stretchThinking.map(\.text).joined(separator: "\n\n")
            var seconds: Double?
            var counted: Set<String> = []
            for part in stretchThinking where counted.insert(part.message).inserted {
                if let value = part.seconds { seconds = (seconds ?? 0) + value }
            }
            items.append(.thinking(id: nextID("thinking"), text: text, seconds: seconds, live: false, since: nil))
        }
        items += stretchItems
        stretchThinking = []
        stretchItems = []
    }

    /// The record's lines: "Started" once, at the first spawn; "finished" once, after it.
    func placeStart() {
        guard let record = cards.record, !placedStart else { return }
        flushCalls()
        stretchItems.append(.subagents(id: "subagents:started", line: record.started, finished: false))
        placedStart = true
    }
    func placeFinish() {
        guard placedStart, !placedFinish, let finished = cards.record?.finished else { return }
        flushCalls()
        stretchItems.append(.subagents(id: "subagents:finished", line: finished, finished: true))
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
        case .prose(let text):
            flushStretch()
            let parsed = nativeMarkdownParse(text)
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
        }
    }
    // Runs with no spawn call in this turn (older publishes, paged-out history) are recorded
    // at its end, as are runs that finished after its last word.
    placeStart()
    placeFinish()
    flushStretch()
    if case .thinking(let text, let seconds, _, let since)? = liveThinking {
        items.append(.thinking(id: nextID("thinking"), text: text, seconds: seconds, live: true, since: since))
    }
    // An error that ended a finished turn offers Retry.
    if !live, case .error(let id, let text, let count, _)? = items.last {
        items[items.count - 1] = .error(id: id, text: text, count: count, final: true)
    }
    return NativeTurnPresentation(items: items, changes: live ? nil : nativeTurnChanges(calls), toolCalls: toolCalls,
                                  copyText: copy.joined(separator: "\n\n"), endedAt: messages.compactMap(\.timestamp).max())
}

/// "Model overloaded — the turn stopped after 6 tool calls." for a turn that ended on an error.
public func nativeTurnErrorText(_ text: String, toolCalls: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard toolCalls > 0 else { return trimmed }
    return "\(trimmed) — the turn stopped after \(nativeCount(toolCalls, "tool call"))."
}

/// "Thought for 4s", "Thought for 1m 04s", or "Thought" when it was shorter than half a
/// second or the host never timed it.
public func nativeThoughtText(_ seconds: Double?) -> String {
    guard let seconds, seconds >= 0.5 else { return "Thought" }
    return "Thought for " + (seconds < 60 ? "\(Int(seconds.rounded()))s" : nativeDurationText(seconds))
}
