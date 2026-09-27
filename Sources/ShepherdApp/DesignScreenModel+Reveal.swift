import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

// "Open in design" (a thread's reference chip, its preview): the piece's board picked and brought
// into view, its element selected once the board draws.

extension DesignScreenModel {
    // MARK: Open in design

    /// "Open in design" from a thread's chip: the piece's board picked and brought into view, and
    /// its element selected once the board draws live.
    func reveal(board: DesignPath, element: DesignElementID?) {
        pendingReveal = (board, element)
        applyReveal()
    }

    func applyReveal() {
        guard let reveal = pendingReveal, let index = snapshot?.index else { return }
        pendingReveal = nil
        guard let entry = index.boards[reveal.board] else { return }
        if let pageID = index.page(of: reveal.board), pageID != page { showPage(pageID) }
        present(nil)
        closeComment()
        setSelection([Pick(board: reveal.board)])
        center(on: CGRect(x: entry.x, y: entry.y, width: entry.w, height: entry.h))
        guard let element = reveal.element, let host else { return }
        Task {
            // The board goes live as the selection's focus; ask it where the element is once it
            // draws (a few tries: a board loads in well under a second).
            for _ in 0..<20 {
                if let found = await host.locate(reveal.board, tids: [element.tid]) {
                    if let pick = found[element.tid], pick.id.path == element.path, picks.last?.board == reveal.board {
                        setSelection([Pick(board: reveal.board, element: pick)])
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Brings a board's frame into the middle of the canvas, fitted when it is larger than the
    /// view.
    func center(on frame: CGRect) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        var next = NWCanvasViewport.fitting(frame, in: canvasSize)
        next.zoom = min(next.zoom, max(viewport.zoom, NWCanvasViewport.zoomRange.lowerBound))
        next.offset = CGPoint(x: canvasSize.width / 2 - frame.midX * next.zoom, y: canvasSize.height / 2 - frame.midY * next.zoom)
        viewport = next
    }
}
