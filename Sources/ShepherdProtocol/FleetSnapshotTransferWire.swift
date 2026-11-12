import Foundation
import ShepherdCore

// Snapshot transfer (`RemoteProtocol.fleetSnapshotCapability`, slice 4c): a dispatch from a checkout with edits,
// untracked or ignored files carries a snapshot (`FleetSnapshotHeader` in the create), its manifest in parts
// (`fleetSnapshotPart`) and the contents the target lacks (`fleetBlobPush`), then the receiving Mac builds the
// worktree, checks the status digest and only then starts the thread. The receiver says what it still needs
// (`FleetSnapshotAck`), so a link that drops resumes with what hadn't arrived, and a manifest that claimed too
// much is repaired by a request for the contents, not a failure.

public enum FleetSnapshotTransfer {
    /// One content in one push: 256 KiB raw, 342 KiB as base64, under the frame cap.
    public static let chunkBytes = 256 * 1024
    /// Manifest entries in one part.
    public static let entriesPerPart = 1_500
    /// The most entries a snapshot may name (a manifest of a million files is not a dispatch).
    public static let maxEntries = 600_000
    /// Most contents one acknowledgement lists as still needed.
    public static let maxNeeds = 4_096
    /// The biggest single content the receiver takes.
    public static let maxBlobBytes: UInt64 = FleetSnapshotCap.refuseAbove
    /// How long a Mac keeps what it received for a dispatch after the record ends (seconds): 7 days.
    public static let keepLifetime: TimeInterval = 7 * 24 * 3_600

    public enum Code {
        /// The pieces of the snapshot don't make the tree the sender described (a changed byte, a missing file, a wrong digest).
        public static let mismatch = FleetDispatchCode.snapshotMismatch
    }
}

/// A content that is not a file of the tree: the bundle of unpushed commits.
public struct FleetBlobRef: Codable, Hashable, Sendable {
    public var hash: FleetHash
    public var size: UInt64

    public init(hash: FleetHash, size: UInt64) { (self.hash, self.size) = (hash, size) }
}

/// What a `fleetDispatchCreate` says of the snapshot that follows it. Counts say when the parts are all in; `bytes` is what
/// the sender will push (after what the target holds), the number the cap and the sending card use.
public struct FleetSnapshotHeader: Codable, Hashable, Sendable {
    public var commit: String
    public var rootHash: FleetHash
    public var digest: FleetHash
    public var files: Int
    public var directories: Int
    public var deletions: Int
    /// Parts the manifest comes in.
    public var parts: Int
    /// Files the snapshot covers (the ones under directories named by hash included), for the sending card.
    public var fileCount: Int
    public var bytes: UInt64
    /// The unpushed commits of the sender's checkout (`git bundle` of `HEAD --not --remotes`), when it has any.
    public var bundle: FleetBlobRef?

    public init(commit: String, rootHash: FleetHash, digest: FleetHash, files: Int, directories: Int, deletions: Int, parts: Int,
                fileCount: Int, bytes: UInt64, bundle: FleetBlobRef? = nil) {
        (self.commit, self.rootHash, self.digest, self.files, self.directories, self.deletions, self.parts) = (commit, rootHash, digest, files, directories, deletions, parts)
        (self.fileCount, self.bytes, self.bundle) = (fileCount, bytes, bundle)
    }

    private enum CodingKeys: String, CodingKey { case commit, rootHash, digest, files, directories, deletions, parts, fileCount, bytes, bundle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        commit = try c.decode(String.self, forKey: .commit)
        rootHash = try c.decode(FleetHash.self, forKey: .rootHash)
        digest = try c.decode(FleetHash.self, forKey: .digest)
        files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
        directories = try c.decodeIfPresent(Int.self, forKey: .directories) ?? 0
        deletions = try c.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        parts = try c.decodeIfPresent(Int.self, forKey: .parts) ?? 0
        fileCount = try c.decodeIfPresent(Int.self, forKey: .fileCount) ?? 0
        bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
        bundle = try c.decodeIfPresent(FleetBlobRef.self, forKey: .bundle)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(commit, forKey: .commit)
        try c.encode(rootHash, forKey: .rootHash)
        try c.encode(digest, forKey: .digest)
        try c.encode(files, forKey: .files)
        try c.encode(directories, forKey: .directories)
        try c.encode(deletions, forKey: .deletions)
        try c.encode(parts, forKey: .parts)
        try c.encode(fileCount, forKey: .fileCount)
        try c.encode(bytes, forKey: .bytes)
        try c.encodeIfPresent(bundle, forKey: .bundle)
    }

