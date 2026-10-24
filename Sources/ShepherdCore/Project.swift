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
    /// The coordinator's reasoning level (a `ThinkingLevel` raw value), applied with `conversationModel` at launch and before each
    /// delivered message; nil keeps the coordinator's own level (the owner's default for a new one).
    public var conversationThinking: String?
    public var threadModel: String?
    public var instructions: String
    /// Permission to request user approval, never permission to link a Space autonomously.
    public var canRequestSpaceLinks: Bool
    public var hostPolicy: ProjectHostPolicy
    public var allowedHosts: [ProjectHostReference]

    public init(maxConcurrentWorkers: Int = 3, conversationModel: String? = nil,
                threadModel: String? = nil, instructions: String = "", canRequestSpaceLinks: Bool = true,
                hostPolicy: ProjectHostPolicy = .selected, allowedHosts: [ProjectHostReference] = [.local], conversationThinking: String? = nil) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.conversationModel = conversationModel
        self.conversationThinking = conversationThinking
        self.threadModel = threadModel
        self.instructions = instructions
        self.canRequestSpaceLinks = canRequestSpaceLinks
        self.hostPolicy = hostPolicy
        self.allowedHosts = allowedHosts
    }

    private enum CodingKeys: String, CodingKey {
        case maxConcurrentWorkers, conversationModel, conversationThinking, threadModel, instructions, canRequestSpaceLinks, hostPolicy, allowedHosts
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxConcurrentWorkers = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentWorkers) ?? 3
        conversationModel = try c.decodeIfPresent(String.self, forKey: .conversationModel)
        conversationThinking = try c.decodeIfPresent(String.self, forKey: .conversationThinking)
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
    /// Native operations of retired worker-event wake-ups (`retireFinishedMessages`), so the conversation still hides them.
    public var retiredWakeups: [UUID] = []
    /// Owner-internal native captures, consumed by the durable history writer before publication. Never decoded from wire/state.
    public var stagedEvents: [ProjectStagedEvent] = []
    /// Explicit read responses only. Normal snapshots/working state leave these nil.
    public var archivedResolvedTaskCount: Int?
    public var referencedTasks: [ProjectTaskProvenance] = []
    public var historyPending: Bool?
    public var commandReceipt: ProjectCommandReceipt?
    public var operationReceipt: ProjectOperationReceipt?
    public var resultPage: ProjectResultPage?
    public var historyPage: [ProjectHistoryEntry]?
    public var historyNext: Int64?
    /// One explicit `.outcomes` page, newest first; `historyNext` continues it.
    public var outcomePage: [ProjectArchivedOutcome]?
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
        case id, ownerID, name, goal, coordinatorAgentID, revision, paused, settings, memory, linkedSpaces, tasks, messages, interruptPending, spaceProposals, memoryOperations, artifacts, retiredWakeups, archivedResolvedTaskCount, referencedTasks, historyPending, commandReceipt, operationReceipt, resultPage, historyPage, historyNext, outcomePage
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
        retiredWakeups = try c.decodeIfPresent([UUID].self, forKey: .retiredWakeups) ?? []
        referencedTasks = try c.decodeIfPresent([ProjectTaskProvenance].self, forKey: .referencedTasks) ?? []
        archivedResolvedTaskCount = try c.decodeIfPresent(Int.self, forKey: .archivedResolvedTaskCount)
        historyPending = try c.decodeIfPresent(Bool.self, forKey: .historyPending)
        commandReceipt = try c.decodeIfPresent(ProjectCommandReceipt.self, forKey: .commandReceipt)
        operationReceipt = try c.decodeIfPresent(ProjectOperationReceipt.self, forKey: .operationReceipt)
        resultPage = try c.decodeIfPresent(ProjectResultPage.self, forKey: .resultPage)
        historyPage = try c.decodeIfPresent([ProjectHistoryEntry].self, forKey: .historyPage)
        historyNext = try c.decodeIfPresent(Int64.self, forKey: .historyNext)
        outcomePage = try c.decodeIfPresent([ProjectArchivedOutcome].self, forKey: .outcomePage)
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
    /// What of the remembered facts rides along with every new turn and remote assignment (`ProjectExecutionAssignment.memory`'s cap).
    public static let briefMemoryBytes = 8_000

    /// The newest whole entries that fit `budget` UTF-8 bytes, oldest first, each line carrying its source, plus one honest
    /// line when older ones were left out. Older facts stay stored, listed in Project settings and returned by the coordinator's
    /// project_read: a brief leaves them out, it never deletes or truncates them.
    public static func briefMemory(_ memory: [ProjectMemory], budget: Int = briefMemoryBytes) -> String {
        let kept = briefMemoryFacts(memory, budget: budget)
        let lines = kept.map { "\($0.text) [source: \($0.source)]" } + (kept.count < memory.count ? [briefMemoryOmission(memory.count - kept.count)] : [])
        return lines.joined(separator: "\n")
    }

    public static func briefMemoryOmission(_ count: Int) -> String {
        "(\(count) older remembered facts omitted; they remain stored with the Project owner.)"
    }

    /// Preserve fact boundaries for executors; a formatted brief cannot be split back into records safely.
    public static func briefMemoryFacts(_ memory: [ProjectMemory], budget: Int = briefMemoryBytes) -> [ProjectMemory] {
        let note = briefMemoryOmission
        // Reserve room for the omission line so the whole brief, note included, stays within budget.
        let room = budget - note(memory.count).utf8.count - 1
        var used = 0
        return Array(memory.reversed().prefix { entry in
            used += "\(entry.text) [source: \(entry.source)]".utf8.count + 1
            return used - 1 <= room
        }.reversed())
    }

    /// Messages kept once older finished ones are retired. `messages` is a delivery log, not chat history (pi's transcript is), so
    /// without this a long conversation hit the 64-entry ceiling and every later save was refused.
    public static let retainedMessages = 32

    /// Retires only durably archived finished messages past `retainedMessages`. Never an unknown dispatch, one waiting or in flight, one whose chat answer is in
    /// flight, a question event its task still waits on, the newest human message (the reply a chat answer cites), or one of the newest eight.
    public mutating func retireFinishedMessages(archived: Set<UUID> = []) {
        guard messages.count > Self.retainedMessages else { return }
        let waiting = Set(tasks.filter { $0.phase == .waiting }.map(\.operationID))
        var newest = Set(messages.suffix(8).map(\.id))
        if let human = messages.last(where: { $0.humanSubmitted == true }) { newest.insert(human.id) }
        var excess = messages.count - Self.retainedMessages
        messages.removeAll { message in
            guard excess > 0, archived.contains(message.id), ![.queued, .delivering, .unknown].contains(message.phase), !newest.contains(message.id),
                  !(message.answerReceipts ?? []).contains(where: { [.queued, .delivering, .unknown].contains($0.nativeAnswer.phase) }),
                  !(message.source.map { $0.kind == .question && waiting.contains($0.operationID) } ?? false) else { return false }
            excess -= 1
            if message.source != nil { retiredWakeups += [message.id] + [message.nativeDeliveryID].compactMap { $0 } }
            return true
        }
        // ponytail: this display-only suppression cache covers 128 IDs; durable history, not this list, owns replay proof.
        if retiredWakeups.count > 128 { retiredWakeups.removeFirst(retiredWakeups.count - 128) }
    }

    public static func validID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    /// This only edits a disposable candidate. The owner must archive its committed predecessor before publication.
    public mutating func retireResolvedTasks(eligible: Set<ProjectTaskID>) {
        var excess = tasks.filter { $0.phase == .resolved }.count - 16
        let protected = Set(messages.filter { [.queued, .delivering, .unknown].contains($0.phase) }.compactMap { $0.source?.taskID })
        retainReferenceProof()
        tasks.removeAll { task in
            guard excess > 0, eligible.contains(task.id), task.phase == .resolved, !protected.contains(task.id), task.pendingAnswer.map({ [.queued, .delivering, .unknown].contains($0.phase) }) != true else { return false }
            excess -= 1; return true
        }
    }

    /// Keep only exact identities referenced by the bounded artifact/proposal working sets.
    public mutating func retainReferenceProof() {
        let references = Set(artifacts.map(\.taskID) + spaceProposals.compactMap(\.originTaskID))
        var proof = referencedTasks.filter { references.contains($0.taskID) }
        for task in tasks where references.contains(task.id) {
            let previous = proof.first { $0.taskID == task.id && $0.workerAgentID == task.workerAgentID }?.operations ?? []
            let known = Set([task.operationID] + (task.previousOperations ?? []) + previous)
            var needed = Set(artifacts.filter { $0.taskID == task.id }.map { $0.key.operationID })
            if spaceProposals.contains(where: { $0.originTaskID == task.id }) { needed.insert(task.operationID) }
            proof.removeAll { $0.taskID == task.id }
            proof.append(.init(taskID: task.id, workerAgentID: task.workerAgentID, operations: needed.intersection(known).sorted { $0.uuidString < $1.uuidString }))
        }
        referencedTasks = proof
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
            if let task = proposal.originTaskID { try require(tasks.contains { $0.id == task } || referencedTasks.contains { $0.taskID == task }, "Proposal task is not in this Project.") }
        }
        for model in [settings.conversationModel, settings.threadModel].compactMap({ $0 }) {
            try require(!model.isEmpty && model.count <= 512, "Model preference must contain 1...512 characters.")
        }
        if let level = settings.conversationThinking {
            try require(ThinkingLevel(rawValue: level) != nil, "Reasoning level must be one of " + ThinkingLevel.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        try require((archivedResolvedTaskCount ?? 0) >= 0, "Invalid archived task count.")
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
            let outcomes = task.outcomes ?? []
            try require(outcomes.count <= ProjectTaskOutcome.hotPerTask && (task.archivedOutcomeCount ?? 0) >= 0 && Set(outcomes.map(\.id)).count == outcomes.count
                && outcomes.allSatisfy { $0.recordedAt.isFinite && $0.recordedAt >= 0 && ($0.evidence?.utf8.count ?? 0) <= ProjectTaskOutcome.maximumEvidenceBytes
                    && (!$0.kind.needsEvidence || $0.evidence?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) },
                "Invalid task outcomes: archive older facts; delivery facts need evidence up to 256 bytes.")
            let resolutions = task.resolutionOperations ?? []
            try require(resolutions.count <= 32 && Set(resolutions).count == resolutions.count, "Invalid resolution receipts.")
            let operations = (task.previousOperations ?? []) + [task.operationID]
            try require(operations.count <= ProjectArtifactReceipt.maximumCount + 2 && Set(operations).count == operations.count, "Invalid task activation identities.")
            try require(!task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.title.count <= 200
                        && !task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && task.prompt.utf8.count <= 16 * 1024,
                        "Task needs a nonempty title and prompt up to 16 KiB UTF-8.")
        }
        let references = Set(artifacts.map(\.taskID) + spaceProposals.compactMap(\.originTaskID))
        try require(referencedTasks.count <= ProjectArtifactReceipt.maximumCount + 32
            && Set(referencedTasks.map(\.taskID)).count == referencedTasks.count
            && referencedTasks.allSatisfy { references.contains($0.taskID)
                && !$0.operations.isEmpty && $0.operations.count <= ProjectArtifactReceipt.maximumCount + 2
                && Set($0.operations).count == $0.operations.count }, "Invalid referenced task provenance.")
        try ProjectArtifactReceipt.validateCollection(artifacts)
        for artifact in artifacts {
            try require(artifact.key.ownerID == ownerID && artifact.key.projectID == id
                && (tasks.contains { $0.id == artifact.taskID && $0.workerAgentID == artifact.workerAgentID
                    && ([$0.operationID] + ($0.previousOperations ?? [])).contains(artifact.key.operationID) }
                || referencedTasks.contains { $0.taskID == artifact.taskID && $0.workerAgentID == artifact.workerAgentID
                    && $0.operations.contains(artifact.key.operationID) }), "Artifact provenance does not match its task.")
        }
        try require(commandReceipt == nil || commandReceipt?.sha256.utf8.count == 64, "Command receipt exceeds its working-set bound.")
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
        try require(retiredWakeups.count <= 128, "Too many retired wake-up receipts.")
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
