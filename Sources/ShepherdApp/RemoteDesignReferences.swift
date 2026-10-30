import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// Design references in a connected host's thread (`design.references.v1`): the same chips, "Looked
// at…" lines and @ picker as a local thread's, for that host's own designs. In a host's thread a
// reference is named as the host sees it (`local` there), as its own sends and snapshots name it;
// the host pins, keeps and reads each piece, and this Mac draws the pictures from the files the
// host served. A reference to any other Mac's design is refused before it goes.

@MainActor
extension ShepherdViewModel {
    /// A host's ordinary thread's references, while the Design tool is on here and the host takes
    /// references to its designs; nil for a design's own chat and an older host.
    func remoteDesignReferenceChips(for ref: RemoteAgentRef) -> DesignReferenceChips? {
        guard settings.designToolEnabled,
              let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }),
              connection.supportsDesignCapability(RemoteProtocol.designReferencesCapability),
              let agent = connection.state.agents.first(where: { $0.id == ref.agentID }),
              !connection.state.isDesignAgent(agent), agent.designID == nil else { return nil }
        if let chips = remoteReferenceChips[ref] { return chips }
        let chips = DesignReferenceChips(agentID: ref.agentID, io: remoteReferenceIO(ref))
        chips.place = connection.config.name
        remoteReferenceChips[ref] = chips
        return chips
    }

    private func remoteReferenceIO(_ ref: RemoteAgentRef) -> DesignReferenceChips.IO {
        let host = ref.hostID
        let agent = ref.agentID
        return DesignReferenceChips.IO(
            payload: { [weak self] id in await self?.remoteKept(host, agent, id).map { ($0.payload, $0.folder) } },
            freshness: { [weak self] id in await self?.remoteKept(host, agent, id)?.freshness ?? .deleted },
            pinnedFreshness: { [weak self] reference in
                guard let self, let library = self.remoteLibrary(host),
                      case .referenceFreshness(let freshness)? = try? await library.request(.referenceFreshness(reference)) else { return .current }
                return freshness
            },
            lookedAt: { [weak self] ref, aspects in
                guard let self, let library = self.remoteLibrary(host),
                      case .referenceLookedAt(let line)? = try? await library.request(.referenceLookedAt(agentID: agent, ref: ref, aspects: Array(aspects)))
                else { return nil }
                return line
            },
            picture: { [weak self] in self?.remoteReferencePicture($0, host: host) },
            catalog: { [weak self] in await self?.remoteMentionCatalog(host) ?? DesignMentionCatalog() },
            rowPicture: { [weak self] in self?.remoteMentionPicture($0, host: host) },
            wantCrop: { [weak self] item, board, tids in
                guard let self, let rendering = self.remoteDesignRendering(host), let path = item.reference.board,
                      let tid = item.reference.element?.tid, let revision = item.revision, let width = board.width, let height = board.height else { return }
                rendering.elementCrops.landed = { [weak self] in self?.remoteReferencePicturesLanded(host) }
                rendering.elementCrops.want(tid, on: DesignElementCrops.Board(design: item.reference.designID, path: path,
                                                                              size: CGSize(width: width, height: height), revision: revision, tids: tids))
            },
            wantPictures: { [weak self] scope in self?.wantRemoteMentionPictures(scope, host: host) },
            open: { [weak self] reference in
                guard let self else { return }
                let design = RemoteDesignRef(hostID: host, designID: reference.designID)
                self.openRemoteDesign(design)
                if let page = reference.page { self.remoteDesignScreen(design)?.reveal(page: page) }
                else if let board = reference.board { self.remoteDesignScreen(design)?.reveal(board: board, element: reference.element) }
            },
            attach: { [weak self] reference in try await self?.attachRemoteDesignReference(reference, to: ref) },
            sendLatest: { [weak self] reference in
                do { try await self?.attachRemoteDesignReference(reference.unpinned, to: ref) } catch {
                    self?.remoteActionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            },
            startDesign: { [weak self] in
                self?.openNewDesign()
                self?.newDesign.choose(host: host)
            })
    }

    private func remoteLibrary(_ host: UUID) -> RemoteDesignLibrary? {
        remoteHosts.connections.first { $0.id == host }?.designs
    }

    /// The @ picker, a pasted reference, "Send vN" in a host's thread: the piece pinned by the
    /// host and waiting in the composer, named as the host sees it. A piece of this Mac's or any
    /// other host's design is refused (the host can't read it).
    func attachRemoteDesignReference(_ reference: DesignReference, to ref: RemoteAgentRef) async throws {
        // A reference from this thread (its picker, its chips) is the host's own; one copied from
        // the host's canvas here names the host.
        let mine: DesignReference
        switch reference.host {
        case .local: mine = reference.fromHost(ref.hostID)
        case .remote(let id) where id == ref.hostID: mine = reference
        case .remote: throw DesignReferenceFailure(RemoteHostClient.designReferencesRefusal)
        }
        let prepared = try await prepareDesignReference(mine)
        guard let named = prepared.reference.onHost(ref.hostID) else { throw DesignReferenceFailure(RemoteHostClient.designReferencesRefusal) }
        let attached = NativeAttachedReference(reference: named, label: prepared.reference.label ?? prepared.piece, outline: prepared.outline)
        guard remoteThreadStores.store(for: ref).attach(reference: attached) else {
            throw DesignReferenceFailure("A message carries at most \(DesignReferenceRecord.maxPerMessage) design references.")
        }
        wantRemoteMentionPictures(.design(reference.designID, name: ""), host: ref.hostID)
    }

    // MARK: Reads

    /// What the host kept of a sent piece, read once for a chip's copy and its standing together;
    /// its picture is kept under this Mac's temporary folder for the chip to draw.
    private func remoteKept(_ host: UUID, _ agent: AgentID, _ id: UUID)
        async -> (payload: DesignReferencePayload, folder: URL, freshness: DesignReferenceFreshness)? {
        let key = "\(host)/\(agent.rawValue)/\(id)"
        if let reading = remoteKeptReads[key] { return await reading.value }
        let reading = Task { @MainActor [weak self] () -> (payload: DesignReferencePayload, folder: URL, freshness: DesignReferenceFreshness)? in
            guard let library = self?.remoteLibrary(host),
                  case .referenceKept(let payload, let picture, let freshness)? = try? await library.request(.referenceKept(agentID: agent, payloadID: id))
            else { return nil }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-remote-references/\(host.uuidString)/\(id.uuidString)",
                                                                                    isDirectory: true)
            var bytes = picture
            // One too large for that reply comes in pieces.
            if bytes == nil, payload.picture != nil || payload.boards?.first?.picture != nil {
                bytes = try? await library.referencePicture(agentID: agent, payloadID: id)
            }
            if let bytes, let name = payload.picture?.name ?? payload.boards?.first?.picture?.name,
               name == (name as NSString).lastPathComponent, !name.hasPrefix(".") {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? bytes.write(to: folder.appendingPathComponent(name), options: .atomic)
            }
            return (payload, folder, freshness)
        }
        remoteKeptReads[key] = reading
        let answer = await reading.value
        remoteKeptReads[key] = nil
        return answer
    }

    /// What the @ picker lists from a host (`RemoteDesignLibrary.mentionCatalog`).
    func remoteMentionCatalog(_ host: UUID) async -> DesignMentionCatalog {
        guard let library = remoteLibrary(host) else { return DesignMentionCatalog() }
        if library.listing == nil { await library.refresh() }
        return library.mentionCatalog()
    }

    /// The picker opened a host's design (or its board): its files synced, its rows read from
    /// them, and its boards drawn for their rows.
    func wantRemoteMentionPictures(_ scope: MentionScope, host: UUID) {
        guard let rendering = remoteDesignRendering(host), let library = remoteLibrary(host) else { return }
        rendering.thumbnails.landed = { [weak self] in self?.remoteReferencePicturesLanded(host) }
        rendering.boardPictures.landed = { [weak self] in self?.remoteReferencePicturesLanded(host) }
        let id: DesignID
        switch scope {
        case .designs:
            Task { await loadRemoteDesigns() }
            return
        case .design(let design, _): id = design
        case .board(let reference, _, _): id = reference.designID
        }
        Task {
            let revision = library.mentionsRevision
            await library.openMentions(id)
            if let index = library.source(id).index { rendering.boardPictures.request(id, snapshot: index.snapshot) }
            guard library.mentionsRevision != revision else { return }
            for (ref, chips) in remoteReferenceChips where ref.hostID == host { chips.startCatalogRead() }
        }
    }

    private func remoteReferencePicturesLanded(_ host: UUID) {
        for (ref, chips) in remoteReferenceChips where ref.hostID == host { chips.picturesChanged() }
    }

    /// A composer chip's picture: its board as drawn here, else the design's first board.
    private func remoteReferencePicture(_ reference: DesignReference, host: UUID) -> CGImage? {
        guard let rendering = remoteDesignRenderings[host], reference.page == nil else { return nil }
        if let board = reference.board {
            if let image = rendering.host(for: reference.designID)?.image(board) { return image }
            if let image = rendering.boardPictures.image(reference.designID, board) { return image }
        }
        return rendering.thumbnails.image(reference.designID)
    }

    private func remoteMentionPicture(_ item: DesignMentionItem, host: UUID) -> CGImage? {
        guard let rendering = remoteDesignRenderings[host] else { return nil }
        switch item.kind {
        case .design: return rendering.thumbnails.image(item.reference.designID)
        case .page: return nil
        case .board:
            guard let board = item.reference.board else { return nil }
            return rendering.boardPictures.image(item.reference.designID, board) ?? rendering.host(for: item.reference.designID)?.image(board)
        case .element:
            guard let board = item.reference.board, let tid = item.reference.element?.tid, let revision = item.revision else { return nil }
            return rendering.elementCrops.crop(item.reference.designID, board, revision: revision, tid: tid)
        }
    }

    /// A host's designs changed: its threads' chips read how they stand again.
    func remoteReferencesDesignsChanged(_ host: UUID) {
        for (ref, chips) in remoteReferenceChips where ref.hostID == host { chips.designsChanged() }
    }
}
