import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol

/// Why a design's files could not be read or changed. `code` is the stable spelling for replies.
public enum DesignStoreError: Error, Hashable, Sendable, CustomStringConvertible {
    case noSuchDesign(DesignID)
    case invalidDesignID(String)
    case designExists(DesignID)
    case invalidPath(String, DesignPath.Problem)
    case noSuchBoard(DesignPath)
    /// The write named `base`, but the design has moved on to `current`: read it again.
    case stale(base: UInt64, current: UInt64)
    case refused(DesignBoardCheck.Refusal)
    case nameTaken(DesignPath, by: DesignPath)
    case tooManyFiles
    case invalidIndex([String])
    case missingBoardFile(DesignPath)
    case io(String)

    public var code: String {
        switch self {
        case .noSuchDesign: return "no_such_design"
        case .invalidDesignID: return "invalid_design_id"
        case .designExists: return "design_exists"
        case .invalidPath: return "invalid_path"
        case .noSuchBoard: return "no_such_board"
        case .stale: return "stale_revision"
        case .refused(let refusal): return refusal.code
        case .nameTaken: return "name_taken"
        case .tooManyFiles: return "too_many_files"
        case .invalidIndex: return "invalid_index"
        case .missingBoardFile: return "missing_board_file"
        case .io: return "io_failed"
        }
    }

    public var description: String {
        switch self {
        case .noSuchDesign(let id): return "unknown design \(id)"
        case .invalidDesignID(let id): return "\"\(id)\" can't name a design folder"
        case .designExists(let id): return "design \(id) already exists"
        case .invalidPath(let raw, let problem): return "\"\(raw)\": \(problem)"
        case .noSuchBoard(let path): return "no board at \(path)"
        case .stale(let base, let current):
            return "the design changed since revision \(base) (it is at \(current)); read it again and redo the change"
        case .refused(let refusal): return refusal.description
        case .nameTaken(let path, let other): return "\(path) and \(other) share the name \(path.stem)"
        case .tooManyFiles: return "a design holds at most \(DesignStore.maxFiles) files"
        case .invalidIndex(let problems): return "canvas.json: " + problems.joined(separator: "; ")
        case .missingBoardFile(let path): return "\(path) is listed but has no file; write the board first"
        case .io(let message): return message
        }
    }
}

/// The files of every design, under the support directory's `designs/<id>/`: `project/canvas.json`,
/// one `project/<path>.dc.html` per board, and Shepherd's `revision` beside `project/`
/// (docs/designs.md › Storage).
///
/// Every read and write runs on the store's own serial queue, never the server's, so a compare
/// and the write it guards are one step. Only `SessionServer` writes: it commits and broadcasts
/// what each write changed. Nothing else changes these files, so there is no watcher.
public final class DesignStore: @unchecked Sendable {
    public let directory: URL
    /// A design holds at most this many files.
    public static let maxFiles = 512

    private let queue = DispatchQueue(label: "shepherd.designs", qos: .userInitiated)

    /// What the store knows of each design it has touched. Queue-confined.
    private struct Loaded {
        var revision: UInt64
        var index: DesignIndex
        /// Each board file's hash; read on first need.
        var files: [DesignPath: String]?
    }
    private var loaded: [DesignID: Loaded] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Paths