    /// Whether the numbers are ones a receiver will work with.
    public var isValid: Bool {
        FleetGitBlobID(hex: commit) != nil && files >= 0 && directories >= 0 && deletions >= 0 && parts >= 0 && parts <= FleetSnapshotTransfer.maxEntries
            && files + directories + deletions <= FleetSnapshotTransfer.maxEntries
            && (bundle.map { $0.size <= FleetSnapshotTransfer.maxBlobBytes } ?? true)
    }
}

/// `RemoteRequest.fleetSnapshotPart`: one part of the manifest, or (`index` -1, no entries) a question about where the receiver stands.
public struct FleetSnapshotPart: Codable, Hashable, Sendable {
    public var index: Int
    public var files: [FleetSnapshotFile]
    public var directories: [FleetSnapshotDirectory]
    public var deletions: [String]
    /// Answer with the contents still needed (not only how many).
    public var wantsNeeds: Bool

    public init(index: Int, files: [FleetSnapshotFile] = [], directories: [FleetSnapshotDirectory] = [], deletions: [String] = [], wantsNeeds: Bool = false) {
        (self.index, self.files, self.directories, self.deletions, self.wantsNeeds) = (index, files, directories, deletions, wantsNeeds)
    }

    private enum CodingKeys: String, CodingKey { case index, files, directories, deletions, wantsNeeds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        files = try c.decodeIfPresent([FleetSnapshotFile].self, forKey: .files) ?? []
        directories = try c.decodeIfPresent([FleetSnapshotDirectory].self, forKey: .directories) ?? []
        deletions = try c.decodeIfPresent([String].self, forKey: .deletions) ?? []
        wantsNeeds = try c.decodeIfPresent(Bool.self, forKey: .wantsNeeds) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        if !files.isEmpty { try c.encode(files, forKey: .files) }
        if !directories.isEmpty { try c.encode(directories, forKey: .directories) }
        if !deletions.isEmpty { try c.encode(deletions, forKey: .deletions) }
        if wantsNeeds { try c.encode(wantsNeeds, forKey: .wantsNeeds) }
    }

    public var entryCount: Int { files.count + directories.count + deletions.count }
}

/// `RemoteRequest.fleetBlobPush`: bytes `offset ..< offset + data.count` of the content named `hash`. Contents go in order; the
/// receiver checks the whole against its hash when the last chunk lands.
public struct FleetBlobChunk: Codable, Hashable, Sendable {
    public var hash: FleetHash
    public var size: UInt64
    public var offset: UInt64
    public var data: Data

    public init(hash: FleetHash, size: UInt64, offset: UInt64, data: Data) {
        (self.hash, self.size, self.offset, self.data) = (hash, size, offset, data)
    }

    public var isValid: Bool {
        data.count <= FleetSnapshotTransfer.chunkBytes && size <= FleetSnapshotTransfer.maxBlobBytes && offset + UInt64(data.count) <= size
    }
}

/// What the receiver holds of a snapshot: the parts that are in (a run from 0), and how many contents it still lacks.
public struct FleetSnapshotAck: Codable, Hashable, Sendable {
    public var dispatchID: UUID
    /// Parts held, counted from the first with none missing.
    public var parts: Int
    /// Contents (the bundle included) not yet held, for `FleetSnapshotPart.wantsNeeds`: the first `maxNeeds` of them.
    public var needs: [FleetHash]
    public var needsCount: Int
    /// The parts and contents are all in and the worktree is being built (or was).
    public var complete: Bool

    public init(dispatchID: UUID, parts: Int, needs: [FleetHash] = [], needsCount: Int = 0, complete: Bool = false) {
        (self.dispatchID, self.parts, self.needs, self.needsCount, self.complete) = (dispatchID, parts, needs, needsCount, complete)
    }

    private enum CodingKeys: String, CodingKey { case dispatchID, parts, needs, needsCount, complete }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dispatchID = try c.decode(UUID.self, forKey: .dispatchID)
        parts = try c.decodeIfPresent(Int.self, forKey: .parts) ?? 0
        needs = try c.decodeIfPresent([FleetHash].self, forKey: .needs) ?? []
        needsCount = try c.decodeIfPresent(Int.self, forKey: .needsCount) ?? needs.count
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dispatchID, forKey: .dispatchID)
        try c.encode(parts, forKey: .parts)
        if !needs.isEmpty { try c.encode(needs, forKey: .needs) }
        try c.encode(needsCount, forKey: .needsCount)
        if complete { try c.encode(complete, forKey: .complete) }
    }
}
