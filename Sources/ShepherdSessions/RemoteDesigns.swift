import CryptoKit
import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

/// Why a remote design request was refused: a stable code and words for the client.
struct RemoteDesignRefusal: Error, Sendable {
    let code: String
    let message: String

    init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    /// A piece asked for from outside the file.
    static func badOffset(_ offset: Int, size: Int?) -> RemoteDesignRefusal {
        RemoteDesignRefusal("invalid_offset", size.map { "offset \(offset) is outside a file of \($0) bytes" } ?? "offset \(offset) is outside the file")
    }

    /// The refusal for any error a design request can meet.
    init(_ error: Error) {
        switch error {
        case let error as RemoteDesignRefusal: self = error
        case let error as DesignStoreError: self.init(error.code, error.description)
        case let error as DesignSystemError: self.init(error.code, error.description)
        case SessionServerError.noSuchDesign(let id): self.init(DesignStoreError.noSuchDesign(id).code, "unknown design \(id)")
        case let error as SessionServerError: self.init("design_refused", error.description)
        default: self.init("design_failed", String(describing: error))
        }
    }
}

/// Answers a remote client's design requests (`designs.v1`) from the host's own design store and
/// server mutations, so a remote write passes every check a local one does. Runs off the server
/// queue; the design store reads and writes on its own. Paths are checked against the grammar
/// before a file is touched, and only a design's `project/` files and its uploads are served.
struct RemoteDesignService: Sendable {
    let server: SessionServer

