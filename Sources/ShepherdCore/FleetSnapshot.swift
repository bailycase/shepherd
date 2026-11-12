import CryptoKit
import Foundation

// The value types and pure functions under a fleet's content index (slice 4b): what a Mac holds of a
// repository's files, named by hash, and how two Macs compare what they hold. No I/O here.

/// A SHA-256: the name of a file's content, and of a directory's Merkle hash.
public struct FleetHash: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    private var a, b, c, d: UInt64

    public init(a: UInt64, b: UInt64, c: UInt64, d: UInt64) { (self.a, self.b, self.c, self.d) = (a, b, c, d) }

    /// The 32 bytes of a SHA-256 digest.
    public init(digest: some Sequence<UInt8>) {
        var words = [UInt64](repeating: 0, count: 4)
        var index = 0
        for byte in digest.prefix(32) {
            words[index / 8] = words[index / 8] << 8 | UInt64(byte)
            index += 1
        }
        self.init(a: words[0], b: words[1], c: words[2], d: words[3])
    }

    public init(of data: some DataProtocol) { self.init(digest: SHA256.hash(data: data)) }

    /// 64 lowercase hex digits (the name `fleetBlob` serves a blob under); nil for anything else.
    public init?(hex: String) {
        guard hex.utf8.count == 64 else { return nil }
        var words = [UInt64](repeating: 0, count: 4)
        var index = 0
        for byte in hex.utf8 {
            let value: UInt64
            switch byte {
            case 48...57: value = UInt64(byte) - 48
            case 97...102: value = UInt64(byte) - 87
            default: return nil
            }
            words[index / 16] = words[index / 16] << 4 | value
            index += 1
        }
        self.init(a: words[0], b: words[1], c: words[2], d: words[3])
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let hash = FleetHash(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a SHA-256"))
        }
        self = hash
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var hex: String { String(format: "%016llx%016llx%016llx%016llx", a, b, c, d) }
    public var description: String { hex }

    /// The first 128 bits: what a manifest holds in place of the whole hash.
    public var prefix: FleetHashPrefix { FleetHashPrefix(hi: a, lo: b) }

    /// The 32 bytes, in order.
    public var bytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(32)
        for word in [a, b, c, d] { for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) } }
        return out
    }

    public static func < (x: FleetHash, y: FleetHash) -> Bool { (x.a, x.b, x.c, x.d) < (y.a, y.b, y.c, y.d) }
}

/// The first 128 bits of a `FleetHash`. A manifest holds these: 16 bytes a hash is a quarter of the
/// space, and a false "held" (two different contents sharing 128 bits is not a thing that happens by
/// chance) is repaired by the target asking for the blob, never trusted.
public struct FleetHashPrefix: Hashable, Comparable, Sendable, Codable {
    public var hi: UInt64
    public var lo: UInt64

    public static let byteCount = 16

    public init(hi: UInt64, lo: UInt64) { (self.hi, self.lo) = (hi, lo) }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = FleetHashPrefix(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a 128 bit prefix"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public init?(hex: String) {
        guard hex.utf8.count == 32, let hi = UInt64(hex.prefix(16), radix: 16), let lo = UInt64(hex.suffix(16), radix: 16) else { return nil }
        self.init(hi: hi, lo: lo)
    }

    public var hex: String { String(format: "%016llx%016llx", hi, lo) }

    /// `count` prefixes laid end to end, 16 bytes each (a manifest batch on the wire).
    public static func pack(_ prefixes: some Sequence<FleetHashPrefix>) -> Data {
        var data = Data()
        for prefix in prefixes {
            for word in [prefix.hi, prefix.lo] {
                for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
            }
        }
        return data
    }

    /// The prefixes in `data`; nil when it isn't a whole number of them.
    public static func unpack(_ data: Data) -> [FleetHashPrefix]? {
        guard data.count % byteCount == 0 else { return nil }
        let bytes = [UInt8](data)
        var out = [FleetHashPrefix]()
        out.reserveCapacity(bytes.count / byteCount)
        var offset = 0
        while offset < bytes.count {
            var words: [UInt64] = [0, 0]
            for word in 0..<2 {
                for byte in 0..<8 { words[word] = words[word] << 8 | UInt64(bytes[offset + word * 8 + byte]) }
            }
            out.append(FleetHashPrefix(hi: words[0], lo: words[1]))
            offset += byteCount
        }
        return out
    }

