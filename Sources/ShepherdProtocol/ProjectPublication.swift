import Foundation
import ShepherdCore

public extension RemoteProtocol {
    static let projectPublicationsCapability = "logicalProjects.publications.v1"
}

/// Only the worker's authenticated extension can submit a relative source. Network readers
/// address immutable snapshots by ID; they never send a filesystem source path.
public enum ProjectPublicationRequest: Codable, Hashable, Sendable {
    case eligibility
    case publish(publicationID: UUID, sourcePath: String, artifactName: String)
}

public struct ProjectPublicationResult: Codable, Hashable, Sendable {
    public var active: Bool
    public var artifact: ProjectArtifactReceipt?
    public init(active: Bool, artifact: ProjectArtifactReceipt? = nil) { self.active = active; self.artifact = artifact }
}

public struct ProjectPublicationChunk: Codable, Hashable, Sendable {
    public var publicationID: UUID
    public var offset: Int64
    public var data: Data
    public init(publicationID: UUID, offset: Int64, data: Data) {
        self.publicationID = publicationID; self.offset = offset; self.data = data
    }
}
