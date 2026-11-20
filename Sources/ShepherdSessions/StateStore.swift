import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdProtocol

/// Errors that prevent a corrupt state file from being safely replaced.
enum StateStoreError: Error, CustomStringConvertible, Sendable {
    case repairRequired(path: String, reason: String)
    case readOnly

    var description: String {
        switch self {
        case .repairRequired(let path, let reason):
            return "Workspace needs repair. Writes to \(path) are disabled: \(reason)"
        case .readOnly:
            return "Workspace is open read-only."
        }
    }
}

/// Persists ShepherdState as JSON with atomic writes. Callers serialize access
/// (the in-process server confines all use to its serial queue), except `committed`, which any
/// thread may read.
final class StateStore: @unchecked Sendable {
    let url: URL
    private(set) var state: ShepherdState
    /// Moves with every committed state, so derived lookups know when to rebuild.
    private(set) var version: UInt64 = 0
    private(set) var historyPrepared = false
    /// The project-history connection `update` uses, opened once (schema and indexes included)
    /// rather than per mutation. Confined, like the rest of the store, to the server queue.
    private var history: ProjectHistoryStore?
    private(set) var recoveryError: StateStoreError?
    private(set) var didRecover = false
    private var readOnly = false
    private let committedLock = NSLock()
    private var committedState = ShepherdState()

    init(url: URL, readOnly: Bool = false) {
        self.url = url
        self.state = ShepherdState()
        load(readOnly: readOnly)
    }

    /// The last committed state, readable from any thread without waiting for the queue. It is
    /// published before the mutation that committed it returns.
    var committed: ShepherdState {
        committedLock.withLock { committedState }
    }

    func requireWritable() throws {
        if let recoveryError { throw recoveryError }
        if readOnly { throw StateStoreError.readOnly }
    }

    /// Startup can settle stale process state in memory without replacing the recovered file.
    func reconcileStartup(_ mutate: (inout ShepherdState) -> Void) throws {
        guard didRecover else { try update(mutate); return }
        try requireWritable()
        var candidate = state
        mutate(&candidate)
        try candidate.validate()
        commit(candidate)
    }

    func update(_ mutate: (inout ShepherdState) -> Void) throws {
        try requireWritable()
        var candidate = state
        mutate(&candidate)
        let logicalChange = candidate.projects != state.projects || candidate.projectExecutions != state.projectExecutions
        if (!candidate.projects.isEmpty || !candidate.projectExecutions.isEmpty || !state.projects.isEmpty || !state.projectExecutions.isEmpty) && (!historyPrepared || logicalChange) {
            let history = try self.history ?? ProjectHistoryStore(beside: url)
            self.history = history
            candidate = try history.prepare(before: state, candidate: candidate)
        }
        try candidate.validate(sizingProjects: !historyPrepared || logicalChange)
        try persist(candidate)
        commit(candidate)
        historyPrepared = true
    }

    /// Logical-project mutations stage the complete snapshot off the server queue. The final
    /// rename and publication stay on that queue as one indivisible state transition; otherwise
    /// another service could persist between the revision check and replacement of state.json.
    struct LogicalProjectsStage: Sendable {
        var url: URL
        var state: ShepherdState
    }

    static func stageLogicalProjects(_ proposed: ShepherdState, before: ShepherdState, at url: URL) throws -> LogicalProjectsStage {
        try stage(at: url) {
            let candidate = try ProjectHistoryStore(beside: url).prepare(before: before, candidate: proposed)
            try candidate.validate()
            guard try NDJSON.encode(RemoteReply.stateChanged(state: candidate)).count <= NDJSON.maxPayloadBytes else {
                throw LogicalProjectsError("project_limit", "Workspace exceeds the remote state frame budget.")
            }
            return candidate
        }
    }

