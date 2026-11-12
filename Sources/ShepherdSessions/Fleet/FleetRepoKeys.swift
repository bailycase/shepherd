import Foundation
import ShepherdCore

/// Works out `Space.repoKey` (`CanonicalRepoKey`) from each space's checkout, and notices when the
/// origin changes. A checkout is looked at again only when its git config (the file that holds the
/// remotes) is not as it was last time, by size and modification time, so a pass over many spaces is a
/// few `stat`s; git runs only for a space whose config changed. The last look is kept in
/// `fleet/repo-stamps.json`, so an origin changed while the host was down is still noticed.
final class FleetRepoKeys: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var stamps: [String: String]

    init(directory: URL) {
        url = directory.appendingPathComponent("repo-stamps.json")
        stamps = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// The git config that holds a checkout's remotes: its own for a primary checkout, the main
    /// checkout's for a linked worktree. Nil when the folder isn't a git checkout.
    static func configFile(folder: String) -> URL? {
        let dot = URL(fileURLWithPath: folder).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dot.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dot.appendingPathComponent("config") }
        // A linked worktree: `.git` is a file naming its own folder, which names the common one.
        guard let text = try? String(contentsOf: dot, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let named = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = URL(fileURLWithPath: named, relativeTo: URL(fileURLWithPath: folder, isDirectory: true)).standardizedFileURL
        if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
            let relative = common.trimmingCharacters(in: .whitespacesAndNewlines)
            return URL(fileURLWithPath: relative, relativeTo: gitDir).standardizedFileURL.appendingPathComponent("config")
        }
        return gitDir.appendingPathComponent("config")
    }

    static func stamp(of config: URL?) -> String {
        guard let config, let attributes = try? FileManager.default.attributesOfItem(atPath: config.path),
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber else { return "none" }
        return "\(Int64(modified.timeIntervalSince1970 * 1000)):\(size)"
    }

    /// The key of the checkout at `folder`: from its origin's push URL (`git remote get-url --push`,
    /// which applies `pushurl` and `insteadOf` as git does), nil when there is none.
    static func key(folder: String) -> String? {
        guard let result = try? BoundedCommand.run(["/usr/bin/git", "-C", folder, "remote", "get-url", "--push", "origin"],
                                                   environment: ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }, timeout: 15),
              result.status == 0 else { return nil }
        return CanonicalRepoKey(remote: String(decoding: result.output, as: UTF8.self))?.value
    }

    /// A checkout with no origin, by its first commit (`CanonicalRepoKey.local`); nil when there is none to name it (no commits yet).
    static func localKey(folder: String) -> String? {
        guard let result = try? BoundedCommand.run(["/usr/bin/git", "-C", folder, "rev-list", "--max-parents=0", "HEAD"],
                                                   environment: ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }, timeout: 15),
              result.status == 0 else { return nil }
        // A repository can have several root commits: the smallest names it, the same on every Mac.
        let roots = String(decoding: result.output, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
        return roots.first.flatMap { CanonicalRepoKey.local(rootCommit: $0) }
    }

    /// What changed: each space whose checkout's config is not as it was when last looked at, with
    /// its key now (nil: none). A space never looked at that already has a key (one a fleet gave it)
    /// keeps it. Blocks on git for the spaces that changed: call it off the server queue.
    func changes(for spaces: [(id: SpaceID, path: String, key: String?)]) -> [SpaceID: String?] {
        var changes: [SpaceID: String?] = [:]
        var saved = false
        for space in spaces {
            let path = (space.path as NSString).expandingTildeInPath
            let stamp = Self.stamp(of: Self.configFile(folder: path))
            let before = lock.withLock { stamps[space.id.rawValue] }
            guard before != stamp else { continue }
            // A checkout with no origin (or one that is a path on a disk) is named by its first commit, so it is still a repository the fleet can
            // find and send.
            let key = stamp == "none" ? nil : Self.key(folder: path) ?? Self.localKey(folder: path)
            lock.withLock { stamps[space.id.rawValue] = stamp }
            saved = true
            if before == nil, space.key != nil { continue }
            // A space a dispatch made from a repository with no origin keeps the key that names it.
            if key == nil, let kept = space.key, CanonicalRepoKey.isLocal(kept) { continue }
            if key != space.key { changes[space.id] = key }
        }
        if saved { save() }
        return changes
    }

    /// The config files to watch, so a changed origin is noticed when it happens.
    static func watchedFiles(of spaces: [Space]) -> [URL] {
        spaces.compactMap { configFile(folder: ($0.path as NSString).expandingTildeInPath) }
    }

    private func save() {
        let snapshot = lock.withLock { stamps }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(snapshot) { FleetStore.write(data, to: url) }
    }
}
