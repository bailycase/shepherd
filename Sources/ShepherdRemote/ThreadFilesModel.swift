import Foundation
import Observation
import ShepherdProtocol

/// A remote thread's Files (`files.v1`; docs/design/side-pane-files.md): a lazy tree of the thread's folder on its host,
/// a filter over the expanded folders, and one file open read-only. Rows are derived once per change; views draw them.
@MainActor
@Observable
public final class ThreadFilesModel {
    public typealias List = @Sendable (_ path: String, _ showHidden: Bool) async throws -> ThreadFileListing
    public typealias Read = @Sendable (_ path: String) async throws -> Data

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

    @ObservationIgnored private let list: List
    @ObservationIgnored private let read: Read
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

    public init(list: @escaping List, read: @escaping Read) {
        self.list = list
        self.read = read
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
        }
        fileRead = pending
        await pending.value
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
