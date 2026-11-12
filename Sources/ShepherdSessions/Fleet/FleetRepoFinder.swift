import Foundation
import ShepherdCore

/// Finds a checkout of a repository this Mac already has (slice 4f), so a space the fleet synced binds to it with no "locate folder"
/// step and a dispatch needs no clone. It looks only at places Shepherd already knows: the folders of this Mac's spaces, the main
/// checkout of each thread's worktree, the checkouts the fleet's content index reads and where earlier spaces were bound. It never
/// walks the disk. A checkout is asked for its origin (`FleetRepoKeys.key`) only when its git config changed since the last look.
///
/// Several checkouts of one repository: the one a space on this Mac already uses, else the one touched most recently, and the choice
/// is kept in `repo-choices.json` (which checkout, and why) so it stays the same until something changes.
final class FleetRepoFinder: @unchecked Sendable {
    /// A folder to look at; `isSpace` says one of this Mac's spaces uses it.
    struct Place: Hashable, Sendable {
        var path: String
        var isSpace: Bool
    }

    struct Candidate: Equatable, Sendable {
        var path: String
        var isSpace: Bool
        var modified: Date
    }

    /// Why a checkout was chosen: `space` (a space here already uses it), `recent` (the most recently touched of several) or `only`.
    struct Choice: Codable, Equatable {
        var path: String
        var how: String
        var at: Double
    }

    private struct Seen {
        var stamp: String
        var key: String?
    }

    private let lock = NSLock()
    private let url: URL
    private let clock: @Sendable () -> Date
    private var seen: [String: Seen] = [:]
    private var byKey: [String: [Candidate]] = [:]
    private(set) var choices: [String: Choice]

    init(directory: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        url = directory.appendingPathComponent("repo-choices.json")
        self.clock = clock
        choices = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Choice].self, from: $0) } ?? [:]
    }

    /// The primary checkout `folder` belongs to: itself, or for a linked worktree the checkout it was made from. Nil when it is neither
    /// (not a git folder, a bare repository, a submodule).
    static func checkout(of folder: String) -> String? {
        let path = (folder as NSString).expandingTildeInPath
        let dot = URL(fileURLWithPath: path).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dot.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return path }
        // A linked worktree: `.git` names its own folder, which names the common one (`<main>/.git`).
        guard let text = try? String(contentsOf: dot, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let named = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDir = URL(fileURLWithPath: named, relativeTo: URL(fileURLWithPath: path, isDirectory: true)).standardizedFileURL
        guard let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) else { return nil }
        let shared = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir).standardizedFileURL
        guard shared.lastPathComponent == ".git" else { return nil }
        return shared.deletingLastPathComponent().path
    }

    /// When a checkout was last touched: its HEAD or its index, whichever is newer.
    private static func modified(_ checkout: String) -> Date {
        let dates = ["HEAD", "index"].compactMap { name in
            (try? FileManager.default.attributesOfItem(atPath: checkout + "/.git/" + name))?[.modificationDate] as? Date
        }
        return dates.max() ?? .distantPast
    }

    /// Reads the origin of each place's checkout (git runs only where its config changed) and what is findable by key. Blocking: call
    /// it off the server queue. True when what can be found changed.
    @discardableResult
    func refresh(_ places: [Place]) -> Bool {
        var checkouts: [String: Bool] = [:]
        for place in places {
            guard let main = Self.checkout(of: place.path) else { continue }
            let canonical = PiHome.canonical(main)
            checkouts[canonical] = (checkouts[canonical] ?? false) || (place.isSpace && PiHome.canonical(place.path) == canonical)
        }
        var found: [String: [Candidate]] = [:]
        var fresh: [String: Seen] = [:]
        for (path, isSpace) in checkouts {
            let stamp = FleetRepoKeys.stamp(of: FleetRepoKeys.configFile(folder: path))
            let before = lock.withLock { seen[path] }
            // A checkout with no origin is known by its first commit, so a repository that never had a remote can still be found.
            let key = before?.stamp == stamp ? before?.key : FleetRepoKeys.key(folder: path) ?? FleetRepoKeys.localKey(folder: path)
            fresh[path] = Seen(stamp: stamp, key: key)
            guard let key else { continue }
            found[key, default: []].append(Candidate(path: path, isSpace: isSpace, modified: Self.modified(path)))
        }
        return lock.withLock {
            seen = fresh
            let changed = Self.shape(found) != Self.shape(byKey)
            byKey = found
            return changed
        }
    }

    /// What a refresh is compared by: each key's checkouts, with their dates left out (they move on every commit).
    private static func shape(_ table: [String: [Candidate]]) -> [String: [String]] {
        table.mapValues { $0.map { "\($0.path)|\($0.isSpace)" }.sorted() }
    }

    /// The checkout of `key` this Mac should use, from what the last refresh saw; nil when there is none. Reads memory only.
    func locate(_ key: String) -> Candidate? {
        let candidates = lock.withLock { byKey[key] ?? [] }.filter { FleetDispatch.folderExists($0.path) }
        let ranked = candidates.sorted { a, b in
            if a.isSpace != b.isSpace { return a.isSpace }
            if a.modified != b.modified { return a.modified > b.modified }
            return a.path < b.path
        }
        guard let best = ranked.first else { return nil }
        let how = best.isSpace ? "space" : ranked.count > 1 ? "recent" : "only"
        let now = (clock().timeIntervalSince1970 * 1000).rounded()
        lock.withLock {
            guard choices[key]?.path != best.path || choices[key]?.how != how else { return }
            choices[key] = Choice(path: best.path, how: how, at: now)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(choices) { FleetStore.write(data, to: url) }
        }
        return best
    }
}
