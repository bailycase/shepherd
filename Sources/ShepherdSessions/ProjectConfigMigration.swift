import Foundation
import Darwin
import ShepherdProtocol

/// No-follow, bounded copy. The source stays terminal Pi's configuration; only the complete
/// staged directory becomes visible to Shepherd, and an existing destination is never replaced.
enum ProjectConfigMigration {
    static let entryLimit = 10_000
    static let byteLimit = 64 * 1024 * 1024
    static let fileLimit = 16 * 1024 * 1024
    static let depthLimit = 16
    static let timeLimit: TimeInterval = 10

    static func copy(in root: URL, deadline: Date = Date().addingTimeInterval(timeLimit)) throws {
        let failure = ProjectFileError("config_migration", "Could not copy this project's .pi configuration to .shepherd. The original is unchanged. Check file permissions, symbolic links and size limits, then retry.")
        // Walk the physical project path without allowing any component to become a symlink.
        guard let physical = realpath(root.path, nil) else { throw failure }
        defer { free(physical) }
        guard URL(fileURLWithPath: String(cString: physical)).resolvingSymlinksInPath().path == root.path else { throw failure }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure }
        defer { close(parent) }
        for part in String(cString: physical).split(separator: "/") {
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw failure }
            close(parent); parent = next
        }
        var info = stat()
        if fstatat(parent, ".shepherd", &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw failure }
            return
        }
        guard errno == ENOENT else { throw failure }
        if fstatat(parent, ".pi", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw failure
        }
        let source = openat(parent, ".pi", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw failure }
        defer { close(source) }
        let temporary = ".shepherd-migration-" + UUID().uuidString
        guard mkdirat(parent, temporary, 0o700) == 0 else { throw failure }
        let target = openat(parent, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { unlinkat(parent, temporary, AT_REMOVEDIR); throw failure }
        var staged = true
        defer {
            if staged { removeContents(target); unlinkat(parent, temporary, AT_REMOVEDIR) }
            close(target)
        }
        var entries = 0, bytes = 0
        try copyDirectory(source, target, depth: 0, entries: &entries, bytes: &bytes, deadline: deadline, failure: failure)
        guard Date() < deadline, fstat(source, &info) == 0, fchmod(target, info.st_mode & 0o777) == 0 else { throw failure }
        // RENAME_EXCL also protects a destination created while the copy was running.
        if renameatx_np(parent, temporary, parent, ".shepherd", UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST, fstatat(parent, ".shepherd", &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else { throw failure }
        } else { staged = false }
    }

    private static func names(_ fd: Int32) throws -> [String] {
        guard let directory = fdopendir(dup(fd)) else { throw ProjectFileError("config_migration", "Could not read project configuration.") }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
            guard result.count <= entryLimit else { throw ProjectFileError("config_migration", "Project configuration exceeds the migration entry limit.") }
            errno = 0
        }
        guard errno == 0 else { throw ProjectFileError("config_migration", "Could not read project configuration.") }
        return result
    }

    private static func copyDirectory(_ source: Int32, _ target: Int32, depth: Int, entries: inout Int, bytes: inout Int,
                                      deadline: Date, failure: ProjectFileError) throws {
        guard depth <= depthLimit else { throw failure }
        for name in try names(source) {
            entries += 1
            guard entries <= entryLimit, Date() < deadline else { throw failure }
            var info = stat()
            guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure }
            if info.st_mode & S_IFMT == S_IFDIR {
                let input = openat(source, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw failure }
                defer { close(input) }
                guard mkdirat(target, name, 0o700) == 0 else { throw failure }
                let output = openat(target, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard output >= 0 else { throw failure }
                defer { close(output) }
                try copyDirectory(input, output, depth: depth + 1, entries: &entries, bytes: &bytes, deadline: deadline, failure: failure)
                guard fchmod(output, info.st_mode & 0o777) == 0 else { throw failure }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG else { throw failure }
                let input = openat(source, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard input >= 0 else { throw failure }
                let handle = FileHandle(fileDescriptor: input, closeOnDealloc: true)
                defer { try? handle.close() }
                guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size <= fileLimit else { throw failure }
                var data = Data()
                while let chunk = try handle.read(upToCount: min(64 * 1024, fileLimit + 1 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= fileLimit, bytes + data.count <= byteLimit, Date() < deadline else { throw failure }
                }
                guard data.count == info.st_size else { throw failure }
                bytes += data.count
                let output = openat(target, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw failure }
                let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
                defer { try? writer.close() }
                try writer.write(contentsOf: data)
                try writer.synchronize()
                guard fchmod(output, info.st_mode & 0o777) == 0 else { throw failure }
            }
        }
    }

    private static func removeContents(_ fd: Int32) {
        _ = fchmod(fd, 0o700)
        for name in (try? names(fd)) ?? [] {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child >= 0 { removeContents(child); close(child); unlinkat(fd, name, AT_REMOVEDIR) }
            else { unlinkat(fd, name, 0) }
        }
    }
}
