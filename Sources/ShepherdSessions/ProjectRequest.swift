import ShepherdCore
import ShepherdProtocol

/// Local project registration and refresh, routed to the live app without selecting a project.
public enum ProjectRequest: Sendable {
    case register(path: String, name: String)
    case refresh
    case child(parentPath: String, path: String, name: String, create: Bool)
}

public typealias ProjectOutcome = Result<(space: Space?, created: Bool), ProjectFileError>
