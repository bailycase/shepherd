import Foundation

/// What a design reference handed to an ordinary thread lets its agent read (docs/designs.md ›
/// Design references): the copy of one piece (a whole design, one board, or one element of it)
/// that Shepherd kept when the user sent it (`payload`). Read only, and only that copy: a grant
/// never covers another piece, a later revision, the design agent's chat, comments, or any write.
///
/// Board and element stay strings here (ShepherdCore has no design grammar); ShepherdProtocol's
/// `DesignReference` checks them before a grant is made.
public struct DesignGrant: Codable, Hashable, Sendable {
    public var designID: DesignID
    /// The board's path in the design (`DesignPath.rawValue`); nil for a page or the whole design.
    public var board: String?
    /// The canvas page, or nil for a whole design, board or element.
    public var page: String?
    /// The element's id (`File.dc.html#<tid>:<path>`) for an element's reference; nil for the
    /// board whole.
    public var element: String?
    /// The element's words when it was pinned.
    public var label: String?
    /// The design's revision the piece was sent at.
    public var revision: UInt64
    /// The board's SHA-256 then (a board or element reference).
    public var boardSHA: String?
    /// When it was granted, in milliseconds since 1970.
    public var grantedAt: Double
    /// The copy the send kept (`DesignReferencePayload.id`), under the support directory's
    /// `design-refs/<agent>/<payload>/`. Nil for a grant from before copies were kept, which
    /// answers nothing and goes at startup.
    public var payload: UUID?

    /// An agent keeps at most this many; the oldest go first.
    public static let maxPerAgent = 100

    public init(designID: DesignID, board: String?, element: String? = nil, label: String? = nil, revision: UInt64,
                boardSHA: String? = nil, grantedAt: Double, payload: UUID? = nil, page: String? = nil) {
        self.designID = designID
        self.board = board
        self.page = page
        self.element = element
        self.label = label
        self.revision = revision
        self.boardSHA = boardSHA
        self.grantedAt = grantedAt
        self.payload = payload
    }

    /// Whether this grant names exactly this design, page, board and element.
    public func isPiece(designID: DesignID, board: String?, element: String?, page: String? = nil) -> Bool {
        self.designID == designID && self.board == board && self.element == element && self.page == page
    }

    /// The same piece of the same design, whatever the revision.
    public func isSamePiece(as other: DesignGrant) -> Bool {
        isPiece(designID: other.designID, board: other.board, element: other.element, page: other.page)
    }
}

extension Agent {
    /// The grant for exactly this piece with a kept copy, pinned at `revision` when given, else
    /// the latest sent; nil when the thread was never sent it.
    public func designGrant(designID: DesignID, board: String?, element: String?, revision: UInt64? = nil, page: String? = nil) -> DesignGrant? {
        let pool = designGrants.filter { $0.payload != nil && $0.isPiece(designID: designID, board: board, element: element, page: page) }
        if let revision { return pool.last { $0.revision == revision } }
        return pool.max { ($0.revision, $0.grantedAt) < ($1.revision, $1.grantedAt) }
    }

    /// Every version of the piece this thread was sent, oldest revision first.
    public func designGrants(forPieceOf grant: DesignGrant) -> [DesignGrant] {
        designGrants.filter { $0.payload != nil && $0.isSamePiece(as: grant) }
            .sorted { ($0.revision, $0.grantedAt) < ($1.revision, $1.grantedAt) }
    }

    /// `grants` added (each copy once), and only the newest `DesignGrant.maxPerAgent` kept.
    /// Answers the grants that went past the cap, whose copies the caller removes. The same piece
    /// sent twice keeps both copies: each message's chip reads its own.
    @discardableResult
    public mutating func addDesignGrants(_ grants: [DesignGrant]) -> [DesignGrant] {
        for grant in grants {
            designGrants.removeAll { $0 == grant }
            designGrants.append(grant)
        }
        guard designGrants.count > DesignGrant.maxPerAgent else { return [] }
        let gone = Array(designGrants.prefix(designGrants.count - DesignGrant.maxPerAgent))
        designGrants.removeFirst(gone.count)
        return gone
    }
}

extension ShepherdState {
    /// Every grant a design agent holds dropped (a design's chat reads its design through its own
    /// tools, never a reference), and every grant without a kept copy (from before copies were
    /// kept: it answers nothing). A grant on a design that is gone stays: its copy was sent with
    /// a message and still reaches the agent.
    public mutating func dropStaleDesignGrants() {
        guard agents.contains(where: { !$0.designGrants.isEmpty }) else { return }
        for index in agents.indices where !agents[index].designGrants.isEmpty {
            if isDesignAgent(agents[index]) {
                agents[index].designGrants = []
            } else {
                agents[index].designGrants.removeAll { $0.payload == nil }
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
