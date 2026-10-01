import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol

// The design agent's batch tools on the design store (docs/designs.md › The design agent):
// reported writes with token enforcement, `boards_edit`, `board_search`, the usage index, and
// checkpoints. Everything here runs on the store's queue, as one step of it where a read and a
// write must not be parted, and writes through the same path every board write takes.

extension DesignStore {
    // MARK: A reported write

    /// A board's text as its file holds it now; nil when it has none.
    func currentText(_ id: DesignID, _ path: DesignPath) -> String? {
        guard let url = try? fileURL(id, path), let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The tokens a design's boards are held to: those of its installed systems.
    func tokenSet(_ id: DesignID, index: DesignIndex) -> DesignTokenSet {
        DesignTokenSet(systems: (try? installedSystemsOnQueue(id, index: index)) ?? [])
    }

    /// Writes `new` over `old` (nil: a new board) as `writeOnQueue` does, held to the design's tokens
    /// by `mode` (a `strict` write that introduces off-system values writes nothing), and reports
    /// on the board it left.
    func writeReported(_ id: DesignID, path: DesignPath, old: String?, new: String, baseRevision: UInt64?,
                       mode: DesignTokenMode) throws -> (written: Written, report: DesignBoardReport) {
        var design = try load(id)
        try Self.compare(baseRevision, design.revision)
        let tokens = tokenSet(id, index: design.index)
        var source = new
        var enforcement: DesignTokenCheck.Enforcement?
        if !tokens.isEmpty {
            let found = DesignTokenCheck.enforce(mode, tokens: tokens, old: old, new: new)
            if mode == .strict, !found.remaining.isEmpty {
                if case .failure(let refusal) = Result(catching: { () throws(DesignBoardCheck.Refusal) in _ = try DesignBoardCheck.check(new) }) {
                    throw DesignStoreError.refused(refusal)
                }
                throw DesignStoreError.offSystem(path, system: tokens.source, found.remaining)
            }
            source = found.source
            enforcement = found
        }
        let written = try writeOnQueue(id, [path: source], baseRevision: baseRevision)
        design = try load(id)
        let files = try self.files(of: id, &design)
        let report = DesignBoardReporter.report(path: path, old: old, new: source, frame: design.index.boards[path],
                                                boards: Set(files.keys), tokens: tokens.isEmpty ? nil : tokens, enforcement: enforcement)
        return (written, report)
    }

    // MARK: boards_edit

    /// Applies `request`'s edits to each board it names, independently, and writes every board
    /// that changed as one change: one revision, one comment-anchor pass, one live reload. A
    /// board whose edits match nothing (or several times without `all`), that doesn't exist, or
    /// whose result fails the board checks is reported and left as it is; with `atomic`, any of
    /// those writes nothing at all. `dryRun` reports and writes nothing. A `checkpoint` is saved
    /// first, only when there is something to write.
    func editBoards(_ id: DesignID, request: DesignBatchEditRequest) async throws -> DesignBatchResult {
        try await run { try self.editBoardsOnQueue(id, request) }
    }

    private struct Candidate {
        var path: DesignPath
        var old: String
        var source: String
        var replaced: [Int]
        var enforcement: DesignTokenCheck.Enforcement?
        var slot: Int
    }

    private func editBoardsOnQueue(_ id: DesignID, _ request: DesignBatchEditRequest) throws -> DesignBatchResult {
        var design = try load(id)
        try Self.compare(request.baseRevision, design.revision)
        guard !request.boards.isEmpty else { throw DesignStoreError.invalidEdit("boards_edit needs at least one board") }
        guard request.boards.count <= DesignBatchEditRequest.maxBoards else {
            throw DesignStoreError.invalidEdit("boards_edit takes at most \(DesignBatchEditRequest.maxBoards) boards, not \(request.boards.count); split the call")
        }
        guard request.snapExisting || !request.edits.isEmpty || request.boards.contains(where: { !($0.edits ?? []).isEmpty }) else {
            throw DesignStoreError.invalidEdit("boards_edit needs edits: {find, replace}, shared or per board")
        }
        var checkpointName: String?
        if let raw = request.checkpoint {
            guard let clean = DesignCheckpointName.clean(raw) else {
                throw DesignStoreError.invalidCheckpoint("a checkpoint name is 1 to \(DesignCheckpointName.maxLength) characters of letters, digits, spaces and _ - . , ' ( ) # + :")
            }
            checkpointName = clean
        }
        let mode = request.tokens ?? .warn
        let files = try self.files(of: id, &design)
        let tokens = tokenSet(id, index: design.index)

        var results: [DesignBatchBoardResult] = []
        var candidates: [Candidate] = []
        var seen = Set<String>()
        for board in request.boards {
            let slot = results.count
            func finish(_ status: DesignBatchBoardResult.Status, edit: Int? = nil, matches: Int? = nil, message: String? = nil) {
                results.append(DesignBatchBoardResult(path: board.path, status: status, edit: edit, matches: matches, message: message))
            }
            guard seen.insert(board.path).inserted else { finish(.invalid, message: "named twice in this call"); continue }
            let path: DesignPath
            do { path = try DesignPath.validate(board.path) } catch {
                finish(.invalid, message: error.description)
                continue
            }
            guard files[path] != nil, let old = currentText(id, path) else { finish(.missing, message: "no board at \(path)"); continue }
            let edits = board.edits ?? request.edits
            var source = old
            var replaced: [Int] = []
            if edits.isEmpty {
                guard request.snapExisting else { finish(.invalid, message: "no edits for this board"); continue }
            } else {
                switch Result(catching: { () throws(DesignBoardEdits.Failure) in try DesignBoardEdits.apply(edits, to: old) }) {
                case .success(let applied):
                    source = applied.source
                    replaced = applied.replaced
                case .failure(let failure):
                    let brief = failure.brief
                    switch failure {
                    case .notFound, .ambiguous: finish(.noMatch, edit: brief.edit, matches: brief.matches, message: brief.message)
                    case .tooLarge: finish(.refused, edit: brief.edit, message: brief.message)
                    default: finish(.invalid, edit: brief.edit, message: brief.message)
                    }
                    continue
                }
            }
            var enforcement: DesignTokenCheck.Enforcement?
            if !tokens.isEmpty {
                let found = DesignTokenCheck.enforce(request.snapExisting ? .snap : mode, tokens: tokens, old: old, new: source,
                                                     all: request.snapExisting)
                if mode == .strict, !request.snapExisting, !found.remaining.isEmpty {
                    let error = DesignStoreError.offSystem(path, system: tokens.source, found.remaining)
                    finish(.refused, message: error.description)
                    continue
                }
                source = found.source
                enforcement = found
            }
            guard source != old else {
                results.append(DesignBatchBoardResult(path: board.path, status: .unchanged, replaced: replaced))
                continue
            }
            if case .failure(let refusal) = Result(catching: { () throws(DesignBoardCheck.Refusal) in _ = try DesignBoardCheck.check(source) }) {
                finish(.refused, message: "the edited board can't be written: \(refusal.description)")
                continue
            }
            candidates.append(Candidate(path: path, old: old, source: source, replaced: replaced, enforcement: enforcement, slot: slot))
            results.append(DesignBatchBoardResult(path: board.path, status: .wouldEdit, replaced: replaced))
        }

        let failed = results.contains { [.noMatch, .refused, .missing, .invalid].contains($0.status) }
        let blocked = request.atomic && failed
        func reports(_ boards: Set<DesignPath>, index: DesignIndex) {
            for candidate in candidates {
                results[candidate.slot].report = DesignBoardReporter.report(
                    path: candidate.path, old: candidate.old, new: candidate.source, frame: index.boards[candidate.path], boards: boards,
                    tokens: tokens.isEmpty ? nil : tokens, enforcement: candidate.enforcement)
            }
        }
        if request.dryRun || blocked || candidates.isEmpty {
            reports(Set(files.keys), index: design.index)
            let write = DesignWriteResult(revision: design.revision, changed: false, title: design.index.title,
                                          boardCount: design.index.boards.count)
            return DesignBatchResult(result: write, boards: results, dryRun: request.dryRun, atomic: request.atomic, blocked: blocked)
        }

        var checkpoint: DesignCheckpointInfo?
        var pruned: [String] = []
        if let checkpointName {
            let made = try createCheckpointOnQueue(id, name: checkpointName)
            checkpoint = made.info
            pruned = made.pruned
        }
        let written = try writeOnQueue(id, Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0.source) }), baseRevision: nil)
        design = try load(id)
        let after = try self.files(of: id, &design)
        reports(Set(after.keys), index: design.index)
        for candidate in candidates { results[candidate.slot].status = .edited }
        return DesignBatchResult(result: written.result, boards: results, dryRun: false, atomic: request.atomic, blocked: false,
                                 checkpoint: checkpoint, pruned: pruned)
    }

    // MARK: board_extract

    /// Lifts an element out of a board into a piece, puts a `<dc-import>` in its place, replaces exact
    /// copies in other boards, and places the piece on the canvas when asked: the piece, every
    /// changed board and canvas.json as one revision (`DesignExtraction`).
    func extract(_ id: DesignID, request: DesignExtractRequest) async throws -> DesignExtractResult {
        try await run { try self.extractOnQueue(id, request) }
    }

    private func extractOnQueue(_ id: DesignID, _ request: DesignExtractRequest) throws -> DesignExtractResult {
        var design = try load(id)
        try Self.compare(request.baseRevision, design.revision)
        let files = try self.files(of: id, &design)
        let board: DesignPath
        do { board = try DesignPath.validate(request.path) } catch { throw DesignStoreError.invalidPath(request.path, error) }
        guard files[board] != nil, let boardText = currentText(id, board) else { throw DesignStoreError.noSuchBoard(board) }
        var checkpointName: String?
        if let raw = request.checkpoint {
            guard let clean = DesignCheckpointName.clean(raw) else {
                throw DesignStoreError.invalidCheckpoint("a checkpoint name is 1 to \(DesignCheckpointName.maxLength) characters of letters, digits, spaces and _ - . , ' ( ) # + :")
            }
            checkpointName = clean
        }
        let piece: DesignPath
        switch Result(catching: { () throws(DesignExtraction.Failure) in try DesignExtraction.piecePath(request.piece, beside: board) }) {
        case .success(let path): piece = path
        case .failure(let failure): throw DesignStoreError.invalidExtract(failure.message)
        }
        let stem = piece.stem.lowercased()
        if let other = Set(files.keys).union(design.index.boards.keys).sorted().first(where: { $0.stem.lowercased() == stem }) {
            throw DesignStoreError.invalidExtract("\(other) already has the name \(piece.stem): pick another name for the piece, or import \(other)")
        }

        var sources: [DesignPath: String] = [board: boardText]
        var skipped: [DesignExtractResult.Skipped] = []
        if request.allCopies {
            for path in orderedBoards(design, files: files) where path != board {
                if let text = currentText(id, path) { sources[path] = text }
            }
        } else {
            for raw in request.copies {
                guard let path = DesignPath(raw) else { skipped.append(.init(path: raw, why: "not a board path")); continue }
                guard path != board else { continue }
                guard files[path] != nil, let text = currentText(id, path) else { skipped.append(.init(path: raw, why: "no such board")); continue }
                sources[path] = text
            }
        }
        let plan: DesignExtraction.Plan
        switch Result(catching: { () throws(DesignExtraction.Failure) in
            try DesignExtraction.plan(request, board: board, piece: piece, sources: sources)
        }) {
        case .success(let made): plan = made
        case .failure(let failure): throw DesignStoreError.invalidExtract(failure.message)
        }

        var index: DesignIndex?
        if let frame = request.frame {
            let bottom = design.index.boards.values.map { $0.y + $0.h }.max() ?? -120
            var entry: [String: JSONValue] = [
                "x": .number(frame.x ?? 0), "y": .number(frame.y ?? bottom + 120),
                "w": .number(frame.w ?? plan.size.width), "h": .number(frame.h ?? plan.size.height),
                "title": .string(frame.title ?? piece.stem),
            ]
            if let page = frame.page { entry["page"] = .string(page) }
            let merged: DesignIndex
            do { merged = try design.index.merging(.object(["boards": .object([piece.rawValue: .object(entry)])])) } catch {
                throw DesignStoreError.invalidIndex([String(describing: error)])
            }
            let known = Set(design.index.problems())
            let problems = merged.problems().filter { !known.contains($0) }
            guard problems.isEmpty else { throw DesignStoreError.invalidIndex(problems) }
            index = merged
        }

        var checkpoint: DesignCheckpointInfo?
        var pruned: [String] = []
        if let checkpointName {
            let made = try createCheckpointOnQueue(id, name: checkpointName)
            checkpoint = made.info
            pruned = made.pruned
        }
        var all = plan.sources
        all[piece] = plan.pieceSource
        let written = try writeOnQueue(id, all, baseRevision: nil, index: index)
        design = try load(id)
        let after = try self.files(of: id, &design)
        func report(_ path: DesignPath, old: String?, new: String) -> DesignBoardReport {
            DesignBoardReporter.report(path: path, old: old, new: new, frame: design.index.boards[path], boards: Set(after.keys),
                                       tokens: nil, enforcement: nil)
        }
        let copies = plan.replaced.sorted { $0.key < $1.key }.map { path, count in
            DesignExtractResult.Replaced(path: path.rawValue, count: count, report: report(path, old: sources[path], new: plan.sources[path] ?? ""))
        }
        return DesignExtractResult(
            result: written.result, piece: piece.rawValue, importTag: plan.importTag, boards: copies, skipped: skipped + plan.skipped,
            warnings: plan.warnings, pieceReport: report(piece, old: nil, new: plan.pieceSource),
            sourceReport: report(board, old: boardText, new: plan.sources[board] ?? boardText), checkpoint: checkpoint, pruned: pruned)
    }

    // MARK: board_search

    /// The design's boards in canvas order (back to front), then any the canvas doesn't list.
    func orderedBoards(_ design: Loaded, files: [DesignPath: String]) -> [DesignPath] {
        var seen = Set<DesignPath>()
        let listed = design.index.order.filter { files[$0] != nil && seen.insert($0).inserted }
        return listed + files.keys.filter { !seen.contains($0) }.sorted()
    }

    func search(_ id: DesignID, query: DesignSearchQuery) async throws -> DesignSearchResult {
        try await run {
            var design = try self.load(id)
            let files = try self.files(of: id, &design)
            var paths = self.orderedBoards(design, files: files)
            if let named = query.paths, !named.isEmpty {
                paths = try named.map { raw in
                    guard let path = DesignPath(raw) else { throw DesignStoreError.invalidSearch(.badPath(raw)) }
                    guard files[path] != nil else { throw DesignStoreError.noSuchBoard(path) }
                    return path
                }
            }
            let boards = paths.compactMap { path in self.currentText(id, path).map { (path: path, source: $0) } }
            switch Result(catching: { () throws(DesignBoardSearch.Failure) in
                try DesignBoardSearch.run(query, boards: boards, known: Set(files.keys))
            }) {
            case .success(let result): return result
            case .failure(let failure): throw DesignStoreError.invalidSearch(failure)
            }
        }
    }

    // MARK: Usage

    /// Which boards import which, at the design's current revision: built once per revision, and
    /// reading only the boards whose hash changed since the last build.
    public func usage(_ id: DesignID) async throws -> DesignUsageIndex {
        try await run {
            var design = try self.load(id)
            if let cached = self.usageIndexes[id], cached.revision == design.revision { return cached.index }
            let files = try self.files(of: id, &design)
            var cache = self.importsBySHA[id] ?? [:]
            var imports: [DesignPath: [DesignImports.Reference]] = [:]
            var live = Set<String>()
            for (path, sha) in files {
                live.insert(sha)
                let raw: [DesignImports.Raw]
                if let hit = cache[sha] {
                    raw = hit
                } else {
                    raw = self.currentText(id, path).flatMap(DesignBoardTree.init(source:)).map { DesignImports.raw(in: $0) } ?? []
                    cache[sha] = raw
                }
                imports[path] = DesignImports.references(raw, of: path)
            }
            self.importsBySHA[id] = cache.filter { live.contains($0.key) }
            let index = DesignUsageIndex.build(imports: imports, boards: Set(files.keys))
            self.usageIndexes[id] = (design.revision, index)
            return index
        }
    }

    // MARK: Checkpoints

    /// Where a design's checkpoints live: beside `project/`, so nothing serves them, an export
    /// carries none and a duplicate starts with none (as with versions and comments).
    private func checkpointsFolder(_ id: DesignID) throws -> URL {
        guard let folder = folder(for: id) else { throw DesignStoreError.invalidDesignID(id.rawValue) }
        return folder.appendingPathComponent("checkpoints", isDirectory: true)
    }

    /// A name's folder: a hash of the lower-cased name, so a name is unique whatever its case and
    /// nothing in it reaches the file system.
    private func checkpointToken(_ name: String) -> String {
        SHA256.hash(data: Data(name.lowercased().utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private struct CheckpointManifest: Codable {
        var name: String
        var createdAt: Double
        var revision: UInt64
        var boards: [String]
        var bytes: Int
    }

    private struct StoredCheckpoint {
        var token: String
        var folder: URL
        var manifest: CheckpointManifest

        var info: DesignCheckpointInfo {
            DesignCheckpointInfo(name: manifest.name, createdAt: manifest.createdAt, boards: manifest.boards.count, bytes: manifest.bytes,
                                 revision: manifest.revision)
        }
    }

    /// The design's checkpoints, oldest first.
    private func storedCheckpoints(_ id: DesignID) throws -> [StoredCheckpoint] {
        let root = try checkpointsFolder(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> StoredCheckpoint? in
            guard !name.hasPrefix(".") else { return nil }
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONDecoder().decode(CheckpointManifest.self, from: data),
                  checkpointToken(manifest.name) == name else { return nil }
            return StoredCheckpoint(token: name, folder: folder, manifest: manifest)
        }
        .sorted { ($0.manifest.createdAt, $0.manifest.name) < ($1.manifest.createdAt, $1.manifest.name) }
    }

    func checkpoints(_ id: DesignID) async throws -> DesignCheckpointResult {
        try await run {
            _ = try self.load(id)
            return DesignCheckpointResult(action: .list, checkpoints: try self.storedCheckpoints(id).map(\.info))
        }
    }

    /// Saves the design's boards and canvas under `name`.
    func createCheckpoint(_ id: DesignID, name: String) async throws -> DesignCheckpointResult {
        try await run {
            let made = try self.createCheckpointOnQueue(id, name: name)
            return DesignCheckpointResult(action: .create, checkpoints: try self.storedCheckpoints(id).map(\.info), checkpoint: made.info,
                                          pruned: made.pruned)
        }
    }

    /// Queue: saves every board file and canvas.json as they are now. Past
    /// `DesignCheckpointName.maxPerDesign` checkpoints, or the byte cap, the oldest go first (not
    /// `protecting`'s) and are named in the answer.
    func createCheckpointOnQueue(_ id: DesignID, name raw: String, protecting: String? = nil,
                                 now: Date = Date()) throws -> (info: DesignCheckpointInfo, pruned: [String]) {
        guard let name = DesignCheckpointName.clean(raw) else {
            throw DesignStoreError.invalidCheckpoint("a checkpoint name is 1 to \(DesignCheckpointName.maxLength) characters of letters, digits, spaces and _ - . , ' ( ) # + :, starting with a letter or digit")
        }
        var design = try load(id)
        let files = try self.files(of: id, &design)
        let token = checkpointToken(name)
        var existing = try storedCheckpoints(id)
        if existing.contains(where: { $0.token == token }) { throw DesignStoreError.checkpointExists(name) }
        var boards: [(path: DesignPath, data: Data)] = []
        var total = 0
        for path in files.keys.sorted() {
            guard let data = try? Data(contentsOf: fileURL(id, path)) else { continue }
            boards.append((path, data))
            total += data.count
        }
        guard let canvas = try? Data(contentsOf: indexURL(id)) else { throw DesignStoreError.io("could not read canvas.json") }
        total += canvas.count
        guard total <= checkpointCaps.bytes else { throw DesignStoreError.checkpointTooLarge(total) }

        let root = try checkpointsFolder(id)
        let staging = root.appendingPathComponent(".new-\(UUID().uuidString)", isDirectory: true)
        let manifest = CheckpointManifest(name: name, createdAt: (now.timeIntervalSince1970 * 1000).rounded(), revision: design.revision,
                                          boards: boards.map(\.path.rawValue), bytes: total)
        do {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("boards", isDirectory: true), withIntermediateDirectories: true)
            for (path, data) in boards {
                let url = staging.appendingPathComponent("boards", isDirectory: true).appendingPathComponent(path.rawValue)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            try canvas.write(to: staging.appendingPathComponent("canvas.json"))
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw DesignStoreError.io("could not save the checkpoint: \(error.localizedDescription)")
        }
        var pruned: [String] = []
        while existing.count >= checkpointCaps.count || existing.reduce(0, { $0 + $1.manifest.bytes }) + total > checkpointCaps.bytes {
            guard let victim = existing.first(where: { $0.token != protecting }) else {
                try? FileManager.default.removeItem(at: staging)
                throw DesignStoreError.checkpointTooLarge(total)
            }
            try? FileManager.default.removeItem(at: victim.folder)
            pruned.append(victim.manifest.name)
            existing.removeAll { $0.token == victim.token }
        }
        do { try FileManager.default.moveItem(at: staging, to: root.appendingPathComponent(token, isDirectory: true)) } catch {
            try? FileManager.default.removeItem(at: staging)
            throw DesignStoreError.io("could not save the checkpoint: \(error.localizedDescription)")
        }
        return (DesignCheckpointInfo(name: name, createdAt: manifest.createdAt, boards: boards.count, bytes: total, revision: design.revision), pruned)
    }

    /// Puts every board and canvas.json back to what the checkpoint holds, as one revision, after
    /// saving the design as `before restore <name>` so a restore can be undone. The design's
    /// installed systems (`designSystems` in canvas.json, and `ds/`) and its comments are not part
    /// of a checkpoint and are left alone, apart from comments finding their elements again on
    /// boards whose content changed (and detaching from boards the restore removed). A board
    /// written after the checkpoint is removed; one deleted since is made again.
    func restoreCheckpoint(_ id: DesignID, name raw: String) async throws -> DesignCheckpointResult {
        try await run {
            guard let name = DesignCheckpointName.clean(raw) else {
                throw DesignStoreError.invalidCheckpoint("a checkpoint name is 1 to \(DesignCheckpointName.maxLength) characters")
            }
            var design = try self.load(id)
            let token = self.checkpointToken(name)
            guard let target = try self.storedCheckpoints(id).first(where: { $0.token == token }) else {
                throw DesignStoreError.noSuchCheckpoint(name)
            }
            var held: [DesignPath: Data] = [:]
            for raw in target.manifest.boards {
                guard let path = DesignPath(raw),
                      let data = try? Data(contentsOf: target.folder.appendingPathComponent("boards", isDirectory: true).appendingPathComponent(raw)) else {
                    throw DesignStoreError.io("the checkpoint \"\(name)\" is damaged: \(raw) is missing")
                }
                held[path] = data
            }
            guard let canvasData = try? Data(contentsOf: target.folder.appendingPathComponent("canvas.json")),
                  var index = try? DesignIndex.decode(canvasData) else {
                throw DesignStoreError.io("the checkpoint \"\(name)\" is damaged: its canvas.json can't be read")
            }
            // Installing a system is the design's own change, never a checkpoint's.
            index.designSystems = design.index.designSystems
            index = index.inSync()
            var files = try self.files(of: id, &design)
            var restored: [DesignPath] = [], recreated: [DesignPath] = []
            for (path, data) in held.sorted(by: { $0.key < $1.key }) {
                if files[path] == nil { recreated.append(path) } else if files[path] != Self.sha256(data) { restored.append(path) }
            }
            let removed = files.keys.filter { held[$0] == nil }.sorted()
            if restored.isEmpty, recreated.isEmpty, removed.isEmpty, index == design.index {
                let write = DesignWriteResult(revision: design.revision, changed: false, title: design.index.title, boardCount: design.index.boards.count)
                return DesignCheckpointResult(action: .restore, checkpoints: try self.storedCheckpoints(id).map(\.info), checkpoint: target.info,
                                              write: write)
            }
            var autoName = DesignCheckpointName.beforeRestore(name)
            var attempt = 2
            while try self.storedCheckpoints(id).contains(where: { $0.token == self.checkpointToken(autoName) }) {
                let suffix = " \(attempt)"
                autoName = String(DesignCheckpointName.beforeRestore(name).prefix(DesignCheckpointName.maxLength - suffix.count)) + suffix
                attempt += 1
            }
            let auto = try self.createCheckpointOnQueue(id, name: autoName, protecting: target.token)

            for path in recreated + restored {
                guard let data = held[path] else { continue }
                if files[path] != nil { _ = try self.keepVersion(id, path) }
                try self.writeFile(id, path, data)
                files[path] = Self.sha256(data)
            }
            for path in removed {
                if let url = try? self.fileURL(id, path) { try? FileManager.default.removeItem(at: url) }
                files[path] = nil
            }
            do { try index.encoded().write(to: self.indexURL(id), options: .atomic) } catch {
                throw DesignStoreError.io("could not write canvas.json: \(error.localizedDescription)")
            }
            design.index = index
            design.files = files
            try self.commit(&design, id)
            for path in restored + recreated {
                if let data = held[path] { self.reanchorComments(id, board: path, source: String(decoding: data, as: UTF8.self)) }
            }
            for path in removed { self.reanchorComments(id, board: path, source: nil) }
            let write = DesignWriteResult(revision: design.revision, changed: true, title: index.title, boardCount: index.boards.count)
            return DesignCheckpointResult(action: .restore, checkpoints: try self.storedCheckpoints(id).map(\.info), checkpoint: target.info,
                                          automatic: auto.info, pruned: auto.pruned, write: write, restored: restored.map(\.rawValue),
                                          recreated: recreated.map(\.rawValue), removed: removed.map(\.rawValue))
        }
    }
}
