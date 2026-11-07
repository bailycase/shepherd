import Foundation
import Observation
import ShepherdProtocol

/// A remote thread's Files (`files.v1`): a lazy tree of the thread's folder on its host,
/// a filter over the expanded folders, and open files: read in place of the tree (iPhone), or as tabs that edit and save over
/// `files.write.v1` (iPad, `FileEdit` as on the Mac). Rows are derived once per change; views draw them.
@MainActor
@Observable
public final class ThreadFilesModel {
    public typealias List = @Sendable (_ path: String, _ showHidden: Bool) async throws -> ThreadFileListing
    public typealias Read = @Sendable (_ path: String) async throws -> Data
    public typealias Write = @Sendable (_ path: String, _ text: String, _ expected: String) async throws -> ThreadFileSaveResult

    /// One line of the tree: a folder, a file, or a note under a folder the host cut short.
    public struct Row: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case folder(expanded: Bool, loading: Bool), file, note }
        /// The path relative to the thread's folder (a note's: its folder's, then "/…").
        public let id: String
        public let name: String
        public let depth: Int
        public let kind: Kind
        public let size: Int64?
        public let error: String?
    }

    public enum Content: Equatable, Sendable {
        case loading
        case text(String)
        case failed(String)
    }

    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var phase = Phase.loading
    public private(set) var rows: [Row] = []
    public var filter = "" { didSet { if filter != oldValue { derive() } } }
    /// The file open in place of the tree, and what it holds.
    public private(set) var openPath: String?
    /// The file last opened: its row stays marked after Back.
    public private(set) var selectedPath: String?
    public private(set) var content = Content.loading
    /// Files open as tabs, in the order they were opened.
    public private(set) var openTabs: [String] = []
    /// Each open text file's editor state, by path. Survives switching tabs; closing the tab drops it.
    public private(set) var edits: [String: FileEdit] = [:]
    /// Bumped whenever an editor's text is replaced from outside it (a read, a revert), so the editor
    /// resets its text then and never while the person types.
    public private(set) var textRevision: UInt = 0
    /// Why the last save failed (a conflict is `FileEdit.conflict`); nil after a save.
    public private(set) var saveError: String?
    public private(set) var saving = false

    @ObservationIgnored private let list: List
    @ObservationIgnored private let read: Read
    @ObservationIgnored private let write: Write?
    @ObservationIgnored private var listings: [String: ThreadFileListing] = [:]
    @ObservationIgnored private var expanded: Set<String> = []
    @ObservationIgnored private var directoryLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var errors: [String: String] = [:]
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var forgotten = false
    @ObservationIgnored private var pendingRequests = 0
    /// Reloadable payload estimate (UTF-8 plus per-entry/row allowance), not heap usage.
    @ObservationIgnored public private(set) var retainedCost = 0
    @ObservationIgnored public var onRetentionChange: (() -> Void)?
    public var hasPendingRequests: Bool { pendingRequests > 0 }
    var retainedEntryCount: Int { listings.values.reduce(0) { $0 + $1.entries.count } }

    public init(list: @escaping List, read: @escaping Read, write: Write? = nil) {
        self.list = list
        self.read = read
        self.write = write
    }

    /// Restores only the visible expanded tree and the open file after payload eviction.
    public func loadIfNeeded() async {
        guard !forgotten, !Task.isCancelled else { return }
        pendingRequests += 1
        defer { finishedRequest() }
        let token = generation
        await loadDirectory("")
        guard token == generation, !Task.isCancelled else { return }
        await restoreExpanded(in: "", generation: token)
        guard token == generation, !Task.isCancelled else { return }
        if let path = openPath, content == .loading { await open(path) }
    }

    /// Collapsed subtrees keep their expansion choices, not their reloadable listings.
    public func toggle(_ path: String) async {
        guard !forgotten, !Task.isCancelled else { return }
        pendingRequests += 1
        defer { finishedRequest() }
        if expanded.remove(path) != nil {
            derive()
            return
        }
        expanded.insert(path)
        derive()
        let token = generation
        await loadDirectory(path)
        guard token == generation, !Task.isCancelled, expanded.contains(path) else { return }
        await restoreExpanded(in: path, generation: token)
    }

    private func loadDirectory(_ path: String) async {
        guard !forgotten, listings[path] == nil, visible(path) else { return }
        if let pending = directoryLoads[path] {
            await pending.value
            return
        }
        let token = generation
        // One model-owned read per path/epoch. Cancelling a view cancels only that reader's
        // restoration, not the request another reader joins. Every caller awaits actual finish.
        let pending = Task { @MainActor in
            guard token == generation else { return }
            do {
                let listing = try await list(path, false)
                guard token == generation else { return }
                if visible(path) { listings[path] = listing }
                if path.isEmpty { phase = .loaded }
            } catch {
                guard token == generation else { return }
                if path.isEmpty { phase = .failed(Self.message(error)) }
                else if visible(path) { errors[path] = Self.message(error) }
            }
            directoryLoads[path] = nil
            derive()
        }
        directoryLoads[path] = pending
        errors[path] = nil
        if path.isEmpty { phase = .loading }
        derive()
        await pending.value
    }

    private func restoreExpanded(in folder: String, generation token: Int) async {
        // Keep only names across suspension, not a copy of a potentially large listing.
        let directories = listings[folder]?.entries.filter(\.isDirectory).map(\.name) ?? []
        for name in directories {
            guard token == generation, !Task.isCancelled, visible(folder) else { return }
            let path = folder.isEmpty ? name : folder + "/" + name
            guard expanded.contains(path) else { continue }
            await loadDirectory(path)
            guard token == generation, !Task.isCancelled, visible(path) else { continue }
            await restoreExpanded(in: path, generation: token)
        }
    }

    private func visible(_ path: String) -> Bool {
        if path.isEmpty { return true }
        var ancestor = ""
        for part in path.split(separator: "/") {
            ancestor = ancestor.isEmpty ? String(part) : ancestor + "/" + part
            if !expanded.contains(ancestor) { return false }
        }
        return true
    }

    @ObservationIgnored private var fileRead: Task<Void, Never>?

    /// Reads a file in place of the tree.
    public func open(_ path: String) async {
        guard !forgotten, !Task.isCancelled else { return }
        pendingRequests += 1
        defer { finishedRequest() }
        if openPath == path, let pending = fileRead {
            await pending.value
            return
        }
        openGeneration += 1
        let token = openGeneration
        fileRead?.cancel()
        openPath = path
        selectedPath = path
        if !openTabs.contains(path) { openTabs.append(path) }
        content = .loading
        let pending = Task { @MainActor in
            guard token == openGeneration else { return }
            let result: Content
            do {
                let data = try await read(path)
                result = String(data: data, encoding: .utf8).map(Content.text) ?? .failed(ThreadFileError.binaryFile.localizedDescription)
            } catch {
                result = .failed(Self.message(error))
            }
            guard token == openGeneration else { return }
            fileRead = nil
            content = result
            if case .text(let text) = result { take(disk: text, for: path) }
        }
        fileRead = pending
        await pending.value
    }

    /// Closes a tab and drops its unsaved edits (the view confirms a dirty one first); the last tab
    /// opened before it shows next.
    public func closeTab(_ path: String) async {
        openTabs.removeAll { $0 == path }
        edits[path] = nil
        guard openPath == path else { return }
        if let next = openTabs.last { await open(next) } else { close() }
    }

    // MARK: Editing

    /// The host's text folded into the file's editor (`FileEdit.take`).
    private func take(disk text: String, for path: String) {
        var edit = edits[path] ?? FileEdit(saved: text, text: text)
        if edits[path] == nil || edit.take(disk: text) { textRevision &+= 1 }
        if edits[path] != edit { edits[path] = edit }
    }

    /// The person typed: the editor's text for `path`.
    public func setText(_ text: String, for path: String) {
        guard edits[path] != nil, edits[path]?.text != text else { return }
        edits[path]?.text = text
    }

    /// Reads the open file again without the loading state: a clean editor takes the host's text,
    /// one with unsaved edits holds it as a conflict. The end of an agent's edit calls this.
    public func checkDisk() async {
        guard !forgotten, let path = openPath, edits[path] != nil, fileRead == nil else { return }
        let token = openGeneration
        guard let data = try? await read(path), token == openGeneration, openPath == path,
              let text = String(data: data, encoding: .utf8) else { return }
        if content != .text(text) { content = .text(text) }
        take(disk: text, for: path)
    }

    /// Drops the open file's unsaved edits for the host's text (the newer one after a conflict).
    public func revert() {
        guard let path = openPath, edits[path]?.revert() == true else { return }
        saveError = nil
        textRevision &+= 1
    }

    /// Saves the open file's text over the version it was edited from. A file that changed since is
    /// never overwritten: it becomes the conflict, and only `overwrite` (the person's Overwrite)
    /// writes over that newer version, still only while it holds.
    public func save(overwrite: Bool = false) async {
        guard let path = openPath, let edit = edits[path], let write, !saving,
              edit.conflict == nil ? edit.isDirty : overwrite else { return }
        saving = true
        defer { saving = false }
        let text = edit.text, expected = edit.conflict ?? edit.saved
        let result: ThreadFileSaveResult
        do { result = try await write(path, text, expected) } catch { result = .failed(Self.message(error)) }
        guard edits[path] != nil else { return }
        switch result {
        case .saved:
            saveError = nil
            edits[path]?.didSave(text)
            if openPath == path { content = .text(text) }
        case .changed(let disk):
            saveError = nil
            edits[path]?.conflict = disk
        case .failed(let message):
            saveError = message
        }
    }

    /// Back to the tree.
    public func close() {
        openGeneration += 1
        openPath = nil
        content = .loading
        fileRead?.cancel()
        fileRead = nil
        accountPayload()
        onRetentionChange?()
    }

    /// The registry calls this only off screen with no requests; generations also fence forced
    /// eviction/forget during a request. Navigation choices stay in memory, never persisted.
    public func releasePayload() {
        generation += 1
        openGeneration += 1
        listings = [:]
        for pending in directoryLoads.values { pending.cancel() }
        directoryLoads = [:]
        fileRead?.cancel()
        fileRead = nil
        errors = [:]
        rows = []
        // Unsaved edits are not reloadable: they stay until their tab closes or the thread is forgotten.
        edits = forgotten ? [:] : edits.filter { $0.value.isDirty || $0.value.conflict != nil }
        let unavailable = "This thread or host is no longer available."
        content = forgotten && openPath != nil ? .failed(unavailable) : .loading
        phase = forgotten ? .failed(unavailable) : .loading
        retainedCost = 0
    }

    /// A deleted thread or forgotten host cannot be revived by a lingering view or late reply.
    public func forget() {
        forgotten = true
        releasePayload()
    }

    private func finishedRequest() {
        pendingRequests -= 1
        accountPayload()
        onRetentionChange?()
    }

    private func accountPayload() {
        guard !forgotten else { retainedCost = 0; return }
        var cost = listings.reduce(0) { total, item in
            total + item.key.utf8.count + 64 + item.value.entries.reduce(0) {
                $0 + 96 + $1.name.utf8.count + ($1.error?.utf8.count ?? 0)
            }
        }
        cost += rows.reduce(0) { $0 + 96 + $1.id.utf8.count + $1.name.utf8.count + ($1.error?.utf8.count ?? 0) }
        cost += errors.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        if case .failed(let message) = phase { cost += message.utf8.count }
        switch content {
        case .text(let text), .failed(let text): cost += text.utf8.count
        case .loading: break
        }
        cost += edits.values.reduce(0) { $0 + ($1.isDirty || $1.conflict != nil ? 0 : $1.saved.utf8.count * 2) }
        retainedCost = cost
    }

    private func derive() {
        // ponytail: zero warm collapsed listings. Reopening fetches again; add a small LRU only
        // if measured reopen latency warrants it. Root and visible expanded paths never evict.
        listings = listings.filter { visible($0.key) }
        errors = errors.filter { visible($0.key) }
        var rows: [Row] = []
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func walk(_ folder: String, depth: Int) {
            guard let listing = listings[folder] else { return }
            for entry in listing.entries {
                let path = folder.isEmpty ? entry.name : folder + "/" + entry.name
                if entry.isDirectory {
                    let open = expanded.contains(path)
                    rows.append(Row(id: path, name: entry.name, depth: depth, kind: .folder(expanded: open, loading: directoryLoads[path] != nil),
                                    size: nil, error: entry.error ?? (open ? errors[path] : nil)))
                    if open { walk(path, depth: depth + 1) }
                } else if needle.isEmpty || entry.name.lowercased().contains(needle) {
                    rows.append(Row(id: path, name: entry.name, depth: depth, kind: .file, size: entry.size, error: entry.error))
                }
            }
            if listing.truncated {
                rows.append(Row(id: folder + "/…", name: "Only the first \(listing.entries.count.formatted()) entries are shown.",
                                depth: depth, kind: .note, size: nil, error: nil))
            }
        }
        walk("", depth: 0)
        if rows != self.rows { self.rows = rows }
        accountPayload()
    }

    private static func message(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
