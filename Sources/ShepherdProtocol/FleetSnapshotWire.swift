import Foundation
import ShepherdCore

// Manifests (`RemoteProtocol.fleetSnapshotCapability`, slice 4b): what each Mac holds of each repository,
// as 128 bit prefixes of content hashes, pushed to the Macs it is paired with so a dispatch can send only
// what the target lacks. A manifest is a stream: one `full` send starts a generation, `delta`s follow
// in order, and a `head` says where the sender stands now. The receiver keeps its copy, checks the
// running digest after each step, and asks for everything again (`FleetRepoManifestAck.resend`) when
// anything doesn't line up.

public enum FleetSnapshotProtocol {
    /// Prefixes in one frame: 16 KiB of them is 256 KiB raw, about 342 KiB as base64, under the frame cap.
    public static let maxBatchPrefixes = 16_384
    /// A repository's manifest is named by its canonical repo key, or `space:<id>` for a space with no origin.
    public static let maxRepoNameBytes = 300
    /// Most parts one full send may have (a manifest of 16 million hashes is not a repository).
    public static let maxParts = 1_024

    /// A repository's name in manifests when it has a key.
    public static func repoName(key: String?, space: String) -> String { key ?? "space:\(space)" }

    public enum Code {
        public static let invalid = "invalid"
    }
}

/// One step of a manifest stream (`RemoteRequest.fleetRepoManifest`).
public struct FleetRepoManifestUpdate: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// The whole set as of step `seq`, in `parts` batches, replacing what the receiver holds.
        case full
        /// The next step of the generation: `seq` is one more than the last.
        case delta
        /// No data: the sender's state now (a link just came up, or a quiet check).
        case head
    }

    public var repo: String
    public var kind: Kind
    public var generation: UInt64
    /// The step this brings the receiver to: each delta is one more than the last, a `full` and a `head` say where the sender is.
    public var seq: UInt64
    /// 16 byte prefixes end to end.
    public var added: Data
    public var removed: Data
    /// Which batch of a `full` this is (0 based) and how many there are. 0 of 1 otherwise.
    public var part: Int
    public var parts: Int
    /// The digest of the sender's whole set after this step; for a `full`, checked once its last part is in.
    public var digest: FleetManifestDigest

    public init(repo: String, kind: Kind, generation: UInt64, seq: UInt64, added: Data = Data(), removed: Data = Data(),
                part: Int = 0, parts: Int = 1, digest: FleetManifestDigest) {
        self.repo = repo
        self.kind = kind
        self.generation = generation
        self.seq = seq
        self.added = added
        self.removed = removed
        self.part = part
        self.parts = parts
        self.digest = digest
    }

    private enum CodingKeys: String, CodingKey { case repo, kind, generation, seq, added, removed, part, parts, digest }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        kind = try c.decode(Kind.self, forKey: .kind)
        generation = try c.decode(UInt64.self, forKey: .generation)
        seq = try c.decode(UInt64.self, forKey: .seq)
        added = try c.decodeIfPresent(Data.self, forKey: .added) ?? Data()
        removed = try c.decodeIfPresent(Data.self, forKey: .removed) ?? Data()
        part = try c.decodeIfPresent(Int.self, forKey: .part) ?? 0
        parts = try c.decodeIfPresent(Int.self, forKey: .parts) ?? 1
        digest = try c.decode(FleetManifestDigest.self, forKey: .digest)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(repo, forKey: .repo)
        try c.encode(kind, forKey: .kind)
        try c.encode(generation, forKey: .generation)
        try c.encode(seq, forKey: .seq)
        if !added.isEmpty { try c.encode(added, forKey: .added) }
        if !removed.isEmpty { try c.encode(removed, forKey: .removed) }
        if part != 0 { try c.encode(part, forKey: .part) }
        if parts != 1 { try c.encode(parts, forKey: .parts) }
        try c.encode(digest, forKey: .digest)
    }

    /// Whether the message is well formed: a bounded name, whole prefixes within the batch limit, sensible parts, and
    /// data only where the kind carries it. The receiver refuses anything else.
    public var isValid: Bool {
        guard !repo.isEmpty, repo.utf8.count <= FleetSnapshotProtocol.maxRepoNameBytes, !repo.contains("\0"),
              added.count % FleetHashPrefix.byteCount == 0, removed.count % FleetHashPrefix.byteCount == 0,
              (added.count + removed.count) / FleetHashPrefix.byteCount <= FleetSnapshotProtocol.maxBatchPrefixes,
              digest.count >= 0 else { return false }
        switch kind {
        case .full: return removed.isEmpty && parts >= 1 && parts <= FleetSnapshotProtocol.maxParts && part >= 0 && part < parts
        case .delta: return parts == 1 && part == 0 && seq >= 1
        case .head: return added.isEmpty && removed.isEmpty && parts == 1 && part == 0
        }
    }
}