    /// The design's folder, or nil when its id can't name one (only `[A-Za-z0-9_-]`, up to 64).
    public func folder(for id: DesignID) -> URL? {
        let raw = id.rawValue
        guard (1...64).contains(raw.utf8.count),
              raw.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
                  || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }) else { return nil }
        return directory.appendingPathComponent(raw, isDirectory: true)
    }

    /// Where a design's canvas lives: what the board web views serve from.
    public func projectFolder(for id: DesignID) -> URL? {
        folder(for: id)?.appendingPathComponent("project", isDirectory: true)
    }

    // MARK: Reads

    public func snapshot(_ id: DesignID) async throws -> DesignSnapshot {
        try await run { try self.snapshotOnQueue(id) }
    }

    public func board(_ id: DesignID, path: DesignPath) async throws -> DesignBoardSource {
        try await run {
            var design = try self.load(id)
            let files = try self.files(of: id, &design)
            guard let sha = files[path] else { throw DesignStoreError.noSuchBoard(path) }
            let url = try self.fileURL(id, path)
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw DesignStoreError.noSuchBoard(path) }
            return DesignBoardSource(path: path, source: String(decoding: data, as: UTF8.self), sha256: sha,
                                     revision: design.revision)
        }
    }

    /// The designs among `ids` whose folder has no readable canvas: startup forgets them. Blocks
    /// the caller on the store's queue; call it off the server's.
    func missingDesigns(among ids: [DesignID]) -> Set<DesignID> {
        queue.sync {
            Set(ids.filter { (try? self.load($0)) == nil })
        }
    }

    /// Each readable design's listed board count.
    func boardCounts(_ ids: [DesignID]) async -> [DesignID: Int] {
        (try? await run {
            var counts: [DesignID: Int] = [:]
            for id in ids {
                if let design = try? self.load(id) { counts[id] = design.index.boards.count }
            }
            return counts
        }) ?? [:]
    }

    // MARK: Writes (SessionServer only)

    /// Makes the design's folder with a new canvas.json titled `title`.
    func create(_ id: DesignID, title: String, at date: Date) async throws -> DesignSnapshot {
        try await run {
            guard let folder = self.folder(for: id), let project = self.projectFolder(for: id) else {
                throw DesignStoreError.invalidDesignID(id.rawValue)
            }
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw DesignStoreError.designExists(id) }
            let index = DesignIndex.new(title: title, at: date)
            do {
                try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
                try index.encoded().write(to: project.appendingPathComponent("canvas.json"), options: .atomic)
                try self.writeRevision(0, of: id)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw DesignStoreError.io("could not create design \(id): \(error.localizedDescription)")
            }
            self.loaded[id] = Loaded(revision: 0, index: index, files: [:])
            return try self.snapshotOnQueue(id)
        }
    }

    /// Removes the design's folder. A folder already gone is not an error.
    func delete(_ id: DesignID) async throws {
        try await run {
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            self.loaded[id] = nil
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            do { try FileManager.default.removeItem(at: folder) } catch {
                throw DesignStoreError.io("could not delete design \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Writes one board's whole source, when the design is still at `baseRevision` (nil: any).
    func writeBoard(_ id: DesignID, path: DesignPath, source: String, baseRevision: UInt64?) async throws -> DesignWriteResult {
        try await run {
            var design = try self.load(id)
            try Self.compare(baseRevision, design.revision)
            let warnings: [DesignBoardCheck.Warning]
            switch Result(catching: { () throws(DesignBoardCheck.Refusal) in try DesignBoardCheck.check(source) }) {
            case .success(let found): warnings = found
            case .failure(let refusal): throw DesignStoreError.refused(refusal)
            }
            var files = try self.files(of: id, &design)
            let data = Data(source.utf8)
            let sha = Self.sha256(data)
            if files[path] == sha {
                return DesignWriteResult(revision: design.revision, changed: false, sha256: sha, warnings: warnings,
                                         title: design.index.title, boardCount: design.index.boards.count)
            }
            if files[path] == nil {
                guard files.count < Self.maxFiles else { throw DesignStoreError.tooManyFiles }
                let stem = path.stem.lowercased()
                let others = Set(files.keys).union(design.index.boards.keys)
                if let other = others.sorted().first(where: { $0 != path && $0.stem.lowercased() == stem }) {
                    throw DesignStoreError.nameTaken(path, by: other)
                }
            }
            let url = try self.fileURL(id, path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                throw DesignStoreError.io("could not write \(path): \(error.localizedDescription)")
            }
            files[path] = sha
            design.files = files
            try self.commit(&design, id)
            return DesignWriteResult(revision: design.revision, changed: true, sha256: sha, warnings: warnings,
                                     title: design.index.title, boardCount: design.index.boards.count)
        }
    }

    /// Applies a canvas_update (`DesignIndex.merging`) when the design is still at
    /// `baseRevision` (nil: any). Boards it adds or changes need their files; boards it removes
    /// lose theirs. Problems the index already had don't block it; new ones do.
    func updateIndex(_ id: DesignID, patch: JSONValue, baseRevision: UInt64?) async throws -> DesignWriteResult {
        try await run {
            var design = try self.load(id)
            try Self.compare(baseRevision, design.revision)
            let merged: DesignIndex
            do { merged = try design.index.merging(patch) } catch {
                throw DesignStoreError.invalidIndex([String(describing: error)])
            }
            if merged == design.index {
                return DesignWriteResult(revision: design.revision, changed: false, title: merged.title,
                                         boardCount: merged.boards.count)
            }
            let known = Set(design.index.problems())
            let problems = merged.problems().filter { !known.contains($0) }
            guard problems.isEmpty else { throw DesignStoreError.invalidIndex(problems) }
            var files = try self.files(of: id, &design)
            for (path, board) in merged.boards.sorted(by: { $0.key < $1.key })
            where design.index.boards[path] != board && files[path] == nil {
                throw DesignStoreError.missingBoardFile(path)
            }
            let removed = design.index.boards.keys.filter { merged.boards[$0] == nil }
            do {
                try merged.encoded().write(to: self.indexURL(id), options: .atomic)
            } catch {
                throw DesignStoreError.io("could not write canvas.json: \(error.localizedDescription)")
            }
            for path in removed {
                if let url = try? self.fileURL(id, path) { try? FileManager.default.removeItem(at: url) }
                files[path] = nil
            }
            design.index = merged
            design.files = files
            try self.commit(&design, id)
            return DesignWriteResult(revision: design.revision, changed: true, title: merged.title,
                                     boardCount: merged.boards.count)
        }
    }

    // MARK: Queue

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func compare(_ base: UInt64?, _ current: UInt64) throws {
        if let base, base != current { throw DesignStoreError.stale(base: base, current: current) }
    }

    private func snapshotOnQueue(_ id: DesignID) throws -> DesignSnapshot {
        var design = try load(id)
        let files = try files(of: id, &design)
        return DesignSnapshot(designID: id, revision: design.revision, index: design.index, boards: files)
    }

    /// The design as the store knows it, read from disk on first touch.
    private func load(_ id: DesignID) throws -> Loaded {
        if let design = loaded[id] { return design }
        guard let folder = folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        let data: Data
        do { data = try Data(contentsOf: indexURL(id)) } catch { throw DesignStoreError.noSuchDesign(id) }
        let index: DesignIndex
        do { index = try DesignIndex.decode(data) } catch {
            throw DesignStoreError.invalidIndex([String(describing: error)])
        }
        let revisionText = (try? String(contentsOf: folder.appendingPathComponent("revision"), encoding: .utf8)) ?? ""
        let revision = UInt64(revisionText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let design = Loaded(revision: revision, index: index.inSync(), files: nil)
        loaded[id] = design
        return design
    }

    /// Every `.dc.html` under `project/` (outside `ds/`) with its hash, read once and kept.
    private func files(of id: DesignID, _ design: inout Loaded) throws -> [DesignPath: String] {
        if let files = design.files { return files }
        guard let project = projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        var files: [DesignPath: String] = [:]
        let root = project.resolvingSymlinksInPath().path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root) else { continue }
            let relative = String(resolved.dropFirst(root.count))
            if relative == "ds" { walker?.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, let path = DesignPath(relative),
                  let data = try? Data(contentsOf: url) else { continue }
            files[path] = Self.sha256(data)
        }
        design.files = files
        loaded[id] = design
        return files
    }

    /// Bumps the revision, keeps it on disk (so a base from before a relaunch still compares),
    /// and remembers the design.
    private func commit(_ design: inout Loaded, _ id: DesignID) throws {
        design.revision += 1
        loaded[id] = design
        try writeRevision(design.revision, of: id)
    }

    private func writeRevision(_ revision: UInt64, of id: DesignID) throws {
        guard let folder = folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        do {
            try Data("\(revision)\n".utf8).write(to: folder.appendingPathComponent("revision"), options: .atomic)
        } catch {
            throw DesignStoreError.io("could not record the revision: \(error.localizedDescription)")
        }
    }

    private func indexURL(_ id: DesignID) throws -> URL {
        guard let project = projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        return project.appendingPathComponent("canvas.json")
    }

    private func fileURL(_ id: DesignID, _ path: DesignPath) throws -> URL {
        guard let project = projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        return project.appendingPathComponent(path.rawValue)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
