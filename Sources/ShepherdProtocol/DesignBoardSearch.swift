import Foundation

// `board_search` (docs/designs.md › Search): a design agent's grep over its boards, host-side
// and without WebKit. Text or a regular expression over a board's markup, its visible text or
// its labels; a structural query over the template tree (the element with this tag, attribute
// or class, with its element id, a short chain of what it sits in and a snippet); and the
// usages of a piece (which boards `<dc-import>` it). Bounded: a few matches per board, a few
// boards, and a "N more" tail.

public struct DesignSearchQuery: Hashable, Sendable, Codable {
    /// Where `text` is looked for.
    public enum Scope: String, Hashable, Sendable, Codable {
        /// The board's whole source (`.dc.html`), markup and script included.
        case markup
        /// The text between the template's tags: what the board says, holes as written.
        case text
        /// Names the markup gives elements: `aria-label`, `alt`, `title`, `placeholder`, `data-el`,
        /// and a `<dc-import>`'s `name`.
        case labels
    }

    public var text: String?
    /// `text` (and `value`) are regular expressions, not literal text.
    public var regex: Bool
    public var scope: Scope
    public var ignoreCase: Bool
    /// A tag name: `div`, `button`, `dc-import`.
    public var tag: String?
    /// An attribute the element carries, and optionally its value.
    public var attribute: String?
    public var value: String?
    /// A class the element carries.
    public var elementClass: String?
    /// A piece, by name (`Card`) or path (`Card.dc.html`): which boards import it.
    public var usages: String?
    /// Search only these boards.
    public var paths: [String]?
    /// Most boards listed (default 20).
    public var limit: Int?

    public init(text: String? = nil, regex: Bool = false, scope: Scope = .markup, ignoreCase: Bool = false, tag: String? = nil,
                attribute: String? = nil, value: String? = nil, elementClass: String? = nil, usages: String? = nil,
                paths: [String]? = nil, limit: Int? = nil) {
        self.text = text
        self.regex = regex
        self.scope = scope
        self.ignoreCase = ignoreCase
        self.tag = tag
        self.attribute = attribute
        self.value = value
        self.elementClass = elementClass
        self.usages = usages
        self.paths = paths
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case text, regex, scope, ignoreCase, tag, attribute, value, elementClass = "class", usages, paths, limit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        regex = try c.decodeIfPresent(Bool.self, forKey: .regex) ?? false
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .markup
        ignoreCase = try c.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? false
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        attribute = try c.decodeIfPresent(String.self, forKey: .attribute)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        elementClass = try c.decodeIfPresent(String.self, forKey: .elementClass)
        usages = try c.decodeIfPresent(String.self, forKey: .usages)
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(text, forKey: .text)
        if regex { try c.encode(true, forKey: .regex) }
        if scope != .markup { try c.encode(scope, forKey: .scope) }
        if ignoreCase { try c.encode(true, forKey: .ignoreCase) }
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encodeIfPresent(attribute, forKey: .attribute)
        try c.encodeIfPresent(value, forKey: .value)
        try c.encodeIfPresent(elementClass, forKey: .elementClass)
        try c.encodeIfPresent(usages, forKey: .usages)
        try c.encodeIfPresent(paths, forKey: .paths)
        try c.encodeIfPresent(limit, forKey: .limit)
    }

    /// Whether the query names an element (a tag, attribute or class).
    var isStructural: Bool { tag != nil || attribute != nil || elementClass != nil }
}

public struct DesignSearchMatch: Hashable, Sendable, Codable {
    /// The board's line (from 1), for text found in its source.
    public var line: Int?
    /// The element, `File.dc.html#<tid>:<path>`; nil outside the template or past the id grammar.
    public var element: String?
    public var tag: String?
    /// What it sits in, outermost first: `main`, `section[data-el=Steps]`.
    public var ancestors: [String]
    /// The line it is on, or its start tag, cut short.
    public var snippet: String

