import Foundation

public enum ProjectMarker: Sendable {}
public typealias ProjectID = Identifier<ProjectMarker>
public enum ProjectMemoryMarker: Sendable {}
public typealias ProjectMemoryID = Identifier<ProjectMemoryMarker>

/// Configuration only: model strings use the same provider/model spelling as Agent.model.
/// Availability is checked at launch, not when saving a preference.
public struct LogicalProjectSettings: Codable, Hashable, Sendable {
    public var maxConcurrentWorkers: Int
    public var conversationModel: String?
    public var threadModel: String?
    public var instructions: String
    /// Permission to request user approval, never permission to link a Space autonomously.
    public var canRequestSpaceLinks: Bool
    public var hostPolicy: ProjectHostPolicy
    public var allowedHosts: [ProjectHostReference]

    public init(maxConcurrentWorkers: Int = 3, conversationModel: String? = nil,
                threadModel: String? = nil, instructions: String = "", canRequestSpaceLinks: Bool = true,
                hostPolicy: ProjectHostPolicy = .selected, allowedHosts: [ProjectHostReference] = [.local]) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.conversationModel = conversationModel
        self.threadModel = threadModel
        self.instructions = instructions
        self.canRequestSpaceLinks = canRequestSpaceLinks
        self.hostPolicy = hostPolicy
        self.allowedHosts = allowedHosts
    }

    private enum CodingKeys: String, CodingKey { case maxConcurrentWorkers, conversationModel, threadModel, instructions, canRequestSpaceLinks, hostPolicy, allowedHosts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentWorkers) ?? 3
        conversationModel = try c.decodeIfPresent(String.self, forKey: .conversationModel)
        threadModel = try c.decodeIfPresent(String.self, forKey: .threadModel)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        canRequestSpaceLinks = try c.decodeIfPresent(Bool.self, forKey: .canRequestSpaceLinks) ?? true
        hostPolicy = try c.decodeIfPresent(ProjectHostPolicy.self, forKey: .hostPolicy) ?? .selected
        allowedHosts = try c.decodeIfPresent([ProjectHostReference].self, forKey: .allowedHosts) ?? [.local]
    }
}

public struct ProjectMemory: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectMemoryID
    public var text: String
    public var source: String
    /// Host-assigned milliseconds since 1970.
    public var createdAt: Double

    public init(id: ProjectMemoryID = ProjectMemoryID(), text: String, source: String, createdAt: Double) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
    }
}

/// Owner-relative destination, never a viewer-relative host or a replicated filesystem path.
public struct ProjectSpaceLink: Codable, Hashable, Sendable, Identifiable {
    public var spaceID: SpaceID
    public var host: ProjectHostReference?
    public var destination: ProjectHostReference { host ?? .local }
    public var id: Identity { .init(host: destination, spaceID: spaceID) }
    public struct Identity: Hashable, Sendable {
        public var host: ProjectHostReference
        public var spaceID: SpaceID
    }
    public var provenance: Provenance
    public var linkedAt: Double
    public enum Provenance: String, Codable, Sendable { case user, project }

    public init(spaceID: SpaceID, provenance: Provenance = .user, linkedAt: Double, host: ProjectHostReference? = nil) {
        self.spaceID = spaceID
        self.host = host
        self.provenance = provenance
        self.linkedAt = linkedAt
    }
}

