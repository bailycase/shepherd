import CryptoKit
import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Explicit snapshots only. Preparation and persistence run off the server queue; only the
/// prepared descriptor checks and exclusive rename share the server's authority linearization.
enum ProjectPublicationFiles {
    struct Manifest: Codable {
        var artifact: ProjectArtifactReceipt
        var device: Int32
        var inode: UInt64
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func failure(_ code: String = "publication_file", _ message: String = "Cannot access a private regular publication file.") -> LogicalProjectsError { .init(code, message) }

    static func sourceParts(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.utf8.count <= 1024, !parts.isEmpty, parts.allSatisfy(ProjectArtifactReceipt.safeComponent) else {
            throw failure("invalid_path", "Choose a nonhidden relative source inside the worker's assigned directory.")
        }
        return parts
    }

    static func source(_ path: String, cwd: String, protected: [String]) throws -> Data {
        let parts = try sourceParts(path)
        // Only macOS's two system aliases are normalized. Resolving the whole cwd here
        // would let a replaced Space/worktree symlink redirect an already assigned worker.
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4096, !cwd.utf8.contains(0),
              !cwd.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw failure() }
        let rootPath = (cwd == "/tmp" || cwd.hasPrefix("/tmp/") || cwd == "/var" || cwd.hasPrefix("/var/")) ? "/private" + cwd : cwd
        let forbidden = protected + ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private/etc", "/dev"]
            + [".ssh", ".config", ".aws", ".azure", ".kube", ".gnupg", ".pi", ".agents", "Library"].map { NSHomeDirectory() + "/" + $0 }
        guard rootPath != "/", rootPath.lowercased() != NSHomeDirectory().lowercased(), !forbidden.contains(where: {
            let canonical = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path.lowercased()
            let sourcePath = (rootPath + "/" + parts.joined(separator: "/")).lowercased()
            return rootPath.lowercased() == canonical || rootPath.lowercased().hasPrefix(canonical + "/")
                || sourcePath == canonical || sourcePath.hasPrefix(canonical + "/")
        }) else { throw failure("protected_path", "Runtime, application, authentication and home configuration roots are not publication sources.") }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        for component in rootPath.split(separator: "/") {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure() }; close(fd); fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        let device = info.st_dev
        for (index, component) in parts.enumerated() {
            let directory = index < parts.count - 1
            let next = openat(fd, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (directory ? O_DIRECTORY : 0))
            guard next >= 0 else { throw failure() }; close(fd); fd = next
            guard fstat(fd, &info) == 0, info.st_dev == device, info.st_uid == geteuid(),
                  info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || info.st_nlink == 1 else { throw failure() }
        }
        return try snapshot(fd, original: info)
    }

