import CryptoKit
import Foundation

/// Fleet's sync engine on the wire (`RemoteProtocol.fleetSyncCapability`): units of settings and
/// content that every Mac holds the same, carried as an append only op log per origin Mac and
/// relayed verbatim by any Mac that has it. Not git, not a CRDT text merge: the newest write per
/// unit wins by hybrid logical clock and the loser is kept in history.
public enum FleetSyncProtocol {
    /// Largest value an op carries inline (a setting's JSON). Anything bigger is a blob.
    public static let maxInlineValueBytes = 64 * 1024
    /// Largest blob a Mac stores or serves.
    public static let maxBlobBytes = 32 * 1024 * 1024
    /// A blob is fetched in chunks of this size (the reply carries it base64, under the 1 MiB frame cap).
    public static let blobChunkBytes = 256 * 1024
    /// A batch of ops is cut at this many encoded bytes (under the 1 MiB frame cap).
    public static let maxBatchBytes = 512 * 1024
    /// And at this many ops.
    public static let maxBatchOps = 500

    /// The hex SHA-256 of `data`: a blob's name.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    /// The codes a client reads off an error reply of a sync request.
    public enum Code {
        public static let notFound = "not_found"
        public static let tooLarge = "too_large"
        public static let invalid = "invalid"
    }
}

/// A hybrid logical clock reading: wall time in milliseconds and a counter that breaks ties
/// between readings in one millisecond. Order is (wall, counter); equal readings from two Macs
/// are ordered by their ids (`FleetOp.supersedes`), so no order depends on trusting a clock.
public struct FleetHLC: Codable, Hashable, Comparable, Sendable {
    public var wallMs: UInt64
    public var counter: UInt32

    public init(wallMs: UInt64, counter: UInt32 = 0) {
        self.wallMs = wallMs
        self.counter = counter
    }

    public static func < (a: FleetHLC, b: FleetHLC) -> Bool {
        (a.wallMs, a.counter) < (b.wallMs, b.counter)
    }

    /// The reading after `last` at wall time `now`: the clock never goes back, whatever the wall clock does.
    public func next(now: UInt64) -> FleetHLC {
        now > wallMs ? FleetHLC(wallMs: now) : FleetHLC(wallMs: wallMs, counter: counter &+ 1)
    }
}

/// What one op says about its unit.
public enum FleetChange: Hashable, Sendable {
    /// The unit's new value, inline (a setting's JSON text).
    case value(String)
    /// The unit's new content, by hash: fetched with `FleetSyncRequest.blob` when not held.
    case blob(hash: String, size: Int)
    /// The unit no longer exists (a setting back to unset).
    case deletion
}

extension FleetChange: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value, hash, size }
    private enum Kind: String, Codable { case value, blob, deletion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .value: self = .value(try c.decode(String.self, forKey: .value))
        case .blob: self = .blob(hash: try c.decode(String.self, forKey: .hash), size: try c.decode(Int.self, forKey: .size))
        case .deletion: self = .deletion
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let text):
            try c.encode(Kind.value, forKey: .kind)
            try c.encode(text, forKey: .value)
        case .blob(let hash, let size):
            try c.encode(Kind.blob, forKey: .kind)
            try c.encode(hash, forKey: .hash)
            try c.encode(size, forKey: .size)
        case .deletion:
            try c.encode(Kind.deletion, forKey: .kind)
        }
    }
}

/// One entry of a Mac's op log. `(mac, seq)` names it: each Mac numbers its own ops from 1 with
/// no gaps, so a version vector says exactly which ops a Mac holds.
public struct FleetOp: Codable, Hashable, Sendable {
    public var mac: UUID
    public var seq: UInt64
    public var hlc: FleetHLC
    /// "setting:host.defaultModel", "instruction:AGENTS.md" (`FleetUnit`).
    public var unit: String
    public var change: FleetChange
    /// Copied from what the Mac already held when its sync first ran, not something a person
    /// wrote: any write by a person beats it, and among seeds the earliest wins, which makes the
    /// Mac where Fleet was first switched on the reference.
    public var seed: Bool
    /// The Mac's name when it wrote this, for history ("Synced from Mac mini") and the sync line.
    public var macName: String

    public init(mac: UUID, seq: UInt64, hlc: FleetHLC, unit: String, change: FleetChange, seed: Bool = false, macName: String = "") {
        self.mac = mac
        self.seq = seq
        self.hlc = hlc
        self.unit = unit
        self.change = change
        self.seed = seed
        self.macName = macName
    }

