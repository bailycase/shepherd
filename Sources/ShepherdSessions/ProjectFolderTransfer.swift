import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

/// Explicit, no-overwrite folder operations. Move is an atomic same-filesystem rename;
/// copy preserves the source. A failed copy may leave a partial destination, never auto-deleted.
enum ProjectFolderTransfer {
    struct Plan: Sendable {
        let source: String
        let destination: String
        let action: ProjectEdit.FolderAction
        let paths: [SpaceID: String]
    }

    static func plan(space: Space, edit: ProjectEdit, state: ShepherdState, liveDirectories: [String], protectedPaths: [String]) throws -> Plan {
        let fm = FileManager.default
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        }
        let source = canonical(space.path)
        guard let raw = edit.destinationPath, (raw as NSString).expandingTildeInPath.hasPrefix("/"), !raw.contains("\0") else {
            throw ProjectFileError("invalid_destination", "An explicit move or copy needs an absolute destinationPath.")
        }
        let requested = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
        let parent = canonical(requested.deletingLastPathComponent().path)
        let destination = (parent as NSString).appendingPathComponent(requested.lastPathComponent)
        func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        guard source != "/", source != fm.homeDirectoryForCurrentUser.path,
              !contains(source, destination), !contains(destination, source) else {
            throw ProjectFileError("invalid_destination", "Source and destination must be separate, non-overlapping project folders.")
        }
        guard !protectedPaths.map(canonical).contains(where: { contains(source, $0) || contains($0, source) || contains(destination, $0) || contains($0, destination) }) else {
            throw ProjectFileError("protected_path", "Application, runtime, authentication, and home configuration folders cannot be moved or copied by project tools.")
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: source, isDirectory: &directory), directory.boolValue,
              fm.fileExists(atPath: parent, isDirectory: &directory), directory.boolValue else {
            throw ProjectFileError("invalid_path", "The source folder and destination's parent must already exist.")
        }
        let entries = try fm.contentsOfDirectory(atPath: parent)
        guard !entries.contains(where: { $0.caseInsensitiveCompare(requested.lastPathComponent) == .orderedSame }) else {
            throw ProjectFileError("destination_exists", "The destination already exists. Nothing was overwritten.")
        }
        let spaces = state.spaces.filter { contains(source, canonical($0.path)) }
        let affected = Set(spaces.map(\.id))
        guard !state.agents.contains(where: { affected.contains($0.spaceID) || $0.worktreePath.map { contains(source, canonical($0)) } == true }),
              !state.tabs.contains(where: { $0.spaceID.map(affected.contains) == true || $0.layout.leaves.contains { contains(source, canonical($0.cwd)) } }),
              !state.automations.contains(where: { contains(source, canonical($0.cwd)) }),
              !state.designs.contains(where: { $0.sourceSpaceID.map(affected.contains) == true }),
              !liveDirectories.contains(where: { contains(source, canonical($0)) }) else {
            throw ProjectFileError("project_in_use", "Remove this folder's threads, terminals, automations, and design references before moving or copying it. Use another project's thread for this operation.")
        }
        guard !state.spaces.contains(where: { !affected.contains($0.id) && contains(destination, canonical($0.path)) }) else {
            throw ProjectFileError("destination_registered", "The destination contains an existing registered project.")
        }
        for project in spaces {
            let git = URL(fileURLWithPath: canonical(project.path)).appendingPathComponent(".git")
            if fm.fileExists(atPath: git.path, isDirectory: &directory) {
                guard directory.boolValue, !fm.fileExists(atPath: git.appendingPathComponent("worktrees").path) else {
                    throw ProjectFileError("linked_worktree", "Linked Git worktrees require Git-aware relocation; this folder tool will not move or copy them.")
                }
            }
        }
        // Bound preflight and refuse embedded linked repositories too, not just registered roots.
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var scanError: Error?
        guard let scan = fm.enumerator(at: URL(fileURLWithPath: source), includingPropertiesForKeys: keys, errorHandler: { _, error in scanError = error; return false }) else {
            throw ProjectFileError("unreadable", "Cannot inspect the source folder safely.")
        }
        var entriesSeen = 0, bytes = 0
        let deadline = Date().addingTimeInterval(15)
        for case let item as URL in scan {
            entriesSeen += 1
            let info = try item.resourceValues(forKeys: Set(keys))
            if info.isSymbolicLink != true { bytes += info.fileSize ?? 0 }
            guard entriesSeen <= 50_000, bytes <= 2_147_483_648, Date() < deadline else {
                throw ProjectFileError("transfer_limit", "Project transfers are limited to 50,000 entries, 2 GiB, and 15 seconds of inspection. Move/copy larger folders outside Shepherd, then register the destination.")
            }
            if item.lastPathComponent == ".git", info.isDirectory != true || info.isSymbolicLink == true || fm.fileExists(atPath: item.appendingPathComponent("worktrees").path) {
                throw ProjectFileError("linked_worktree", "The folder contains linked Git metadata. Use Git-aware relocation instead.")
            }
            if item.lastPathComponent == "worktrees",
               fm.fileExists(atPath: item.deletingLastPathComponent().appendingPathComponent("HEAD").path),
               fm.fileExists(atPath: item.deletingLastPathComponent().appendingPathComponent("objects").path) {
                throw ProjectFileError("linked_worktree", "The folder contains a bare Git repository with linked worktrees. Use Git-aware relocation instead.")
            }
        }
        if let scanError { throw ProjectFileError("unreadable", "Cannot inspect all source files: \(scanError)") }
        let paths = Dictionary(uniqueKeysWithValues: spaces.map { project in
            (project.id, destination + canonical(project.path).dropFirst(source.count))
        })
        return Plan(source: source, destination: destination, action: edit.folderAction, paths: paths)
    }

    static func perform(_ plan: Plan) throws {
        if plan.action == .copy {
            do { try FileManager.default.copyItem(atPath: plan.source, toPath: plan.destination) }
            catch { throw ProjectFileError("copy_failed", "Copy failed: \(error). The source is unchanged. Inspect \(plan.destination) for a partial copy; nothing was deleted automatically.") }
        } else {
            guard renamex_np(plan.source, plan.destination, UInt32(RENAME_EXCL)) == 0 else {
                throw ProjectFileError("move_failed", "Move failed: \(String(cString: strerror(errno))). Move requires the same filesystem and an unused destination. Nothing was copied automatically.")
            }
        }
    }

    static func rollbackMove(_ plan: Plan) -> Bool {
        renamex_np(plan.destination, plan.source, UInt32(RENAME_EXCL)) == 0
    }
}
