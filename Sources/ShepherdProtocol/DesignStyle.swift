import Foundation

/// An element's inline `style` as its board's source writes it: each declaration with where its
/// value lies, so a tweak can rewrite one value in place (docs/designs.md › Tweak).
public struct DesignInlineStyle: Hashable, Sendable {
    public struct Declaration: Hashable, Sendable {
        /// The property, lower-cased (`padding`, `--accent`).
        public let property: String
        /// The value with character references decoded, trimmed, without `!important`.
        public let value: String
        public let important: Bool
        /// Whether its value is bound to the board's logic (`{{ … }}`).
        public var isBound: Bool { value.contains("{{") }
        /// The whole declaration (name to value) and its value, in the source's UTF-8 bytes.
        let range: Range<Int>
        let valueRange: Range<Int>
    }

    public let declarations: [Declaration]
    /// The whole style is one `{{ hole }}`: the board's logic sets it, so nothing can be added.
    public let isBoundWhole: Bool

    /// The value the browser uses for `property`: its last declaration.
    public func value(_ property: String) -> String? {
        declaration(property)?.value
    }

    public func declaration(_ property: String) -> Declaration? {
        declarations.last { $0.property == property }
    }

    public static let empty = DesignInlineStyle(declarations: [], isBoundWhole: false)
}

/// Reads and edits an element's inline style in a board's source, at the parser's offsets
/// (`DesignTemplate`'s tag ranges): an edit rewrites the bytes of one declaration's value, adds a
/// declaration after the last, removes one, or adds the attribute. Every other byte of the board
/// stays exactly as written; the board is never serialized again.
public enum DesignStyleEdit {
    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        /// The source has no `<x-dc>` template.
        case noTemplate
        /// No element has that tid, or the tid and path name different elements.
        case noElement(Int)
        /// The element takes no style of its own: HTML implies it, or it is `<helmet>`, `<sc-if>`,
        /// `<sc-for>`, `<dc-import>`, `<style>`, `<script>` or `<title>`.
        case notStyled(Int)
        /// The board's logic sets this value (`{{ … }}`), or the whole style.
        case bound(String)
        /// A property or value outside what a tweak writes.
        case unsafe(String)