    private enum CodingKeys: String, CodingKey { case mac, seq, hlc, unit, change, seed, macName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mac = try c.decode(UUID.self, forKey: .mac)
        seq = try c.decode(UInt64.self, forKey: .seq)
        hlc = try c.decode(FleetHLC.self, forKey: .hlc)
        unit = try c.decode(String.self, forKey: .unit)
        change = try c.decode(FleetChange.self, forKey: .change)
        seed = try c.decodeIfPresent(Bool.self, forKey: .seed) ?? false
        macName = try c.decodeIfPresent(String.self, forKey: .macName) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mac, forKey: .mac)
        try c.encode(seq, forKey: .seq)
        try c.encode(hlc, forKey: .hlc)
        try c.encode(unit, forKey: .unit)
        try c.encode(change, forKey: .change)
        if seed { try c.encode(true, forKey: .seed) }
        if !macName.isEmpty { try c.encode(macName, forKey: .macName) }
    }

    /// Whether this op wins over `other` for the same unit: any op a person made over a seed;
    /// two seeds, the earlier; otherwise the later clock reading, then the larger Mac id.
    public func supersedes(_ other: FleetOp) -> Bool {
        if seed != other.seed { return !seed }
        if hlc != other.hlc { return seed ? hlc < other.hlc : hlc > other.hlc }
        return mac.uuidString > other.mac.uuidString
    }

    /// The blob this op needs, if any.
    public var blobHash: String? {
        if case .blob(let hash, _) = change { return hash }
        return nil
    }

    /// Whether a peer's op is well formed: shape and sizes only. What a unit means is the
    /// materializer's business, and it refuses what it can't apply.
    public var isWellFormed: Bool {
        guard seq >= 1, FleetUnit.isValid(unit) else { return false }
        switch change {
        case .value(let text): return text.utf8.count <= FleetSyncProtocol.maxInlineValueBytes
        case .blob(let hash, let size): return FleetSyncProtocol.isHash(hash) && size >= 0 && size <= FleetSyncProtocol.maxBlobBytes
        case .deletion: return true
        }
    }
}

/// Unit names: `<kind>:<name>`. Slice 2a carries `setting` (`host.<key>` and `pi.<key>` and the
/// `fleet.<key>` policy) and `instruction` (`AGENTS.md`, `APPEND_SYSTEM.md`). Skills and
/// extensions follow: `skill:<name>` holds a skill's state (on or off, where it came from) and
/// `skill:<name>/<path>` each file in it; `extension:<path>` is a file under `your-extensions/` and
/// `extmeta:<id>` says what one extension is (its name, the files pi loads, whether it is on).
public enum FleetUnit {
    public static func setting(_ key: String) -> String { "setting:" + key }
    public static func instruction(_ file: InstructionFile) -> String { "instruction:" + file.fileName }
    public static func skill(_ name: String) -> String { "skill:" + name }
    public static func skillFile(_ name: String, _ path: String) -> String { "skill:\(name)/\(path)" }
    public static func extensionFile(_ path: String) -> String { "extension:" + path }
    public static func extensionMeta(_ id: String) -> String { "extmeta:" + id }

    /// A skill unit's skill and, for a file, its path inside the skill ("pdf", "scripts/fill.py");
    /// nil path is the skill's state.
    public static func skillParts(of unit: String) -> (name: String, path: String?)? {
        guard kind(of: unit) == "skill", let name = name(of: unit) else { return nil }
        guard let slash = name.firstIndex(of: "/") else { return (name, nil) }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }

    public static func kind(of unit: String) -> String? { split(unit)?.kind }
    public static func name(of unit: String) -> String? { split(unit)?.name }

    private static func split(_ unit: String) -> (kind: String, name: String)? {
        guard let colon = unit.firstIndex(of: ":") else { return nil }
        let kind = String(unit[..<colon]), name = String(unit[unit.index(after: colon)...])
        return kind.isEmpty || name.isEmpty ? nil : (kind, name)
    }

    /// A unit name from a peer: a lowercase kind and a short printable name with no `..`, so a
    /// name never reaches a path or a key it shouldn't.
    public static func isValid(_ unit: String) -> Bool {
        guard unit.utf8.count <= 200, let (kind, name) = split(unit),
              kind.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) }), kind.utf8.count <= 20 else { return false }
        return !name.contains("..") && name.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }
}

/// The highest `seq` each Mac's log is held up to. Two Macs compare vectors to know which ops the
/// other lacks.
public struct FleetVersionVector: Codable, Hashable, Sendable {
    public var seqs: [UUID: UInt64]

    public init(_ seqs: [UUID: UInt64] = [:]) { self.seqs = seqs }

