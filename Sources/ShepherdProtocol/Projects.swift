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
