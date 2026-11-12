import CryptoKit
import Darwin
import Foundation
import os
import ShepherdCore
import ShepherdProtocol

/// The sending side of a dispatch's snapshot (slice 4c): what the checkout holds beyond its commit, worked out from the warm content
/// index (no tree walk and no hashing but of the few files the index hadn't seen), the contents the target lacks, the bundle of
/// unpushed commits, and the numbers the cap and the digest are made of. Blocking: call it off the server queue.
struct FleetSnapshotSender {
    /// A snapshot ready to send.
    struct Built {
        var id: UUID
        var plan: FleetSnapshotPlan
        var header: FleetSnapshotHeader
        var parts: [FleetSnapshotPart]
        /// The checkout the contents are read from.
        var root: String
        var bundle: (ref: FleetBlobRef, url: URL)?
        var warning: Bool
        /// Milliseconds since `build` began at the end of each step, in order (the budget test and the log).
        var phases: [String] = []
        /// The git commands the build ran (the first word of each): the listing of the commit's tree unless this Mac had it, the bundle.
        var git: [String] = []
    }

    enum Failure: Error, Equatable {
        case notARepository
        /// The index isn't built (a large checkout still on its first scan, or one too big to index).
        case notIndexed(String)
        /// Above the cap: the biggest contents, as `path:bytes`.
        case tooLarge(bytes: UInt64, biggest: [String])
        case git(String)
    }

    /// Where the contents the target lacks are read from, by hash: the checkout's files and the bundle.
    var index: FleetContentIndex
    var root: String
    var commit: String
    /// What the target holds of the repository.
    var target: FleetManifest?
    var directory: URL
    /// Where a snapshot warns and where it is refused (tests lower them).
    var warnAbove = FleetSnapshotCap.warnAbove
    var refuseAbove = FleetSnapshotCap.refuseAbove