    public static func < (x: FleetHashPrefix, y: FleetHashPrefix) -> Bool { (x.hi, x.lo) < (y.hi, y.lo) }
}

/// The id git gives a blob (SHA-1, 20 bytes).
public struct FleetGitBlobID: Hashable, Sendable, Codable, CustomStringConvertible {
    private var a, b: UInt64
    private var c: UInt32

    public init(digest: some Sequence<UInt8>) {
        var words = [UInt64](repeating: 0, count: 3)
        var index = 0
        for byte in digest.prefix(20) {
            let word = index / 8
            words[word] = words[word] << 8 | UInt64(byte)
            index += 1
        }
        self.init(a: words[0], b: words[1], c: UInt32(truncatingIfNeeded: words[2]))
    }

    private init(a: UInt64, b: UInt64, c: UInt32) { (self.a, self.b, self.c) = (a, b, c) }

    /// 40 hex digits.
    public init?(hex: String) {
        guard hex.utf8.count == 40, let a = UInt64(hex.prefix(16), radix: 16), let b = UInt64(hex.dropFirst(16).prefix(16), radix: 16),
              let c = UInt32(hex.suffix(8), radix: 16) else { return nil }
        self.init(a: a, b: b, c: c)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let id = FleetGitBlobID(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a git blob id"))
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    public var hex: String { String(format: "%016llx%016llx%08x", a, b, c) }
    public var description: String { hex }

    /// The id git gives `content` as a blob: SHA-1 of "blob <size>\0" and the content.
    public static func of(_ content: some DataProtocol) -> FleetGitBlobID {
        var hasher = Insecure.SHA1()
        hasher.update(data: Array("blob \(content.count)\0".utf8))
        hasher.update(data: content)
        return FleetGitBlobID(digest: hasher.finalize())
    }
}

// MARK: - Index entries

/// What a path in a checkout is, for hashing and for the exec bit.
public enum FleetEntryKind: UInt8, Codable, Hashable, Sendable {
    case file = 0
    case executable = 1
    case symlink = 2
}

/// Where git puts a file: in its index, not in it and not ignored, or ignored.
public enum FleetGitClass: UInt8, Codable, Hashable, Sendable {
    case tracked = 0
    case untracked = 1
    case ignored = 2
}

/// One file (or link) of a checkout as the index holds it.
public struct FleetIndexEntry: Hashable, Sendable {
    public var kind: FleetEntryKind
    public var size: UInt64
    /// Modification time in nanoseconds: with `size`, what says the content was not read again.
    public var modified: Int64
    /// SHA-256 of the content (of the target text for a link).
    public var hash: FleetHash
    /// The id git gives this content as a blob, so a dirty set is a comparison and not a `git status`.
    public var gitID: FleetGitBlobID
    public var state: FleetGitClass

    public init(kind: FleetEntryKind, size: UInt64, modified: Int64, hash: FleetHash, gitID: FleetGitBlobID, state: FleetGitClass) {
        self.kind = kind
        self.size = size
        self.modified = modified
        self.hash = hash
        self.gitID = gitID
        self.state = state
    }
}

/// What changed between two states of an index, by path.
public struct FleetIndexDiff: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    /// Same path, different content or exec bit or kind.
    public var changed: [String] = []
    /// Same path and content, a different modification time (a `touch`): nothing to send.
    public var touched: [String] = []
    /// Same path and content, a different git class.
    public var reclassified: [String] = []
    /// A path that went away while its content appeared at another path (a rename: the content is already held).
    public var renamed: [(from: String, to: String)] = []

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty && touched.isEmpty && reclassified.isEmpty }

    public static func == (a: FleetIndexDiff, b: FleetIndexDiff) -> Bool {
        a.added == b.added && a.removed == b.removed && a.changed == b.changed && a.touched == b.touched
            && a.reclassified == b.reclassified && a.renamed.map { [$0.from, $0.to] } == b.renamed.map { [$0.from, $0.to] }
    }

