import Foundation
import Darwin
import ShepherdProtocol

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

    /// A space resource file the Resources tab may create, edit and remove, by its path:
    /// `<base>/skills/<name>/SKILL.md` (also `.agents/skills`), `<base>/prompts/<name>.md`,
    /// `<base>/agents/<name>.md` or `<base>/extensions/<name>.{ts,js,mjs,cjs}`. Nothing nested deeper.
    static func resourceKind(_ path: String) -> ProjectResource.Kind? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts.dropFirst().allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") && $0.utf8.count <= 128 })
        else { return nil }
        switch (parts.count, parts[1]) {
        case (4, "skills") where (directories + [".agents"]).contains(parts[0]) && parts[3] == "SKILL.md": return .skill
        case (3, "prompts") where directories.contains(parts[0]) && parts[2].hasSuffix(".md"): return .prompt
        case (3, "agents") where directories.contains(parts[0]) && parts[2].hasSuffix(".md"): return .agent
        case (3, "extensions") where directories.contains(parts[0]) && ["ts", "js", "mjs", "cjs"].contains((parts[2] as NSString).pathExtension): return .extension
        default: return nil
        }
    }
}
