import Foundation
import ShepherdCore

/// Display-only identity from a typed Project tool receipt, never mutation authority.
public struct NativeProjectAction: Codable, Hashable, Sendable {
    public var projectID: ProjectID
    public var revision: UInt64
    public var operationID: UUID
    public var taskID: ProjectTaskID?
    public var proposalID: UUID?

    public init(projectID: ProjectID, revision: UInt64, operationID: UUID, taskID: ProjectTaskID? = nil, proposalID: UUID? = nil) {
        self.projectID = projectID; self.revision = revision; self.operationID = operationID
        self.taskID = taskID; self.proposalID = proposalID
    }

    static let toolNames: Set<String> = ["project_assign", "project_follow_up", "project_resolve", "project_propose_space"]

    private enum CodingKeys: String, CodingKey { case projectID, revision, operationID, taskID, proposalID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try c.decode(ProjectID.self, forKey: .projectID)
        revision = try c.decode(UInt64.self, forKey: .revision)
        operationID = try c.decode(UUID.self, forKey: .operationID)
        taskID = try c.decodeIfPresent(ProjectTaskID.self, forKey: .taskID)
        proposalID = try c.decodeIfPresent(UUID.self, forKey: .proposalID)
        guard Project.validID(projectID.rawValue), revision > 0,
              taskID.map({ Project.validID($0.rawValue) }) ?? true,
              (taskID == nil) != (proposalID == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .projectID, in: c, debugDescription: "Invalid Project action reference")
        }
    }

    static func reference(toolName: String?, details: JSONValue?, isError: Bool?) -> NativeProjectAction? {
        guard let toolName, toolNames.contains(toolName), isError != true, let details,
              let project = details["projectID"]?.stringValue, Project.validID(project),
              let operation = details["operationID"]?.stringValue, operation.utf8.count == 36,
              let operationID = UUID(uuidString: operation),
              let revision = details["revision"]?.doubleValue, revision.isFinite,
              revision >= 1, revision <= 9_007_199_254_740_991, revision.rounded() == revision else { return nil }
        if toolName == "project_propose_space" {
            guard details["taskID"] == nil,
                  let proposal = details["proposalID"]?.stringValue, proposal.utf8.count == 36,
                  let proposalID = UUID(uuidString: proposal) else { return nil }
            return .init(projectID: .init(rawValue: project), revision: UInt64(revision), operationID: operationID, proposalID: proposalID)
        }
        guard details["proposalID"] == nil,
              let task = details["taskID"]?.stringValue, Project.validID(task) else { return nil }
        return .init(projectID: .init(rawValue: project), revision: UInt64(revision), operationID: operationID, taskID: .init(rawValue: task))
    }

    /// Selective history decoding never keeps opaque tool details.
    var details: JSONValue {
        var values: [String: JSONValue] = ["projectID": .string(projectID.rawValue), "revision": .number(Double(revision)),
                                           "operationID": .string(operationID.uuidString)]
        if let taskID { values["taskID"] = .string(taskID.rawValue) }
        if let proposalID { values["proposalID"] = .string(proposalID.uuidString) }
        return .object(values)
    }
}
