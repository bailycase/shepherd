import Foundation

// A thread's folder, read-only (docs/design/side-pane-files.md): the Mac's Files pane reads a local
// thread's folder with it, and a host's server answers a remote viewer's `RemoteAgentQuery.files`
// and `.fileRead` (`files.v1`) with it, for the thread's folder on its own disk.

/// One entry of a listed folder.
public struct ThreadFileEntry: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case file, directory }
    public var name: String
    public var kind: Kind
    /// Bytes; regular files only.
    public var size: Int64?
    /// The entry is a symlink (its target stays inside the folder).
    public var symlink: Bool?
    /// The entry could not be opened (permissions); its siblings still list.
    public var error: String?

    public init(name: String, kind: Kind, size: Int64? = nil, symlink: Bool = false, error: String? = nil) {
        self.name = name
        self.kind = kind
        self.size = size
        self.symlink = symlink ? true : nil
        self.error = error
    }

    public var isDirectory: Bool { kind == .directory }
    public var isSymlink: Bool { symlink == true }
}

/// A folder's entries, folders first then by name. `truncated`: the host stopped at
/// `ThreadFilesLimits.listedEntries` or `listingBytes`.
public struct ThreadFileListing: Codable, Hashable, Sendable {
    public var entries: [ThreadFileEntry]
    public var truncated: Bool

    public init(entries: [ThreadFileEntry], truncated: Bool = false) {
        self.entries = entries
        self.truncated = truncated
    }
}

/// What `files.v1` serves at most. A listing scans at most `ThreadFileSystem.maxDirectoryEntries`
/// (the Mac pane's bound) and replies with at most `listedEntries` whose names fit `listingBytes`;
/// a read is a UTF-8 text file of at most `readBytes` (base64 of it stays far under the 1 MiB frame).
public enum ThreadFilesLimits {
    public static let listedEntries = 2_000
    public static let listingBytes = 512 * 1024
    public static let readBytes = 256 * 1024
}

/// Why a folder or file can't be read.
public enum ThreadFileError: Error, Equatable, Sendable, LocalizedError {
    case invalidPath
    case outsideRoot
    case notFound
    case notDirectory
    case specialFile
    case tooLarge(Int64)
    case binaryFile
    case readFailed(String)
    case listFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Paths are relative to the thread's folder, without “..”."
        case .outsideRoot: "File is outside the space root"
        case .notFound: "No such file or folder"
        case .notDirectory: "Not a folder"
        case .specialFile: "Cannot read special files (devices, FIFOs)"
        case .tooLarge(let size): "File too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
        case .binaryFile: "Binary file (not UTF-8 text)"
        case .readFailed(let message), .listFailed(let message): message
        }
    }

    /// The remote error code a host answers with.
    public var code: String {
        switch self {
        case .invalidPath: "invalid_path"
        case .outsideRoot: "outside_root"
        case .notFound: "not_found"
        case .notDirectory: "not_directory"
        case .specialFile: "special_file"
        case .tooLarge: "too_large"
        case .binaryFile: "binary"
        case .readFailed, .listFailed: "read_failed"
        }
    }
}

/// Descriptor-based, bounded reads of one root folder: never recursive, never a special file, and
/// containment is checked on the opened descriptor (`F_GETPATH`), so a symlink, or a swap to one
/// after the path was checked, cannot leave the root. A folder symlinked back into one of its own
/// ancestors is not listed (no cycles).
public enum ThreadFileSystem {
    /// Bound total scanned entries, including hidden and unsupported entries.
    public static let maxDirectoryEntries = 10_000
    /// The Mac pane's read bounds: 2 MB for text, 8 MB for images.
    public static let maxTextSize: Int64 = 2 * 1024 * 1024
    public static let maxImageSize: Int64 = 8 * 1024 * 1024
    /// Image extensions the Mac pane previews.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "heic", "heif"]

