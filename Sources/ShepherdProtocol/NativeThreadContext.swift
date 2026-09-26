import Foundation

/// v4 snapshot field (`RemoteProtocol.nativeContextCapability`): what fills the model's context
/// window. The total is pi's (`get_session_stats` contextUsage); the split and the largest items
/// are the host's estimate from the messages pi holds, scaled to that total. Every member but
/// `largest` is optional: pi reports no window without a model, and no total before its first
/// reply or after a compaction until its next one.
public struct NativeThreadContext: Codable, Hashable, Sendable {
    /// pi's count of the context. nil before pi's first reply, and after a compaction until the
    /// next reply (then `estimate` stands in).
    public var tokens: Int?
    /// The model's context window.
    public var window: Int?
    /// pi compacts on its own once the context passes this: the window less pi's
    /// `compaction.reserveTokens`. nil when auto-compaction is off or the window is unknown.
    public var autoCompactAt: Int?
    /// pi's `autoCompactionEnabled`: it compacts on its own near the window.
    public var autoCompact: Bool?
    /// What a compaction keeps as it is (pi's `compaction.keepRecentTokens`).
    public var keepRecent: Int?
    /// After a compaction, until pi's next reply: about how much is left (pi's
    /// `estimatedTokensAfter`, else the host's own estimate).
    public var estimate: Int?
    /// The context before the latest compaction (its `tokensBefore`).
    public var before: Int?
    /// What the total is made of, as the host estimates it.
    public var split: NativeContextSplit?
    /// The largest tool results in the context, largest first (at most `NativeContextItem.limit`).
    public var largest: [NativeContextItem]
    /// A compaction pi is running.
    public var compacting: NativeCompactionRun?
    /// The thread entry of the latest compaction (its summary), for Show summary.
    public var summaryEntryID: String?

    public init(
        tokens: Int? = nil, window: Int? = nil, autoCompactAt: Int? = nil, autoCompact: Bool? = nil, keepRecent: Int? = nil,
        estimate: Int? = nil, before: Int? = nil, split: NativeContextSplit? = nil, largest: [NativeContextItem] = [],
        compacting: NativeCompactionRun? = nil, summaryEntryID: String? = nil
    ) {
        self.tokens = tokens
        self.window = window
        self.autoCompactAt = autoCompactAt
        self.autoCompact = autoCompact
        self.keepRecent = keepRecent
        self.estimate = estimate
        self.before = before
        self.split = split
        self.largest = largest
        self.compacting = compacting
        self.summaryEntryID = summaryEntryID
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, window, autoCompactAt, autoCompact, keepRecent, estimate, before, split, largest, compacting, summaryEntryID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try values.decodeIfPresent(Int.self, forKey: .tokens)
        window = try values.decodeIfPresent(Int.self, forKey: .window)
        autoCompactAt = try values.decodeIfPresent(Int.self, forKey: .autoCompactAt)
        autoCompact = try values.decodeIfPresent(Bool.self, forKey: .autoCompact)
        keepRecent = try values.decodeIfPresent(Int.self, forKey: .keepRecent)
        estimate = try values.decodeIfPresent(Int.self, forKey: .estimate)
        before = try values.decodeIfPresent(Int.self, forKey: .before)
        split = try values.decodeIfPresent(NativeContextSplit.self, forKey: .split)
        largest = try values.decodeIfPresent([NativeContextItem].self, forKey: .largest) ?? []
        compacting = try values.decodeIfPresent(NativeCompactionRun.self, forKey: .compacting)
        summaryEntryID = try values.decodeIfPresent(String.self, forKey: .summaryEntryID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(tokens, forKey: .tokens)
        try values.encodeIfPresent(window, forKey: .window)
        try values.encodeIfPresent(autoCompactAt, forKey: .autoCompactAt)
        try values.encodeIfPresent(autoCompact, forKey: .autoCompact)
        try values.encodeIfPresent(keepRecent, forKey: .keepRecent)
        try values.encodeIfPresent(estimate, forKey: .estimate)
        try values.encodeIfPresent(before, forKey: .before)
        try values.encodeIfPresent(split, forKey: .split)
        if !largest.isEmpty { try values.encode(largest, forKey: .largest) }
        try values.encodeIfPresent(compacting, forKey: .compacting)
        try values.encodeIfPresent(summaryEntryID, forKey: .summaryEntryID)
    }
}

/// What the context is made of, in tokens scaled to pi's total. pi gives no breakdown: the host
/// sizes each part from the messages pi holds (four characters a token, as pi estimates).
public struct NativeContextSplit: Codable, Hashable, Sendable {
    /// pi's system prompt and the tools' definitions.
    public var system: Int
    /// Instruction files pi loaded into the prompt (AGENTS.md, CLAUDE.md).
    public var instructions: Int
    /// User and assistant messages, the agent's calls, and summaries.
    public var messages: Int
    public var toolResults: Int
    /// The instruction files' names, as pi loaded them.
    public var instructionFiles: [String]

