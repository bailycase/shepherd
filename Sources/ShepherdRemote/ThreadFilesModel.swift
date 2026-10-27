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
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var errors: [String: String] = [:]
    @ObservationIgnored private var openGeneration = 0
    @ObservationIgnored private var loadingRoot = false

    public init(list: @escaping List, read: @escaping Read) {
        self.list = list
        self.read = read
    }

    /// The root, unless it is loaded already (again after a failure).
    public func loadIfNeeded() async {
        if listings[""] != nil || loadingRoot { return }
        loadingRoot = true
        defer { loadingRoot = false }
        phase = .loading
        do {
            listings[""] = try await list("", false)
            phase = .loaded
        } catch {
            phase = .failed(Self.message(error))
        }
        derive()
    }

    /// Opens or closes a folder; its entries load the first time.
    public func toggle(_ path: String) async {
        if expanded.remove(path) != nil {
            derive()
            return
        }
        expanded.insert(path)
        guard listings[path] == nil, !loading.contains(path) else { return derive() }
        loading.insert(path)
        errors[path] = nil
        derive()
        do { listings[path] = try await list(path, false) } catch { errors[path] = Self.message(error) }
        loading.remove(path)
        derive()
    }

    /// Reads a file in place of the tree.
    public func open(_ path: String) async {
        openGeneration += 1
        let generation = openGeneration
        openPath = path
        selectedPath = path
        content = .loading
        let result: Content
        do {
            let data = try await read(path)
            result = String(data: data, encoding: .utf8).map(Content.text) ?? .failed(ThreadFileError.binaryFile.localizedDescription)
        } catch {
            result = .failed(Self.message(error))
        }
        guard generation == openGeneration else { return }
        content = result
    }

    /// Back to the tree.
    public func close() {
        openGeneration += 1
        openPath = nil
        content = .loading
    }

    private func derive() {
        var rows: [Row] = []
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        func walk(_ folder: String, depth: Int) {
            guard let listing = listings[folder] else { return }
            for entry in listing.entries {
                let path = folder.isEmpty ? entry.name : folder + "/" + entry.name
                if entry.isDirectory {
                    let open = expanded.contains(path)
                    rows.append(Row(id: path, name: entry.name, depth: depth, kind: .folder(expanded: open, loading: loading.contains(path)),
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
    }

    private static func message(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
