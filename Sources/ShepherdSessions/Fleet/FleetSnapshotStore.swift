import CryptoKit
import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

/// What a Mac holds of the contents dispatches sent it (slice 4c): files by SHA-256 under `<support>/fleet/snapshot-blobs/`,
/// mode 0600. A content stays while a dispatch uses it and 7 days after (`prune`), and dedupes against every later dispatch.
/// It is kept apart from the sync store's blobs so neither side's pruning reaches the other's files.
final class FleetSnapshotBlobs: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// The whole content doesn't hash to its name.
        case mismatch
        /// A chunk that doesn't continue what is held.
        case outOfOrder
        case io(String)
    }

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    func url(_ hash: FleetHash) -> URL { directory.appendingPathComponent(hash.hex) }
    private func partURL(_ hash: FleetHash) -> URL { directory.appendingPathComponent(hash.hex + ".part") }

    func has(_ hash: FleetHash) -> Bool { FileManager.default.fileExists(atPath: url(hash).path) }

    /// Marks a content as used now, so it outlives the seven days from this.
    func touch(_ hash: FleetHash) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url(hash).path)
    }

    /// Takes a piece of a content. Chunks arrive in order from offset 0; the last one completes the content, which is checked
    /// against its name before it is kept. Returns true once the content is held.
    func receive(_ chunk: FleetBlobChunk) throws -> Bool {
        if has(chunk.hash) { return true }
        lock.lock()
        defer { lock.unlock() }
        let part = partURL(chunk.hash)
        let manager = FileManager.default
        if chunk.offset == 0 { manager.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: part) else { throw Failure.io("no part file") }
        defer { try? handle.close() }
        let held = (try? handle.seekToEnd()) ?? 0
        guard held == chunk.offset else { throw Failure.outOfOrder }
        do { try handle.write(contentsOf: chunk.data) } catch { throw Failure.io("write failed") }
        guard held + UInt64(chunk.data.count) == chunk.size else { return false }
        try? handle.close()
        guard let digest = Self.hash(of: part) else { throw Failure.io("read failed") }
        guard digest == chunk.hash else { try? manager.removeItem(at: part); throw Failure.mismatch }
        do { try manager.moveItem(at: part, to: url(chunk.hash)) } catch { throw Failure.io("move failed") }
        return true
    }

    /// Puts a whole content in (a bundle the sender built, or a blob read from a checkout in a test).
    @discardableResult
    func put(_ data: Data) -> FleetHash? {
        let hash = FleetHash(of: data)
        guard !has(hash) else { return hash }
        return FileManager.default.createFile(atPath: url(hash).path, contents: data, attributes: [.posixPermissions: 0o600]) ? hash : nil
    }

    /// Drops contents unused for `lifetime` (and half written ones that old).
    func prune(olderThan lifetime: TimeInterval = FleetSnapshotTransfer.keepLifetime, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) > lifetime else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// SHA-256 of a file, read in pieces.
    static func hash(of url: URL) -> FleetHash? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return FleetHash(digest: sha.finalize())
    }
}

/// A git index file (version 2) written without git: the worktree a dispatch builds has its files already, with the stat data
/// of the clones, so the index is the commit's tree and those stats. A path that differs from the commit gets a zeroed stat, which
/// git reads as "look at the content", and a deleted one a zeroed stat with no file. Nothing is hashed.
enum FleetGitIndexFile {
    struct Entry {
        var path: String
        /// The tree's mode: 0o100644, 0o100755, 0o120000 or 0o160000.
        var mode: UInt32
        var id: FleetGitBlobID
        /// The file as it is on disk now; nil for one that differs from the commit or is gone.
        var status: stat?
    }

    static func data(_ entries: [Entry]) -> Data {
        var out = Data("DIRC".utf8)
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) } }
        put32(2)
        put32(UInt32(entries.count))
        for entry in entries.sorted(by: { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }) {
            let start = out.count
            let s = entry.status
            put32(UInt32(truncatingIfNeeded: s?.st_ctimespec.tv_sec ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_ctimespec.tv_nsec ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_mtimespec.tv_sec ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_mtimespec.tv_nsec ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_dev ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_ino ?? 0))
            put32(entry.mode)
            put32(UInt32(truncatingIfNeeded: s?.st_uid ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_gid ?? 0))
            put32(UInt32(truncatingIfNeeded: s?.st_size ?? 0))
            out.append(contentsOf: bytes(of: entry.id))
            let name = Array(entry.path.utf8)
            out.append(contentsOf: [UInt8(min(name.count, 0xFFF) >> 8), UInt8(min(name.count, 0xFFF) & 0xFF)])
            out.append(contentsOf: name)
            // 1 to 8 NULs, so the entry's length is a multiple of 8.
            let length = out.count - start
            out.append(contentsOf: [UInt8](repeating: 0, count: 8 - length % 8))
        }
        out.append(contentsOf: Insecure.SHA1.hash(data: out))
        return out
    }

    private static func bytes(of id: FleetGitBlobID) -> [UInt8] {
        let hex = Array(id.hex.utf8)
        return stride(from: 0, to: hex.count, by: 2).map { i in UInt8(String(decoding: hex[i..<i + 2], as: UTF8.self), radix: 16) ?? 0 }
    }
}
