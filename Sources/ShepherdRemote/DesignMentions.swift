import Foundation
import ShepherdCore
import ShepherdProtocol

/// Where a design the @ picker lists lives (MentionPicker, DesignRefStates). Only `.local` is
/// listed yet; the others are the picker's host tags and dimmed rows, drawn by ShepherdUI's
/// states until remote references come.
public enum DesignMentionHost: Hashable, Sendable {
    case local
    /// A host this Mac connects to: its name, and whether it is offline (when it was last seen,
    /// ms since 1970).
    case remote(name: String, offline: Bool, lastSeen: Double?)
}

/// One row the composer's @ picker can pick: a design, a page, a board, or an element of a
/// board, with its breadcrumb (docs/designs.md › Design references › The @ picker).
public struct DesignMentionItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case design, page, board, element
    }

    public var id: String { reference.string }
    public var kind: Kind
    /// The piece, not pinned: picking it pins it (`SessionServer.pinDesignReference`).
    public var reference: DesignReference
    /// A design's name, a board's title (else its stem), an element's name and words
    /// ("card “Checkout funnel”").
    public var title: String
    /// The titles above it, the design first: ["Checkout funnel dashboard", "A · Funnel first"].
    public var breadcrumb: [String]
    public var host: DesignMentionHost
    /// A design's first installed system ("acme-web"), its boards, and when it was last active
    /// (ms since 1970).
    public var system: String?
    public var boardCount: Int?
    public var activeAt: Double?
    /// A board's size and how many elements the picker lists on it.
    public var width: Double?
    public var height: Double?
    public var elementCount: Int?
    /// An element's tag and how many elements are under it.
    public var tag: String?
    public var inside: Int?
    /// What an element is and holds, under its title ("funnel bars · 5 steps"; `DesignElementSummary`).
    public var detail: String?
    /// The design's revision the row was read at: a row's picture is kept per revision.
    public var revision: UInt64?

    public init(kind: Kind, reference: DesignReference, title: String, breadcrumb: [String], host: DesignMentionHost = .local,
                system: String? = nil, boardCount: Int? = nil, activeAt: Double? = nil, width: Double? = nil, height: Double? = nil,
                elementCount: Int? = nil, tag: String? = nil, inside: Int? = nil, detail: String? = nil, revision: UInt64? = nil) {
        self.kind = kind
        self.reference = reference
        self.title = title
        self.breadcrumb = breadcrumb
        self.host = host
        self.system = system
        self.boardCount = boardCount
        self.activeAt = activeAt
        self.width = width
        self.height = height
        self.elementCount = elementCount
        self.tag = tag
        self.inside = inside
        self.detail = detail
        self.revision = revision
    }

    /// Whether every word of `query` is in its title or breadcrumb, ignoring case and accents.
    func matches(_ words: [String]) -> Bool {
        let haystack = (breadcrumb + [title]).joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy(haystack.contains)
    }
}

/// Where the @ picker's read of this Mac's designs stands, so it can say what it is doing before
/// there are rows to list (docs/design/design-tool-references.md › The @ picker): reading, read,
/// or failed. Reading is asked once per opening, and an answer belongs to the opening that asked:
/// one that comes after a newer opening began is dropped, so a slow first read never overwrites
/// the second's. A catalog already read keeps its rows through a later read and through its failure
/// (a Retry nobody needs is no failure); only a picker with no catalog says "Loading…" or "Couldn't".
public struct DesignMentionLoad: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Nothing asked yet.
        case idle
        case loading
        case loaded
        case failed(reason: String)
    }

    /// What the picker draws.
    public enum Stage: Equatable, Sendable {
        /// The rows of the catalog read last (which may be none: "No designs yet").
        case rows
        case loading
        case failed(reason: String)
    }

    public private(set) var phase: Phase = .idle
    /// A catalog has been read: its rows show, whatever a later read is doing.
    public private(set) var hasCatalog = false
    private var request = 0

    public init() {}

    /// What the picker draws now: the rows once any were read; before that, the read under way
    /// (an idle picker is about to ask) or why it failed.
    public var stage: Stage {
        if hasCatalog { return .rows }
        if case .failed(let reason) = phase { return .failed(reason: reason) }
        return .loading
    }

    /// A read starts; answer it with the returned number.
    @discardableResult
    public mutating func begin() -> Int {
        request += 1
        phase = .loading
        return request
    }

    /// The read `request` came back with a catalog. False, and nothing changes, when a newer
    /// read began since.
    @discardableResult
    public mutating func finish(_ request: Int) -> Bool {
        guard request == self.request else { return false }
        phase = .loaded
        hasCatalog = true
        return true
    }

    /// The read `request` failed (or gave up). A catalog read before keeps its rows. False, and
    /// nothing changes, when a newer read began since.
    @discardableResult
    public mutating func fail(_ request: Int, reason: String) -> Bool {
        guard request == self.request else { return false }
        phase = hasCatalog ? .loaded : .failed(reason: reason)
        return true
    }
}