    public init(line: Int? = nil, element: String? = nil, tag: String? = nil, ancestors: [String] = [], snippet: String) {
        self.line = line
        self.element = element
        self.tag = tag
        self.ancestors = ancestors
        self.snippet = snippet
    }
}

public struct DesignSearchBoard: Hashable, Sendable, Codable {
    public var path: String
    /// Every match in the board; `matches` lists the first few.
    public var count: Int
    public var matches: [DesignSearchMatch]

    public init(path: String, count: Int, matches: [DesignSearchMatch]) {
        self.path = path
        self.count = count
        self.matches = matches
    }
}

public struct DesignSearchResult: Hashable, Sendable, Codable {
    public var boards: [DesignSearchBoard]
    public var totalMatches: Int
    /// Boards with a match, listed or not.
    public var totalBoards: Int
    /// Boards looked at.
    public var searched: Int
    /// Boards with a match that `boards` leaves out.
    public var omittedBoards: Int
    /// For a usages query: the piece, as a board path, and whether the design has it.
    public var piece: String?
    public var pieceExists: Bool?
    /// The search stopped at its time budget after `searched` boards.
    public var timedOut: Bool

    public init(boards: [DesignSearchBoard], totalMatches: Int, totalBoards: Int, searched: Int, omittedBoards: Int,
                piece: String? = nil, pieceExists: Bool? = nil, timedOut: Bool = false) {
        self.boards = boards
        self.totalMatches = totalMatches
        self.totalBoards = totalBoards
        self.searched = searched
        self.omittedBoards = omittedBoards
        self.piece = piece
        self.pieceExists = pieceExists
        self.timedOut = timedOut
    }
}

public enum DesignBoardSearch {
    public static let defaultLimit = 20
    public static let maxLimit = 100
    /// Matches listed per board.
    public static let perBoard = 5
    /// How long a search may run before it reports what it has.
    public static let budget: TimeInterval = 8

    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case empty
        case badPattern(String)
        case badPath(String)
        case badPiece(String)

        public var code: String { "invalid_search" }

