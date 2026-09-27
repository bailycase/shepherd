import Foundation
import ShepherdCore
import ShepherdProtocol

/// The copies design references keep (docs/designs.md › Design references › The copy): one
/// folder per sent reference under the support directory's `design-refs/<agent>/<payload>/`,
/// holding `payload.json` (`DesignReferencePayload`) and its files. Never the drop folder, which
/// is pruned after a day. Everything runs on the store's own queue, never the server's.
public final class DesignReferencePayloadStore: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "shepherd.design-refs", qos: .userInitiated)

    public init(directory: URL) {
        self.directory = directory
    }

    /// An agent's folder, or nil when its id can't name one.
    public func folder(for agentID: AgentID) -> URL? {
        Self.isSegment(agentID.rawValue) ? directory.appendingPathComponent(agentID.rawValue, isDirectory: true) : nil
    }

    /// A copy's folder.
    public func folder(for agentID: AgentID, payload id: UUID) -> URL? {
        folder(for: agentID)?.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    /// Makes a copy's folder (empty) and answers it.
    func create(agentID: AgentID, payload id: UUID) async throws -> URL {
        try await run {
            guard let folder = self.folder(for: agentID, payload: id) else { throw DesignReferenceError("invalid_agent", "no folder for that agent") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
    }

    /// Writes files into a copy's folder, each by its plain name.
    func write(_ files: [String: Data], agentID: AgentID, payload id: UUID) async throws {
        try await run {
            guard let folder = self.folder(for: agentID, payload: id) else { throw DesignReferenceError("invalid_agent", "no folder for that agent") }
            for (name, data) in files {
                guard Self.isSegment(name) else { throw DesignReferenceError("invalid_file", "\(name) is not a file name") }
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
        }
    }

    /// Writes the copy's manifest: the last step of a capture, so a folder without one is a
    /// capture that never finished.
    func save(_ payload: DesignReferencePayload) async throws {
        let data = try payload.encoded()
        try await write([DesignReferencePayload.manifestName: data], agentID: payload.agentID, payload: payload.id)
    }

    /// The copy `id` that `agentID` was sent; nil when there is none (or it belongs to another agent).
    public func load(agentID: AgentID, payload id: UUID) async -> DesignReferencePayload? {
        try? await run { self.loadOnQueue(agentID: agentID, payload: id) }
    }

    /// A file of a copy, by its name.
    func read(agentID: AgentID, payload id: UUID, file name: String) async -> Data? {
        try? await run {
            guard Self.isSegment(name), let folder = self.folder(for: agentID, payload: id) else { return nil }
            return try? Data(contentsOf: folder.appendingPathComponent(name))
        }
    }

    /// Removes copies (a queued message taken back, a send pi refused, grants past the cap).
    func remove(agentID: AgentID, payloads ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        _ = try? await run {
            for id in ids {
                if let folder = self.folder(for: agentID, payload: id) { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    /// Removes every copy the agents were sent: they are gone.
    func removeAgents(_ ids: Set<AgentID>) {
        guard !ids.isEmpty else { return }
        queue.async {
            for id in ids {
                if let folder = self.folder(for: id) { try? FileManager.default.removeItem(at: folder) }
            }
        }
    }

    /// Startup: every agent's folder but `agents`' goes, and every copy no grant names (a capture
    /// that never finished, or a send the app quit during).
    func prune(keeping grants: [AgentID: Set<UUID>]) {
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? []
            for name in names where !name.hasPrefix(".") {
                let agent = AgentID(rawValue: name)
                let folder = self.directory.appendingPathComponent(name, isDirectory: true)
                guard let kept = grants[agent] else {
                    try? FileManager.default.removeItem(at: folder)
                    continue
                }
                let copies = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                for copy in copies where UUID(uuidString: copy).map({ !kept.contains($0) }) ?? true {
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent(copy))
                }
            }
        }
    }

    /// Waits for every write queued so far (tests).
    public func flush() {
        queue.sync {}
    }

    private func loadOnQueue(agentID: AgentID, payload id: UUID) -> DesignReferencePayload? {
        guard let folder = folder(for: agentID, payload: id),
              let data = try? Data(contentsOf: folder.appendingPathComponent(DesignReferencePayload.manifestName)),
              let payload = try? DesignReferencePayload.decode(data),
              payload.id == id, payload.agentID == agentID else { return nil }
        return payload
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// One plain path segment: `[A-Za-z0-9._@-]`, not starting with a dot, up to 128 bytes.
    static func isSegment(_ name: String) -> Bool {
        (1...128).contains(name.utf8.count) && !name.hasPrefix(".") && name.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || "@._-".utf8.contains($0)
        }
    }
}
