import Foundation
import ShepherdCore
import ShepherdProtocol

// Shared pieces on the Mac's canvas (docs/designs.md › Shared pieces; DESIGN.md › Shared pieces): a
// piece other boards import says how many use it, and an element that is one use of a piece
// (selection stops at its `<dc-import>`) offers Go to source, which brings the piece's board into
// view. The canvas is read-only about a use: Tweak writes no style on an instance, since the
// piece draws it; the change goes to the piece, once, for every board.

/// What the Tweak tab says of a selected use of a piece.
struct DesignPieceNote {
    /// "3 boards": how many boards use the piece, when it has any.
    var boards: String?
    /// Brings the piece's board into view; nil when the piece has no frame on this canvas.
    var goToSource: (() -> Void)?
}

extension DesignScreenModel {
    /// The piece's board a use mounts, when the design has it with a frame on its canvas to go to.
    func pieceBoard(for pick: DesignElementPick) -> DesignPath? {
        guard let name = pick.piece, let board = DesignImports.resolve(name: name, from: pick.board),
              snapshot?.index.boards[board] != nil else { return nil }
        return board
    }

    /// The Tweak tab's note for the latest pick, when it is a use of a piece.
    var pieceNote: DesignPieceNote? {
        guard let pick = picks.last?.element, let name = pick.piece else { return nil }
        let piece = DesignImports.resolve(name: name, from: pick.board)
        let uses = piece.map { usage.usedIn($0) } ?? 0
        return DesignPieceNote(boards: uses > 0 ? "\(uses) \(uses == 1 ? "board" : "boards")" : nil,
                               goToSource: pieceBoard(for: pick).map { board in { [weak self] in self?.goToSource(board) } })
    }

    /// Go to source: the piece's board picked and brought into view.
    func goToSource(_ board: DesignPath) {
        reveal(board: board, element: nil)
    }
}
