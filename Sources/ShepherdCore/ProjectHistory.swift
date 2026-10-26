import Foundation

/// Identity proof for bounded live artifact and Space-proposal records, never a full historical task.
public struct ProjectTaskProvenance: Codable, Hashable, Sendable {
    public var taskID: ProjectTaskID
    public var workerAgentID: AgentID
    public var operations: [UUID]
}

public struct ProjectCommandReceipt: Codable, Hashable, Sendable {
    public var operationID: UUID
    public var sha256: String
    public init(operationID: UUID, sha256: String) { self.operationID = operationID; self.sha256 = sha256 }
}

public struct ProjectOperationReceipt: Codable, Hashable, Sendable {
    public var operationID: UUID
    public var taskID: ProjectTaskID?
    public var proposalID: UUID?
    public var task: ProjectTask?
    public var proposal: ProjectSpaceProposal?
    public var message: ProjectMessage?
    public init(operationID: UUID, task: ProjectTask? = nil, proposal: ProjectSpaceProposal? = nil, message: ProjectMessage? = nil) {
        self.operationID = operationID; self.taskID = task?.id; self.proposalID = proposal?.id
        self.task = task; self.proposal = proposal; self.message = message
    }
}

/// Captured from this turn's final assistant message before native row projection. Never thinking or tool output.
public struct ProjectVisibleResult: Hashable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024
    public var text: String
    public var complete: Bool
    public var stopReason: String?
    public init(text: String, complete: Bool, stopReason: String?) {
        self.text = text; self.complete = complete; self.stopReason = stopReason
    }
}

/// Internal staging only: Project's decoder/encoder never accepts or publishes these records.
public struct ProjectStagedEvent: Hashable, Sendable {
    public var message: ProjectMessage
    public var result: ProjectVisibleResult?
    public var settledTask: ProjectTask?
    public init(message: ProjectMessage, result: ProjectVisibleResult? = nil, settledTask: ProjectTask? = nil) {
        self.message = message; self.result = result; self.settledTask = settledTask
    }
}

public struct ProjectHistoryEntry: Codable, Hashable, Sendable {
    public var sequence: Int64
    public var messageID: UUID
    public var source: ProjectEventSource?
    public var phase: ProjectMessage.Phase
    public var humanSubmitted: Bool?
    public var message: ProjectMessage?
    public var bodyOmittedReason: String?
    public init(sequence: Int64, messageID: UUID, source: ProjectEventSource?, phase: ProjectMessage.Phase, humanSubmitted: Bool?, message: ProjectMessage? = nil) {
        self.sequence = sequence; self.messageID = messageID; self.source = source; self.phase = phase; self.humanSubmitted = humanSubmitted; self.message = message
    }
}

public struct ProjectResultIdentity: Codable, Hashable, Sendable {
    public var ownerID: UUID
    public var projectID: ProjectID
    public var eventID: UUID
    public var source: ProjectEventSource
    public var host: ProjectHostReference
    public var deliveryID: UUID?
    public var observedProjectRevision: UInt64?
    public var executionReceiptRevision: UInt64?
    public init(ownerID: UUID, projectID: ProjectID, eventID: UUID, source: ProjectEventSource,
                host: ProjectHostReference, deliveryID: UUID?, observedProjectRevision: UInt64?) {
        self.ownerID = ownerID; self.projectID = projectID; self.eventID = eventID; self.source = source
        self.host = host; self.deliveryID = deliveryID; self.observedProjectRevision = observedProjectRevision
    }
}

/// Completeness concerns retained visible content, never success, review or permission to act.
public struct ProjectResultPage: Codable, Hashable, Sendable {
    public enum Availability: String, Codable, Sendable { case complete, incomplete, unavailable, unsupported }
    public var identity: ProjectResultIdentity?
    public var availability: Availability
    public var reason: String?
    public var totalBytes: Int64
    public var sha256: String?
    public var offset: Int64
    /// UTF-8 bytes. Decode only after assembling pages; a boundary can split a Unicode scalar.
    public var data: Data
    public var nextOffset: Int64?
    public var stopReason: String?
    public var redacted = true
    public var originEventID: UUID?
    public var originIdentity: ProjectResultIdentity?
    public init(identity: ProjectResultIdentity? = nil, availability: Availability, reason: String? = nil,
                totalBytes: Int64 = 0, sha256: String? = nil, offset: Int64 = 0, data: Data = Data(), nextOffset: Int64? = nil, stopReason: String? = nil) {
        self.identity = identity; self.availability = availability; self.reason = reason; self.totalBytes = totalBytes
        self.sha256 = sha256; self.offset = offset; self.data = data; self.nextOffset = nextOffset; self.stopReason = stopReason
    }
}
