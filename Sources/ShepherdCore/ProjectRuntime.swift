import Foundation

public enum ProjectTaskMarker: Sendable {}
public typealias ProjectTaskID = Identifier<ProjectTaskMarker>

/// A local ordinary thread's assignment, not a second transcript or a success assertion.
public struct ProjectTask: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case queued, reserved, running, waiting, settled, resolved, unknown, failed
        public var occupiesSlot: Bool { [.reserved, .running, .waiting, .unknown].contains(self) }
    }
    public var id: ProjectTaskID
    public var operationID: UUID
    public var previousOperations: [UUID]?
    public var resolutionOperations: [UUID]?
    public var nativeDeliveryID: UUID?
    public var workerSessionID: String?
    /// Missing in legacy state means the initial helper/publication scope (epoch zero).
    public var childScopeEpoch: UInt64?
    public var workerAgentID: AgentID
    public var spaceID: SpaceID
    public var host: ProjectHostReference?
    public var destination: ProjectHostReference { host ?? .local }
    public var executionAssignment: ProjectExecutionAssignment?
    public var executionReceipt: ProjectExecutionReceipt?
    public var title: String
    public var prompt: String
    public var phase: Phase
    public var revision: UInt64
    public var error: String?
    public var settledAt: Double?
    public var question: String?
    public var pendingAnswer: ProjectQuestionAnswer?

    public init(id: ProjectTaskID = .init(), operationID: UUID, workerAgentID: AgentID = .init(),
                spaceID: SpaceID, title: String, prompt: String, phase: Phase = .queued, revision: UInt64 = 1,
                host: ProjectHostReference? = nil) {
        self.id = id; self.operationID = operationID; self.workerAgentID = workerAgentID
        self.host = host
        self.spaceID = spaceID; self.title = title; self.prompt = prompt; self.phase = phase; self.revision = revision
    }
}

/// The native answer envelope is persisted opaquely to avoid a Core -> Protocol dependency.
/// Only the owner decodes it, rechecking the original native fence immediately before delivery.
public struct ProjectQuestionAnswer: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable { case queued, delivering, delivered, failed, unknown }
    public var operationID: UUID
    public var sessionID: String
    public var generation: String
    public var dialogID: String
    public var request: Data
    public var phase: Phase
    public init(operationID: UUID, sessionID: String, generation: String, dialogID: String, request: Data, phase: Phase = .queued) {
        self.operationID = operationID; self.sessionID = sessionID; self.generation = generation
        self.dialogID = dialogID; self.request = request; self.phase = phase
    }
}

/// Durable send identity. A process or connection disappearing never authorizes replaying a
/// delivery whose outcome is unknown; the ordinary native transcript remains authoritative.
public struct ProjectMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable { case queued, delivering, delivered, unknown, failed }
    public var id: UUID
    public var text: String
    public var phase: Phase
    public var source: ProjectEventSource?
    /// Only the owner's human `.message` admission sets this; legacy/synthetic messages are ineligible.
    public var humanSubmitted: Bool?
    public var answerReceipts: [ProjectChatAnswerReceipt]?
    public var nativeDeliveryID: UUID?
    /// Private owner input blobs, not artifacts or model-tool context. Bytes never enter state.json.
    public var images: [ProjectInputImage]?
    public init(id: UUID, text: String, phase: Phase = .queued, source: ProjectEventSource? = nil, images: [ProjectInputImage]? = nil) {
        self.id = id; self.text = text; self.phase = phase; self.source = source; self.images = images
    }
}

/// A bounded human-message receipt binds a relay operation to the original native answer.
public struct ProjectChatAnswerReceipt: Codable, Hashable, Sendable {
    public var taskID: ProjectTaskID
    public var questionEventID: UUID
    public var nativeAnswer: ProjectQuestionAnswer
    public init(taskID: ProjectTaskID, questionEventID: UUID, nativeAnswer: ProjectQuestionAnswer) {
        self.taskID = taskID; self.questionEventID = questionEventID; self.nativeAnswer = nativeAnswer
    }
}

public struct ProjectInputImage: Codable, Hashable, Sendable {
    public var id: UUID
    public var mimeType: String
    public var name: String?
    public var byteCount: Int
    public init(id: UUID, mimeType: String, name: String? = nil, byteCount: Int) {
        self.id = id; self.mimeType = mimeType; self.name = name; self.byteCount = byteCount
    }
}

/// Durable provenance doubles as the event receipt: one task activation/dialog wakes at most once.
public struct ProjectEventSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case settled, question, failed }
    public var kind: Kind
    public var taskID: ProjectTaskID
    public var operationID: UUID
    public var workerAgentID: AgentID
    public var sessionID: String?
    public var dialogID: String?
    public var generation: String?
    public init(kind: Kind, taskID: ProjectTaskID, operationID: UUID, workerAgentID: AgentID, sessionID: String?, dialogID: String? = nil, generation: String? = nil) {
        self.kind = kind; self.taskID = taskID; self.operationID = operationID; self.workerAgentID = workerAgentID
        self.sessionID = sessionID; self.dialogID = dialogID; self.generation = generation
    }
}

public extension ShepherdState {
    func isProjectCoordinator(_ agent: Agent) -> Bool { agent.coordinatorFor != nil }
    func isProjectCoordinator(_ id: AgentID) -> Bool { agents.contains { $0.id == id && $0.coordinatorFor != nil } }
    func isOrdinaryThread(_ agent: Agent) -> Bool { !isDesignAgent(agent) && !isProjectCoordinator(agent) }
    var withoutProjectCoordinators: ShepherdState {
        var copy = self
        let ids = Set(agents.filter { $0.coordinatorFor != nil }.map(\.id))
        let tabs = Set(agents.filter { ids.contains($0.id) }.map(\.tabID))
        copy.agents.removeAll { ids.contains($0.id) }
        copy.tabs.removeAll { tabs.contains($0.id) || $0.inspectorFor.map(ids.contains) == true }
        copy.spaces.removeAll { $0.holdsProjects }
        return copy
    }
}
