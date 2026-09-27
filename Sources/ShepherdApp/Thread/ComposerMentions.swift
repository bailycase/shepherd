import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The composer's design references (DesignRefStates › In the composer, RefPasted, RefAtDesigns,
// RefAtElements, RefAtSearch): the @ picker's rules and a pasted reference becoming a chip. Pure
// values and rules here; the composer draws them and the view model pins and attaches.

/// The @ mention being typed at the end of a draft: an "@" at the start or after whitespace, and
/// what follows it on the same line.
struct ComposerMention: Equatable {
    /// The draft before the "@".
    var before: String
    /// What follows the "@".
    var text: String

    /// A mention runs at most this long; past it the draft is prose.
    static let maxLength = 160

    /// The mention the draft ends in, or nil: an "@" that starts the draft or follows whitespace,
    /// with no line break after it (an address like a@b.c is no mention).
    static func token(in draft: String) -> ComposerMention? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let text = draft[draft.index(after: at)...]
        guard !text.contains(where: \.isNewline), text.count <= maxLength, !text.hasPrefix(" ") else { return nil }
        return ComposerMention(before: String(draft[..<at]), text: String(text))
    }

    /// The draft with the mention written as `text` ("@Checkout funnel dashboard › ").
    func draft(with text: String) -> String { before + "@" + text }
}

/// Where the @ picker is: the designs, inside a design (its boards), or inside a board (its
/// elements), with the titles of the way in.
enum MentionScope: Equatable {
    case designs
    case design(DesignID, name: String)
    case board(DesignReference, design: String, board: String)

    /// The breadcrumb over the list, and what the draft spells before the filter.
    var crumbs: [String] {
        switch self {
        case .designs: []
        case .design(_, let name): [name]
        case .board(_, let design, let board): [design, board]
        }
    }

    var catalogScope: DesignMentionCatalog.Scope {
        switch self {
        case .designs: .designs
        case .design(let id, _): .design(id)
        case .board(let reference, _, _): .board(reference)
        }
    }

    /// One level up.
    var parent: MentionScope {
        switch self {
        case .designs, .design: .designs
        case .board(let reference, let design, _): .design(reference.designID, name: design)
        }
    }

    /// The mention's words for this scope: "Checkout funnel dashboard › A · Funnel first › ".
    var spelled: String {
        crumbs.isEmpty ? "" : crumbs.joined(separator: Self.separator) + Self.separator
    }

    static let separator = " › "

    /// The scope a mention's words spell ("Checkout funnel dashboard › A · Funnel first › …"):
    /// a design, then one of its boards, named by their titles in `catalog`; the designs when they
    /// name none.
    static func spelled(by text: String, in catalog: DesignMentionCatalog) -> MentionScope {
        let parts = text.components(separatedBy: separator)
        guard parts.count >= 2, let design = catalog.designs.first(where: { $0.title == parts[0] }) else { return .designs }
        let scope = MentionScope.design(design.reference.designID, name: design.title)
        guard parts.count >= 3,
              let board = catalog.boards[design.reference.designID]?.first(where: { $0.title == parts[1] }) else { return scope }
        return .board(board.reference, design: design.title, board: board.title)
    }

    /// What the list is filtered by, from the mention's words: what follows the scope's
    /// breadcrumb, or nil when the words no longer spell it (the scope is left).
    func filter(in text: String) -> String? {
        let spelled = spelled
        guard !spelled.isEmpty else { return text }
        guard text.hasPrefix(spelled) else { return nil }
        return String(text.dropFirst(spelled.count))
    }
}

/// What the picker draws for a scope and a filter (MentionPicker's stages): sections of rows, the
/// breadcrumb inside a design or board, and what it says with nothing to list.
struct MentionPickerContent: Equatable {
    var sections: [NWMentionSection] = []
    var crumbs: [String]?
    var empty: NWMentionEmpty?
    /// The catalog's item behind each row, by row id.
    var items: [String: DesignMentionItem] = [:]

    var rows: [NWMentionRow] { sections.flatMap(\.rows) }

