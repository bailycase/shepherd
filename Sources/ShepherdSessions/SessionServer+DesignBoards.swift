import Foundation
import ShepherdCore
import ShepherdProtocol

// Boards an ordinary thread draws (ThreadBoardDraft, ThreadBoardChange): design_show with a
// source keeps the board as a copy beside the thread's references, drawn by the app in the
// design's own context, and shown in the thread as a card. Nothing reaches the design until the
// user adds or applies it from that card; Discard only marks the copy. A thread draws only for a
// design it was sent a piece of.

extension SessionServer {
    /// Keeps a board `agentID` drew for `reference`'s design: with `title`, a new board placed
    /// beside `reference`'s board (a draft); without, a new version of `reference`'s board (a
    /// change). Answers what the agent hears, with the copy's id in `lookedAt.payload`.
    func proposeDesignBoard(agentID: AgentID, reference raw: String, source: String, title rawTitle: String?) async throws -> DesignReferenceAnswer {
        let state = self.state
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { throw DesignReferenceError("no_such_agent", "no such agent") }
        guard !state.isDesignAgent(agent), agent.designID == nil else { throw DesignReferenceError.notAThread }
        guard let reference = DesignReference(string: raw) else { throw DesignReferenceError.invalid(raw) }
        guard reference.host == .local else { throw DesignReferenceError.remote }
        guard agent.designGrants.contains(where: { $0.designID == reference.designID }) else { throw DesignReferenceError.notGranted }
        let title = rawTitle.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let title, title.isEmpty || title.utf8.count > 120 {
            throw DesignReferenceError("invalid_title", "A drafted board's title is 1 to 120 characters, like \"B · Pay on phone\".")
        }
        guard title != nil || reference.board != nil else {
            throw DesignReferenceError("no_board", "A change names the board it changes; to draw a new board, give it a title.")
        }
        if case .failure(let refusal) = Result(catching: { () throws(DesignBoardCheck.Refusal) in try DesignBoardCheck.check(source) }) {
            throw DesignReferenceError(refusal.code, refusal.description)
        }

        // The design as it is now: the board a change replaces, or the boards a draft sits beside.
        let service = DesignReferenceService(server: self)
        let anchor = reference.board.flatMap { DesignReference(designID: reference.designID, board: $0) }
            ?? DesignReference(designID: reference.designID)!
        let resolved = try await service.resolve(anchor, state: state)
        var files = resolved.files
        let index = resolved.snapshot.index
        let (path, entry, proposal) = try Self.proposedFrame(title: title, board: reference.board, source: source, resolved: resolved)
        // The board drawn as it would be: in the design's files, at its frame's size.
        files.index.boards[path] = entry
        files.sources[path] = source
        if !files.members.contains(path) { files.members.append(path) }

        let pinned = DesignReference(designID: reference.designID, board: path, revision: resolved.revision)!
        let id = UUID()
        let payloads = designReferencePayloads
        let folder = try await payloads.create(agentID: agentID, payload: id)
        do {
            var payload = DesignReferencePayload(id: id, agentID: agentID, reference: pinned, design: resolved.design.name,
                                                 boardTitle: entry.title.flatMap(DesignViewRecord.label) ?? path.stem,
                                                 revision: resolved.revision, capturedAt: Self.nowMilliseconds(), width: entry.w, height: entry.h)
            payload.proposal = proposal
            payload.boardPageTitle = entry.page.flatMap { page in index.pages?.first { $0.id == page }?.name.flatMap(DesignViewRecord.label) }
            let sourceName = DesignReferenceFileNames.source(pinned)
            try await payloads.write([sourceName: Data(source.utf8)], agentID: agentID, payload: id)
            payload.source = .init(name: sourceName, bytes: source.utf8.count)
            let drawn = try await captureDesignReference(DesignReferenceCaptureRequest(
                reference: pinned, boards: [.init(path: path, source: source, isCurrent: false, picture: DesignReferenceFileNames.image(pinned),
                                                  html: DesignReferenceFileNames.html(pinned))],
                folder: folder, files: files))
            payload.picture = drawn.boards.first?.picture
            payload.html = drawn.boards.first?.html
            try await payloads.save(payload)
            let board = payload.boardTitle ?? path.stem
            let size = "\(Int(entry.w)) × \(Int(entry.h))"
            let text = proposal.kind == .draft
                ? "Drew \(board) (\(size)) as a draft in \(resolved.design.name), shown in the thread. It isn't on the design's canvas until the user adds it from the card."
                : "Proposed a change to \(board) (\(size)) from revision \(resolved.revision), shown in the thread. The board changes only when the user applies it from the card."
            return DesignReferenceAnswer(text: text, lookedAt: DesignReferenceLookedAt(
                ref: pinned.string, title: resolved.design.name + " › " + board, aspects: [], payload: id))
        } catch {
            await payloads.remove(agentID: agentID, payloads: [id])
            throw error
        }
    }

