import Foundation

/// An element of a board's template, numbered as view-state.md numbers it.
public struct DesignTemplateElement: Hashable, Sendable {
    /// Depth-first index among every element of the template, from 0.
    public let tid: Int
    /// Child positions from the template's top level down to this element.
    public let path: [Int]
    /// The tag name, lower-cased.
    public let name: String
    /// The parent's tid; nil at the top level.
    public let parent: Int?
    /// Where its start tag is in the board's source, in UTF-8 bytes; nil for an element HTML
    /// implies (a table's `tbody`).
    public let tagRange: Range<Int>?
}

/// A board's template: the text strictly between its `<x-dc>` open tag and its last `</x-dc>`,
/// read the way an HTML parser builds it inside a `<template>` (every element counts, `<helmet>`,
/// `<sc-for>`, `<sc-if>` and `<dc-import>` included; text and comments don't).
///
/// This is the Swift twin of the board runtime's numbering: the server checks anchors and the
/// agent resolves ids with it, and `Tests/Designs/element-ids.json` holds the two in step.
/// It models what boards use: void and raw-text elements, comments, SVG and MathML (where
/// `/>` closes), the end tags HTML implies (`p`, `li`, `dd`/`dt`, `option`, headings, table
/// cells and rows, with the `tbody` and `tr` a table implies), and stray end tags. It does not
/// model foster parenting (content misplaced inside a table) or the reconstruction of misnested
/// formatting tags, which boards don't write.
public struct DesignTemplate: Sendable {
    public let elements: [DesignTemplateElement]

    /// Nil when the source has no `<x-dc>` … `</x-dc>` fragment.
    public init?(board source: String) {
        let bytes = Array(source.utf8)
        guard let range = Self.fragmentRange(in: bytes) else { return nil }
        var builder = TemplateBuilder(bytes: bytes, range: range)
        elements = builder.build()
    }

    /// The element `id` names, when its tid and path agree on one.
    public func element(for id: DesignElementID) -> DesignTemplateElement? {
        guard id.tid < elements.count else { return nil }
        let element = elements[id.tid]
        return element.path == id.path ? element : nil
    }

    /// Where the fragment lies: after the first `<x-dc>` open tag, up to the last `</x-dc>`.
    static func fragmentRange(in bytes: [UInt8]) -> Range<Int>? {
        let open = Array("<x-dc".utf8)
        let close = Array("</x-dc>".utf8)
        var start: Int?
        var i = 0
        while i + open.count < bytes.count {
            if bytes[i] == 0x3C, HTMLBytes.matches(bytes, at: i, open) {
                let next = bytes[i + open.count]
                if next == UInt8(ascii: ">") || HTMLBytes.isSpace(next) {
                    guard let end = bytes[(i + open.count)...].firstIndex(of: UInt8(ascii: ">")) else { return nil }
                    start = end + 1
                    break
                }
            }
            i += 1
        }
        guard let start else { return nil }
        var j = bytes.count - close.count
        while j >= start {
            if bytes[j] == 0x3C, HTMLBytes.matches(bytes, at: j, close) { return start..<j }
            j -= 1
        }
        return nil
    }
}

// MARK: - Tokens

/// A start or end tag read from HTML source.
struct HTMLTag {
    var range: Range<Int>
    var name: String
    var isEnd: Bool
    var selfClosing: Bool
    var attributes: [(name: String, value: String)]

    func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }
}

enum HTMLBytes {
    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D }
    static func isAlpha(_ b: UInt8) -> Bool { (b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A }
    static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }

    static func matches(_ bytes: [UInt8], at i: Int, _ needle: [UInt8]) -> Bool {
        guard i + needle.count <= bytes.count else { return false }
        for k in 0..<needle.count where lower(bytes[i + k]) != needle[k] { return false }
        return true
    }
}

