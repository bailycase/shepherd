import Foundation
import ShepherdCore

// `board_extract` (docs/designs.md › Shared pieces): one element of a board becomes a piece, a
// board of its own, and a `<dc-import>` takes its place, so it is drawn once and every board that
// imports it follows. The same extraction can replace exact copies of the element in other
// boards. Pure over the boards' text: the store reads the boards, runs this, and writes the
// piece, the boards it changed and the piece's canvas frame as one revision.

public struct DesignExtractRequest: Hashable, Sendable, Codable {
    /// Text in the element that becomes a prop the importer passes.
    public struct Prop: Hashable, Sendable, Codable {
        public var name: String
        public var text: String

        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    /// A canvas frame for the piece. Missing numbers take defaults: the piece's size, x of 0, and
    /// y below the lowest board.
    public struct Frame: Hashable, Sendable, Codable {
        public var x: Double?
        public var y: Double?
        public var w: Double?
        public var h: Double?
        public var title: String?
        public var page: String?

        public init(x: Double? = nil, y: Double? = nil, w: Double? = nil, h: Double? = nil, title: String? = nil, page: String? = nil) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
            self.title = title
            self.page = page
        }
    }

    /// The board that holds the element.
    public var path: String
    /// The element's id: `4`, `4:0/1` or `A.dc.html#4:0/1`.
    public var element: String
    /// The new board: `Card` or `Card.dc.html`, beside the source board.
    public var piece: String
    public var props: [Prop]
    /// The piece's `$preview`, when its root has no fixed px width and height.
    public var size: DesignBoardCheck.Size?
    public var frame: Frame?
    /// Boards in which to replace exact copies of the element.
    public var copies: [String]
    /// Every other board.
    public var allCopies: Bool
    public var checkpoint: String?
    public var baseRevision: UInt64?

    public init(path: String, element: String, piece: String, props: [Prop] = [], size: DesignBoardCheck.Size? = nil, frame: Frame? = nil,
                copies: [String] = [], allCopies: Bool = false, checkpoint: String? = nil, baseRevision: UInt64? = nil) {
        self.path = path
        self.element = element
        self.piece = piece
        self.props = props
        self.size = size
        self.frame = frame
        self.copies = copies
        self.allCopies = allCopies
        self.checkpoint = checkpoint
        self.baseRevision = baseRevision
    }

    private enum CodingKeys: String, CodingKey { case path, element, piece, props, size, frame, copies, allCopies, checkpoint, baseRevision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        element = try c.decode(String.self, forKey: .element)
        piece = try c.decode(String.self, forKey: .piece)
        props = try c.decodeIfPresent([Prop].self, forKey: .props) ?? []
        size = try c.decodeIfPresent(DesignBoardCheck.Size.self, forKey: .size)
        frame = try c.decodeIfPresent(Frame.self, forKey: .frame)
        copies = try c.decodeIfPresent([String].self, forKey: .copies) ?? []
        allCopies = try c.decodeIfPresent(Bool.self, forKey: .allCopies) ?? false
        checkpoint = try c.decodeIfPresent(String.self, forKey: .checkpoint)
        baseRevision = try c.decodeIfPresent(UInt64.self, forKey: .baseRevision)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(element, forKey: .element)
        try c.encode(piece, forKey: .piece)
        if !props.isEmpty { try c.encode(props, forKey: .props) }
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(frame, forKey: .frame)
        if !copies.isEmpty { try c.encode(copies, forKey: .copies) }
        if allCopies { try c.encode(true, forKey: .allCopies) }
        try c.encodeIfPresent(checkpoint, forKey: .checkpoint)
        try c.encodeIfPresent(baseRevision, forKey: .baseRevision)
    }
}

public struct DesignExtractResult: Hashable, Sendable, Codable {
    public struct Replaced: Hashable, Sendable, Codable {
        public var path: String
        /// How many copies of the element became imports.
        public var count: Int
        public var report: DesignBoardReport?