    static let searched = "Searches this Mac’s designs, boards and elements."
    /// A whole design's or board's row: its item is the design's (or board's) own, under this id.
    static func wholeID(_ item: DesignMentionItem) -> String { "whole:" + item.id }

    /// The rows for `scope` and `filter` from `catalog`, most recently active designs first.
    /// `thumbnail` gives a row's picture, when one is at hand.
    static func make(catalog: DesignMentionCatalog, scope: MentionScope, filter: String, now: Date = Date(),
                     thumbnail: (DesignMentionItem) -> NWReferenceImage? = { _ in nil }) -> MentionPickerContent {
        var content = MentionPickerContent()
        let words = filter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        func add(_ item: DesignMentionItem, row: NWMentionRow) -> NWMentionRow {
            content.items[row.id] = item
            return row
        }
        switch scope {
        case .designs where words.isEmpty:
            guard !catalog.designs.isEmpty else {
                content.empty = .noDesigns
                return content
            }
            let rows = catalog.designs.map { item in
                add(item, row: NWMentionRow(id: item.id, kind: .design, title: item.title, subtitle: designLine(item, now: now),
                                            lead: item.system, trailing: .drill, thumbnail: thumbnail(item)))
            }
            content.sections = [NWMentionSection(id: "designs", title: "Designs", trailing: "\(catalog.designs.count) on this Mac", rows: rows)]
        case .designs:
            // What the search found, where the piece's own name holds a word of it (its path is
            // there to place it, as the boards show).
            let found = catalog.search(filter).filter { item in
                let title = item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return words.contains { title.contains($0) }
            }
            guard !found.isEmpty else {
                content.empty = .nothingMatches(query: filter, searched: searched)
                return content
            }
            let rows = found.map { item in
                add(item, row: searchRow(item, words: words, thumbnail: thumbnail(item)))
            }
            content.sections = [NWMentionSection(id: "matches", title: "Designs, boards and elements",
                                                 trailing: rows.count == 1 ? "1 match" : "\(rows.count) matches", rows: rows)]
        case .design, .board:
            let all = catalog.rows(in: scope.catalogScope)
            guard let own = all.first else {
                content.empty = .nothingMatches(query: filter, searched: searched)
                content.crumbs = scope.crumbs
                return content
            }
            content.crumbs = scope.crumbs
            let whole = own.kind == .design
                ? NWMentionRow(id: wholeID(own), kind: .design, title: "Whole design", subtitle: boardsText(own.boardCount ?? 0),
                               trailing: .pick, thumbnail: thumbnail(own))
                : NWMentionRow(id: wholeID(own), kind: .board, title: "Whole board", subtitle: boardLine(own),
                               trailing: .pick, thumbnail: thumbnail(own))
            let inside = all.dropFirst().filter { words.isEmpty || matches($0.title, words) }
            let rows = inside.map { item in
                item.kind == .board
                    ? add(item, row: NWMentionRow(id: item.id, kind: .board, title: item.title, subtitle: boardLine(item), trailing: .drill,
                                                  thumbnail: thumbnail(item), matched: words))
                    : add(item, row: NWMentionRow(id: item.id, kind: .element, title: item.title, subtitle: elementLine(item),
                                                  trailing: .pick, thumbnail: thumbnail(item), matched: words))
            }
            var sections: [NWMentionSection] = []
            if words.isEmpty { sections.append(NWMentionSection(id: "whole", title: "", rows: [add(own, row: whole)])) }
            let title = own.kind == .design ? "Boards" : "Elements"
            if !rows.isEmpty {
                sections.append(NWMentionSection(id: title.lowercased(), title: title, trailing: "\(rows.count)", rows: rows))
            } else if !words.isEmpty {
                content.empty = .nothingMatches(query: filter, searched: searched)
            }
            content.sections = sections
        }
        return content
    }

