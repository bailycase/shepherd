import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdUI

/// The Designs page (NavDesigns) as plain values: This Mac's designs, most recently edited first,
/// in rows of four, and the design systems they are drawn in. Pure: the same inputs always give
/// the same page. Derived once per change, never in a view's body.
struct DesignsPageModel: Equatable {
    struct Card: Identifiable, Equatable {
        let id: DesignID
        let name: String
        /// The design's system: its namespace, else its project's name (the agent checks the
        /// boards against the project's own stylesheets).
        let system: String?
        /// "4 boards".
        let detail: String
        /// "edited 2h ago".
        let edited: String
        let board: NWDesignCardBoard
        /// Moves when the thumbnail's image changes.
        let thumbnail: Int
        let selected: Bool
    }

    struct System: Identifiable, Equatable {
        var id: String { name }
        let name: String
        /// "3 designs".
        let count: String
    }

    /// The first board a card draws, as the thumbnails last read it.
    struct FirstBoard: Equatable {
        var size: CGSize
        var version: Int
    }

    var cards: [Card] = []
    var systems: [System] = []
    /// The filter matched nothing (there are designs).
    var noMatch = false

    static let columns = 4

    /// The cards in rows of `columns`.
    var rows: [[Card]] {
        stride(from: 0, to: cards.count, by: Self.columns).map { Array(cards[$0..<min($0 + Self.columns, cards.count)]) }
    }

    static func make(designs: [Design], spaces: [Space], firstBoards: [DesignID: FirstBoard], filter: String,
                     selection: DesignID?, now: Date) -> DesignsPageModel {
        let names = Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func system(_ design: Design) -> String? { design.systemNamespace ?? names[design.spaceID] }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = designs.sorted { a, b in
            a.lastActiveAt != b.lastActiveAt ? a.lastActiveAt > b.lastActiveAt : a.createdAt > b.createdAt
        }
        let matching = query.isEmpty ? sorted : sorted.filter { design in
            design.name.localizedCaseInsensitiveContains(query) || (system(design)?.localizedCaseInsensitiveContains(query) ?? false)
        }
        var model = DesignsPageModel()
        model.cards = matching.map { design in
            let first = firstBoards[design.id]
            return Card(id: design.id, name: design.name, system: system(design), detail: boardsText(design.boardCount ?? 0),
                        edited: "edited \(SuggestionsPresentation.when(design.lastActiveAt / 1000, now: now))",
                        board: NWDesignCardBoard(size: first?.size), thumbnail: first?.version ?? 0,
                        selected: design.id == selection)
        }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for design in matching {
            guard let name = system(design) else { continue }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        model.systems = order.map { System(name: $0, count: designsText(counts[$0] ?? 0)) }
        model.noMatch = !designs.isEmpty && matching.isEmpty
        return model
    }

    /// "1 board", "4 boards".
    static func boardsText(_ count: Int) -> String { count == 1 ? "1 board" : "\(count) boards" }

    /// "1 design", "3 designs".
    static func designsText(_ count: Int) -> String { count == 1 ? "1 design" : "\(count) designs" }
}

/// What the Designs page is derived from.
struct DesignsPageInputs: Equatable {
    var designs: [Design]
    var spaces: [Space]
    var firstBoards: [DesignID: DesignsPageModel.FirstBoard]
    var filter: String
    var selection: DesignID?
    /// The minute its relative times were worded in.
    var minute: Int
}
