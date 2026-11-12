import CryptoKit
import Foundation

// What a dispatch's snapshot says (slice 4c): the sender's checkout as a difference from the commit it is pinned
// at, named by content hash, and the status digest both Macs compute over it. No I/O here: the sender turns its
// content index into a plan, the receiver checks what it built against the same numbers.

/// A file the target has to end up with that the commit's tree doesn't hold: an edit, a new or an ignored file, a link.
public struct FleetSnapshotFile: Codable, Hashable, Sendable {
    public var path: String
    public var kind: FleetEntryKind
    /// SHA-256 of the content (of the link's target text for a link).
    public var hash: FleetHash
    public var size: UInt64

    public init(path: String, kind: FleetEntryKind, hash: FleetHash, size: UInt64) {
        (self.path, self.kind, self.hash, self.size) = (path, kind, hash, size)
    }
}

/// A directory the target already holds, named by its Merkle hash (an unchanged `node_modules`): the target clones it from
/// where its own index says it lives.
public struct FleetSnapshotDirectory: Codable, Hashable, Sendable {
    public var path: String
    public var hash: FleetHash
    public var files: Int
    public var bytes: UInt64

    public init(path: String, hash: FleetHash, files: Int, bytes: UInt64) {
        (self.path, self.hash, self.files, self.bytes) = (path, hash, files, bytes)
    }
}

/// One path of a commit's tree (`git ls-tree -r`).
public struct FleetTreeEntry: Hashable, Sendable {
    public var kind: FleetEntryKind
    /// The blob's id; for a submodule, the commit's.
    public var gitID: FleetGitBlobID
    public var isSubmodule: Bool

    public init(kind: FleetEntryKind, gitID: FleetGitBlobID, isSubmodule: Bool = false) {
        (self.kind, self.gitID, self.isSubmodule) = (kind, gitID, isSubmodule)
    }
}

/// What a thread's dispatch does with the edits, untracked and ignored files of the checkout it is sent from (Settings ▸ Fleet ▸
/// Code ▸ Uncommitted changes). Fleet-wide, like the other dispatch settings.
public enum FleetUncommittedChanges: String, Codable, CaseIterable, Hashable, Sendable {
    /// The work arrives as the checkout is: its commit, its edits, its new files and its ignored files.
    case sendThem
    /// The work starts from the pinned commit alone.
    case leaveBehind
}

/// A space's changes to what stays home when its checkout is sent (`fleet.snapshotExcludes.<spaceID>`): paths relative to the checkout
/// ("packages/web/dist") or, with no "/", a name that matches at any depth ("dist").
public struct FleetSnapshotExcludes: Codable, Hashable, Sendable {
    /// Kept home as well.
    public var excluded: [String]
    /// Sent although a default rule would keep the directory home.
    public var included: [String]

    public init(excluded: [String] = [], included: [String] = []) { (self.excluded, self.included) = (excluded, included) }

    public var isEmpty: Bool { excluded.isEmpty && included.isEmpty }

    /// The synced setting's name: `fleet.snapshotExcludes.<spaceID>`.
    public static func settingKey(spaceID: String) -> String { "fleet.snapshotExcludes." + spaceID }

    private enum CodingKeys: String, CodingKey { case excluded, included }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
        included = try c.decodeIfPresent([String].self, forKey: .included) ?? []
    }
}

/// How much a dispatch may send, counted in bytes actually sent (after dedupe): above `warnAbove` it sends and says so, above
/// `refuseAbove` it sends nothing.
public enum FleetSnapshotCap {
    public static let warnAbove: UInt64 = 1 << 30
    public static let refuseAbove: UInt64 = 4 << 30

    public enum Verdict: Equatable, Sendable { case send, warn, refuse }

    public static func verdict(bytes: UInt64, warnAbove: UInt64 = FleetSnapshotCap.warnAbove, refuseAbove: UInt64 = FleetSnapshotCap.refuseAbove) -> Verdict {
        bytes > refuseAbove ? .refuse : bytes > warnAbove ? .warn : .send
    }
}

/// The difference between a checkout and the commit it is pinned at.
public struct FleetSnapshotManifest: Hashable, Sendable {
    public var commit: String
    public var files: [FleetSnapshotFile]
    public var directories: [FleetSnapshotDirectory]
    /// Tracked paths the checkout no longer has.
    public var deletions: [String]
    /// The Merkle root of the whole tree the target ends up with.
    public var rootHash: FleetHash

    public init(commit: String, files: [FleetSnapshotFile] = [], directories: [FleetSnapshotDirectory] = [], deletions: [String] = [], rootHash: FleetHash) {
        self.commit = commit
        self.files = files
        self.directories = directories
        self.deletions = deletions
        self.rootHash = rootHash
    }

