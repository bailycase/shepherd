import Foundation
import ShepherdCore

/// Owner-local launch handed to the app's ordinary session creator after durable reservation.
/// This is not a remote execution contract or permission for a model to spawn peers.
public struct ProjectRuntimeLaunch: Sendable {
    public var projectID: ProjectID
    public var agentID: AgentID
    public var spaceID: SpaceID
    public var cwd: String
    public var name: String
    public var model: String?
    public var coordinator: Bool
    public init(projectID: ProjectID, agentID: AgentID, spaceID: SpaceID, cwd: String, name: String, model: String?, coordinator: Bool) {
        self.projectID = projectID; self.agentID = agentID; self.spaceID = spaceID
        self.cwd = cwd; self.name = name; self.model = model; self.coordinator = coordinator
    }
}

/// Owner-validated actions. Extension callers receive only the explicitly permitted subset.
public enum ProjectRuntimeRequest: Codable, Hashable, Sendable {
    case conversation
    case read
    case inspect(taskID: ProjectTaskID)
    case answer(operationID: UUID, taskID: ProjectTaskID, questionEventID: UUID, humanReplyID: UUID, answer: NativeDialogAnswer)
    case proposeSpace(operationID: UUID, path: String?, spaceID: SpaceID?, originTaskID: ProjectTaskID?)
    case decideSpace(proposalID: UUID, expectedProposalRevision: UInt64, accept: Bool)
    case remember(operationID: UUID, text: String, taskID: ProjectTaskID)
    case message(operationID: UUID, text: String, images: [NativeImage]? = nil)
    case assign(operationID: UUID, spaceID: SpaceID, title: String, prompt: String, host: ProjectHostReference? = nil)
    case followUp(taskID: ProjectTaskID, operationID: UUID, text: String)
    case resolve(taskID: ProjectTaskID, operationID: UUID? = nil)
    case reopen(taskID: ProjectTaskID)
    case pause
    case resume
}

/// A Project viewer addresses only its owner; no worker is started on the viewing Mac.
public enum ProjectRuntimeTransport: Codable, Hashable, Sendable {
    case hosts
    case action(projectID: ProjectID, expectedRevision: UInt64, request: ProjectRuntimeRequest)
    case conversation(projectID: ProjectID, request: NativeThreadRequest)
    case worker(projectID: ProjectID, taskID: ProjectTaskID, request: NativeThreadRequest)
    case answer(projectID: ProjectID, expectedRevision: UInt64, taskID: ProjectTaskID, request: NativeThreadRequest)

    public var nativeRequest: NativeThreadRequest? {
        switch self {
        case .conversation(_, let request), .worker(_, _, let request), .answer(_, _, _, let request): request
        case .hosts, .action: nil
        }
    }

    public var messageImages: [NativeImage] {
        if case .action(_, _, .message(_, _, let images)) = self { return images ?? [] }
        return []
    }
}

public extension RemoteProtocol {
    static let projectWorkerCapability = "logicalProjects.worker.v1"
}

public enum ProjectRuntimeResult: Codable, Hashable, Sendable {
    case hosts([ProjectHostOption])
    case project(Project)
    case native(NativeThreadResult)
}
