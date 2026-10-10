import Foundation

/// Host-produced provenance, never inferred from a file name or model-provided task identity.
public struct ProjectArtifactReceipt: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable { case staged, ready, refused }
    public static let maximumBytes = 32 * 1024 * 1024
    public static let chunkBytes = 256 * 1024
    public static let maximumCount = 32
    public static let maximumAggregateBytes: Int64 = 256 * 1024 * 1024
    public static let transferSeconds: TimeInterval = 120
    public var id: UUID
    public var key: ProjectExecutionKey
    public var taskID: ProjectTaskID
    public var workerAgentID: AgentID
    public var sessionID: String
    public var generation: String
    public var artifactName: String
    public var relativePath: String
    public var size: Int64
    public var sha256: String
    /// Hash of the explicit relative source argument; retries cannot select a different source.
    public var sourceIdentity: String
    public var state: State
    /// Owner-relative authenticated placement binding; nil for owner-local production.
    public var executor: ProjectHostReference?
    /// Bounded public refusal code, not a filesystem error/path or private transport diagnostic.
    public var refusal: String?

    public init(id: UUID, key: ProjectExecutionKey, taskID: ProjectTaskID, workerAgentID: AgentID,
                sessionID: String, generation: String, artifactName: String, size: Int64 = 0,
                sha256: String = "", sourceIdentity: String, state: State = .staged) {
        self.id = id; self.key = key; self.taskID = taskID; self.workerAgentID = workerAgentID
        self.sessionID = sessionID; self.generation = generation; self.artifactName = artifactName
        relativePath = artifactName; self.size = size; self.sha256 = sha256
        self.sourceIdentity = sourceIdentity; self.state = state
    }

    public static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            && !["logs", "sessions", "auth", "settings", "config", "credentials", "keychain", "secrets", "id_rsa", "id_ed25519"].contains(((name as NSString).deletingPathExtension).lowercased())
            && !["log", "jsonl", "pem", "key", "p12", "pfx", "mobileprovision"].contains((name as NSString).pathExtension.lowercased())
    }

    public func validate() throws {
        guard Project.validID(key.projectID.rawValue), Project.validID(taskID.rawValue), Project.validID(workerAgentID.rawValue),
              !sessionID.isEmpty, sessionID.utf8.count <= 512, !generation.isEmpty, generation.utf8.count <= 512,
              Self.safeComponent(artifactName), relativePath == artifactName,
              size >= 0, size <= Self.maximumBytes, (refusal?.utf8.count ?? 0) <= 64,
              [sha256, sourceIdentity].allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw ProjectValidationError("Invalid publication receipt.")
        }
    }

    public static func validateCollection(_ receipts: [Self]) throws {
        guard receipts.count <= maximumCount, Set(receipts.map(\.id)).count == receipts.count,
              receipts.reduce(Int64(0), { $0 + max(0, min($1.size, Int64(maximumBytes))) }) <= maximumAggregateBytes,
              try JSONEncoder().encode(receipts).count <= 64 * 1024 else {
            throw ProjectValidationError("Publication receipt or byte budget is full.")
        }
        for receipt in receipts { try receipt.validate() }
    }
}
