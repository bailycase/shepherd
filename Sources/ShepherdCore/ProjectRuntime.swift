import Foundation

public enum ProjectTaskMarker: Sendable {}
public typealias ProjectTaskID = Identifier<ProjectTaskMarker>

/// A local ordinary thread's assignment, not a second transcript or a success assertion.
public struct ProjectTask: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        /// settled: the worker turn stopped, not success or resolution. resolved: terminal assignment.
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
    /// The model and thinking level the coordinator chose for this task (`project_assign`, `project_follow_up`); nil takes
    /// the Project's thread model and the owner's default thinking.
    public var model: String?
    public var thinking: String?
    public var phase: Phase
    public var revision: UInt64
    public var error: String?
    public var settledAt: Double?
    public var question: String?
    public var pendingAnswer: ProjectQuestionAnswer?
    /// The newest review/delivery facts (at most `ProjectTaskOutcome.hotPerTask`), each bound to one exact activation. Older facts
    /// are archived to durable history before they leave this working copy and are paged with `.outcomes`. nil (legacy or none
    /// recorded) is unknown, never success.
    public var outcomes: [ProjectTaskOutcome]?
    /// How many earlier facts live only in durable history. Lifetime facts are never capped or deleted.
    public var archivedOutcomeCount: Int?
    /// The newest fact recorded for the current activation; an older activation's facts are not this one's.
    public var currentOutcome: ProjectTaskOutcome? { outcomes?.last { $0.operationID == operationID } }

    /// Moves the oldest already-archived facts out of the working copy until it holds `hotPerTask`. The current activation's newest
    /// fact always stays, so a row never reads unknown while its fact exists. An unarchived fact is never removed.
    public mutating func retireOutcomes(archived: Set<UUID>) {
        guard var list = outcomes, list.count > ProjectTaskOutcome.hotPerTask else { return }
        let pinned = currentOutcome?.id
        while list.count > ProjectTaskOutcome.hotPerTask, let i = list.firstIndex(where: { $0.id != pinned && archived.contains($0.id) }) {
            list.remove(at: i)
            archivedOutcomeCount = (archivedOutcomeCount ?? 0) + 1
        }
        outcomes = list
    }

    public init(id: ProjectTaskID = .init(), operationID: UUID, workerAgentID: AgentID = .init(),
                spaceID: SpaceID, title: String, prompt: String, phase: Phase = .queued, revision: UInt64 = 1,
                host: ProjectHostReference? = nil, model: String? = nil, thinking: String? = nil) {
        self.id = id; self.operationID = operationID; self.workerAgentID = workerAgentID
        self.host = host; self.model = model; self.thinking = thinking
        self.spaceID = spaceID; self.title = title; self.prompt = prompt; self.phase = phase; self.revision = revision
    }
}

/// A fact about one exact task activation, separate from its runtime phase. Recording it never changes the phase, reopens the
/// task or touches its worker. Coordinator-recorded facts are the coordinator's claim, not the person's approval.
public struct ProjectTaskOutcome: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case accepted, needsChanges, merged, uploaded, available
        /// Delivery facts name their evidence (a PR, commit, build or release reference); review verdicts may not.
        public var needsEvidence: Bool { [.merged, .uploaded, .available].contains(self) }
        public var label: String {
            switch self {
            case .accepted: "Accepted"
            case .needsChanges: "Needs changes"
            case .merged: "Merged"
            case .uploaded: "Uploaded"
            case .available: "Available"
            }
        }
    }
    /// The working-state bound, not a lifetime quota: older facts are archived, never refused or dropped.
    public static let hotPerTask = 4
    /// One explicit `.outcomes` history page.
    public static let pageSize = 8
    public static let maximumEvidenceBytes = 256
    /// The recording operation's identity (its replay receipt).
    public var id: UUID
    /// The exact task activation this fact is about.
    public var operationID: UUID
    public var kind: Kind
    public var evidence: String?
    /// The coordinator that recorded it; nil is the owner's own Project control.
    public var recordedBy: AgentID?
    /// Host-assigned milliseconds since 1970.
    public var recordedAt: Double
    public init(id: UUID, operationID: UUID, kind: Kind, evidence: String? = nil, recordedBy: AgentID? = nil, recordedAt: Double) {
        self.id = id; self.operationID = operationID; self.kind = kind; self.evidence = evidence
        self.recordedBy = recordedBy; self.recordedAt = recordedAt
    }
}

/// A durable outcome record: the fact with its exact task identity. Explicit read responses only.
public struct ProjectArchivedOutcome: Codable, Hashable, Sendable {
    public var taskID: ProjectTaskID
    public var outcome: ProjectTaskOutcome
    public init(taskID: ProjectTaskID, outcome: ProjectTaskOutcome) { self.taskID = taskID; self.outcome = outcome }
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
    /// Redacted native refusal detail for a known failed send, never proof of an unknown outcome.
    public var failureDetail: String?
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
    /// A thread a Project started for one of its tasks (owned here, or run here for another host's Project). It lives under its
    /// Project, never in the sidebar's own lists; it still asks, notifies and opens like any thread.
    func isProjectWorker(_ id: AgentID) -> Bool {
        projects.contains { $0.tasks.contains { $0.workerAgentID == id } }
            || projectExecutions.contains { $0.assignment?.reservedWorkerID == id }
            || agents.contains { $0.id == id && ($0.executionFor != nil || $0.projectWorkerFor.map { project in projects.contains { $0.id == project } } == true) }
    }
    /// What the sidebar lists as a thread of its own: an ordinary thread no Project started.
    func isSidebarThread(_ agent: Agent) -> Bool { isOrdinaryThread(agent) && !isProjectWorker(agent.id) }
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
