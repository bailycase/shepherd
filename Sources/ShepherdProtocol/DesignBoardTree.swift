import Foundation

/// A board read for the design agent's tools: its template as `DesignTemplate` numbers it, plus
/// what that parse leaves out (each element's attributes, where each ends, the text between the
/// tags, and where the tags stop balancing). The write report, `board_search`, the usage index
/// and `board_extract` all read boards through it.
///
/// Pure and bounded by the source's size (a board is at most `DesignBoardCheck.maxBytes`).
public struct DesignBoardTree: Sendable {
    public let source: String
    public let template: DesignTemplate
    let bytes: [UInt8]
    let scan: DesignMarkupScan
    /// Each element's tid by where its start tag begins.
    private let tidAt: [Int: Int]

    /// Nil when the source has no `<x-dc>` … `</x-dc>` template.
    public init?(source: String) {
        guard let template = DesignTemplate(board: source) else { return nil }
        let bytes = Array(source.utf8)
        guard let range = DesignTemplate.fragmentRange(in: bytes) else { return nil }
        self.source = source
        self.template = template
        self.bytes = bytes
        scan = DesignMarkupScan.scan(bytes: bytes, range: range)
        var at: [Int: Int] = [:]
        for element in template.elements {
            if let start = element.tagRange?.lowerBound { at[start] = element.tid }
        }
        tidAt = at
    }

    public var elements: [DesignTemplateElement] { template.elements }

    /// The first place the template's tags stop balancing, nil when they balance.
    public var imbalance: DesignMarkupImbalance? { scan.imbalance }

    /// The top-level elements besides `<helmet>`: a board has exactly one root.
    public var roots: [DesignTemplateElement] {
        template.elements.filter { $0.parent == nil && $0.name != "helmet" }
    }

    /// The element's attributes as written (names lower-cased, entities decoded), in order.
    public func attributes(of tid: Int) -> [(name: String, value: String)] {
        guard template.elements.indices.contains(tid), let range = template.elements[tid].tagRange else { return [] }
        var tokenizer = HTMLTokenizer(bytes: bytes, range: range)
        return tokenizer.next()?.attributes ?? []
    }

    public func attribute(_ name: String, of tid: Int) -> String? {
        attributes(of: tid).first { $0.name == name }?.value
    }

    /// The element's start tag as written.
    public func startTag(of tid: Int) -> String? {
        guard template.elements.indices.contains(tid), let range = template.elements[tid].tagRange else { return nil }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    /// Where the element is in the source, from its start tag to the end of its end tag (or to
    /// where HTML ends it). Nil for an element HTML implied, or one the tag scan lost track of.
    public func range(of tid: Int) -> Range<Int>? {
        guard template.elements.indices.contains(tid), let start = template.elements[tid].tagRange?.lowerBound,
              let end = scan.ends[start], end >= start else { return nil }
        return start..<end
    }

    /// The element's source text, `range(of:)`'s bytes.
    public func markup(of tid: Int) -> String? {
        range(of: tid).map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    /// The text nodes of the template outside `<style>`, `<script>`, `<title>` and `<helmet>`
    /// that hold more than whitespace, each with the element it is directly in (nil: top level).
    public var texts: [(range: Range<Int>, element: Int?)] {
        var out: [(range: Range<Int>, element: Int?)] = []
        for text in scan.texts {
            guard let slice = bytes[safe: text.range], slice.contains(where: { !HTMLBytes.isSpace($0) }) else { continue }
            out.append((text.range, text.owner.flatMap { tidAt[$0] }))
        }
        return out
    }

    /// The line (from 1) a source offset is on.
    public func line(at offset: Int) -> Int {
        var line = 1
        var i = 0
        let end = min(offset, bytes.count)
        while i < end {
            if bytes[i] == 0x0A { line += 1 }
            i += 1
        }
        return line
    }

    /// Where each line starts, for repeated lookups.
    public var lineStarts: [Int] {
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == 0x0A { starts.append(i + 1) }
        return starts
    }

    /// The elements above `tid`, nearest first.
    public func ancestors(of tid: Int) -> [DesignTemplateElement] {
        var out: [DesignTemplateElement] = []
        var current = template.elements.indices.contains(tid) ? template.elements[tid].parent : nil
        while let id = current, template.elements.indices.contains(id) {
            out.append(template.elements[id])
            current = template.elements[id].parent
        }
        return out
    }
}

private extension Array where Element == UInt8 {
    subscript(safe range: Range<Int>) -> ArraySlice<UInt8>? {
        range.lowerBound >= 0 && range.upperBound <= count ? self[range] : nil
    }
}

// MARK: - Balance

/// Where a template's tags stop balancing.
public struct DesignMarkupImbalance: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// An element still open where an end tag for one above it arrived.
        case unclosed
        /// An element still open at the template's end.
        case unclosedAtEnd = "unclosed_at_end"
        /// An end tag with nothing open to close.
        case stray
        /// A non-void HTML element written `<x />`: HTML ignores the slash, so it stays open.
        case selfClosed = "self_closed"
    }