    /// Ordinary mutations retain their existing validation policy without opening project history
    /// for an unrelated layout/name change. The server has already prepared history at startup.
    static func stageUpdate(_ proposed: ShepherdState, before: ShepherdState, at url: URL, prepareHistory: Bool) throws -> LogicalProjectsStage {
        try stage(at: url) {
            var candidate = proposed
            let projectsChanged = candidate.projects != before.projects || candidate.projectExecutions != before.projectExecutions
            let needsHistory = projectsChanged || (prepareHistory && (!before.projects.isEmpty || !before.projectExecutions.isEmpty))
            if needsHistory { candidate = try ProjectHistoryStore(beside: url).prepare(before: before, candidate: candidate) }
            try candidate.validate(sizingProjects: needsHistory)
            return candidate
        }
    }

    private static func stage(at url: URL, prepare: () throws -> ShepherdState) throws -> LogicalProjectsStage {
        // Reserve the state write first. A non-writable workspace must fail before advancing history.
        let staged = url.deletingLastPathComponent().appendingPathComponent(".logical-project-state-\(UUID().uuidString.lowercased())")
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            let candidate = try prepare()
            let data = try JSONEncoder().encode(candidate.persisted)
            try file.write(contentsOf: data)
            try file.close()
            return LogicalProjectsStage(url: staged, state: candidate)
        } catch {
            try? file.close()
            _ = unlink(staged.path)
            throw error
        }
    }

    func commitLogicalProjects(_ candidate: ShepherdState, version expected: UInt64, staged: LogicalProjectsStage) throws {
        try requireWritable()
        guard version == expected else {
            throw LogicalProjectsError("workspace_changed", "Workspace changed while saving. Refresh and retry.")
        }
        // Only a single atomic metadata operation runs here; encoding and writing ran off queue.
        guard rename(staged.url.path, url.path) == 0 else {
            throw SessionServerError.persistFailed(String(cString: strerror(errno)))
        }
        commit(staged.state)
        historyPrepared = true
    }

    /// Commits a change that no invariant depends on and no relaunch needs (an agent's status,
    /// which `start()` resets to idle anyway): published at once, but neither validated nor
    /// written. The next `update` writes it along with its own change.
    func updateLive(_ mutate: (inout ShepherdState) -> Void) {
        var next = state
        mutate(&next)
        commit(next)
    }

    private func commit(_ next: ShepherdState) {
        state = next
        version &+= 1
        committedLock.withLock { committedState = next }
    }

    /// The server calls with readOnly: false only after acquiring the workspace lock.
    func load(readOnly: Bool = false) {
        self.readOnly = readOnly
        recoveryError = nil
        didRecover = false
        historyPrepared = false
        commit(ShepherdState())
        switch PersistedFile<ShepherdState>.load(from: url, validate: { try $0.validate() }) {
        case .loaded(let loaded): commit(loaded)
        case .missing: return
        case .damaged(let original, let cause):
            do {
                guard !readOnly, let original else { throw cause }
                let id = UUID().uuidString.lowercased()
                let backup: URL
                if let existing = recoveryCopy(matching: original) {
                    backup = existing
                } else {
                    backup = url.appendingPathExtension("recovery-\(id)")
                    try original.write(to: backup, options: .withoutOverwriting)
                }
                let rejected = url.appendingPathExtension("rejected-\(id)")
                let candidate = try Self.recover(original, rejectedAt: rejected)
                commit(candidate)
                didRecover = true
                ShepherdLog.warning("Recovered \(url.path); original at \(backup.path), rejected records at \(rejected.path)")
            } catch {
                let failure = StateStoreError.repairRequired(path: url.path, reason: String(describing: error))
                recoveryError = failure
                if !readOnly { ShepherdLog.error("\(failure); original error: \(cause)") }
            }
        }
    }

    private func recoveryCopy(matching original: Data) -> URL? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let files = try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
                                                                 includingPropertiesForKeys: Array(keys))
        return files?.first { file in
            guard file.lastPathComponent.hasPrefix("\(url.lastPathComponent).recovery-"),
                  let info = try? file.resourceValues(forKeys: keys),
                  info.isRegularFile == true, info.isSymbolicLink == false, info.fileSize == original.count else { return false }
            return (try? Data(contentsOf: file)) == original
        }
    }

    private func persist(_ candidate: ShepherdState) throws {
        try requireWritable()

        let data = try JSONEncoder().encode(candidate.persisted)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