    /// Works out the snapshot. `unpushed` says the checkout has commits no remote ref holds; `wholeRepository` says the bundle is the
    /// repository itself (every ref), for a target that has no checkout and couldn't clone it from origin.
    func build(id: UUID, unpushed: Bool, wholeRepository: Bool = false) throws -> Built {
        let began = ContinuousClock.now
        var phases: [String] = []
        var git: [String] = []
        func mark(_ name: String) { phases.append("\(name) \(Int((ContinuousClock.now - began) / .milliseconds(1)))") }
        // The commit's tree: a commit never changes, so one listed before is kept, and one being listed (the dispatch asked for it when it
        // pinned the commit) is waited for. A listing this build has to make runs while the index is brought up to date below, not after.
        let listing = OSAllocatedUnfairLock<FleetTrackedTrees.Tree?>(initialState: nil)
        let ranGit = OSAllocatedUnfairLock(initialState: false)
        let listed = DispatchGroup()
        listed.enter()
        let (listedRoot, listedCommit) = (root, commit)
        DispatchQueue.global(qos: .userInitiated).async {
            if let loaded = FleetTrackedTrees.shared.load(root: listedRoot, commit: listedCommit) {
                listing.withLock { $0 = loaded.tree }
                ranGit.withLock { $0 = loaded.ranGit }
            }
            listed.leave()
        }
        // Whatever the system already has for this root reaches the index first, so a file written a moment ago is in it; then
        // the check below. The check that the directory hashes still agree with the entries reads nothing and runs beside the rest.
        guard index.stateNow == .ready else { listed.wait(); throw Failure.notIndexed(index.stateNow.rawValue) }
        index.settle()
        mark("settle")
        // Then every file and directory the index holds is looked at against the disk, so an edit the system hasn't reported yet is still in it.
        index.queue.sync { _ = index.catchUp() }
        mark("catch-up")
        guard let view = index.queue.sync(execute: { index.snapshotView() }) else {
            listed.wait()
            throw Failure.notIndexed(index.stateNow.rawValue)
        }
        let agree = OSAllocatedUnfairLock(initialState: true)
        let agreed = DispatchGroup()
        if !view.treeChecked {
            agreed.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let consistent = FleetContentIndex.treeAgrees(entries: view.entries, tree: view.tree)
                agree.withLock { $0 = consistent }
                if consistent { index.queue.async { index.treeAgreed(at: view.mutations) } }
                agreed.leave()
            }
        }
        listed.wait()
        if ranGit.withLock({ $0 }) { git.append("ls-tree") }
        mark("ls-tree")
        guard let tracked = listing.withLock({ $0 }) else { agreed.wait(); throw Failure.git("ls-tree") }
        let root = self.root
        let plan = FleetSnapshotPlan.make(
            commit: commit, tracked: tracked.entries, entries: view.entries, tree: view.tree, target: target,
            goneFromDisk: { var status = stat(); return lstat(root + "/" + $0, &status) != 0 },
            unindexedHash: { path in FleetSnapshotBlobs.hash(of: URL(fileURLWithPath: root + "/" + path)) ?? FleetHash(a: 0, b: 0, c: 0, d: 0) },
            trackedDirectories: tracked.directories)
        mark("plan")
        agreed.wait()
        // A tree that disagrees with its entries is drift: the index looks again, and this dispatch doesn't go on what it held.
        guard agree.withLock({ $0 }) else {
            index.queue.sync { _ = index.verify(sample: 64) }
            throw Failure.notIndexed(index.stateNow.rawValue)
        }
        mark("tree")
        if let problem = plan.manifest.problem { throw Failure.git("manifest: \(problem)") }
        var bundle: (FleetBlobRef, URL)?
        if wholeRepository || unpushed { bundle = try makeBundle(id: id, wholeRepository: wholeRepository); git.append("bundle") }
        let total = plan.bytes + (bundle?.0.size ?? 0)
        let verdict = FleetSnapshotCap.verdict(bytes: total, warnAbove: warnAbove, refuseAbove: refuseAbove)
        if verdict == .refuse {
            throw Failure.tooLarge(bytes: total, biggest: plan.biggest.map { "\($0.path):\($0.bytes)" })
        }
        let parts = Self.parts(of: plan.manifest)
        let header = FleetSnapshotHeader(
            commit: commit, rootHash: plan.manifest.rootHash, digest: plan.manifest.digest, files: plan.manifest.files.count,
            directories: plan.manifest.directories.count, deletions: plan.manifest.deletions.count, parts: parts.count,
            fileCount: plan.fileCount, bytes: total, bundle: bundle?.0, repoBundle: wholeRepository)
        mark("parts")
        return Built(id: id, plan: plan, header: header, parts: parts, root: root, bundle: bundle, warning: verdict == .warn, phases: phases, git: git)
    }

    /// `git ls-tree -r -z`: `<mode> <type> <id>\t<path>\0`.
    static func parse(tree output: String) -> [String: FleetTreeEntry] {
        Dictionary(parseOrdered(tree: output)) { first, _ in first }
    }

    /// The same, in git's own order (which is the order of an index file).
    static func parseOrdered(tree output: String) -> [(String, FleetTreeEntry)] {
        var out: [(String, FleetTreeEntry)] = []
        out.reserveCapacity(output.utf8.count / 64)
        for record in output.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, let id = FleetGitBlobID(hex: String(fields[2])) else { continue }
            let path = String(record[record.index(after: tab)...])
            switch fields[0] {
            case "100644": out.append((path, FleetTreeEntry(kind: .file, gitID: id)))
            case "100755": out.append((path, FleetTreeEntry(kind: .executable, gitID: id)))
            case "120000": out.append((path, FleetTreeEntry(kind: .symlink, gitID: id)))
            case "160000": out.append((path, FleetTreeEntry(kind: .file, gitID: id, isSubmodule: true)))
            default: continue
            }
        }
        return out
    }

    /// The manifest cut into parts a frame can carry: files, then directories, then deletions.
    static func parts(of manifest: FleetSnapshotManifest) -> [FleetSnapshotPart] {
        let size = FleetSnapshotTransfer.entriesPerPart
        var parts: [FleetSnapshotPart] = []
        func next() -> Int { parts.count }
        for chunk in stride(from: 0, to: manifest.files.count, by: size) {
            parts.append(FleetSnapshotPart(index: next(), files: Array(manifest.files[chunk..<min(chunk + size, manifest.files.count)])))
        }
        for chunk in stride(from: 0, to: manifest.directories.count, by: size) {
            parts.append(FleetSnapshotPart(index: next(), directories: Array(manifest.directories[chunk..<min(chunk + size, manifest.directories.count)])))
        }
        for chunk in stride(from: 0, to: manifest.deletions.count, by: size) {
            parts.append(FleetSnapshotPart(index: next(), deletions: Array(manifest.deletions[chunk..<min(chunk + size, manifest.deletions.count)])))
        }
        return parts
    }

    /// The repository and nothing else, for a dispatch that carries no edits (Settings ▸ Fleet ▸ Uncommitted changes leaves them behind) to a
    /// Mac that has no checkout and couldn't clone one: a bundle of every ref, under the cap. It needs no index.
    static func repositoryOnly(id: UUID, root: String, commit: String, rev: String? = nil, directory: URL, warnAbove: UInt64 = FleetSnapshotCap.warnAbove,
                               refuseAbove: UInt64 = FleetSnapshotCap.refuseAbove) throws -> Built {
        let zero = FleetHash(a: 0, b: 0, c: 0, d: 0)
        // With `rev`: only what no remote ref holds up to it (a Mac that has the repository lacks just that); without: every ref.
        let bundle = try makeBundle(id: id, root: root, directory: directory, wholeRepository: rev == nil, rev: rev ?? "HEAD")
        let verdict = FleetSnapshotCap.verdict(bytes: bundle.0.size, warnAbove: warnAbove, refuseAbove: refuseAbove)
        if verdict == .refuse { throw Failure.tooLarge(bytes: bundle.0.size, biggest: ["the repository's history:\(bundle.0.size)"]) }
        let header = FleetSnapshotHeader(commit: commit, rootHash: zero, digest: zero, files: 0, directories: 0, deletions: 0, parts: 0, fileCount: 0,
                                         bytes: bundle.0.size, bundle: bundle.0, repoBundle: rev == nil, repoOnly: true)
        return Built(id: id, plan: .empty(commit: commit), header: header, parts: [], root: root, bundle: bundle, warning: verdict == .warn, git: ["bundle"])
    }

    private func makeBundle(id: UUID, wholeRepository: Bool = false) throws -> (FleetBlobRef, URL) {
        try Self.makeBundle(id: id, root: root, directory: directory, wholeRepository: wholeRepository)
    }

    /// `git bundle` of what no remote ref holds (or, for `wholeRepository`, of every ref), written under the fleet's own directory.
    private static func makeBundle(id: UUID, root: String, directory: URL, wholeRepository: Bool, rev: String = "HEAD") throws -> (FleetBlobRef, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(id.uuidString.lowercased()).bundle")
        try? FileManager.default.removeItem(at: url)
        let arguments = wholeRepository ? ["bundle", "create", url.path, "--all"] : ["bundle", "create", url.path, rev, "--not", "--remotes"]
        guard let made = FleetDispatchGit.run(arguments, in: root, timeout: wholeRepository ? 3_600 : 300), made.status == 0,
              let hash = FleetSnapshotBlobs.hash(of: url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else { throw Failure.git("bundle") }
        return (FleetBlobRef(hash: hash, size: size), url)
    }
}