/// Reads tags one at a time from a byte range, skipping text, comments, doctypes and
/// processing instructions. The builder tells it when an element's content is raw text.
struct HTMLTokenizer {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        position = range.lowerBound
        end = range.upperBound
    }

    mutating func next(foreign: Bool = false) -> HTMLTag? {
        while position < end {
            guard let lt = bytes[position..<end].firstIndex(of: 0x3C) else {
                position = end
                return nil
            }
            position = lt
            guard lt + 1 < end else { position = end; return nil }
            let next = bytes[lt + 1]
            if next == UInt8(ascii: "!") {
                if HTMLBytes.matches(bytes, at: lt, Array("<!--".utf8)) {
                    skipComment()
                } else if foreign, HTMLBytes.matches(bytes, at: lt, Array("<![cdata[".utf8)) {
                    skip(past: Array("]]>".utf8), from: lt + 9)
                } else {
                    skip(pastByte: UInt8(ascii: ">"), from: lt + 2)
                }
            } else if next == UInt8(ascii: "?") {
                skip(pastByte: UInt8(ascii: ">"), from: lt + 2)
            } else if next == UInt8(ascii: "/") {
                guard lt + 2 < end else { position = end; return nil }
                if HTMLBytes.isAlpha(bytes[lt + 2]) {
                    position = lt + 2
                    return readTag(isEnd: true, from: lt)
                } else if bytes[lt + 2] == UInt8(ascii: ">") {
                    position = lt + 3
                } else {
                    skip(pastByte: UInt8(ascii: ">"), from: lt + 2)
                }
            } else if HTMLBytes.isAlpha(next) {
                position = lt + 1
                return readTag(isEnd: false, from: lt)
            } else {
                position = lt + 1
            }
        }
        return nil
    }

    /// Skips an element's raw text up to (not past) its end tag, or to the end.
    mutating func skipRawText(of name: String) {
        let needle = Array("</\(name)".utf8)
        var i = position
        while i < end {
            guard let lt = bytes[i..<end].firstIndex(of: 0x3C) else { break }
            if HTMLBytes.matches(bytes, at: lt, needle) {
                let after = lt + needle.count
                if after >= end || HTMLBytes.isSpace(bytes[after]) || bytes[after] == UInt8(ascii: ">") || bytes[after] == UInt8(ascii: "/") {
                    position = lt
                    return
                }
            }
            i = lt + 1
        }
        position = end
    }

    mutating func skipToEnd() { position = end }

    private mutating func skipComment() {
        // `<!-->` and `<!--->` end at once, as HTML reads them.
        let body = position + 4
        if body < end, bytes[body] == UInt8(ascii: ">") { position = body + 1; return }
        if body + 1 < end, bytes[body] == UInt8(ascii: "-"), bytes[body + 1] == UInt8(ascii: ">") { position = body + 2; return }
        skip(past: Array("-->".utf8), from: body)
    }

    private mutating func skip(pastByte byte: UInt8, from start: Int) {
        if start < end, let found = bytes[start..<end].firstIndex(of: byte) {
            position = found + 1
        } else {
            position = end
        }
    }

    private mutating func skip(past needle: [UInt8], from start: Int) {
        var i = start
        while i + needle.count <= end {
            if bytes[i] == needle[0], HTMLBytes.matches(bytes, at: i, needle) { position = i + needle.count; return }
            i += 1
        }
        position = end
    }

    private mutating func readTag(isEnd: Bool, from start: Int) -> HTMLTag {
        var name: [UInt8] = []
        while position < end {
            let b = bytes[position]
            if HTMLBytes.isSpace(b) || b == UInt8(ascii: "/") || b == UInt8(ascii: ">") { break }
            name.append(HTMLBytes.lower(b))
            position += 1
        }
        var tag = HTMLTag(range: start..<start, name: String(decoding: name, as: UTF8.self), isEnd: isEnd,
                          selfClosing: false, attributes: [])
        while position < end {
            let b = bytes[position]
            if HTMLBytes.isSpace(b) { position += 1; continue }
            if b == UInt8(ascii: ">") {
                position += 1
                tag.range = start..<position
                return tag
            }
            if b == UInt8(ascii: "/") {
                position += 1
                if position < end, bytes[position] == UInt8(ascii: ">") {
                    tag.selfClosing = true
                    position += 1
                    tag.range = start..<position
                    return tag
                }
                continue
            }
            readAttribute(into: &tag)
        }
        tag.range = start..<position
        return tag
    }

    private mutating func readAttribute(into tag: inout HTMLTag) {
        var name: [UInt8] = [HTMLBytes.lower(bytes[position])]
        position += 1
        while position < end {
            let b = bytes[position]
            if HTMLBytes.isSpace(b) || b == UInt8(ascii: "/") || b == UInt8(ascii: ">") || b == UInt8(ascii: "=") { break }
            name.append(HTMLBytes.lower(b))
            position += 1
        }
        var probe = position
        while probe < end, HTMLBytes.isSpace(bytes[probe]) { probe += 1 }
        var value = ""
        if probe < end, bytes[probe] == UInt8(ascii: "=") {
            position = probe + 1
            while position < end, HTMLBytes.isSpace(bytes[position]) { position += 1 }
            if position < end, bytes[position] == UInt8(ascii: "\"") || bytes[position] == UInt8(ascii: "'") {
                let quote = bytes[position]
                let start = position + 1
                let close = bytes[start..<end].firstIndex(of: quote) ?? end
                value = String(decoding: bytes[start..<close], as: UTF8.self)
                position = min(close + 1, end)
            } else {
                let start = position
                while position < end, !HTMLBytes.isSpace(bytes[position]), bytes[position] != UInt8(ascii: ">") { position += 1 }
                value = String(decoding: bytes[start..<position], as: UTF8.self)
            }
        }
        let attributeName = String(decoding: name, as: UTF8.self)
        // A repeated attribute keeps its first value, as HTML does.
        if !tag.attributes.contains(where: { $0.name == attributeName }) {
            tag.attributes.append((attributeName, HTMLEntities.decode(value)))
        }
    }
}

