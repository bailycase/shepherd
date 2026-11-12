import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol

/// What this Mac holds of one repository, as it announces it to its peers (slice 4b): the content hashes of every
/// file and the Merkle hashes of every directory in every checkout of the repository here, as 128 bit prefixes.
/// Checkouts overlap (two clones of one repository share nearly everything), so each prefix is counted and is in the
/// manifest while any checkout holds it.
///
/// Changes pile up until `flush` turns them into one delta, which takes the next sequence number; the last few deltas
/// are kept, so a peer that missed some is caught up and one that missed too many is sent the whole set (a new
/// generation). Server queue.
final class FleetLocalManifest {
    /// Deltas kept for a peer that is behind.
    static let keptDeltas = 64

    struct Delta {
        var seq: UInt64
        var added: [FleetHashPrefix]
        var removed: [FleetHashPrefix]
        /// The digest of the whole set after this delta.
        var digest: FleetManifestDigest
    }

    let repo: String
    private(set) var generation: UInt64
    private(set) var seq: UInt64 = 0
    private(set) var manifest = FleetManifest()
    private var counts: [FleetHashPrefix: Int] = [:]
    private var pendingAdded: Set<FleetHashPrefix> = []
    private var pendingRemoved: Set<FleetHashPrefix> = []
    private var log: [Delta] = []

    init(repo: String, generation: UInt64 = FleetLocalManifest.newGeneration()) {
        self.repo = repo
        self.generation = generation
    }

    /// Below 2^53, so it survives any JSON reader.
    static func newGeneration() -> UInt64 { UInt64.random(in: 1..<(1 << 53)) }

    var head: FleetManifestHead { FleetManifestHead(generation: generation, seq: seq, digest: manifest.digest) }
    var hasPending: Bool { !pendingAdded.isEmpty || !pendingRemoved.isEmpty }

    func add(_ hashes: [FleetHash]) {
        for hash in hashes {
            let prefix = hash.prefix
            counts[prefix, default: 0] += 1
            if counts[prefix] == 1 {
                if pendingRemoved.remove(prefix) == nil { pendingAdded.insert(prefix) }
            }
        }
    }

    func remove(_ hashes: [FleetHash]) {
        for hash in hashes {
            let prefix = hash.prefix
            guard let count = counts[prefix] else { continue }
            if count <= 1 {
                counts[prefix] = nil
                if pendingAdded.remove(prefix) == nil { pendingRemoved.insert(prefix) }
            } else {
                counts[prefix] = count - 1
            }
        }
    }

    /// Makes the changes since the last flush the next delta, applying them to `manifest`. Nil when there are none.
    @discardableResult
    func flush() -> Delta? {
        guard hasPending else { return nil }
        let added = Array(pendingAdded), removed = Array(pendingRemoved)
        pendingAdded = []
        pendingRemoved = []
        for prefix in removed { manifest.remove(prefix) }
        for prefix in added { manifest.insert(prefix) }
        seq += 1
        let delta = Delta(seq: seq, added: added, removed: removed, digest: manifest.digest)
        log.append(delta)
        if log.count > Self.keptDeltas { log.removeFirst(log.count - Self.keptDeltas) }
        return delta
    }

    /// The whole set in batches, as of the current step: deltas from `seq` on continue it.
    func fullUpdates() -> [FleetRepoManifestUpdate] {
        let all = manifest.prefixes.sorted()
        let size = FleetSnapshotProtocol.maxBatchPrefixes
        let parts = max(1, (all.count + size - 1) / size)
        return (0..<parts).map { part in
            FleetRepoManifestUpdate(repo: repo, kind: .full, generation: generation, seq: seq,
                                    added: FleetHashPrefix.pack(all[(part * size)..<min(all.count, (part + 1) * size)]),
                                    part: part, parts: parts, digest: manifest.digest)
        }
    }