    public subscript(mac: UUID) -> UInt64 {
        get { seqs[mac] ?? 0 }
        set { seqs[mac] = newValue == 0 ? nil : newValue }
    }

    /// Whether this vector holds everything `other` does.
    public func covers(_ other: FleetVersionVector) -> Bool {
        other.seqs.allSatisfy { self[$0.key] >= $0.value }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: UInt64].self)
        seqs = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(Dictionary(uniqueKeysWithValues: seqs.map { ($0.key.uuidString, $0.value) }))
    }
}

/// What one Mac's host asks another's over their fleet link, after `hello` with a peer's token
/// (`RemoteRequest.fleetSync`). Answered with a `FleetSyncReply`.
public enum FleetSyncRequest: Codable, Hashable, Sendable {
    /// A link came up: the sender's vector. Answered `.state` with the receiver's.
    case hello(vector: FleetVersionVector)
    /// Ops the receiver lacks, in order per origin. Answered `.state`.
    case ops([FleetOp])
    /// One op, live. Answered `.state`.
    case op(FleetOp)
    /// A blob (or a chunk of one) by hash. Answered `.blob`.
    case blob(hash: String, offset: Int)

    private enum CodingKeys: String, CodingKey { case kind, vector, ops, op, hash, offset }
    private enum Kind: String, Codable { case hello, ops, op, blob }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .hello: self = .hello(vector: try c.decode(FleetVersionVector.self, forKey: .vector))
        case .ops: self = .ops(try c.decode([FleetOp].self, forKey: .ops))
        case .op: self = .op(try c.decode(FleetOp.self, forKey: .op))
        case .blob: self = .blob(hash: try c.decode(String.self, forKey: .hash), offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let vector):
            try c.encode(Kind.hello, forKey: .kind)
            try c.encode(vector, forKey: .vector)
        case .ops(let ops):
            try c.encode(Kind.ops, forKey: .kind)
            try c.encode(ops, forKey: .ops)
        case .op(let op):
            try c.encode(Kind.op, forKey: .kind)
            try c.encode(op, forKey: .op)
        case .blob(let hash, let offset):
            try c.encode(Kind.blob, forKey: .kind)
            try c.encode(hash, forKey: .hash)
            try c.encode(offset, forKey: .offset)
        }
    }
}

public enum FleetSyncReply: Codable, Hashable, Sendable {
    /// The receiver's vector after the request.
    case state(vector: FleetVersionVector)
    /// `data` is `total` bytes of the blob from `offset` on, up to `FleetSyncProtocol.blobChunkBytes`.
    case blob(hash: String, offset: Int, total: Int, data: Data)

    private enum CodingKeys: String, CodingKey { case kind, vector, hash, offset, total, data }
    private enum Kind: String, Codable { case state, blob }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .state: self = .state(vector: try c.decode(FleetVersionVector.self, forKey: .vector))
        case .blob:
            self = .blob(hash: try c.decode(String.self, forKey: .hash), offset: try c.decode(Int.self, forKey: .offset),
                         total: try c.decode(Int.self, forKey: .total), data: try c.decode(Data.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .state(let vector):
            try c.encode(Kind.state, forKey: .kind)
            try c.encode(vector, forKey: .vector)
        case .blob(let hash, let offset, let total, let data):
            try c.encode(Kind.blob, forKey: .kind)
            try c.encode(hash, forKey: .hash)
            try c.encode(offset, forKey: .offset)
            try c.encode(total, forKey: .total)
            try c.encode(data, forKey: .data)
        }
    }
}

/// Where sync stands with each Mac, for Settings ▸ Fleet's status line (`FleetSnapshot.sync`).
public struct FleetSyncStatus: Codable, Hashable, Sendable {
    public struct Peer: Codable, Hashable, Sendable, Identifiable {
        public enum State: String, Codable, Hashable, Sendable {
            /// Linked, and neither Mac holds anything the other lacks.
            case inSync
            /// Linked, and ops or blobs are still moving.
            case catchingUp
            /// No link: it takes what it missed when it wakes.
            case offline
        }

        public var hostID: UUID
        public var name: String
        public var state: State
        public var id: UUID { hostID }

        public init(hostID: UUID, name: String, state: State) {
            self.hostID = hostID
            self.name = name
            self.state = state
        }
    }

    /// Every paired Mac, oldest pairing first.
    public var peers: [Peer]
    /// What the first sync replaced on this Mac, in one line ("Replaced AGENTS.md with Mac mini's.
    /// The old copy is in its history."), nil when it replaced nothing or the notice is old.
    public var notice: String?

    public init(peers: [Peer] = [], notice: String? = nil) {
        self.peers = peers
        self.notice = notice
    }
}
