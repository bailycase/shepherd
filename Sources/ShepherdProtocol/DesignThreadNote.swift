import Foundation
import ShepherdCore

/// A short note an ordinary thread left on a design piece it was sent ("Implemented in #142 on
/// agent/checkout-funnel."): docs/designs.md › Notes back. The canvas draws it as a thread pin
/// (blue, a code glyph) naming the thread, never as a comment or the design agent's, and the user
/// can remove it. Kept beside the design's project (`thread-notes.json`), never inside the
/// `project/` its agent edits, and never shown to the design agent.
public struct DesignThreadNote: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The thread that left it, and its name then.
    public var agentID: AgentID
    public var thread: String
    public var board: DesignPath
    /// The element it is on, as the board numbered it when the piece was sent; nil for the board.
    public var element: DesignElementID?
    /// The element's words then, to find it again after a rewrite renumbers it.
    public var label: String?
    /// The revision of the piece the thread was sent ("from v23").
    public var revision: UInt64
    public var text: String
    /// Milliseconds since 1970.
    public var createdAt: Double

    /// A note is one short paragraph of plain text.
    public static let maxLength = 500
    /// A design keeps at most this many; the oldest go first.
    public static let maxPerDesign = 200
    /// A thread leaves at most this many notes in `rateWindow` seconds, across designs.
    public static let rateLimit = 6
    public static let rateWindow: TimeInterval = 600

    public init(id: UUID = UUID(), agentID: AgentID, thread: String, board: DesignPath, element: DesignElementID? = nil,
                label: String? = nil, revision: UInt64, text: String, createdAt: Double) {
        self.id = id
        self.agentID = agentID
        self.thread = thread
        self.board = board
        self.element = element
        self.label = label
        self.revision = revision
        self.text = text
        self.createdAt = createdAt
    }

    /// Whether this note is on the same piece, left by the same thread: a new one replaces it.
    public func isSamePlace(as other: DesignThreadNote) -> Bool {
        agentID == other.agentID && board == other.board && element == other.element
    }

    /// `text` as a note keeps it: every run of whitespace and control characters one space, the
    /// ends trimmed. Nil when nothing is left or it is longer than `maxLength` characters.
    public static func cleaned(_ text: String) -> String? {
        var out = ""
        var space = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format && scalar.value != 0x200D {
                space = !out.isEmpty
                continue
            }
            if space { out.append(" "); space = false }
            out.unicodeScalars.append(scalar)
        }
        guard !out.isEmpty, out.count <= maxLength else { return nil }
        return out
    }
}

/// A design's `thread-notes.json`.
public struct DesignThreadNotes: Codable, Hashable, Sendable {
    public var version: Int
    /// Oldest first.
    public var notes: [DesignThreadNote]

    public init(notes: [DesignThreadNote] = []) {
        version = 1
        self.notes = notes
    }

    /// `note` added in place of the same thread's note on the same piece, the oldest going past
    /// `DesignThreadNote.maxPerDesign`.
    public mutating func add(_ note: DesignThreadNote) {
        notes.removeAll { $0.isSamePlace(as: note) }
        notes.append(note)
        if notes.count > DesignThreadNote.maxPerDesign { notes.removeFirst(notes.count - DesignThreadNote.maxPerDesign) }
    }
}
