import Foundation
import ShepherdCore
import ShepherdProtocol
import SwiftUI

/// The jump card while it is up: what it lists and what is highlighted. Pictures come from the
/// design's live canvas, else the shared board pictures.
@MainActor @Observable
final class DesignJumpModel {
    /// The design the card opened over.
    let design: DesignID
    var query = "" {
        didSet { if query != oldValue { refresh(resetHighlight: true) } }
    }
    var scope: DesignJumpScope = .thisDesign {
        didSet { if scope != oldValue { refresh(resetHighlight: true) } }
    }
    private(set) var rows: [DesignJumpItem] = []
    var highlight = 0
    /// Moves when a picture lands.
    private(set) var pictures = 0
    @ObservationIgnored private let read: (DesignJumpScope, String) -> [DesignJumpItem]

    init(design: DesignID, read: @escaping (DesignJumpScope, String) -> [DesignJumpItem]) {
        self.design = design
        self.read = read
        refresh(resetHighlight: true)
    }

    func refresh(resetHighlight: Bool = false) {
        rows = read(scope, query)
        if resetHighlight {
            highlight = query.isEmpty ? DesignJump.initialHighlight(rows) : 0
        } else {
            highlight = min(highlight, max(0, rows.count - 1))
        }
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlight = min(max(0, highlight + delta), rows.count - 1)
    }

    func cycleScope() {
        let all = DesignJumpScope.allCases
        scope = all[((all.firstIndex(of: scope) ?? 0) + 1) % all.count]
    }

    func picturesLanded() { pictures += 1 }

    var highlighted: DesignJumpItem? { rows.indices.contains(highlight) ? rows[highlight] : nil }
}

extension ShepherdViewModel {
    /// The design the jump card serves: one of this Mac's, on screen as its canvas.
    var jumpableDesign: Design? {
        guard let design = shownDesign, !design.buildsSystem else { return nil }
        return design
    }

    /// The command palette's chord: over a design, Jump to a board; anywhere else, the palette.
    /// Pressed again, it closes whichever is up.
    func toggleCommandPaletteOrJump() {
        if designJump != nil { designJump = nil; return }
        if showCommandPalette { showCommandPalette = false; return }
        if let design = jumpableDesign { openDesignJump(design.id) } else { showCommandPalette = true }
    }

    /// Opens the card over `id`'s canvas, on This design.
    func openDesignJump(_ id: DesignID) {
        showCommandPalette = false
        let screen = designScreen(id)
        let rendering = designRendering
        let model = DesignJumpModel(design: id) { [weak self, weak screen] scope, query in
            guard let self else { return [] }
            return DesignJump.items(scope: scope, query: query, index: screen?.snapshot?.index, design: id,
                                    current: screen?.focusBoard, recents: self.designJumpRecents,
                                    designs: self.state.designs, now: Date())
        }
        designJump = model
        // The pictures: boards for This design, first boards for All designs.
        // One callback per cache, shared with the @ picker and the chips: it fans out to all.
        rendering.boardPictures.landed = { [weak self] in self?.referencePicturesLanded() }
        rendering.thumbnails.landed = { [weak self] in self?.referencePicturesLanded() }
        let server = server
        Task { [weak self] in
            if let snapshot = try? await server.designSnapshot(id) { rendering.boardPictures.request(id, snapshot: snapshot) }
            await self?.loadDesignThumbnails()
        }
    }

    /// A row's picture: the board as the canvas last drew it, else its small picture; a design's
    /// first board.
    func jumpPicture(_ item: DesignJumpItem, in design: DesignID) -> CGImage? {
        switch item.kind {
        case .board(let path):
            designRendering.host(for: design)?.image(path) ?? designRendering.boardPictures.image(design, path)
        case .design(let id):
            designRendering.thumbnails.image(id)
        }
    }

    /// ⏎ on a row: the board picked and in view on this design's canvas, or the design opened.
    func runDesignJump(_ item: DesignJumpItem) {
        guard let model = designJump else { return }
        designJump = nil
        switch item.kind {
        case .board(let path):
            designJumpRecents.opened(path, in: model.design, at: Date().timeIntervalSince1970)
            designScreen(model.design).reveal(board: path, element: nil)
        case .design(let id):
            openDesign(id)
        }
    }
}
