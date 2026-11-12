import CryptoKit
import Darwin
import Foundation
import os
import ShepherdCore
import ShepherdProtocol

private typealias FileStatus = stat

/// The receiving side of a dispatch's snapshot (slice 4c): the fresh worktree a thread will work in, built from contents the Mac
/// already holds, and checked against the sender's status digest before anything starts in it.
///
/// What it writes in the user's repository (docs/rules.md, "Only these paths mutate repositories"): objects fetched from origin or
/// from the sender's bundle, the one `refs/fleet/<dispatchID>` ref the bundle lands in, and the worktree itself (`git worktree add
/// --no-checkout`, then its files and index). Never the user's existing checkout. Any failure removes the worktree, its branch
/// and the ref, so a dispatch that didn't verify leaves nothing behind.
///
/// Steps: the commit is made present; the worktree is added with no checkout; the spare's files are cloned in with one `clonefile`
/// (or, with no spare, git checks the tree out); the files that differ between the spare's commit and the pinned one are written; the
/// snapshot's directories and files are cloned from where this Mac's index (or its received contents) holds them, deletions removed;
/// the index file is written from the tree and the clones' stat data; and the digest is recomputed from what is there.
struct FleetSnapshotApply {
    struct Input {
        var id: UUID
        /// The space's checkout: the repository the worktree belongs to.
        var repo: String
        /// The space's own base ref, for its spare.
        var base: String?
        var branch: String
        var header: FleetSnapshotHeader
        var manifest: FleetSnapshotManifest
        var blobs: FleetSnapshotBlobs
        var spares: FleetSpares
        /// Every content index this Mac keeps, to find files and directories it already holds.
        var indexes: [FleetContentIndex]
        var began: ContinuousClock.Instant
        /// What the arrival logged before the build began (milliseconds since the create), put first in `Stats.phases`.
        var prelude: [String] = []
    }

    /// What the build did, for the budget test and the log: counts, never content.
    struct Stats: Equatable, Sendable {
        var clones = 0
        var copies = 0
        /// Files written by hand: the ones the sent contents and the commit difference made.
        var filesWritten = 0
        var bytesWritten: UInt64 = 0
        /// The first word of each git command run, in order.
        var git: [String] = []
        var usedSpare = false
        /// Milliseconds since the create arrived at the end of each step, in order.
        var phases: [String] = []
        /// Files and directories of the manifest that came from this Mac's own checkouts.
        var heldLocally = 0
        var receivedFiles = 0
    }

    struct Applied {
        var path: String
        var stats: Stats
        var fileMillis: Int
        /// The sender's bundle was fetched into `refs/fleet/<dispatchID>`.
        var madeRef: Bool
    }

    struct Failure: Error, Equatable {
        var code: String
        var detail: String?
    }

    var input: Input
    private var stats = Stats()

    init(_ input: Input) {
        self.input = input
        stats.phases = input.prelude
    }

    /// Builds and verifies the worktree. Blocking. On failure everything made is removed.
    mutating func run() -> Result<Applied, Failure> {
        var created = Created()
        do {
            let path = try build(&created)
            let millis = Int((ContinuousClock.now - input.began) / .milliseconds(1))
            return .success(Applied(path: path, stats: stats, fileMillis: millis, madeRef: created.ref))
        } catch let failure as Failure {
            cleanup(created)
            return .failure(failure)
        } catch {
            cleanup(created)
            return .failure(Failure(code: FleetDispatchCode.snapshotFailed, detail: String(String(describing: error).prefix(200))))
        }
    }

    private struct Created {
        var worktree: String?
        /// The folder the files are laid out in while git makes the worktree; gone once it has taken the worktree's place.
        var staging: String?
        var ref: Bool = false
    }

    private mutating func git(_ arguments: [String], in directory: String? = nil, timeout: TimeInterval = 60, environment: [String: String] = [:]) -> (status: Int32, output: String)? {
        stats.git.append(arguments.first(where: { !$0.hasPrefix("-") }) ?? "")
        return FleetDispatchGit.run(arguments, in: directory ?? input.repo, timeout: timeout, environment: environment)
    }

