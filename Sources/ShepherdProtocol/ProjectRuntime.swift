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
    /// A `ThinkingLevel` raw value; nil takes the owner's default.
    public var thinking: String?
    public var coordinator: Bool
    public init(projectID: ProjectID, agentID: AgentID, spaceID: SpaceID, cwd: String, name: String, model: String?,
                thinking: String? = nil, coordinator: Bool) {
        self.projectID = projectID; self.agentID = agentID; self.spaceID = spaceID
        self.cwd = cwd; self.name = name; self.model = model; self.thinking = thinking; self.coordinator = coordinator
    }
}

/// Owner-validated actions. Extension callers receive only the explicitly permitted subset.
public enum ProjectRuntimeRequest: Codable, Hashable, Sendable {
    public var targetTaskID: ProjectTaskID? {
        switch self {
        case .followUp(let id, _, _, _, _), .resolve(let id, _), .reopen(let id), .remember(_, _, let id), .recordOutcome(_, let id, _, _, _),
             .outcomes(let id, _, _): id
        default: nil
        }
    }
    public var operationID: UUID? {
        switch self {
        case .message(let id, _, _), .assign(let id, _, _, _, _, _, _), .followUp(_, let id, _, _, _), .remember(let id, _, _), .proposeSpace(let id, _, _, _),
             .recordOutcome(let id, _, _, _, _): id
        case .resolve(_, let id): id
        default: nil
        }
    }
    case conversation
    case read
    case worker(taskID: ProjectTaskID)
    case inspect(taskID: ProjectTaskID, operationID: UUID? = nil)
    /// Explicit indexed history and immutable final-result pages. Neither is a success assertion.
    case history(taskID: ProjectTaskID? = nil, beforeSequence: Int64? = nil, includeBodies: Bool? = nil)
    case result(taskID: ProjectTaskID, operationID: UUID, offset: Int64 = 0, sha256: String? = nil)
    /// Explicit page of one task's durable outcome facts, newest first, optionally one exact activation. Not a success assertion.
    case outcomes(taskID: ProjectTaskID, operationID: UUID? = nil, beforeSequence: Int64? = nil)
    case answer(operationID: UUID, taskID: ProjectTaskID, questionEventID: UUID, humanReplyID: UUID, answer: NativeDialogAnswer)
    case proposeSpace(operationID: UUID, path: String?, spaceID: SpaceID?, originTaskID: ProjectTaskID?)
    case decideSpace(proposalID: UUID, expectedProposalRevision: UInt64, accept: Bool)
    case remember(operationID: UUID, text: String, taskID: ProjectTaskID)
    case message(operationID: UUID, text: String, images: [NativeImage]? = nil)
    /// `model` and `thinking` are the coordinator's choice for this one task; nil takes the Project's defaults.
    case assign(operationID: UUID, spaceID: SpaceID, title: String, prompt: String, host: ProjectHostReference? = nil,
                model: String? = nil, thinking: String? = nil)
    /// Continue the original unresolved assignment after its turn settles. Resolved tasks are terminal.
    case followUp(taskID: ProjectTaskID, operationID: UUID, text: String, model: String? = nil, thinking: String? = nil)
    case resolve(taskID: ProjectTaskID, operationID: UUID? = nil)
    /// Append one review/delivery fact about the exact settled or resolved activation `taskOperationID`. Never changes the phase.
    case recordOutcome(operationID: UUID, taskID: ProjectTaskID, taskOperationID: UUID, kind: ProjectTaskOutcome.Kind, evidence: String? = nil)
    /// Legacy wire compatibility only. New requests refuse with task_resolved; use assign for new work.
    case reopen(taskID: ProjectTaskID)
    case pause
    case resume
}

/// A Project viewer addresses only its owner; no worker is started on the viewing Mac.
public enum ProjectRuntimeTransport: Codable, Hashable, Sendable {
    public var requiresResults: Bool {
        if case .action(_, _, let request) = self {
            switch request { case .worker, .result, .history, .inspect(_, .some), .outcomes: return true; default: break }
        }
        return false
    }
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
    static let projectResultCapability = "logicalProjects.result.v1"
}

public enum ProjectRuntimeResult: Codable, Hashable, Sendable {
    case hosts([ProjectHostOption])
    case project(Project)
    case native(NativeThreadResult)
}