/// What the @ picker offers from this Mac: its designs (most recently active first), each
/// design's boards in canvas order, and each board's elements. Derived off the main thread and
/// off the server's queue (`SessionServer.designMentionCatalog`); the picker reads it and
/// `search` narrows it, both pure.
public struct DesignMentionCatalog: Hashable, Sendable {
    public var designs: [DesignMentionItem]
    public var pages: [DesignID: [DesignMentionItem]]
    public var boards: [DesignID: [DesignMentionItem]]
    /// By the board's reference string (`DesignMentionItem.id`).
    public var elements: [String: [DesignMentionItem]]

    /// A board lists at most this many elements.
    public static let maxElementsPerBoard = 300

    public init(designs: [DesignMentionItem] = [], pages: [DesignID: [DesignMentionItem]] = [:],
                boards: [DesignID: [DesignMentionItem]] = [:], elements: [String: [DesignMentionItem]] = [:]) {
        self.designs = designs
        self.pages = pages
        self.boards = boards
        self.elements = elements
    }

    /// Where the picker is: the designs, inside a design, or inside a board.
    public enum Scope: Hashable, Sendable {
        case designs
        case design(DesignID)
        case board(DesignReference)
    }

    /// The rows of a scope: the designs; a design's own row (the whole design, "rare": its first
    /// row) then its boards; a board's own row ("Whole board") then its elements.
    public func rows(in scope: Scope) -> [DesignMentionItem] {
        switch scope {
        case .designs:
            return designs
        case .design(let id):
            return (designs.first { $0.reference.designID == id }.map { [$0] } ?? []) + (pages[id] ?? []) + (boards[id] ?? [])
        case .board(let reference):
            let key = reference.unpinned.string
            let board = boards[reference.designID]?.first { $0.id == key }
            return (board.map { [$0] } ?? []) + (elements[key] ?? [])
        }
    }