/// Character references in attribute values: the numeric ones and the few named ones boards
/// write. Anything else stays as written.
enum HTMLEntities {
    static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}"]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";"), let scalar = reference(String(after[..<semi])) {
                out += scalar
                rest = after[after.index(after: semi)...]
            } else {
                out += "&"
                rest = after
            }
        }
        return out + rest
    }

    private static func reference(_ body: String) -> String? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        if body.hasPrefix("#") {
            return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        return named[body]
    }
}

// MARK: - Tree

/// Builds the element tree of a fragment with the parts of HTML's tree construction boards
/// meet, numbering each element as it is inserted (which is document order).
private struct TemplateBuilder {
    private struct Open {
        let name: String
        let tid: Int
        let path: [Int]
        let foreign: Bool
        var children = 0
    }

    private var tokenizer: HTMLTokenizer
    private var stack: [Open] = []
    private var topLevel = 0
    private var elements: [DesignTemplateElement] = []

    init(bytes: [UInt8], range: Range<Int>) {
        tokenizer = HTMLTokenizer(bytes: bytes, range: range)
    }

    mutating func build() -> [DesignTemplateElement] {
        while let tag = tokenizer.next(foreign: inForeignContent) {
            if tag.isEnd { endTag(tag.name) } else { startTag(tag) }
        }
        return elements
    }

    // MARK: Element sets