    /// Everything that differs from `old` to `new`, each list sorted. A removed path whose content (and kind) came back at one new
    /// path is a rename and appears in `renamed` as well as in `removed` and `added`.
    public static func between(_ old: [String: FleetIndexEntry], _ new: [String: FleetIndexEntry]) -> FleetIndexDiff {
        var diff = FleetIndexDiff()
        for (path, entry) in new {
            guard let before = old[path] else { diff.added.append(path); continue }
            if before.hash != entry.hash || before.kind != entry.kind { diff.changed.append(path) }
            else if before.state != entry.state { diff.reclassified.append(path) }
            else if before.modified != entry.modified { diff.touched.append(path) }
        }
        for path in old.keys where new[path] == nil { diff.removed.append(path) }
        diff.added.sort(); diff.removed.sort(); diff.changed.sort(); diff.touched.sort(); diff.reclassified.sort()
        var gone: [FleetHash: [String]] = [:]
        for path in diff.removed { gone[old[path]!.hash, default: []].append(path) }
        for path in diff.added {
            let entry = new[path]!
            if var candidates = gone[entry.hash], let from = candidates.first(where: { old[$0]!.kind == entry.kind }) {
                diff.renamed.append((from, path))
                candidates.removeAll { $0 == from }
                gone[entry.hash] = candidates
            }
        }
        return diff
    }
}

// MARK: - Merkle tree

/// A checkout's directories hashed bottom up: a file is its content hash, a directory is the hash of
/// its children's names, kinds and hashes in name order, so the root changes when any file under it does and
/// does not depend on the order things were added. This is what lets a dispatch say "your `node_modules`
/// is the one I have" with one hash.
///
/// Mutations only mark what they touched; `commit()` recomputes each touched directory once, deepest first,
/// and reports every directory hash that appeared, changed or went (the manifest's adds and removes).
public struct FleetMerkleTree: Sendable {
    public enum Kind: UInt8, Sendable { case file = 0x46, executable = 0x58, symlink = 0x4C, directory = 0x44 }

    public struct Node: Equatable, Sendable {
        public var kind: Kind
        public var hash: FleetHash
    }

    /// A directory hash that came, changed or went in a `commit()`.
    public struct Change: Equatable, Sendable {
        public var path: String
        public var old: FleetHash?
        public var new: FleetHash?
    }

    /// Directory path ("" is the root) to its children by name.
    private var children: [String: [String: Node]] = ["": [:]]
    private var committed: [String: FleetHash] = [:]
    private var dirty: Set<String> = []
    private var removedDirectories: [(String, FleetHash)] = []

    public init() {}

