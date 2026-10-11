import Foundation
import ShepherdCore

extension NativeProjectAction {
    /// Run at the RPC decode boundary (large records decode off the state queue). Native
    /// projection keeps only these five fields, never opaque details or a second Project copy.
    static func receipt(toolName: String?, details: JSONValue?, content: [RPCContentBlock], isError: Bool?) -> NativeProjectAction? {
        guard let action = reference(toolName: toolName, details: details, isError: isError),
              content.count == 1, case .text(let text) = content[0], text.utf8.count <= 1_048_576,
              let receipt = try? JSONDecoder().decode(ProjectActionReceipt.self, from: Data(text.utf8)),
              receipt.id == action.projectID, receipt.revision == action.revision else { return nil }
        if let proposal = action.proposalID {
            let matches = (receipt.spaceProposals ?? []).filter { $0.operationID == action.operationID }
            return matches.count == 1 && matches[0].id == proposal ? action : nil
        }
        let matches = (receipt.tasks ?? []).filter { task in
            if toolName == "project_resolve" { return (task.resolutionOperations ?? []).contains(action.operationID) }
            return task.operationID == action.operationID || (task.previousOperations ?? []).contains(action.operationID)
        }
        return matches.count == 1 && matches[0].id == action.taskID ? action : nil
    }
}

private struct ProjectActionReceipt: Decodable {
    var id: ProjectID
    var revision: UInt64
    var tasks: [Task]?
    var spaceProposals: [Proposal]?
    struct Task: Decodable {
        var id: ProjectTaskID
        var operationID: UUID
        var previousOperations: [UUID]?
        var resolutionOperations: [UUID]?
    }
    struct Proposal: Decodable {
        var id: UUID
        var operationID: UUID
    }
}
