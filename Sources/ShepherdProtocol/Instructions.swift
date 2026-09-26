import Foundation

// Settings ▸ Instructions: Shepherd's root instructions for pi. Shepherd keeps its own `AGENTS.md`
// and `APPEND_SYSTEM.md` in its support directory (`ShepherdPaths.instructionsDirectory`) and
// hands them to every pi it launches through the instructions extension, so the user's own
// `~/.pi/agent` is never written. Remote clients read and save a host's files over
// `RemoteRequest.instructions` (`RemoteProtocol.instructionsCapability`).

/// One of the two root instruction files.
public enum InstructionFile: String, Codable, CaseIterable, Hashable, Sendable {
    /// How you work: read like pi's own root AGENTS.md, before any parent folder's or repo's.
    case agents = "AGENTS.md"
    /// Rules that override everything else: added to pi's system prompt.
    case appendSystem = "APPEND_SYSTEM.md"

    public var fileName: String { rawValue }
}

/// A saved version of an instruction file, as the host keeps it (newest first, a bounded
/// number per file). Times are seconds since 1970.
public struct InstructionRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var file: InstructionFile
    public var savedAt: Double
    /// What changed, in words: "Added “Never force-push.”", "Synced from studio",
    /// "Restored the Sep 19 version".
    public var summary: String
    /// Where the save came from ("This Mac", "iPhone", a host's name), nil for the host itself.
    public var origin: String?
    /// The whole file after this save.
    public var content: String

    public init(id: UUID = UUID(), file: InstructionFile, savedAt: Double, summary: String, origin: String? = nil, content: String) {
        self.id = id
        self.file = file
        self.savedAt = savedAt
        self.summary = summary
        self.origin = origin
        self.content = content
    }

    /// The revision as a client lists it: everything but the content.
    public var entry: InstructionHistoryEntry {
        InstructionHistoryEntry(id: id, file: file, savedAt: savedAt, summary: summary, origin: origin)
    }
}

/// A saved version as a client lists it; Restore names it by `id`.
public struct InstructionHistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var file: InstructionFile
    public var savedAt: Double
    public var summary: String
    public var origin: String?

    public init(id: UUID, file: InstructionFile, savedAt: Double, summary: String, origin: String? = nil) {
        self.id = id
        self.file = file
        self.savedAt = savedAt
        self.summary = summary
        self.origin = origin
    }
}

/// A host's instruction files as a client reads them: each file's text (empty while it has
/// none), where the host keeps them, and what was saved when (newest first).
public struct InstructionsSnapshot: Codable, Hashable, Sendable {
    public var agents: String
    public var appendSystem: String
    /// The host's instructions directory, with its home folder as `~`.
    public var directory: String
    public var history: [InstructionHistoryEntry]

    public init(agents: String = "", appendSystem: String = "", directory: String, history: [InstructionHistoryEntry] = []) {
        self.agents = agents
        self.appendSystem = appendSystem
        self.directory = directory
        self.history = history
    }

    public subscript(file: InstructionFile) -> String {
        get {
            switch file {
            case .agents: agents
            case .appendSystem: appendSystem
            }
        }
        set {
            switch file {
            case .agents: agents = newValue
            case .appendSystem: appendSystem = newValue
            }
        }
    }

    /// The file's path on the host, for its editor header ("~/Library/…/instructions/AGENTS.md").
    public func path(of file: InstructionFile) -> String {
        directory.hasSuffix("/") ? directory + file.fileName : directory + "/" + file.fileName
    }

    /// When the file was last saved, if the host kept its history.
    public func lastSaved(_ file: InstructionFile) -> Double? {
        history.first { $0.file == file }?.savedAt
    }
}

/// Settings ▸ Instructions on a remote host (`RemoteProtocol.instructionsCapability`). Every
/// request answers with the host's files as they are afterwards (`RemoteReply.instructions`).
public enum RemoteInstructionsRequest: Codable, Hashable, Sendable {
    /// The files, where they live and their history.
    case fetch
    /// Replace one file. `origin` names the client in the history ("studio", "iPhone"); `sync`
    /// marks a copy of another host's file (Same on every host, Copy … to …), which the history
    /// records as "Synced from origin".
    case save(file: InstructionFile, content: String, origin: String, sync: Bool)
    /// Put a saved version back.
    case restore(revisionID: UUID, origin: String)
}