    public var kind: Kind
    /// The element's tag name (for `stray`, the end tag's).
    public var tag: String
    /// The line (from 1) of the element, or of the stray end tag.
    public var line: Int
    /// For `unclosed`: the end tag that arrived, and its line.
    public var reached: String?
    public var reachedLine: Int?

    public init(kind: Kind, tag: String, line: Int, reached: String? = nil, reachedLine: Int? = nil) {
        self.kind = kind
        self.tag = tag
        self.line = line
        self.reached = reached
        self.reachedLine = reachedLine
    }

    public var description: String {
        switch kind {
        case .unclosed:
            let closer = reached.map { "</\($0)>" } ?? "an end tag"
            return "<\(tag)> from line \(line) is never closed: \(closer) at line \(reachedLine ?? line) arrived first (a dropped </\(tag)>?)"
        case .unclosedAtEnd:
            return "<\(tag)> from line \(line) is never closed (the template ends first)"
        case .stray:
            return "</\(tag)> at line \(line) closes nothing"
        case .selfClosed:
            return "<\(tag) /> at line \(line) is self-closed, which HTML ignores, so it stays open: write <\(tag)></\(tag)>"
        }
    }
}

/// One pass over a template's tags, kept apart from `DesignTemplate`'s tree builder so the
/// numbering that `Tests/Designs/element-ids.json` pins never changes with it: where elements
/// end, the text between them, and the first imbalance.
struct DesignMarkupScan: Sendable {
    var imbalance: DesignMarkupImbalance?
    /// Start-tag offset → the offset just past the element (its end tag, or where HTML ends it).
    var ends: [Int: Int] = [:]
    /// Text outside raw-text elements and `<helmet>`, with the start-tag offset of its element.
    var texts: [(range: Range<Int>, owner: Int?)] = []

    private struct Open {
        let name: String
        let start: Int
        let foreign: Bool
        var optional: Bool { DesignMarkupScan.optionalEnd.contains(name) && !foreign }
    }