    /// A search result: its path before it, and what it is under it.
    static func searchRow(_ item: DesignMentionItem, words: [String], thumbnail: NWReferenceImage?) -> NWMentionRow {
        switch item.kind {
        case .design:
            NWMentionRow(id: item.id, kind: .design, title: item.title, subtitle: boardsText(item.boardCount ?? 0), lead: item.system,
                         trailing: .drill, thumbnail: thumbnail, matched: words)
        case .board:
            NWMentionRow(id: item.id, kind: .board, title: item.title, crumbs: item.breadcrumb,
                         subtitle: ["board", size(item)].compactMap { $0 }.joined(separator: " · "), trailing: .drill,
                         thumbnail: thumbnail, matched: words)
        case .element:
            NWMentionRow(id: item.id, kind: .element, title: item.title, crumbs: item.breadcrumb, subtitle: "element", trailing: .pick,
                         thumbnail: thumbnail, matched: words)
        }
    }

    /// "4 boards · edited 2h ago", "3 boards · yesterday", "9 boards · 3d ago".
    static func designLine(_ item: DesignMentionItem, now: Date) -> String {
        var parts = [boardsText(item.boardCount ?? 0)]
        if let active = item.activeAt, active > 0 { parts.append(activeText(active, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// When a design was last edited, as the picker says it.
    static func activeText(_ milliseconds: Double, now: Date) -> String {
        let seconds = now.timeIntervalSince1970 - milliseconds / 1000
        let when = SuggestionsPresentation.when(milliseconds / 1000, now: now)
        if seconds < 86_400 { return "edited " + when }
        if when == "yesterday" { return when }
        let days = Int(seconds / 86_400)
        return days < 30 ? "\(days)d ago" : "edited " + when
    }

    /// "1280 × 800 · 14 elements".
    static func boardLine(_ item: DesignMentionItem) -> String {
        [size(item), item.elementCount.map { $0 == 1 ? "1 element" : "\($0) elements" }].compactMap { $0 }.joined(separator: " · ")
    }

    /// "div · 12 inside".
    static func elementLine(_ item: DesignMentionItem) -> String {
        [item.tag, item.inside.flatMap { $0 > 0 ? "\($0) inside" : nil }].compactMap { $0 }.joined(separator: " · ")
    }

    static func size(_ item: DesignMentionItem) -> String? {
        guard let width = item.width, let height = item.height else { return nil }
        return "\(Int(width)) × \(Int(height))"
    }

    static func boardsText(_ count: Int) -> String { count == 1 ? "1 board" : "\(count) boards" }

    static func matches(_ title: String, _ words: [String]) -> Bool {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words.allSatisfy(folded.contains)
    }
}

/// The picker's state in a composer: where it is, which row is highlighted, what it lists, and
/// the draft Esc closed it for. Derived once per change of the draft or the catalog, never while
/// drawing.
struct MentionPickerState: Equatable {
    var scope: MentionScope = .designs
    var highlighted: String?
    /// Esc closed the picker for this draft; typing more opens it again.
    var dismissed: String?
    var content = MentionPickerContent()
    /// The mention it lists for, while open.
    var mention: ComposerMention?

    var isOpen: Bool { mention != nil }

    /// Follows the draft: open while it ends in a mention (and Esc hasn't closed it), in the scope
    /// the mention still spells, listing `catalog`'s rows for it.
    mutating func update(draft: String, catalog: DesignMentionCatalog?, now: Date = Date(),
                         thumbnail: (DesignMentionItem) -> NWReferenceImage? = { _ in nil }) {
        guard draft != dismissed, let mention = ComposerMention.token(in: draft) else {
            close()
            return
        }
        if dismissed != nil { dismissed = nil }
        var filter = scope.filter(in: mention.text)
        if let catalog, filter == nil || scope == .designs || filter?.contains(MentionScope.separator) == true {
            // The words may spell a design or a board (typed, pasted, a draft kept, or Back).
            let spelled = MentionScope.spelled(by: mention.text, in: catalog)
            if spelled != .designs || filter == nil {
                scope = spelled
                filter = spelled.filter(in: mention.text)
            }
        }
        if filter == nil {
            scope = .designs
            filter = mention.text
        }
        self.mention = mention
        guard let catalog else {
            content = MentionPickerContent()
            return
        }
        content = MentionPickerContent.make(catalog: catalog, scope: scope, filter: filter ?? "", now: now, thumbnail: thumbnail)
        let ids = content.rows.map(\.id)
        if highlighted.map({ !ids.contains($0) }) ?? true { highlighted = ids.first }
    }

    mutating func close() {
        mention = nil
        scope = .designs
        highlighted = nil
        content = MentionPickerContent()
    }

    /// ↑ and ↓ move the highlight, stopping at the ends.
    mutating func move(_ step: Int) {
        let ids = content.rows.map(\.id)
        guard !ids.isEmpty else { return }
        let index = highlighted.flatMap(ids.firstIndex(of:)) ?? -step
        highlighted = ids[min(max(0, index + step), ids.count - 1)]
    }

    var highlightedRow: NWMentionRow? { content.rows.first { $0.id == highlighted } }

    /// What a row does: drill into a design or a board (the draft spells the way in), or pick it.
    enum Choice: Equatable {
        case drill(draft: String)
        case pick(DesignReference, draft: String)
    }

    /// `row` chosen: a design or board row drills in, writing its path into the draft; anything
    /// else picks its piece and takes the mention out of the draft.
    mutating func choose(_ row: NWMentionRow) -> Choice? {
        guard let mention, let item = content.items[row.id] else { return nil }
        if row.trailing == .drill {
            switch item.kind {
            case .design:
                scope = .design(item.reference.designID, name: item.title)
            case .board:
                scope = .board(item.reference, design: item.breadcrumb.first ?? "", board: item.title)
            case .element:
                return pickChoice(item, mention: mention)
            }
            highlighted = nil
            return .drill(draft: mention.draft(with: scope.spelled))
        }
        return pickChoice(item, mention: mention)
    }

    private mutating func pickChoice(_ item: DesignMentionItem, mention: ComposerMention) -> Choice {
        let draft = mention.before
        close()
        return .pick(item.reference.unpinned, draft: draft)
    }

    /// Back a level (the breadcrumb's Back, ←, or ⌫ with nothing typed after it): the draft spells
    /// the parent scope. Nil at the designs.
    mutating func back() -> String? {
        guard let mention, scope != .designs else { return nil }
        scope = scope.parent
        highlighted = nil
        return mention.draft(with: scope.spelled)
    }

    /// Whether nothing is typed after the scope's breadcrumb.
    var filterIsEmpty: Bool {
        guard let mention else { return true }
        return (scope.filter(in: mention.text) ?? mention.text).isEmpty
    }
}

/// A reference pasted into the draft becomes a chip (RefPasted): "A copied reference pastes as a
/// chip, never as a link. Plain text pastes as text."
enum ComposerReferencePaste {
    /// The references a paste brought into `draft` (text that grew by more than a keystroke from
    /// `previous`), each a whole word, and the draft without them. Nil when it brought none.
    static func extract(_ draft: String, previous: String) -> (draft: String, references: [DesignReference])? {
        guard draft.count > previous.count + 1, draft.localizedCaseInsensitiveContains(DesignReference.scheme + "://") else { return nil }
        let known = Set(tokens(previous).compactMap { DesignReference(string: $0)?.string })
        var references: [DesignReference] = []
        var kept: [Substring] = []
        var cleaned = ""
        // Split on whitespace but keep the draft's own spacing around what stays.
        var index = draft.startIndex
        while index < draft.endIndex {
            if draft[index].isWhitespace {
                cleaned.append(draft[index])
                index = draft.index(after: index)
                continue
            }
            let end = draft[index...].firstIndex(where: \.isWhitespace) ?? draft.endIndex
            let word = draft[index..<end]
            if let reference = DesignReference(string: String(word)), !known.contains(reference.string) {
                references.append(reference)
            } else {
                kept.append(word)
                cleaned += word
            }
            index = end
        }
        guard !references.isEmpty else { return nil }
        return (tidy(cleaned), references)
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Runs of spaces the chips left collapse to one, and the ends lose theirs.
    static func tidy(_ text: String) -> String {
        var out = ""
        var lastSpace = false
        for character in text {
            if character == " " {
                if lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
