import Foundation
import Darwin

/// Project aliases only. Global Pi configuration stays in Shepherd's private agent home.
enum ProjectConfiguration {
    static let directories = [".shepherd", ".pi"]

    /// A same-named file in .shepherd wins; edits still target the concrete path selected by the caller.
    static func file(_ name: String, in root: URL) -> String {
        let paths = directories.map { $0 + "/" + name }
        return paths.first {
            // Let the file service reject an unsafe preferred path instead of silently falling back.
            var info = stat()
            return lstat(root.appendingPathComponent($0).path, &info) == 0 || errno != ENOENT
        } ?? paths[0]
    }

    static func isMCP(_ path: String) -> Bool {
        directories.contains { path == $0 + "/mcp.json" }
    }
}
