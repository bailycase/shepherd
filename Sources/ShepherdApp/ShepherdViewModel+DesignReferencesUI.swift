import AppKit
import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// Design references in a thread (DesignRefStates): its chips, its "Looked at…" lines, its
// composer's @ picker, and "Open in design". The canvas's side is
// ShepherdViewModel+ImplementInThread.swift; the model half (pinning, sending, the copies) is
// ShepherdViewModel+DesignReferences.swift.

@MainActor
extension ShepherdViewModel {
    // MARK: A thread's references

    /// A local thread's references, while the Design tool is on; nil for a design's own agent
    /// (its chat never shows another design's pieces) and for a thread that is gone. Reads the
    /// server's copy of the state, so a layout asking observes only the Design tool's switch.
    func designReferenceChips(for agentID: AgentID) -> DesignReferenceChips? {
        guard settings.designToolEnabled else { return nil }
        if let chips = referenceChips[agentID] { return chips }
        let state = server.state
        guard let agent = state.agents.first(where: { $0.id == agentID }), !state.isDesignAgent(agent), agent.designID == nil else {
            return nil
        }
        let chips = DesignReferenceChips(agentID: agentID, io: referenceIO(agentID))
        referenceChips[agentID] = chips
        return chips
    }

    private func referenceIO(_ agentID: AgentID) -> DesignReferenceChips.IO {
        let server = server
        return DesignReferenceChips.IO(
            payload: { await server.designReferencePayload(agentID: agentID, payloadID: $0) },
            freshness: { await server.designReferenceFreshness(agentID: agentID, payloadID: $0) },
            pinnedFreshness: { await server.designReferenceFreshness($0) },
            lookedAt: { await server.designReferenceLookedAt(agentID: agentID, ref: $0, aspects: $1) },
            picture: { [weak self] in self?.referencePicture($0) },
            catalog: { await server.designMentionCatalog() },
            rowPicture: { [weak self] in self?.mentionPicture($0) },
            wantPictures: { [weak self] in self?.wantMentionPictures($0) },
            open: { [weak self] in self?.openDesignReference($0) },
            attach: { [weak self] reference in
                guard let self else { return }
                try await self.attachDesignReference(reference, to: agentID)
                // Its chip draws the piece's board once the board's picture is drawn.
                self.wantMentionPictures(.design(reference.designID, name: ""))
            },
            sendLatest: { [weak self] reference in
                guard let self else { return }
                do {
                    try await self.sendLatestDesignReference(reference, to: agentID)
                    self.focusedPaneID = self.state.agents.first { $0.id == agentID }?.paneID
                } catch {
                    self.remoteActionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            },
            startDesign: { [weak self] in self?.openNewDesign() })
    }

    /// Designs changed (a revision, a deletion, a new board): chips read how they stand again.
    func referencesDesignsChanged() {
        let signature = Dictionary(state.designs.map { ($0.id, [$0.lastActiveAt, Double($0.boardCount ?? -1)]) }, uniquingKeysWith: { a, _ in a })
        guard signature != referenceDesignSignature else { return }
        referenceDesignSignature = signature
        let live = Set(state.agents.map(\.id))
        referenceChips = referenceChips.filter { live.contains($0.key) }
        for chips in referenceChips.values { chips.designsChanged() }
    }

    /// A picture landed for a picker row or a composer chip.
    func referencePicturesLanded() {
        for chips in referenceChips.values { chips.picturesChanged() }
    }

    /// A piece's picture before it is sent: its board as the canvas last drew it (cut to the
    /// element when the canvas picked it), else the board's small picture, else the design's
    /// first board.
    func referencePicture(_ reference: DesignReference) -> CGImage? {
        guard reference.host == .local, design(reference.designID) != nil else { return nil }
        if let board = reference.board {
            if let image = designRendering.host(for: reference.designID)?.image(board) { return image }
            if let image = designRendering.boardPictures.image(reference.designID, board) { return image }
        }
        return designRendering.thumbnails.image(reference.designID)
    }

    /// A picker row's picture: a design's first board, a board's (or an element's board's) own.
    func mentionPicture(_ item: DesignMentionItem) -> CGImage? {
        switch item.kind {
        case .design:
            return designRendering.thumbnails.image(item.reference.designID)
        case .board, .element:
            guard let board = item.reference.board else { return nil }
            return designRendering.boardPictures.image(item.reference.designID, board)
                ?? designRendering.host(for: item.reference.designID)?.image(board)
        }
    }

    /// The picker opened on `scope`: its designs' first boards, or a design's boards, are drawn
    /// if they aren't yet.
    func wantMentionPictures(_ scope: MentionScope) {
        let rendering = designRendering
        rendering.thumbnails.landed = { [weak self] in self?.referencePicturesLanded() }
        rendering.boardPictures.landed = { [weak self] in self?.referencePicturesLanded() }
        let id: DesignID
        switch scope {
        case .designs:
            Task { await loadDesignThumbnails() }
            return
        case .design(let design, _): id = design
        case .board(let reference, _, _): id = reference.designID
        }
        let server = server
        Task {
            guard let snapshot = try? await server.designSnapshot(id) else { return }
            rendering.boardPictures.request(id, snapshot: snapshot)
        }
    }

    /// "Open in design" (a chip, its preview): the design on screen, the piece's board picked and
    /// in view, its element selected once the board draws.
    func openDesignReference(_ reference: DesignReference) {
        guard reference.host == .local, design(reference.designID) != nil else {
            remoteActionError = "That design is no longer on this Mac."
            return
        }
        openDesign(reference.designID)
        if let board = reference.board { designScreen(reference.designID).reveal(board: board, element: reference.element) }
    }
}
