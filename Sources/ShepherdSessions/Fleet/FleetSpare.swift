import CryptoKit
import Darwin
import Foundation
import ShepherdCore

/// Clones files and directories on APFS (`clonefile(2)`): the new name shares the old one's blocks, so a clone is
/// neither a copy nor extra disk, and a directory is one call. It works inside one volume; across volumes (or on a volume
/// that can't) the same step copies, and the measured budget doesn't apply.
enum FleetClone {
    struct Counters: Sendable {
        var clones = 0
        var copies = 0
    }

    /// Clones `source` (a file, a link or a directory) to `destination`, which must not exist. True when it was cloned, false when copied.
    @discardableResult
    static func item(_ source: String, to destination: String) throws -> Bool {
        if clonefile(source, destination, UInt32(CLONE_NOFOLLOW)) == 0 { return true }
        let code = errno
        guard code == ENOTSUP || code == EXDEV else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "clone of \(source) failed: \(String(cString: strerror(code)))"])
        }
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        return false
    }
}

/// The per repo spare (slice 4c): a plain directory (not a git worktree, so it registers nothing in the user's repository
/// and never touches its index or refs) holding the tracked files at the space's base tip, built from the repository's own
/// objects. A dispatch's worktree starts as one `clonefile` of it. It is rebuilt in the background when the base ref moves
/// (no fetch), skipped for a repository over 2 GiB tracked, and skipped when the disk is short.
///
/// A spare that is a little behind the commit a dispatch pins is still right: the receiver writes the files that differ between the
/// two. Building and swapping run off the server queue (blocking); `lock` keeps a clone from reading a tree while it is swapped.
final class FleetSpares: @unchecked Sendable {
    struct Meta: Codable, Equatable {
        var repo: String
        var commit: String
        /// Left alone: too big, or no base ref. Recorded so the check isn't repeated until the base moves.
        var skipped: String?
        var files: Int
        var bytes: UInt64
    }

    /// What a dispatch clones.
    struct Ready: Sendable {
        var tree: String
        var commit: String
    }

    /// The tracked files of a spare's commit, parsed once: in git's order (an index file's), and by path. A dispatch that starts from this
    /// commit, or from one a few files away, builds its own listing from this without asking git for the whole tree.
    struct Listing: Sendable {
        var commit: String
        var ordered: [(String, FleetTreeEntry)]
        var tree: [String: FleetTreeEntry]
    }

    static let maxTrackedBytes: UInt64 = 2 << 30

    let directory: URL
    private let lock = NSLock()
    private var building: Set<String> = []
    /// Tests: how many times a spare was built.
    private(set) var builds = 0
    private let listingLock = NSLock()
    private var listings: [String: Listing] = [:]

    init(directory: URL) { self.directory = directory }