    private func cleanup(_ created: Created) {
        if let staging = created.staging { try? FileManager.default.removeItem(atPath: staging) }
        Self.discard(repo: input.repo, worktree: created.worktree, branch: input.branch, ref: created.ref ? input.id : nil)
    }

    /// Takes away what a build made: the worktree, its branch and the fleet ref.
    static func discard(repo: String, worktree: String?, branch: String, ref: UUID?) {
        if let worktree {
            _ = FleetDispatchGit.run(["worktree", "remove", "--force", worktree], in: repo, timeout: 60)
            try? FileManager.default.removeItem(atPath: worktree)
            _ = FleetDispatchGit.run(["worktree", "prune"], in: repo)
            _ = FleetDispatchGit.run(["branch", "-D", branch], in: repo)
        }
        if let ref { _ = FleetDispatchGit.run(["update-ref", "-d", "refs/fleet/\(ref.uuidString.lowercased())"], in: repo) }
    }

    // MARK: Build

    private mutating func mark(_ name: String) {
        stats.phases.append("\(name) \(Int((ContinuousClock.now - input.began) / .milliseconds(1)))")
    }

    /// What the git side of a build gives back: the commit's tree listed and (with a spare) what differs from the spare's commit.
    private struct GitSide: Sendable {
        var listing: (status: Int32, output: String)?
        var difference: (status: Int32, output: String)?
    }