    public init(system: Int, instructions: Int, messages: Int, toolResults: Int, instructionFiles: [String] = []) {
        self.system = system
        self.instructions = instructions
        self.messages = messages
        self.toolResults = toolResults
        self.instructionFiles = instructionFiles
    }

    private enum CodingKeys: String, CodingKey { case system, instructions, messages, toolResults, instructionFiles }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        system = try values.decodeIfPresent(Int.self, forKey: .system) ?? 0
        instructions = try values.decodeIfPresent(Int.self, forKey: .instructions) ?? 0
        messages = try values.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        toolResults = try values.decodeIfPresent(Int.self, forKey: .toolResults) ?? 0
        instructionFiles = try values.decodeIfPresent([String].self, forKey: .instructionFiles) ?? []
    }

    public var total: Int { system + instructions + messages + toolResults }
}

/// One large item in the context: a tool result, named by the file or command it came from.
public struct NativeContextItem: Codable, Hashable, Sendable, Identifiable {
    public static let limit = 3

    public enum Kind: String, Codable, Hashable, Sendable {
        case file, command, tool

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .tool
        }
    }

    /// The thread entry to find it by (a tool result's `t:<call id>`).
    public var entryID: String
    public var kind: Kind
    /// A file's name, a command's first line, or the tool's name.
    public var label: String
    public var tokens: Int

    public var id: String { entryID }

    public init(entryID: String, kind: Kind, label: String, tokens: Int) {
        self.entryID = entryID
        self.kind = kind
        self.label = label
        self.tokens = tokens
    }
}

/// Why pi compacted (`compaction_start.reason`).
public enum NativeCompactionReason: String, Codable, Hashable, Sendable {
    /// Someone asked for it (`compact`, `/compact`, or Compact now).
    case manual
    /// The context passed the auto-compact mark.
    case threshold
    /// The model refused a prompt over its window; pi compacted and retries.
    case overflow
    /// From a newer pi or host.
    case unknown

    public init(from decoder: Decoder) throws {
        self = NativeCompactionReason(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    public init(pi value: String?) {
        self = value.flatMap(NativeCompactionReason.init(rawValue:)) ?? .unknown
    }
}

/// A compaction pi is running: from `compaction_start` to `compaction_end`.
public struct NativeCompactionRun: Codable, Hashable, Sendable {
    public var reason: NativeCompactionReason
    /// When it started (ms since epoch).
    public var startedAt: Double
    /// The context it is summarizing.
    public var tokens: Int?

    public init(reason: NativeCompactionReason, startedAt: Double, tokens: Int? = nil) {
        self.reason = reason
        self.startedAt = startedAt
        self.tokens = tokens
    }
}

/// A compaction in the thread (`NativeThreadMessage.compaction`): a finished one is pi's
/// `compactionSummary` message in history, carrying what the agent kept; one running, or one
/// that stopped or failed, is a live row (role "compaction").
public struct NativeCompaction: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case running, done, stopped, failed

        public init(from decoder: Decoder) throws {
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .done
        }
    }

    public var phase: Phase
    /// nil for a compaction this host did not see happen (before it started, or another pi's).
    public var reason: NativeCompactionReason?
    public var tokensBefore: Int?
    /// pi's estimate of the context right after (`estimatedTokensAfter`), when the host saw it.
    public var tokensAfter: Int?
    /// What the agent kept: pi's summary, in the agent's own sections (clipped to the host's
    /// text limit).
    public var summary: String?
    /// An overflow compaction pi retries the prompt after.
    public var willRetry: Bool?
    /// Why a compaction failed.
    public var error: String?

    public init(phase: NativeCompaction.Phase, reason: NativeCompactionReason? = nil, tokensBefore: Int? = nil, tokensAfter: Int? = nil,
                summary: String? = nil, willRetry: Bool? = nil, error: String? = nil) {
        self.phase = phase
        self.reason = reason
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.summary = summary
        self.willRetry = willRetry
        self.error = error
    }
}