        public var description: String {
            switch self {
            case .noTemplate: return "the board has no <x-dc> template"
            case .noElement(let tid): return "no element \(tid) on the board"
            case .notStyled(let tid): return "element \(tid) takes no style"
            case .bound(let property): return "the board's logic sets \(property)"
            case .unsafe(let text): return "\"\(text)\" is not a value a tweak writes"
            }
        }
    }

    /// Tags whose `style` is not the element's own look.
    static let unstyled: Set<String> = ["helmet", "sc-if", "sc-for", "dc-import", "style", "script", "title", "template"]

    // MARK: Reading

    /// Element `tid`'s inline style; `.empty` when it has none. Nil when the board has no such
    /// element, or it takes no style.
    public static func style(of tid: Int, in source: String) -> DesignInlineStyle? {
        let bytes = Array(source.utf8)
        guard let template = DesignTemplate(board: source), tid >= 0, tid < template.elements.count,
              let tag = startTag(of: template.elements[tid], in: bytes) else { return nil }
        guard let style = tag.attribute("style") else { return .empty }
        return parse(bytes, style)
    }

    /// Every element's inline style that takes one, read in one pass (tid → style; `.empty` for
    /// an element without the attribute).
    public static func styles(in source: String) -> [Int: DesignInlineStyle] {
        let bytes = Array(source.utf8)
        guard let template = DesignTemplate(board: source) else { return [:] }
        var styles: [Int: DesignInlineStyle] = [:]
        for element in template.elements {
            guard let tag = startTag(of: element, in: bytes) else { continue }
            styles[element.tid] = tag.attribute("style").map { parse(bytes, $0) } ?? .empty
        }
        return styles
    }

    /// Element `tid`'s attribute `name` as written, character references decoded.
    public static func attribute(_ name: String, of tid: Int, in source: String) -> String? {
        let bytes = Array(source.utf8)
        guard let template = DesignTemplate(board: source), tid >= 0, tid < template.elements.count,
              let range = template.elements[tid].tagRange else { return nil }
        return StartTag(bytes: bytes, range: range).attribute(name).map { HTMLEntities.decode($0.text(bytes)) }
    }

    /// The tids of the elements whose `data-el` is `name`, in document order.
    public static func elements(named name: String, in source: String) -> [Int] {
        let bytes = Array(source.utf8)
        guard !name.isEmpty, let template = DesignTemplate(board: source) else { return [] }
        return template.elements.compactMap { element in
            guard let range = element.tagRange, !unstyled.contains(element.name),
                  let value = StartTag(bytes: bytes, range: range).attribute("data-el"),
                  HTMLEntities.decode(value.text(bytes)) == name else { return nil }
            return element.tid
        }
    }

    // MARK: Editing

    /// `source` with element `tid`'s style changed: each property set to its value, or removed
    /// where the value is nil. Values are what a tweak writes (lengths, `var(--token)`, colors):
    /// anything with quotes, markup, `;`, braces or a backslash is refused.
    public static func apply(_ changes: [String: String?], to tid: Int, in source: String) throws(Problem) -> String {
        try apply([tid: changes], in: source)
    }

    /// Several elements of one board changed at once (every element of a name, say). Each edit
    /// is made at its own offsets, from the end of the file back, so none moves another: values
    /// are replaced and declarations removed first, then new declarations are added.
    public static func apply(_ changes: [Int: [String: String?]], in source: String) throws(Problem) -> String {
        for properties in changes.values {
            for (property, value) in properties {
                guard isSafeProperty(property) else { throw .unsafe(property) }
                if let value, !isSafeValue(value) { throw .unsafe(value) }
            }
        }
        let replaced = try pass(changes, in: source, adding: false)
        return try pass(changes, in: replaced, adding: true)
    }

    private static func pass(_ changes: [Int: [String: String?]], in source: String, adding: Bool) throws(Problem) -> String {
        guard let template = DesignTemplate(board: source) else { throw .noTemplate }
        let bytes = Array(source.utf8)
        var edits: [(range: Range<Int>, text: [UInt8])] = []
        for (tid, properties) in changes.sorted(by: { $0.key < $1.key }) where !properties.isEmpty {
            guard tid >= 0, tid < template.elements.count else { throw .noElement(tid) }
            let element = template.elements[tid]
            guard let tag = startTag(of: element, in: bytes) else { throw .notStyled(tid) }
            let ordered = properties.sorted { $0.key < $1.key }
            edits += try adding ? additions(ordered, tag: tag, name: element.name, bytes: bytes)
                                : replacements(ordered, tag: tag, bytes: bytes)
        }
        var out = bytes
        for edit in merged(edits).sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: edit.text)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Removals that touch (a property written twice) become one.
    private static func merged(_ edits: [(range: Range<Int>, text: [UInt8])]) -> [(range: Range<Int>, text: [UInt8])] {
        var out: [(range: Range<Int>, text: [UInt8])] = []
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            if let last = out.last, last.text.isEmpty, edit.text.isEmpty, edit.range.lowerBound < last.range.upperBound {
                out[out.count - 1].range = last.range.lowerBound..<Swift.max(last.range.upperBound, edit.range.upperBound)
            } else {
                out.append(edit)
            }
        }
        return out
    }

    /// Whether `text` is a property a tweak may write: lower-case letters and dashes, or a
    /// custom property.
    public static func isSafeProperty(_ text: String) -> Bool {
        guard let first = text.utf8.first, (1...64).contains(text.utf8.count) else { return false }
        guard first == UInt8(ascii: "-") || (0x61...0x7A).contains(first) else { return false }
        return text.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }
    }

    /// Whether `text` is a value a tweak may write: `24px`, `var(--space-6)`, `#4f46e5`, `row`,
    /// `8px 12px`, `rgba(0, 0, 0, 0.1)`.
    public static func isSafeValue(_ text: String) -> Bool {
        guard (1...200).contains(text.utf8.count), text.trimmingCharacters(in: .whitespaces) == text else { return false }
        let characters = text.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
                || " #.%(),-_+/".utf8.contains(b)
        }
        guard characters else { return false }
        // Only functions that compute a color or a length: never one that loads (`url()`,
        // `image-set()`).
        var name = ""
        for c in text.lowercased() {
            if c == "(" {
                guard safeFunctions.contains(name) else { return false }
                name = ""
            } else if c.isLetter || c.isNumber || c == "-" || c == "_" {
                name.append(c)
            } else {
                name = ""
            }
        }
        return true
    }

    static let safeFunctions: Set<String> = [
        "var", "calc", "min", "max", "clamp", "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch",
        "color-mix",
    ]

    private static func startTag(of element: DesignTemplateElement, in bytes: [UInt8]) -> StartTag? {
        guard let range = element.tagRange, !unstyled.contains(element.name) else { return nil }
        return StartTag(bytes: bytes, range: range)
    }

    /// The first pass: values rewritten in place, declarations removed.
    private static func replacements(_ ordered: [(key: String, value: String?)], tag: StartTag,
                                     bytes: [UInt8]) throws(Problem) -> [(range: Range<Int>, text: [UInt8])] {
        guard let attribute = tag.attribute("style"), attribute.quote != nil else { return [] }
        let style = parse(bytes, attribute)
        guard !style.isBoundWhole else { throw .bound("style") }
        var edits: [(range: Range<Int>, text: [UInt8])] = []
        for (property, value) in ordered {
            let existing = style.declarations.filter { $0.property == property }
            guard let last = existing.last else { continue }
            guard !last.isBound else { throw .bound(property) }
            if let value {
                edits.append((last.valueRange, Array(value.utf8)))
            } else {
                for declaration in existing { edits.append((removal(declaration, in: attribute.value, bytes: bytes), [])) }
            }
        }
        return edits
    }

    /// The second pass: declarations the style lacks added after its last, the attribute added
    /// where there is none, and an unquoted style written again quoted.
    private static func additions(_ ordered: [(key: String, value: String?)], tag: StartTag, name: String,
                                  bytes: [UInt8]) throws(Problem) -> [(range: Range<Int>, text: [UInt8])] {
        guard let attribute = tag.attribute("style") else {
            let added = ordered.compactMap { property, value in value.map { "\(property): \($0)" } }
            guard !added.isEmpty else { return [] }
            let at = tag.range.lowerBound + 1 + name.utf8.count
            return [(at..<at, Array(" style=\"\(added.joined(separator: "; "))\"".utf8))]
        }
        let style = parse(bytes, attribute)
        guard !style.isBoundWhole else { throw .bound("style") }
        if attribute.quote == nil {
            // An unquoted value can't take a space: write the attribute's value again, quoted,
            // with the same declarations and the changes. A bare `style` gains its `=`.
            let text = try rewritten(attribute.text(bytes), style: style, ordered, base: attribute.value.lowerBound)
            return [(attribute.value, Array("\(attribute.isBare ? "=" : "")\"\(text)\"".utf8))]
        }
        let appended = ordered.compactMap { property, value -> String? in
            guard let value, style.declaration(property) == nil else { return nil }
            return "\(property): \(value)"
        }
        guard !appended.isEmpty else { return [] }
        // After the last thing written, keeping whatever space trails it.
        var end = attribute.value.upperBound
        while end > attribute.value.lowerBound, HTMLBytes.isSpace(bytes[end - 1]) { end -= 1 }
        let text: String
        if end == attribute.value.lowerBound {
            text = appended.joined(separator: "; ")
        } else if bytes[end - 1] == UInt8(ascii: ";") {
            text = " " + appended.joined(separator: "; ") + ";"
        } else {
            text = "; " + appended.joined(separator: "; ")
        }
        return [(end..<end, Array(text.utf8))]
    }

    /// An unquoted style's text with the changes made, for writing it again quoted.
    private static func rewritten(_ text: String, style: DesignInlineStyle, _ ordered: [(key: String, value: String?)],
                                  base: Int) throws(Problem) -> String {
        var out = Array(text.utf8)
        var appended: [String] = []
        var edits: [(Range<Int>, [UInt8])] = []
        for (property, value) in ordered {
            let existing = style.declarations.filter { $0.property == property }
            if let last = existing.last {
                guard !last.isBound else { throw .bound(property) }
                if let value { edits.append((last.valueRange.shifted(-base), Array(value.utf8))) }
                else { for d in existing { edits.append((d.range.shifted(-base), [])) } }
            } else if let value {
                appended.append("\(property): \(value)")
            }
        }
        for (range, replacement) in edits.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) { out.replaceSubrange(range, with: replacement) }
        var result = String(decoding: out, as: UTF8.self)
        if !appended.isEmpty { result += (result.isEmpty || result.hasSuffix(";") ? "" : "; ") + appended.joined(separator: "; ") }
        return result.replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// What removing a declaration takes out: it and the `;` and space after it, or, for the last
    /// one, the `;` before it.
    private static func removal(_ declaration: DesignInlineStyle.Declaration, in value: Range<Int>, bytes: [UInt8]) -> Range<Int> {
        var end = declaration.range.upperBound
        while end < value.upperBound, HTMLBytes.isSpace(bytes[end]) { end += 1 }
        if end < value.upperBound, bytes[end] == UInt8(ascii: ";") {
            end += 1
            while end < value.upperBound, HTMLBytes.isSpace(bytes[end]) { end += 1 }
            return declaration.range.lowerBound..<end
        }
        var start = declaration.range.lowerBound
        var probe = start
        while probe > value.lowerBound, HTMLBytes.isSpace(bytes[probe - 1]) { probe -= 1 }
        if probe > value.lowerBound, bytes[probe - 1] == UInt8(ascii: ";") { start = probe - 1 }
        return start..<declaration.range.upperBound
    }

    // MARK: Parsing

    /// The declarations of a style attribute's raw value: split at `;` outside quotes,
    /// parentheses and `{{ holes }}`.
    static func parse(_ bytes: [UInt8], _ attribute: StartTag.Attribute) -> DesignInlineStyle {
        let range = attribute.value
        var declarations: [DesignInlineStyle.Declaration] = []
        var start = range.lowerBound
        var i = range.lowerBound
        var depth = 0
        var quote: UInt8?
        var sawColonOutsideHoles = false
        func flush(_ end: Int) {
            if let declaration = declaration(bytes, start..<end) {
                declarations.append(declaration)
                sawColonOutsideHoles = true
            }
        }
        while i < range.upperBound {
            let b = bytes[i]
            if let q = quote {
                if b == q { quote = nil }
            } else if b == UInt8(ascii: "{"), i + 1 < range.upperBound, bytes[i + 1] == UInt8(ascii: "{") {
                // A hole: skip to its end.
                var j = i + 2
                while j + 1 < range.upperBound, !(bytes[j] == UInt8(ascii: "}") && bytes[j + 1] == UInt8(ascii: "}")) { j += 1 }
                i = min(j + 2, range.upperBound)
                continue
            } else if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
                quote = b
            } else if b == UInt8(ascii: "(") {
                depth += 1
            } else if b == UInt8(ascii: ")") {
                depth = max(0, depth - 1)
            } else if b == UInt8(ascii: ";"), depth == 0 {
                flush(i)
                start = i + 1
            }
            i += 1
        }
        flush(range.upperBound)
        let raw = String(decoding: bytes[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let whole = !sawColonOutsideHoles && raw.hasPrefix("{{") && raw.hasSuffix("}}")
        return DesignInlineStyle(declarations: declarations, isBoundWhole: whole)
    }

    private static func declaration(_ bytes: [UInt8], _ range: Range<Int>) -> DesignInlineStyle.Declaration? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, HTMLBytes.isSpace(bytes[lower]) { lower += 1 }
        while upper > lower, HTMLBytes.isSpace(bytes[upper - 1]) { upper -= 1 }
        guard lower < upper, let colon = bytes[lower..<upper].firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let name = String(decoding: bytes[lower..<colon], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("{{") else { return nil }
        var valueStart = colon + 1
        while valueStart < upper, HTMLBytes.isSpace(bytes[valueStart]) { valueStart += 1 }
        var valueEnd = upper
        var important = false
        let text = String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self)
        if let bang = text.range(of: #"\s*!\s*important\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            important = true
            valueEnd = valueStart + text[..<bang.lowerBound].utf8.count
        }
        let value = HTMLEntities.decode(String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self))
        return DesignInlineStyle.Declaration(property: name.lowercased(), value: value, important: important,
                                             range: lower..<upper, valueRange: valueStart..<valueEnd)
    }
}

