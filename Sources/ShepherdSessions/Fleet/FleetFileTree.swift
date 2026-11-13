import Darwin
import Foundation
import ShepherdProtocol

/// The regular files under a folder, for the sources whose units are the files of a tree (a
/// skill, an extension). A link, a socket or a FIFO is never a unit: a link would make the
/// store read or write outside the folder it syncs.
enum FleetFileTree {
    struct File: Equatable {
        /// Relative to the folder it was found under ("scripts/run.sh").
        var relative: String
        var path: String
        var size: Int
        /// Modification time, in nanoseconds.
        var modified: Int64
        var executable: Bool
    }

    struct Limits {
        var files: Int
        var bytes: Int
    }

    /// What one skill may hold and still sync, and what one extension (with its `node_modules`) may.
    /// A tree over its limit is left to its own Mac: a unit per file would only slow every Mac down.
    static let skillLimits = Limits(files: 2_000, bytes: 32 << 20)
    static let extensionLimits = Limits(files: 10_000, bytes: 128 << 20)

    /// Names no tree syncs: version control and Finder's own files.
    static func isNoise(_ name: String) -> Bool { name == ".git" || name == ".DS_Store" }

    /// Every regular file under `root` (a single file is its own answer, relative "" ), sorted by
    /// path; nil when there are more than `limits` allow. A folder that can't be read counts as empty.
    /// `followingFileLinks` counts a link to a file as that file (as a copy of a folder of someone's
    /// own makes it), never a link to a folder.
    static func files(under root: String, skipping skipped: (String) -> Bool = isNoise, followingFileLinks: Bool = false,
                      limits: Limits) -> [File]? {
        var info = stat()
        guard lstat(root, &info) == 0 else { return [] }
        if (info.st_mode & S_IFMT) == S_IFREG {
            return Int(info.st_size) <= limits.bytes ? [file(root, relative: "", info)] : nil
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return [] }
        var found: [File] = []
        var bytes = 0
        guard walk(root, relative: "", skipping: skipped, links: followingFileLinks, limits: limits, into: &found, bytes: &bytes) else { return nil }
        return found.sorted { $0.relative < $1.relative }
    }

    private static func walk(_ folder: String, relative: String, skipping skipped: (String) -> Bool, links: Bool, limits: Limits,
                             into found: inout [File], bytes: inout Int) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for name in names where !skipped(name) {
            let path = folder + "/" + name
            let inner = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            if links, (info.st_mode & S_IFMT) == S_IFLNK {
                var target = stat()
                guard stat(path, &target) == 0, (target.st_mode & S_IFMT) == S_IFREG else { continue }
                info = target
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard walk(path, relative: inner, skipping: skipped, links: links, limits: limits, into: &found, bytes: &bytes) else { return false }
            case S_IFREG:
                bytes += Int(info.st_size)
                guard found.count < limits.files, bytes <= limits.bytes else { return false }
                found.append(file(path, relative: inner, info))
            default:
                continue
            }
        }
        return true
    }

    private static func file(_ path: String, relative: String, _ info: stat) -> File {
        File(relative: relative, path: path, size: Int(info.st_size),
             modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
             executable: info.st_mode & 0o111 != 0)
    }

    // MARK: Safe paths

    /// A relative path that stays inside its folder: no empty, `.` or `..` component, nothing absolute.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Writes `data` to `relative` under `folder`, by a temporary file and a rename, creating the
    /// folders between. Throws when the path would leave `folder` through a link. A file that was
    /// executable stays so, and a new one is when it starts with a `#!` line: the unit carries
    /// content, not a mode.
    static func write(_ data: Data, to relative: String, under folder: URL) throws {
        guard isSafe(relative) else { throw FleetUnitRefused(description: "\(relative) isn't a path inside its folder") }
        let target = folder.appendingPathComponent(relative)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireInside(parent, folder)
        var info = stat()
        if lstat(target.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
            throw FleetUnitRefused(description: "\(relative) is a link")
        }
        let executable = (lstat(target.path, &info) == 0 && info.st_mode & 0o111 != 0) || data.starts(with: [0x23, 0x21])
        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).fleet")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: executable ? 0o755 : 0o644]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, target.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Removes the file at `relative` under `folder` and any folder that leaves empty (up to, and
    /// not including, `folder`). A path that isn't there is already as wanted.
    static func remove(_ relative: String, under folder: URL) throws {
        guard isSafe(relative) else { throw FleetUnitRefused(description: "\(relative) isn't a path inside its folder") }
        var target = folder.appendingPathComponent(relative)
        try requireInside(target.deletingLastPathComponent(), folder)
        var info = stat()
        guard lstat(target.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR else { return }
        try FileManager.default.removeItem(at: target)
        let root = folder.standardizedFileURL.path
        while true {
            target = target.deletingLastPathComponent()
            guard target.standardizedFileURL.path != root, target.standardizedFileURL.path.hasPrefix(root + "/"),
                  (try? FileManager.default.contentsOfDirectory(atPath: target.path))?.isEmpty == true else { return }
            try FileManager.default.removeItem(at: target)
        }
    }

    /// `folder` is `root` or under it once links are resolved.
    private static func requireInside(_ folder: URL, _ root: URL) throws {
        let inner = folder.resolvingSymlinksInPath().path, outer = root.resolvingSymlinksInPath().path
        guard inner == outer || inner.hasPrefix(outer + "/") else { throw FleetUnitRefused(description: "a path leaves its folder through a link") }
    }
}

/// Hashes files, remembering by size and modification time what it already read, so a scan of a
/// large tree reads only the files that changed. A file modified in the last two seconds is read
/// every time: a second write inside the clock's granularity must not hide behind the first.
final class FleetFileHasher {
    private struct Entry {
        var size: Int
        var modified: Int64
        var hash: String
    }

    private var cache: [String: Entry] = [:]
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    func hash(_ file: FleetFileTree.File) -> String? {
        if let entry = cache[file.path], entry.size == file.size, entry.modified == file.modified { return entry.hash }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path), options: .mappedIfSafe) else { return nil }
        let hash = FleetSyncProtocol.hash(data)
        let age = clock().timeIntervalSince1970 - Double(file.modified) / 1e9
        if age > 2 { cache[file.path] = Entry(size: file.size, modified: file.modified, hash: hash) }
        return hash
    }

    /// Forgets every file not in `paths`.
    func keep(_ paths: Set<String>) {
        if cache.count > paths.count { cache = cache.filter { paths.contains($0.key) } }
    }
}