    /// The user's Add to design or Apply to design (`accept`), or Discard, on a board `agentID`
    /// drew: a draft becomes a board on the canvas where the card placed it, a change replaces
    /// the board while it is still the version the agent drew from. Answers the copy as it now is.
    public func settleDesignBoardProposal(agentID: AgentID, payloadID: UUID, accept: Bool) async throws -> DesignReferencePayload {
        let payloads = designReferencePayloads
        guard var payload = await payloads.load(agentID: agentID, payload: payloadID), var proposal = payload.proposal,
              let path = payload.reference.board else {
            throw DesignReferenceError("no_such_board", "That board is no longer kept in the thread.")
        }
        guard proposal.state == .pending else {
            throw DesignReferenceError("already_settled", proposal.state == .added ? "That board is already in the design." : "That board was discarded.")
        }
        if accept {
            let designID = payload.reference.designID
            guard state.designs.contains(where: { $0.id == designID }) else { throw DesignReferenceError("no_such_design", "That design is no longer here.") }
            guard let name = payload.source?.name, let data = await payloads.read(agentID: agentID, payload: payloadID, file: name) else {
                throw DesignReferenceError.noCopy
            }
            let source = String(decoding: data, as: UTF8.self)
            let snapshot = try await designs.snapshot(designID)
            var size: [String: JSONValue] = [:]
            if let width = payload.width, let height = payload.height { size = ["w": .number(width), "h": .number(height)] }
            switch proposal.kind {
            case .draft:
                // The name the card showed, unless the design took it since.
                let taken = Set(snapshot.index.boards.keys).union(snapshot.boards.keys)
                var target = path
                if taken.contains(where: { $0.stem.lowercased() == path.stem.lowercased() }) {
                    guard let next = Self.draftPath(payload.boardTitle ?? path.stem, taken: taken) else { throw DesignStoreError.noSuchBoard(path) }
                    target = next
                }
                _ = try await writeDesignBoard(designID, path: target, source: source)
                var frame = size
                frame["x"] = .number(proposal.x ?? 0)
                frame["y"] = .number(proposal.y ?? 0)
                if let title = payload.boardTitle { frame["title"] = .string(title) }
                var patch: [String: JSONValue] = ["boards": .object([target.rawValue: .object(frame)])]
                if !snapshot.index.order.isEmpty { patch["order"] = .array((snapshot.index.order + [target]).map { .string($0.rawValue) }) }
                _ = try await updateDesignIndex(designID, patch: .object(patch))
            case .change:
                guard snapshot.boards[path] == proposal.baseSHA else {
                    throw DesignReferenceError("board_changed", "\(payload.boardTitle ?? path.stem) changed since the agent drew this. Ask it to draw the change again.")
                }
                _ = try await writeDesignBoard(designID, path: path, source: source)
                if let current = snapshot.index.boards[path], current.w != payload.width || current.h != payload.height, !size.isEmpty {
                    _ = try await updateDesignIndex(designID, patch: .object(["boards": .object([path.rawValue: .object(size)])]))
                }
            }
            proposal.state = .added
        } else {
            proposal.state = .discarded
        }
        payload.proposal = proposal
        try await payloads.save(payload)
        return payload
    }

    /// Where a drawn board goes and what it proposes: a draft's new path and frame beside
    /// `board` (else right of every board), or the frame of the board a change replaces.
    private static func proposedFrame(title: String?, board: DesignPath?, source: String, resolved: DesignReferenceService.Resolved) throws
        -> (DesignPath, DesignIndex.Board, DesignReferencePayload.Proposal) {
        let index = resolved.snapshot.index
        let preview = DesignBoardCheck.previewSize(of: source)
        guard let title else {
            guard let path = board, let current = index.boards[path], let held = resolved.boards.first else {
                throw DesignReferenceError("no_board", "A change names the board it changes; to draw a new board, give it a title.")
            }
            var entry = current
            if let preview {
                entry.w = preview.width
                entry.h = preview.height
            }
            return (path, entry, .init(kind: .change, baseSHA: held.source.sha256))
        }
        guard let preview else {
            throw DesignReferenceError("no_size", "A drafted board needs its size: set $preview in its data-props, like {\"$preview\":{\"width\":320,\"height\":480}}.")
        }
        guard let path = draftPath(title, taken: Set(index.boards.keys).union(resolved.snapshot.boards.keys)) else {
            throw DesignReferenceError("invalid_title", "No board name fits \"\(title)\".")
        }
        var entry = board.flatMap { index.duplicating($0, as: path)?.boards[path] }
            ?? DesignIndex.Board(x: index.boards.values.map { $0.x + $0.w }.max().map { $0 + 80 } ?? 0,
                                 y: index.boards.values.map(\.y).min() ?? 0, w: 0, h: 0)
        entry.title = title
        entry.w = preview.width
        entry.h = preview.height
        return (path, entry, .init(kind: .draft, x: entry.x, y: entry.y))
    }

    /// A board path for a drafted board's title ("B · Pay on phone" → `B-Pay-on-phone.dc.html`),
    /// numbered past any board whose name `taken` has (regardless of case).
    static func draftPath(_ title: String, taken: Set<DesignPath>) -> DesignPath? {
        let words = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" }
        let stem = String(words).split(separator: "-").joined(separator: "-").prefix(60)
        let base = stem.isEmpty ? "Board" : String(stem)
        let stems = Set(taken.map { $0.stem.lowercased() })
        for number in 1...500 {
            let name = number == 1 ? base : "\(base)-\(number)"
            if !stems.contains(name.lowercased()) { return DesignPath(name + DesignPath.fileExtension) }
        }
        return nil
    }
}
