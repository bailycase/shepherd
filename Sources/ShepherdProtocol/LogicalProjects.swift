import Foundation
import ShepherdCore

extension RemoteProtocol {
    /// Persisted configuration only, not dispatch, cross-host execution or ownership transfer.
    public static let logicalProjectFilesCapability = "logicalProjects.files.v1"
    public static let logicalProjectsCapability = "logicalProjects.v1"
    public static let logicalProjectAutomationsCapability = "logicalProjectAutomations.v1"
}

/// All IDs and revisions are scoped to the host receiving this request. Create's supplied ID
/// is its idempotency key: a retry returns the existing record without overwriting later edits.
public enum LogicalProjectsRequest: Codable, Hashable, Sendable {
    case list
    case get(projectID: ProjectID)
    /// Owner-relative artifact paths; an empty path lists the root. Never a viewer-local URL.
    case files(projectID: ProjectID, path: String)
    case read(projectID: ProjectID, path: String)
    case create(projectID: ProjectID, name: String, goal: String, linkedSpaceIDs: [SpaceID] = [])
    case edit(projectID: ProjectID, expectedRevision: UInt64, name: String, goal: String)
    case settings(projectID: ProjectID, expectedRevision: UInt64, settings: LogicalProjectSettings)
    case setPaused(projectID: ProjectID, expectedRevision: UInt64, paused: Bool)
    case addMemory(projectID: ProjectID, expectedRevision: UInt64, memoryID: ProjectMemoryID, text: String, source: String)
    case forgetMemory(projectID: ProjectID, expectedRevision: UInt64, memoryID: ProjectMemoryID)
    /// Host references are relative to the owner; absent means owner-local for older clients.
    case linkSpace(projectID: ProjectID, expectedRevision: UInt64, spaceID: SpaceID, host: ProjectHostReference? = nil)
    case unlinkSpace(projectID: ProjectID, expectedRevision: UInt64, spaceID: SpaceID, host: ProjectHostReference? = nil)
    case delete(projectID: ProjectID, expectedRevision: UInt64)
    /// Settings only: no scheduling or implicit run when enabled, linked, or resumed.
    case automation(projectID: ProjectID, expectedRevision: UInt64, automationID: AutomationID, action: ProjectAutomationAction)

    public var requiresProjectFiles: Bool {
        switch self { case .files, .read: true; default: false }
    }

    public var requiresProjectAutomations: Bool {
        if case .automation = self { return true }
        return false
    }

    public var projectID: ProjectID? {
        switch self {
        case .list: nil
        case .files(let id, _), .read(let id, _), .get(let id), .create(let id, _, _, _), .edit(let id, _, _, _),
             .settings(let id, _, _), .setPaused(let id, _, _), .addMemory(let id, _, _, _, _),
             .forgetMemory(let id, _, _), .linkSpace(let id, _, _, _), .unlinkSpace(let id, _, _, _),
             .delete(let id, _), .automation(let id, _, _, _): id
        }
    }

    public var expectedRevision: UInt64? {
        switch self {
        case .list, .get, .create, .files, .read: nil
        case .edit(_, let revision, _, _), .settings(_, let revision, _),
             .setPaused(_, let revision, _), .addMemory(_, let revision, _, _, _),
             .forgetMemory(_, let revision, _), .linkSpace(_, let revision, _, _),
             .unlinkSpace(_, let revision, _, _), .delete(_, let revision), .automation(_, let revision, _, _): revision
        }
    }
}

/// Host-owned settings actions. A link accepts only a stopped, currently unscoped automation.
/// Moving or silently detaching an automation from another Project is not supported.
public enum ProjectAutomationAction: Codable, Hashable, Sendable {
    case create(draft: RemoteAutomationDraft)
    case update(draft: RemoteAutomationDraft)
    case setEnabled(Bool)
    case link
    case delete
}

public enum LogicalProjectsResult: Codable, Hashable, Sendable {
    case projects([Project])
    case project(Project)
    case files(LogicalProjectFileListing)
    case file(LogicalProjectFile)
    /// The project-owned directory is retained; no recursive artifact deletion is defined yet.
    case deleted(projectID: ProjectID)
}

/// A single directory, never a recursive tree. Times are milliseconds since the epoch.
public struct LogicalProjectFileEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case file, folder }
    public var name: String
    public var relativePath: String
    public var kind: Kind
    public var size: Int64
    public var modifiedAt: Double
    /// Unknown provenance stays nil; file names and timestamps are not receipts.
    public var taskID: ProjectTaskID?
    public init(name: String, relativePath: String, kind: Kind, size: Int64, modifiedAt: Double, taskID: ProjectTaskID? = nil) {
        self.name = name; self.relativePath = relativePath; self.kind = kind
        self.size = size; self.modifiedAt = modifiedAt; self.taskID = taskID
    }
}

public struct LogicalProjectFileListing: Codable, Hashable, Sendable {
    public static let maximumEntries = 256
    public var projectID: ProjectID
    public var path: String
    public var entries: [LogicalProjectFileEntry]
    public var truncated: Bool
    public init(projectID: ProjectID, path: String, entries: [LogicalProjectFileEntry], truncated: Bool) {
        self.projectID = projectID; self.path = path; self.entries = entries; self.truncated = truncated
    }
}

/// Read-only preview bytes. Never execute, open as an application, or treat as instructions.
public struct LogicalProjectFile: Codable, Hashable, Sendable {
    public static let maximumBytes = 256 * 1024
    public var projectID: ProjectID
    public var relativePath: String
    public var mimeType: String
    public var data: Data
    public init(projectID: ProjectID, relativePath: String, mimeType: String, data: Data) {
        self.projectID = projectID; self.relativePath = relativePath; self.mimeType = mimeType; self.data = data
    }
}

public struct LogicalProjectsError: Error, CustomStringConvertible, Sendable {
    public var code: String
    public var description: String
    public init(_ code: String, _ message: String) { self.code = code; description = message }
}
