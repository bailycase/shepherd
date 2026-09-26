import Foundation
import ShepherdProtocol

/// A user message that carried Pencil markup: how many marks, and how many with a note.
public struct NativeMarkupCounts: Equatable, Sendable {
    public var strokes: Int
    public var notes: Int

    public init(strokes: Int, notes: Int) {
        self.strokes = strokes
        self.notes = notes
    }

    /// "2 strokes · 2 notes".
    public var text: String { DesignMarkup.countsText(strokes: strokes, notes: notes) }
}

/// The comments a design agent's turn proposed from the viewer's markup: its last
/// `markup_propose` call that the host answered, with the proposals the host checked.
public struct NativeMarkupProposals: Equatable, Sendable {
    public var proposals: [DesignCommentDraft]

    public init(proposals: [DesignCommentDraft]) {
        self.proposals = proposals
    }

    /// The turn's last successful `markup_propose` result, or nil when it made none.
    public init?(_ turn: NativeTurn) {
        for message in turn.messages.reversed()
        where message.role == "toolResult" && message.toolName == "markup_propose" && message.isError != true && message.status != "error" {
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            if let read = DesignMarkupProposals.parse(text) {
                self.init(proposals: read.proposals)
                return
            }
        }
        return nil
    }

    /// Each proposal's name (`<call>#<n>`), in order.
    public var ids: [String] { proposals.compactMap(\.proposal) }
}