    private mutating func build(_ created: inout Created) throws -> String {
        let commit = input.manifest.commit
        mark("start")
        let destination = GitWorktree.destination(repo: input.repo, branch: input.branch)
        let spare = input.spares.refresh(ifBuilt: PiHome.canonical(input.repo))
        // With a spare the files are laid out in a sibling folder, and the folder takes the worktree's place at the end (so a worktree
        // that fails its digest never held the files).
        let work = spare == nil ? destination : destination + ".fleet-stage"
        let repo = input.repo
        // The commit's tree is listed and (with a spare) the difference from the spare's commit taken at once, with the spare's files
        // cloned beside them: git processes and a clone that don't need each other. A commit this repository lacks fails the git
        // calls, and is made present (origin, then the bundle) before they are tried again.
        func gitSide() -> GitSide {
            let group = DispatchGroup()
            let side = OSAllocatedUnfairLock(initialState: GitSide())
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let listing = FleetDispatchGit.run(["ls-tree", "-r", "-z", "\(commit)^{commit}"], in: repo, timeout: 60)
                side.withLock { $0.listing = listing }
                group.leave()
            }
            if let spare, spare.commit != commit {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let difference = FleetDispatchGit.run(["diff-tree", "-r", "-z", "--no-renames", "--raw", spare.commit, commit], in: repo, timeout: 60)
                    side.withLock { $0.difference = difference }
                    group.leave()
                }
            }
            group.wait()
            return side.withLock { $0 }
        }
        // The spare's files, cloned in one call while git works.
        let cloned = OSAllocatedUnfairLock<Result<Bool?, Error>?>(initialState: nil)
        let cloneGroup = DispatchGroup()
        if spare != nil {
            created.staging = work
            // The folder the worktree goes in may not exist yet.
            try? FileManager.default.createDirectory(atPath: (work as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            cloneGroup.enter()
            let (spares, canonical) = (input.spares, PiHome.canonical(input.repo))
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try spares.withTree(repo: canonical) { ready in try FleetClone.item(ready.tree, to: work) } }
                cloned.withLock { $0 = result }
                cloneGroup.leave()
            }
        }
        func complete(_ side: GitSide) -> Bool { side.listing?.status == 0 && (spare == nil || spare?.commit == commit || side.difference?.status == 0) }
        stats.git += ["ls-tree"] + (spare.map { $0.commit != commit ? ["diff-tree"] : [] } ?? [])
        var side = gitSide()
        if !complete(side) {
            try makeCommitPresent(commit, created: &created)
            mark("commit")
            stats.git += ["ls-tree"] + (spare.map { $0.commit != commit ? ["diff-tree"] : [] } ?? [])
            side = gitSide()
        }
        guard let listing = side.listing, listing.status == 0 else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "ls-tree") }
        // The worktree: written directly where this repository allows it (git's own `worktree add` is the slowest step of a warm
        // dispatch), by git otherwise. Only once the commit is known to be here, so no branch ever points at a missing object.
        if !FleetFastWorktree.add(repo: repo, branch: input.branch, commit: commit, destination: destination) {
            stats.git.append("worktree")
            do { _ = try GitWorktree.add(repo: repo, branch: input.branch, from: commit, checkout: false) } catch {
                throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "worktree: " + String(String(describing: error).prefix(160)))
            }
        }
        created.worktree = destination
        mark("worktree")
        let ordered = FleetSnapshotSender.parseOrdered(tree: listing.output)
        let tree = Dictionary(ordered) { first, _ in first }
        mark("ls-tree")
        var touched = Set<String>()
        // The files of the commit's tree.
        if let spare {
            cloneGroup.wait()
            let outcome = cloned.withLock { $0 }
            guard case .success(let wasCloned?)? = outcome else {
                if case .failure(let error)? = outcome { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: String(String(describing: error).prefix(160))) }
                throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "the spare went away")
            }
            if wasCloned { stats.clones += 1 } else { stats.copies += 1 }
            stats.usedSpare = true
            if spare.commit != commit {
                guard let difference = side.difference, difference.status == 0 else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "diff-tree") }
                try writeDifference(difference.output, into: work, tree: tree, touched: &touched)
            }
        } else {
            guard let out = git(["read-tree", "--reset", "-u", commit], in: destination, timeout: 600), out.status == 0 else {
                throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "checkout")
            }
        }
        mark("tree")
        try applySnapshot(into: work, touched: &touched)
        mark("snapshot")
        if stats.usedSpare { try writeIndex(of: work, worktree: destination, ordered: ordered, touched: touched) }
        mark("index")
        try verify(destination: work, tree: tree)
        mark("verify")
        if work != destination { try swapIn(work, for: destination) }
        mark("swap")
        created.staging = nil
        return destination
    }

    /// The laid out folder takes the worktree's place: the `.git` file moves into it, the empty folder git made goes, the folder is renamed.
    private func swapIn(_ work: String, for destination: String) throws {
        let manager = FileManager.default
        try manager.moveItem(atPath: destination + "/.git", toPath: work + "/.git")
        try manager.removeItem(atPath: destination)
        try manager.moveItem(atPath: work, toPath: destination)
    }

    /// The pinned commit is here, from origin or from the sender's bundle; the bundle's objects land under the one ref.
    private mutating func makeCommitPresent(_ commit: String, created: inout Created) throws {
        func has() -> Bool { FleetDispatchGit.run(["cat-file", "-e", "\(commit)^{commit}"], in: input.repo)?.status == 0 }
        if has() { return }
        _ = git(["fetch", "--quiet", "origin"], timeout: 120)
        if has() { return }
        if let bundle = input.header.bundle, input.blobs.has(bundle.hash) {
            let ref = "refs/fleet/\(input.id.uuidString.lowercased())"
            let fetched = git(["fetch", "--quiet", input.blobs.url(bundle.hash).path, "HEAD:\(ref)"], timeout: 300)
            created.ref = fetched?.status == 0
            if has() { return }
        }
        throw Failure(code: FleetDispatchCode.commitUnreachable, detail: nil)
    }

    // MARK: The commit's tree

    /// The paths that differ between the spare's commit and the pinned one (`diff-tree`'s output) are written from the repository's own objects.
    private mutating func writeDifference(_ raw: String, into destination: String, tree: [String: FleetTreeEntry], touched: inout Set<String>) throws {
        let manager = FileManager.default
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [(path: String, deleted: Bool)] = []
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index].split(separator: " ").last.map(String.init) ?? ""
            changes.append((fields[index + 1], status.hasPrefix("D")))
            index += 2
        }
        let wanted = changes.filter { !$0.deleted }.compactMap { tree[$0.path] }.filter { !$0.isSubmodule }.map(\.gitID.hex)
        let contents = try batch(wanted)
        for change in changes {
            let path = destination + "/" + change.path
            if FleetSnapshotPaths.problem(change.path) != nil { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "path in the commit") }
            try? manager.removeItem(atPath: path)
            touched.insert(change.path)
            guard !change.deleted, let entry = tree[change.path], !entry.isSubmodule else { continue }
            try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard let data = contents[entry.gitID.hex] else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "object missing") }
            if entry.kind == .symlink {
                guard symlink(String(decoding: data, as: UTF8.self), path) == 0 else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "link") }
            } else {
                guard manager.createFile(atPath: path, contents: data, attributes: [.posixPermissions: entry.kind == .executable ? 0o755 : 0o644]) else {
                    throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "write")
                }
                stats.filesWritten += 1
                stats.bytesWritten += UInt64(data.count)
            }
        }
    }

    /// The contents of objects, by id, from `git cat-file --batch`.
    private mutating func batch(_ ids: [String]) throws -> [String: Data] {
        guard !ids.isEmpty else { return [:] }
        stats.git.append("cat-file")
        let argv = ["/usr/bin/git", "-C", input.repo, "cat-file", "--batch"]
        let environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"]) { $1 }
        guard let result = try? BoundedCommand.run(argv, environment: environment, input: Data((ids.joined(separator: "\n") + "\n").utf8), timeout: 120),
              result.status == 0 else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "cat-file") }
        var out: [String: Data] = [:]
        let data = result.output
        var position = data.startIndex
        while position < data.endIndex {
            guard let newline = data[position...].firstIndex(of: 10) else { break }
            let header = String(decoding: data[position..<newline], as: UTF8.self).split(separator: " ")
            position = data.index(after: newline)
            guard header.count == 3, let size = Int(header[2]), data.distance(from: position, to: data.endIndex) >= size else { break }
            out[String(header[0])] = Data(data[position..<data.index(position, offsetBy: size)])
            position = data.index(position, offsetBy: size + 1, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }

    // MARK: The snapshot

    private func isPlainDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// Makes the folders above `path` in `destination`, refusing to pass through a link: a path that went through one could write outside it.
    private func ensureParents(of path: String, in destination: String, known: inout Set<String>) throws {
        var current = destination
        for part in (path as NSString).deletingLastPathComponent.split(separator: "/") where !part.isEmpty {
            current += "/" + part
            if known.contains(current) { continue }
            var status = stat()
            if lstat(current, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    // A file in the way of a folder is replaced (the tree changed type there); a link never is.
                    guard status.st_mode & S_IFMT == S_IFREG else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "link in the way: \(path.prefix(80))") }
                    try FileManager.default.removeItem(atPath: current)
                    try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: false)
                    known.insert(current)
                    continue
                }
            } else {
                try FileManager.default.createDirectory(atPath: current, withIntermediateDirectories: false)
            }
            known.insert(current)
        }
    }

    private mutating func applySnapshot(into destination: String, touched: inout Set<String>) throws {
        let manifest = input.manifest
        if let problem = manifest.problem { throw Failure(code: FleetDispatchCode.snapshotMismatch, detail: problem) }
        let manager = FileManager.default
        var known = Set<String>()
        for path in manifest.deletions {
            try manager.removeItemIfPresent(atPath: destination + "/" + path)
            touched.insert(path)
        }
        // Where this Mac already holds each directory and file the manifest names.
        let hashes = Set(manifest.files.map(\.hash))
        let wantedDirectories = Set(manifest.directories.map(\.hash))
        var files: [FleetHash: FleetContentIndex.Located] = [:], directories: [FleetHash: FleetContentIndex.Located] = [:]
        for index in input.indexes where index.stateNow == .ready {
            let found = index.queue.sync { index.locate(files: hashes.filter { files[$0] == nil }, directories: wantedDirectories.filter { directories[$0] == nil }, gitIDs: []) }
            files.merge(found.files) { first, _ in first }
            directories.merge(found.directories) { first, _ in first }
        }
        for directory in manifest.directories {
            guard let source = directories[directory.hash] else {
                throw Failure(code: FleetDispatchCode.snapshotMismatch, detail: "stale manifest: directory \(directory.path.prefix(80))")
            }
            let target = destination + "/" + directory.path
            try ensureParents(of: directory.path, in: destination, known: &known)
            try manager.removeItemIfPresent(atPath: target)
            if try FleetClone.item(source.path, to: target) { stats.clones += 1 } else { stats.copies += 1 }
            stats.heldLocally += 1
            touched.insert(directory.path)
        }
        // Files first, links last: a link is never a folder something else is written through.
        for file in manifest.files.sorted(by: { ($0.kind == .symlink ? 1 : 0, $0.path) < ($1.kind == .symlink ? 1 : 0, $1.path) }) {
            let target = destination + "/" + file.path
            try ensureParents(of: file.path, in: destination, known: &known)
            try manager.removeItemIfPresent(atPath: target)
            touched.insert(file.path)
            if file.kind == .symlink {
                let text = try linkText(for: file, located: files[file.hash])
                guard FleetSnapshotPaths.linkStaysInside(path: file.path, target: text) else {
                    throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "link leaves the worktree: \(file.path.prefix(80))")
                }
                guard symlink(text, target) == 0 else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "link") }
                stats.filesWritten += 1
                continue
            }
            var source: String
            if let held = files[file.hash], Self.unchanged(held, size: file.size) {
                source = held.path
                stats.heldLocally += 1
            } else if input.blobs.has(file.hash) {
                source = input.blobs.url(file.hash).path
                stats.receivedFiles += 1
            } else {
                throw Failure(code: FleetDispatchCode.snapshotMismatch, detail: "missing content: \(file.path.prefix(80))")
            }
            if try FleetClone.item(source, to: target) { stats.clones += 1 } else { stats.copies += 1 }
            // A clone keeps its source's mode; the manifest says what this one is (a blob is stored 0600).
            let wantedMode: mode_t = file.kind == .executable ? 0o755 : 0o644
            var status = stat()
            if lstat(target, &status) != 0 || status.st_mode & 0o777 != wantedMode { chmod(target, wantedMode) }
        }
    }

    /// A located file that still looks the way the index recorded it.
    static func unchanged(_ held: FleetContentIndex.Located, size: UInt64) -> Bool {
        var status = stat()
        guard lstat(held.path, &status) == 0, UInt64(status.st_size) == held.size, held.size == size else { return false }
        return Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec) == held.modified
    }

    private func linkText(for file: FleetSnapshotFile, located: FleetContentIndex.Located?) throws -> String {
        if input.blobs.has(file.hash), let data = try? Data(contentsOf: input.blobs.url(file.hash)), FleetHash(of: data) == file.hash {
            return String(decoding: data, as: UTF8.self)
        }
        if let located {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(located.path, &buffer, Int(PATH_MAX))
            if count >= 0 {
                let data = Data(buffer.prefix(count).map { UInt8(bitPattern: $0) })
                if FleetHash(of: data) == file.hash { return String(decoding: data, as: UTF8.self) }
            }
        }
        throw Failure(code: FleetDispatchCode.snapshotMismatch, detail: "missing content: \(file.path.prefix(80))")
    }

    // MARK: The index file

    /// The index file of the worktree whose files are laid out in `folder` (the worktree's own folder, or the one that is about to take
    /// its place: a rename keeps every file's stat data).
    private mutating func writeIndex(of folder: String, worktree: String, ordered: [(String, FleetTreeEntry)], touched: Set<String>) throws {
        guard let gitDirectory = Self.gitDirectory(of: worktree) else { throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "gitdir") }
        // Every clone's stat data, read across the cores (a tree of tens of thousands of files is that many `lstat` calls).
        var statuses = [FileStatus?](repeating: nil, count: ordered.count)
        statuses.withUnsafeMutableBufferPointer { out in
            let results = out
            let chunk = max(256, ordered.count / 16 + 1)
            DispatchQueue.concurrentPerform(iterations: (ordered.count + chunk - 1) / chunk) { part in
                for position in (part * chunk)..<min(ordered.count, (part + 1) * chunk) {
                    let (path, entry) = ordered[position]
                    guard !touched.contains(path), !entry.isSubmodule else { continue }
                    var read = stat()
                    if lstat(folder + "/" + path, &read) == 0 { results[position] = read }
                }
            }
        }
        var entries: [FleetGitIndexFile.Entry] = []
        entries.reserveCapacity(ordered.count)
        for (position, (path, entry)) in ordered.enumerated() {
            let mode: UInt32 = entry.isSubmodule ? 0o160000 : entry.kind == .executable ? 0o100755 : entry.kind == .symlink ? 0o120000 : 0o100644
            entries.append(FleetGitIndexFile.Entry(path: path, mode: mode, id: entry.gitID, status: statuses[position]))
        }
        let data = FleetGitIndexFile.data(entries, ordered: true)
        guard FileManager.default.createFile(atPath: gitDirectory + "/index", contents: data, attributes: [.posixPermissions: 0o644]) else {
            throw Failure(code: FleetDispatchCode.snapshotFailed, detail: "index")
        }
    }

    /// The git directory a linked worktree's `.git` file points at.
    static func gitDirectory(of worktree: String) -> String? {
        guard let text = try? String(contentsOfFile: worktree + "/.git", encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        return text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Checking

    /// Recomputes the status digest from what this Mac built and compares it with the sender's. The tree's hashes come from this Mac's
    /// own index (by git blob id) and from the contents it was sent; every received content was checked against its hash as it landed,
    /// and each file the manifest names is looked at here for the size it was sent with.
    private mutating func verify(destination: String, tree: [String: FleetTreeEntry]) throws {
        let manifest = input.manifest
        func mismatch(_ detail: String) -> Failure { Failure(code: FleetDispatchCode.snapshotMismatch, detail: detail) }
        for file in manifest.files {
            var status = stat()
            guard lstat(destination + "/" + file.path, &status) == 0 else { throw mismatch("missing: \(file.path.prefix(80))") }
            if file.kind != .symlink, UInt64(status.st_size) != file.size { throw mismatch("size: \(file.path.prefix(80))") }
        }
        for directory in manifest.directories where !isPlainDirectory(destination + "/" + directory.path) { throw mismatch("directory: \(directory.path.prefix(80))") }
        for path in manifest.deletions {
            var status = stat()
            if lstat(destination + "/" + path, &status) == 0 { throw mismatch("still there: \(path.prefix(80))") }
        }
        // The hash of every tracked file of the commit.
        var base: [String: (kind: FleetEntryKind, hash: FleetHash)] = [:]
        // What the manifest replaces or removes needs no hash of the commit's version.
        let replaced = Set(manifest.files.map(\.path) + manifest.deletions)
        let ids = Set(tree.filter { !$0.value.isSubmodule && !replaced.contains($0.key) }.map(\.value.gitID))
        var known: [FleetGitBlobID: FleetHash] = [:]
        for index in input.indexes where index.stateNow == .ready {
            let found = index.queue.sync { index.locate(files: [], directories: [], gitIDs: ids.filter { known[$0] == nil }) }
            known.merge(found.hashes) { first, _ in first }
        }
        let unknown = ids.filter { known[$0] == nil }
        if !unknown.isEmpty {
            for (id, data) in try batch(unknown.map(\.hex)) { if let parsed = FleetGitBlobID(hex: id) { known[parsed] = FleetHash(of: data) } }
        }
        for (path, entry) in tree where !entry.isSubmodule {
            if replaced.contains(path) { base[path] = (entry.kind, FleetHash(a: 0, b: 0, c: 0, d: 0)); continue }
            guard let hash = known[entry.gitID] else { throw mismatch("no hash: \(path.prefix(80))") }
            base[path] = (entry.kind, hash)
        }
        let root = FleetSnapshotManifest.root(base: base, files: manifest.files, directories: manifest.directories, deletions: manifest.deletions)
        guard root == input.header.rootHash else { throw mismatch("the tree isn't the sender's") }
        var computed = manifest
        computed.rootHash = root
        guard computed.digest == input.header.digest else { throw mismatch("digest") }
    }
}

extension FileManager {
    fileprivate func removeItemIfPresent(atPath path: String) throws {
        var status = stat()
        if lstat(path, &status) == 0 { try removeItem(atPath: path) }
    }
}

extension FleetSpares {
    /// The spare as it stands, without building one (a dispatch never waits for a build).
    func refresh(ifBuilt repo: String) -> Ready? { current(repo: repo) }
}

/// The worktree `git worktree add --no-checkout --no-track -b <branch> <destination> <commit>` makes, written directly: the branch's ref, the
/// worktree's entry under `.git/worktrees`, and the `.git` file in the new folder. It is the slowest step of a warm dispatch (a git
/// process that does a few file writes), and a repository that keeps anything more than the plain layout (a config section for
/// extensions, a worktree config, a hooks path, a packed or taken branch name, a worktree of that name) is left to git.
enum FleetFastWorktree {
    /// True when the worktree was made here; false when nothing was written and git should make it.
    static func add(repo: String, branch: String, commit: String, destination: String) -> Bool {
        let manager = FileManager.default
        guard FleetDispatchGit.isCommit(commit), commit.count == 40, !branch.hasPrefix("-"), !branch.contains(".."), !branch.contains("\0"), !branch.hasSuffix("/"), !branch.hasSuffix(".lock"),
              !branch.contains("//"), !branch.contains("@{"), !branch.contains("\\"), !branch.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 || "~^:?*[".unicodeScalars.contains($0) }),
              !branch.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0.hasSuffix(".lock") }),
              let top = realPath(repo) else { return false }
        let git = top + "/.git"
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: git, isDirectory: &isDirectory), isDirectory.boolValue,
              let raw = try? String(contentsOfFile: git + "/config", encoding: .utf8), case let config = raw.lowercased(),
              !config.contains("[extensions"), !config.contains("worktree"), !config.contains("hookspath"), !config.contains("reftable"),
              !manager.fileExists(atPath: git + "/hooks/reference-transaction"),
              !manager.fileExists(atPath: git + "/refs/heads/" + branch), !manager.fileExists(atPath: destination),
              !((try? String(contentsOfFile: git + "/packed-refs", encoding: .utf8))?.contains(" refs/heads/" + branch + "\n") ?? false) else { return false }
        let name = (destination as NSString).lastPathComponent
        let admin = git + "/worktrees/" + name
        guard !name.isEmpty, !name.hasPrefix("."), !manager.fileExists(atPath: admin) else { return false }
        let parent = (destination as NSString).deletingLastPathComponent
        do { try manager.createDirectory(atPath: parent, withIntermediateDirectories: true) } catch { return false }
        guard let folder = realPath(parent).map({ $0 + "/" + (destination as NSString).lastPathComponent }) else { return false }
        var made: [String] = []
        func write(_ text: String, to path: String) -> Bool {
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            let bytes = Array(text.utf8)
            guard Darwin.write(descriptor, bytes, bytes.count) == bytes.count else { return false }
            made.append(path)
            return true
        }
        func undo() {
            for path in made.reversed() { try? manager.removeItem(atPath: path) }
        }
        do {
            try manager.createDirectory(atPath: admin, withIntermediateDirectories: true)
            made.append(admin)
            try manager.createDirectory(atPath: (git + "/refs/heads/" + branch as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: false)
            made.append(folder)
        } catch { undo(); return false }
        guard write(commit + "\n", to: git + "/refs/heads/" + branch),
              write("ref: refs/heads/" + branch + "\n", to: admin + "/HEAD"),
              write("../..\n", to: admin + "/commondir"),
              write(folder + "/.git\n", to: admin + "/gitdir"),
              write("gitdir: " + admin + "\n", to: folder + "/.git") else { undo(); return false }
        return true
    }

    private static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        return realpath((path as NSString).expandingTildeInPath, &buffer) == nil ? nil : String(cString: buffer)
    }
}