    func answer(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        // A design being undone is out of the workspace until it is back.
        if case .undoDelete(let id) = request {
            try await server.undoDesignDeletion(id)
            return .ok
        }
        if let id = request.designID, !server.state.designs.contains(where: { $0.id == id }) {
            throw SessionServerError.noSuchDesign(id)
        }
        let designs = server.designs
        switch request {
        case .list:
            return .listing(try await listing())
        case .index(let id):
            async let snapshot = server.designSnapshot(id)
            async let files = designs.projectFiles(id)
            return .index(RemoteDesignIndex(snapshot: try await snapshot, files: try await files))
        case .boards(let id, let paths, let known):
            return .files(try await files(id, paths: paths, known: known))
        case .file(let id, let path, let sha, let offset):
            guard DesignStore.isServable(path) else {
                throw RemoteDesignRefusal("invalid_path", "\"\(path)\" names no file a design serves.")
            }
            guard offset >= 0 else { throw RemoteDesignRefusal.badOffset(offset, size: nil) }
            guard let piece = try await designs.projectFilePiece(id, path: path, offset: offset, length: RemoteProtocol.designChunkBytes,
                                                                    sha256: sha) else {
                throw RemoteDesignRefusal(RemoteDesignCode.noSuchFile, "The design has no \(path).")
            }
            guard piece.sha256 == sha else {
                throw RemoteDesignRefusal(RemoteDesignCode.staleFile, "\(path) changed since it was listed; read the design again.")
            }
            return .chunk(RemoteDesignChunk(sha256: piece.sha256, offset: piece.offset, total: piece.total, data: piece.data))
        case .asset(let id, let blobID, let offset):
            guard DesignBundle.isAssetName(blobID), !blobID.contains(".") else {
                throw RemoteDesignRefusal("invalid_path", "\"\(blobID)\" names no upload.")
            }
            guard offset >= 0 else { throw RemoteDesignRefusal.badOffset(offset, size: nil) }
            guard let asset = try await designs.assetPiece(id, blobID: blobID, offset: offset, length: RemoteProtocol.designChunkBytes) else {
                throw RemoteDesignRefusal(RemoteDesignCode.noSuchFile, "The design has no upload \(blobID).")
            }
            let piece = asset.piece
            return .chunk(RemoteDesignChunk(name: asset.name, sha256: piece.sha256, offset: piece.offset, total: piece.total, data: piece.data))
        case .comments(let id):
            return .comments(try await server.designComments(id))
        case .addComment(let id, let draft, let base):
            let outcome = try await server.addDesignComment(id, draft: draft, baseRevision: base)
            return .comment(outcome.comment, undelivered: outcome.undelivered)
        case .replyToComment(let id, let comment, let text, let base):
            let outcome = try await server.replyToDesignComment(id, commentID: comment, text: text, baseRevision: base)
            return .comment(outcome.comment, undelivered: outcome.undelivered)
        case .resolveComment(let id, let comment, let resolved, let base):
            return .comment(try await server.resolveDesignComment(id, commentID: comment, resolved: resolved, baseRevision: base),
                            undelivered: nil)
        case .writeBoards(let id, let sources, let base):
            let boards = try Dictionary(uniqueKeysWithValues: sources.map { (try Self.board($0.key), $0.value) })
            return .boardsWritten(RemoteDesignBoardsWrite(try await server.writeDesignBoards(id, sources: boards, baseRevision: base)))
        case .updateIndex(let id, let patch, let base):
            return .written(try await server.updateDesignIndex(id, patch: patch, baseRevision: base))
        case .duplicateBoard(let id, let path, let base):
            let duplicate = try await server.duplicateDesignBoard(id, path: try Self.board(path), baseRevision: base)
            return .duplicated(path: duplicate.path, result: duplicate.result)
        case .restoreVersions(let id, let versions, let ifCurrent):
            let numbers = try Dictionary(uniqueKeysWithValues: versions.map { (try Self.board($0.key), $0.value) })
            let current = try ifCurrent.map { try Dictionary(uniqueKeysWithValues: $0.map { (try Self.board($0.key), $0.value) }) }
            return .boardsWritten(RemoteDesignBoardsWrite(try await server.restoreDesignVersions(id, numbers, ifCurrent: current)))
        case .system(let namespace):
            return .system(try await server.designSystem(namespace))
        case .watch:
            return .ok
        case .create:
            // Made by the app, on the server queue's own path (`remoteCreateDesign`).
            throw RemoteDesignRefusal("unsupported", "A design is made through the host's New design.")
        case .sendMarkup(let id, let markup):
            return .markupSent(undelivered: try await server.sendDesignMarkup(id, markup: markup))
        case .settleProposals(let id, let proposals, let deliver, let base):
            let outcome = try await server.settleDesignProposals(id, proposals: proposals, deliver: deliver, baseRevision: base)
            return .proposalsSettled(outcome.comments, undelivered: outcome.undelivered)
        case .delete(let id):
            guard server.state.designs.contains(where: { $0.id == id && !$0.buildsSystem }) else {
                throw SessionServerError.noSuchDesign(id)
            }
            return .deleted(try await server.deleteDesign(id))
        case .undoDelete:
            return .ok
        case .importBegin, .importChunk, .importFinish, .importCancel:
            // Kept with the connection, on the server queue's own path (`remoteDesignImport`).
            throw RemoteDesignRefusal("unsupported", "An import goes through the host's connection.")
        case .buildSystem:
            // Started by the app, on the server queue's own path (`remoteBuildDesignSystem`).
            throw RemoteDesignRefusal("unsupported", "A system build is started through the host's app.")
        case .ensureAgent:
            // Started by the app, on the server queue's own path (`remoteEnsureDesignAgent`).
            throw RemoteDesignRefusal("unsupported", "A design's agent is started through the host's Open.")
        case .duplicate(let id):
            return .designDuplicated(try await server.duplicateDesign(id))
        case .removeFromRecents(let id):
            try await server.removeDesignFromRecents(id)
            return .ok
        case .systemFile(let namespace, let path, let offset):
            guard offset >= 0 else { throw RemoteDesignRefusal.badOffset(offset, size: nil) }
            guard let data = try await server.designSystemFile(namespace, path: path) else {
                throw RemoteDesignRefusal(RemoteDesignCode.noSuchFile, "\(namespace) has no \(path).")
            }
            guard offset <= data.count else { throw RemoteDesignRefusal.badOffset(offset, size: data.count) }
            let end = min(data.count, offset + RemoteProtocol.designChunkBytes)
            return .chunk(RemoteDesignChunk(sha256: Self.sha256(data), offset: offset, total: data.count, data: data.subdata(in: offset..<end)))
        case .renameSystem(let namespace, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= DesignComment.maxTextBytes else {
                throw RemoteDesignRefusal("invalid_title", "A design system needs a title.")
            }
            return .systemChanged(try await server.renameDesignSystem(namespace, to: trimmed))
        case .duplicateSystem(let namespace):
            return .systemChanged(try await server.duplicateDesignSystem(namespace))
        case .deleteSystem(let namespace):
            try await server.deleteDesignSystem(namespace)
            return .ok
        case .resyncSystem(let namespace):
            return .systemSynced(try await server.resyncDesignSystem(namespace))
        case .deleteSystemBuild(let id):
            try await server.deleteSystemBuild(id)
            return .ok
        case .referenceKept(let agentID, let payloadID):
            guard server.state.agents.contains(where: { $0.id == agentID }) else { throw SessionServerError.noSuchAgent(agentID) }
            guard let kept = await server.designReferencePayload(agentID: agentID, payloadID: payloadID) else {
                throw RemoteDesignRefusal("no_such_reference", "The thread holds no such reference.")
            }
            let freshness = await server.designReferenceFreshness(agentID: agentID, payloadID: payloadID)
            // The picture rides along while it fits one reply; a larger one comes in pieces (`referencePicture`).
            let url = Self.keptPicture(kept)
            let size = url.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? .max
            let picture = size <= RemoteProtocol.designChunkBytes ? url.flatMap { try? Data(contentsOf: $0) } : nil
            return .referenceKept(kept.payload, picture: picture, freshness: freshness)
        case .referencePicture(let agentID, let payloadID, let offset):
            guard server.state.agents.contains(where: { $0.id == agentID }) else { throw SessionServerError.noSuchAgent(agentID) }
            guard offset >= 0 else { throw RemoteDesignRefusal.badOffset(offset, size: nil) }
            guard let kept = await server.designReferencePayload(agentID: agentID, payloadID: payloadID), let url = Self.keptPicture(kept),
                  let piece = try await server.referencePictureReader.piece(file: url, root: kept.folder, offset: offset) else {
                throw RemoteDesignRefusal(RemoteDesignCode.noSuchFile, "The thread holds no picture of that reference.")
            }
            return .chunk(piece)
        case .referenceFreshness(let reference):
            guard reference.host == .local else { throw RemoteDesignRefusal("remote_design", "That design isn't on this host.") }
            return .referenceFreshness(await server.designReferenceFreshness(reference))
        case .settleBoardProposal(let agentID, let payloadID, let accept):
            guard server.state.agents.contains(where: { $0.id == agentID }) else { throw SessionServerError.noSuchAgent(agentID) }
            do {
                let payload = try await server.settleDesignBoardProposal(agentID: agentID, payloadID: payloadID, accept: accept)
                return .referenceKept(payload, picture: nil, freshness: .current)
            } catch let error as DesignReferenceError {
                throw RemoteDesignRefusal(error.code, error.message)
            }
        case .referenceLookedAt(let agentID, let ref, let aspects):
            guard server.state.agents.contains(where: { $0.id == agentID }) else { throw SessionServerError.noSuchAgent(agentID) }
            return .referenceLookedAt(await server.designReferenceLookedAt(agentID: agentID, ref: ref, aspects: Set(aspects)))
        case .pinReference(let reference):
            // Only this host's own design (`local` here), checked and resolved by the host itself.
            do {
                let pinned = try await server.pinDesignReference(reference)
                return .referencePinned(RemoteDesignReferencePin(
                    reference: pinned.reference, label: pinned.reference.label, design: pinned.design, boardTitle: pinned.boardTitle,
                    pageTitle: pinned.pageTitle, elementLabel: pinned.elementLabel, elementName: pinned.elementName,
                    width: pinned.width, height: pinned.height, outline: pinned.outline))
            } catch let error as DesignReferenceError {
                throw RemoteDesignRefusal(error.code, error.message)
            }
        }
    }

    /// Every design with a canvas (a system build has none), most recently changed first, each
    /// with its first board for a thumbnail, and the host's design systems.
    private func listing() async throws -> RemoteDesignListing {
        let records = server.state.designs.filter { !$0.buildsSystem }
            .sorted { $0.lastActiveAt != $1.lastActiveAt ? $0.lastActiveAt > $1.lastActiveAt : $0.createdAt > $1.createdAt }
        var summaries: [RemoteDesignSummary] = []
        for design in records {
            // A design whose files can't be read still lists, with what the record knows.
            guard let snapshot = try? await server.designSnapshot(design.id) else {
                summaries.append(RemoteDesignSummary(design: design, revision: 0, boardCount: design.boardCount ?? 0,
                                                     openComments: 0, firstBoard: nil))
                continue
            }
            let open = (try? await server.designComments(design.id).open.count) ?? 0
            let first = snapshot.index.order.first.flatMap { path -> RemoteDesignFirstBoard? in
                guard let board = snapshot.index.boards[path], let sha = snapshot.boards[path] else { return nil }
                return RemoteDesignFirstBoard(path: path, sha256: sha, width: board.w, height: board.h)
            }
            summaries.append(RemoteDesignSummary(design: design, revision: snapshot.revision, boardCount: snapshot.index.boards.count,
                                                 openComments: open, firstBoard: first))
        }
        return RemoteDesignListing(designs: summaries, systems: await server.designSystemSummaries())
    }

    /// The files among `paths` (nil: all) whose hash isn't the one `known` names, their bytes
    /// inline while they fit one chunk, in the index's order.
    private func files(_ id: DesignID, paths: [String]?, known: [String: String]) async throws -> RemoteDesignFiles {
        let designs = server.designs
        let listed = try await designs.projectFiles(id)
        let revision = try await server.designSnapshot(id).revision
        let byPath = Dictionary(listed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let wanted = paths ?? listed.map(\.path)
        var changed: [RemoteDesignFile] = []
        var unchanged: [String] = []
        var missing: [String] = []
        var budget = RemoteProtocol.designChunkBytes
        for path in wanted {
            guard let info = byPath[path] else {
                missing.append(path)
                continue
            }
            if known[path] == info.sha256 {
                unchanged.append(path)
                continue
            }
            var data: Data?
            if info.size <= budget, let file = try await designs.projectFile(id, path: path) {
                // Hashed again as read: a file changed since the listing goes as it is now.
                if file.data.count <= budget {
                    data = file.data
                    budget -= file.data.count
                }
                changed.append(RemoteDesignFile(path: path, sha256: file.sha256, size: file.data.count, data: data))
                continue
            }
            changed.append(RemoteDesignFile(path: path, sha256: info.sha256, size: info.size, data: nil))
        }
        return RemoteDesignFiles(designID: id, revision: revision, changed: changed, unchanged: unchanged, missing: missing)
    }

    /// A kept reference's picture, inside its copy's folder: the piece's own, else a page's or a
    /// design's first board's.
    static func keptPicture(_ kept: (payload: DesignReferencePayload, folder: URL)) -> URL? {
        guard let name = kept.payload.picture?.name ?? kept.payload.boards?.first?.picture?.name,
              name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { return nil }
        let root = kept.folder.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        return file
    }

    /// A board path a client sent, checked against the grammar.
    static func board(_ raw: String) throws -> DesignPath {
        do { return try DesignPath.validate(raw) } catch {
            throw DesignStoreError.invalidPath(raw, error)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// DesignStore's metadata-validated digest/ranged-read pattern, for kept pictures rather than
/// project files. Serial IO, with only 64 small digest records retained (never picture bytes).
/// Ownership is checked by the service on every request, not by a cache hit.
actor ReferencePictureReader {
    private struct Digest {
        let metadata: [Int64]
        let sha256: String
    }
    private var hashes: [String: Digest] = [:]
    private var order: [String] = []
    private let read: @Sendable (FileHandle, Int) throws -> Data

    init(read: @escaping @Sendable (FileHandle, Int) throws -> Data = { try $0.read(upToCount: $1) ?? Data() }) {
        self.read = read
    }

    func piece(file: URL, root: URL, offset: Int) throws -> RemoteDesignChunk? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base + "/") else { return nil }
        let fd = open(resolved.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= DesignImport.maxFileBytes else { return nil }
        let size = Int(info.st_size)
        guard offset >= 0, offset <= size else { throw RemoteDesignRefusal.badOffset(offset, size: size) }
        let metadata = Self.metadata(info)
        let key = resolved.path
        var whole: Data?
        let sha: String
        if let known = hashes[key], known.metadata == metadata {
            sha = known.sha256
        } else {
            guard let data = try? read(handle, size), data.count == size else { return nil }
            sha = RemoteDesignService.sha256(data)
            whole = data
        }
        let end = offset + min(RemoteProtocol.designChunkBytes, size - offset)
        let data: Data
        if let whole {
            data = whole.subdata(in: offset..<end)
        } else if end == offset {
            data = Data()
        } else {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let bytes = try? read(handle, end - offset), bytes.count == end - offset else { return nil }
            data = bytes
        }
        // In-place writes and same-size atomic replacements invalidate the digest as well as
        // mtime/size changes. A concurrent write during a read never seeds the cache.
        var after = stat()
        guard fstat(fd, &after) == 0, Self.metadata(after) == metadata else {
            hashes[key] = nil
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        if order.count >= 64 { hashes.removeValue(forKey: order.removeFirst()) }
        order.append(key)
        hashes[key] = Digest(metadata: metadata, sha256: sha)
        return RemoteDesignChunk(sha256: sha, offset: offset, total: size, data: data)
    }

    private static func metadata(_ info: stat) -> [Int64] {
        [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size,
         Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
         Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
}