    /// The deltas that bring a peer that has `acked` up to `seq`, as updates; nil when it can't be done from the log
    /// (another generation, behind the log's start, or a delta too big for one frame).
    func updates(after acked: (generation: UInt64, seq: UInt64)) -> [FleetRepoManifestUpdate]? {
        guard acked.generation == generation, acked.seq <= seq else { return nil }
        let wanted = log.filter { $0.seq > acked.seq }
        guard wanted.count == Int(seq - acked.seq) else { return nil }
        var out: [FleetRepoManifestUpdate] = []
        for delta in wanted {
            guard delta.added.count + delta.removed.count <= FleetSnapshotProtocol.maxBatchPrefixes else { return nil }
            out.append(FleetRepoManifestUpdate(repo: repo, kind: .delta, generation: generation, seq: delta.seq, added: FleetHashPrefix.pack(delta.added),
                                               removed: FleetHashPrefix.pack(delta.removed), digest: delta.digest))
        }
        return out
    }

    /// Where this manifest stands, with no data.
    func headUpdate() -> FleetRepoManifestUpdate {
        FleetRepoManifestUpdate(repo: repo, kind: .head, generation: generation, seq: seq, digest: manifest.digest)
    }
}

/// What this Mac holds of the manifests its peers sent (`<support>/fleet/index/peers/<hostID>/`): one copy per peer
/// per repository, kept on disk so a restarted host knows what its peers have before any link is up and a peer's `head`
/// finds the copy still good. Server queue; saves happen off it (`save`).
struct FleetPeerManifests {
    /// Prefixes one peer may have us hold, across its repositories, and repositories one peer may have.
    static let maxPrefixesPerPeer = 8_000_000
    static let maxRepos = 500

    struct Copy {
        var head: FleetManifestHead
        var manifest: FleetManifest
    }

    private struct Staging {
        var generation: UInt64
        var parts: Int
        var next: Int
        var manifest: FleetManifest
    }

    private var copies: [UUID: [String: Copy]] = [:]
    private var staging: [UUID: [String: Staging]] = [:]
    private var changed: Set<Pair> = []

    private struct Pair: Hashable { var host: UUID; var repo: String }

    func copy(of host: UUID, repo: String) -> Copy? { copies[host]?[repo] }

    /// What `host` holds of `repo`, if it has said.
    func manifest(of host: UUID, repo: String) -> FleetManifest? { copies[host]?[repo]?.manifest }

    func repos(of host: UUID) -> [String] { copies[host].map { $0.keys.sorted() } ?? [] }

    func holds(_ host: UUID, repo: String, _ hash: FleetHash) -> Bool { copies[host]?[repo]?.manifest.contains(hash) ?? false }

    mutating func forget(_ host: UUID) {
        copies[host] = nil
        staging[host] = nil
    }

