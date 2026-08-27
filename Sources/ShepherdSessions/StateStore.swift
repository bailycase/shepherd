import Foundation
import ShepherdCore
import ShepherdRemote

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
/// (the in-process server confines all use to its serial queue).
final class StateStore: @unchecked Sendable {
    let url: URL
    private(set) var state: ShepherdState
    private var recoveryError: StateStoreError?

    init(url: URL) {
        self.url = url
        self.state = ShepherdState()
        self.recoveryError = nil
        load()
    }

    func update(_ mutate: (inout ShepherdState) -> Void) throws {
        if let recoveryError {
            throw recoveryError
        }

        var candidate = state
        mutate(&candidate)
        try candidate.validate()
        try persist(candidate)
        state = candidate
    }

    private func load() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            do {
                let loaded = try JSONDecoder().decode(ShepherdState.self, from: data)
                try loaded.validate()
                state = loaded
            } catch {
                quarantine(cause: error)
            }
        } catch {
            quarantine(cause: error)
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
        let data = try encoder.encode(candidate)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
