import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A board the agent showed with design_show, or wrote into the design with board_write or board_edit (ThreadBoardShown,
/// ThreadBoardStale, ThreadBoardEdited): the copy it
/// was sent, drawn as a card that keeps what the agent saw after the design moves on. A board it
/// drew (ThreadBoardDraft, ThreadBoardChange) comes under its "Drew a board" line, with Discard
/// and Add to design (or Apply to design) while it waits. Where the thread can't read its
/// references (the Design tool off), or until the copy is read, the call stays its activity line.
struct BoardCardView<Fallback: View>: View {
    let id: UUID
    @ViewBuilder let fallback: () -> Fallback
    @Environment(\.designReferences) private var references
    @Environment(\.presentImages) private var presentImages
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        if let references, let board = references.boards[id] {
            VStack(alignment: .leading, spacing: AppLayout.activitySpacing) {
                if let label = board.lineLabel {
                    SHActivityLine(kind: .drew, label: label, meta: board.lineMeta ?? "", status: .done)
                }
                SHBoardCard(design: board.design, board: board.board, meta: board.meta, note: failure ?? board.note, size: board.size,
                            picture: board.picture.map { .picture($0.image) } ?? (board.hasPicture ? .loading : .missing),
                            open: board.picture == nil ? nil : { openFullSize(board) }) {
                    BoardActions(board: board, busy: busy, settle: settle, open: { references.io.open($0) })
                }
            }
            .task(id: references.generation) { await references.loadBoard(id) }
        } else {
            fallback()
                .task(id: references?.generation) { await references?.loadBoard(id) }
        }
    }

    /// The board's picture over the thread, in the viewer images open in (ThreadBoardEditedOpen). A picture that can't be read
    /// leaves the card as it is; Open in design is still there.
    private func openFullSize(_ board: DesignReferenceChips.Board) {
        guard let url = board.pictureURL, let data = try? Data(contentsOf: url), let size = board.size else { return }
        let image = ViewerImage(id: board.copy?.uuidString ?? url.lastPathComponent, name: board.board, data: data, mimeType: "image/png",
                                pixels: CGSize(width: size.width * 2, height: size.height * 2))
        guard image.picture != nil else { return }
        presentImages(ImageViewerState(images: [image], origin: ([board.design] + board.meta.suffix(1)).joined(separator: " · ")))
    }

    private func settle(_ accept: Bool) {
        guard let references, !busy else { return }
        busy = true
        Task {
            failure = await references.settle(id, accept: accept)
            busy = false
        }
    }
}

/// A board's actions, on its card and under the pane: a drawn board's badge, Discard and Add (or
/// Apply) to design while it waits; a shown one's Show vN once the design moved on, and Open in
/// design.
struct BoardActions: View {
    let board: DesignReferenceChips.Board
    var busy = false
    var badge = true
    var settle: ((Bool) -> Void)?
    var open: ((DesignReference) -> Void)?

    var body: some View {
        if let proposal = board.proposal {
            if proposal.state == .pending, let settle {
                if badge { SHBoardBadge(proposal.kind == .draft ? "Draft" : "Changed") }
                Button("Discard") { settle(false) }
                    .buttonStyle(.sh(.ghost, size: .s))
                    .disabled(busy)
                Button(proposal.kind == .draft ? "Add to design" : "Apply to design") { settle(true) }
                    .buttonStyle(.sh(.strong, size: .s))
                    .disabled(busy)
            } else if proposal.state == .added, let open {
                Button("Open in design") { open(board.reference.unpinned) }
                    .buttonStyle(.sh(.ghost, size: .s))
            }
        } else if let open {
            if let latest = board.showLatest {
                Button(latest) { open(board.reference.unpinned) }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .help("Open the board as it is now")
            }
            Button("Open in design") { open(board.reference) }
                .buttonStyle(.sh(.ghost, size: .s))
        }
    }
}

/// The board a card opened beside the thread (ThreadBoardPane), in the side pane's Design tab; a
/// board the agent drew keeps Discard and Apply under it.
struct BoardPane: View {
    let board: DesignReferenceChips.Board
    let open: () -> Void
    var settle: ((Bool) -> Void)?

    var body: some View {
        SHBoardPane(design: board.design, board: board.board, meta: board.meta, size: board.size, picture: board.picture?.image,
                    open: open) {
            if board.proposal?.state == .pending, let settle {
                BoardActions(board: board, badge: false, settle: settle)
            }
        }
    }
}