    /// Takes a step of `host`'s stream and answers where the copy stands. Never trusts a step it can't check:
    /// anything that doesn't line up is answered `resend`, and a copy that failed its digest is dropped.
    mutating func receive(_ update: FleetRepoManifestUpdate, from host: UUID) -> FleetRepoManifestAck {
        let repo = update.repo
        func ack(_ resend: Bool = false) -> FleetRepoManifestAck {
            let held = copies[host]?[repo]?.head
            return FleetRepoManifestAck(repo: repo, generation: held?.generation ?? 0, seq: held?.seq ?? 0, resend: resend)
        }
        guard update.isValid, let added = FleetHashPrefix.unpack(update.added), let removed = FleetHashPrefix.unpack(update.removed) else { return ack(true) }
        if copies[host]?[repo] == nil, (copies[host]?.count ?? 0) >= Self.maxRepos { return ack(true) }
        let announced = FleetManifestHead(generation: update.generation, seq: update.seq, digest: update.digest)
        switch update.kind {
        case .full:
            let batch = update.part == 0 ? Staging(generation: update.generation, parts: update.parts, next: 0, manifest: FleetManifest()) : staging[host]?[repo]
            guard var current = batch, current.generation == update.generation, current.parts == update.parts, current.next == update.part else {
                staging[host]?[repo] = nil
                return ack(true)
            }
            let others = (copies[host] ?? [:]).filter { $0.key != repo }.values.reduce(0) { $0 + $1.manifest.count }
            for prefix in added { current.manifest.insert(prefix) }
            guard others + current.manifest.count <= Self.maxPrefixesPerPeer else { staging[host]?[repo] = nil; return ack(true) }
            current.next += 1
            guard current.next == current.parts else {
                staging[host, default: [:]][repo] = current
                return ack()
            }
            staging[host]?[repo] = nil
            guard FleetManifestDiff.verifies(current.manifest, against: announced) else { return ack(true) }
            copies[host, default: [:]][repo] = Copy(head: announced, manifest: current.manifest)
            changed.insert(Pair(host: host, repo: repo))
            return ack()
        case .delta:
            switch FleetManifestDiff.judge(held: copies[host]?[repo]?.head, announced: announced, carriesDelta: true) {
            case .inSync, .catchUp: return ack()
            case .resend: return ack(true)
            case .apply:
                guard var copy = copies[host]?[repo] else { return ack(true) }
                // In place: a copy that fails its digest is dropped below, so nothing half applied is ever kept.
                copies[host]?[repo] = nil
                for prefix in removed { copy.manifest.remove(prefix) }
                for prefix in added { copy.manifest.insert(prefix) }
                guard FleetManifestDiff.verifies(copy.manifest, against: announced) else { changed.insert(Pair(host: host, repo: repo)); return ack(true) }
                copy.head = announced
                copies[host]?[repo] = copy
                changed.insert(Pair(host: host, repo: repo))
                return ack()
            }
        case .head:
            // In sync, or behind (the sender sends the steps between): the answer says where the copy stands either way.
            return ack(FleetManifestDiff.judge(held: copies[host]?[repo]?.head, announced: announced, carriesDelta: false) == .resend)
        }
    }

    // MARK: On disk

    private static func file(_ host: UUID, _ repo: String, in directory: URL) -> URL {
        let name = SHA256.hash(data: Data(repo.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(host.uuidString, isDirectory: true).appendingPathComponent(name + ".manifest")
    }

    /// Reads every copy saved under `directory`.
    static func load(from directory: URL) -> FleetPeerManifests {
        var loaded = FleetPeerManifests()
        let fm = FileManager.default
        for hostFolder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let host = UUID(uuidString: hostFolder.lastPathComponent) else { continue }
            for file in (try? fm.contentsOfDirectory(at: hostFolder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "manifest" {
                guard let data = try? Data(contentsOf: file), let newline = data.firstIndex(of: 10),
                      let header = try? JSONDecoder().decode(SavedHeader.self, from: data[data.startIndex..<newline]),
                      let prefixes = FleetHashPrefix.unpack(data[data.index(after: newline)...]) else { continue }
                let manifest = FleetManifest(prefixes)
                guard manifest.digest == header.digest else { continue }
                loaded.copies[host, default: [:]][header.repo] = Copy(head: FleetManifestHead(generation: header.generation, seq: header.seq, digest: header.digest),
                                                                       manifest: manifest)
            }
        }
        return loaded
    }

    private struct SavedHeader: Codable {
        var repo: String
        var generation: UInt64
        var seq: UInt64
        var digest: FleetManifestDigest
    }

    /// What changed since the last call, as a job to run off the server queue (the copies are values, so it holds its own).
    mutating func takeSave(to directory: URL) -> (() -> Void)? {
        guard !changed.isEmpty else { return nil }
        let pairs = changed
        changed = []
        var writes: [(URL, Copy?, String)] = []
        for pair in pairs { writes.append((Self.file(pair.host, pair.repo, in: directory), copies[pair.host]?[pair.repo], pair.repo)) }
        return {
            for (url, copy, repo) in writes {
                guard let copy else { try? FileManager.default.removeItem(at: url); continue }
                var data = (try? JSONEncoder().encode(SavedHeader(repo: repo, generation: copy.head.generation, seq: copy.head.seq, digest: copy.head.digest))) ?? Data()
                data.append(10)
                data.append(FleetHashPrefix.pack(copy.manifest.prefixes))
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }

    /// Removes what is saved for `host` (it left the fleet).
    static func erase(_ host: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(host.uuidString, isDirectory: true))
    }
}
