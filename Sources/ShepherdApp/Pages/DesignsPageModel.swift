import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The Designs page (NavDesigns) as plain values: This Mac's designs, most recently edited first,
/// in rows of four, and its design systems in rows of three ending in "Build one from a repo".
/// Pure: the same inputs always give the same page. Derived once per change, never in a view's
/// body.
struct DesignsPageModel: Equatable {
    struct Card: Identifiable, Equatable {
        let id: DesignID
        let name: String
        /// The design's system: its namespace; nil while it is drawn in none (a design belongs to
        /// no project).
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

    /// A design system's card, or a system build whose agent hasn't written its system yet.
    struct System: Identifiable, Equatable {
        let id: DesignSystemTarget
        let name: String
        /// "dashboard-web · tokens.css".
        let source: String?
        /// "3 designs".
        let count: String
        /// Four of its colors.
        let swatches: [DesignSystemPresentation.Swatch]
    }

    /// A remote host's designs (`designs.v1`), under its name: its cards, most recently edited
    /// first, as the host listed them.
    struct HostSection: Identifiable, Equatable {
        let id: UUID
        let name: String
        let cards: [Card]

        var rows: [[Card]] {
            stride(from: 0, to: cards.count, by: DesignsPageModel.columns)
                .map { Array(cards[$0..<min($0 + DesignsPageModel.columns, cards.count)]) }
        }
    }

    /// A project "Build one from a repo" can read.
    struct Project: Identifiable, Equatable {
        let id: SpaceID
        let name: String
    }

    /// The first board a card draws, as the thumbnails last read it.
    struct FirstBoard: Equatable {
        var size: CGSize
        var version: Int
    }

    var cards: [Card] = []
    /// Each connected host that serves designs, after this Mac's.
    var hosts: [HostSection] = []
    var systems: [System] = []
    /// The projects a system can be built from; none leaves the tile disabled.
    var projects: [Project] = []
    /// The filter matched nothing (there are designs).
    var noMatch = false

    static let columns = 4
    static let systemColumns = 3

    /// The cards in rows of `columns`.
    var rows: [[Card]] {
        stride(from: 0, to: cards.count, by: Self.columns).map { Array(cards[$0..<min($0 + Self.columns, cards.count)]) }
    }

    /// The systems in rows of `systemColumns`, the build tile after the last: each row's
    /// systems, and whether the tile ends it.
    var systemRows: [(systems: [System], tile: Bool)] {
        let slots = systems.count + 1
        return stride(from: 0, to: slots, by: Self.systemColumns).map { start in
            let end = min(start + Self.systemColumns, slots)
            return (Array(systems[min(start, systems.count)..<min(end, systems.count)]), end == slots)
        }
    }

    /// Night Watch's source line: it is generated from ShepherdUI's tokens.
    static let builtInSource = "shepherd · ShepherdUI Tokens"

    static func make(designs: [Design], spaces: [Space], firstBoards: [DesignID: FirstBoard], filter: String,
                     selection: DesignID?, now: Date, systems: [DesignSystemSummary] = [],
                     swatches: [String: [DesignSystemPresentation.Swatch]] = [:]) -> DesignsPageModel {
        let names = Dictionary(spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func system(_ design: Design) -> String? { design.systemNamespace }
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ text: String?) -> Bool { text?.localizedCaseInsensitiveContains(query) ?? false }
        let canvases = designs.filter { !$0.buildsSystem }
        let sorted = canvases.sorted { a, b in
            a.lastActiveAt != b.lastActiveAt ? a.lastActiveAt > b.lastActiveAt : a.createdAt > b.createdAt
        }
        let matching = query.isEmpty ? sorted : sorted.filter { matches($0.name) || matches(system($0)) }
        var model = DesignsPageModel()
        model.cards = matching.map { design in
            let first = firstBoards[design.id]
            return Card(id: design.id, name: design.name, system: system(design), detail: boardsText(design.boardCount ?? 0),
                        edited: "edited \(SuggestionsPresentation.when(design.lastActiveAt / 1000, now: now))",
                        board: NWDesignCardBoard(size: first?.size), thumbnail: first?.version ?? 0,
                        selected: design.id == selection)
        }

        // The systems built here by name, then builds still reading their project, then the
        // built-ins.
        var counts: [String: Int] = [:]
        for design in canvases { if let ns = design.systemNamespace { counts[ns, default: 0] += 1 } }
        let used = Set(matching.compactMap(\.systemNamespace))
        let own = systems.filter { !$0.builtIn }.sorted { $0.info.title.localizedStandardCompare($1.info.title) == .orderedAscending }
        let builtIn = systems.filter(\.builtIn)
        var cards: [System] = (own + builtIn).map { summary in
            let info = summary.info
            let source = summary.builtIn ? builtInSource
                : DesignSystemPresentation.source(project: info.spaceID.flatMap { names[$0] }, sources: info.sources)
            return System(id: .system(info.namespace), name: info.title, source: source, count: designsText(counts[info.namespace] ?? 0),
                          swatches: swatches[info.namespace] ?? [])
        }
        let built = Set(systems.compactMap(\.info.ownerDesignID))
        let pending = designs.filter { $0.buildsSystem && !built.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }.map { build in
            System(id: .build(build.id), name: build.name, source: build.sourceSpaceID.flatMap { names[$0] }.map { "\($0) · building" } ?? "building",
                   count: "", swatches: [])
        }
        cards.insert(contentsOf: pending, at: own.count)
        if !query.isEmpty {
            cards = cards.filter { card in
                if matches(card.name) || matches(card.source) { return true }
                if case .system(let ns) = card.id { return used.contains(ns) || matches(ns) }
                return false
            }
        }
        model.systems = cards
        model.projects = spaces.filter { !$0.hidden }.map { Project(id: $0.id, name: $0.name) }
        model.noMatch = !canvases.isEmpty && matching.isEmpty
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
    var systems: [DesignSystemSummary]
    var swatches: [String: [DesignSystemPresentation.Swatch]]
    /// The hosts' designs, as their sections list them.
    var hosts: [DesignsPageModel.HostSection] = []
    /// The minute its relative times were worded in.
    var minute: Int
}
