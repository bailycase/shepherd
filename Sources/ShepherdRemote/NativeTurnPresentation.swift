import Foundation
import ShepherdProtocol

/// Where a turn's subagent cards replace their spawn calls: the spawn call ids that have
/// cards, and whether the group folds into one stack (a strip or the ledger) at the first one.
public struct NativeCardLayout: Equatable, Hashable, Sendable {
    public var callIDs: Set<String>
    public var folds: Bool

    public init(callIDs: Set<String> = [], folds: Bool = false) {
        self.callIDs = callIDs
        self.folds = folds
    }

    public static let none = NativeCardLayout()

    /// A turn's placement as the thread lays it out: the group folds once it has more than
    /// the strip threshold of runs or every run has finished.
    public init(_ placement: NativeSubagentPlacement?) {
        guard let placement, !placement.byToolCall.isEmpty else { self.init(); return }
        let all = placement.all
        self.init(callIDs: Set(placement.byToolCall.keys),
                  folds: all.count > NativeRunsStrip.collapseThreshold || nativeSubagentGroupIsTerminal(all))
    }
}

/// An agent turn as the thread draws it (NWThread board): thinking, prose, activity lines,
/// subagent cards where their spawn calls were, notes and errors, then the changes card and
/// the footer. Built once per turn change; views only read it.
public struct NativeTurnPresentation: Equatable, Sendable {
    public enum Item: Equatable, Sendable, Identifiable {
        /// Thinking for one stretch of work (merged between prose), or the live block.
        case thinking(id: String, text: String, seconds: Double?, live: Bool, since: Double?)
        case prose(id: String, text: String, blocks: [NativeMarkdownBlock])
        case activity(NativeActivityBurst)
        /// Subagent cards at a spawn position: `callIDs` look up the placement; `all` is a
        /// folded group (every run of the turn in one stack).
        case subagents(id: String, callIDs: [String], all: Bool)
        case note(id: String, text: String)
        /// A failed provider request; `final` when it ended the turn.
        case error(id: String, text: String, count: Int, final: Bool)

        public var id: String {
            switch self {
            case .thinking(let id, _, _, _, _), .prose(let id, _, _), .subagents(let id, _, _), .note(let id, _), .error(let id, _, _, _): id
            case .activity(let burst): "burst:" + burst.id
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

    /// The last item is a running call.
    public var endsInLiveActivity: Bool {
        if case .activity(let burst)? = items.last { return burst.state == .running }
        return false
    }
}

/// Builds a turn's presentation. Consecutive calls of one kind merge into activity lines;
/// prose splits them. Thinking between prose blocks folds into one "Thought for Ns" at the
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
    }

    var raw: [Raw] = []
    for message in messages {
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
    }

    // The block still streaming is the turn's live thinking; everything else folds.
    var liveThinking: Raw?
    if live, case .thinking? = raw.last { liveThinking = raw.removeLast() }

    var items: [NativeTurnPresentation.Item] = []
    var calls: [NativeActivityCall] = []
    var toolCalls = 0
    var copy: [String] = []
    var ordinal = 0
    var placedFold = false
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
        stretchItems += nativeActivityBursts(stretchCalls).map { .activity($0) }
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

    for item in raw {
        switch item {
        case .thinking(let text, let seconds, let message, _):
            stretchThinking.append((text, seconds, message))
        case .tool(let message):
            toolCalls += 1
            // Once cards stand for a turn's children, their bookkeeping calls have no second
            // surface; unassociated calls stay visible so errors are not hidden.
            if hasCards, ["shepherd_child_wait", "shepherd_child_result"].contains(message.toolName ?? "") { continue }
            if let id = message.toolCallID, cards.callIDs.contains(id) {
                toolCalls -= 1
                flushCalls()
                if cards.folds {
                    if !placedFold {
                        stretchItems.append(.subagents(id: "cards:" + id, callIDs: [], all: true))
                        placedFold = true
                    }
                } else {
                    stretchItems.append(.subagents(id: "cards:" + id, callIDs: [id], all: false))
                }
                continue
            }
            let value = call(message)
            stretchCalls.append(value)
            calls.append(value)
        case .prose(let text):
            flushStretch()
            items.append(.prose(id: nextID("prose"), text: text, blocks: nativeMarkdownBlocks(text)))
            copy.append(text)
        case .note(let text):
            flushStretch()
            items.append(.note(id: nextID("note"), text: text))
        case .error(let text, let count):
            flushStretch()
            items.append(.error(id: nextID("error"), text: text, count: count, final: false))
        }
    }
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