    /// Canonical realpath via C realpath(3). Unlike Foundation's `resolvingSymlinksInPath`, this
    /// always resolves `/tmp` → `/private/tmp` on macOS, matching F_GETPATH on open descriptors.
    public static func canonicalRealpath(_ path: String) -> String? {
        path.withCString { cPath in
            guard let resolved = realpath(cPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// `child` is `root` or inside it (both canonical).
    public static func isContained(_ child: String, in root: String) -> Bool {
        if child == root { return true }
        return child.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: Remote paths

    /// The path on disk of `relative` in `root`, for a remote request: relative only (no leading
    /// `/` or `~`, no `.` or `..` component, no NUL), every component inside the root, and no
    /// folder on the way that resolves to one before it (a symlink back to an ancestor). The read
    /// or listing then checks the opened descriptor again.
    public static func resolve(_ relative: String, in root: String) -> Result<String, ThreadFileError> {
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~"), !relative.contains("\0") else { return .failure(.invalidPath) }
        let parts = relative.split(separator: "/")
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return .failure(.invalidPath) }
        guard let realRoot = canonicalRealpath(root) else { return .failure(.notFound) }
        var path = root
        var chain = [realRoot]
        for part in parts {
            path += "/" + part
            guard let canonical = canonicalRealpath(path) else { return .failure(.notFound) }
            guard isContained(canonical, in: realRoot) else { return .failure(.outsideRoot) }
            guard !chain.contains(where: { isContained($0, in: canonical) }) else { return .failure(.outsideRoot) }
            chain.append(canonical)
        }
        return .success(path)
    }

    /// A remote listing of `relative` in `root`, cut to `ThreadFilesLimits`.
    public static func listing(_ relative: String, in root: String, showHidden: Bool) -> Result<ThreadFileListing, ThreadFileError> {
        resolve(relative, in: root).flatMap { path in
            guard let realRoot = canonicalRealpath(root) else { return .failure(.notFound) }
            return list(path: path, resolvedRoot: realRoot, showHidden: showHidden).map(capped)
        }
    }

    /// A remote read of `relative` in `root`: UTF-8 text of at most `ThreadFilesLimits.readBytes`.
    public static func text(_ relative: String, in root: String) -> Result<Data, ThreadFileError> {
        resolve(relative, in: root).flatMap { path in
            guard let realRoot = canonicalRealpath(root) else { return .failure(.notFound) }
            return read(path: path, resolvedRoot: realRoot, maxSize: Int64(ThreadFilesLimits.readBytes)).flatMap { data in
                decodeText(data) == nil ? .failure(.binaryFile) : .success(data)
            }
        }
    }

    /// The first entries that fit a reply: `listedEntries`, and names whose JSON (every escape
    /// counted) fits `listingBytes`.
    static func capped(_ entries: [ThreadFileEntry]) -> ThreadFileListing {
        var bytes = 0
        var kept: [ThreadFileEntry] = []
        for entry in entries {
            let escaped = entry.name.utf8.reduce(0) { $0 + ($1 < 0x20 ? 6 : ($1 == 0x22 || $1 == 0x5C) ? 2 : 1) }
            bytes += escaped + (entry.error?.utf8.count ?? 0) + 96
            guard kept.count < ThreadFilesLimits.listedEntries, bytes <= ThreadFilesLimits.listingBytes else {
                return ThreadFileListing(entries: kept, truncated: true)
            }
            kept.append(entry)
        }
        return ThreadFileListing(entries: kept)
    }

    // MARK: Reading

    /// Reads a regular file of at most `maxSize` bytes inside `resolvedRoot`. Opens with
    /// O_NONBLOCK (no blocking on FIFOs or devices), then fstat and F_GETPATH on the descriptor
    /// (no TOCTOU), and reads max+1 bytes to catch a file that grew since.
    public static func read(path: String, resolvedRoot: String, maxSize: Int64) -> Result<Data, ThreadFileError> {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return .failure(errno == ENOENT ? .notFound : .readFailed(String(cString: strerror(errno))))
        }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { return .failure(.readFailed("fstat failed")) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(.specialFile) }

        var fdPathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &fdPathBuf) == 0 else { return .failure(.readFailed("Cannot resolve fd path")) }
        guard isContained(String(cString: fdPathBuf), in: resolvedRoot) else { return .failure(.outsideRoot) }

        let size = Int64(st.st_size)
        guard size <= maxSize else { return .failure(.tooLarge(size)) }

        // Clear O_NONBLOCK now that we know it's a regular file.
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }

        let limit = Int(maxSize) + 1
        var data = Data()
        data.reserveCapacity(min(Int(size), limit))
        let chunkSize = 64 * 1024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        while data.count < limit {
            if Task.isCancelled { return .failure(.readFailed("File load cancelled")) }
            let toRead = min(chunkSize, limit - data.count)
            let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, toRead) }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(.readFailed(String(cString: strerror(errno))))
            }
            if n == 0 { break }
            data.append(contentsOf: chunk.prefix(n))
        }
        if data.count > Int(maxSize) { return .failure(.tooLarge(Int64(data.count))) }
        return .success(data)
    }

    /// The text of `data`, or nil for a binary file: a NUL anywhere, more than 10% control
    /// characters in the first 8 KB, or not UTF-8.
    public static func decodeText(_ data: Data) -> String? {
        if data.contains(0) { return nil }
        let scanLength = min(data.count, 8192)
        if scanLength > 0 {
            let controls = data.prefix(scanLength).reduce(0) { $0 + ($1 < 32 && $1 != 9 && $1 != 10 && $1 != 13 ? 1 : 0) }
            if controls > scanLength / 10 { return nil }
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Listing

    /// Lists a folder with descriptor-based enumeration: opens it with O_DIRECTORY and checks
    /// containment via F_GETPATH on the descriptor (defeating a swap to a symlink between path
    /// resolution and opendir). Entries are folders and regular files (through symlinks that stay
    /// inside), folders first, then by name.
    public static func list(path: String, resolvedRoot: String, showHidden: Bool) -> Result<[ThreadFileEntry], ThreadFileError> {
        let dirFd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFd >= 0 else {
            switch errno {
            case ENOENT: return .failure(.notFound)
            case ENOTDIR: return .failure(.notDirectory)
            default: return .failure(.listFailed(String(cString: strerror(errno))))
            }
        }

        var dirPathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathOK = fcntl(dirFd, F_GETPATH, &dirPathBuf) == 0
        let dirRealPath = pathOK ? String(cString: dirPathBuf) : ""
        // fdopendir takes ownership only on success.
        guard let directory = fdopendir(dirFd) else {
            close(dirFd)
            return .failure(.listFailed(String(cString: strerror(errno))))
        }
        defer { closedir(directory) }

        guard pathOK else { return .failure(.listFailed("Cannot resolve directory path")) }
        guard isContained(dirRealPath, in: resolvedRoot) else { return .failure(.outsideRoot) }

        // Resolve every display ancestor: aliases can jump to siblings, so a lexical prefix
        // comparison of the current target misses cycles.
        var ancestors: Set<String> = [dirRealPath]
        var ancestor = path
        while ancestor != "/" && !ancestor.isEmpty {
            if let canonical = canonicalRealpath(ancestor), isContained(canonical, in: resolvedRoot) {
                ancestors.insert(canonical)
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }

        var entries: [ThreadFileEntry] = []
        var scanned = 0
        while true {
            if Task.isCancelled { return .failure(.listFailed("Directory load cancelled")) }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { return .failure(.listFailed(String(cString: strerror(errno)))) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            scanned += 1
            guard scanned <= maxDirectoryEntries else {
                return .failure(.listFailed("Directory exceeds \(maxDirectoryEntries) entries"))
            }
            if !showHidden && name.hasPrefix(".") { continue }

            var lst = stat()
            guard fstatat(dirFd, name, &lst, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue } // Removed during enumeration.
                return .failure(.listFailed(String(cString: strerror(errno))))
            }
            let kind = lst.st_mode & S_IFMT
            let isSymlink = kind == S_IFLNK
            if kind != S_IFLNK && kind != S_IFREG && kind != S_IFDIR { continue }
            let target = openat(dirFd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (isSymlink ? 0 : O_NOFOLLOW))
            guard target >= 0 else {
                if errno == ENOENT || errno == ELOOP { continue }
                // An unreadable child must not hide its readable siblings. Its eventual selection
                // still goes through the descriptor-validated read boundary.
                entries.append(ThreadFileEntry(name: name, kind: kind == S_IFDIR ? .directory : .file,
                                               size: kind == S_IFREG ? Int64(lst.st_size) : nil, symlink: isSymlink,
                                               error: String(cString: strerror(errno))))
                continue
            }
            defer { close(target) }
            var st = stat()
            guard fstat(target, &st) == 0 else { return .failure(.listFailed(String(cString: strerror(errno)))) }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if !isDir && (st.st_mode & S_IFMT) != S_IFREG { continue }
            var targetPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(target, F_GETPATH, &targetPath) == 0 else { return .failure(.listFailed("Cannot resolve entry path")) }
            let canonical = String(cString: targetPath)
            guard isContained(canonical, in: resolvedRoot) else { continue }
            if isDir && ancestors.contains(canonical) { continue }
            entries.append(ThreadFileEntry(name: name, kind: isDir ? .directory : .file, size: isDir ? nil : Int64(st.st_size),
                                           symlink: isSymlink))
        }

        entries.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return .success(entries)
    }
}