/// Reads a content a snapshot lacks out of a checkout (or the bundle), a chunk at a time, checking it against its hash as it goes.
struct FleetSnapshotReader {
    enum Failure: Error { case changed(String), unreadable(String) }

    /// The chunks of the file at `path`, ending with the one that completes it; throws `changed` when what was read isn't `hash`.
    /// A link is its target text.
    static func chunks(path: String, hash: FleetHash, link: Bool, _ emit: (FleetBlobChunk) async throws -> Void) async throws {
        if link {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(path, &buffer, Int(PATH_MAX))
            guard count >= 0 else { throw Failure.unreadable(path) }
            let data = Data(buffer.prefix(count).map { UInt8(bitPattern: $0) })
            guard FleetHash(of: data) == hash else { throw Failure.changed(path) }
            try await emit(FleetBlobChunk(hash: hash, size: UInt64(data.count), offset: 0, data: data))
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.unreadable(path) }
        defer { try? handle.close() }
        var status = stat()
        guard fstat(handle.fileDescriptor, &status) == 0 else { throw Failure.unreadable(path) }
        let size = UInt64(status.st_size)
        var offset: UInt64 = 0
        if size == 0 { try await emit(FleetBlobChunk(hash: hash, size: 0, offset: 0, data: Data())); return }
        while offset < size {
            guard let data = try? handle.read(upToCount: FleetSnapshotTransfer.chunkBytes), !data.isEmpty else { throw Failure.changed(path) }
            try await emit(FleetBlobChunk(hash: hash, size: size, offset: offset, data: data))
            offset += UInt64(data.count)
        }
    }
}