    /// The hash of a directory of `nodes`.
    public static func hash(of nodes: [String: Node]) -> FleetHash {
        var hasher = SHA256()
        for name in nodes.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
            let node = nodes[name]!
            let utf8 = Array(name.utf8)
            hasher.update(data: [node.kind.rawValue])
            hasher.update(data: withUnsafeBytes(of: UInt32(utf8.count).bigEndian) { Data($0) })
            hasher.update(data: utf8)
            hasher.update(data: node.hash.bytes)
        }
        return FleetHash(digest: hasher.finalize())
    }

    private static func split(_ path: String) -> (parent: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    /// Marks `directory` and every directory above it. Whatever is marked has all its ancestors marked.
    private mutating func markDirty(from directory: String) {
        var current = directory
        while dirty.insert(current).inserted, !current.isEmpty { current = Self.split(current).parent }
    }

    /// Records the file or link at `path` (relative, "/" separated).
    public mutating func set(_ path: String, kind: FleetEntryKind, hash: FleetHash) {
        let (parent, name) = Self.split(path)
        let node = Node(kind: kind == .symlink ? .symlink : kind == .executable ? .executable : .file, hash: hash)
        // Every directory above the file that doesn't exist yet is made, with its place in its parent.
        var current = parent
        while !current.isEmpty {
            let (up, directory) = Self.split(current)
            if children[current] == nil { children[current] = [:] }
            if children[up]?[directory] != nil { break }
            children[up, default: [:]][directory] = Node(kind: .directory, hash: FleetHash(a: 0, b: 0, c: 0, d: 0))
            current = up
        }
        // A file where a directory was (or the other way round) replaces it.
        if children[parent]?[name]?.kind == .directory { remove(path) }
        children[parent, default: [:]][name] = node
        markDirty(from: parent)
    }

    /// Records a whole directory by its hash, with nothing beneath it (a snapshot that says "your `node_modules` is the one I
    /// have"). The tree's hash comes out the same as if every file under it had been set.
    public mutating func setDirectory(_ path: String, hash: FleetHash) {
        let (parent, name) = Self.split(path)
        var current = parent
        while !current.isEmpty {
            let (up, directory) = Self.split(current)
            if children[current] == nil { children[current] = [:] }
            if children[up]?[directory] != nil { break }
            children[up, default: [:]][directory] = Node(kind: .directory, hash: FleetHash(a: 0, b: 0, c: 0, d: 0))
            current = up
        }
        if children[parent]?[name]?.kind == .directory, children[path] != nil { dropDirectory(path) }
        children[parent, default: [:]][name] = Node(kind: .directory, hash: hash)
        markDirty(from: parent)
    }

    /// Removes the file or link at `path`, or the whole directory there.
    public mutating func remove(_ path: String) {
        let (parent, name) = Self.split(path)
        guard let node = children[parent]?[name] else { return }
        if node.kind == .directory { dropDirectory(path) }
        children[parent]?[name] = nil
        markDirty(from: parent)
    }

    private mutating func dropDirectory(_ path: String) {
        if let hash = committed.removeValue(forKey: path) { removedDirectories.append((path, hash)) }
        dirty.remove(path)
        for (name, node) in children[path] ?? [:] where node.kind == .directory { dropDirectory(path + "/" + name) }
        children[path] = nil
    }

    /// The names (and kinds) directly under the directory `path`.
    public func names(in directory: String) -> [String: Node]? { children[directory] }

    /// Recomputes what the mutations touched. Empty directories are removed.
    @discardableResult
    public mutating func commit() -> [Change] {
        var changes: [Change] = []
        for (path, hash) in removedDirectories { changes.append(Change(path: path, old: hash, new: nil)) }
        removedDirectories = []
        // Deepest first, so a directory's children are hashed before it. One that a removal emptied leaves its parent,
        // which is marked too (every directory above a change is), so no directory is missed.
        for path in dirty.map({ (Self.depth($0), $0) }).sorted(by: { $0.0 > $1.0 }).map(\.1) {
            guard let nodes = children[path] else { continue }
            if nodes.isEmpty, !path.isEmpty {
                let (parent, name) = Self.split(path)
                children[path] = nil
                children[parent]?[name] = nil
                if let old = committed.removeValue(forKey: path) { changes.append(Change(path: path, old: old, new: nil)) }
                continue
            }
            let hash = Self.hash(of: nodes)
            let old = committed[path]
            committed[path] = hash
            if old != hash { changes.append(Change(path: path, old: old, new: hash)) }
            if !path.isEmpty {
                let (parent, name) = Self.split(path)
                children[parent]?[name] = Node(kind: .directory, hash: hash)
            }
        }
        dirty = []
        return changes
    }

    private static func depth(_ path: String) -> Int { path.isEmpty ? 0 : path.utf8.reduce(1) { $0 + ($1 == 47 ? 1 : 0) } }

    /// The root's hash as of the last `commit()`.
    public var root: FleetHash { committed[""] ?? Self.hash(of: [:]) }

    /// The hash of the directory at `path` as of the last `commit()`.
    public func hash(ofDirectory path: String) -> FleetHash? { committed[path] }

    /// Every directory hash held, with its path ("" is the root: a tree identical to this one has this hash).
    public var directoryHashes: [(path: String, hash: FleetHash)] { committed.map { ($0.key, $0.value) } }
}

// MARK: - Manifests

/// A running digest of a set of prefixes: how many, and all of them XORed together. It is updated as one
/// is added or removed, does not depend on order, and two sets that differ by a prefix differ in it.
public struct FleetManifestDigest: Hashable, Codable, Sendable {
    public var count: Int
    public var xor: FleetHashPrefix