/// What a receiver answers to a manifest step: where its copy stands, and whether it needs everything again.
public struct FleetRepoManifestAck: Codable, Hashable, Sendable {
    public var repo: String
    public var generation: UInt64
    public var seq: UInt64
    /// The copy can't be brought to the sender's by this message (a gap, another generation, a digest that doesn't match):
    /// send the whole set again.
    public var resend: Bool

    public init(repo: String, generation: UInt64, seq: UInt64, resend: Bool = false) {
        self.repo = repo
        self.generation = generation
        self.seq = seq
        self.resend = resend
    }

    private enum CodingKeys: String, CodingKey { case repo, generation, seq, resend }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decode(String.self, forKey: .repo)
        generation = try c.decode(UInt64.self, forKey: .generation)
        seq = try c.decode(UInt64.self, forKey: .seq)
        resend = try c.decodeIfPresent(Bool.self, forKey: .resend) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(repo, forKey: .repo)
        try c.encode(generation, forKey: .generation)
        try c.encode(seq, forKey: .seq)
        if resend { try c.encode(resend, forKey: .resend) }
    }
}

/// Where this Mac's content index stands, for its app (`FleetSnapshot.index`): reported so a dispatch from a
/// repository still being indexed can say so instead of waiting on it.
public struct FleetIndexStatus: Codable, Hashable, Sendable {
    public struct Repo: Codable, Hashable, Sendable {
        /// The repository's manifest name (`FleetSnapshotProtocol.repoName`).
        public var repo: String
        public var name: String
        /// Files indexed so far.
        public var files: Int
        /// The first scan is done and events keep it current.
        public var ready: Bool
        /// The folder holds more files than the index takes (`FleetContentIndex.maxFiles`) and isn't indexed.
        public var tooLarge: Bool

        public init(repo: String, name: String, files: Int, ready: Bool, tooLarge: Bool = false) {
            self.repo = repo
            self.name = name
            self.files = files
            self.ready = ready
            self.tooLarge = tooLarge
        }

        private enum CodingKeys: String, CodingKey { case repo, name, files, ready, tooLarge }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repo = try c.decode(String.self, forKey: .repo)
            name = try c.decode(String.self, forKey: .name)
            files = try c.decode(Int.self, forKey: .files)
            ready = try c.decode(Bool.self, forKey: .ready)
            tooLarge = try c.decodeIfPresent(Bool.self, forKey: .tooLarge) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(repo, forKey: .repo)
            try c.encode(name, forKey: .name)
            try c.encode(files, forKey: .files)
            try c.encode(ready, forKey: .ready)
            if tooLarge { try c.encode(tooLarge, forKey: .tooLarge) }
        }
    }

    /// Some repository is still on its first scan.
    public var indexing: Bool
    public var repos: [Repo]

    public init(indexing: Bool = false, repos: [Repo] = []) {
        self.indexing = indexing
        self.repos = repos
    }
}