    /// The status digest: SHA-256 over the commit, the sorted dirty, untracked and ignored paths with their kinds and content hashes, the
    /// directories named by hash, the deletions, and the Merkle root of the whole tree. Both Macs compute it from what they hold.
    public var digest: FleetHash {
        func order(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }
        var hasher = SHA256()
        func put(_ text: String) {
            let utf8 = Array(text.utf8)
            hasher.update(data: withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { Data($0) })
            hasher.update(data: utf8)
        }
        put("fleet-snapshot-v1")
        put(commit)
        for file in files.sorted(by: { order($0.path, $1.path) }) {
            hasher.update(data: [0x46, file.kind.rawValue])
            put(file.path)
            hasher.update(data: file.hash.bytes)
        }
        for directory in directories.sorted(by: { order($0.path, $1.path) }) {
            hasher.update(data: [0x44])
            put(directory.path)
            hasher.update(data: directory.hash.bytes)
        }
        for path in deletions.sorted(by: order) {
            hasher.update(data: [0x58])
            put(path)
        }
        hasher.update(data: rootHash.bytes)
        return FleetHash(digest: hasher.finalize())
    }

    /// The Merkle root of the tree the target ends up with: the commit's tree (`base`: kind and content hash by path), the
    /// deletions taken out, the files and the directories named by hash put in.
    public static func root(base: [String: (kind: FleetEntryKind, hash: FleetHash)], files: [FleetSnapshotFile],
                            directories: [FleetSnapshotDirectory], deletions: [String]) -> FleetHash {
        var tree = FleetMerkleTree()
        for (path, entry) in base { tree.set(path, kind: entry.kind, hash: entry.hash) }
        for path in deletions { tree.remove(path) }
        for file in files { tree.set(file.path, kind: file.kind, hash: file.hash) }
        for directory in directories { tree.setDirectory(directory.path, hash: directory.hash) }
        tree.commit()
        return tree.root
    }

    /// What is wrong with this manifest as a receiver would find it; nil when nothing is. Run before anything is written.
    public var problem: String? {
        var seen = Set<String>()
        for path in files.map(\.path) + directories.map(\.path) + deletions {
            if let bad = FleetSnapshotPaths.problem(path) { return "\(bad): \(path.prefix(80))" }
            guard seen.insert(path.lowercased()).inserted else { return "listed twice: \(path.prefix(80))" }
        }
        // Nothing may sit inside a file or link the manifest also names, nor inside a directory it names by hash.
        let owners = Set(files.map { $0.path.lowercased() } + directories.map { $0.path.lowercased() })
        for path in files.map(\.path) + directories.map(\.path) {
            var end = path.startIndex
            while let slash = path[end...].firstIndex(of: "/") {
                if owners.contains(path[..<slash].lowercased()) { return "inside another entry: \(path.prefix(80))" }
                end = path.index(after: slash)
            }
        }
        guard FleetGitBlobID(hex: commit) != nil else { return "not a commit" }
        return nil
    }
}

/// Which paths a manifest may name.
public enum FleetSnapshotPaths {
    public static let maxBytes = 2048

    /// Why `path` may not be written into a worktree; nil when it may. Absolute paths, `..`, `.`, empty parts and anything
    /// at or under `.git` (any case, as APFS folds it) are refused.
    public static func problem(_ path: String) -> String? {
        guard !path.isEmpty else { return "empty path" }
        guard path.utf8.count <= maxBytes else { return "path too long" }
        guard !path.hasPrefix("/") else { return "absolute path" }
        guard !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return "control character in path" }
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty { return "empty path component" }
            if part == "." || part == ".." { return "relative path component" }
            if part.lowercased() == ".git" { return "path under .git" }
        }
        return nil
    }

    /// Whether the link `target`, written at `path` of a worktree, stays inside it: relative, and never above the root.
    public static func linkStaysInside(path: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0") else { return false }
        var depth = path.split(separator: "/").count - 1
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                depth -= 1
                if depth < 0 { return false }
            default: depth += 1
            }
        }
        return true
    }
}

/// A snapshot as the sender works it out from its index: what to say, what to send, what it costs.
public struct FleetSnapshotPlan: Sendable {
    public var manifest: FleetSnapshotManifest
    /// Contents the target doesn't hold, once each, in the order they go.
    public var missing: [FleetHash]
    /// Where in the checkout each missing content is (the first path that has it).
    public var sources: [FleetHash: String]
    /// Bytes of `missing`.
    public var bytes: UInt64
    /// The largest contents to send, for a refusal that names them.
    public var biggest: [(path: String, bytes: UInt64)]
    /// Files the snapshot covers, the ones under directories named by hash included.
    public var fileCount: Int

    /// A snapshot that carries nothing: for a dispatch that sends only the repository (`FleetSnapshotHeader.repoOnly`).
    public static func empty(commit: String) -> FleetSnapshotPlan {
        FleetSnapshotPlan(manifest: FleetSnapshotManifest(commit: commit, rootHash: FleetHash(a: 0, b: 0, c: 0, d: 0)), missing: [], sources: [:], bytes: 0, biggest: [], fileCount: 0)
    }