    static let void: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input",
        "keygen", "link", "meta", "param", "source", "track", "wbr",
    ]
    static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "textarea", "title"]
    /// Elements whose end tag HTML lets a page leave out.
    static let optionalEnd: Set<String> = [
        "p", "li", "dt", "dd", "option", "optgroup", "tr", "td", "th", "thead", "tbody", "tfoot", "caption",
        "colgroup", "rb", "rp", "rt", "rtc",
    ]
    static let integrationPoints: Set<String> = ["foreignobject", "desc", "title", "mi", "mo", "mn", "ms", "mtext", "annotation-xml"]
    /// Start tags that end an open `<p>`.
    static let closesP: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p",
        "search", "section", "summary", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "form", "table", "hr",
    ]
    /// Text inside these is markup's, not the page's words.
    static let silent: Set<String> = ["style", "script", "title", "helmet", "textarea"]

    static func scan(bytes: [UInt8], range: Range<Int>) -> DesignMarkupScan {
        var result = DesignMarkupScan()
        var tokenizer = HTMLTokenizer(bytes: bytes, range: range)
        var stack: [Open] = []
        let starts = lineStarts(bytes)

        func line(_ offset: Int) -> Int {
            var low = 0
            var high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) >> 1
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low + 1
        }
        func note(_ imbalance: DesignMarkupImbalance) {
            if result.imbalance == nil { result.imbalance = imbalance }
        }
        func inForeign() -> Bool {
            guard let top = stack.last else { return false }
            return top.foreign && !integrationPoints.contains(top.name)
        }
        func flushTexts() {
            let owner = stack.last?.start
            let quiet = stack.contains { !$0.foreign && silent.contains($0.name) }
            for text in tokenizer.texts where !quiet { result.texts.append((text, owner)) }
            tokenizer.texts.removeAll(keepingCapacity: true)
        }
        func pop(_ open: Open, at offset: Int) { result.ends[open.start] = offset }

        while let tag = tokenizer.next(foreign: inForeign()) {
            flushTexts()
            let name = tag.name
            if !tag.isEnd {
                let foreignStart = inForeign() || name == "svg" || name == "math"
                if !foreignStart {
                    // A start tag HTML reads as ending what is open.
                    while let top = stack.last, !top.foreign, top.optional {
                        let closes = top.name == name
                            || (["td", "th"].contains(name) && ["td", "th"].contains(top.name))
                            || (name == "tr" && ["td", "th", "tr"].contains(top.name))
                            || (["thead", "tbody", "tfoot"].contains(name) && ["td", "th", "tr", "thead", "tbody", "tfoot"].contains(top.name))
                            || (top.name == "p" && closesP.contains(name))
                            || (["dt", "dd"].contains(name) && ["dt", "dd"].contains(top.name))
                            || (name == "option" && top.name == "option")
                        guard closes else { break }
                        pop(stack.removeLast(), at: tag.range.lowerBound)
                    }
                    if void.contains(name) {
                        result.ends[tag.range.lowerBound] = tag.range.upperBound
                        continue
                    }
                }
                if tag.selfClosing {
                    if foreignStart {
                        result.ends[tag.range.lowerBound] = tag.range.upperBound
                        continue
                    }
                    note(DesignMarkupImbalance(kind: .selfClosed, tag: name, line: line(tag.range.lowerBound)))
                }
                stack.append(Open(name: name, start: tag.range.lowerBound, foreign: foreignStart))
                if !foreignStart, rawText.contains(name) { tokenizer.skipRawText(of: name) }
                continue
            }
            // An end tag.
            if void.contains(name) { continue }
            guard let index = stack.lastIndex(where: { $0.name == name }) else {
                if !["p", "br", "html", "body", "head"].contains(name) {
                    note(DesignMarkupImbalance(kind: .stray, tag: name, line: line(tag.range.lowerBound)))
                }
                continue
            }
            for open in stack[(index + 1)...].reversed() {
                if !open.optional {
                    note(DesignMarkupImbalance(kind: .unclosed, tag: open.name, line: line(open.start), reached: name,
                                               reachedLine: line(tag.range.lowerBound)))
                }
                pop(open, at: tag.range.lowerBound)
            }
            pop(stack[index], at: tag.range.upperBound)
            stack.removeSubrange(index...)
        }
        flushTexts()
        for open in stack.reversed() {
            if !open.optional { note(DesignMarkupImbalance(kind: .unclosedAtEnd, tag: open.name, line: line(open.start))) }
            pop(open, at: range.upperBound)
        }
        return result
    }

    private static func lineStarts(_ bytes: [UInt8]) -> [Int] {
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == 0x0A { starts.append(i + 1) }
        return starts
    }
}
