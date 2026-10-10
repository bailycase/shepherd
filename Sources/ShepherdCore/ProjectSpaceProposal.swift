import Foundation

/// References are relative to the Project owner. A binding changes when that owner's saved
/// destination changes; a viewer's similarly named host is never interchangeable.
public enum ProjectHostReference: Codable, Hashable, Sendable {
    case local
    case remote(hostID: UUID, bindingID: UUID)
}

public struct ProjectHostOption: Codable, Hashable, Sendable {
    public var reference: ProjectHostReference
    public var name: String
    /// Visible executor Spaces from the owner's authenticated connection, never path mappings.
    public var spaces: [Space]?
    public init(reference: ProjectHostReference, name: String, spaces: [Space]? = nil) {
        self.reference = reference; self.name = name; self.spaces = spaces
    }
}

public enum ProjectHostPolicy: String, Codable, Sendable { case selected, anyConnected }

public struct ProjectSpaceProposal: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable { case pending, accepted, denied }
    public var id: UUID
    public var operationID: UUID
    public var path: String?
    public var spaceID: SpaceID?
    public var displayPath: String
    public var phase: Phase
    public var originTaskID: ProjectTaskID?
    public var revision: UInt64
    public init(id: UUID, operationID: UUID, path: String? = nil, spaceID: SpaceID? = nil,
                displayPath: String, phase: Phase = .pending, originTaskID: ProjectTaskID? = nil, revision: UInt64 = 1) {
        self.id = id; self.operationID = operationID; self.path = path; self.spaceID = spaceID
        self.displayPath = displayPath; self.phase = phase; self.originTaskID = originTaskID; self.revision = revision
    }
}