    /// Descriptor and the pre-read stat are supplied together; recheck after the bounded read.
    static func snapshot(_ fd: Int32, original: stat) throws -> Data {
        var info = stat()
        guard original.st_size >= 0, original.st_size <= ProjectArtifactReceipt.maximumBytes else { throw failure("file_too_large", "Publication exceeds 32 MiB.") }
        let bytes = try readBounded(fd, limit: ProjectArtifactReceipt.maximumBytes)
        guard fstat(fd, &info) == 0, info.st_size == original.st_size, bytes.count == info.st_size,
              info.st_nlink == 1, info.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              info.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw failure("source_changed", "Source changed while it was snapshotted; no publication was committed.")
        }
        // Known textual credentials are refused, not redacted into a different artifact.
        // This cannot detect arbitrary image-encoded or renamed/obfuscated secrets.
        let text = String(decoding: bytes, as: UTF8.self)
        guard NativeRedaction.projectData(text) == text else { throw failure("secret_artifact", "Source contains known secret-bearing text; publication refused.") }
        return bytes
    }

    static func readBounded(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(ProjectArtifactReceipt.chunkBytes, limit + 1))
        let deadline = Date().addingTimeInterval(ProjectArtifactReceipt.transferSeconds)
        while data.count <= limit {
            guard Date() < deadline else { throw failure("publication_timeout", "Publication I/O deadline exceeded.") }
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw failure() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { throw failure("file_too_large", "Publication grew beyond its byte limit.") }
        return data
    }

    static func digest(_ fd: Int32, expectedSize: Int64) throws -> String {
        guard expectedSize >= 0, expectedSize <= ProjectArtifactReceipt.maximumBytes, lseek(fd, 0, SEEK_SET) == 0 else { throw failure() }
        let data = try readBounded(fd, limit: Int(expectedSize))
        guard data.count == expectedSize else { throw failure("publication_corrupt", "Publication size changed.") }
        return hash(data)
    }

    /// The injected state parent is trusted; below it every component is descriptor-pinned.
    static func withStore<T>(_ id: UUID, beside stateURL: URL, create: Bool, reserving bytes: Int = 0,
                             ifMissing: (() throws -> T)? = nil, _ body: (Int32) throws -> T) throws -> T {
        guard let resolved = realpath(stateURL.deletingLastPathComponent().path, nil) else { throw failure() }
        defer { free(resolved) }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        for component in String(cString: resolved).split(separator: "/") {
            let next = openat(parent, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure() }; close(parent); parent = next
        }
        var info = stat()
        guard fstat(parent, &info) == 0 else { throw failure() }
        let device = info.st_dev
        for component in ["project-publications", id.uuidString.lowercased()] {
            if create {
                if mkdirat(parent, component, 0o700) == 0 {
                    guard fsync(parent) == 0 else { throw failure() }
                } else if errno != EEXIST { throw failure() }
            }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, !create, let ifMissing { return try ifMissing() }
            guard next >= 0 else { throw failure() }; close(parent); parent = next
            guard fstat(parent, &info) == 0, info.st_dev == device, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw failure() }
            if component == "project-publications", create {
                let copy = fcntl(parent, F_DUPFD_CLOEXEC, 0)
                guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw failure() }
                defer { closedir(stream) }
                var count = 0, total = Int64(bytes), found = false
                while let entry = readdir(stream) {
                    let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                        pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                    }
                    if name == "." || name == ".." { continue }
                    count += 1
                    guard count <= 128 else { throw failure("publication_capacity", "Private publication ledger is full; no automatic eviction is performed.") }
                    if name == id.uuidString.lowercased() { found = true }
                    let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw failure() }
                    var file = stat()
                    if fstatat(child, "bytes", &file, AT_SYMLINK_NOFOLLOW) == 0 { total += max(0, file.st_size) }
                    close(child)
                    guard total <= ProjectArtifactReceipt.maximumAggregateBytes else { throw failure("publication_capacity", "Private staging exceeds 256 MiB.") }
                }
                guard found || count < 128 else { throw failure("publication_capacity", "Private publication ledger is full.") }
            }
        }
        return try body(parent)
    }

    static func openFile(_ name: String, at parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        var info = stat(), folder = stat()
        guard fstat(fd, &info) == 0, fstat(parent, &folder) == 0, info.st_dev == folder.st_dev,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid() else { close(fd); throw failure() }
        return fd
    }

    static func write(_ data: Data, name: String, at parent: Int32) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("publication_exists", "Publication staging already exists; unknown partial writes are never replayed.") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(ProjectArtifactReceipt.transferSeconds)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard Date() < deadline else { throw failure("publication_timeout", "Publication write deadline exceeded.") }
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(ProjectArtifactReceipt.chunkBytes, bytes.count - offset))
                if count < 0 { if errno == EINTR { continue }; throw failure() }
                guard count > 0 else { throw failure() }; offset += count
            }
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { throw failure() }
    }

    static func retained(_ id: UUID, beside url: URL) throws -> ProjectArtifactReceipt? {
        try withStore(id, beside: url, create: false, ifMissing: { nil }) { parent in
            // An existing identity, even an empty one, is an unknown prior write, not permission
            // to allocate again. Only absent directories mean there is no retained snapshot.
            let manifest = try manifest(at: parent)
            guard manifest.artifact.id == id else { throw failure() }
            return manifest.artifact
        }
    }

    static func stage(_ bytes: Data, receipt: ProjectArtifactReceipt, beside url: URL) throws {
        try receipt.validate()
        guard bytes.count == receipt.size, hash(bytes) == receipt.sha256 else { throw failure("publication_corrupt", "Publication digest or size mismatch.") }
        try withStore(receipt.id, beside: url, create: true, reserving: bytes.count) { parent in
            try write(bytes, name: "bytes", at: parent)
            let fd = try openFile("bytes", at: parent); defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw failure() }
            let manifest = Manifest(artifact: receipt, device: info.st_dev, inode: info.st_ino)
            try write(JSONEncoder().encode(manifest), name: "receipt.json", at: parent)
        }
    }

    static func chunk(_ receipt: ProjectArtifactReceipt, offset: Int64, beside url: URL) throws -> Data {
        guard offset >= 0, offset <= receipt.size else { throw failure("invalid_offset", "Publication offset is out of bounds.") }
        return try withStore(receipt.id, beside: url, create: false) { parent in
            let fd = try openFile("bytes", at: parent); defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size == receipt.size, lseek(fd, off_t(offset), SEEK_SET) == offset else { throw failure() }
            var data = Data(count: min(ProjectArtifactReceipt.chunkBytes, Int(receipt.size - offset)))
            let count = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard count == data.count else { throw failure() }
            return data
        }
    }

    static func manifest(at parent: Int32) throws -> Manifest {
        let fd = try openFile("receipt.json", at: parent); defer { close(fd) }
        let manifest = try JSONDecoder().decode(Manifest.self, from: readBounded(fd, limit: 8192))
        try manifest.artifact.validate()
        return manifest
    }

    static func writeReady(_ receipt: ProjectArtifactReceipt, at staging: Int32) throws {
        var ready = receipt; ready.state = .ready
        var info = stat()
        if fstatat(staging, "ready.json", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            let fd = try openFile("ready.json", at: staging); defer { close(fd) }
            guard try JSONDecoder().decode(ProjectArtifactReceipt.self, from: readBounded(fd, limit: 8192)) == ready else { throw failure("publication_corrupt", "Ready receipt changed.") }
        } else {
            guard errno == ENOENT else { throw failure() }
            try write(JSONEncoder().encode(ready), name: "ready.json", at: staging)
        }
    }

    static func verifyCommitted(_ receipt: ProjectArtifactReceipt, beside url: URL) throws -> Bool {
        try withStore(receipt.id, beside: url, create: false) { staging in
            let manifest = try manifest(at: staging)
            var original = receipt; original.state = .staged
            guard manifest.artifact == original else { return false }
            // Covers a crash between rename and ready.json: the fsynced manifest plus the
            // original inode in the owner root proves the side effect without replaying it.
            var bytes = stat()
            guard fstatat(staging, "bytes", &bytes, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { return false }
            return try LogicalProjectDirectory.withArtifact(id: receipt.key.projectID, path: receipt.relativePath, beside: url, folder: false) { fd, info in
                guard info.st_dev == manifest.device, info.st_ino == manifest.inode else { return false }
                return try digest(fd, expectedSize: receipt.size) == receipt.sha256
            }
        }
    }

    /// Own descriptors across queue hops. No descriptor escapes to a caller that can close or
    /// reuse it; vnode events remember changes even if an attacker restores size and timestamps.
    final class PreparedCommit: @unchecked Sendable {
        fileprivate let receipt: ProjectArtifactReceipt
        fileprivate var staging: Int32 = -1, owner: Int32 = -1, bytes: Int32 = -1, record: Int32 = -1, events: Int32 = -1
        fileprivate var parents: [Int32] = []
        fileprivate var directories: [(parent: Int32, name: String, device: Int32, inode: UInt64)] = []
        fileprivate var original = stat()
        fileprivate var alreadyCommitted = false

        fileprivate init(_ receipt: ProjectArtifactReceipt) { self.receipt = receipt }
        deinit { for fd in [staging, owner, bytes, record, events] + parents where fd >= 0 { close(fd) } }

        fileprivate func watch(_ fd: Int32, changes: UInt32) throws {
            var event = kevent(ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
                               fflags: changes, data: 0, udata: nil)
            guard kevent(events, &event, 1, nil, 0, nil) == 0 else { throw failure() }
        }

        /// Bounded descriptor checks only. Called in the SAME state-queue turn as revalidation.
        func rename() throws {
            var current = stat(), named = stat(), event = kevent(), timeout = timespec()
            let parent = alreadyCommitted ? owner : staging
            let name = alreadyCommitted ? receipt.artifactName : "bytes"
            for directory in directories {
                guard fstatat(directory.parent, directory.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_dev == directory.device, named.st_ino == directory.inode,
                      named.st_mode & S_IFMT == S_IFDIR, named.st_mode & 0o777 == 0o700, named.st_uid == geteuid() else {
                    throw failure("publication_corrupt", "Prepared publication directory was replaced.")
                }
            }
            guard fstat(bytes, &current) == 0, unchanged(current, original),
                  fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, unchanged(named, original),
                  kevent(events, nil, 0, &event, 1, &timeout) == 0 else {
                throw failure("publication_corrupt", "Prepared publication changed; no artifact was committed.")
            }
            if alreadyCommitted { return }
            guard renameatx_np(staging, "bytes", owner, receipt.artifactName, UInt32(RENAME_EXCL)) == 0 else {
                throw failure(errno == EEXIST ? "artifact_collision" : "publication_file", "Artifact commit refused; no existing artifact was overwritten.")
            }
        }

        /// Hashing and durability stay off the state queue, including the recovery-only case.
        func finish() throws {
            var named = stat(), before = stat(), after = stat()
            guard fstat(bytes, &before) == 0,
                  try digest(bytes, expectedSize: receipt.size) == receipt.sha256,
                  fstat(bytes, &after) == 0, unchanged(before, after),
                  fstatat(owner, receipt.artifactName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  unchanged(named, after), after.st_dev == original.st_dev, after.st_ino == original.st_ino else {
                throw failure("publication_corrupt", "Publication changed during commit; no ready receipt was acknowledged.")
            }
            guard fsync(owner) == 0, fsync(staging) == 0 else { throw failure() }
            try writeReady(receipt, at: staging)
        }
    }

    private static func unchanged(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_nlink == 1 && b.st_nlink == 1
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    static func prepareCommit(_ receipt: ProjectArtifactReceipt, beside url: URL) throws -> PreparedCommit {
        try receipt.validate()
        return try withStore(receipt.id, beside: url, create: false) { staging in
            try LogicalProjectDirectory.withDirectory(id: receipt.key.projectID, beside: url) { owner, _ in
                let prepared = PreparedCommit(receipt)
                prepared.staging = fcntl(staging, F_DUPFD_CLOEXEC, 0)
                prepared.owner = fcntl(owner, F_DUPFD_CLOEXEC, 0)
                prepared.events = kqueue()
                guard prepared.staging >= 0, prepared.owner >= 0, prepared.events >= 0,
                      fcntl(prepared.events, F_SETFD, FD_CLOEXEC) == 0 else { throw failure() }
                let moved = UInt32(NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE | NOTE_ATTRIB)
                try prepared.watch(prepared.staging, changes: moved | UInt32(NOTE_WRITE))
                try prepared.watch(prepared.owner, changes: moved)
                // Watch the two private container directories as well: replacing an ancestor
                // must not redirect provenance while the leaf descriptors remain valid.
                for (leaf, name, container) in [(staging, receipt.id.uuidString.lowercased(), "project-publications"),
                                                (owner, receipt.key.projectID.rawValue, "logical-projects")] {
                    var child = leaf
                    for component in [name, container] {
                        let parent = openat(child, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard parent >= 0 else { throw failure() }
                        prepared.parents.append(parent)
                        var info = stat()
                        guard fstat(child, &info) == 0 else { throw failure() }
                        prepared.directories.append((parent, component, info.st_dev, info.st_ino))
                        try prepared.watch(parent, changes: moved)
                        child = parent
                    }
                }
                prepared.record = try openFile("receipt.json", at: staging)
                try prepared.watch(prepared.record, changes: moved | UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_LINK))
                let manifest = try JSONDecoder().decode(Manifest.self, from: readBounded(prepared.record, limit: 8192))
                guard manifest.artifact == receipt else { throw failure("publication_conflict", "Private manifest changed.") }
                var info = stat()
                if fstatat(owner, receipt.artifactName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard fstatat(staging, "bytes", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                        throw failure("artifact_collision", "Artifact name already exists; choose a new filename. Nothing was overwritten.")
                    }
                    prepared.alreadyCommitted = true
                } else if errno != ENOENT { throw failure() }
                prepared.bytes = try openFile(prepared.alreadyCommitted ? receipt.artifactName : "bytes",
                                              at: prepared.alreadyCommitted ? owner : staging)
                try prepared.watch(prepared.bytes, changes: moved | UInt32(NOTE_WRITE | NOTE_EXTEND | NOTE_LINK))
                guard fstat(prepared.bytes, &prepared.original) == 0,
                      prepared.original.st_dev == manifest.device, prepared.original.st_ino == manifest.inode,
                      try digest(prepared.bytes, expectedSize: receipt.size) == receipt.sha256 else {
                    throw failure("publication_corrupt", "Publication digest or inode mismatch.")
                }
                return prepared
            }
        }
    }

    /// Synchronous helper for offline recovery fixtures; live producers use the server's common
    /// commitPublication path so authority and rename cannot be separated by a queue hop.
    static func commit(_ receipt: ProjectArtifactReceipt, beside url: URL) throws {
        let prepared = try prepareCommit(receipt, beside: url)
        try prepared.rename()
        try prepared.finish()
    }
}