/// The trees of commits this Mac has listed lately, by checkout and commit: a commit never changes, so the second dispatch from one
/// doesn't list it again. A few are kept (a tree of a large repository is tens of megabytes).
final class FleetTrackedTrees: @unchecked Sendable {
    /// A commit's files, and every directory above a file that isn't a submodule (what a dispatch needs to know a tracked directory).
    struct Tree: Sendable {
        var entries: [String: FleetTreeEntry]
        var directories: Set<String>

        init(_ entries: [String: FleetTreeEntry]) {
            self.entries = entries
            var directories = Set<String>()
            for (path, entry) in entries where !entry.isSubmodule {
                var end = path.startIndex
                while let slash = path[end...].firstIndex(of: "/") {
                    directories.insert(String(path[..<slash]))
                    end = path.index(after: slash)
                }
            }
            self.directories = directories
        }
    }

    static let shared = FleetTrackedTrees()
    private static let limit = 4
    private let lock = NSLock()
    private var kept: [(key: String, tree: Tree)] = []
    private var listing: [String: DispatchGroup] = [:]

    private func cached(_ key: String) -> Tree? {
        guard let position = kept.firstIndex(where: { $0.key == key }) else { return nil }
        let found = kept.remove(at: position)
        kept.append(found)
        return found.tree
    }

    /// The tree of `commit` in `root`: kept, being listed by someone else (waited for), or listed here (`ranGit`). Blocking. Nil when git can't list it.
    func load(root: String, commit: String) -> (tree: Tree, ranGit: Bool)? {
        let key = root + "\0" + commit
        lock.lock()
        if let hit = cached(key) { lock.unlock(); return (hit, false) }
        if let running = listing[key] {
            lock.unlock()
            running.wait()
            return lock.withLock { cached(key) }.map { ($0, false) }
        }
        let group = DispatchGroup()
        group.enter()
        listing[key] = group
        lock.unlock()
        var parsed: Tree?
        if let out = FleetDispatchGit.run(["ls-tree", "-r", "-z", commit], in: root, timeout: 60), out.status == 0 {
            parsed = Tree(FleetSnapshotSender.parse(tree: out.output))
        }
        lock.withLock {
            if let parsed {
                kept.removeAll { $0.key == key }
                kept.append((key, parsed))
                if kept.count > Self.limit { kept.removeFirst(kept.count - Self.limit) }
            }
            listing[key] = nil
        }
        group.leave()
        return parsed.map { ($0, true) }
    }

    /// Starts listing `commit` beside whatever comes next (a dispatch that has pinned a commit is about to ask for it).
    func prefetch(root: String, commit: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.load(root: root, commit: commit) }
    }
}
