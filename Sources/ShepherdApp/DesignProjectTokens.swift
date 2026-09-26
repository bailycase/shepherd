import Foundation
import ShepherdProtocol

/// The custom properties a design's project declares in its stylesheets, read the way the design
/// agent's `design_check` reads them (`Extensions/shepherd-design.ts`): a bounded walk that skips
/// build and dependency folders. Read-only, off the main actor.
enum DesignProjectTokens {
    static let skipped: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "out", "DerivedData", "Pods", ".next", ".nuxt",
        "coverage", ".swiftpm", "vendor", "Vendor", "target", ".venv", "venv", "__pycache__",
    ]
    static let maxWalked = 5_000
    static let maxFiles = 200
    static let maxBytes = 1_000_000
    static let maxDepth = 6

    static func read(_ folder: URL?) async -> DesignTokens {
        guard let folder else { return DesignTokens() }
        return await Task.detached(priority: .utility) { walk(folder) }.value
    }

    static func walk(_ root: URL) -> DesignTokens {
        var tokens = DesignTokens()
        var stack: [(URL, Int)] = [(root, 0)]
        var walked = 0
        var files = 0
        let manager = FileManager.default
        while let (folder, depth) = stack.popLast(), walked < maxWalked, files < maxFiles {
            let entries = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                                                            options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in entries {
                walked += 1
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if depth < maxDepth, !skipped.contains(entry.lastPathComponent) { stack.append((entry, depth + 1)) }
                } else if values?.isRegularFile == true, ["css", "scss", "less"].contains(entry.pathExtension.lowercased()),
                          (values?.fileSize ?? 0) <= maxBytes, let text = try? String(contentsOf: entry, encoding: .utf8) {
                    let found = DesignTokens.read(css: text)
                    if !found.isEmpty { files += 1 }
                    tokens = tokens.merged(with: found)
                }
            }
        }
        return tokens
    }
}