    private func folder(for repo: String) -> URL {
        let name = SHA256.hash(data: Data(repo.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    private func meta(of repo: String) -> Meta? {
        (try? Data(contentsOf: folder(for: repo).appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
    }

    /// The commit the repository's base ref is at (a local ref; nothing is fetched): the space's base where it has one, else origin's default branch.
    static func baseCommit(repo: String, base: String?) -> String? {
        var refs: [String] = []
        if let base = base?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty, !base.hasPrefix("-") { refs.append(base) }
        if let branch = GitWorktree.defaultBranch(repo: repo, network: false) { refs.append("origin/\(branch)") }
        for ref in refs {
            if let found = FleetDispatchGit.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: repo), found.status == 0, FleetDispatchGit.isCommit(found.output) {
                return found.output
            }
        }
        return nil
    }

    /// The spare as it stands (built, or not), for a dispatch: nothing is built here.
    func current(repo: String) -> Ready? {
        guard let meta = meta(of: repo), meta.skipped == nil else { return nil }
        let tree = folder(for: repo).appendingPathComponent("tree").path
        return FileManager.default.fileExists(atPath: tree) ? Ready(tree: tree, commit: meta.commit) : nil
    }

    /// The spare's commit as a parsed listing, when this Mac has made one for the spare as it stands.
    func listing(repo: String, commit: String) -> Listing? {
        listingLock.withLock { listings[repo].flatMap { $0.commit == commit ? $0 : nil } }
    }

    /// Lists the spare's commit once (a git call), so the next dispatch needs none. Blocking; call off the server queue.
    func warmListing(repo: String) {
        guard let ready = current(repo: repo), listing(repo: repo, commit: ready.commit) == nil,
              let out = FleetDispatchGit.run(["ls-tree", "-r", "-z", ready.commit], in: repo, timeout: 60), out.status == 0 else { return }
        let ordered = FleetSnapshotSender.parseOrdered(tree: out.output)
        let listing = Listing(commit: ready.commit, ordered: ordered, tree: Dictionary(ordered) { first, _ in first })
        listingLock.withLock { listings[repo] = listing }
    }

    /// Runs `body` while no swap can happen; the spare's tree is stable inside it.
    func withTree<T>(repo: String, _ body: (Ready) throws -> T) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let ready = current(repo: repo) else { return nil }
        return try body(ready)
    }

    /// Brings the spare of `repo` to the base tip: nothing when it is there, a build otherwise. Blocking; call off the server queue.
    /// Returns what the spare is now.
    @discardableResult
    func refresh(repo: String, base: String?) -> Ready? {
        guard let commit = Self.baseCommit(repo: repo, base: base) else { return current(repo: repo) }
        if let have = meta(of: repo), have.commit == commit {
            warmListing(repo: repo)
            return current(repo: repo)
        }
        lock.lock()
        let started = building.insert(repo).inserted
        lock.unlock()
        guard started else { return current(repo: repo) }
        defer { lock.lock(); building.remove(repo); lock.unlock() }
        build(repo: repo, commit: commit)
        warmListing(repo: repo)
        return current(repo: repo)
    }

    private func build(repo: String, commit: String) {
        let manager = FileManager.default
        let home = folder(for: repo)
        do { try manager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return }
        // Size first, from the tree's listing: no content is read.
        guard let listing = FleetDispatchGit.run(["ls-tree", "-r", "-l", "-z", commit], in: repo, timeout: 60), listing.status == 0 else { return }
        var files = 0
        var bytes: UInt64 = 0
        for line in listing.output.split(separator: "\0") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[..<tab].split(separator: " ", omittingEmptySubsequences: true)
            if fields.count == 4, fields[1] == "blob" { files += 1; bytes += UInt64(fields[3]) ?? 0 }
        }
        func skip(_ why: String) {
            write(Meta(repo: repo, commit: commit, skipped: why, files: files, bytes: bytes), in: home)
            removeTree(at: home.appendingPathComponent("tree"))
        }
        if bytes > Self.maxTrackedBytes { return skip("tooBig") }
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        guard UInt64(max(0, free)) > bytes * 2 + (256 << 20) else { return }
        let fresh = home.appendingPathComponent("tree.new", isDirectory: true)
        removeTree(at: fresh)
        let index = home.appendingPathComponent("index.tmp").path
        defer { try? manager.removeItem(atPath: index) }
        do { try manager.createDirectory(at: fresh, withIntermediateDirectories: true) } catch { return }
        // The tracked files of `commit`, from local objects: a private index file and a work tree that is this directory.
        let environment = ["GIT_INDEX_FILE": index]
        guard let read = FleetDispatchGit.run(["--work-tree=\(fresh.path)", "read-tree", commit], in: repo, timeout: 120, environment: environment), read.status == 0,
              let out = FleetDispatchGit.run(["--work-tree=\(fresh.path)", "checkout-index", "-a", "-f"], in: repo, timeout: 600, environment: environment), out.status == 0 else {
            removeTree(at: fresh)
            return
        }
        // Swapped in under the lock, so a clone never reads half a rename.
        let tree = home.appendingPathComponent("tree", isDirectory: true)
        let old = home.appendingPathComponent("tree.old", isDirectory: true)
        lock.lock()
        removeTree(at: old)
        if manager.fileExists(atPath: tree.path) { try? manager.moveItem(at: tree, to: old) }
        let moved = (try? manager.moveItem(at: fresh, to: tree)) != nil
        if moved { write(Meta(repo: repo, commit: commit, skipped: nil, files: files, bytes: bytes), in: home); builds += 1 }
        lock.unlock()
        removeTree(at: old)
        if !moved { removeTree(at: fresh) }
    }

    private func write(_ meta: Meta, in home: URL) {
        if let data = try? JSONEncoder().encode(meta) { FleetStore.write(data, to: home.appendingPathComponent("meta.json")) }
    }

    private func removeTree(at url: URL) { try? FileManager.default.removeItem(at: url) }
}
