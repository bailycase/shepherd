import Foundation
import ShepherdCore

public extension RemoteProtocol {
    /// Owner-relative placement and pause-preserving native question controls.
    static let projectPlacementCapability = "logicalProjects.placement.v1"
}

public enum ProjectExecutionRequest: Codable, Hashable, Sendable {
    case execute(ProjectExecutionAssignment)
    case publicationRead(key: ProjectExecutionKey, publicationID: UUID, offset: Int64)

    public var requiresPublications: Bool {
        switch self {
        case .publicationRead: true
        case .execute(let assignment): assignment.publicationsEnabled == true
        default: false
        }
    }
    case snapshot(key: ProjectExecutionKey, watch: Bool)
    case cancel(key: ProjectExecutionKey)
    case pause(key: ProjectExecutionKey)
    case resume(key: ProjectExecutionKey)
    case answer(key: ProjectExecutionKey, request: NativeThreadRequest)

    public var requiresPlacement: Bool {
        switch self { case .pause, .resume, .answer: true; default: false }
    }

    public var key: ProjectExecutionKey {
        switch self {
        case .execute(let assignment): assignment.key
        case .snapshot(let key, _), .cancel(let key), .pause(let key), .resume(let key), .answer(let key, _), .publicationRead(let key, _, _): key
        }
    }
}

public struct ProjectExecutionResult: Codable, Hashable, Sendable {
    public var receipt: ProjectExecutionReceipt
    /// The existing, budgeted native producer; no second transcript is persisted.
    public var thread: NativeThreadSnapshot?
    public var publication: ProjectPublicationChunk?
    /// Live executor proof for this exact activation/session/generation. Missing is not proof.
    public var workerTakenOver: Bool?
    public init(receipt: ProjectExecutionReceipt, thread: NativeThreadSnapshot? = nil, workerTakenOver: Bool? = nil) {
        self.receipt = receipt; self.thread = thread; self.workerTakenOver = workerTakenOver
    }
}
