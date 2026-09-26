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
    case noSuchComment(String)
    /// A comment the store won't keep: why.
    case invalidComment(String)
    case tooManyComments
    case noSuchVersion(DesignPath, Int)
    /// A folder that can't become a design: why (`DesignImport.Problem`, or its canvas).
    case importRefused(String)
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
        case .noSuchComment: return "no_such_comment"
        case .invalidComment: return "invalid_comment"
        case .tooManyComments: return "too_many_comments"
        case .noSuchVersion: return "no_such_version"
        case .importRefused: return "import_refused"
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
        case .noSuchComment(let id): return "no comment \(id) on this design"
        case .invalidComment(let why): return why
        case .tooManyComments: return "a design keeps at most \(DesignComment.maxComments) comments"
        case .noSuchVersion(let path, let number): return "\(path) keeps no version \(number)"
        case .importRefused(let why): return why
        case .io(let message): return message
        }
    }
}

/// The files of every design, under the support directory's `designs/<id>/`: `project/canvas.json`,
/// one `project/<path>.dc.html` per board, and Shepherd's `revision` and `comments.json` beside
/// `project/` (docs/designs.md › Storage).
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
    /// Each design's comments.json as last read or written. Queue-confined.
    private var commentFiles: [DesignID: DesignComments] = [:]

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

    /// The designs among `ids` whose folder has no canvas.json: startup forgets them. A canvas
    /// that is there but unreadable keeps its design, so nothing is forgotten over a bad edit.
    /// Blocks the caller on the store's queue; call it off the server's.
    func missingDesigns(among ids: [DesignID]) -> Set<DesignID> {
        queue.sync {
            Set(ids.filter { id in
                guard let url = try? self.indexURL(id) else { return true }
                return !FileManager.default.fileExists(atPath: url.path)
            })
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
            self.commentFiles[id] = nil
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            do { try FileManager.default.removeItem(at: folder) } catch {
                throw DesignStoreError.io("could not delete design \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Writes one board's whole source, when the design is still at `baseRevision` (nil: any).
    /// The content it replaces is kept as the board's next version.
    func writeBoard(_ id: DesignID, path: DesignPath, source: String, baseRevision: UInt64?) async throws -> DesignWriteResult {
        try await run {
            let written = try self.writeOnQueue(id, [path: source], baseRevision: baseRevision)
            var result = written.result
            result.sha256 = written.shas[path]
            result.created = written.created.contains(path)
            return result
        }
    }

    /// Writes several boards' whole sources as one change (one revision), when the design is
    /// still at `baseRevision` (nil: any). Every source is checked before any is written.
    func writeBoards(_ id: DesignID, sources: [DesignPath: String], baseRevision: UInt64?) async throws -> DesignBoardsWrite {
        try await run {
            let written = try self.writeOnQueue(id, sources, baseRevision: baseRevision)
            return DesignBoardsWrite(result: written.result, shas: written.shas, versions: written.versions)
        }
    }

    /// A board's kept versions, oldest first.
    func versions(_ id: DesignID, path: DesignPath) async throws -> [DesignBoardVersion] {
        try await run {
            _ = try self.load(id)
            return try self.versionsOnQueue(id, path).map(\.version)
        }
    }

    /// Puts boards back to kept versions as one change, when the design is still at
    /// `baseRevision` and (when given) each board still has the hash `ifCurrent` names, so an undo
    /// never takes back a later write. What each board held is kept as its next version.
    func restore(_ id: DesignID, versions: [DesignPath: Int], ifCurrent: [DesignPath: String]?,
                 baseRevision: UInt64?) async throws -> DesignBoardsWrite {
        try await run {
            var design = try self.load(id)
            try Self.compare(baseRevision, design.revision)
            let files = try self.files(of: id, &design)
            var sources: [DesignPath: String] = [:]
            for (path, number) in versions.sorted(by: { $0.key < $1.key }) {
                if let expected = ifCurrent?[path], files[path] != expected {
                    throw DesignStoreError.stale(base: baseRevision ?? design.revision, current: design.revision)
                }
                guard let kept = try self.versionsOnQueue(id, path).first(where: { $0.version.number == number }),
                      let data = try? Data(contentsOf: kept.url) else {
                    throw DesignStoreError.noSuchVersion(path, number)
                }
                sources[path] = String(decoding: data, as: UTF8.self)
            }
            let written = try self.writeOnQueue(id, sources, baseRevision: baseRevision)
            return DesignBoardsWrite(result: written.result, shas: written.shas, versions: written.versions)
        }
    }

    private struct Written {
        var result: DesignWriteResult
        var shas: [DesignPath: String]
        var versions: [DesignPath: Int]
        var created: Set<DesignPath>
    }

    /// Queue: checks every source, keeps what each changed board held as a version, writes them
    /// atomically, and moves the revision once.
    private func writeOnQueue(_ id: DesignID, _ sources: [DesignPath: String], baseRevision: UInt64?) throws -> Written {
        var design = try load(id)
        try Self.compare(baseRevision, design.revision)
        var warnings: [DesignBoardCheck.Warning] = []
        for (_, source) in sources.sorted(by: { $0.key < $1.key }) {
            switch Result(catching: { () throws(DesignBoardCheck.Refusal) in try DesignBoardCheck.check(source) }) {
            case .success(let found): warnings += found.filter { !warnings.contains($0) }
            case .failure(let refusal): throw DesignStoreError.refused(refusal)
            }
        }
        var files = try self.files(of: id, &design)
        var shas: [DesignPath: String] = [:]
        var changed: [(path: DesignPath, data: Data)] = []
        var created: Set<DesignPath> = []
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            let data = Data(source.utf8)
            let sha = Self.sha256(data)
            shas[path] = sha
            guard files[path] != sha else { continue }
            if files[path] == nil {
                guard files.count + created.count < Self.maxFiles else { throw DesignStoreError.tooManyFiles }
                let stem = path.stem.lowercased()
                let others = Set(files.keys).union(design.index.boards.keys).union(created)
                if let other = others.sorted().first(where: { $0 != path && $0.stem.lowercased() == stem }) {
                    throw DesignStoreError.nameTaken(path, by: other)
                }
                created.insert(path)
            }
            changed.append((path, data))
        }
        guard !changed.isEmpty else {
            return Written(result: DesignWriteResult(revision: design.revision, changed: false, warnings: warnings,
                                                     title: design.index.title, boardCount: design.index.boards.count),
                           shas: shas, versions: [:], created: [])
        }
        var versions: [DesignPath: Int] = [:]
        var failure: DesignStoreError?
        for (path, data) in changed {
            do {
                if !created.contains(path) { versions[path] = try keepVersion(id, path) }
                try writeFile(id, path, data)
                files[path] = shas[path]
            } catch let error as DesignStoreError {
                failure = error
                break
            } catch {
                failure = .io("could not write \(path): \(error.localizedDescription)")
                break
            }
        }
        let wrote = changed.contains { files[$0.path] == shas[$0.path] }
        design.files = files
        if wrote {
            try commit(&design, id)
            // A rewrite renumbers a board's elements: its comments find theirs again.
            for (path, _) in changed where !created.contains(path) && files[path] == shas[path] {
                if let source = sources[path] { reanchorComments(id, board: path, source: source) }
            }
        }
        if let failure { throw failure }
        return Written(result: DesignWriteResult(revision: design.revision, changed: true, warnings: warnings,
                                                 title: design.index.title, boardCount: design.index.boards.count),
                       shas: shas, versions: versions, created: created)
    }

    /// Writes a board's file atomically, only inside the design: never through a linked folder
    /// that leads outside it, and no folder is made there.
    private func writeFile(_ id: DesignID, _ path: DesignPath, _ data: Data) throws {
        let url = try fileURL(id, path)
        let folder = url.deletingLastPathComponent()
        guard let project = projectFolder(for: id), Self.isInside(Self.deepestExisting(folder), project) else {
            throw DesignStoreError.invalidPath(path.rawValue, .parentReference)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DesignStoreError.io("could not write \(path): \(error.localizedDescription)")
        }
        guard Self.isInside(folder, project) else { throw DesignStoreError.invalidPath(path.rawValue, .parentReference) }
        do { try data.write(to: url, options: .atomic) } catch {
            throw DesignStoreError.io("could not write \(path): \(error.localizedDescription)")
        }
    }

    // MARK: Versions

    /// Where a board's versions live: `versions/<path>/<n>.dc.html`, beside `project/`, so the
    /// board scheme never serves them and they are no board.
    private func versionsFolder(_ id: DesignID, _ path: DesignPath) throws -> URL {
        guard let folder = folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        return folder.appendingPathComponent("versions", isDirectory: true).appendingPathComponent(path.rawValue, isDirectory: true)
    }

    private struct Kept {
        var version: DesignBoardVersion
        var url: URL
    }

    private func versionsOnQueue(_ id: DesignID, _ path: DesignPath) throws -> [Kept] {
        let folder = try versionsFolder(id, path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> Kept? in
            guard name.hasSuffix(".dc.html"), let number = Int(name.dropLast(".dc.html".count)), number > 0 else { return nil }
            let url = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date(timeIntervalSince1970: 0)
            return Kept(version: DesignBoardVersion(number: number, sha256: Self.sha256(data), bytes: data.count,
                                                    savedAt: (saved.timeIntervalSince1970 * 1000).rounded()), url: url)
        }
        .sorted { $0.version.number < $1.version.number }
    }

    /// Keeps the board's file as its next version, then forgets all but the newest
    /// `DesignBoardVersion.kept`. Returns the version's number.
    private func keepVersion(_ id: DesignID, _ path: DesignPath) throws -> Int {
        let current = try fileURL(id, path)
        let data: Data
        do { data = try Data(contentsOf: current) } catch {
            throw DesignStoreError.io("could not keep a version of \(path): \(error.localizedDescription)")
        }
        let folder = try versionsFolder(id, path)
        let existing = try versionsOnQueue(id, path)
        let number = (existing.last?.version.number ?? 0) + 1
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(number).dc.html"), options: .atomic)
        } catch {
            throw DesignStoreError.io("could not keep a version of \(path): \(error.localizedDescription)")
        }
        for old in existing.dropLast(max(0, DesignBoardVersion.kept - 1)) { try? FileManager.default.removeItem(at: old.url) }
        return number
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
            // Only files the store found inside the design: never one through a linked folder.
            for path in removed where files[path] != nil {
                if let url = try? self.fileURL(id, path) { try? FileManager.default.removeItem(at: url) }
                if let versions = try? self.versionsFolder(id, path) { try? FileManager.default.removeItem(at: versions) }
                files[path] = nil
            }
            design.index = merged
            design.files = files
            try self.commit(&design, id)
            // A removed board's comments have nothing left to pin to.
            for path in removed { self.reanchorComments(id, board: path, source: nil) }
            return DesignWriteResult(revision: design.revision, changed: true, title: merged.title,
                                     boardCount: merged.boards.count)
        }
    }

    /// Copies a board as a new one beside it (`DesignIndex.duplicating`): its file byte for byte
    /// at a free path, and its entry in canvas.json, as one change, when the design is still at
    /// `baseRevision` (nil: any). Its comments and versions stay with the original.
    func duplicateBoard(_ id: DesignID, path: DesignPath, baseRevision: UInt64?) async throws -> DesignDuplicate {
        try await run {
            var design = try self.load(id)
            try Self.compare(baseRevision, design.revision)
            var files = try self.files(of: id, &design)
            guard design.index.boards[path] != nil else { throw DesignStoreError.noSuchBoard(path) }
            guard files[path] != nil else { throw DesignStoreError.missingBoardFile(path) }
            guard files.count < Self.maxFiles else { throw DesignStoreError.tooManyFiles }
            let taken = Set(files.keys).union(design.index.boards.keys)
            guard let copy = DesignIndex.duplicatePath(for: path, taken: taken),
                  let next = design.index.duplicating(path, as: copy) else {
                throw DesignStoreError.invalidIndex(["no free name for a copy of \(path)"])
            }
            let known = Set(design.index.problems())
            let problems = next.problems().filter { !known.contains($0) }
            guard problems.isEmpty else { throw DesignStoreError.invalidIndex(problems) }
            let data: Data
            do { data = try Data(contentsOf: self.fileURL(id, path)) } catch {
                throw DesignStoreError.io("could not read \(path): \(error.localizedDescription)")
            }
            try self.writeFile(id, copy, data)
            do {
                try next.encoded().write(to: self.indexURL(id), options: .atomic)
            } catch {
                if let url = try? self.fileURL(id, copy) { try? FileManager.default.removeItem(at: url) }
                throw DesignStoreError.io("could not write canvas.json: \(error.localizedDescription)")
            }
            files[copy] = Self.sha256(data)
            design.index = next
            design.files = files
            try self.commit(&design, id)
            let result = DesignWriteResult(revision: design.revision, changed: true, sha256: files[copy], created: true,
                                           title: next.title, boardCount: next.boards.count)
            return DesignDuplicate(path: copy, result: result)
        }
    }

    // MARK: Import

    /// Makes design `id`'s folder from a Claude Design folder on disk (`DesignImport`'s rules):
    /// its canvas and every file under its `project/` (and a Shepherd export's `assets/`) copied
    /// in, nothing else. The source is only read. The copy is made beside the designs and moved
    /// into place whole, so a refused or failed import leaves nothing behind.
    func importFolder(_ id: DesignID, from source: URL) async throws -> DesignSnapshot {
        try await run {
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw DesignStoreError.designExists(id) }
            let root = source.standardizedFileURL
            let plan: DesignImport.Plan
            do {
                plan = try DesignImport.plan(try Self.walk(root))
            } catch let problem as DesignImport.Problem {
                throw DesignStoreError.importRefused(problem.description)
            } catch {
                throw DesignStoreError.io("could not read the folder: \(error.localizedDescription)")
            }
            let named = root.lastPathComponent == "project" ? root.deletingLastPathComponent().lastPathComponent : root.lastPathComponent
            let index: (data: Data, index: DesignIndex)
            do {
                index = try DesignImport.index(try Self.readRegular(root.appendingPathComponent(plan.index)), fallbackTitle: named)
            } catch let error as DesignStoreError {
                throw error
            } catch {
                throw DesignStoreError.importRefused("canvas.json isn't a canvas Shepherd reads: \(error)")
            }
            let staging = self.directory.appendingPathComponent(".import-\(id.rawValue)", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            do {
                try FileManager.default.createDirectory(at: staging.appendingPathComponent("project", isDirectory: true),
                                                        withIntermediateDirectories: true)
                for (from, to) in plan.files.sorted(by: { $0.key < $1.key }) where from != plan.index {
                    let target = staging.appendingPathComponent(to)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.readRegular(root.appendingPathComponent(from)).write(to: target)
                }
                try index.data.write(to: staging.appendingPathComponent("project/canvas.json"))
                try Data("0\n".utf8).write(to: staging.appendingPathComponent("revision"))
                try FileManager.default.moveItem(at: staging, to: folder)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                if let error = error as? DesignStoreError { throw error }
                throw DesignStoreError.io("could not import the folder: \(error.localizedDescription)")
            }
            self.loaded[id] = nil
            self.commentFiles[id] = nil
            return try self.snapshotOnQueue(id)
        }
    }

    /// Everything under `root`, as `lstat` sees it: links are reported, never followed. A folder
    /// holding `project/` is walked only there and in `assets/`.
    private static func walk(_ root: URL) throws -> [DesignImport.Entry] {
        var entries: [DesignImport.Entry] = []
        let manager = FileManager.default
        func kind(_ path: String) -> (DesignImport.Kind, Int) {
            guard let attributes = try? manager.attributesOfItem(atPath: path) else { return (.other, 0) }
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?: return (.file, size)
            case .typeDirectory?: return (.directory, 0)
            case .typeSymbolicLink?: return (.symlink, 0)
            default: return (.other, 0)
            }
        }
        let (rootKind, _) = kind(root.path)
        guard rootKind == .directory else { throw DesignImport.Problem.noCanvas }
        let isProject = kind(root.appendingPathComponent("canvas.json").path).0 == .file
        func visit(_ folder: URL, _ relative: String, depth: Int) throws {
            let names = try manager.contentsOfDirectory(atPath: folder.path).sorted()
            for name in names {
                let path = relative.isEmpty ? name : relative + "/" + name
                let (kind, size) = kind(folder.appendingPathComponent(name).path)
                entries.append(DesignImport.Entry(path, kind, size: size))
                guard entries.count <= DesignImport.maxFiles * 8 else { throw DesignImport.Problem.tooManyFiles }
                guard kind == .directory, !name.hasPrefix("."), depth < DesignImport.maxDepth else { continue }
                if relative.isEmpty, !isProject, name != "project", name != "assets" { continue }
                try visit(folder.appendingPathComponent(name, isDirectory: true), path, depth: depth + 1)
            }
        }
        try visit(root, "", depth: 0)
        return entries
    }

    /// A regular file's bytes, refused when it is a link or over the import's cap.
    private static func readRegular(_ url: URL) throws -> Data {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw DesignStoreError.importRefused("\(url.lastPathComponent) changed while it was read.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= DesignImport.maxFileBytes else {
            throw DesignStoreError.importRefused(DesignImport.Problem.tooLarge(url.lastPathComponent).description)
        }
        return data
    }

    // MARK: Export

    /// What an export of `boards` reads: the canvas, the boards and every board they import
    /// (`DesignBundle.members`), the project's other files (its design systems, named support
    /// files), and the uploads those boards name. Only reads.
    public func exportFiles(_ id: DesignID, boards: [DesignPath]) async throws -> DesignExportFiles {
        try await run {
            var design = try self.load(id)
            let files = try self.files(of: id, &design)
            guard let project = self.projectFolder(for: id), let folder = self.folder(for: id) else {
                throw DesignStoreError.invalidDesignID(id.rawValue)
            }
            for path in boards where files[path] == nil { throw DesignStoreError.noSuchBoard(path) }
            var sources: [DesignPath: String] = [:]
            let members = DesignBundle.members(boards) { path in
                if let known = sources[path] { return known }
                guard files[path] != nil, let data = try? Data(contentsOf: project.appendingPathComponent(path.rawValue)) else { return nil }
                let text = String(decoding: data, as: UTF8.self)
                sources[path] = text
                return text
            }
            var support: [String: Data] = [:]
            var total = 0
            let root = project.resolvingSymlinksInPath().path + "/"
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL {
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(root) else { continue }
                let relative = String(resolved.dropFirst(root.count))
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true, relative != "canvas.json",
                      !relative.hasSuffix(DesignPath.fileExtension), url.lastPathComponent != "support.js",
                      relative.split(separator: "/").allSatisfy({ DesignImport.isSegment(String($0)) }),
                      let size = values?.fileSize, size <= DesignImport.maxFileBytes, total + size <= DesignImport.maxTotalBytes,
                      let data = try? Data(contentsOf: url) else { continue }
                support[relative] = data
                total += data.count
            }
            var assets: [String: DesignExportFiles.Asset] = [:]
            let assetFolder = folder.appendingPathComponent("assets", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: assetFolder.path))?.sorted() ?? []
            let texts = members.compactMap { sources[$0] } + support.filter { $0.key.hasSuffix(".css") }.map { String(decoding: $0.value, as: UTF8.self) }
            for blob in Set(texts.flatMap(DesignBundle.blobIDs)).sorted() {
                guard let name = names.first(where: { $0 == blob || $0.hasPrefix(blob + ".") }), DesignBundle.isAssetName(name) else { continue }
                let url = assetFolder.appendingPathComponent(name)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes?[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: url),
                      data.count <= DesignImport.maxFileBytes else { continue }
                assets[blob] = DesignExportFiles.Asset(name: name, data: data)
            }
            return DesignExportFiles(index: design.index, boards: boards, members: members, sources: sources,
                                     support: support, assets: assets)
        }
    }

    // MARK: Comments

    /// The design's comments, open and resolved, in the order they were made.
    public func comments(_ id: DesignID) async throws -> DesignComments {
        try await run {
            _ = try self.load(id)
            return try self.loadComments(id)
        }
    }

    /// Pins a new comment to an element of a board, when the comments are still at
    /// `baseRevision` (nil: any). The element must be one the board's source has now; its words
    /// are read from the source, so a later rewrite finds it by what the store saw.
    func addComment(_ id: DesignID, draft: DesignCommentDraft, baseRevision: UInt64?, at date: Double) async throws -> DesignComment {
        try await run {
            var design = try self.load(id)
            var file = try self.loadComments(id)
            try Self.compare(baseRevision, file.revision)
            guard let text = DesignComment.text(draft.text) else {
                throw DesignStoreError.invalidComment("a comment is 1 to \(DesignComment.maxTextBytes) bytes of text")
            }
            guard file.comments.count < DesignComment.maxComments else { throw DesignStoreError.tooManyComments }
            let files = try self.files(of: id, &design)
            guard files[draft.board] != nil, design.index.boards[draft.board] != nil else {
                throw DesignStoreError.noSuchBoard(draft.board)
            }
            let data: Data
            do { data = try Data(contentsOf: try self.fileURL(id, draft.board)) } catch { throw DesignStoreError.noSuchBoard(draft.board) }
            guard let element = DesignElementID(board: draft.board.viewName, tid: draft.tid, path: draft.path),
                  let template = DesignTemplate(board: String(decoding: data, as: UTF8.self)),
                  template.element(for: element) != nil else {
                throw DesignStoreError.invalidComment("\(draft.board) has no element \(draft.tid):\(draft.path.map(String.init).joined(separator: "/"))")
            }
            let comment = DesignComment(number: file.nextNumber, board: draft.board, tid: draft.tid, path: draft.path,
                                        label: template.labels[draft.tid],
                                        target: draft.target.flatMap(DesignViewRecord.label),
                                        rect: draft.rect.flatMap { $0.isValid ? $0 : nil },
                                        text: text, author: .user, createdAt: date)
            file.comments.append(comment)
            try self.saveComments(&file, id)
            return comment
        }
    }

    /// Adds a reply under a comment, when the comments are still at `baseRevision` (nil: any).
    func replyToComment(_ id: DesignID, commentID: UUID, author: DesignCommentAuthor, text raw: String,
                        baseRevision: UInt64?, at date: Double) async throws -> DesignComment {
        try await run {
            _ = try self.load(id)
            var file = try self.loadComments(id)
            try Self.compare(baseRevision, file.revision)
            guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
                throw DesignStoreError.noSuchComment(commentID.uuidString)
            }
            guard let text = DesignComment.text(raw) else {
                throw DesignStoreError.invalidComment("a reply is 1 to \(DesignComment.maxTextBytes) bytes of text")
            }
            guard file.comments[index].replies.count < DesignComment.maxReplies else {
                throw DesignStoreError.invalidComment("a comment keeps at most \(DesignComment.maxReplies) replies")
            }
            file.comments[index].replies.append(DesignCommentReply(author: author, text: text, createdAt: date))
            try self.saveComments(&file, id)
            return file.comments[index]
        }
    }

    /// Resolves a comment (or opens it again), when the comments are still at `baseRevision`.
    func setCommentResolved(_ id: DesignID, commentID: UUID, resolved: Bool, baseRevision: UInt64?,
                            at date: Double) async throws -> DesignComment {
        try await run {
            _ = try self.load(id)
            var file = try self.loadComments(id)
            try Self.compare(baseRevision, file.revision)
            guard let index = file.comments.firstIndex(where: { $0.id == commentID }) else {
                throw DesignStoreError.noSuchComment(commentID.uuidString)
            }
            guard file.comments[index].isOpen == resolved else { return file.comments[index] }
            file.comments[index].resolvedAt = resolved ? date : nil
            if !resolved {
                // Open again, it looks for its element in the board as it is now.
                let comment = file.comments[index]
                let source = try? String(contentsOf: try self.fileURL(id, comment.board), encoding: .utf8)
                file.comments[index] = DesignCommentAnchor.reanchor([comment], board: comment.board, source: source)[0]
            }
            try self.saveComments(&file, id)
            return file.comments[index]
        }
    }

    /// The design's comments.json; an empty one when there is none yet.
    private func loadComments(_ id: DesignID) throws -> DesignComments {
        if let file = commentFiles[id] { return file }
        let url = try commentsURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            commentFiles[id] = DesignComments()
            return DesignComments()
        }
        let file: DesignComments
        do { file = try JSONDecoder().decode(DesignComments.self, from: Data(contentsOf: url)) } catch {
            throw DesignStoreError.io("comments.json is unreadable: \(error.localizedDescription)")
        }
        commentFiles[id] = file
        return file
    }

    /// Bumps the comments' revision and writes them atomically.
    private func saveComments(_ file: inout DesignComments, _ id: DesignID) throws {
        file.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do {
            try encoder.encode(file).write(to: try commentsURL(id), options: .atomic)
        } catch {
            file.revision -= 1
            throw DesignStoreError.io("could not write comments.json: \(error.localizedDescription)")
        }
        commentFiles[id] = file
    }

    /// Queue: the comments on `board` find their elements again in `source` (nil: the board is
    /// gone), and the file is written when any moved. A comments.json that can't be read or
    /// written is left for the next change; the board's own write already happened.
    private func reanchorComments(_ id: DesignID, board: DesignPath, source: String?) {
        guard var file = try? loadComments(id), file.comments.contains(where: { $0.board == board && $0.isOpen }) else { return }
        let next = DesignCommentAnchor.reanchor(file.comments, board: board, source: source)
        guard next != file.comments else { return }
        file.comments = next
        try? saveComments(&file, id)
    }

    private func commentsURL(_ id: DesignID) throws -> URL {
        guard let folder = folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        return folder.appendingPathComponent("comments.json")
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

    /// Whether `folder`, with its links resolved, is `project` or inside it.
    private static func isInside(_ folder: URL, _ project: URL) -> Bool {
        (folder.resolvingSymlinksInPath().path + "/").hasPrefix(project.resolvingSymlinksInPath().path + "/")
    }

    /// `folder`, or its nearest ancestor that exists.
    private static func deepestExisting(_ folder: URL) -> URL {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
