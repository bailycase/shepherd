import Foundation
import ShepherdCore

/// Host-owned project files. The relative file name is allowlisted by the host, not an arbitrary path.
public enum RemoteProjectsRequest: Codable, Hashable, Sendable {
    case list(offset: Int = 0)
    case files(directory: String)
    case context(directory: String)
    case open(directory: String, file: String)
    public var requiresDetails: Bool {
        switch self { case .context, .open: true; default: false }
    }
    /// Explicit, host-owned OAuth actions. No server configuration or tokens cross this API.
    case mcp(directory: String, file: String, action: ProjectMCPAction)
    public var requiresMCP: Bool { if case .mcp = self { true } else { false } }
    public var requiresProjectTrust: Bool {
        if case .mcp(_, _, .approveProject) = self { true } else { false }
    }
    case read(directory: String, file: String)
    case save(directory: String, file: String, text: String, expected: String?)
}

public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
    public var directory: String
    public var projectID: SpaceID?
    public var name: String
    public var displayPath: String
    public var summary: String
    public var minimal: Bool
    public var error: String?
    public var id: String { directory }

    public init(directory: String, name: String, displayPath: String, summary: String, minimal: Bool = false, error: String? = nil, projectID: SpaceID? = nil) {
        self.projectID = projectID
        self.directory = directory; self.name = name; self.displayPath = displayPath
        self.summary = summary; self.minimal = minimal; self.error = error
    }
}

public struct ProjectListing: Codable, Hashable, Sendable {
    public var projects: [ProjectSummary]
    public var nextOffset: Int?
    public init(projects: [ProjectSummary], nextOffset: Int? = nil) { self.projects = projects; self.nextOffset = nextOffset }
}

public struct ProjectFile: Codable, Hashable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case instructions, pi, skills, extensions, mcp
        public var title: String {
            switch self {
            case .instructions: "Instructions"
            case .pi: "Pi settings"
            case .skills: "Skills"
            case .extensions: "Extensions"
            case .mcp: "MCP servers"
            }
        }
    }
    public var path: String
    public var category: Category
    public var exists: Bool
    public var id: String { path }
    public init(path: String, category: Category, exists: Bool) { self.path = path; self.category = category; self.exists = exists }
}

public struct ProjectFileText: Codable, Hashable, Sendable {
    public var file: ProjectFile
    /// Nil means no file. An empty string means an existing empty file, also for conflict checking.
    public var text: String?
    public var modifiedAt: Double?
    public init(file: ProjectFile, text: String?, modifiedAt: Double? = nil) {
        self.file = file; self.text = text; self.modifiedAt = modifiedAt
    }
}

public enum RemoteProjectsResult: Codable, Hashable, Sendable {
    case listing(ProjectListing)
    case files([ProjectFile])
    case text(ProjectFileText)
    case context(ProjectContext)
    case opened
    case mcp(ProjectMCPResult)
}

public enum ProjectMCPAction: Codable, Hashable, Sendable {
    case credentials
    /// Explicit user confirmation covers all Pi project resources, not only MCP.
    case approveProject
    case login(server: String)
    case poll(id: UUID)
    case complete(id: UUID, redirectURL: String)
    case cancel(id: UUID)
    case logout(server: String)
}

public struct ProjectMCPResult: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable { case waiting, done, failed }
    public var id: UUID?
    public var phase: Phase
    public var authorizationURL: String?
    public var signedIn: [String]
    public var message: String?
    /// Eligibility to load project resources, never a live thread connection. Nil on old hosts.
    public var projectTrusted: Bool?
    public init(id: UUID? = nil, phase: Phase = .done, authorizationURL: String? = nil,
                signedIn: [String] = [], message: String? = nil, projectTrusted: Bool? = nil) {
        self.id = id; self.phase = phase; self.authorizationURL = authorizationURL
        self.signedIn = signedIn; self.message = message; self.projectTrusted = projectTrusted
    }
}

public struct ProjectContext: Codable, Hashable, Sendable {
    public struct File: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var displayPath: String
        public var id: String { path }
        public var isGlobal: Bool?
        public init(path: String, displayPath: String, isGlobal: Bool? = nil) {
            self.path = path; self.displayPath = displayPath; self.isGlobal = isGlobal
        }
    }
    public var files: [File]
    public var resources: Int
    public var mcpServers: Int
    public init(files: [File] = [], resources: Int = 0, mcpServers: Int = 0) {
        self.files = files; self.resources = resources; self.mcpServers = mcpServers
    }
}

public struct ProjectFileError: Error, CustomStringConvertible, Sendable {
    public var code: String
    public var description: String
    public init(_ code: String, _ message: String) { self.code = code; self.description = message }
}
