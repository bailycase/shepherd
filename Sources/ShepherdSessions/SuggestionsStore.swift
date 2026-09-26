import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Experiments ▸ Suggested instructions on this host: the experiment's settings, the
/// lines agents suggested that wait for the user, the lines added from them (so Undo can take one
/// back out), and the lessons the user dismissed (never suggested again). One JSON file beside
/// the instructions, `suggestions.json`; a lock makes each read or write whole.
///
/// Adding a line writes it to its file through `InstructionsStore`, so the file's history
/// records it like any other save.
public final class SuggestionsStore: @unchecked Sendable {
    /// The most lines kept waiting, added, and dismissed; the oldest go first.
    public static let waitingLimit = 30
    public static let addedLimit = 30
    public static let dismissedLimit = 300

    private struct Stored: Codable {
        var version = 1
        var settings = SuggestedInstructionsSettings()
        /// Newest first.
        var waiting: [InstructionSuggestion] = []
        /// Newest first.
        var added: [AddedSuggestion] = []
        /// `InstructionsText.lineKey` of every dismissed line, newest first.
        var dismissed: [String] = []
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case noSuchSuggestion
        case writeFailed(String)

        public var description: String {
            switch self {
            case .noSuchSuggestion: "That suggestion is no longer waiting."
            case .writeFailed(let reason): "Couldn't save the suggestions: \(reason)"
            }
        }
    }

    public let url: URL
    private let instructions: InstructionsStore
    private let lock = NSLock()

    public init(url: URL, instructions: InstructionsStore) {
        self.url = url
        self.instructions = instructions
    }

    public func snapshot() -> SuggestionsSnapshot {
        lock.withLock { Self.snapshot(of: load()) }
    }

    /// Changes the experiment's settings. Turning it on starts "on since" now; turning it off
    /// drops what is waiting and keeps the lines already added.
    @discardableResult
    public func configure(_ settings: SuggestedInstructionsSettings, now: Date = Date()) throws -> SuggestionsSnapshot {
        try lock.withLock {
            var stored = load()
            var settings = settings
            if settings.enabled {
                settings.since = stored.settings.enabled ? stored.settings.since ?? now.timeIntervalSince1970 : now.timeIntervalSince1970
            } else {
                settings.since = nil
                stored.waiting = []
            }
            stored.settings = settings
            try save(stored)
            return Self.snapshot(of: stored)
        }
    }

    /// Records a line an agent suggested, unless the same lesson is already waiting, was
    /// dismissed, or is in the file. The caller has checked the settings allow it.
    public func suggest(line: String, reason: String, file: InstructionFile, source: SuggestionSource,
                        now: Date = Date()) throws -> (outcome: SuggestionOutcome, snapshot: SuggestionsSnapshot) {
        try lock.withLock {
            var stored = load()
            let item = InstructionsText.listItem(line)
            let key = InstructionsText.lineKey(item)
            if stored.waiting.contains(where: { InstructionsText.lineKey($0.line) == key }) {
                return (.alreadyWaiting, Self.snapshot(of: stored))
            }
            if stored.dismissed.contains(key) { return (.dismissed, Self.snapshot(of: stored)) }
            if InstructionsText.holds(item, in: instructions.snapshot()[file]) { return (.inFile, Self.snapshot(of: stored)) }
            let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            stored.waiting.insert(InstructionSuggestion(line: item, reason: reason, file: file, source: source,
                                                        suggestedAt: now.timeIntervalSince1970), at: 0)
            stored.waiting = Array(stored.waiting.prefix(Self.waitingLimit))
            try save(stored)
            return (.waiting, Self.snapshot(of: stored))
        }
    }

    /// Adds a waiting line to its file (`line` when it was edited first, `file` when it was
    /// retargeted) and remembers it for Undo. A file that already has the lesson is left as it is.
    @discardableResult
    public func add(_ id: UUID, line: String? = nil, file: InstructionFile? = nil, now: Date = Date()) throws -> SuggestionsSnapshot {
        try lock.withLock {
            var stored = load()
            guard let index = stored.waiting.firstIndex(where: { $0.id == id }) else { throw StoreError.noSuchSuggestion }
            let suggestion = stored.waiting.remove(at: index)
            try write(suggestion, line: line, file: file, into: &stored, now: now)
            try save(stored)
            return Self.snapshot(of: stored)
        }
    }

    /// Adds every waiting line to its file, oldest first so the files read in the order they
    /// were learned.
    @discardableResult
    public func addAll(now: Date = Date()) throws -> SuggestionsSnapshot {
        try lock.withLock {
            var stored = load()
            let waiting = stored.waiting
            stored.waiting = []
            for suggestion in waiting.reversed() {
                try write(suggestion, line: nil, file: nil, into: &stored, now: now)
            }
            try save(stored)
            return Self.snapshot(of: stored)
        }
    }

    /// Drops a waiting line; its lesson is never suggested again.
    @discardableResult
    public func dismiss(_ id: UUID) throws -> SuggestionsSnapshot {
        try lock.withLock {
            var stored = load()
            guard let index = stored.waiting.firstIndex(where: { $0.id == id }) else { throw StoreError.noSuchSuggestion }
            let suggestion = stored.waiting.remove(at: index)
            stored.dismissed.insert(InstructionsText.lineKey(suggestion.line), at: 0)
            stored.dismissed = Array(stored.dismissed.prefix(Self.dismissedLimit))
            try save(stored)
            return Self.snapshot(of: stored)
        }
    }

    /// Takes an added line back out of its file. A line already gone from the file (edited away
    /// by hand) only leaves the list.
    @discardableResult
    public func undo(_ id: UUID) throws -> SuggestionsSnapshot {
        try lock.withLock {
            var stored = load()
            guard let index = stored.added.firstIndex(where: { $0.id == id }) else { throw StoreError.noSuchSuggestion }
            let added = stored.added.remove(at: index)
            if let text = InstructionsText.removing(added.line, from: instructions.snapshot()[added.file]) {
                try instructions.save(added.file, content: text, origin: added.sourceName)
            }
            try save(stored)
            return Self.snapshot(of: stored)
        }
    }

    // MARK: Locked

    /// Writes one suggestion's line into its file and records it as added.
    private func write(_ suggestion: InstructionSuggestion, line: String?, file: InstructionFile?,
                       into stored: inout Stored, now: Date) throws {
        let item = InstructionsText.listItem(line ?? suggestion.line)
        let file = file ?? suggestion.file
        let text = instructions.snapshot()[file]
        if !InstructionsText.holds(item, in: text) {
            try instructions.save(file, content: InstructionsText.appending(item, to: text), origin: suggestion.source.name, now: now)
        }
        stored.added.insert(AddedSuggestion(id: suggestion.id, line: item, file: file, sourceName: suggestion.source.name,
                                            addedAt: now.timeIntervalSince1970), at: 0)
        stored.added = Array(stored.added.prefix(Self.addedLimit))
    }

    private static func snapshot(of stored: Stored) -> SuggestionsSnapshot {
        SuggestionsSnapshot(settings: stored.settings, waiting: stored.waiting, added: stored.added)
    }

    private func load() -> Stored {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored()
        }
        return stored
    }

    private func save(_ stored: Stored) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(stored).write(to: url, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}
