import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

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

// MARK: - Source

/// Where a tree reads: this Mac's disk, or a remote thread's host over `files.v1`. Paths are the
/// tree's own (absolute under `rootPath`); a remote source turns them into the host's relative ones.
struct FileTreeSource: Sendable {
    let list: @Sendable (_ path: String, _ showHidden: Bool) async -> Result<[ThreadFileEntry], FileTreeError>
    let read: @Sendable (_ path: String) async -> Result<FileContent, FileTreeError>

    /// This Mac's disk, inside `resolvedRoot`.
    static func local(resolvedRoot: String) -> FileTreeSource {
        FileTreeSource(list: { ThreadFileSystem.list(path: $0, resolvedRoot: resolvedRoot, showHidden: $1) },
                       read: { FileTreeModel.safeReadFile(path: $0, resolvedRoot: resolvedRoot) })
    }

    /// `path` in the tree (under `root`) as the host takes it: relative, "" for the root.
    static func relative(_ path: String, root: String) -> String {
        path == root ? "" : String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
    }

    /// A remote thread's folder `root` on its host, over `files.v1`: the tree's paths go to the host relative to
    /// it, and text comes back within `ThreadFilesLimits.readBytes` (images read as binary there).
    static func remote(root: String, agentID: AgentID, host: String,
                       client: @escaping @MainActor @Sendable () -> RemoteHostClient?) -> FileTreeSource {
        @Sendable func relative(_ path: String) -> String { Self.relative(path, root: root) }
        @Sendable func failure(_ error: Error) -> String {
            if case RemoteHostClientError.rejected(_, let message) = error { return message }
            return String(describing: error)
        }
        return FileTreeSource(list: { path, hidden in
            guard let client = await client() else { return .failure(.listFailed("\(host) is offline.")) }
            do { return .success(try await client.listFiles(agentID: agentID, path: relative(path), showHidden: hidden).entries) }
            catch { return .failure(.listFailed(failure(error))) }
        }, read: { path in
            guard let client = await client() else { return .failure(.readFailed("\(host) is offline.")) }
            do {
                let data = try await client.readFile(agentID: agentID, path: relative(path))
                return FileTreeModel.content(text: data, ext: (path as NSString).pathExtension.lowercased())
            } catch { return .failure(.readFailed(failure(error))) }
        })
    }
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

    @ObservationIgnored private let source: FileTreeSource

    // MARK: Init

    /// A tree of `rootPath`, read from `source` (nil: this Mac's disk).
    init(rootPath: String, source: FileTreeSource? = nil) {
        let expanded = (rootPath as NSString).expandingTildeInPath
        let real = ThreadFileSystem.canonicalRealpath(expanded) ?? expanded
        self.rootPath = expanded
        self.resolvedRoot = real
        self.source = source ?? .local(resolvedRoot: real)
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

        let source = self.source
        let showHidden = self.showHidden
        let work = Task.detached(priority: .userInitiated) {
            await source.list(path, showHidden).map { entries in
                entries.map { entry in
                    var node = FileNode(id: path.hasSuffix("/") ? path + entry.name : path + "/" + entry.name, name: entry.name,
                                        isDirectory: entry.isDirectory, isSymlink: entry.isSymlink, fileSize: entry.size)
                    node.error = entry.error
                    return node
                }
            }
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
                guard let real = ThreadFileSystem.canonicalRealpath(tab.id), ThreadFileSystem.isContained(real, in: root) else { return tab.id }
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

        let source = self.source
        let work = Task.detached(priority: .userInitiated) { await source.read(path) }
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

    nonisolated static let maxTextSize = ThreadFileSystem.maxTextSize
    nonisolated static let maxImageSize = ThreadFileSystem.maxImageSize
    nonisolated static let maxDirectoryEntries = ThreadFileSystem.maxDirectoryEntries
    nonisolated static let imageExtensions = ThreadFileSystem.imageExtensions

    /// A file on this Mac, through the shared descriptor-validated reader.
    nonisolated static func safeReadFile(path: String, resolvedRoot: String) -> Result<FileContent, FileTreeError> {
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = imageExtensions.contains(ext)
        return ThreadFileSystem.read(path: path, resolvedRoot: resolvedRoot, maxSize: isImage ? maxImageSize : maxTextSize)
            .flatMap { isImage ? .success(.image($0)) : content(text: $0, ext: ext) }
    }

    /// Text lines of `data`, or the binary error.
    nonisolated static func content(text data: Data, ext: String) -> Result<FileContent, FileTreeError> {
        guard let text = ThreadFileSystem.decodeText(data) else { return .failure(.binaryFile) }
        if data.isEmpty { return .success(.text([], ext)) }
        return .success(.text(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), ext))
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
typealias FileTreeError = ThreadFileError
