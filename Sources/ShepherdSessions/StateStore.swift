import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdProtocol

/// Errors that prevent a corrupt state file from being safely replaced.
enum StateStoreError: Error, CustomStringConvertible, Sendable {
    case quarantineFailed(path: String, reason: String)

    var description: String {
        switch self {
        case .quarantineFailed(let path, let reason):
            return "could not quarantine invalid state at \(path): \(reason)"
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
    private var recoveryError: StateStoreError?
    private let committedLock = NSLock()
    private var committedState = ShepherdState()

    init(url: URL, readOnly: Bool = false) {
        self.url = url
        self.state = ShepherdState()
        self.recoveryError = nil
        load(readOnly: readOnly)
    }

    /// The last committed state, readable from any thread without waiting for the queue. It is
    /// published before the mutation that committed it returns.
    var committed: ShepherdState {
        committedLock.withLock { committedState }
    }

    func update(_ mutate: (inout ShepherdState) -> Void) throws {
        if let recoveryError {
            throw recoveryError
        }

        var candidate = state
        mutate(&candidate)
        try candidate.validate()
        try persist(candidate)
        commit(candidate)
    }

    /// Logical-project mutations stage the complete snapshot off the server queue. The final
    /// rename and publication stay on that queue as one indivisible state transition; otherwise
    /// another service could persist between the revision check and replacement of state.json.
    static func stageLogicalProjects(_ candidate: ShepherdState, at url: URL) throws -> URL {
        try candidate.validate()
        guard try NDJSON.encode(RemoteReply.stateChanged(state: candidate)).count <= NDJSON.maxPayloadBytes else {
            throw LogicalProjectsError("project_limit", "Workspace exceeds the remote state frame budget.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate.persisted)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".logical-project-state-\(UUID().uuidString.lowercased())")
        let fd = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.close()
            return staged
        } catch {
            try? file.close()
            _ = unlink(staged.path)
            throw error
        }
    }

    func commitLogicalProjects(_ candidate: ShepherdState, version expected: UInt64, staged: URL) throws {
        if let recoveryError { throw recoveryError }
        guard version == expected else {
            throw LogicalProjectsError("workspace_changed", "Workspace changed while saving. Refresh and retry.")
        }
        // Only a single atomic metadata operation runs here; encoding and writing ran off queue.
        guard rename(staged.path, url.path) == 0 else {
            throw SessionServerError.persistFailed(String(cString: strerror(errno)))
        }
        commit(candidate)
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

    /// Before exclusive startup the server may display state, but must not quarantine it.
    func load(readOnly: Bool = false) {
        recoveryError = nil
        commit(ShepherdState())
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            do {
                let loaded = try JSONDecoder().decode(ShepherdState.self, from: data)
                try loaded.validate()
                commit(loaded)
            } catch {
                if !readOnly { quarantine(cause: error) }
            }
        } catch {
            if !readOnly { quarantine(cause: error) }
        }
    }

    private func quarantine(cause: Error) {
        let fileManager = FileManager.default
        var backup = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(UUID().uuidString.lowercased())"
        )
        while fileManager.fileExists(atPath: backup.path) {
            backup = url.deletingLastPathComponent().appendingPathComponent(
                "\(url.lastPathComponent).corrupt-\(UUID().uuidString.lowercased())"
            )
        }
        do {
            try fileManager.moveItem(at: url, to: backup)
            ShepherdLog.warning(
                "quarantined invalid state at \(url.path) to \(backup.path): \(cause)"
            )
        } catch {
            let failure = StateStoreError.quarantineFailed(path: url.path, reason: String(describing: error))
            recoveryError = failure
            ShepherdLog.error("\(failure); original error: \(cause)")
        }
    }

    private func persist(_ candidate: ShepherdState) throws {
        if let recoveryError {
            throw recoveryError
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate.persisted)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
