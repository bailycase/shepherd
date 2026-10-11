import Foundation
import ShepherdCore

/// Native authorization for one consumed Project turn, never supplied by a model tool.
public struct ProjectChildScope: Codable, Hashable, Sendable {
    public var key: ProjectExecutionKey
    public var workerAgentID: AgentID
    public var sessionID: String
    public var generation: String
    /// Explicitly resumed parked work gets a new identity; old cancellation tombstones survive.
    public var epoch: UInt64
    public init(key: ProjectExecutionKey, workerAgentID: AgentID, sessionID: String, generation: String, epoch: UInt64 = 0) {
        self.key = key; self.workerAgentID = workerAgentID; self.sessionID = sessionID; self.generation = generation; self.epoch = epoch
    }
    private enum CodingKeys: String, CodingKey { case key, workerAgentID, sessionID, generation, epoch }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(ProjectExecutionKey.self, forKey: .key)
        workerAgentID = try c.decode(AgentID.self, forKey: .workerAgentID)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        generation = try c.decode(String.self, forKey: .generation)
        epoch = try c.decodeIfPresent(UInt64.self, forKey: .epoch) ?? 0
    }
}

public enum ProjectChildAction: String, Codable, Sendable { case stop, drain }
