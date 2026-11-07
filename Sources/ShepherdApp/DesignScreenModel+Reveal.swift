import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

// "Open in design" (a thread's reference chip, its preview): the piece's board picked and brought
// into view, its element selected once the board draws.

/// Where the canvas was before a Jump landed, and the board it landed on.
struct DesignJumpBack: Equatable {
    let id = UUID()
    let title: String
    let page: String?
    let viewport: SHCanvasViewport
    let picks: [DesignScreenModel.Pick]

    /// How long the toast stays without a touch.
    static let lifetime: Duration = .seconds(6)
}

extension DesignScreenModel {
    // MARK: Open in design

    /// "Open in design" from a thread's chip: the piece's board picked and brought into view, and
    /// its element selected once the board draws live.
    func reveal(board: DesignPath, element: DesignElementID?) {
        pendingReveal = (board, element, nil)
        applyReveal()
    }

    /// Waits for the canvas's snapshot just as a board reveal does.
    func reveal(page: String) {
        pendingReveal = (nil, nil, page)
        applyReveal()
    }

    func applyReveal() {
        guard let reveal = pendingReveal, let index = snapshot?.index else { return }
        if reveal.page != nil, canvasSize.width <= 0 || canvasSize.height <= 0 { return }
        pendingReveal = nil
        if let pageID = reveal.page {
            guard index.pages?.contains(where: { $0.id == pageID }) == true else { return }
            showPage(pageID)
            present(nil)
            closeComment()
            clearSelection()
            viewport = .fitting(boards.bounds, in: canvasSize)
            return
        }
        guard let board = reveal.board, let entry = index.boards[board] else { return }
        if let pageID = index.page(of: board), pageID != page { showPage(pageID) }
        present(nil)
        closeComment()
        setSelection([Pick(board: board)])
        center(on: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h))
        guard let element = reveal.element, let host else { return }
        Task {
            // The board goes live as the selection's focus; ask it where the element is once it
            // draws (a few tries: a board loads in well under a second).
            for _ in 0..<20 {
                if let found = await host.locate(board, tids: [element.tid]) {
                    if let pick = found[element.tid], pick.id.path == element.path, picks.last?.board == board {
                        setSelection([Pick(board: board, element: pick)])
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: Jump and Back

    /// A Jump's landing (JumpLanded): the board picked and in view, as a reveal does, with where
    /// the canvas was kept for Back.
    func jump(to board: DesignPath, title: String) {
        let before = DesignJumpBack(title: title, page: page, viewport: viewport, picks: picks)
        reveal(board: board, element: nil)
        // Kept once the canvas has moved: a reveal still waiting on the snapshot would clear it.
        if pendingReveal == nil { jumpBack = before }
    }

    /// Back: the page, viewport and selection the canvas had before the jump.
    func goBackFromJump() {
        guard let back = jumpBack else { return }
        if let page = back.page { showPage(page) }
        setSelection(back.picks)
        viewport = back.viewport
        jumpBack = nil
    }

    /// The toast's own time ran out.
    func dismissJumpBack(_ id: UUID) {
        if jumpBack?.id == id { jumpBack = nil }
    }

    /// Brings a board's frame into the middle of the canvas, fitted when it is larger than the
    /// view.
    func center(on frame: CGRect) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        var next = SHCanvasViewport.fitting(frame, in: canvasSize)
        next.zoom = min(next.zoom, max(viewport.zoom, SHCanvasViewport.zoomRange.lowerBound))
        next.offset = CGPoint(x: canvasSize.width / 2 - frame.midX * next.zoom, y: canvasSize.height / 2 - frame.midY * next.zoom)
        viewport = next
    }
}
