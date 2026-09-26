import CryptoKit
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
