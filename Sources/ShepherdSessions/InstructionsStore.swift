import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Shepherd's root instructions for pi on this host (Settings ▸ Instructions): `AGENTS.md` and
/// `APPEND_SYSTEM.md` in `directory`, where the instructions extension reads them when a pi
/// session starts, and `history.json` beside them (the newest `limit` saves of each file, with
/// their text, so any of them can be put back).
///
/// The server serves remote clients from it and the Mac's own Settings page through it; a lock
/// makes each read or write whole. The files are small, so they are read and written in place.
public final class InstructionsStore: @unchecked Sendable {
    public static let limit = 30

    private struct HistoryFile: Codable {
        var version = 1
        /// Newest first.
        var revisions: [InstructionRevision] = []
    }

    public let directory: URL
    private let lock = NSLock()
    private let observerLock = NSLock()
    private var observer: (@Sendable (InstructionFile) -> Void)?

    /// Told, from whichever thread saved, after a file's text changed (Fleet's sync reads it then).
    public var onChange: (@Sendable (InstructionFile) -> Void)? {
        get { observerLock.withLock { observer } }
        set { observerLock.withLock { observer = newValue } }
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public enum StoreError: Error, Equatable, CustomStringConvertible {
        case noSuchRevision
        case writeFailed(String)

        public var description: String {
            switch self {
            case .noSuchRevision: "That version is no longer in the history."
            case .writeFailed(let reason): "Couldn't save the instructions: \(reason)"
            }
        }
    }

    /// One file's text as it is now (empty while it has none).
    public func content(_ file: InstructionFile) -> String {
        lock.withLock { read(file) }
    }

    /// The files as they are now, where they live, and their history (newest first).
    public func snapshot() -> InstructionsSnapshot {
        lock.withLock { unlockedSnapshot() }
    }

    /// Replaces one file. Saving what it already holds changes nothing and adds no history.
    /// `origin` names where the save came from ("iPhone", a host), nil for this host's own
    /// Settings; `sync` records it as a copy of another host's file.
    @discardableResult
    public func save(_ file: InstructionFile, content: String, origin: String? = nil, sync: Bool = false,
                     now: Date = Date()) throws -> InstructionsSnapshot {
        let snapshot = try lock.withLock { () -> (InstructionsSnapshot, Bool) in
            let old = read(file)
            guard old != content else { return (unlockedSnapshot(), false) }
            let summary = sync ? "Synced from \(origin ?? "another host")" : InstructionsText.summary(from: old, to: content)
            try write(file, content: content, summary: summary, origin: origin, now: now)
            return (unlockedSnapshot(), true)
        }
        if snapshot.1 { onChange?(file) }
        return snapshot.0
    }

    /// Puts a saved version back, as a new save ("Restored the Sep 19 version").
    @discardableResult
    public func restore(revisionID: UUID, origin: String? = nil, now: Date = Date()) throws -> InstructionsSnapshot {
        let result = try lock.withLock { () -> (InstructionsSnapshot, InstructionFile?) in
            guard let revision = loadHistory().revisions.first(where: { $0.id == revisionID }) else {
                throw StoreError.noSuchRevision
            }
            guard read(revision.file) != revision.content else { return (unlockedSnapshot(), nil) }
            let day = Date(timeIntervalSince1970: revision.savedAt).formatted(.dateTime.month(.abbreviated).day())
            try write(revision.file, content: revision.content, summary: "Restored the \(day) version", origin: origin, now: now)
            return (unlockedSnapshot(), revision.file)
        }
        if let file = result.1 { onChange?(file) }
        return result.0
    }

    // MARK: Locked

    private func unlockedSnapshot() -> InstructionsSnapshot {
        InstructionsSnapshot(
            agents: read(.agents),
            appendSystem: read(.appendSystem),
            directory: (directory.path as NSString).abbreviatingWithTildeInPath,
            history: loadHistory().revisions.map(\.entry)
        )
    }

    private func url(_ file: InstructionFile) -> URL {
        directory.appendingPathComponent(file.fileName)
    }

    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    private func read(_ file: InstructionFile) -> String {
        (try? String(contentsOf: url(file), encoding: .utf8)) ?? ""
    }

    private func loadHistory() -> HistoryFile {
        guard let data = try? Data(contentsOf: historyURL),
              let history = try? JSONDecoder().decode(HistoryFile.self, from: data) else { return HistoryFile() }
        return history
    }

    /// Writes the file, then records the save; the newest `limit` saves of each file are kept.
    private func write(_ file: InstructionFile, content: String, summary: String, origin: String?, now: Date) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url(file), options: .atomic)
            var history = loadHistory()
            history.revisions.insert(InstructionRevision(file: file, savedAt: now.timeIntervalSince1970, summary: summary,
                                                         origin: origin, content: content), at: 0)
            var kept: [InstructionFile: Int] = [:]
            history.revisions = history.revisions.filter { revision in
                kept[revision.file, default: 0] += 1
                return kept[revision.file, default: 0] <= Self.limit
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(history).write(to: historyURL, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }
}
