import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A board the agent showed with design_show (ThreadBoardShown, ThreadBoardStale): the copy it
/// was sent, drawn as a card that keeps what the agent saw after the design moves on. Where the
/// thread can't read its references (the Design tool off), or until the copy is read, the call
/// stays its activity line.
struct BoardCardView<Fallback: View>: View {
    let id: UUID
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.designReferences) private var references

    var body: some View {
        if let references, let board = references.boards[id] {
            SHBoardCard(design: board.design, board: board.board, meta: board.meta, note: board.note, size: board.size,
                        picture: board.picture.map { .picture($0.image) } ?? (board.hasPicture ? .loading : .missing),
                        open: { references.io.showBeside(board) }) {
                if let latest = board.showLatest {
                    Button(latest) { references.io.open(board.reference.unpinned) }
                        .buttonStyle(.sh(.secondary, size: .s))
                        .help("Open the board as it is now")
                }
                Button("Open in design") { references.io.open(board.reference) }
                    .buttonStyle(.sh(.ghost, size: .s))
            }
            .task(id: references.generation) { await references.loadBoard(id) }
        } else {
            fallback()
                .task(id: references?.generation) { await references?.loadBoard(id) }
        }
    }
}

/// The board a card opened beside the thread (ThreadBoardPane), in the side pane's Design tab.
struct BoardPane: View {
    let board: DesignReferenceChips.Board
    let open: () -> Void

    var body: some View {
        SHBoardPane(design: board.design, board: board.board, meta: board.meta, size: board.size, picture: board.picture?.image,
                    open: open) {}
    }
}
