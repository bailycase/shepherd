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

/// The tokens file a project keeps its design in (DZStart's "found in web/static/tokens.css"):
/// a stylesheet declaring custom properties, found by the same bounded, read-only walk.
enum DesignSystemDetection {
    /// A stylesheet with fewer custom properties than this is no tokens file.
    static let minDeclarations = 3

    /// The project's tokens file, relative to it, or nil. Off the main actor.
    static func find(_ folder: URL?) async -> String? {
        guard let folder else { return nil }
        return await Task.detached(priority: .utility) { best(candidates(folder)) }.value
    }

    /// Among stylesheets and how many custom properties each declares: one named for tokens
    /// (`tokens.css`, `design-tokens.scss`), else `variables` or `theme`, shallowest first; else
    /// the one declaring the most. Nil when none declares `minDeclarations`.
    static func best(_ candidates: [(path: String, declarations: Int)]) -> String? {
        let eligible = candidates.filter { $0.declarations >= minDeclarations }
        func rank(_ path: String) -> Int {
            let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
            if name.contains("token") { return 0 }
            if name.contains("variables") || name.contains("theme") { return 1 }
            return 2
        }
        return eligible.min { a, b in
            let (ra, rb) = (rank(a.path), rank(b.path))
            if ra != rb { return ra < rb }
            if ra == 2, a.declarations != b.declarations { return a.declarations > b.declarations }
            let (da, db) = (a.path.split(separator: "/").count, b.path.split(separator: "/").count)
            if da != db { return da < db }
            if a.declarations != b.declarations { return a.declarations > b.declarations }
            return a.path < b.path
        }?.path
    }

    /// Every stylesheet under `root` (skipping build and dependency folders) with how many
    /// custom properties it declares.
    static func candidates(_ root: URL) -> [(path: String, declarations: Int)] {
        var found: [(path: String, declarations: Int)] = []
        var stack: [(URL, Int)] = [(root, 0)]
        var walked = 0
        let manager = FileManager.default
        let base = root.standardizedFileURL.path + "/"
        while let (folder, depth) = stack.popLast(), walked < DesignProjectTokens.maxWalked, found.count < DesignProjectTokens.maxFiles {
            let entries = ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                                            options: [.skipsHiddenFiles])) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in entries {
                walked += 1
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                // Links are never followed: what a project reads is inside it.
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    if depth < DesignProjectTokens.maxDepth, !DesignProjectTokens.skipped.contains(entry.lastPathComponent) {
                        stack.append((entry, depth + 1))
                    }
                } else if values?.isRegularFile == true, ["css", "scss", "less"].contains(entry.pathExtension.lowercased()),
                          (values?.fileSize ?? 0) <= DesignProjectTokens.maxBytes,
                          let text = try? String(contentsOf: entry, encoding: .utf8) {
                    let path = entry.standardizedFileURL.path
                    guard path.hasPrefix(base) else { continue }
                    let relative = String(path.dropFirst(base.count))
                    let count = DesignSystemCSS.declarations(text, file: relative).count
                    if count > 0 { found.append((relative, count)) }
                }
            }
        }
        return found
    }
}