    /// Every design, board and element whose title or breadcrumb holds each word of `query`, in
    /// the catalog's order (a design, then its boards, each with its elements), at most `limit`.
    public func search(_ query: String, limit: Int = 60) -> [DesignMentionItem] {
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Array(designs.prefix(limit)) }
        var out: [DesignMentionItem] = []
        for design in designs {
            if design.matches(words) { out.append(design) }
            for page in pages[design.reference.designID] ?? [] where page.matches(words) {
                if out.count >= limit { return out }
                out.append(page)
            }
            for board in boards[design.reference.designID] ?? [] {
                if out.count >= limit { return out }
                if board.matches(words) { out.append(board) }
                for element in elements[board.id] ?? [] where element.matches(words) {
                    if out.count >= limit { return out }
                    out.append(element)
                }
            }
            if out.count >= limit { return Array(out.prefix(limit)) }
        }
        return out
    }

    /// One design's rows, from what the host read: the design, its boards in canvas order (their
    /// sources by path; a board without one lists no elements), and each board's elements with
    /// their words or `data-el` names.
    public static func entries(design: Design, snapshot: DesignSnapshot, sources: [DesignPath: String], system: String?)
        -> (design: DesignMentionItem, pages: [DesignMentionItem], boards: [DesignMentionItem], elements: [String: [DesignMentionItem]])? {
        guard let whole = DesignReference(designID: design.id, board: nil) else { return nil }
        let order = DesignReferenceReading.canvasOrder(snapshot.index)
        let designItem = DesignMentionItem(kind: .design, reference: whole, title: design.name, breadcrumb: [], system: system,
                                           boardCount: order.count, activeAt: design.lastActiveAt, revision: snapshot.revision)
        let pages = (snapshot.index.pages ?? []).compactMap { page -> DesignMentionItem? in
            guard let reference = DesignReference(designID: design.id, board: nil, page: page.id) else { return nil }
            return DesignMentionItem(kind: .page, reference: reference, title: page.name.flatMap(DesignViewRecord.label) ?? page.id,
                                     breadcrumb: [design.name], boardCount: order.filter { snapshot.index.page(of: $0) == page.id }.count,
                                     revision: snapshot.revision)
        }
        var boards: [DesignMentionItem] = []
        var elements: [String: [DesignMentionItem]] = [:]
        for path in order {
            guard let reference = DesignReference(designID: design.id, board: path), let entry = snapshot.index.boards[path] else { continue }
            let title = entry.title.flatMap(DesignViewRecord.label) ?? path.stem
            let rows = sources[path].map { Self.elements(of: reference, source: $0, breadcrumb: [design.name, title], revision: snapshot.revision) } ?? []
            boards.append(DesignMentionItem(kind: .board, reference: reference, title: title, breadcrumb: [design.name],
                                            width: entry.w, height: entry.h, elementCount: rows.count, revision: snapshot.revision))
            elements[reference.string] = rows
        }
        return (designItem, pages, boards, elements)
    }

    /// A board's elements as the picker lists them: each that has words or a `data-el` name,
    /// in document order, leaving out what the runtime and markup scaffold (`<helmet>`,
    /// `<style>`, `<sc-for>`, …) and an element that only repeats its parent's words. Each says
    /// what it is and holds (`DesignElementSummary`).
    public static func elements(of board: DesignReference, source: String, breadcrumb: [String], revision: UInt64? = nil) -> [DesignMentionItem] {
        guard let path = board.board, let template = DesignTemplate(board: source) else { return [] }
        let names = DesignStyleEdit.attributes("data-el", in: source)
        let roles = DesignStyleEdit.attributes("role", in: source)
        let styles = DesignStyleEdit.styles(in: source)
        let details = DesignElementSummary(template: template, names: names, roles: roles, styles: styles,
                                          loopLists: DesignStyleEdit.attributes("list", in: source),
                                          loopItems: DesignStyleEdit.attributes("as", in: source))
        var parents = Set<Int>()
        for element in template.elements { if let parent = element.parent { parents.insert(parent) } }
        let scaffold = DesignElementSummary.scaffold
        var inside = [Int](repeating: 0, count: template.elements.count)
        for element in template.elements.reversed() {
            if let parent = element.parent { inside[parent] += 1 + inside[element.tid] }
        }
        var out: [DesignMentionItem] = []
        for element in template.elements where !scaffold.contains(element.name) {
            let name = names[element.tid].flatMap { $0.contains("{{") || $0.isEmpty ? nil : $0 }
            let label = template.labels[element.tid]
            guard name != nil || label != nil else { continue }
            if name == nil, let parent = element.parent, template.labels[parent] == label { continue }
            guard let id = DesignElementID(board: path.viewName, tid: element.tid, path: element.path),
                  let reference = DesignReference(designID: board.designID, board: path, element: id) else { continue }
            out.append(DesignMentionItem(kind: .element, reference: reference,
                                         title: DesignReferenceReading.elementTitle(
                                             name: name ?? DesignReferenceReading.elementNoun(element, children: parents.contains(element.tid),
                                                                                              words: label != nil, style: styles[element.tid],
                                                                                              role: roles[element.tid]),
                                             label: label, tag: element.name),
                                         breadcrumb: breadcrumb, tag: element.name, inside: inside[element.tid],
                                         detail: details.detail(element.tid), revision: revision))
            if out.count >= maxElementsPerBoard { break }
        }
        return out
    }
}