        public init(path: String, count: Int, report: DesignBoardReport? = nil) {
            self.path = path
            self.count = count
            self.report = report
        }
    }

    public struct Skipped: Hashable, Sendable, Codable {
        public var path: String
        public var why: String

        public init(path: String, why: String) {
            self.path = path
            self.why = why
        }
    }

    public var result: DesignWriteResult
    /// The piece's board path.
    public var piece: String
    /// The `<dc-import>` that took the element's place.
    public var importTag: String
    /// The other boards whose copies were replaced.
    public var boards: [Replaced]
    public var skipped: [Skipped]
    public var warnings: [String]
    public var pieceReport: DesignBoardReport?
    public var sourceReport: DesignBoardReport?
    public var checkpoint: DesignCheckpointInfo?
    public var pruned: [String]

    public init(result: DesignWriteResult, piece: String, importTag: String, boards: [Replaced] = [], skipped: [Skipped] = [],
                warnings: [String] = [], pieceReport: DesignBoardReport? = nil, sourceReport: DesignBoardReport? = nil,
                checkpoint: DesignCheckpointInfo? = nil, pruned: [String] = []) {
        self.result = result
        self.piece = piece
        self.importTag = importTag
        self.boards = boards
        self.skipped = skipped
        self.warnings = warnings
        self.pieceReport = pieceReport
        self.sourceReport = sourceReport
        self.checkpoint = checkpoint
        self.pruned = pruned
    }
}

public enum DesignExtraction {
    public struct Failure: Error, Hashable, Sendable, CustomStringConvertible {
        public var message: String
        public var code: String { "invalid_extract" }
        public var description: String { message }

        init(_ message: String) { self.message = message }
    }

    /// What an extraction changes.
    public struct Plan: Hashable, Sendable {
        public var piece: DesignPath
        public var pieceSource: String
        /// The text of every board the extraction changes: the source board and the boards whose
        /// copies were replaced.
        public var sources: [DesignPath: String]
        /// The import that took the element's place in the source board.
        public var importTag: String
        /// How many copies became imports, by board (the source board's own element not counted).
        public var replaced: [DesignPath: Int]
        public var skipped: [DesignExtractResult.Skipped]
        public var warnings: [String]
        /// The piece's `$preview`.
        public var size: DesignBoardCheck.Size
    }

    static let reservedProps: Set<String> = ["name", "key", "ref", "children", "class", "style", "id", "hint"]

