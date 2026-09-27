import Foundation

/// What a design reference handed to an ordinary thread lets its agent read (docs/designs.md ›
/// Design references): one board of one design, or one element of it, from the revision it was
/// pinned at on. Read only: a grant never covers another design, another board, another element
/// of an element's board, the design agent's chat, comments, or any write.
///
/// Board and element stay strings here (ShepherdCore has no design grammar); ShepherdProtocol's
/// `DesignReference` checks them before a grant is made.
public struct DesignGrant: Codable, Hashable, Sendable {
    public var designID: DesignID
    /// The board's path in the design (`DesignPath.rawValue`).
    public var board: String
    /// The element's id (`File.dc.html#<tid>:<path>`) for an element's reference; nil for the
    /// board whole.
    public var element: String?
    /// The element's words when it was pinned, to find it again after a rewrite renumbers it.
    public var label: String?
    /// The design's revision when the reference was sent: what `changes` compares against.
    public var revision: UInt64
    /// The board's SHA-256 then (its pinned copy is kept under that name).
    public var boardSHA: String?
    /// When it was granted, in milliseconds since 1970.
    public var grantedAt: Double

    /// An agent keeps at most this many; the oldest go first.
    public static let maxPerAgent = 100

    public init(designID: DesignID, board: String, element: String? = nil, label: String? = nil, revision: UInt64,
                boardSHA: String? = nil, grantedAt: Double) {
        self.designID = designID
        self.board = board
        self.element = element
        self.label = label
        self.revision = revision
        self.boardSHA = boardSHA
        self.grantedAt = grantedAt
    }

    /// Whether a read of `board` (with `element`, or the board whole) in `designID` is this
    /// reference: the same design and board, and for an element's grant the same element, or its
    /// board whole (the board's page and image come with an element's reference).
    public func covers(designID: DesignID, board: String, element: String?) -> Bool {
        guard designID == self.designID, board == self.board else { return false }
        guard let element else { return true }
        return self.element == nil || self.element == element
    }

    /// The same piece of the same design, whatever the revision.
    public func isSamePiece(as other: DesignGrant) -> Bool {
        designID == other.designID && board == other.board && element == other.element
    }
}

extension Agent {
    /// The grant that lets this agent read the piece, preferring the one pinned at `revision`,
    /// else the latest for it; nil when none covers it.
    public func designGrant(designID: DesignID, board: String, element: String?, revision: UInt64? = nil) -> DesignGrant? {
        let covering = designGrants.filter { $0.covers(designID: designID, board: board, element: element) }
        let exact = covering.filter { $0.element == element }
        let pool = exact.isEmpty ? covering : exact
        if let revision, let pinned = pool.last(where: { $0.revision == revision }) { return pinned }
        return pool.max { ($0.revision, $0.grantedAt) < ($1.revision, $1.grantedAt) }
    }

    /// `grants` added: a piece already granted at the same revision is kept once, and only the
    /// newest `DesignGrant.maxPerAgent` are kept.
    public mutating func addDesignGrants(_ grants: [DesignGrant]) {
        for grant in grants {
            designGrants.removeAll { $0.isSamePiece(as: grant) && $0.revision == grant.revision }
            designGrants.append(grant)
        }
        if designGrants.count > DesignGrant.maxPerAgent {
            designGrants.removeFirst(designGrants.count - DesignGrant.maxPerAgent)
        }
    }
}

extension ShepherdState {
    /// Every grant on a design no longer in the workspace dropped, and every design agent's
    /// (a design's chat reads its design through its own tools, never a reference).
    public mutating func dropStaleDesignGrants() {
        guard agents.contains(where: { !$0.designGrants.isEmpty }) else { return }
        let designs = Set(designs.map(\.id))
        for index in agents.indices where !agents[index].designGrants.isEmpty {
            if isDesignAgent(agents[index]) {
                agents[index].designGrants = []
            } else {
                agents[index].designGrants.removeAll { !designs.contains($0.designID) }
            }
        }
    }

    /// Whether `dropStaleDesignGrants` would change anything.
    public var hasStaleDesignGrants: Bool {
        var copy = self
        copy.dropStaleDesignGrants()
        return copy != self
    }
}
