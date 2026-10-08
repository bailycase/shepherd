import Darwin
import Foundation
import ShepherdProtocol

/// Folder creation is explicit, single-level, and never replaces an existing directory or link.
enum ChildProjectDirectory {
    static func prepare(parentPath: String, path: String, name: String, create: Bool) throws -> String {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty, displayName.count <= 256,
              displayName.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ProjectFileError("invalid", "Enter a display name of 1–256 characters without control characters.")
        }
        func absolute(_ value: String) throws -> URL {
            let expanded = (value as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), !value.contains("\0") else {
                throw ProjectFileError("invalid_path", "Use an absolute folder path.")
            }
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let parent = try absolute(parentPath).resolvingSymlinksInPath()
        let requested = try absolute(path)
        let candidate = create
            ? requested.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(requested.lastPathComponent)
            : requested.resolvingSymlinksInPath()
        let prefix = parent.path == "/" ? "/" : parent.path + "/"
        guard candidate.path != parent.path, candidate.path.hasPrefix(prefix) else {
            throw ProjectFileError("outside_parent", "Choose a folder inside the parent project.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectFileError("invalid_parent", "The parent project folder no longer exists.")
        }
        guard create else { return candidate.path }
        guard candidate.deletingLastPathComponent().path == parent.path else {
            throw ProjectFileError("invalid_folder", "Create a single folder directly inside the parent project.")
        }
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectFileError("create_failed", "Cannot open the parent folder: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard mkdirat(fd, requested.lastPathComponent, mode_t(0o755)) == 0 else {
            if errno == EEXIST { throw ProjectFileError("already_exists", "That folder name already exists. Select Existing folder to add it.") }
            throw ProjectFileError("create_failed", "Could not create the folder: \(String(cString: strerror(errno)))")
        }
        return candidate.path
    }
}
