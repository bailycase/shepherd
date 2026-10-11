import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

/// Descriptor-relative creation refuses links at every component and never removes a directory.
/// Only the two new levels are created; the injected state parent must already exist.
enum LogicalProjectDirectory {
    static func create(id: ProjectID, beside stateURL: URL) throws {
        try withDirectory(id: id, beside: stateURL, create: true) { _, _ in () }
    }

    static func directory(id: ProjectID, beside stateURL: URL, create: Bool = false) throws -> URL {
        try withDirectory(id: id, beside: stateURL, create: create) { _, url in url }
    }

    /// Keep the private root pinned until all artifact I/O is complete.
    static func withDirectory<T>(id: ProjectID, beside stateURL: URL, create: Bool = false,
                                         body: (Int32, URL) throws -> T) throws -> T {
        guard Project.validID(id.rawValue) else {
            throw LogicalProjectsError("invalid_project", "Invalid project ID.")
        }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw failure() }
        defer { close(parent) }
        // The injected state parent is trusted (macOS itself aliases /tmp and /var). Pin its
        // canonical location, then walk descriptors; no link below it is ever followed.
        guard let resolved = realpath(stateURL.deletingLastPathComponent().path, nil) else { throw failure() }
        defer { free(resolved) }
        // Foundation normalizes some /private aliases back to symlinked /var and /tmp.
        let components = String(cString: resolved).split(separator: "/").map(String.init)
        for component in components {
            guard component != ".", component != ".." else {
                throw LogicalProjectsError("project_directory", "Invalid state directory path.")
            }
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure() }
            close(parent)
            parent = next
        }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0 else { throw failure() }
        if create, mkdirat(parent, "logical-projects", 0o700) != 0, errno != EEXIST { throw failure() }
        let root = openat(parent, "logical-projects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw failure() }
        defer { close(root) }
        // A preexisting shared/writable root is not ours to silently chmod or adopt.
        var info = stat()
        guard fstat(root, &info) == 0, info.st_dev == parentInfo.st_dev, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
            throw LogicalProjectsError("project_directory", "Logical project root must be private and owned by this user.")
        }
        if create, mkdirat(root, id.rawValue, 0o700) != 0 {
            if errno == EEXIST {
                throw LogicalProjectsError("project_directory_exists", "Project directory already exists; it was retained and will not be adopted or removed.")
            }
            throw failure()
        }
        let child = openat(root, id.rawValue, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw failure() }
        defer { close(child) }
        guard fstat(child, &info) == 0, info.st_dev == parentInfo.st_dev,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw failure() }
        return try body(child, URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("logical-projects").appendingPathComponent(id.rawValue))
    }

    /// Hidden entries are internal context/configuration, not published artifacts. Log and
    /// session files are also excluded, including direct reads, rather than dumped into Files.
    private static func isArtifact(_ name: String) -> Bool {
        !name.hasPrefix(".") && !["logs", "sessions", "auth.json", "settings.json"].contains(name.lowercased())
            && !["log", "jsonl"].contains((name as NSString).pathExtension.lowercased())
    }

    private static func components(_ path: String) throws -> [String] {
        guard path.utf8.count <= 1024, !path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw LogicalProjectsError("invalid_path", "Use a bounded owner-relative artifact path.")
        }
        if path.isEmpty { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 && isArtifact($0) }) else {
            throw LogicalProjectsError("invalid_path", "Path is not a published artifact.")
        }
        return parts
    }

    static func withArtifact<T>(id: ProjectID, path: String, beside stateURL: URL, folder: Bool,
                                        body: (Int32, stat) throws -> T) throws -> T {
        let parts = try components(path)
        guard folder || !parts.isEmpty else { throw LogicalProjectsError("invalid_path", "Choose an artifact file.") }
        return try withDirectory(id: id, beside: stateURL) { root, _ in
            var fd = fcntl(root, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else { throw failure() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw failure() }
            let device = info.st_dev
            for (index, name) in parts.enumerated() {
                let directory = folder || index < parts.count - 1
                // NONBLOCK avoids hanging on a substituted FIFO/device before fstat rejects it.
                let next = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
                guard next >= 0 else { throw failure() }
                close(fd); fd = next
                guard fstat(fd, &info) == 0, info.st_dev == device,
                      info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
                      directory || info.st_nlink == 1 else { throw failure() }
            }
            return try body(fd, info)
        }
    }

    static func files(id: ProjectID, path: String, beside stateURL: URL, receipts: [ProjectArtifactReceipt] = []) throws -> LogicalProjectsResult {
        try withArtifact(id: id, path: path, beside: stateURL, folder: true) { fd, folder in
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard copy >= 0 else { throw failure() }
            guard let stream = fdopendir(copy) else { close(copy); throw failure() }
            defer { closedir(stream) }
            var entries: [LogicalProjectFileEntry] = []
            var scanned = 0, encodedBudget = 512 * 1024, truncated = false
            // Bound scanned entries as well as published entries (even a directory full of logs).
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { throw failure() }
                    break
                }
                if scanned == 4096 { truncated = true; break }
                scanned += 1
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingCString: $0) }
                }
                guard let name else { truncated = true; continue }
                guard isArtifact(name) else { continue }
                let relative = path.isEmpty ? name : path + "/" + name
                guard relative.utf8.count <= 1024 else { truncated = true; continue }
                var info = stat()
                guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { truncated = true; continue }
                guard info.st_dev == folder.st_dev else { continue }
                let kind: LogicalProjectFileEntry.Kind
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = .folder
                case S_IFREG where info.st_nlink == 1: kind = .file
                default: continue
                }
                let cost = (name.utf8.count + relative.utf8.count) * 6 + 256
                if entries.count == LogicalProjectFileListing.maximumEntries || cost > encodedBudget { truncated = true; break }
                encodedBudget -= cost
                let receipt = receipts.first { $0.state == .ready && $0.relativePath == relative && $0.size == info.st_size }
                // A receipt alone cannot attribute bytes subsequently replaced outside this API.
                let verified = receipt.flatMap { receipt in
                    (try? ProjectPublicationFiles.verifyCommitted(receipt, beside: stateURL)) == true ? receipt.taskID : nil
                }
                entries.append(.init(name: name, relativePath: relative, kind: kind, size: Int64(info.st_size),
                                     modifiedAt: Double(info.st_mtimespec.tv_sec) * 1000 + Double(info.st_mtimespec.tv_nsec) / 1_000_000,
                                     taskID: verified))
            }
            return .files(.init(projectID: id, path: path, entries: entries.sorted { $0.name < $1.name }, truncated: truncated))
        }
    }

    static func read(id: ProjectID, path: String, beside stateURL: URL) throws -> LogicalProjectsResult {
        try withArtifact(id: id, path: path, beside: stateURL, folder: false) { fd, info in
            let limit = LogicalProjectFile.maximumBytes
            guard info.st_size <= limit else { throw LogicalProjectsError("file_too_large", "Artifact exceeds the 256 KiB preview limit.") }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while bytes.count <= limit {
                let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - bytes.count))
                if count < 0 { if errno == EINTR { continue }; throw failure() }
                if count == 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            guard bytes.count <= limit else { throw LogicalProjectsError("file_too_large", "Artifact grew beyond the preview limit.") }
            let mime: String
            if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { mime = "image/png" }
            else if bytes.starts(with: [255, 216, 255]) { mime = "image/jpeg" }
            else if let text = String(data: bytes, encoding: .utf8),
                    !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) }) { mime = "text/plain; charset=utf-8" }
            else { throw LogicalProjectsError("unsupported_file", "Only UTF-8 text, PNG and JPEG previews are available.") }
            return .file(.init(projectID: id, relativePath: path, mimeType: mime, data: bytes))
        }
    }

    private static func failure() -> LogicalProjectsError {
        LogicalProjectsError("project_directory", "Cannot access a private owner-local Project directory or regular artifact file.")
    }
}