        public var description: String {
            switch self {
            case .empty: return "board_search needs text, a tag, an attribute, a class, or usages (a piece's name)"
            case .badPattern(let why): return "the regular expression is not valid: \(why)"
            case .badPath(let path): return "\"\(path)\" is not a board path"
            case .badPiece(let name): return "\"\(name)\" names no piece: give a board's name (Card) or path (Card.dc.html)"
            }
        }
    }

    /// Checks a query before anything is read.
    public static func validate(_ query: DesignSearchQuery) throws(Failure) {
        let hasText = query.text.map { !$0.isEmpty } ?? false
        guard hasText || query.isStructural || (query.usages.map { !$0.isEmpty } ?? false) else { throw .empty }
        if query.regex {
            for pattern in [query.text, query.value].compactMap({ $0 }) where !pattern.isEmpty {
                do { _ = try NSRegularExpression(pattern: pattern, options: options(query)) } catch {
                    throw .badPattern((error as NSError).localizedDescription)
                }
            }
        }
    }

    private static func options(_ query: DesignSearchQuery) -> NSRegularExpression.Options {
        query.ignoreCase ? [.caseInsensitive] : []
    }

    /// The piece a usages query names, as a board path: `Card`, `Card.dc.html` or `parts/Card.dc.html`.
    public static func piece(named name: String) -> DesignPath? {
        let raw = name.hasSuffix(DesignPath.fileExtension) ? name : name + DesignPath.fileExtension
        return DesignPath(raw)
    }

    /// Runs `query` over `boards` (path and source, in the order to list them).
    public static func run(_ query: DesignSearchQuery, boards: [(path: DesignPath, source: String)],
                           known: Set<DesignPath>, now: () -> Date = Date.init) throws(Failure) -> DesignSearchResult {
        try validate(query)
        let started = now()
        let limit = min(max(query.limit ?? defaultLimit, 1), maxLimit)
        var listed: [DesignSearchBoard] = []
        var totalMatches = 0, totalBoards = 0, searched = 0
        var timedOut = false
        var pieceTarget: DesignPath?
        if let name = query.usages, !name.isEmpty {
            guard let found = piece(named: name) else { throw .badPiece(name) }
            pieceTarget = found
        }
        let matcher = try Matcher(query)
        for (path, source) in boards {
            if now().timeIntervalSince(started) > budget { timedOut = true; break }
            searched += 1
            let found = matcher.search(path: path, source: source, piece: pieceTarget, deadline: started.addingTimeInterval(budget), now: now)
            guard found.count > 0 else { continue }
            totalMatches += found.count
            totalBoards += 1
            if listed.count < limit {
                listed.append(DesignSearchBoard(path: path.rawValue, count: found.count, matches: Array(found.matches.prefix(perBoard))))
            }
        }
        return DesignSearchResult(boards: listed, totalMatches: totalMatches, totalBoards: totalBoards, searched: searched,
                                  omittedBoards: totalBoards - listed.count, piece: pieceTarget?.rawValue,
                                  pieceExists: pieceTarget.map { known.contains($0) }, timedOut: timedOut)
    }

    // MARK: Matching

    private struct Matcher {
        let query: DesignSearchQuery
        let textPattern: NSRegularExpression?
        let valuePattern: NSRegularExpression?

        init(_ query: DesignSearchQuery) throws(Failure) {
            self.query = query
            func compile(_ pattern: String?) throws(Failure) -> NSRegularExpression? {
                guard query.regex, let pattern, !pattern.isEmpty else { return nil }
                do { return try NSRegularExpression(pattern: pattern, options: DesignBoardSearch.options(query)) } catch {
                    throw .badPattern((error as NSError).localizedDescription)
                }
            }
            textPattern = try compile(query.text)
            valuePattern = try compile(query.value)
        }

        /// Whether `haystack` holds the query's text.
        func holds(_ haystack: String) -> Bool {
            guard let text = query.text, !text.isEmpty else { return true }
            return first(in: haystack, text, textPattern) != nil
        }

        /// The first place `needle` (or its pattern) is in `haystack`, as a UTF-16 range.
        func first(in haystack: String, _ needle: String, _ pattern: NSRegularExpression?) -> NSRange? {
            if let pattern {
                let range = pattern.rangeOfFirstMatch(in: haystack, range: NSRange(location: 0, length: (haystack as NSString).length))
                return range.location == NSNotFound ? nil : range
            }
            let range = (haystack as NSString).range(of: needle, options: query.ignoreCase ? [.caseInsensitive] : [])
            return range.location == NSNotFound ? nil : range
        }

        /// Every place the query's text is in `haystack`, as UTF-16 ranges, to the deadline.
        func all(in haystack: String, deadline: Date, now: () -> Date) -> [NSRange] {
            guard let text = query.text, !text.isEmpty else { return [] }
            let whole = NSRange(location: 0, length: (haystack as NSString).length)
            var found: [NSRange] = []
            if let pattern = textPattern {
                pattern.enumerateMatches(in: haystack, options: [.reportProgress], range: whole) { match, _, stop in
                    if now() > deadline { stop.pointee = true; return }
                    guard let match, match.range.length > 0 else { return }
                    found.append(match.range)
                    if found.count >= 10_000 { stop.pointee = true }
                }
                return found
            }
            var from = 0
            while from < whole.length, found.count < 10_000 {
                let range = (haystack as NSString).range(of: text, options: query.ignoreCase ? [.caseInsensitive] : [],
                                                         range: NSRange(location: from, length: whole.length - from))
                guard range.location != NSNotFound else { break }
                found.append(range)
                from = range.location + max(1, range.length)
            }
            return found
        }

        func valueMatches(_ value: String) -> Bool {
            guard let wanted = query.value else { return true }
            if let valuePattern {
                return valuePattern.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)) != nil
            }
            return query.ignoreCase ? value.lowercased() == wanted.lowercased() : value == wanted
        }

        func search(path: DesignPath, source: String, piece: DesignPath?, deadline: Date, now: () -> Date) -> (count: Int, matches: [DesignSearchMatch]) {
            guard let tree = DesignBoardTree(source: source) else {
                // No template: only the raw text can match.
                guard query.scope == .markup, !query.isStructural, query.usages == nil else { return (0, []) }
                return markup(path: path, source: source, tree: nil, deadline: deadline, now: now)
            }
            if let piece { return usages(of: piece, path: path, tree: tree) }
            if query.isStructural { return structural(path: path, tree: tree) }
            switch query.scope {
            case .markup: return markup(path: path, source: source, tree: tree, deadline: deadline, now: now)
            case .text: return texts(path: path, tree: tree, deadline: deadline, now: now)
            case .labels: return labels(path: path, tree: tree)
            }
        }

        // MARK: Kinds

        private func markup(path: DesignPath, source: String, tree: DesignBoardTree?, deadline: Date,
                            now: () -> Date) -> (count: Int, matches: [DesignSearchMatch]) {
            let ns = source as NSString
            let ranges = all(in: source, deadline: deadline, now: now)
            let lines = DesignTokenCheck.LineIndex(ns)
            var matches: [DesignSearchMatch] = []
            for range in ranges.prefix(DesignBoardSearch.perBoard) {
                let line = lines.line(range.location)
                var match = DesignSearchMatch(line: line, snippet: snippet(in: ns, range: range))
                if let tree, let tid = innermost(containing: utf8Offset(of: range.location, in: source), tree: tree) {
                    match = element(match, tid: tid, tree: tree, path: path)
                }
                matches.append(match)
            }
            return (ranges.count, matches)
        }

        private func texts(path: DesignPath, tree: DesignBoardTree, deadline: Date, now: () -> Date) -> (count: Int, matches: [DesignSearchMatch]) {
            var count = 0
            var matches: [DesignSearchMatch] = []
            for text in tree.texts {
                let words = String(decoding: tree.bytes[text.range], as: UTF8.self)
                let hits = all(in: words, deadline: deadline, now: now)
                guard !hits.isEmpty else { continue }
                count += hits.count
                if matches.count < DesignBoardSearch.perBoard {
                    var match = DesignSearchMatch(line: tree.line(at: text.range.lowerBound),
                                                  snippet: snippet(in: words as NSString, range: hits[0]))
                    if let tid = text.element { match = element(match, tid: tid, tree: tree, path: path) }
                    matches.append(match)
                }
            }
            return (count, matches)
        }

        private static let labelAttributes: Set<String> = ["aria-label", "alt", "title", "placeholder", "data-el"]

        private func labels(path: DesignPath, tree: DesignBoardTree) -> (count: Int, matches: [DesignSearchMatch]) {
            var count = 0
            var matches: [DesignSearchMatch] = []
            for element in tree.elements {
                for (name, value) in tree.attributes(of: element.tid) {
                    let isLabel = Self.labelAttributes.contains(name) || (element.name == "dc-import" && name == "name")
                    guard isLabel, holds(value) else { continue }
                    count += 1
                    if matches.count < DesignBoardSearch.perBoard {
                        var match = DesignSearchMatch(snippet: "\(name)=\"\(DesignBoardSearch.cut(value, 100))\"")
                        match = self.element(match, tid: element.tid, tree: tree, path: path)
                        matches.append(match)
                    }
                }
            }
            return (count, matches)
        }

        private func structural(path: DesignPath, tree: DesignBoardTree) -> (count: Int, matches: [DesignSearchMatch]) {
            var count = 0
            var matches: [DesignSearchMatch] = []
            let wantedTag = query.tag?.lowercased()
            let wantedAttribute = query.attribute?.lowercased()
            for element in tree.elements {
                if let wantedTag, element.name != wantedTag { continue }
                let attributes = (wantedAttribute != nil || query.elementClass != nil) ? tree.attributes(of: element.tid) : []
                if let wantedAttribute {
                    guard let found = attributes.first(where: { $0.name == wantedAttribute }), valueMatches(found.value) else { continue }
                } else if query.value != nil, query.elementClass == nil {
                    // A value without an attribute: any attribute holds it.
                    guard tree.attributes(of: element.tid).contains(where: { valueMatches($0.value) }) else { continue }
                }
                if let wanted = query.elementClass {
                    let classes = attributes.first { $0.name == "class" }?.value.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) ?? []
                    guard classes.contains(where: { query.ignoreCase ? $0.lowercased() == wanted.lowercased() : $0 == wanted }) else { continue }
                }
                if let words = query.text, !words.isEmpty {
                    guard let label = tree.template.labels[element.tid], holds(label) else { continue }
                }
                count += 1
                if matches.count < DesignBoardSearch.perBoard {
                    matches.append(self.element(DesignSearchMatch(snippet: ""), tid: element.tid, tree: tree, path: path))
                }
            }
            return (count, matches)
        }

        private func usages(of piece: DesignPath, path: DesignPath, tree: DesignBoardTree) -> (count: Int, matches: [DesignSearchMatch]) {
            var count = 0
            var matches: [DesignSearchMatch] = []
            for reference in DesignImports.references(in: tree, of: path) where reference.target == piece {
                count += 1
                if matches.count < DesignBoardSearch.perBoard {
                    matches.append(element(DesignSearchMatch(snippet: ""), tid: reference.tid, tree: tree, path: path))
                }
            }
            return (count, matches)
        }

        // MARK: Pieces of a match

        /// `match` with the element's id, tag, what it sits in, and (when it has no snippet yet)
        /// its start tag as the snippet.
        private func element(_ match: DesignSearchMatch, tid: Int, tree: DesignBoardTree, path: DesignPath) -> DesignSearchMatch {
            var out = match
            guard tree.elements.indices.contains(tid) else { return out }
            let element = tree.elements[tid]
            out.tag = element.name
            out.element = DesignElementID(board: path, element: element)?.description
            out.ancestors = tree.ancestors(of: tid).prefix(3).reversed().map { ancestor in
                let name = tree.attribute("data-el", of: ancestor.tid)
                return name.map { "\(ancestor.name)[data-el=\(DesignBoardSearch.cut($0, 30))]" } ?? ancestor.name
            }
            if out.snippet.isEmpty {
                var shown = tree.startTag(of: tid).map { DesignBoardSearch.cut($0, 140) } ?? "<\(element.name)>"
                if let label = tree.template.labels[tid], !label.isEmpty { shown += " “\(DesignBoardSearch.cut(label, 40))”" }
                out.snippet = shown
            }
            if out.line == nil, let range = element.tagRange { out.line = tree.line(at: range.lowerBound) }
            return out
        }

        /// The innermost element whose source holds the byte offset.
        private func innermost(containing offset: Int, tree: DesignBoardTree) -> Int? {
            var best: Int?
            for element in tree.elements {
                guard let start = element.tagRange?.lowerBound, start <= offset else { continue }
                if let range = tree.range(of: element.tid), range.contains(offset) { best = element.tid }
            }
            return best
        }

        /// The UTF-8 offset of a UTF-16 offset.
        private func utf8Offset(of utf16: Int, in text: String) -> Int {
            let index = String.Index(utf16Offset: utf16, in: text)
            return text.utf8.distance(from: text.utf8.startIndex, to: index)
        }

        /// The line around a match, trimmed and cut so the match is in it.
        private func snippet(in text: NSString, range: NSRange) -> String {
            let lineRange = text.lineRange(for: range)
            var line = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.count > 140 {
                let before = text.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
                let lead = before.count - before.drop(while: { $0 == " " || $0 == "\t" }).count
                let into = max(0, before.count - lead - 30)
                let trimmed = Array(line)
                let start = min(into, max(0, trimmed.count - 140))
                line = (start > 0 ? "…" : "") + String(trimmed[start..<min(trimmed.count, start + 140)]) + (start + 140 < trimmed.count ? "…" : "")
            }
            return line
        }
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
