import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Server-queue owned. Independent of live workspace status, which startup resets to idle.
final class AgentRecoveryStore {
    static let attemptLimit = 3

    struct Checkpoint: Codable, Equatable {
        var sessionID: String
        var active: Bool
        var items: [RPCThreadState.QueueItem]
        var pending: [RPCThreadState.QueueItem]
        var paused: Bool
        var mode: NativeQueueMode
        var attempts = 0
        var operationID: UUID?
        var token: String?
        var fence: String?
    }

    private let directory: URL
    private var loaded: Set<AgentID> = []
    private var records: [AgentID: Checkpoint] = [:]

    init(directory: URL) { self.directory = directory }

    func checkpoint(for agent: AgentID) throws -> Checkpoint? {
        if !loaded.contains(agent) {
            let url = file(for: agent)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                do {
                    records[agent] = try JSONDecoder().decode(Checkpoint.self, from: data)
                } catch is DecodingError {
                    // Preserve the unreadable work for inspection; never overwrite it to admit
                    // a new send. A failed quarantine remains an error and blocks replacement.
                    let quarantine = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: url, to: quarantine)
                    ShepherdLog.warning("Quarantined an unreadable agent recovery checkpoint")
                }
            }
            loaded.insert(agent)
        }
        return records[agent]
    }

    // ponytail: synchronous write-ahead keeps admission crash-safe; stage large image blobs off
    // queue if image-heavy recovery checkpoints measurably stall other sessions.
    func save(_ checkpoint: Checkpoint?, for agent: AgentID, force: Bool = false) throws {
        let previous = try self.checkpoint(for: agent)
        guard force || checkpoint != previous else { return }
        if let checkpoint {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(checkpoint).write(to: file(for: agent), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(for: agent).path)
        } else if previous != nil {
            try FileManager.default.removeItem(at: file(for: agent))
        }
        records[agent] = checkpoint
    }

    func prune(keeping agents: Set<AgentID>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let names = Set(agents.map { file(for: $0).lastPathComponent })
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" && !names.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
        records = records.filter { agents.contains($0.key) }
        loaded.formIntersection(agents)
    }

    private func file(for agent: AgentID) -> URL {
        // IDs are opaque; encoding also keeps imported IDs from becoming filesystem paths.
        let name = Data(agent.rawValue.utf8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}
