import CryptoKit
import Darwin
import Foundation
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

    /// Works out the snapshot. `unpushed` says the checkout has commits no remote ref holds.
    func build(id: UUID, unpushed: Bool) throws -> Built {
        // Whatever the system already has for this root reaches the index first, so a file written a moment ago is in it; then a
        // spot check of a sample of what the index holds against the disk (the plan's R13).
        index.settle()
        index.queue.sync { _ = index.verify(sample: 64) }
        guard let view = index.queue.sync(execute: { index.snapshotView() }) else {
            throw Failure.notIndexed(index.queue.sync { index.state.rawValue })
        }
        guard let tree = FleetDispatchGit.run(["ls-tree", "-r", "-z", commit], in: root, timeout: 60), tree.status == 0 else { throw Failure.git("ls-tree") }
        let tracked = Self.parse(tree: tree.output)
        let root = self.root
        let plan = FleetSnapshotPlan.make(
            commit: commit, tracked: tracked, entries: view.entries, tree: view.tree, target: target,
            goneFromDisk: { var status = stat(); return lstat(root + "/" + $0, &status) != 0 },
            unindexedHash: { path in FleetSnapshotBlobs.hash(of: URL(fileURLWithPath: root + "/" + path)) ?? FleetHash(a: 0, b: 0, c: 0, d: 0) })
        if let problem = plan.manifest.problem { throw Failure.git("manifest: \(problem)") }
        var bundle: (FleetBlobRef, URL)?
        if unpushed { bundle = try makeBundle(id: id) }
        let total = plan.bytes + (bundle?.0.size ?? 0)
        let verdict = FleetSnapshotCap.verdict(bytes: total)
        if verdict == .refuse {
            throw Failure.tooLarge(bytes: total, biggest: plan.biggest.map { "\($0.path):\($0.bytes)" })
        }
        let parts = Self.parts(of: plan.manifest)
        let header = FleetSnapshotHeader(
            commit: commit, rootHash: plan.manifest.rootHash, digest: plan.manifest.digest, files: plan.manifest.files.count,
            directories: plan.manifest.directories.count, deletions: plan.manifest.deletions.count, parts: parts.count,
            fileCount: plan.fileCount, bytes: total, bundle: bundle?.0)
        return Built(id: id, plan: plan, header: header, parts: parts, root: root, bundle: bundle, warning: verdict == .warn)
    }

    /// `git ls-tree -r -z`: `<mode> <type> <id>\t<path>\0`.
    static func parse(tree output: String) -> [String: FleetTreeEntry] {
        var out: [String: FleetTreeEntry] = [:]
        for record in output.split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, let id = FleetGitBlobID(hex: String(fields[2])) else { continue }
            let path = String(record[record.index(after: tab)...])
            switch fields[0] {
            case "100644": out[path] = FleetTreeEntry(kind: .file, gitID: id)
            case "100755": out[path] = FleetTreeEntry(kind: .executable, gitID: id)
            case "120000": out[path] = FleetTreeEntry(kind: .symlink, gitID: id)
            case "160000": out[path] = FleetTreeEntry(kind: .file, gitID: id, isSubmodule: true)
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

    /// `git bundle` of what no remote ref holds, written under the fleet's own directory.
    private func makeBundle(id: UUID) throws -> (FleetBlobRef, URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(id.uuidString.lowercased()).bundle")
        try? FileManager.default.removeItem(at: url)
        guard let made = FleetDispatchGit.run(["bundle", "create", url.path, "HEAD", "--not", "--remotes"], in: root, timeout: 300), made.status == 0,
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