/// A start tag's attributes with where each lies in the source.
struct StartTag {
    struct Attribute {
        let name: String
        /// The value's bytes, inside its quotes.
        let value: Range<Int>
        /// `"` or `'`; nil when unquoted (or bare).
        let quote: UInt8?
        /// Written without `=` (`<div style>`): its value is the empty range after its name.
        var isBare = false

        func text(_ bytes: [UInt8]) -> String { String(decoding: bytes[value], as: UTF8.self) }
    }

    let range: Range<Int>
    let attributes: [Attribute]

    func attribute(_ name: String) -> Attribute? { attributes.first { $0.name == name } }

    /// Reads the tag at `range` (from its `<` to its `>`), as `HTMLTokenizer` does.
    init(bytes: [UInt8], range: Range<Int>) {
        self.range = range
        var attributes: [Attribute] = []
        var i = range.lowerBound + 1
        let end = range.upperBound
        while i < end, !HTMLBytes.isSpace(bytes[i]), bytes[i] != UInt8(ascii: "/"), bytes[i] != UInt8(ascii: ">") { i += 1 }
        while i < end {
            let b = bytes[i]
            if HTMLBytes.isSpace(b) || b == UInt8(ascii: "/") { i += 1; continue }
            if b == UInt8(ascii: ">") { break }
            let nameStart = i
            i += 1
            while i < end {
                let c = bytes[i]
                if HTMLBytes.isSpace(c) || c == UInt8(ascii: "/") || c == UInt8(ascii: ">") || c == UInt8(ascii: "=") { break }
                i += 1
            }
            let name = String(decoding: bytes[nameStart..<i].map(HTMLBytes.lower), as: UTF8.self)
            var probe = i
            while probe < end, HTMLBytes.isSpace(bytes[probe]) { probe += 1 }
            var value = i..<i
            var quote: UInt8?
            let isBare = !(probe < end && bytes[probe] == UInt8(ascii: "="))
            if !isBare {
                i = probe + 1
                while i < end, HTMLBytes.isSpace(bytes[i]) { i += 1 }
                if i < end, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") {
                    quote = bytes[i]
                    let start = i + 1
                    let close = bytes[start..<end].firstIndex(of: bytes[i]) ?? end
                    value = start..<close
                    i = min(close + 1, end)
                } else {
                    let start = i
                    while i < end, !HTMLBytes.isSpace(bytes[i]), bytes[i] != UInt8(ascii: ">") { i += 1 }
                    value = start..<i
                }
            }
            // A repeated attribute keeps its first value, as HTML does.
            if !attributes.contains(where: { $0.name == name }) {
                attributes.append(Attribute(name: name, value: value, quote: quote, isBare: isBare))
            }
        }
        self.attributes = attributes
    }
}

private extension Range where Bound == Int {
    func shifted(_ by: Int) -> Range<Int> { (lowerBound + by)..<(upperBound + by) }
}
