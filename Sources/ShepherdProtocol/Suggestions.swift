import Foundation

// Settings ▸ Experiments ▸ Suggested instructions: when an agent learns something the hard way
// (a re-run, a failed check, a correction from the user) it drafts one line for Shepherd's root
// instructions with the instructions extension's `suggest_instruction` tool
// (`ExtensionMessage.suggestInstruction`). The line waits on the host until the user adds it to
// its file or dismisses it; nothing is written before that. Remote clients read and act on a
// host's suggestions over `RemoteRequest.suggestions` (`RemoteProtocol.suggestionsCapability`).

/// The experiment's settings on a host: off until the user turns it on.
public struct SuggestedInstructionsSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// When it was last turned on (seconds since 1970): "on since Sep 12".
    public var since: Double?
    /// The agents that may suggest: threads, automations, or both.
    public var sources: Set<SuggestionSource.Kind>
    /// The files agents may suggest for. `APPEND_SYSTEM.md` overrides everything else, so it is
    /// off until the user wants it.
    public var files: Set<InstructionFile>

    public init(enabled: Bool = false, since: Double? = nil,
                sources: Set<SuggestionSource.Kind> = Set(SuggestionSource.Kind.allCases),
                files: Set<InstructionFile> = [.agents]) {
        self.enabled = enabled
        self.since = since
        self.sources = sources
        self.files = files
    }

    /// The files an agent of `kind` may suggest for right now, in file order; empty when it may
    /// not suggest at all.
    public func files(for kind: SuggestionSource.Kind) -> [InstructionFile] {
        guard enabled, sources.contains(kind) else { return [] }
        return InstructionFile.allCases.filter(files.contains)
    }
}

/// Where a suggestion came from: the kind of agent and its name when it suggested.
public struct SuggestionSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        /// An agent the user started (a thread).
        case thread
        /// An automation's run.
        case automation
    }

    public var kind: Kind
    /// "Fix flaky ledger test", "Nightly dependency bump".
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// A line waiting for the user.
public struct InstructionSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The line as it would be added: one Markdown list item ("- Ask for join keys before adding
    /// an event.").
    public var line: String
    /// Why, in the agent's words.
    public var reason: String
    public var file: InstructionFile
    public var source: SuggestionSource
    /// Seconds since 1970.
    public var suggestedAt: Double

    public init(id: UUID = UUID(), line: String, reason: String, file: InstructionFile, source: SuggestionSource,
                suggestedAt: Double) {
        self.id = id
        self.line = line
        self.reason = reason
        self.file = file
        self.source = source
        self.suggestedAt = suggestedAt
    }
}

/// A suggestion the user added, which Undo takes back out of its file.
public struct AddedSuggestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The line as it went into the file.
    public var line: String
    public var file: InstructionFile
    /// The agent that suggested it ("Ledger cleanup").
    public var sourceName: String
    /// Seconds since 1970.
    public var addedAt: Double

    public init(id: UUID, line: String, file: InstructionFile, sourceName: String, addedAt: Double) {
        self.id = id
        self.line = line
        self.file = file
        self.sourceName = sourceName
        self.addedAt = addedAt
    }
}

/// A host's suggestions as a client reads them: the experiment's settings, the lines waiting,
/// and the lines added from them, each newest first.
public struct SuggestionsSnapshot: Codable, Hashable, Sendable {
    public var settings: SuggestedInstructionsSettings
    public var waiting: [InstructionSuggestion]
    public var added: [AddedSuggestion]

    public init(settings: SuggestedInstructionsSettings = SuggestedInstructionsSettings(),
                waiting: [InstructionSuggestion] = [], added: [AddedSuggestion] = []) {
        self.settings = settings
        self.waiting = waiting
        self.added = added
    }
}

/// What became of a line an agent suggested (`ExtensionReply.suggestion`).
public enum SuggestionOutcome: String, Codable, Hashable, Sendable {
    /// It waits for the user.
    case waiting
    /// The same line is already waiting.
    case alreadyWaiting
    /// The user dismissed it before; it is never suggested again.
    case dismissed
    /// Its file already has it.
    case inFile
}

/// Settings ▸ Experiments on a remote host (`RemoteProtocol.suggestionsCapability`). Every request
/// answers with the host's suggestions as they are afterwards (`RemoteReply.suggestions`).
public enum RemoteSuggestionsRequest: Codable, Hashable, Sendable {
    /// The settings, what is waiting, and what was added.
    case fetch
    /// Turn the experiment on or off, or change what it learns from and suggests for. Turning it
    /// off keeps the lines added and drops what is waiting.
    case configure(SuggestedInstructionsSettings)
    /// Add a waiting line to its file: `line` when it was edited first, `file` when it was
    /// retargeted.
    case add(id: UUID, line: String?, file: InstructionFile?)
    /// Add every waiting line to its file.
    case addAll
    /// Drop a waiting line; the same line is never suggested again.
    case dismiss(id: UUID)
    /// Take an added line back out of its file.
    case undo(id: UUID)
}
