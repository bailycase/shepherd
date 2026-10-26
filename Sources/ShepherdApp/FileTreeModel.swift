import Foundation
import Observation

// MARK: - POSIX helpers

/// Canonical realpath via C realpath(3). Unlike Foundation's `resolvingSymlinksInPath`,
/// this always resolves `/tmp` → `/private/tmp` and `/var` → `/private/var` on macOS,
/// matching what the kernel returns from F_GETPATH on open descriptors.
private func canonicalRealpath(_ path: String) -> String? {
    path.withCString { cPath in
        guard let resolved = Darwin.realpath(cPath, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Containment check: `child` is within `root` (both canonical).
private func isContained(_ child: String, in root: String) -> Bool {
    if child == root { return true }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return child.hasPrefix(prefix)
}

// MARK: - File node

/// A node in the lazy file tree. Folders load children on first expansion.
/// All IO runs off-main via `FileTreeModel`; this is a value snapshot.
struct FileNode: Identifiable, Equatable {
    let id: String          // full path
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    /// nil until the folder has been expanded at least once.
    var children: [FileNode]?
    var isLoading: Bool = false
    var error: String?
    /// File size in bytes; populated for regular files only.
    var fileSize: Int64?
    /// Line count, populated after the file content is read.
    var lineCount: Int?

    var isExpanded: Bool { children != nil }
}

// MARK: - Open file tab

/// One open file tab in the viewer.
struct OpenFileTab: Identifiable, Equatable {
    let id: String   // full path
    let name: String
}

// MARK: - Model

/// Async file-tree model scoped to one space root. Loads lazily, avoids
/// symlink cycles, blocks special files, and never does recursive IO.
///
/// Concurrency: all filesystem work dispatches to a detached task so the
/// caller (MainActor) never blocks. Results are applied on MainActor.
/// The model is `@Observable` per project rules (never ObservableObject).
@MainActor @Observable
final class FileTreeModel {
    // MARK: Public state

    /// The space root this tree is scoped to.
    let rootPath: String
    /// Canonical (C realpath) root for containment checks. Matches F_GETPATH.
    let resolvedRoot: String

    private(set) var root: FileNode
    var filter: String = ""
    var showHidden: Bool = false

    /// Bumped on every manual refresh so the file viewer re-reads.
    private(set) var refreshGeneration: UInt = 0

    /// The currently selected file path, or nil.
    private(set) var selectedPath: String? {
        didSet {
            // Keep tabs in sync: selected tab must exist
            if let path = selectedPath, !openTabs.contains(where: { $0.id == path }) {
                let name = (path as NSString).lastPathComponent
                openTabs.append(OpenFileTab(id: path, name: name))
            }
        }
    }

    /// Open file tabs in the viewer, ordered by open time.
    private(set) var openTabs: [OpenFileTab] = []

    /// The loaded content of the selected file (lines for text, data for images).
    private(set) var selectedContent: FileContent?

    /// Error loading the selected file.
    private(set) var selectedError: String?

    /// Whether the selected file is loading.
    private(set) var selectedLoading: Bool = false

    // MARK: Private

    /// Paths currently expanded, persisted across reloads.
    @ObservationIgnored private var expandedPaths: Set<String> = []

    /// Unique token for each selection change or file read, including refreshes.
    @ObservationIgnored private var selectionGeneration: UInt = 0

    /// Per-directory expansion generation: bumped on collapse/refresh so a pending
    /// expand that started before can't overwrite a newer tree state.
    @ObservationIgnored private var treeRevision: UInt = 0

    @ObservationIgnored private var expandGeneration: [String: UInt] = [:]

    // MARK: Init

    init(rootPath: String) {
        let expanded = (rootPath as NSString).expandingTildeInPath
        let real = canonicalRealpath(expanded) ?? expanded
        self.rootPath = expanded
        self.resolvedRoot = real
        self.root = FileNode(
            id: expanded,
            name: URL(fileURLWithPath: expanded).lastPathComponent,
            isDirectory: true,
            isSymlink: false
        )
    }

    // MARK: - Tree operations

    func loadRoot() async {
        guard root.children == nil, !root.isLoading else { return }
        await expand(path: rootPath)
    }

    func expand(path: String) async {
        guard findNode(path: path, in: root) != nil else { return }

        let revision = treeRevision
        // Bump generation for this path
        let gen = (expandGeneration[path] ?? 0) &+ 1
        expandGeneration[path] = gen

        updateNode(path: path) { $0.isLoading = true; $0.error = nil }

        let resolvedRoot = self.resolvedRoot
        let showHidden = self.showHidden
        let work = Task.detached(priority: .userInitiated) {
            Self.listDirectory(path: path, resolvedRoot: resolvedRoot, showHidden: showHidden)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }

        // Stale: a collapse or refresh bumped the generation while we were loading
        guard treeRevision == revision, expandGeneration[path] == gen else { return }
        // Node may have been removed by a refresh
        guard findNode(path: path, in: root) != nil else { return }
        guard !Task.isCancelled else {
            updateNode(path: path) { $0.isLoading = false }
            return
        }

        switch result {
        case .success(let children):
            expandedPaths.insert(path)
            updateNode(path: path) {
                $0.children = children
                $0.isLoading = false
            }
        case .failure(let error):
            updateNode(path: path) {
                $0.children = []
                $0.isLoading = false
                $0.error = error.localizedDescription
            }
        }
    }

    func collapse(path: String) {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        expandedPaths = expandedPaths.filter { $0 != path && !$0.hasPrefix(prefix) }
        for key in expandGeneration.keys where key == path || key.hasPrefix(prefix) {
            expandGeneration[key, default: 0] &+= 1
        }
        updateNode(path: path) { $0.children = nil; $0.isLoading = false }
    }

    func toggle(path: String) async {
        if expandedPaths.contains(path) {
            collapse(path: path)
        } else {
            await expand(path: path)
        }
    }

    func refresh() async {
        refreshGeneration &+= 1
        treeRevision &+= 1
        let revision = treeRevision
        selectionGeneration &+= 1
        // Re-expand previously expanded paths, sorted parent-first so
        // nested descendants find their parents already loaded.
        let sorted = expandedPaths.union([rootPath]).sorted()
        // Reset root and all generations
        root = FileNode(id: rootPath, name: root.name, isDirectory: true, isSymlink: false)
        expandedPaths.removeAll()
        expandGeneration.removeAll()

        for path in sorted {
            guard treeRevision == revision, !Task.isCancelled else { return }
            await expand(path: path)
        }
        guard treeRevision == revision, !Task.isCancelled else { return }
        // Re-read selected file
        if let sel = selectedPath {
            await loadFile(at: sel)
        }
    }

    // MARK: - Tab management

    func closeTab(_ path: String) async {
        openTabs.removeAll { $0.id == path }
        if selectedPath == path {
            await select(path: openTabs.last?.id)
        }
    }

    /// Remove tabs for files that no longer exist under the current root.
    func pruneStale() async {
        let root = self.resolvedRoot
        let tabs = openTabs
        let stale = await Task.detached {
            Set(tabs.compactMap { tab -> String? in
                guard let real = canonicalRealpath(tab.id), isContained(real, in: root) else { return tab.id }
                return nil
            })
        }.value
        openTabs.removeAll { stale.contains($0.id) }
        if let sel = selectedPath, !openTabs.contains(where: { $0.id == sel }) {
            await select(path: openTabs.last?.id)
        }
    }

    // MARK: - File selection

    func select(path: String?) async {
        guard selectedPath != path else { return }
        selectedPath = path
        selectionGeneration &+= 1
        selectedContent = nil
        guard let path else {
            selectedError = nil
            selectedLoading = false
            return
        }
        await loadFile(at: path)
    }

    private func loadFile(at path: String) async {
        guard path == selectedPath else { return }
        selectionGeneration &+= 1
        let gen = selectionGeneration
        selectedLoading = true
        selectedError = nil

        let resolvedRoot = self.resolvedRoot
        let work = Task.detached(priority: .userInitiated) {
            Self.safeReadFile(path: path, resolvedRoot: resolvedRoot)
        }
        let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }

        // Cancelled by a newer selection
        guard gen == selectionGeneration, selectedPath == path else { return }

        selectedLoading = false
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let content):
            selectedContent = content
            if case .text(let lines, _) = content {
                updateNode(path: path) { $0.lineCount = lines.count }
            }
        case .failure(let error):
            selectedContent = nil
            selectedError = error.localizedDescription
        }
    }

    // MARK: - Tree navigation

    private func findNode(path: String, in node: FileNode) -> FileNode? {
        if node.id == path { return node }
        guard let children = node.children else { return nil }
        for child in children {
            if let found = findNode(path: path, in: child) { return found }
        }
        return nil
    }

    private func updateNode(path: String, transform: (inout FileNode) -> Void) {
        root = Self.applyUpdate(to: root, path: path, transform: transform)
    }

    private static func applyUpdate(to node: FileNode, path: String, transform: (inout FileNode) -> Void) -> FileNode {
        if node.id == path {
            var copy = node
            transform(&copy)
            return copy
        }
        guard var children = node.children else { return node }
        var changed = false
        for i in children.indices {
            let updated = applyUpdate(to: children[i], path: path, transform: transform)
            if updated != children[i] {
                children[i] = updated
                changed = true
            }
        }
        guard changed else { return node }
        var copy = node
        copy.children = children
        return copy
    }

    /// Flat list of visible nodes for rendering, with depth info.
    func visibleNodes() -> [(node: FileNode, depth: Int)] {
        guard root.isExpanded else { return [] }
        var result: [(FileNode, Int)] = []
        let lowFilter = filter.lowercased()
        collectVisible(node: root, depth: -1, filter: lowFilter, result: &result)
        return result
    }

    private func collectVisible(node: FileNode, depth: Int, filter: String, result: inout [(FileNode, Int)]) {
        if depth >= 0 {
            if !filter.isEmpty && !node.isDirectory && !node.name.lowercased().contains(filter) {
                return
            }
            result.append((node, depth))
        }
        guard let children = node.children else { return }
        for child in children {
            collectVisible(node: child, depth: depth + 1, filter: filter, result: &result)
        }
    }

    // MARK: - File content

    /// Maximum file size to read (2 MB for text, 8 MB for images).
    nonisolated static let maxTextSize: Int64 = 2 * 1024 * 1024
    nonisolated static let maxImageSize: Int64 = 8 * 1024 * 1024

    /// Bound total scanned entries, including hidden and unsupported entries.
    nonisolated static let maxDirectoryEntries = 10_000

    /// Image extensions we'll attempt to preview.
    nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "ico", "heic", "heif"]

    /// Read file content safely using descriptor-based IO to avoid TOCTOU races.
    /// Opens with O_NONBLOCK, then fstat on the descriptor to verify regular file
    /// and containment via F_GETPATH before reading. Uses chunked read loop
    /// and reads max+1 bytes to detect unexpected growth.
    private nonisolated static func safeReadFile(path: String, resolvedRoot: String) -> Result<FileContent, FileTreeError> {
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = imageExtensions.contains(ext)
        let maxSize = isImage ? maxImageSize : maxTextSize

        // Open with O_RDONLY | O_NONBLOCK to avoid blocking on FIFOs/devices
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            return .failure(.readFailed(String(cString: strerror(errno))))
        }
        defer { close(fd) }

        // fstat on the open descriptor — no TOCTOU race
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            return .failure(.readFailed("fstat failed"))
        }

        // Must be a regular file
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .failure(.specialFile)
        }

        // Containment via F_GETPATH on the open descriptor: the kernel resolves
        // the fd's actual canonical path, defeating post-open symlink tricks and
        // matching our canonicalRealpath-based root.
        var fdPathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &fdPathBuf) == 0 else {
            return .failure(.readFailed("Cannot resolve fd path"))
        }
        let fdRealPath = String(cString: fdPathBuf)
        guard isContained(fdRealPath, in: resolvedRoot) else {
            return .failure(.outsideRoot)
        }

        let size = Int64(st.st_size)
        guard size <= maxSize else {
            return .failure(.tooLarge(size))
        }

        // Clear O_NONBLOCK now that we know it's a regular file
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }

        let length = Int(size)
        // Chunked read loop: read up to max+1 to detect growth.
        // Handles EINTR and short reads.
        let limit = Int(maxSize) + 1
        var data = Data()
        data.reserveCapacity(min(length, limit))
        let chunkSize = 64 * 1024
        var totalRead = 0

        while totalRead < limit {
            if Task.isCancelled { return .failure(.readFailed("File load cancelled")) }
            let toRead = min(chunkSize, limit - totalRead)
            var chunk = [UInt8](repeating: 0, count: toRead)
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                Darwin.read(fd, buf.baseAddress!, toRead)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .failure(.readFailed(String(cString: strerror(errno))))
            }
            if n == 0 { break } // EOF
            data.append(contentsOf: chunk.prefix(n))
            totalRead += n
        }

        // File grew past max since fstat
        if totalRead > Int(maxSize) {
            return .failure(.tooLarge(Int64(totalRead)))
        }

        if isImage {
            return .success(.image(data))
        }

        // Binary detection: reject if data contains NUL or excessive control chars
        if isBinaryData(data) {
            return .failure(.binaryFile)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.binaryFile)
        }

        if data.isEmpty { return .success(.text([], ext)) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return .success(.text(lines, ext))
    }

    /// Reject NUL anywhere; scan the first 8KB for excessive control characters.
    private nonisolated static func isBinaryData(_ data: Data) -> Bool {
        if data.contains(0) { return true }
        let scanLen = min(data.count, 8192)
        guard scanLen > 0 else { return false }
        var controlCount = 0
        for i in 0..<scanLen {
            let byte = data[i]
            // Control chars except tab, newline, carriage return
            if byte < 32 && byte != 9 && byte != 10 && byte != 13 {
                controlCount += 1
            }
        }
        // More than 10% control chars suggests binary
        return controlCount > scanLen / 10
    }

    // MARK: - Directory listing

    /// List a directory's contents using descriptor-based enumeration.
    /// Opens the directory with O_DIRECTORY, verifies containment via F_GETPATH
    /// on the descriptor (defeating a replacement-with-symlink between path
    /// resolution and opendir), then enumerates its children.
    /// Node IDs use the original `path` so tree lookups match the caller's paths.
    private nonisolated static func listDirectory(path: String, resolvedRoot: String, showHidden: Bool) -> Result<[FileNode], FileTreeError> {
        // Open the directory itself as a descriptor to verify containment
        let dirFd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFd >= 0 else {
            return .failure(.listFailed(String(cString: strerror(errno))))
        }

        // Verify the opened directory is within root via F_GETPATH
        var dirPathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathOK = fcntl(dirFd, F_GETPATH, &dirPathBuf) == 0
        let dirRealPath = pathOK ? String(cString: dirPathBuf) : ""
        // fdopendir takes ownership only on success.
        guard let directory = fdopendir(dirFd) else {
            close(dirFd)
            return .failure(.listFailed(String(cString: strerror(errno))))
        }
        defer { closedir(directory) }

        guard pathOK else {
            return .failure(.listFailed("Cannot resolve directory path"))
        }
        guard isContained(dirRealPath, in: resolvedRoot) else {
            return .failure(.outsideRoot)
        }

        // Resolve every display ancestor: aliases can jump to siblings, so a
        // lexical prefix comparison of the current target misses cycles.
        var ancestors: Set<String> = [dirRealPath]
        var ancestor = path
        while ancestor != "/" && !ancestor.isEmpty {
            if let canonical = canonicalRealpath(ancestor), isContained(canonical, in: resolvedRoot) {
                ancestors.insert(canonical)
            }
            ancestor = (ancestor as NSString).deletingLastPathComponent
        }

        var nodes: [FileNode] = []
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
            let isSymlink = (lst.st_mode & S_IFMT) == S_IFLNK
            let kind = lst.st_mode & S_IFMT
            if kind != S_IFLNK && kind != S_IFREG && kind != S_IFDIR { continue }
            let target = openat(dirFd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (isSymlink ? 0 : O_NOFOLLOW))
            guard target >= 0 else {
                if errno == ENOENT || errno == ELOOP { continue }
                // An unreadable child must not hide its readable siblings. Its eventual
                // selection still goes through the descriptor-validated read boundary.
                let message = String(cString: strerror(errno))
                var node = FileNode(id: path.hasSuffix("/") ? path + name : path + "/" + name,
                                    name: name, isDirectory: kind == S_IFDIR,
                                    isSymlink: isSymlink, fileSize: kind == S_IFREG ? Int64(lst.st_size) : nil)
                node.error = message
                nodes.append(node)
                continue
            }
            defer { close(target) }
            var st = stat()
            guard fstat(target, &st) == 0 else {
                return .failure(.listFailed(String(cString: strerror(errno))))
            }
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if !isDir && (st.st_mode & S_IFMT) != S_IFREG { continue }
            var targetPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(target, F_GETPATH, &targetPath) == 0 else {
                return .failure(.listFailed("Cannot resolve entry path"))
            }
            let canonical = String(cString: targetPath)
            guard isContained(canonical, in: resolvedRoot) else { continue }
            if isDir && ancestors.contains(canonical) { continue }
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            nodes.append(FileNode(id: fullPath, name: name, isDirectory: isDir,
                                  isSymlink: isSymlink, fileSize: isDir ? nil : Int64(st.st_size)))
        }

        // Sort: directories first, then alphabetically case-insensitive
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return .success(nodes)
    }
}

// MARK: - Content and errors

/// What a file contains, after reading.
enum FileContent: Equatable {
    /// Text lines and the file extension (for syntax highlighting).
    case text([String], String)
    /// Raw image data.
    case image(Data)
}

/// Errors from tree and file operations.
enum FileTreeError: LocalizedError {
    case outsideRoot
    case specialFile
    case tooLarge(Int64)
    case binaryFile
    case readFailed(String)
    case listFailed(String)

    var errorDescription: String? {
        switch self {
        case .outsideRoot: "File is outside the space root"
        case .specialFile: "Cannot read special files (devices, FIFOs)"
        case .tooLarge(let size): "File too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
        case .binaryFile: "Binary file (not UTF-8 text)"
        case .readFailed(let msg): msg
        case .listFailed(let msg): msg
        }
    }
}
