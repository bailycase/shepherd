import CryptoKit
import Foundation
import os
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
    /// Pencil markup the store won't hand on, or a proposal it won't make: why.
    case invalidMarkup(String)
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
        case .invalidMarkup: return "invalid_markup"
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
        case .invalidMarkup(let why): return why
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
    /// Each served file's hash, while its size and modification time hold. Queue-confined.
    private struct ServedHash {
        var size: Int
        var modified: Date
        var sha256: String
    }
    private var servedHashes: [DesignID: [String: ServedHash]] = [:]
    /// The hash of each file served in pieces (`project/<path>`, `assets/<name>`), while its size
    /// and modification time hold, so a piece reads only its own bytes. Queue-confined.
    private var pieceHashes: [DesignID: [String: ServedHash]] = [:]

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

    /// How many earlier versions of boards the design keeps, in all (DeleteDesignDialog: "their
    /// 23 versions").
    public func versionCount(_ id: DesignID) async throws -> Int {
        try await run {
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let versions = folder.appendingPathComponent("versions", isDirectory: true)
            let walker = FileManager.default.enumerator(at: versions, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles])
            var count = 0
            while let url = walker?.nextObject() as? URL {
                if url.lastPathComponent.hasSuffix(DesignPath.fileExtension),
                   (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { count += 1 }
            }
            return count
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
            self.forget(id)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            do { try FileManager.default.removeItem(at: folder) } catch {
                throw DesignStoreError.io("could not delete design \(id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: Deleting, with Undo

    /// Where a deleted design's folder waits while it can still be restored: beside the designs,
    /// hidden, never the Trash. Nothing serves it, and startup and quitting remove what is left.
    func stagedFolder(for id: DesignID) -> URL? {
        folder(for: id).map { directory.appendingPathComponent(Self.stagedPrefix + $0.lastPathComponent, isDirectory: true) }
    }

    static let stagedPrefix = ".deleted-"

    /// Sets a deleted design's folder aside (one rename), so Undo can put it back whole. True
    /// when there was a folder to move; a design already set aside is refused.
    func stageDeletion(_ id: DesignID) async throws -> Bool {
        try await run {
            guard let folder = self.folder(for: id), let staged = self.stagedFolder(for: id) else {
                throw DesignStoreError.invalidDesignID(id.rawValue)
            }
            self.forget(id)
            guard !FileManager.default.fileExists(atPath: staged.path) else { throw DesignStoreError.designExists(id) }
            guard FileManager.default.fileExists(atPath: folder.path) else { return false }
            do { try FileManager.default.moveItem(at: folder, to: staged) } catch {
                throw DesignStoreError.io("could not delete design \(id): \(error.localizedDescription)")
            }
            return true
        }
    }

    /// Undo: the set-aside folder back in its place. A design whose folder was never set aside
    /// (it had none) comes back without one.
    func unstageDeletion(_ id: DesignID) async throws {
        try await run {
            guard let folder = self.folder(for: id), let staged = self.stagedFolder(for: id) else {
                throw DesignStoreError.invalidDesignID(id.rawValue)
            }
            self.forget(id)
            guard FileManager.default.fileExists(atPath: staged.path) else { return }
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw DesignStoreError.designExists(id) }
            do { try FileManager.default.moveItem(at: staged, to: folder) } catch {
                throw DesignStoreError.io("could not restore design \(id): \(error.localizedDescription)")
            }
        }
    }

    /// The undo window closed: the set-aside folder goes for good.
    func finishDeletion(_ id: DesignID) async throws {
        try await run {
            guard let staged = self.stagedFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            self.forget(id)
            guard FileManager.default.fileExists(atPath: staged.path) else { return }
            do { try FileManager.default.removeItem(at: staged) } catch {
                throw DesignStoreError.io("could not delete design \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Queue: what the store remembers of a design, dropped when its folder moves or goes.
    private func forget(_ id: DesignID) {
        loaded[id] = nil
        commentFiles[id] = nil
        servedHashes[id] = nil
        pieceHashes[id] = nil
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

    // MARK: Pins (design references)

    /// Keeps the board's source as it is now under `pins/<sha256>.dc.html` beside `project/`, and
    /// records which source the board had at this revision (`pins/index.json`), so a reference
    /// pinned now is sent as it was even if the design moves on before the send. A pin is never
    /// served, never a board, and goes with the design's folder. Answers the board's source, its
    /// hash and the design's revision.
    public func pinBoard(_ id: DesignID, path: DesignPath) async throws -> DesignBoardSource {
        guard let pinned = try await pinBoards(id, paths: [path]).first else { throw DesignStoreError.noSuchBoard(path) }
        return pinned
    }

    /// `pinBoard` for several boards at one revision, in the order given. `wholeDesign` records
    /// them as what a whole-design reference holds at that revision (`pinnedDesign`), with the
    /// number of boards the design had then.
    public func pinBoards(_ id: DesignID, paths: [DesignPath], wholeDesign boardCount: Int? = nil) async throws -> [DesignBoardSource] {
        try await run {
            var design = try self.load(id)
            let files = try self.files(of: id, &design)
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let pins = folder.appendingPathComponent("pins", isDirectory: true)
            var index = Self.pinIndex(pins)
            var out: [DesignBoardSource] = []
            for path in paths {
                guard let sha = files[path] else { throw DesignStoreError.noSuchBoard(path) }
                let data: Data
                do { data = try Data(contentsOf: try self.fileURL(id, path)) } catch { throw DesignStoreError.noSuchBoard(path) }
                let pin = pins.appendingPathComponent(sha + DesignPath.fileExtension)
                if !FileManager.default.fileExists(atPath: pin.path) {
                    do {
                        try FileManager.default.createDirectory(at: pins, withIntermediateDirectories: true)
                        try data.write(to: pin, options: .atomic)
                    } catch {
                        throw DesignStoreError.io("could not keep a pinned copy of \(path): \(error.localizedDescription)")
                    }
                }
                index.record(revision: design.revision, board: path, sha256: sha)
                out.append(DesignBoardSource(path: path, source: String(decoding: data, as: UTF8.self), sha256: sha, revision: design.revision))
            }
            if let boardCount {
                index.record(revision: design.revision, design: PinIndex.Held(boards: paths.map(\.rawValue), boardCount: boardCount))
            }
            if let data = try? JSONEncoder().encode(index) {
                try? data.write(to: pins.appendingPathComponent("index.json"), options: .atomic)
            }
            return out
        }
    }

    /// A board's source as a reference pinned it (`pinBoard`), or nil when no pin has that hash.
    public func pinnedBoard(_ id: DesignID, sha256: String) async throws -> String? {
        guard sha256.utf8.count == 64, sha256.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return try await run {
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let pin = folder.appendingPathComponent("pins", isDirectory: true).appendingPathComponent(sha256 + DesignPath.fileExtension)
            guard let data = try? Data(contentsOf: pin), Self.sha256(data) == sha256 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The board's source at `revision`, when a reference pinned it then; nil when none did.
    public func pinnedBoard(_ id: DesignID, path: DesignPath, revision: UInt64) async throws -> DesignBoardSource? {
        try await run {
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let pins = folder.appendingPathComponent("pins", isDirectory: true)
            guard let sha = Self.pinIndex(pins).sha256(revision: revision, board: path),
                  let data = try? Data(contentsOf: pins.appendingPathComponent(sha + DesignPath.fileExtension)),
                  Self.sha256(data) == sha else { return nil }
            return DesignBoardSource(path: path, source: String(decoding: data, as: UTF8.self), sha256: sha, revision: revision)
        }
    }

    /// What a whole-design reference pinned at `revision` holds (`pinBoards(wholeDesign:)`): each
    /// board's source then, in the order it was held, and how many boards the design had. Nil
    /// when no whole-design reference was pinned then, or a pin is gone.
    public func pinnedDesign(_ id: DesignID, revision: UInt64) async throws -> (boards: [DesignBoardSource], boardCount: Int)? {
        try await run {
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let pins = folder.appendingPathComponent("pins", isDirectory: true)
            let index = Self.pinIndex(pins)
            guard let held = index.designs?["\(revision)"] else { return nil }
            var boards: [DesignBoardSource] = []
            for raw in held.boards {
                guard let path = DesignPath(raw), let sha = index.sha256(revision: revision, board: path),
                      let data = try? Data(contentsOf: pins.appendingPathComponent(sha + DesignPath.fileExtension)),
                      Self.sha256(data) == sha else { return nil }
                boards.append(DesignBoardSource(path: path, source: String(decoding: data, as: UTF8.self), sha256: sha, revision: revision))
            }
            return (boards, held.boardCount)
        }
    }

    /// Which source each board had at the revisions references were pinned at, newest
    /// `PinIndex.limit` revisions kept, and what whole-design references held then.
    struct PinIndex: Codable {
        static let limit = 200
        var revisions: [String: [String: String]] = [:]
        /// Absent from an index written before whole-design pins were recorded.
        var designs: [String: Held]?

        struct Held: Codable, Equatable {
            var boards: [String]
            var boardCount: Int
        }

        mutating func record(revision: UInt64, board: DesignPath, sha256: String) {
            revisions["\(revision)", default: [:]][board.rawValue] = sha256
            trim()
        }

        mutating func record(revision: UInt64, design held: Held) {
            designs = designs ?? [:]
            designs?["\(revision)"] = held
            trim()
        }

        private mutating func trim() {
            if revisions.count > Self.limit {
                let old = revisions.keys.compactMap(UInt64.init).sorted().prefix(revisions.count - Self.limit)
                for key in old { revisions["\(key)"] = nil }
            }
            if let designs, designs.count > Self.limit {
                let old = designs.keys.compactMap(UInt64.init).sorted().prefix(designs.count - Self.limit)
                for key in old { self.designs?["\(key)"] = nil }
            }
        }

        func sha256(revision: UInt64, board: DesignPath) -> String? {
            revisions["\(revision)"]?[board.rawValue]
        }
    }

    private static func pinIndex(_ pins: URL) -> PinIndex {
        (try? Data(contentsOf: pins.appendingPathComponent("index.json"))).flatMap { try? JSONDecoder().decode(PinIndex.self, from: $0) }
            ?? PinIndex()
    }

    // MARK: Notes back (docs/designs.md › Notes back)

    /// The notes threads left on the design's pieces, oldest first: `thread-notes.json` beside
    /// `project/`, never inside it. Empty when there are none or the file is unreadable.
    public func threadNotes(_ id: DesignID) async throws -> [DesignThreadNote] {
        try await run {
            _ = try self.load(id)
            return self.loadThreadNotes(id).notes
        }
    }

    /// Adds `note` in place of the same thread's note on the same piece.
    func addThreadNote(_ id: DesignID, _ note: DesignThreadNote) async throws -> DesignThreadNote {
        try await run {
            _ = try self.load(id)
            var file = self.loadThreadNotes(id)
            file.add(note)
            try self.saveThreadNotes(file, id)
            return note
        }
    }

    /// Removes a note; false when the design has none by that id.
    func removeThreadNote(_ id: DesignID, noteID: UUID) async throws -> Bool {
        try await run {
            _ = try self.load(id)
            var file = self.loadThreadNotes(id)
            guard file.notes.contains(where: { $0.id == noteID }) else { return false }
            file.notes.removeAll { $0.id == noteID }
            try self.saveThreadNotes(file, id)
            return true
        }
    }

    private func loadThreadNotes(_ id: DesignID) -> DesignThreadNotes {
        guard let folder = folder(for: id),
              let data = try? Data(contentsOf: folder.appendingPathComponent("thread-notes.json")) else { return DesignThreadNotes() }
        return (try? JSONDecoder().decode(DesignThreadNotes.self, from: data)) ?? DesignThreadNotes()
    }

    private func saveThreadNotes(_ file: DesignThreadNotes, _ id: DesignID) throws {
        guard let folder = folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(file).write(to: folder.appendingPathComponent("thread-notes.json"), options: .atomic)
        } catch {
            throw DesignStoreError.io("could not keep the note: \(error.localizedDescription)")
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

    // MARK: Duplicate

    /// Makes design `copy`'s folder from `source`'s: its canvas (titled `title`, every other key
    /// kept), every board and project file, and its uploads, as one move into place. Its versions
    /// and comments stay with the original, and a link in the original is not copied.
    func duplicateDesign(_ source: DesignID, as copy: DesignID, title: String) async throws -> DesignSnapshot {
        try await run {
            guard let from = self.folder(for: source), let folder = self.folder(for: copy) else {
                throw DesignStoreError.invalidDesignID(copy.rawValue)
            }
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw DesignStoreError.designExists(copy) }
            let design = try self.load(source)
            let index = try design.index.merging(.object(["title": .string(title)]))
            let staging = self.directory.appendingPathComponent(".import-\(copy.rawValue)", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            do {
                for part in ["project", "assets"] {
                    try Self.copyFiles(from.appendingPathComponent(part, isDirectory: true),
                                       to: staging.appendingPathComponent(part, isDirectory: true))
                }
                try FileManager.default.createDirectory(at: staging.appendingPathComponent("project", isDirectory: true),
                                                        withIntermediateDirectories: true)
                try index.encoded().write(to: staging.appendingPathComponent("project/canvas.json"), options: .atomic)
                try Data("0\n".utf8).write(to: staging.appendingPathComponent("revision"))
                try FileManager.default.moveItem(at: staging, to: folder)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                throw DesignStoreError.io("could not duplicate the design: \(error.localizedDescription)")
            }
            self.forget(copy)
            return try self.snapshotOnQueue(copy)
        }
    }

    /// Copies the regular files and folders under `source` to `target`, as `lstat` sees them: a
    /// link is left behind, never followed. Nothing when `source` isn't a folder.
    private static func copyFiles(_ source: URL, to target: URL) throws {
        let manager = FileManager.default
        var isFolder: ObjCBool = false
        guard manager.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue,
              (try? manager.destinationOfSymbolicLink(atPath: source.path)) == nil else { return }
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: source.path) {
            let from = source.appendingPathComponent(name)
            switch (try? manager.attributesOfItem(atPath: from.path))?[.type] as? FileAttributeType {
            case .typeDirectory?: try copyFiles(from, to: target.appendingPathComponent(name, isDirectory: true))
            case .typeRegular?: try manager.copyItem(at: from, to: target.appendingPathComponent(name))
            default: continue
            }
        }
    }

    // MARK: Import

    /// A project read into staging, waiting for the viewer's choice. Queue-confined.
    private struct StagedImport {
        let preview: DesignImportPreview
        let staging: URL
        let canvas: (data: Data, index: DesignIndex)
    }
    private var stagedImports: [UUID: StagedImport] = [:]
    /// Reading, unpacking and copying a project runs here, never on the store's queue: a large
    /// one must not hold up the designs' own reads and writes.
    private let importQueue = DispatchQueue(label: "shepherd.designs.import", qos: .userInitiated)
    static let importPrefix = ".import-"
    static let unzipPrefix = ".unzip-"

    /// Reads a Claude Design project (a ZIP or a folder) into staging beside the designs, by
    /// `DesignImport`'s rules, and answers what it holds; nothing is in Designs until
    /// `finishImport`. A ZIP is checked from its table of contents first (names inside the
    /// project, no links, sizes), then unpacked with `/usr/bin/ditto` into its own staging
    /// folder and checked again as a folder. A board pointing outside the project refuses the
    /// whole import; a board that can't be read is the viewer's choice. The source is only read;
    /// a refusal or failure leaves nothing behind. `existingSystem` answers the namespace of a
    /// system this host already has with the same files.
    func prepareImport(from source: URL, at now: Double,
                       existingSystem: @escaping @Sendable ([String: Data]) async -> String? = { _ in nil },
                       progress: @escaping @Sendable (DesignImportProgress) -> Void = { _ in }) async throws -> DesignImportPreview {
        let token = UUID()
        let file = source.lastPathComponent
        progress(.checking(file: file))
        let staged: StagedImport = try await withCheckedThrowingContinuation { continuation in
            importQueue.async {
                continuation.resume(with: Result { try self.stage(source, token: token, now: now, progress: progress) })
            }
        }
        var preview = staged.preview
        for index in preview.systems.indices {
            let folder = staged.staging.appendingPathComponent("project/ds/\(preview.systems[index].namespace)", isDirectory: true)
            preview.systems[index].existing = await existingSystem(Self.regularFiles(folder))
        }
        let ready = StagedImport(preview: preview, staging: staged.staging, canvas: staged.canvas)
        try await run { self.stagedImports[token] = ready }
        return preview
    }

    /// Import queue: the project checked and copied into `.import-<token>/`.
    private func stage(_ source: URL, token: UUID, now: Double, progress: (DesignImportProgress) -> Void) throws -> StagedImport {
        let manager = FileManager.default
        let original = source.standardizedFileURL
        let file = original.lastPathComponent
        var root = original
        let unzipped = directory.appendingPathComponent(Self.unzipPrefix + token.uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: unzipped) }
        let type = (try? manager.attributesOfItem(atPath: original.path))?[.type] as? FileAttributeType
        switch type {
        case .typeDirectory?: break
        case .typeRegular?:
            try Self.unzip(original, into: unzipped)
            root = unzipped
        case .typeSymbolicLink?: throw DesignImportFailure.linksOutside([DesignImportLink(board: file, target: "a link")])
        default: throw DesignImportFailure.notAProject
        }
        root = Self.projectRoot(root)
        let plan: DesignImport.Plan
        do {
            plan = try DesignImport.plan(try Self.walk(root))
        } catch let problem as DesignImport.Problem {
            throw problem.failure
        } catch let failure as DesignImportFailure {
            throw failure
        } catch {
            throw DesignImportFailure.refused("Couldn’t read the folder: \(error.localizedDescription)")
        }
        let named = file.lowercased().hasSuffix(".zip") ? String(file.dropLast(4))
            : root.lastPathComponent == "project" ? root.deletingLastPathComponent().lastPathComponent : file
        let canvas: (data: Data, index: DesignIndex)
        do {
            canvas = try DesignImport.index(try Self.readRegular(root.appendingPathComponent(plan.index)), fallbackTitle: named)
        } catch let failure as DesignImportFailure {
            throw failure
        } catch {
            throw DesignImportFailure.refused("canvas.json isn’t a canvas Shepherd reads: \(error)")
        }
        let index = canvas.index
        let projectSource = plan.index == "canvas.json" ? "" : "project/"
        var unreadable: [DesignImportUnreadable] = []
        var outside: [DesignImportLink] = []
        let boardFiles = Set(index.boards.keys.map { projectSource + $0.rawValue })
        let listed = index.order + index.boards.keys.filter { !index.order.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        let staging = directory.appendingPathComponent(Self.importPrefix + token.uuidString, isDirectory: true)
        try? manager.removeItem(at: staging)
        do {
            try manager.createDirectory(at: staging.appendingPathComponent("project", isDirectory: true), withIntermediateDirectories: true)
            // Boards first, in canvas order, so the count moves as they land; then the rest.
            let boards = listed.filter { plan.files[projectSource + $0.rawValue] != nil }
            var done = 0
            let system = index.designSystems?.first.flatMap { $0.title ?? $0.namespace }
            let title = index.title ?? named
            progress(.boards(done: 0, of: boards.count, title: title, system: system))
            for board in boards {
                let from = projectSource + board.rawValue
                let data = try Self.readRegular(root.appendingPathComponent(from))
                let entry = index.boards[board]
                let name = entry?.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? board.rawValue
                if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                    unreadable.append(DesignImportUnreadable(path: board.rawValue, title: name, reason: "is empty"))
                } else if let text = String(data: data, encoding: .utf8) {
                    for target in DesignImport.outsideReferences(in: text, board: board.rawValue) {
                        outside.append(DesignImportLink(board: board.rawValue, target: target))
                    }
                } else {
                    unreadable.append(DesignImportUnreadable(path: board.rawValue, title: name, reason: "isn’t text"))
                }
                if outside.isEmpty {
                    let target = staging.appendingPathComponent(plan.files[from] ?? ("project/" + board.rawValue))
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target)
                }
                done += 1
                progress(.boards(done: done, of: boards.count, title: title, system: system))
            }
            if !outside.isEmpty { throw DesignImportFailure.linksOutside(outside) }
            for (from, to) in plan.files.sorted(by: { $0.key < $1.key }) where from != plan.index && !boardFiles.contains(from) {
                let target = staging.appendingPathComponent(to)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.readRegular(root.appendingPathComponent(from)).write(to: target)
            }
            try Data("0\n".utf8).write(to: staging.appendingPathComponent("revision"))
        } catch {
            try? manager.removeItem(at: staging)
            if let failure = error as? DesignImportFailure { throw failure }
            throw DesignImportFailure.refused("Couldn’t read the project: \(error.localizedDescription)")
        }
        let present = listed.filter { plan.files[projectSource + $0.rawValue] != nil }
        let stamp = index.extra["createdOnFiles"].flatMap { value -> String? in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
        }
        let systems = (index.designSystems ?? []).compactMap { record -> DesignImportPreview.System? in
            guard let namespace = record.namespace, DesignPath.isSystemNamespace(namespace),
                  manager.fileExists(atPath: staging.appendingPathComponent("project/ds/\(namespace)").path) else { return nil }
            return DesignImportPreview.System(namespace: namespace, title: record.title ?? namespace)
        }
        let title = index.title ?? named
        let preview = DesignImportPreview(id: token, file: file, title: title, boards: present.count - unreadable.count,
                                          pages: max(index.pages?.count ?? 0, 1), systems: systems, unreadable: unreadable,
                                          origin: DesignImportOrigin(file: file, title: title, stamp: stamp, importedAt: now))
        return StagedImport(preview: preview, staging: staging, canvas: canvas)
    }

    /// Moves a staged project into design `id`'s folder, named `title`: the design exists from
    /// here. Boards that couldn't be read are refused unless `skippingUnreadable`, which leaves
    /// them (their files and their canvas entries) out. Answers the design's snapshot and its own
    /// design systems' files, by namespace.
    func finishImport(_ token: UUID, as id: DesignID, title: String, skippingUnreadable: Bool) async throws
        -> (snapshot: DesignSnapshot, systems: [String: [String: Data]]) {
        try await run {
            guard let staged = self.stagedImports[token] else { throw DesignImportFailure.refused("That import was put away.") }
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw DesignStoreError.designExists(id) }
            if let failure = staged.preview.unreadableFailure, !skippingUnreadable { throw failure }
            var patch: [String: JSONValue] = [:]
            if staged.canvas.index.title != title { patch["title"] = .string(title) }
            if !staged.preview.unreadable.isEmpty {
                patch["boards"] = .object(Dictionary(uniqueKeysWithValues: staged.preview.unreadable.map { ($0.path, JSONValue.null) }))
                for board in staged.preview.unreadable {
                    try? FileManager.default.removeItem(at: staged.staging.appendingPathComponent("project/" + board.path))
                }
            }
            let data = patch.isEmpty ? staged.canvas.data : try staged.canvas.index.merging(.object(patch)).encoded()
            do {
                try data.write(to: staged.staging.appendingPathComponent("project/canvas.json"))
                try FileManager.default.moveItem(at: staged.staging, to: folder)
            } catch {
                throw DesignImportFailure.refused("Couldn’t move the project into Designs: \(error.localizedDescription)")
            }
            self.stagedImports[token] = nil
            self.forget(id)
            var systems: [String: [String: Data]] = [:]
            for system in staged.preview.systems {
                systems[system.namespace] = Self.regularFiles(folder.appendingPathComponent("project/ds/\(system.namespace)", isDirectory: true))
            }
            return (try self.snapshotOnQueue(id), systems)
        }
    }

    /// Cancel: the staged project goes, and nothing was imported.
    func cancelImport(_ token: UUID) async {
        _ = try? await run {
            guard let staged = self.stagedImports.removeValue(forKey: token) else { return }
            try? FileManager.default.removeItem(at: staged.staging)
        }
    }

    /// Makes design `id` from a Claude Design folder or ZIP at once (no choice to make: a board
    /// that can't be read refuses it).
    func importFolder(_ id: DesignID, from source: URL, at now: Double = Date().timeIntervalSince1970 * 1000) async throws -> DesignSnapshot {
        let preview = try await prepareImport(from: source, at: now)
        do {
            return try await finishImport(preview.id, as: id, title: preview.title, skippingUnreadable: false).snapshot
        } catch {
            await cancelImport(preview.id)
            throw error
        }
    }

    /// Removes what imports and deletions left beside the designs: at launch after a crash, and
    /// at quit (a deletion within its window completes, an import waiting on a choice is put
    /// away). Blocks the caller on the store's queue; call it off the server's.
    @discardableResult
    func removeLeftovers() -> [String] {
        queue.sync {
            stagedImports.removeAll()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            var removed: [String] = []
            for name in names.sorted() where [Self.stagedPrefix, Self.importPrefix, Self.unzipPrefix].contains(where: name.hasPrefix) {
                if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: true))) != nil {
                    removed.append(name)
                }
            }
            return removed
        }
    }

    /// The project inside what was chosen or unpacked: the folder holding canvas.json (or
    /// project/canvas.json), else the one folder it holds that does (a ZIP of a folder).
    private static func projectRoot(_ root: URL) -> URL {
        let manager = FileManager.default
        func holdsCanvas(_ folder: URL) -> Bool {
            ["canvas.json", "project/canvas.json"].contains { name in
                (try? manager.attributesOfItem(atPath: folder.appendingPathComponent(name).path))?[.type] as? FileAttributeType
                    == .typeRegular
            }
        }
        guard !holdsCanvas(root) else { return root }
        let folders = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
            .map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { (try? manager.attributesOfItem(atPath: $0.path))?[.type] as? FileAttributeType == .typeDirectory }
        if folders.count == 1, let only = folders.first, holdsCanvas(only) { return only }
        return root
    }

    /// Unpacks a ZIP into `folder` once its table of contents passes the import's rules
    /// (`DesignArchive.check`): nothing is unpacked from an archive that breaks them. ditto
    /// unpacks what the data holds, not the sizes the table claims, so what lands is measured as
    /// it lands and ditto is stopped once it passes `limit`: a ZIP that lies about its sizes
    /// can't fill the disk.
    static func unzip(_ archive: URL, into folder: URL, limit: Int64 = DesignImport.maxProjectBytes) throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: archive) } catch { throw DesignImportFailure.notAProject }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        guard size <= DesignImport.maxProjectBytes else { throw DesignImportFailure.tooLarge(bytes: size, limit: DesignImport.maxProjectBytes) }
        let tailLength = min(Int64(DesignArchive.tailBytes), size)
        try handle.seek(toOffset: UInt64(size - tailLength))
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        let entries: [DesignArchive.Entry]
        do {
            let directory = try DesignArchive.directory(tail: tail, fileSize: size)
            try handle.seek(toOffset: UInt64(directory.offset))
            entries = try DesignArchive.entries(try handle.read(upToCount: Int(directory.size)) ?? Data(), count: directory.count)
        } catch DesignArchive.ReadError.notAZip {
            throw DesignImportFailure.notAProject
        } catch DesignArchive.ReadError.unsupported(let what) {
            throw DesignImportFailure.refused("Shepherd can’t read \(what). Export the project from Claude Design again.")
        }
        try DesignArchive.check(entries)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", "--noqtn", "--noacl", archive.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        ditto.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        ditto.terminationHandler = { _ in exited.signal() }
        try ditto.run()
        let message = OSAllocatedUnfairLock(initialState: Data())
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let read = errors.fileHandleForReading.readDataToEndOfFile()
            message.withLock { $0 = read }
            drained.signal()
        }
        var unpacked: Int64 = 0
        while exited.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            unpacked = bytes(under: folder)
            if unpacked > limit {
                ditto.terminate()
                exited.wait()
                drained.wait()
                throw DesignImportFailure.tooLarge(bytes: unpacked, limit: limit)
            }
        }
        drained.wait()
        unpacked = bytes(under: folder)
        guard unpacked <= limit else { throw DesignImportFailure.tooLarge(bytes: unpacked, limit: limit) }
        guard ditto.terminationStatus == 0 else {
            throw DesignImportFailure.refused("The ZIP couldn’t be unpacked: \(String(decoding: message.withLock { $0 }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The bytes of every file under `folder`, as `lstat` sees them.
    private static func bytes(under folder: URL) -> Int64 {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        var total: Int64 = 0
        while let url = walker?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Every regular file under `folder` by relative path, as `lstat` sees it (links are left
    /// out): a system's files for `DesignSystemStore.adopt`.
    private static func regularFiles(_ folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let manager = FileManager.default
        func visit(_ url: URL, _ relative: String, depth: Int) {
            guard depth < 8, let names = try? manager.contentsOfDirectory(atPath: url.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let child = url.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                switch (try? manager.attributesOfItem(atPath: child.path))?[.type] as? FileAttributeType {
                case .typeDirectory?: visit(child, path, depth: depth + 1)
                case .typeRegular?: if let data = try? Data(contentsOf: child) { files[path] = data }
                default: continue
                }
            }
        }
        visit(folder, "", depth: 0)
        return files
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
    /// Opened with `O_NOFOLLOW` and checked on the open descriptor, so a file swapped for a link or
    /// grown past the cap after the walk is still refused, before anything is read.
    private static func readRegular(_ url: URL) throws -> Data {
        let changed = DesignImportFailure.refused("\(url.lastPathComponent) changed while it was read.")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP { throw changed }
            throw DesignImportFailure.refused("Couldn’t read \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw changed }
        let tooLarge = DesignImportFailure.fileTooLarge(path: url.lastPathComponent, bytes: Int64(info.st_size),
                                                        limit: Int64(DesignImport.maxFileBytes))
        guard info.st_size <= DesignImport.maxFileBytes else { throw tooLarge }
        let data = try handle.read(upToCount: DesignImport.maxFileBytes + 1) ?? Data()
        guard data.count <= DesignImport.maxFileBytes else { throw tooLarge }
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

    // MARK: Design systems

    /// Copies a design system into the design's `project/ds/<namespace>/` (files of an earlier
    /// copy that this one doesn't hold leave) and records it in canvas.json's `designSystems`,
    /// in place of an earlier record of that folder, else last: one change, when the design is
    /// still at `baseRevision` (nil: any). A folder whose record came from elsewhere (claude.ai)
    /// is kept as it is, and a canvas holds at most `DesignIndex.maxSystems` systems.
    func installSystem(_ id: DesignID, namespace: String, record: DesignIndex.SystemRecord, files: [String: Data],
                       baseRevision: UInt64?) async throws -> DesignWriteResult {
        try await run {
            var design = try self.load(id)
            try Self.compare(baseRevision, design.revision)
            guard DesignPath.isSystemNamespace(namespace) else { throw DesignSystemError.invalidNamespace(namespace) }
            guard files[DesignSystemFile.tokens] != nil else { throw DesignSystemError.noTokens(namespace) }
            var systems = design.index.designSystems ?? []
            let at = systems.firstIndex { $0.namespace == namespace }
            if let at, !systems[at].isShepherds { throw DesignSystemError.namespaceTaken(namespace) }
            guard let project = self.projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let folder = project.appendingPathComponent("ds", isDirectory: true).appendingPathComponent(namespace, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path), at == nil {
                throw DesignSystemError.namespaceTaken(namespace)
            }
            var next = design.index
            if let at {
                systems[at] = record
                // A later record of the same folder goes.
                systems = systems.enumerated().filter { $0.offset == at || $0.element.namespace != namespace }.map(\.element)
            } else {
                systems.append(record)
            }
            next.designSystems = systems
            let known = Set(design.index.problems())
            let problems = next.problems().filter { !known.contains($0) }
            guard problems.isEmpty else { throw DesignStoreError.invalidIndex(problems) }
            let boards = try self.files(of: id, &design)
            let others = self.systemFileCount(project, excluding: namespace)
            guard boards.count + others + files.count + 1 <= Self.maxFiles else { throw DesignStoreError.tooManyFiles }
            guard Self.isInside(Self.deepestExisting(folder), project) else {
                throw DesignStoreError.io("ds/\(namespace) leads outside the design")
            }
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                for (path, data) in files.sorted(by: { $0.key < $1.key }) {
                    guard DesignSystemFile.isPath(path) else { throw DesignSystemError.invalidFile(path) }
                    let url = folder.appendingPathComponent(path)
                    // Checked before anything is made, so a link under ds/ never has a folder made through it.
                    guard Self.isInside(Self.deepestExisting(url.deletingLastPathComponent()), folder) else {
                        throw DesignSystemError.invalidFile(path)
                    }
                    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
                }
                for stale in self.systemFiles(folder) where files[stale] == nil {
                    try? manager.removeItem(at: folder.appendingPathComponent(stale))
                }
                try next.encoded().write(to: self.indexURL(id), options: .atomic)
            } catch let error as DesignSystemError {
                throw error
            } catch {
                throw DesignStoreError.io("could not install \(namespace): \(error.localizedDescription)")
            }
            design.index = next
            try self.commit(&design, id)
            return DesignWriteResult(revision: design.revision, changed: true, title: next.title, boardCount: next.boards.count)
        }
    }

    /// The systems canvas.json records, with the tokens each copy under `ds/` holds: its
    /// tokens.json, else the custom properties of its tokens.css.
    public func installedSystems(_ id: DesignID) async throws -> [DesignSystemInstalled] {
        try await run {
            let design = try self.load(id)
            guard let project = self.projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            return (design.index.designSystems ?? []).compactMap { record -> DesignSystemInstalled? in
                guard let namespace = record.namespace, DesignPath.isSystemNamespace(namespace) else { return nil }
                let folder = project.appendingPathComponent("ds", isDirectory: true).appendingPathComponent(namespace, isDirectory: true)
                var tokens: DesignSystemTokens?
                var file: String?
                let json = folder.appendingPathComponent(DesignSystemFile.tokens)
                let css = folder.appendingPathComponent(DesignSystemFile.stylesheet)
                if Self.isInside(json, project), let data = try? Data(contentsOf: json), let read = try? DesignSystemTokens.decode(data) {
                    tokens = read
                    file = "ds/\(namespace)/\(DesignSystemFile.tokens)"
                } else if Self.isInside(css, project), let text = try? String(contentsOf: css, encoding: .utf8) {
                    let declared = DesignSystemCSS.declarations(text, file: DesignSystemFile.stylesheet)
                    var read = DesignSystemTokens(name: record.title, namespace: namespace)
                    read.colors = declared.filter { DesignSystemCSS.isHex($0.value) }.map {
                        .init(name: $0.name, value: $0.value, source: .init(file: $0.file, line: $0.line))
                    }
                    for found in declared {
                        guard let px = DesignSystemCSS.px(found.value) else { continue }
                        let step = DesignSystemTokens.Length(name: found.name, px: px, source: .init(file: found.file, line: found.line))
                        switch DesignTokens.role(of: found.name) {
                        case .radius: read.radii.append(step)
                        case .text: continue
                        case .spacing, nil: read.spacing.append(step)
                        }
                    }
                    tokens = read
                    file = "ds/\(namespace)/\(DesignSystemFile.stylesheet)"
                }
                return DesignSystemInstalled(namespace: namespace, title: record.title, shepherd: record.isShepherds,
                                             version: record.extra["version"]?.stringValue, tokens: tokens, tokensFile: file)
            }
        }
    }

    /// The files under a system's folder in a design, by path relative to it.
    private func systemFiles(_ folder: URL) -> [String] {
        let root = folder.resolvingSymlinksInPath().path + "/"
        var out: [String] = []
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            out.append(String(resolved.dropFirst(root.count)))
        }
        return out
    }

    /// How many files the design's `ds/` holds outside `namespace`'s folder.
    private func systemFileCount(_ project: URL, excluding namespace: String) -> Int {
        let ds = project.appendingPathComponent("ds", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: ds.path)) ?? []
        return names.filter { $0 != namespace }.reduce(0) { $0 + systemFiles(ds.appendingPathComponent($1, isDirectory: true)).count }
    }

    // MARK: Serving files (remote)

    /// Every file under the design's `project/` a board may load, with its hash and size: the
    /// boards and the rest (installed systems, stylesheets, fonts, images), by the path grammar,
    /// never through a link that leads out of `project/`, and never `canvas.json` (the index) or
    /// a `support.js` (each device serves its own runtime there). A file's hash is kept while its
    /// size and modification time stay the same.
    public func projectFiles(_ id: DesignID) async throws -> [RemoteDesignFileInfo] {
        try await run {
            _ = try self.load(id)
            guard let project = self.projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            var known = self.servedHashes[id] ?? [:]
            var seen: [String: ServedHash] = [:]
            var files: [RemoteDesignFileInfo] = []
            let root = project.resolvingSymlinksInPath().path + "/"
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            let walker = FileManager.default.enumerator(at: project, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            while let url = walker?.nextObject() as? URL, files.count < Self.maxFiles {
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(root) else { continue }
                let relative = String(resolved.dropFirst(root.count))
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, values?.isSymbolicLink != true, Self.isServable(relative),
                      let size = values?.fileSize, size <= DesignImport.maxFileBytes else { continue }
                let modified = values?.contentModificationDate ?? .distantPast
                let hash: ServedHash
                if let cached = known[relative], cached.size == size, cached.modified == modified {
                    hash = cached
                } else {
                    guard let data = try? Data(contentsOf: url) else { continue }
                    hash = ServedHash(size: data.count, modified: modified, sha256: Self.sha256(data))
                }
                seen[relative] = hash
                files.append(RemoteDesignFileInfo(path: relative, sha256: hash.sha256, size: hash.size))
            }
            known = seen
            self.servedHashes[id] = known
            return files.sorted { $0.path < $1.path }
        }
    }

    /// One file of the design's `project/` as `projectFiles` lists it, with its hash; nil when the
    /// design has no such file. `path` is checked segment by segment before anything is read.
    public func projectFile(_ id: DesignID, path: String) async throws -> (data: Data, sha256: String)? {
        guard Self.isServable(path) else { throw DesignStoreError.io("\"\(path)\" names no file a design serves") }
        return try await run {
            _ = try self.load(id)
            guard let project = self.projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            guard let data = Self.readInside(project.appendingPathComponent(path), root: project) else { return nil }
            return (data, Self.sha256(data))
        }
    }

    /// An upload in the design's `assets/` (`/_blob/<id>`): its file name and bytes; nil when
    /// there is none. Only a regular file inside `assets/` is read.
    public func asset(_ id: DesignID, blobID: String) async throws -> (name: String, data: Data)? {
        guard DesignBundle.isAssetName(blobID), !blobID.contains(".") else {
            throw DesignStoreError.io("\"\(blobID)\" names no upload")
        }
        return try await run {
            _ = try self.load(id)
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let assets = folder.appendingPathComponent("assets", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path))?.sorted() ?? []
            guard let name = names.first(where: { ($0 == blobID || $0.hasPrefix(blobID + ".")) && DesignBundle.isAssetName($0) }),
                  let data = Self.readInside(assets.appendingPathComponent(name), root: assets) else { return nil }
            return (name, data)
        }
    }

    /// A served file read in pieces: `length` bytes from `offset`, and the whole file's size and
    /// hash.
    public struct Piece: Sendable {
        public var data: Data
        public var offset: Int
        public var total: Int
        public var sha256: String
    }

    /// A piece of one file of the design's `project/`, as `projectFile` would serve it; nil when
    /// the design has no such file. Only the piece's bytes are read once the file's hash is known.
    /// With `sha256`, a file whose hash moved answers its new hash with no bytes.
    public func projectFilePiece(_ id: DesignID, path: String, offset: Int, length: Int, sha256: String? = nil) async throws -> Piece? {
        guard Self.isServable(path) else { throw DesignStoreError.io("\"\(path)\" names no file a design serves") }
        return try await run {
            _ = try self.load(id)
            guard let project = self.projectFolder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            return try self.piece(id, key: "project/" + path, file: project.appendingPathComponent(path), root: project,
                                  offset: offset, length: length, sha256: sha256)
        }
    }

    /// A piece of an upload in the design's `assets/`, with its file name; nil when there is none.
    public func assetPiece(_ id: DesignID, blobID: String, offset: Int, length: Int) async throws -> (name: String, piece: Piece)? {
        guard DesignBundle.isAssetName(blobID), !blobID.contains(".") else {
            throw DesignStoreError.io("\"\(blobID)\" names no upload")
        }
        return try await run {
            _ = try self.load(id)
            guard let folder = self.folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
            let assets = folder.appendingPathComponent("assets", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: assets.path))?.sorted() ?? []
            guard let name = names.first(where: { ($0 == blobID || $0.hasPrefix(blobID + ".")) && DesignBundle.isAssetName($0) }),
                  let piece = try self.piece(id, key: "assets/" + name, file: assets.appendingPathComponent(name), root: assets,
                                             offset: offset, length: length) else { return nil }
            return (name, piece)
        }
    }

    /// Queue: a piece of a regular file that resolves (links followed) inside `root` and fits the
    /// cap. The whole file is read only while its hash isn't known for its size and modification
    /// time. `sha256` (the hash the asker holds): a file that no longer has it answers its new
    /// hash with no bytes, whatever the offset. An offset outside the file throws.
    private func piece(_ id: DesignID, key: String, file: URL, root: URL, offset: Int, length: Int,
                       sha256 expected: String? = nil) throws -> Piece? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= DesignImport.maxFileBytes else { return nil }
        let modified = values.contentModificationDate ?? .distantPast
        var whole: Data?
        let sha: String
        if let known = pieceHashes[id]?[key], known.size == size, known.modified == modified {
            sha = known.sha256
        } else {
            guard let data = try? Data(contentsOf: resolved), data.count == size else { return nil }
            sha = Self.sha256(data)
            pieceHashes[id, default: [:]][key] = ServedHash(size: size, modified: modified, sha256: sha)
            whole = data
        }
        if let expected, expected != sha { return Piece(data: Data(), offset: 0, total: size, sha256: sha) }
        guard offset >= 0, offset <= size else { throw RemoteDesignRefusal.badOffset(offset, size: size) }
        let end = offset + min(max(length, 0), size - offset)
        if let whole { return Piece(data: whole.subdata(in: offset..<end), offset: offset, total: size, sha256: sha) }
        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil, let data = try? handle.read(upToCount: end - offset) ?? Data(),
              data.count == end - offset else { return nil }
        return Piece(data: data, offset: offset, total: size, sha256: sha)
    }

    /// Whether a design serves `path` under its `project/`: segments by the file grammar, not
    /// the index, and no `support.js`.
    static func isServable(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.count <= 16, path != "canvas.json", segments.last != "support.js" else { return false }
        return segments.allSatisfy(DesignImport.isSegment)
    }

    /// A regular file's bytes, when it resolves (links followed) inside `root` and fits the cap.
    private static func readInside(_ file: URL, root: URL) -> Data? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/"),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= DesignImport.maxFileBytes else { return nil }
        return try? Data(contentsOf: resolved)
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

    /// Keeps several comments as one change, when the comments are still at `baseRevision`:
    /// each checked as `addComment` checks one, all kept or none. A draft naming a proposal the
    /// design already keeps a comment for isn't kept again; that comment is answered in its
    /// place. Answers the comments in the drafts' order, and which of them are new. The design
    /// agent's proposals from Pencil markup are kept this way when it makes them.
    func addComments(_ id: DesignID, drafts: [DesignCommentDraft], baseRevision: UInt64?,
                     at date: Double) async throws -> (comments: [DesignComment], added: Set<UUID>) {
        try await run {
            var design = try self.load(id)
            var file = try self.loadComments(id)
            try Self.compare(baseRevision, file.revision)
            guard !drafts.isEmpty, drafts.count <= DesignMarkupProposal.maxProposals else {
                throw DesignStoreError.invalidComment("keep 1 to \(DesignMarkupProposal.maxProposals) comments at once")
            }
            let files = try self.files(of: id, &design)
            var templates: [DesignPath: DesignTemplate] = [:]
            var result: [DesignComment] = []
            var added: Set<UUID> = []
            for draft in drafts {
                if let proposal = draft.proposal {
                    guard DesignCommentDraft.isProposalID(proposal) else {
                        throw DesignStoreError.invalidComment("a proposal's name is one line of at most 200 bytes")
                    }
                    if let kept = file.comments.first(where: { $0.proposal == proposal }) {
                        result.append(kept)
                        continue
                    }
                }
                guard let text = DesignComment.text(draft.text) else {
                    throw DesignStoreError.invalidComment("a comment is 1 to \(DesignComment.maxTextBytes) bytes of text")
                }
                guard file.comments.count < DesignComment.maxComments else { throw DesignStoreError.tooManyComments }
                guard files[draft.board] != nil, design.index.boards[draft.board] != nil else {
                    throw DesignStoreError.noSuchBoard(draft.board)
                }
                if templates[draft.board] == nil {
                    let data: Data
                    do { data = try Data(contentsOf: try self.fileURL(id, draft.board)) } catch { throw DesignStoreError.noSuchBoard(draft.board) }
                    templates[draft.board] = DesignTemplate(board: String(decoding: data, as: UTF8.self))
                }
                guard let element = DesignElementID(board: draft.board.viewName, tid: draft.tid, path: draft.path),
                      let template = templates[draft.board], template.element(for: element) != nil else {
                    throw DesignStoreError.invalidComment("\(draft.board) has no element \(draft.tid):\(draft.path.map(String.init).joined(separator: "/"))")
                }
                let comment = DesignComment(number: file.nextNumber, board: draft.board, tid: draft.tid, path: draft.path,
                                            label: template.labels[draft.tid],
                                            target: draft.target.flatMap(DesignViewRecord.label),
                                            rect: draft.rect.flatMap { $0.isValid ? $0 : nil },
                                            text: text, author: .user, createdAt: date, proposal: draft.proposal)
                file.comments.append(comment)
                result.append(comment)
                added.insert(comment.id)
            }
            if !added.isEmpty { try self.saveComments(&file, id) }
            return (result, added)
        }
    }

    /// The viewer's answer to proposals kept from Pencil markup (Apply, or Keep as comments):
    /// each named proposal's comment marked settled, all or none, when the comments are still at
    /// `baseRevision`. A proposal settled already stays as it was. Answers the comments in the
    /// names' order, and which of them settled now.
    func settleProposals(_ id: DesignID, proposals: [String], baseRevision: UInt64?,
                         at date: Double) async throws -> (comments: [DesignComment], settled: Set<UUID>) {
        try await run {
            _ = try self.load(id)
            var file = try self.loadComments(id)
            try Self.compare(baseRevision, file.revision)
            guard (1...DesignMarkupProposal.maxProposals).contains(proposals.count) else {
                throw DesignStoreError.invalidMarkup("settle 1 to \(DesignMarkupProposal.maxProposals) proposals at once")
            }
            var result: [DesignComment] = []
            var settled: Set<UUID> = []
            for proposal in proposals {
                guard DesignCommentDraft.isProposalID(proposal),
                      let index = file.comments.firstIndex(where: { $0.proposal == proposal }) else {
                    throw DesignStoreError.invalidMarkup("the design keeps no comment from proposal \(proposal)")
                }
                if file.comments[index].proposalSettledAt == nil {
                    file.comments[index].proposalSettledAt = date
                    settled.insert(file.comments[index].id)
                }
                result.append(file.comments[index])
            }
            if !settled.isEmpty { try self.saveComments(&file, id) }
            return (result, settled)
        }
    }

    // MARK: Pencil markup

    /// `markup` as the design agent is handed it: checked against its grammar, each mark on a
    /// board the canvas lists, its element one the board's source has now, and its label read
    /// from that source rather than taken from the viewer's device.
    func checkMarkup(_ id: DesignID, _ markup: DesignMarkup) async throws -> DesignMarkup {
        try await run {
            guard markup.isValid else {
                throw DesignStoreError.invalidMarkup("markup is 1 to \(DesignMarkup.maxStrokes) marks, each on a board by its view name")
            }
            let design = try self.load(id)
            let boards = Dictionary(design.index.boards.keys.map { ($0.viewName, $0) }, uniquingKeysWith: { a, _ in a })
            var templates: [DesignPath: DesignTemplate] = [:]
            var checked = markup
            for index in checked.strokes.indices {
                let stroke = checked.strokes[index]
                guard let path = boards[stroke.board] else { throw DesignStoreError.invalidMarkup("the canvas has no board \(stroke.board)") }
                guard let element = stroke.element else {
                    checked.strokes[index].label = nil
                    continue
                }
                let template = try self.template(id, path, &templates)
                guard template.element(for: element) != nil else {
                    throw DesignStoreError.invalidMarkup("\(path) has no element \(element)")
                }
                checked.strokes[index].label = template.labels[element.tid].flatMap(DesignViewRecord.label)
            }
            return checked
        }
    }

    /// The design agent's proposals from the markup (`markup_propose`), as the chat offers them:
    /// each element one a board of the canvas has now, its words a comment's, and its card's
    /// name the element's `data-el` name, else its words. Named `<call>#<n>`.
    func resolveProposals(_ id: DesignID, call: String, _ proposals: [DesignMarkupProposal]) async throws -> [DesignCommentDraft] {
        try await run {
            guard (1...DesignMarkupProposal.maxProposals).contains(proposals.count) else {
                throw DesignStoreError.invalidMarkup("propose 1 to \(DesignMarkupProposal.maxProposals) comments")
            }
            let design = try self.load(id)
            let boards = Dictionary(design.index.boards.keys.map { ($0.viewName, $0) }, uniquingKeysWith: { a, _ in a })
            var templates: [DesignPath: DesignTemplate] = [:]
            var sources: [DesignPath: String] = [:]
            return try proposals.enumerated().map { index, proposal in
                guard let element = DesignElementID(proposal.element), element.instance == nil else {
                    throw DesignStoreError.invalidMarkup("\"\(proposal.element)\" is not an element id (File.dc.html#tid:path)")
                }
                guard let path = boards[element.board] else { throw DesignStoreError.invalidMarkup("the canvas has no board \(element.board)") }
                let template = try self.template(id, path, &templates)
                guard template.element(for: element) != nil else { throw DesignStoreError.invalidMarkup("\(path) has no element \(element)") }
                guard let text = DesignComment.text(proposal.text) else {
                    throw DesignStoreError.invalidMarkup("a proposed comment is 1 to \(DesignComment.maxTextBytes) bytes of text")
                }
                if sources[path] == nil { sources[path] = try self.boardText(id, path) }
                let name = sources[path].flatMap { DesignStyleEdit.attribute("data-el", of: element.tid, in: $0) }
                let label = template.labels[element.tid]
                let proposalID = DesignMarkupProposals.proposalID(call: call, index: index)
                guard DesignCommentDraft.isProposalID(proposalID) else { throw DesignStoreError.invalidMarkup("the call's id is too long") }
                return DesignCommentDraft(board: path, tid: element.tid, path: element.path, label: label,
                                          target: (name ?? label).flatMap(DesignViewRecord.label), text: text, proposal: proposalID)
            }
        }
    }

    /// A board's template, read once per call.
    private func template(_ id: DesignID, _ path: DesignPath, _ cache: inout [DesignPath: DesignTemplate]) throws -> DesignTemplate {
        if let template = cache[path] { return template }
        guard let template = DesignTemplate(board: try boardText(id, path)) else {
            throw DesignStoreError.invalidMarkup("\(path) has no template")
        }
        cache[path] = template
        return template
    }

    private func boardText(_ id: DesignID, _ path: DesignPath) throws -> String {
        do { return String(decoding: try Data(contentsOf: try fileURL(id, path)), as: UTF8.self) } catch { throw DesignStoreError.noSuchBoard(path) }
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