    /// Works out the snapshot of a checkout.
    /// - tracked: the commit's tree. - entries, tree: the checkout's content index.
    /// - target: what the target holds of this repository (the 128 bit prefixes), nil when unknown.
    /// - goneFromDisk: whether a tracked path the index doesn't hold is really deleted (an excluded one is not).
    /// - unindexedHash: the content hash of a tracked path the index leaves out but the disk has.
    /// - trackedDirectories: every directory above a tracked path, when the caller keeps them (they are worked out from `tracked` otherwise).
    ///
    /// The root is the index's own tree (already hashed, and a copy of it is cheap) with what the index doesn't say put right: the
    /// tracked paths it leaves out (excluded ones) added, and the submodules' folders, which the receiver doesn't build, taken out. It
    /// is the root `FleetSnapshotManifest.root` gives from the commit's tree and the manifest, without hashing the tree again.
    public static func make(commit: String, tracked: [String: FleetTreeEntry], entries: [String: FleetIndexEntry], tree: FleetMerkleTree,
                            target: FleetManifest?, goneFromDisk: (String) -> Bool, unindexedHash: (String) -> FleetHash,
                            trackedDirectories known: Set<String>? = nil) -> FleetSnapshotPlan {
        let held = target ?? FleetManifest()
        let submodules = Set(tracked.filter { $0.value.isSubmodule }.keys)
        var files: [FleetSnapshotFile] = []
        var deletions: [String] = []
        var unindexed: [(path: String, kind: FleetEntryKind, hash: FleetHash)] = []
        var trackedDirectories = known ?? Set<String>()
        let findDirectories = known == nil
        for (path, entry) in tracked where !entry.isSubmodule {
            if findDirectories {
                var end = path.startIndex
                while let slash = path[end...].firstIndex(of: "/") {
                    trackedDirectories.insert(String(path[..<slash]))
                    end = path.index(after: slash)
                }
            }
            guard let have = entries[path] else {
                if goneFromDisk(path) { deletions.append(path) } else { unindexed.append((path, entry.kind, unindexedHash(path))) }
                continue
            }
            if have.gitID != entry.gitID || have.kind != entry.kind {
                files.append(FleetSnapshotFile(path: path, kind: have.kind, hash: have.hash, size: have.size))
            }
        }
        var directories: [FleetSnapshotDirectory] = []
        func walk(_ directory: String) {
            guard let children = tree.names(in: directory) else { return }
            for name in children.keys.sorted() {
                let node = children[name]!
                let path = directory.isEmpty ? name : directory + "/" + name
                if submodules.contains(path) { continue }
                if node.kind == .directory {
                    if trackedDirectories.contains(path) || !held.contains(node.hash) { walk(path) }
                    else { directories.append(FleetSnapshotDirectory(path: path, hash: node.hash, files: 0, bytes: 0)) }
                } else if tracked[path] == nil, let entry = entries[path] {
                    files.append(FleetSnapshotFile(path: path, kind: entry.kind, hash: entry.hash, size: entry.size))
                }
            }
        }
        walk("")
        // What each directory named by hash stands for.
        if !directories.isEmpty {
            var counts: [String: (files: Int, bytes: UInt64)] = [:]
            let names = Set(directories.map(\.path))
            for (path, entry) in entries where tracked[path] == nil {
                var end = path.startIndex
                while let slash = path[end...].firstIndex(of: "/") {
                    let prefix = String(path[..<slash])
                    if names.contains(prefix) {
                        counts[prefix, default: (0, 0)].files += 1
                        counts[prefix, default: (0, 0)].bytes += entry.size
                        break
                    }
                    end = path.index(after: slash)
                }
            }
            directories = directories.map { FleetSnapshotDirectory(path: $0.path, hash: $0.hash, files: counts[$0.path]?.files ?? 0, bytes: counts[$0.path]?.bytes ?? 0) }
        }
        func order(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }
        files.sort { order($0.path, $1.path) }
        directories.sort { order($0.path, $1.path) }
        deletions.sort(by: order)
        var whole = tree
        for path in submodules { whole.remove(path) }
        for path in unindexed { whole.set(path.path, kind: path.kind, hash: path.hash) }
        whole.commit()
        let manifest = FleetSnapshotManifest(commit: commit, files: files, directories: directories, deletions: deletions, rootHash: whole.root)
        let wanted = FleetManifestDiff.missing(files.map(\.hash), from: held)
        var sources: [FleetHash: String] = [:]
        var sizes: [FleetHash: UInt64] = [:]
        for file in files where sources[file.hash] == nil { sources[file.hash] = file.path; sizes[file.hash] = file.size }
        let bytes = wanted.reduce(UInt64(0)) { $0 + (sizes[$1] ?? 0) }
        let biggest = wanted.compactMap { hash in sources[hash].map { (path: $0, bytes: sizes[hash] ?? 0) } }.sorted { $0.bytes > $1.bytes }.prefix(3)
        let covered = files.count + directories.reduce(0) { $0 + $1.files }
        return FleetSnapshotPlan(manifest: manifest, missing: wanted, sources: sources, bytes: bytes, biggest: Array(biggest), fileCount: covered)
    }
}