    public static let empty = FleetManifestDigest(count: 0, xor: FleetHashPrefix(hi: 0, lo: 0))

    public init(count: Int, xor: FleetHashPrefix) { (self.count, self.xor) = (count, xor) }

    mutating func toggle(_ prefix: FleetHashPrefix, adding: Bool) {
        count += adding ? 1 : -1
        xor = FleetHashPrefix(hi: xor.hi ^ prefix.hi, lo: xor.lo ^ prefix.lo)
    }
}

/// What a Mac holds of one repository, as 128 bit prefixes of the content hashes of its files and the
/// Merkle hashes of its directories, with the digest of the set.
public struct FleetManifest: Equatable, Sendable {
    public private(set) var prefixes: Set<FleetHashPrefix> = []
    public private(set) var digest = FleetManifestDigest.empty

    public init() {}

    public init(_ prefixes: some Sequence<FleetHashPrefix>) {
        for prefix in prefixes { insert(prefix) }
    }

    public var count: Int { prefixes.count }

    @discardableResult
    public mutating func insert(_ prefix: FleetHashPrefix) -> Bool {
        guard prefixes.insert(prefix).inserted else { return false }
        digest.toggle(prefix, adding: true)
        return true
    }

    @discardableResult
    public mutating func remove(_ prefix: FleetHashPrefix) -> Bool {
        guard prefixes.remove(prefix) != nil else { return false }
        digest.toggle(prefix, adding: false)
        return true
    }

    public func contains(_ hash: FleetHash) -> Bool { prefixes.contains(hash.prefix) }

    /// The digest of `prefixes` computed from scratch (what a receiver checks its copy against).
    public static func digest(of prefixes: some Sequence<FleetHashPrefix>) -> FleetManifestDigest {
        FleetManifest(prefixes).digest
    }
}

/// Where a held copy of a peer's manifest stands: which stream of deltas, how far along it, and its digest.
public struct FleetManifestHead: Hashable, Codable, Sendable {
    public var generation: UInt64
    public var seq: UInt64
    public var digest: FleetManifestDigest

    public init(generation: UInt64, seq: UInt64, digest: FleetManifestDigest) {
        (self.generation, self.seq, self.digest) = (generation, seq, digest)
    }
}

/// Comparing manifests. Pure.
public enum FleetManifestDiff {
    /// The hashes in `wanted` the manifest doesn't hold, in order and without repeats: what a sender has
    /// to send. Held is decided by the 128 bit prefix, so it can only err toward "held", which the target repairs.
    public static func missing(_ wanted: [FleetHash], from manifest: FleetManifest) -> [FleetHash] {
        var seen = Set<FleetHash>()
        return wanted.filter { !manifest.contains($0) && seen.insert($0).inserted }
    }

    /// What a receiver does with what a sender announced.
    public enum Verdict: Equatable, Sendable {
        /// Take the delta: it is the next one of the stream held.
        case apply
        /// Nothing to apply: the copy is the sender's.
        case inSync
        /// The copy is behind in the same generation: say where it stands, and the sender sends the steps between.
        case catchUp
        /// The copy can't be brought to the sender's by this message: send everything again.
        case resend
    }

    /// Judges a `delta` (the next step of a stream) or a `head` (the sender's state now, no data) against the copy held.
    /// `held` is nil when nothing is held for the repository.
    public static func judge(held: FleetManifestHead?, announced: FleetManifestHead, carriesDelta: Bool) -> Verdict {
        guard let held, held.generation == announced.generation else { return .resend }
        if carriesDelta {
            if announced.seq == held.seq + 1 { return .apply }
            // A step already taken is nothing to do; one beyond the next means steps were missed.
            return announced.seq > held.seq ? .catchUp : .inSync
        }
        if announced.seq == held.seq { return announced.digest == held.digest ? .inSync : .resend }
        return announced.seq > held.seq ? .catchUp : .resend
    }

    /// After applying a delta: whether the copy's digest is the one the sender announced for it.
    public static func verifies(_ manifest: FleetManifest, against announced: FleetManifestHead) -> Bool {
        manifest.digest == announced.digest
    }
}