    /// The piece's path: `Card` or `Card.dc.html` beside the board, or the full path when it names
    /// the board's own folder.
    public static func piecePath(_ raw: String, beside board: DesignPath) throws(Failure) -> DesignPath {
        let folder = folder(of: board)
        guard !raw.hasSuffix(".html") || raw.hasSuffix(DesignPath.fileExtension) else {
            throw Failure("name the piece Card or Card.dc.html: a board's file ends in .dc.html")
        }
        let name = raw.hasSuffix(DesignPath.fileExtension) ? raw : raw + DesignPath.fileExtension
        let full = name.contains("/") ? name : (folder.isEmpty ? name : folder + "/" + name)
        guard let path = DesignPath(full) else {
            throw Failure("\"\(raw)\" can't name a board: letters, digits, _ . - only, ending in .dc.html")
        }
        guard Self.folder(of: path) == folder else {
            throw Failure("the piece goes beside \(board) (\(folder.isEmpty ? "the project's top level" : folder + "/")): a board imports only pieces in its own folder or below it")
        }
        return path
    }

    static func folder(of path: DesignPath) -> String {
        path.rawValue.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
    }

    /// `name` for a `<dc-import>` in `board` that mounts `piece`: the piece's path from the board's
    /// folder. Nil when the piece is not in that folder or below it (the runtime refuses `..`).
    public static func importName(of piece: DesignPath, in board: DesignPath) -> String? {
        let from = folder(of: board)
        let raw = String(piece.rawValue.dropLast(DesignPath.fileExtension.count))
        if from.isEmpty { return raw }
        guard raw.hasPrefix(from + "/") else { return nil }
        return String(raw.dropFirst(from.count + 1))
    }

    /// `itemCount` as an attribute: `item-count`.
    static func attributeName(_ prop: String) -> String {
        var out = ""
        for character in prop {
            if character.isUppercase { out += "-" + character.lowercased() } else { out.append(character) }
        }
        return out
    }

    /// What makes two copies the same: whitespace runs as one space, trimmed, and the indentation
    /// between two tags (a run with a line break in it) gone. A single space between inline tags is
    /// kept: it is on the page.
    static func normalized(_ markup: String) -> String {
        let flat = markup.replacingOccurrences(of: #">\s*\n\s*<"#, with: "><", options: .regularExpression)
        return flat.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func parseElement(_ raw: String) -> (tid: Int, path: [Int]?)? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let hash = text.lastIndex(of: "#") { text = String(text[text.index(after: hash)...]) }
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, first.utf8.count <= 4, let tid = Int(first), tid >= 0 else { return nil }
        guard parts.count == 2 else { return (tid, nil) }
        var path: [Int] = []
        for part in parts[1].split(separator: "/", omittingEmptySubsequences: false) {
            guard let index = Int(part), index >= 0 else { return nil }
            path.append(index)
        }
        return (tid, path)
    }

    /// The attribute value for text as written in the board: a `"` can't end it.
    private static func attributeValue(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func isHole(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("{{") && trimmed.hasSuffix("}}")
    }

    /// A JavaScript string literal for `text`: its decoded characters (a board's text is decoded where it is read).
    private static func literal(_ text: String) -> String {
        let decoded = HTMLEntities.decode(text)
        let data = (try? JSONEncoder().encode([decoded])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    /// Plans the extraction of `request.element` from `board` into `piece`, with the boards in `sources`
    /// (the source board, and the boards whose copies are looked for).
    public static func plan(_ request: DesignExtractRequest, board: DesignPath, piece: DesignPath,
                            sources: [DesignPath: String]) throws(Failure) -> Plan {
        guard let source = sources[board], let tree = DesignBoardTree(source: source) else {
            throw Failure("\(board) has no <x-dc> template to take an element from")
        }
        if let imbalance = tree.imbalance {
            throw Failure("\(board)'s tags don't balance, so an element's extent can't be told: \(imbalance). Fix that first.")
        }
        guard let id = parseElement(request.element) else {
            throw Failure("\"\(request.element)\" is not an element id: use 4, 4:0/1 or \(board)#4:0/1")
        }
        guard tree.elements.indices.contains(id.tid) else { throw Failure("\(board) has no element \(id.tid)") }
        let element = tree.elements[id.tid]
        if let path = id.path, path != element.path {
            throw Failure("element \(id.tid) of \(board) is at \(element.path.map(String.init).joined(separator: "/")), not \(path.map(String.init).joined(separator: "/")): the board changed; read it again")
        }
        if element.name == "helmet" { throw Failure("a board's <helmet> is not a piece") }
        guard element.parent != nil else { throw Failure("element \(id.tid) is the board's root: extract an element inside it") }
        guard let markup = tree.markup(of: id.tid), let range = tree.range(of: id.tid) else {
            throw Failure("element \(id.tid) (<\(element.name)>) has no extent in the source: HTML implied it")
        }

        // Props: text in the element that the importer passes.
        var seen = Set<String>()
        var replacements: [(range: Range<String.Index>, name: String, text: String)] = []
        for prop in request.props {
            let name = prop.name
            guard name.range(of: #"^[a-z][A-Za-z0-9]{0,30}$"#, options: .regularExpression) != nil, !reservedProps.contains(name),
                  !attributeName(name).hasPrefix("hint-") else {
                throw Failure("\"\(name)\" can't be a prop name: camelCase letters and digits (label, itemCount), never \(reservedProps.sorted().joined(separator: ", "))")
            }
            guard seen.insert(name).inserted else { throw Failure("the prop \(name) is named twice") }
            guard !prop.text.isEmpty, prop.text.count <= 500 else { throw Failure("the prop \(name)'s text is 1 to 500 characters") }
            var found: [Range<String.Index>] = []
            var from = markup.startIndex
            while let at = markup.range(of: prop.text, range: from..<markup.endIndex) {
                found.append(at)
                from = at.upperBound
            }
            guard found.count == 1, let one = found.first else {
                throw Failure(found.isEmpty
                    ? "the prop \(name)'s text \"\(cut(prop.text))\" is not in the element: copy it exactly, entities as written"
                    : "the prop \(name)'s text \"\(cut(prop.text))\" is in the element \(found.count) times: use more of the text around the one you mean")
            }
            replacements.append((one, name, prop.text))
        }
        replacements.sort { $0.range.lowerBound < $1.range.lowerBound }
        for pair in zip(replacements, replacements.dropFirst()) where pair.0.range.upperBound > pair.1.range.lowerBound {
            throw Failure("the props \(pair.0.name) and \(pair.1.name) overlap in the element's text")
        }
        var pieceMarkup = markup
        for replacement in replacements.reversed() {
            pieceMarkup.replaceSubrange(replacement.range, with: "{{ \(replacement.name) }}")
        }

        // The piece's size: the element's own, else the request's.
        let size: DesignBoardCheck.Size
        if let style = tree.attribute("style", of: id.tid), let own = DesignBoardCheck.inlineSize(style) {
            size = own
        } else if let given = request.size, given.width >= 40, given.height >= 40 {
            size = given
        } else {
            throw Failure("the element has no fixed px width and height of its own, so the piece has no size: pass size {width, height}")
        }
        if request.size != nil, let style = tree.attribute("style", of: id.tid), let own = DesignBoardCheck.inlineSize(style), own != request.size {
            throw Failure("the element is \(own) but size says \(request.size!): a piece's root and its $preview are the same size")
        }

        // The import that takes its place.
        guard let name = importName(of: piece, in: board) else {
            throw Failure("\(piece) is not beside or below \(board)")
        }
        var attributes = ["name=\"\(name)\""]
        attributes.append("hint-size=\"\(number(size.width))px,\(number(size.height))px\"")
        for replacement in replacements {
            attributes.append("\(attributeName(replacement.name))=\"\(isHole(replacement.text) ? replacement.text.trimmingCharacters(in: .whitespaces) : attributeValue(replacement.text))\"")
        }
        let importTag = "<dc-import \(attributes.joined(separator: " "))></dc-import>"

        // The piece's board.
        let helmets = tree.elements.filter { $0.parent == nil && $0.name == "helmet" }.compactMap { tree.markup(of: $0.tid) }
        let pieceSource = assemble(stem: piece.stem, source: source, helmets: helmets, markup: pieceMarkup, size: size,
                                   props: replacements.map { ($0.name, isHole($0.text) ? "" : $0.text) })

        // Warnings: holes the piece still reads from the old board.
        let own = Set(replacements.map(\.name))
        var strays: [String] = []
        let holes = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]*?)\s*\}\}"#)
        let ns = pieceMarkup as NSString
        for match in holes.matches(in: pieceMarkup, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: match.range(at: 1))
            if !own.contains(inner), !strays.contains(inner) { strays.append(inner) }
        }
        var warnings: [String] = []
        if !strays.isEmpty {
            let shown = strays.prefix(6).map { "{{ \($0) }}" }.joined(separator: ", ")
            warnings.append("the piece still reads \(shown) from its old board, where it drew from that board's logic; they draw empty in the piece. Pass them as props (text: \"{{ … }}\"), or move that logic into the piece's script")
        }

        // The source board, and exact copies elsewhere.
        var changed: [DesignPath: String] = [:]
        var replaced: [DesignPath: Int] = [:]
        var skipped: [DesignExtractResult.Skipped] = []
        let target = normalized(markup)
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            var edits: [(range: Range<Int>, tag: String)] = []
            var copyTree: DesignBoardTree?
            if path == board {
                edits.append((range, importTag))
                copyTree = tree
            } else {
                copyTree = DesignBoardTree(source: text)
                if copyTree == nil { skipped.append(.init(path: path.rawValue, why: "it has no <x-dc> template")); continue }
                if let imbalance = copyTree?.imbalance {
                    skipped.append(.init(path: path.rawValue, why: "its tags don't balance (\(imbalance)), so its elements' extent can't be told"))
                    continue
                }
            }
            guard let other = copyTree else { continue }
            guard let relative = importName(of: piece, in: path) else {
                if path != board {
                    skipped.append(.init(path: path.rawValue, why: "it is in a folder the piece is not in or below: an import never climbs out of its folder"))
                    continue
                }
                continue
            }
            let tag = path == board ? importTag : tagFor(name: relative, original: importTag, board: board, piece: piece)
            var last: Range<Int>?
            for candidate in other.elements where candidate.name == element.name && candidate.parent != nil {
                guard let candidateRange = other.range(of: candidate.tid) else { continue }
                if path == board, candidateRange == range { continue }
                if let last, candidateRange.lowerBound < last.upperBound { continue }
                if let held = edits.first(where: { $0.range.overlaps(candidateRange) }), held.range != candidateRange { continue }
                guard normalized(other.markup(of: candidate.tid) ?? "") == target else { continue }
                edits.append((candidateRange, tag))
                last = candidateRange
            }
            let copies = path == board ? edits.count - 1 : edits.count
            guard !edits.isEmpty else { continue }
            var bytes = Array(text.utf8)
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                bytes.replaceSubrange(edit.range, with: Array(edit.tag.utf8))
            }
            changed[path] = String(decoding: bytes, as: UTF8.self)
            if copies > 0 { replaced[path] = copies }
        }
        return Plan(piece: piece, pieceSource: pieceSource, sources: changed, importTag: importTag, replaced: replaced, skipped: skipped,
                    warnings: warnings, size: size)
    }

    /// The import for a copy in another board: the same attributes, the name relative to that board.
    private static func tagFor(name: String, original: String, board: DesignPath, piece: DesignPath) -> String {
        guard let own = importName(of: piece, in: board) else { return original }
        return original.replacingOccurrences(of: "name=\"\(own)\"", with: "name=\"\(name)\"")
    }

    private static func cut(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 40 ? String(flat.prefix(39)) + "…" : flat
    }

    private static func number(_ value: Double) -> String {
        Int(exactly: value).map(String.init) ?? String(value)
    }

    /// The piece's `.dc.html`: the source board's head (so a design system's links still resolve),
    /// its helmets (so the piece draws alone as it does in its board), the element as the template's
    /// root, and a script that reads each prop with its old text as the default.
    private static func assemble(stem: String, source: String, helmets: [String], markup: String, size: DesignBoardCheck.Size,
                                 props: [(name: String, text: String)]) -> String {
        var head = ""
        if let support = source.range(of: DesignBoardCheck.supportScript), let end = source.range(of: "</head>", options: .caseInsensitive, range: support.upperBound..<source.endIndex) {
            head = source[support.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>\(stem)</title>\n\(DesignBoardCheck.supportScript)\n"
        if !head.isEmpty { out += head + "\n" }
        out += "</head>\n<body>\n<x-dc>\n"
        for helmet in helmets { out += helmet + "\n" }
        out += markup + "\n</x-dc>\n"
        out += "<script type=\"text/x-dc\" data-dc-script data-props='{\"$preview\":{\"width\":\(number(size.width)),\"height\":\(number(size.height))}}'>\n"
        out += "class Component extends DCLogic {\n"
        if props.isEmpty {
            out += "  renderVals() { return {}; }\n"
        } else {
            out += "  renderVals() {\n    return {\n"
            for prop in props { out += "      \(prop.name): this.props.\(prop.name) ?? \(literal(prop.text)),\n" }
            out += "    };\n  }\n"
        }
        out += "}\n</script>\n</body>\n</html>\n"
        return out
    }
}