    static let void: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input",
        "keygen", "link", "meta", "param", "source", "track", "wbr",
    ]
    static let rawText: Set<String> = ["script", "style", "xmp", "iframe", "noembed", "noframes", "textarea", "title"]
    static let closesP: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p",
        "search", "section", "summary", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "listing", "form",
        "plaintext", "table", "hr", "xmp", "li", "dd", "dt",
    ]
    static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    static let impliedEnd: Set<String> = ["dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc"]
    static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body",
        "br", "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt",
        "embed", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3",
        "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li",
        "link", "listing", "main", "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript",
        "object", "ol", "p", "param", "plaintext", "pre", "script", "search", "section", "select", "source",
        "style", "summary", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "title",
        "tr", "track", "ul", "wbr", "xmp",
    ]
    static let scopeBoundary: Set<String> = ["applet", "caption", "html", "table", "td", "th", "marquee", "object", "template"]
    static let tableParts: Set<String> = ["caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"]
    static let tableSections: Set<String> = ["tbody", "thead", "tfoot"]
    /// HTML tags that end SVG or MathML content they appear in.
    static let foreignBreakout: Set<String> = [
        "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr",
        "ol", "p", "pre", "ruby", "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u",
        "ul", "var",
    ]
    /// End tags that close their element, and whatever it still holds, when it is in scope.
    static let blocks: Set<String> = [
        "address", "applet", "article", "aside", "blockquote", "button", "center", "dd", "details", "dialog",
        "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "header", "hgroup",
        "listing", "main", "marquee", "menu", "nav", "object", "ol", "pre", "search", "section", "summary", "ul",
    ]
    /// Foreign elements whose content is HTML again.
    static let integrationPoints: Set<String> = ["foreignobject", "desc", "title", "mi", "mo", "mn", "ms", "mtext", "annotation-xml"]

    // MARK: Stack queries

    private var inForeignContent: Bool {
        guard let top = stack.last else { return false }
        return top.foreign && !Self.integrationPoints.contains(top.name)
    }

    private func inScope(_ names: Set<String>, extra: Set<String> = []) -> Bool {
        for node in stack.reversed() {
            if !node.foreign, names.contains(node.name) { return true }
            if node.foreign ? Self.integrationPoints.contains(node.name) : (Self.scopeBoundary.contains(node.name) || extra.contains(node.name)) {
                return false
            }
        }
        return false
    }

    private func inTableScope(_ names: Set<String>) -> Bool {
        for node in stack.reversed() {
            if !node.foreign, names.contains(node.name) { return true }
            if !node.foreign, node.name == "table" || node.name == "template" { return false }
        }
        return false
    }

    private var top: String? { stack.last.map { $0.foreign ? "" : $0.name } }

    // MARK: Changes

    private mutating func insert(_ name: String, tag: HTMLTag? = nil, foreign: Bool = false, open: Bool = true) {
        let index: Int
        let parentPath: [Int]
        if stack.isEmpty {
            index = topLevel
            topLevel += 1
            parentPath = []
        } else {
            index = stack[stack.count - 1].children
            stack[stack.count - 1].children += 1
            parentPath = stack[stack.count - 1].path
        }
        let tid = elements.count
        elements.append(DesignTemplateElement(tid: tid, path: parentPath + [index], name: name, parent: stack.last?.tid,
                                              tagRange: tag?.range))
        if open { stack.append(Open(name: name, tid: tid, path: parentPath + [index], foreign: foreign)) }
    }

    private mutating func popUntil(_ names: Set<String>) {
        while let node = stack.popLast() {
            if !node.foreign, names.contains(node.name) { return }
        }
    }

    private mutating func generateImpliedEndTags(except name: String? = nil) {
        while let top, Self.impliedEnd.contains(top), top != name { stack.removeLast() }
    }

    private mutating func closeP() {
        guard inScope(["p"], extra: ["button"]) else { return }
        generateImpliedEndTags(except: "p")
        popUntil(["p"])
    }

    private mutating func clearTo(_ names: Set<String>) {
        while let top, !names.contains(top) { stack.removeLast() }
    }

    // MARK: Tags

    private mutating func startTag(_ tag: HTMLTag) {
        var name = tag.name
        if inForeignContent {
            if Self.foreignBreakout.contains(name)
                || (name == "font" && ["color", "face", "size"].contains(where: { tag.attribute($0) != nil })) {
                while let node = stack.last, node.foreign, !Self.integrationPoints.contains(node.name) { stack.removeLast() }
            } else {
                insert(name, tag: tag, foreign: true, open: !tag.selfClosing)
                return
            }
        }
        if name == "image" { name = "img" }
        switch name {
        case "html", "head", "body", "frameset", "frame":
            return
        case "svg", "math":
            insert(name, tag: tag, foreign: true, open: !tag.selfClosing)
            return
        default:
            break
        }

        if Self.tableParts.contains(name) {
            tableStart(name, tag: tag)
            return
        }
        if name == "table" {
            if top == "table" || top.map(Self.tableSections.contains) == true || top == "tr" {
                // A table where only rows belong ends the open one first.
                if inTableScope(["table"]) { popUntil(["table"]) }
            } else {
                closeP()
            }
            insert(name, tag: tag)
            return
        }

        switch name {
        case "li":
            for node in stack.reversed() {
                if !node.foreign, node.name == "li" {
                    generateImpliedEndTags(except: "li")
                    popUntil(["li"])
                    break
                }
                if !node.foreign, Self.special.contains(node.name), !["address", "div", "p"].contains(node.name) { break }
            }
            closeP()
        case "dd", "dt":
            for node in stack.reversed() {
                if !node.foreign, node.name == "dd" || node.name == "dt" {
                    generateImpliedEndTags(except: node.name)
                    popUntil([node.name])
                    break
                }
                if !node.foreign, Self.special.contains(node.name), !["address", "div", "p"].contains(node.name) { break }
            }
            closeP()
        case "form":
            // A form inside an open form is dropped, as HTML drops it.
            if stack.contains(where: { !$0.foreign && $0.name == "form" }) { return }
            closeP()
        case _ where Self.headings.contains(name):
            closeP()
            if let top, Self.headings.contains(top) { stack.removeLast() }
        case _ where Self.closesP.contains(name):
            closeP()
        case "a":
            if inScope(["a"]) { popUntil(["a"]) }
        case "button":
            if inScope(["button"]) {
                generateImpliedEndTags()
                popUntil(["button"])
            }
        case "option":
            if top == "option" { stack.removeLast() }
        case "optgroup":
            if top == "option" { stack.removeLast() }
        default:
            break
        }

        let isVoid = Self.void.contains(name)
        insert(name, tag: tag, open: !isVoid)
        if name == "plaintext" {
            tokenizer.skipToEnd()
        } else if Self.rawText.contains(name) {
            tokenizer.skipRawText(of: name)
        }
    }

    /// Table parts: implied `tbody` and `tr`, and cells and rows closing their open siblings.
    /// Outside any table they are ignored, as HTML ignores them in a body.
    private mutating func tableStart(_ name: String, tag: HTMLTag) {
        if inTableScope(["td", "th"]) {
            popUntil(["td", "th"])
        }
        guard inTableScope(["table"]) || top.map(Self.tableSections.contains) == true || top == "tr" else { return }
        switch name {
        case "caption", "colgroup":
            clearTo(["table", "template"])
            insert(name, tag: tag)
        case "col":
            if top != "colgroup" {
                clearTo(["table", "template"])
                insert("colgroup")
            }
            insert(name, tag: tag, open: false)
        case "tbody", "thead", "tfoot":
            clearTo(["table", "template"])
            insert(name, tag: tag)
        case "tr":
            if inTableScope(["tr"]) { popUntil(["tr"]) }
            openSection()
            insert(name, tag: tag)
        default: // td, th
            if top != "tr" {
                openSection()
                insert("tr")
            }
            insert(name, tag: tag)
        }
    }

    /// Makes a table section the current node: the open one, or a `tbody` the table implies.
    private mutating func openSection() {
        guard top.map(Self.tableSections.contains) != true else { return }
        clearTo(["table", "template"])
        insert("tbody")
    }

    private mutating func endTag(_ name: String) {
        if inForeignContent {
            for index in stack.indices.reversed() {
                let node = stack[index]
                if node.name == name {
                    stack.removeSubrange(index...)
                    return
                }
                if !node.foreign { break }
            }
        }
        switch name {
        case "html", "body", "head":
            return
        case "p":
            if !inScope(["p"], extra: ["button"]) { insert("p", open: false); return }
            generateImpliedEndTags(except: "p")
            popUntil(["p"])
        case "li":
            guard inScope(["li"], extra: ["ol", "ul"]) else { return }
            generateImpliedEndTags(except: "li")
            popUntil(["li"])
        case "br":
            insert("br", open: false)
        case _ where Self.headings.contains(name):
            guard inScope(Self.headings) else { return }
            generateImpliedEndTags()
            popUntil(Self.headings)
        case "form":
            // Only the form itself leaves the stack; what it still holds stays open.
            guard inScope(["form"]), let at = stack.lastIndex(where: { !$0.foreign && $0.name == "form" }) else { return }
            generateImpliedEndTags()
            stack.remove(at: at)
        case _ where Self.blocks.contains(name):
            guard inScope([name]) else { return }
            generateImpliedEndTags(except: name)
            popUntil([name])
        case _ where Self.tableParts.contains(name) || name == "table":
            guard inTableScope([name]) else { return }
            popUntil([name])
        default:
            for index in stack.indices.reversed() {
                let node = stack[index]
                if node.name == name {
                    generateImpliedEndTags(except: name)
                    if let at = stack.lastIndex(where: { $0.tid == node.tid }) { stack.removeSubrange(at...) }
                    return
                }
                if !node.foreign, Self.special.contains(node.name) { return }
            }
        }
    }
}