/// A logical project on the host storing this record; unrelated to directory configuration.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    public var id: ProjectID
    /// Stable authority identity for this Project, independent of host labels and connections.
    public var ownerID: UUID
    public var name: String
    public var goal: String
    /// Lazily allocated conversation identity; never an ordinary task thread.
    public var coordinatorAgentID: AgentID?
    public var revision: UInt64
    public var paused: Bool
    public var settings: LogicalProjectSettings
    public var memory: [ProjectMemory]
    public var linkedSpaces: [ProjectSpaceLink]
    public var tasks: [ProjectTask] = []
    /// Retained independently of task follow-ups and execution retry snapshots.
    public var artifacts: [ProjectArtifactReceipt] = []
    public var messages: [ProjectMessage] = []
    public var spaceProposals: [ProjectSpaceProposal] = []
    /// Receipts survive Forget so retrying an old tool call cannot resurrect forgotten memory.
    public var memoryOperations: [UUID] = []
    /// A pause request may precede an actual native interruption acknowledgement.
    public var interruptPending: Bool = false

    public init(id: ProjectID = ProjectID(), name: String, goal: String = "",
                coordinatorAgentID: AgentID? = nil, revision: UInt64 = 1, paused: Bool = false,
                settings: LogicalProjectSettings = .init(), memory: [ProjectMemory] = [],
                linkedSpaces: [ProjectSpaceLink] = []) {
        self.id = id
        self.ownerID = UUID()
        self.name = name
        self.goal = goal
        self.coordinatorAgentID = coordinatorAgentID
        self.revision = revision
        self.paused = paused
        self.settings = settings
        self.memory = memory
        self.linkedSpaces = linkedSpaces
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownerID, name, goal, coordinatorAgentID, revision, paused, settings, memory, linkedSpaces, tasks, messages, interruptPending, spaceProposals, memoryOperations, artifacts
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ProjectID.self, forKey: .id)
        ownerID = try c.decodeIfPresent(UUID.self, forKey: .ownerID) ?? UUID(uuidString: id.rawValue) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        coordinatorAgentID = try c.decodeIfPresent(AgentID.self, forKey: .coordinatorAgentID)
        revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 1
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? true
        settings = try c.decodeIfPresent(LogicalProjectSettings.self, forKey: .settings) ?? .init()
        memory = try c.decodeIfPresent([ProjectMemory].self, forKey: .memory) ?? []
        linkedSpaces = try c.decodeIfPresent([ProjectSpaceLink].self, forKey: .linkedSpaces) ?? []
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        artifacts = try c.decodeIfPresent([ProjectArtifactReceipt].self, forKey: .artifacts) ?? []
        messages = try c.decodeIfPresent([ProjectMessage].self, forKey: .messages) ?? []
        interruptPending = try c.decodeIfPresent(Bool.self, forKey: .interruptPending) ?? false
        spaceProposals = try c.decodeIfPresent([ProjectSpaceProposal].self, forKey: .spaceProposals) ?? []
        memoryOperations = try c.decodeIfPresent([UUID].self, forKey: .memoryOperations) ?? []
    }

    // Aggregate byte limits also bound JSON-escaped, four-byte characters. The server checks
    // the actual encoded workspace against the existing 1 MiB remote frame ceiling.
    public static let maximumCount = 32
    public static let maximumNameLength = 200
    public static let maximumGoalLength = 4_000
    public static let maximumInstructionsLength = 16_000
    public static let maximumMemoryCount = 64
    public static let maximumMemoryLength = 4_000
    public static let maximumLinkedSpaces = 32
    public static let maximumEncodedCollectionBytes = 512 * 1024

    public static func validID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    public func validate() throws {
        func require(_ valid: Bool, _ message: String) throws {
            if !valid { throw ProjectValidationError(message) }
        }
        try require(Self.validID(id.rawValue), "Project ID must be a canonical lowercase UUID.")
        try require(revision > 0 && revision < UInt64.max, "Invalid project revision.")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && name.count <= Self.maximumNameLength, "Project name must contain 1...200 characters.")
        try require(goal.count <= Self.maximumGoalLength, "Project goal exceeds 4000 characters.")
        try require((1...6).contains(settings.maxConcurrentWorkers), "Threads at once must be 1...6.")
        try require(settings.instructions.count <= Self.maximumInstructionsLength, "Instructions exceed 16000 characters.")
        try require(settings.allowedHosts.count <= 32 && Set(settings.allowedHosts).count == settings.allowedHosts.count, "Invalid allowed hosts.")
        try require(spaceProposals.count <= 32 && Set(spaceProposals.map(\.id)).count == spaceProposals.count
                    && Set(spaceProposals.map(\.operationID)).count == spaceProposals.count, "Invalid or excessive Space proposals.")
        for proposal in spaceProposals {
            try require((proposal.path != nil) != (proposal.spaceID != nil), "Choose an existing Space or an absolute path.")
            try require(proposal.revision > 0 && proposal.displayPath.count <= 4096, "Invalid Space proposal.")
            if let path = proposal.path { try require(path.hasPrefix("/") && !path.utf8.contains(0) && path.count <= 4096, "Invalid Space path.") }
            if let task = proposal.originTaskID { try require(tasks.contains { $0.id == task }, "Proposal task is not in this Project.") }
        }
        for model in [settings.conversationModel, settings.threadModel].compactMap({ $0 }) {
            try require(!model.isEmpty && model.count <= 512, "Model preference must contain 1...512 characters.")
        }
        try require(tasks.count <= 64 && Set(tasks.map(\.id)).count == tasks.count
                    && Set(tasks.map(\.operationID)).count == tasks.count
                    && Set(tasks.map(\.workerAgentID)).count == tasks.count, "Invalid or excessive project tasks.")
        for task in tasks {
            try require(Self.validID(task.id.rawValue) && Self.validID(task.workerAgentID.rawValue)
                        && Self.validID(task.spaceID.rawValue) && task.revision > 0, "Invalid task identity or revision.")
            if let assignment = task.executionAssignment {
                try assignment.validate()
                try require(task.destination != .local && assignment.key.ownerID == ownerID && assignment.key.projectID == id
                    && assignment.key.operationID == task.operationID && assignment.taskID == task.id
                    && assignment.reservedWorkerID == task.workerAgentID && assignment.executorSpaceID == task.spaceID,
                    "Execution assignment does not match its reserved task.")
                if let receipt = task.executionReceipt {
                    try receipt.validate()
                    try require(receipt.key == assignment.key && (receipt.assignment == nil || receipt.assignment == assignment), "Execution evidence changed its assignment.")
                }
            }
            try require(task.executionReceipt == nil || task.executionAssignment != nil, "Execution receipt lacks its immutable assignment.")
            if let session = task.workerSessionID { try require(!session.isEmpty && session.utf8.count <= 1024, "Invalid worker session identity.") }
            if let answer = task.pendingAnswer {
                try require(answer.request.count <= 32 * 1024 && answer.sessionID.utf8.count <= 1024
                    && answer.generation.utf8.count <= 1024 && answer.dialogID.utf8.count <= 1024, "Pending answer exceeds its native envelope budget.")
            }
            let resolutions = task.resolutionOperations ?? []
            try require(resolutions.count <= 32 && Set(resolutions).count == resolutions.count, "Invalid resolution receipts.")
            let operations = (task.previousOperations ?? []) + [task.operationID]
            try require(operations.count <= 32 && Set(operations).count == operations.count, "Invalid task activation identities.")
            try require(!task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.title.count <= 200
                        && !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.prompt.utf8.count <= 16 * 1024,
                        "Task needs a nonempty title and prompt up to 16 KiB UTF-8.")
        }
        try ProjectArtifactReceipt.validateCollection(artifacts)
        for artifact in artifacts {
            try require(artifact.key.ownerID == ownerID && artifact.key.projectID == id
                && tasks.contains { $0.id == artifact.taskID && $0.workerAgentID == artifact.workerAgentID
                    && ([$0.operationID] + ($0.previousOperations ?? [])).contains(artifact.key.operationID) }, "Artifact provenance does not match its task.")
        }
        try require(messages.count <= 64 && Set(messages.map(\.id)).count == messages.count, "Project message queue is full or duplicated.")
        let answers = messages.flatMap { $0.answerReceipts ?? [] }
        try require(answers.count <= 64 && Set(answers.map { $0.nativeAnswer.operationID }).count == answers.count,
                    "Project chat answer receipts are full or duplicated.")
        for message in messages {
            for receipt in message.answerReceipts ?? [] {
                let answer = receipt.nativeAnswer
                try require(message.humanSubmitted == true && message.source == nil && answer.request.count <= 32 * 1024
                    && answer.sessionID.utf8.count <= 1024 && answer.generation.utf8.count <= 1024 && answer.dialogID.utf8.count <= 1024,
                    "Invalid human chat answer receipt.")
            }
            let images = message.images ?? []
            try require((!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && message.text.utf8.count <= 16 * 1024,
                        "Project message needs text or images, with text up to 16 KiB UTF-8.")
            // Matches NativeImage's payload bounds without a Core -> Protocol dependency.
            try require(images.count <= 4 && Set(images.map(\.id)).count == images.count
                        && images.allSatisfy { $0.byteCount >= 0 && $0.byteCount <= 2 * 1024 * 1024
                            && $0.mimeType.hasPrefix("image/") && $0.mimeType.utf8.count <= 256
                            && ($0.name?.utf8.count ?? 0) <= 1024 }
                        && images.reduce(0, { $0 + $1.byteCount }) <= 5 * 1024 * 1024
                        && (images.isEmpty || message.source == nil), "Invalid Project input image descriptors.")
        }
        try require(memoryOperations.count <= 128 && Set(memoryOperations).count == memoryOperations.count, "Invalid or excessive memory receipts.")
        try require(memory.count <= Self.maximumMemoryCount, "Project exceeds 64 memory entries.")
        try require(Set(memory.map(\.id)).count == memory.count, "Duplicate memory ID.")
        for entry in memory {
            try require(Self.validID(entry.id.rawValue), "Invalid memory ID.")
            try require(!entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && entry.text.count <= Self.maximumMemoryLength, "Memory must contain 1...4000 characters.")
            try require(!entry.source.isEmpty && entry.source.count <= 200, "Memory source must contain 1...200 characters.")
            try require(entry.createdAt.isFinite && entry.createdAt >= 0, "Invalid memory timestamp.")
        }
        try require(linkedSpaces.count <= Self.maximumLinkedSpaces, "Project exceeds 32 linked Spaces.")
        try require(Set(linkedSpaces.map(\.id)).count == linkedSpaces.count, "Duplicate linked Space.")
        for link in linkedSpaces {
            try require(Self.validID(link.spaceID.rawValue), "Invalid linked Space ID.")
            try require(link.linkedAt.isFinite && link.linkedAt >= 0, "Invalid Space link timestamp.")
        }
    }
}

public struct ProjectValidationError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ message: String) { description = message }
}
