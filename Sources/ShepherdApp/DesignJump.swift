import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Jump to a board (JumpInContext): over a design, the command palette's chord opens this card
// instead of the palette. "This design" lists the boards opened lately, newest first, then the
// rest of the design in canvas order; "All designs" lists this Mac's designs, most recently
// edited first. A query filters either by name, with the palette's ranking. ⏎ shows the board
// picked and in view, or opens the design.

/// One row of the card: a board of the design on screen, or a design.
struct DesignJumpItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case board(DesignPath)
        case design(DesignID)
    }

    enum Section: Equatable {
        case recent, otherBoards, designs
    }

    let kind: Kind
    let section: Section
    let title: String
    /// "1280 × 800 · opened 2m ago", "4 boards · edited 2h ago".
    let meta: String
    /// "this board": the board the canvas has picked.
    var tag: String?

    var id: String {
        switch kind {
        case .board(let path): "board/" + path.rawValue
        case .design(let id): "design/" + id.rawValue
        }
    }
}

/// The card's scope pills.
enum DesignJumpScope: Hashable, CaseIterable {
    case thisDesign, allDesigns

    var title: String {
        switch self {
        case .thisDesign: "This design"
        case .allDesigns: "All designs"
        }
    }
}

/// When each board of each design was last jumped to, newest first: a click on the canvas picks a
/// board, it doesn't open one (the board lists the board on screen under one opened since). Kept
/// across launches: the card's Recent section reads it.
struct DesignJumpRecents: Codable, Equatable {
    /// Boards per design, newest first, with when (seconds since 1970).
    private(set) var boards: [String: [Entry]] = [:]

    struct Entry: Codable, Equatable {
        var path: String
        var at: Double
    }

    /// The most a design remembers: older boards fall into Other boards.
    static let limit = 8

    func entries(_ design: DesignID) -> [Entry] { boards[design.rawValue] ?? [] }

    /// `path` was opened now: first, once.
    mutating func opened(_ path: DesignPath, in design: DesignID, at time: Double) {
        var list = entries(design).filter { $0.path != path.rawValue }
        list.insert(Entry(path: path.rawValue, at: time), at: 0)
        boards[design.rawValue] = Array(list.prefix(Self.limit))
    }

    /// Forgets designs that are gone.
    mutating func prune(keeping designs: Set<DesignID>) {
        let keep = Set(designs.map(\.rawValue))
        boards = boards.filter { keep.contains($0.key) }
    }
}

enum DesignJump {
    /// The rows for `scope` and `query`. This design: Recent (boards opened lately that still
    /// exist, newest first, the board on screen tagged "this board"), then Other boards in canvas
    /// order. With a query, the matches in one list, best first. All designs: every design, most
    /// recently edited first, the one on screen tagged "this design".
    static func items(scope: DesignJumpScope, query: String, index: DesignIndex?, design: DesignID?, current: DesignPath?,
                      recents: DesignJumpRecents, designs: [Design], now: Date) -> [DesignJumpItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch scope {
        case .thisDesign:
            guard let index, let design else { return [] }
            let order = DesignReferenceReading.canvasOrder(index)
            func name(_ path: DesignPath) -> String {
                let title = index.boards[path]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                return title?.isEmpty == false ? title! : path.stem
            }
            func size(_ path: DesignPath) -> String {
                guard let board = index.boards[path] else { return "" }
                return "\(Int(board.w.rounded())) × \(Int(board.h.rounded()))"
            }
            let opened = recents.entries(design).compactMap { entry -> (DesignPath, Double)? in
                guard let path = DesignPath(entry.path), index.boards[path] != nil else { return nil }
                return (path, entry.at)
            }
            let recent = opened.map { path, at in
                DesignJumpItem(kind: .board(path), section: .recent, title: name(path),
                               meta: "\(size(path)) · opened \(openedText(at, now: now))", tag: path == current ? "this board" : nil)
            }
            let seen = Set(opened.map(\.0))
            let others = order.filter { !seen.contains($0) }.map { path in
                DesignJumpItem(kind: .board(path), section: .otherBoards, title: name(path), meta: size(path),
                               tag: path == current ? "this board" : nil)
            }
            return ranked(recent + others, query: query)
        case .allDesigns:
            let sorted = designs.filter { !$0.buildsSystem }.sorted { a, b in
                a.lastActiveAt != b.lastActiveAt ? a.lastActiveAt > b.lastActiveAt : a.createdAt > b.createdAt
            }
            let rows = sorted.map { item in
                DesignJumpItem(kind: .design(item.id), section: .designs, title: item.name,
                               meta: "\(DesignsPageModel.boardsText(item.boardCount ?? 0)) · edited \(SuggestionsPresentation.when(item.lastActiveAt / 1000, now: now))",
                               tag: item.id == design ? "this design" : nil)
            }
            return ranked(rows, query: query)
        }
    }

    /// The rows matching `query`, best first (the palette's ranking), in their order where equal.
    /// No query keeps them all as they are.
    static func ranked(_ rows: [DesignJumpItem], query: String) -> [DesignJumpItem] {
        guard !query.isEmpty else { return rows }
        var matches: [(row: DesignJumpItem, rank: Int, offset: Int)] = []
        for (offset, row) in rows.enumerated() {
            if let rank = PaletteSearch.rank(query: query, in: row.title) { matches.append((row, rank, offset)) }
        }
        matches.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.offset < $1.offset }
        return matches.map(\.row)
    }

    /// The row the card highlights as it opens: the first that isn't the board (or design) on
    /// screen, so getting back to the one before takes only ⏎.
    static func initialHighlight(_ rows: [DesignJumpItem]) -> Int {
        rows.firstIndex { $0.tag == nil } ?? 0
    }

    /// "2m ago", "10m ago", "yesterday", "Sep 24": as the board says it.
    static func openedText(_ time: Double, now: Date) -> String {
        SuggestionsPresentation.when(time, now: now).replacingOccurrences(of: "just now", with: "now")
    }
}
