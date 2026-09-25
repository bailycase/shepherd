import Foundation

// MARK: Markdown blocks

/// One block of agent prose. Inline Markdown (emphasis, code spans, links, strikethrough,
/// inline HTML, footnote references) stays inside each block's text for the renderer.
public enum NativeMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [NativeMarkdownListItem])
    case quote([NativeMarkdownBlock])
    /// A fenced block; `language` is the fence's info word ("swift"), when given. `$$` math
    /// blocks are fences labelled "math".
    case code(String, language: String?)
    case rule
    case table(NativeMarkdownTable)
    /// An image on its own line: `![alt](source)` or `<img>`. Never fetched by the parser.
    case image(alt: String, source: String)
    /// `<details><summary>…</summary>…</details>`: collapsed until opened.
    case details(summary: String, blocks: [NativeMarkdownBlock])
    /// The message's footnotes, gathered at its end in the order they are first referenced.
    case footnotes([NativeMarkdownFootnote])
}

public struct NativeMarkdownListItem: Equatable, Sendable {
    /// The item's first paragraph.
    public var text: String
    /// A task list item's box: `- [ ]` or `- [x]`.
    public var task: NativeMarkdownTask?
    /// Everything after the first paragraph: more paragraphs, nested lists at any depth, code.
    public var children: [NativeMarkdownBlock]

    public init(text: String, task: NativeMarkdownTask? = nil, children: [NativeMarkdownBlock] = []) {
        self.text = text
        self.task = task
        self.children = children
    }
}

public enum NativeMarkdownTask: Equatable, Sendable {
    case open, done
}

/// A GitHub-flavoured pipe table: every row padded to the same number of columns.
public struct NativeMarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable {
        case none, leading, center, trailing
    }

    public var alignments: [Alignment]
    public var header: [String]
    public var rows: [[String]]
    /// The table as the reply wrote it (its complete rows), for Copy.
    public var source: String

    public init(alignments: [Alignment], header: [String], rows: [[String]], source: String) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
        self.source = source
    }

    public var columns: Int { header.count }
}

public struct NativeMarkdownFootnote: Equatable, Sendable {
    public var number: Int
    public var text: String

    public init(number: Int, text: String) {
        self.number = number
        self.text = text
    }
}

/// Block parser for agent prose: headings, paragraphs, lists nested to any depth (task items
/// included), quotes, fenced code (and `$$` math), rules, GFM tables, images, `<details>`,
/// footnotes. Inline Markdown stays inside each block's text. Fences keep their contents
/// literal and an unclosed fence runs to the end. HTML is never rendered: `<details>` becomes a
/// disclosure, `<img>` and `<hr>` their blocks, and other block tags are stripped to their text.
public func nativeMarkdownBlocks(_ text: String) -> [NativeMarkdownBlock] {
    nativeMarkdownParse(text).blocks
}

/// `nativeMarkdownBlocks`, and whether the text ends inside a fence still open: the fenced
/// block a streaming reply is writing, the last one, whose code is still growing.
///
/// `streaming` is a reply still arriving. Its last line, when unterminated and only the start of
/// a block's marker (`|…`, `-`, `#`, `` ` ``, a delimiter row, a tag), is held back, and so is a
/// table header still waiting for its delimiter row: a table appears as a table as soon as its
/// delimiter row arrives, grows a whole row at a time, and never flickers through a paragraph.
public func nativeMarkdownParse(_ text: String, streaming: Bool = false) -> (blocks: [NativeMarkdownBlock], endsInOpenFence: Bool) {
    guard !text.isEmpty else { return ([], false) }
    // Split on the UTF-16 newline (fast, and it splits "\r\n", which is one Character).
    var lines = text.components(separatedBy: "\n").map(markdownLine)
    if streaming, let last = lines.last, nativeMarkdownPendingLine(last) { lines.removeLast() }
    let context = MarkdownContext(streaming: streaming)
    var blocks = parseBlocks(lines, context, atEnd: true)
    if !context.footnotes.isEmpty || text.contains("[^") { blocks = numberFootnotes(blocks, context.footnotes) }
    return (blocks, context.endsInOpenFence)
}

/// Whether a streaming reply's unterminated last line is only the start of a block's marker,
/// so it waits for more before it is drawn (it would draw as something else for a moment).
func nativeMarkdownPendingLine(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard let first = t.first else { return false }
    // A table row (or header) being written, or a delimiter row, a rule, a bare list marker.
    if first == "|" || t.allSatisfy({ "-:| ".contains($0) }) { return true }
    if t.allSatisfy({ $0 == "#" }) { return true }
    if t.count <= 3, t.allSatisfy({ "*+_>$".contains($0) }) { return true }
    if first == "`" || first == "~" {
        let run = t.prefix(while: { $0 == first }).count
        let rest = t.dropFirst(run)
        if run == t.count { return true }
        // A fence opening, its info word still arriving.
        if run >= 3, !rest.contains(" "), !rest.contains(first) { return true }
    }
    if first.isNumber, t.count <= 10 {
        let digits = t.last == "." || t.last == ")" ? t.dropLast() : Substring(t)
        if digits.allSatisfy(\.isNumber) { return true }
    }
    if first == "<", !t.contains(">") { return true }
    if t.hasPrefix("[^"), !t.contains("]") { return true }
    if t.hasPrefix("!["), !t.contains(")") { return true }
    return false
}

// MARK: Parsing

private final class MarkdownContext {
    let streaming: Bool
    var endsInOpenFence = false
    /// Footnote definitions in the order they were written.
    var footnotes: [(label: String, text: String)] = []

    init(streaming: Bool) { self.streaming = streaming }
}

/// A line with its carriage return dropped and leading tabs as four spaces.
private func markdownLine(_ line: String) -> String {
    var line = Substring(line)
    if line.utf8.last == UInt8(ascii: "\r") { line = line.dropLast() }
    guard line.first == "\t" else { return String(line) }
    var lead = ""
    var rest = line[...]
    while let c = rest.first, c == "\t" || c == " " {
        lead += c == "\t" ? "    " : " "
        rest = rest.dropFirst()
    }
    return lead + rest
}

private func leadingSpaces(_ line: String) -> Int { line.prefix(while: { $0 == " " }).count }

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

private func parseBlocks(_ lines: [String], _ context: MarkdownContext, atEnd: Bool) -> [NativeMarkdownBlock] {
    var blocks: [NativeMarkdownBlock] = []
    var paragraph: [String] = []
    func flush() {
        guard !paragraph.isEmpty else { return }
        blocks += paragraphBlocks(paragraph.joined(separator: "\n"))
        paragraph = []
    }
    func restIsBlank(after index: Int) -> Bool { lines[(index + 1)...].allSatisfy(\.isBlank) }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let indent = leadingSpaces(line)
        let trimmed = line.trimmed
        if trimmed.isEmpty {
            flush()
            i += 1
            continue
        }
        let block = indent < 4

        if block, let fence = MarkdownFence(trimmed) {
            flush()
            var body: [String] = []
            var next = i + 1
            var closed = false
            while next < lines.count {
                let lead = leadingSpaces(lines[next])
                // Only a line starting with the fence's character can close it.
                if lead < 4, lines[next].dropFirst(lead).first == fence.character, fence.closes(lines[next].trimmed) {
                    closed = true
                    break
                }
                body.append(lead == 0 ? lines[next] : String(lines[next].dropFirst(min(indent, lead))))
                next += 1
            }
            blocks.append(.code(body.joined(separator: "\n"), language: fence.language))
            if !closed, atEnd { context.endsInOpenFence = true }
            i = closed ? next + 1 : next
            continue
        }
        if block, trimmed.hasPrefix("$$") {
            let rest = trimmed.dropFirst(2)
            if rest.count >= 2, rest.hasSuffix("$$") {
                flush()
                blocks.append(.code(String(rest.dropLast(2)).trimmed, language: "math"))
                i += 1
                continue
            }
            if rest.allSatisfy(\.isWhitespace) {
                flush()
                var body: [String] = []
                var next = i + 1
                var closed = false
                while next < lines.count {
                    if lines[next].trimmed.hasSuffix("$$") {
                        let last = String(lines[next].trimmed.dropLast(2))
                        if !last.trimmed.isEmpty { body.append(last) }
                        closed = true
                        break
                    }
                    body.append(lines[next].trimmed)
                    next += 1
                }
                blocks.append(.code(body.joined(separator: "\n"), language: "math"))
                i = closed ? next + 1 : next
                continue
            }
        }
        if block, trimmed.first == "<", trimmed.lowercased().hasPrefix("<details") {
            flush()
            let (details, next) = parseDetails(lines, from: i, context, atEnd: atEnd)
            blocks.append(details)
            i = next
            continue
        }
        if block, trimmed.hasPrefix("<!--") {
            flush()
            var next = i
            while next < lines.count, !lines[next].contains("-->") { next += 1 }
            i = next + 1
            continue
        }
        if block, let definition = footnoteDefinition(trimmed) {
            flush()
            var text = [definition.text]
            var next = i + 1
            while next < lines.count {
                let candidate = lines[next]
                if candidate.isBlank {
                    // A blank line continues the note only when an indented line follows.
                    if next + 1 < lines.count, leadingSpaces(lines[next + 1]) >= 2, !lines[next + 1].isBlank {
                        text.append("")
                        next += 1
                        continue
                    }
                    break
                }
                let t = candidate.trimmed
                if leadingSpaces(candidate) < 2, startsBlock(t) || text.last == "" { break }
                text.append(t)
                next += 1
            }
            context.footnotes.append((definition.label, text.joined(separator: "\n")))
            i = next
            continue
        }
        if block, isRule(trimmed) {
            flush()
            blocks.append(.rule)
            i += 1
            continue
        }
        if block, let heading = atxHeading(trimmed) {
            flush()
            blocks.append(heading)
            i += 1
            continue
        }
        if block, trimmed.utf8.contains(UInt8(ascii: "|")) {
            if i + 1 < lines.count, let table = parseTable(lines, header: i) {
                flush()
                blocks.append(.table(table.table))
                i = table.next
                continue
            }
            // A header still waiting for its delimiter row: held, never drawn as a paragraph.
            if context.streaming, atEnd, trimmed.hasPrefix("|"), restIsBlank(after: i) {
                flush()
                i += 1
                continue
            }
        }
        if block, trimmed.hasPrefix(">") {
            flush()
            var inner: [String] = []
            var next = i
            while next < lines.count {
                let t = lines[next].trimmed
                if t.hasPrefix(">") {
                    var rest = t.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    next += 1
                    continue
                }
                // A lazy line continues the quote's paragraph.
                if !t.isEmpty, let last = inner.last, !last.isBlank, !startsBlock(t) {
                    inner.append(t)
                    next += 1
                    continue
                }
                break
            }
            blocks.append(.quote(parseBlocks(inner, context, atEnd: atEnd && restIsBlank(after: next - 1))))
            i = next
            continue
        }
        if block, let marker = ListMarker(line) {
            flush()
            let (list, next) = parseList(lines, from: i, marker, context, atEnd: atEnd)
            blocks.append(list)
            i = next
            continue
        }
        if trimmed.hasPrefix("<"), let html = htmlBlockLine(trimmed) {
            switch html {
            case .rule:
                flush()
                blocks.append(.rule)
            case .image(let alt, let source):
                flush()
                blocks.append(.image(alt: alt, source: source))
            case .heading(let level, let text):
                flush()
                blocks.append(.heading(level: level, text: text))
            case .text(let text):
                if text.isEmpty { flush() } else { paragraph.append(text) }
            }
            i += 1
            continue
        }
        paragraph.append(trimmed)
        i += 1
    }
    flush()
    return blocks
}

/// A paragraph, or the images it holds when it is nothing but images.
private func paragraphBlocks(_ text: String) -> [NativeMarkdownBlock] {
    if text.hasPrefix("!["), let images = onlyImages(text) {
        return images.map { .image(alt: $0.alt, source: $0.source) }
    }
    return [.paragraph(text)]
}

/// `![alt](source "title")`, one or more, and nothing else.
private func onlyImages(_ text: String) -> [(alt: String, source: String)]? {
    var images: [(alt: String, source: String)] = []
    var rest = Substring(text)
    while true {
        rest = rest.drop(while: \.isWhitespace)
        if rest.isEmpty { return images.isEmpty ? nil : images }
        guard rest.hasPrefix("!["), let close = rest.firstIndex(of: "]") else { return nil }
        let alt = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
        rest = rest[rest.index(after: close)...]
        guard rest.first == "(", let end = rest.firstIndex(of: ")") else { return nil }
        let inside = rest[rest.index(after: rest.startIndex)..<end].trimmingCharacters(in: .whitespaces)
        // `<a path with spaces>`, or the first word before an optional "title".
        let source = inside.hasPrefix("<") ? String(inside.dropFirst().prefix(while: { $0 != ">" }))
            : inside.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard !source.isEmpty else { return nil }
        images.append((String(alt), source))
        rest = rest[rest.index(after: end)...]
    }
}

/// Whether a line opens a block that ends a paragraph (or a lazy continuation).
private func startsBlock(_ trimmed: String) -> Bool {
    // Most lines (prose, table rows) start with none of the markers: skip the checks.
    guard let first = trimmed.first, first.isNumber || "`~>#-*_+<[$".contains(first) else { return false }
    return MarkdownFence(trimmed) != nil || trimmed.hasPrefix(">") || atxHeading(trimmed) != nil || isRule(trimmed)
        || ListMarker(trimmed) != nil || trimmed.lowercased().hasPrefix("<details") || footnoteDefinition(trimmed) != nil
        || trimmed.hasPrefix("$$")
}

private func isRule(_ trimmed: String) -> Bool {
    guard let first = trimmed.first, "-*_".contains(first) else { return false }
    var count = 0
    for c in trimmed {
        if c == first { count += 1 } else if c != " " { return false }
    }
    return count >= 3
}

private func atxHeading(_ trimmed: String) -> NativeMarkdownBlock? {
    let hashes = trimmed.prefix(while: { $0 == "#" }).count
    guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
    var text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
    // A closing sequence: "## Title ##".
    if let space = text.lastIndex(of: " "), text[text.index(after: space)...].allSatisfy({ $0 == "#" }) {
        text = String(text[..<space]).trimmed
    } else if text.allSatisfy({ $0 == "#" }) {
        text = ""
    }
    return text.isEmpty ? nil : .heading(level: hashes, text: text)
}

private struct MarkdownFence {
    let character: Character
    let count: Int
    let language: String?

    init?(_ trimmed: String) {
        guard let c = trimmed.first, c == "`" || c == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == c }).count
        guard run >= 3 else { return nil }
        let info = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        character = c
        count = run
        let word = info.split(separator: " ").first.map(String.init)
        language = word?.isEmpty == false ? word : nil
    }

    func closes(_ trimmed: String) -> Bool {
        let run = trimmed.prefix(while: { $0 == character }).count
        return run >= count && run == trimmed.count
    }
}

private func footnoteDefinition(_ trimmed: String) -> (label: String, text: String)? {
    guard trimmed.hasPrefix("[^"), let close = trimmed.firstIndex(of: "]") else { return nil }
    let label = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close]
    guard !label.isEmpty, !label.contains(" "), trimmed[close...].dropFirst().first == ":" else { return nil }
    return (String(label), String(trimmed[close...].dropFirst(2)).trimmed)
}

// MARK: Lists

/// "- item", "* item", "+ item", "3. item", "3) item": the marker's kind, number, where its
/// content starts, and the content.
private struct ListMarker {
    let indent: Int
    let ordered: Bool
    let number: Int
    /// The column the item's content starts at.
    let contentIndent: Int
    let text: String

    init?(_ line: String) {
        let indent = leadingSpaces(line)
        let rest = line.dropFirst(indent)
        var width: Int
        var ordered = false
        var number = 1
        if let first = rest.first, "-*+".contains(first) {
            width = 1
        } else {
            let digits = rest.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9, let value = Int(digits) else { return nil }
            let punct = rest.dropFirst(digits.count).first
            guard punct == "." || punct == ")" else { return nil }
            width = digits.count + 1
            ordered = true
            number = value
        }
        let after = rest.dropFirst(width)
        guard after.first == " " else { return nil }
        var spaces = after.prefix(while: { $0 == " " }).count
        let text = after.dropFirst(spaces)
        if spaces > 4 || text.isEmpty { spaces = 1 }
        self.indent = indent
        self.ordered = ordered
        self.number = number
        contentIndent = indent + width + spaces
        self.text = text.trimmingCharacters(in: .whitespaces)
    }
}

private func parseList(_ lines: [String], from start: Int, _ first: ListMarker, _ context: MarkdownContext,
                       atEnd: Bool) -> (NativeMarkdownBlock, Int) {
    var items: [NativeMarkdownListItem] = []
    var marker = first
    var index = start
    while true {
        // Lines indented past the marker belong to the item: two spaces nest, as agents write.
        let threshold = min(marker.contentIndent, marker.indent + 2)
        var itemLines = [marker.text]
        var next = index + 1
        var end = next
        var blank = false
        while next < lines.count {
            let line = lines[next]
            let trimmed = line.trimmed
            if trimmed.isEmpty {
                itemLines.append("")
                blank = true
                next += 1
                continue
            }
            let indent = leadingSpaces(line)
            if indent >= threshold {
                itemLines.append(String(line.dropFirst(min(indent, marker.contentIndent))))
                blank = false
                next += 1
                end = next
                continue
            }
            if blank || startsBlock(trimmed) { break }
            // A lazy line continues the item's paragraph.
            itemLines.append(trimmed)
            next += 1
            end = next
        }
        // Blank lines after the item's last line are the list's, not the item's.
        itemLines.removeLast(next - end)
        let itemAtEnd = atEnd && lines[end...].allSatisfy(\.isBlank)
        items.append(listItem(parseBlocks(itemLines, context, atEnd: itemAtEnd)))

        var sibling = end
        while sibling < lines.count, lines[sibling].isBlank { sibling += 1 }
        guard sibling < lines.count, let following = ListMarker(lines[sibling]), following.ordered == first.ordered,
              following.indent < threshold, !isRule(lines[sibling].trimmed) else {
            return (.list(ordered: first.ordered, start: first.number, items: items), end)
        }
        marker = following
        index = sibling
    }
}

/// An item from its blocks: the first paragraph is its text, and a leading `[ ]` or `[x]` its
/// task box.
private func listItem(_ blocks: [NativeMarkdownBlock]) -> NativeMarkdownListItem {
    guard case .paragraph(var text)? = blocks.first else { return NativeMarkdownListItem(text: "", children: blocks) }
    var task: NativeMarkdownTask?
    for (box, state) in [("[ ]", NativeMarkdownTask.open), ("[x]", .done), ("[X]", .done)] where text.hasPrefix(box) {
        let rest = text.dropFirst(box.count)
        guard rest.isEmpty || rest.first == " " || rest.first == "\n" else { continue }
        task = state
        text = String(rest.drop(while: { $0 == " " }))
    }
    return NativeMarkdownListItem(text: text, task: task, children: Array(blocks.dropFirst()))
}

// MARK: Tables

private func parseTable(_ lines: [String], header index: Int) -> (table: NativeMarkdownTable, next: Int)? {
    let headerLine = lines[index].trimmed
    let delimiterLine = lines[index + 1].trimmed
    let header = tableCells(headerLine)
    guard let alignments = delimiterRow(delimiterLine),
          alignments.count == header.count || delimiterLine.contains("|") else { return nil }
    var rows: [[String]] = []
    var source = [headerLine, delimiterLine]
    var next = index + 2
    while next < lines.count {
        let trimmed = lines[next].trimmed
        guard !trimmed.isEmpty, trimmed.utf8.contains(UInt8(ascii: "|")), !startsBlock(trimmed) else { break }
        rows.append(tableCells(trimmed))
        source.append(trimmed)
        next += 1
    }
    // Uneven rows are padded, never dropped: every cell the reply wrote is kept.
    let columns = max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
    func padded<T>(_ values: [T], _ filler: T) -> [T] { values + Array(repeating: filler, count: columns - values.count) }
    let table = NativeMarkdownTable(alignments: padded(alignments, .none), header: padded(header, ""),
                                    rows: rows.map { padded($0, "") }, source: source.joined(separator: "\n"))
    return (table, next)
}

/// `|:--|:-:|--:|`: each column's alignment, or nil when the line is not a delimiter row.
private func delimiterRow(_ trimmed: String) -> [NativeMarkdownTable.Alignment]? {
    guard trimmed.contains("-"), trimmed.allSatisfy({ "-:| ".contains($0) }) else { return nil }
    var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    if cells.first?.isEmpty == true { cells.removeFirst() }
    if cells.last?.isEmpty == true { cells.removeLast() }
    guard !cells.isEmpty else { return nil }
    var alignments: [NativeMarkdownTable.Alignment] = []
    for cell in cells {
        let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): alignments.append(.center)
        case (true, false): alignments.append(.leading)
        case (false, true): alignments.append(.trailing)
        case (false, false): alignments.append(.none)
        }
    }
    return alignments
}

/// A row's cells: split on pipes that are not escaped (`\|`) and not inside a code span; an
/// escaped pipe inside a code span reads as a pipe, as GitHub draws it. Scans bytes: every
/// character it splits on is ASCII.
private func tableCells(_ trimmed: String) -> [String] {
    let bytes = Array(trimmed.utf8)
    let pipe = UInt8(ascii: "|"), backslash = UInt8(ascii: "\\"), backtick = UInt8(ascii: "`")
    var cells: [String] = []
    var cell: [UInt8] = []
    var index = bytes.first == pipe ? 1 : 0
    var trailingPipe = false
    func close() {
        cells.append(String(decoding: cell, as: UTF8.self).trimmingCharacters(in: .whitespaces))
        cell = []
    }
    while index < bytes.count {
        let byte = bytes[index]
        if byte == backslash, index + 1 < bytes.count, bytes[index + 1] == pipe {
            cell += [backslash, pipe]
            index += 2
            continue
        }
        if byte == backtick {
            let run = bytes[index...].prefix(while: { $0 == backtick }).count
            if let close = closingBackticks(bytes, from: index + run, run: run, tick: backtick) {
                var code = Array(bytes[index..<(close + run)])
                // `a \| b` inside code reads `a | b`.
                var at = 0
                while at + 1 < code.count {
                    if code[at] == backslash, code[at + 1] == pipe { code.remove(at: at) }
                    at += 1
                }
                cell += code
                index = close + run
                continue
            }
            cell += Array(repeating: backtick, count: run)
            index += run
            continue
        }
        if byte == pipe {
            close()
            index += 1
            trailingPipe = index == bytes.count
            continue
        }
        cell.append(byte)
        index += 1
    }
    let rest = String(decoding: cell, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    if !trailingPipe || !rest.isEmpty { cells.append(rest) }
    return cells
}

/// Where a code span opened by `run` backticks closes: the next run of exactly that length.
private func closingBackticks<T: Equatable>(_ characters: [T], from start: Int, run: Int, tick: T) -> Int? {
    var index = start
    while index < characters.count {
        guard characters[index] == tick else { index += 1; continue }
        let length = characters[index...].prefix(while: { $0 == tick }).count
        if length == run { return index }
        index += length
    }
    return nil
}

// MARK: HTML

private enum HTMLLine {
    case rule
    case image(alt: String, source: String)
    case heading(Int, String)
    /// The line's text with its block tags stripped (empty ends the paragraph). Inline tags
    /// stay for the renderer.
    case text(String)
}

/// Tags whose markup is dropped from a block line, keeping their text.
private let htmlBlockTags: Set<String> = [
    "p", "div", "center", "section", "article", "header", "footer", "main", "nav", "aside", "figure", "figcaption",
    "table", "thead", "tbody", "tfoot", "tr", "td", "th", "ul", "ol", "li", "dl", "dt", "dd", "picture", "source",
    "blockquote", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "img", "br", "span", "font", "summary", "details",
    "video", "audio",
]

private func htmlBlockLine(_ trimmed: String) -> HTMLLine? {
    guard let name = htmlTagName(trimmed[...]), htmlBlockTags.contains(name) else { return nil }
    if name == "hr" { return .rule }
    var stripped = ""
    var rest = Substring(trimmed)
    while let open = rest.firstIndex(of: "<") {
        stripped += rest[..<open]
        let tag = rest[open...]
        guard let close = tag.firstIndex(of: ">") else { stripped += tag; rest = ""; break }
        let whole = tag[...close]
        if let tagName = htmlTagName(whole), htmlBlockTags.contains(tagName), tagName != "img", tagName != "br" {
            if tagName == "li", !whole.hasPrefix("</") { stripped += "• " }
        } else {
            stripped += whole
        }
        rest = tag[tag.index(after: close)...]
    }
    stripped += rest
    stripped = stripped.trimmed
    if stripped.lowercased().hasPrefix("<img"), stripped.hasSuffix(">"), stripped.filter({ $0 == "<" }).count == 1,
       let source = htmlAttribute("src", in: stripped) {
        return .image(alt: htmlAttribute("alt", in: stripped) ?? "", source: source)
    }
    if name.count == 2, name.first == "h", let level = Int(String(name.last!)), !stripped.isEmpty {
        return .heading(level, stripped)
    }
    if ["<br>", "<br/>", "<br />"].contains(stripped.lowercased()) { return .text("") }
    return .text(stripped)
}

/// "div" for `<div class="x">` or `</div>`, nil when the text does not start with a tag.
private func htmlTagName(_ text: Substring) -> String? {
    guard text.first == "<" else { return nil }
    var rest = text.dropFirst()
    if rest.first == "/" { rest = rest.dropFirst() }
    let name = rest.prefix(while: { $0.isLetter || $0.isNumber })
    guard !name.isEmpty, name.first!.isLetter else { return nil }
    let after = rest.dropFirst(name.count).first
    guard after == nil || after == ">" || after == " " || after == "/" || after == "\t" else { return nil }
    return name.lowercased()
}

/// An attribute's value in a tag: `src="a.png"`, `src='a.png'`, or `src=a.png`.
private func htmlAttribute(_ name: String, in tag: String) -> String? {
    let lower = tag.lowercased()
    var searchStart = lower.startIndex
    while let range = lower.range(of: name + "=", range: searchStart..<lower.endIndex) {
        searchStart = range.upperBound
        // Only a whole attribute name: "src" never matches inside "data-src".
        if range.lowerBound > lower.startIndex, !lower[lower.index(before: range.lowerBound)].isWhitespace { continue }
        let value = tag[range.upperBound...]
        if let quote = value.first, quote == "\"" || quote == "'" {
            return value.dropFirst().prefix(while: { $0 != quote }).description
        }
        return value.prefix(while: { !$0.isWhitespace && $0 != ">" }).description
    }
    return nil
}

private func parseDetails(_ lines: [String], from start: Int, _ context: MarkdownContext,
                          atEnd: Bool) -> (NativeMarkdownBlock, Int) {
    var depth = 0
    var next = start
    var raw: [String] = []
    var closed = false
    while next < lines.count {
        let lower = lines[next].lowercased()
        depth += lower.components(separatedBy: "<details").count - 1
        depth -= lower.components(separatedBy: "</details>").count - 1
        raw.append(lines[next])
        next += 1
        if depth <= 0 { closed = true; break }
    }
    var body = raw.joined(separator: "\n")
    // The opening tag, and the closing one when it has arrived.
    if let open = body.range(of: "<details", options: .caseInsensitive),
       let end = body[open.upperBound...].firstIndex(of: ">") {
        body.removeSubrange(open.lowerBound...end)
    }
    if closed, let close = body.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
        body.removeSubrange(close)
    }
    var summary = "Details"
    if let open = body.range(of: "<summary", options: .caseInsensitive),
       let openEnd = body[open.upperBound...].firstIndex(of: ">") {
        let after = body.index(after: openEnd)
        if let close = body.range(of: "</summary>", options: .caseInsensitive, range: after..<body.endIndex) {
            let text = body[after..<close.lowerBound].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ").trimmed
            if !text.isEmpty { summary = text }
            body.removeSubrange(open.lowerBound..<close.upperBound)
        } else {
            // The summary is still arriving: nothing of the body yet.
            body = ""
        }
    }
    let inner = body.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    let blocks = parseBlocks(inner, context, atEnd: atEnd && !closed)
    return (.details(summary: summary, blocks: blocks), next)
}

// MARK: Footnotes

/// References to defined notes become `[^1]`, `[^2]`, … in the order they are first cited;
/// references to undefined notes are escaped, so they read as written. The notes follow the
/// message's last block.
private func numberFootnotes(_ blocks: [NativeMarkdownBlock], _ definitions: [(label: String, text: String)]) -> [NativeMarkdownBlock] {
    var defined: [String: String] = [:]
    for definition in definitions where defined[definition.label] == nil { defined[definition.label] = definition.text }
    var numbers: [String: Int] = [:]
    var order: [String] = []

    func rewrite(_ text: String) -> String {
        guard text.contains("[^") else { return text }
        return outsideCodeSpans(text) { segment in
            var result = ""
            var rest = segment[...]
            while let open = rest.range(of: "[^") {
                let label = rest[open.upperBound...].prefix(while: { $0 != "]" && $0 != " " && $0 != "[" })
                let closeIndex = rest.index(open.upperBound, offsetBy: label.count)
                let escaped = open.lowerBound > rest.startIndex && rest[rest.index(before: open.lowerBound)] == "\\"
                guard !label.isEmpty, closeIndex < rest.endIndex, rest[closeIndex] == "]", !escaped else {
                    result += rest[..<open.upperBound]
                    rest = rest[open.upperBound...]
                    continue
                }
                result += rest[..<open.lowerBound]
                if defined[String(label)] != nil {
                    let number = numbers[String(label)] ?? {
                        order.append(String(label))
                        numbers[String(label)] = order.count
                        return order.count
                    }()
                    result += "[^\(number)]"
                } else {
                    result += "\\[^\(label)]"
                }
                rest = rest[rest.index(after: closeIndex)...]
            }
            return result + rest
        }
    }

    var result = blocks.map { $0.mappingText(rewrite) }
    for definition in definitions where numbers[definition.label] == nil {
        order.append(definition.label)
        numbers[definition.label] = order.count
    }
    if !order.isEmpty {
        result.append(.footnotes(order.map { NativeMarkdownFootnote(number: numbers[$0]!, text: rewrite(defined[$0] ?? "")) }))
    }
    return result
}

/// `text` with `transform` applied to everything outside its code spans.
private func outsideCodeSpans(_ text: String, _ transform: (String) -> String) -> String {
    guard text.contains("`") else { return transform(text) }
    let characters = Array(text)
    var result = ""
    var plain = ""
    var index = 0
    while index < characters.count {
        if characters[index] == "`" {
            let run = characters[index...].prefix(while: { $0 == "`" }).count
            if let close = closingBackticks(characters, from: index + run, run: run, tick: Character("`")) {
                result += transform(plain) + String(characters[index..<(close + run)])
                plain = ""
                index = close + run
                continue
            }
            plain += String(repeating: "`", count: run)
            index += run
            continue
        }
        plain.append(characters[index])
        index += 1
    }
    return result + transform(plain)
}

extension NativeMarkdownBlock {
    /// The block with `transform` applied to all of its inline text (not code).
    func mappingText(_ transform: (String) -> String) -> NativeMarkdownBlock {
        switch self {
        case .heading(let level, let text):
            return .heading(level: level, text: transform(text))
        case .paragraph(let text):
            return .paragraph(transform(text))
        case .list(let ordered, let start, let items):
            return .list(ordered: ordered, start: start, items: items.map {
                NativeMarkdownListItem(text: transform($0.text), task: $0.task, children: $0.children.map { $0.mappingText(transform) })
            })
        case .quote(let blocks):
            return .quote(blocks.map { $0.mappingText(transform) })
        case .code, .rule, .image:
            return self
        case .table(var table):
            table.header = table.header.map(transform)
            table.rows = table.rows.map { $0.map(transform) }
            return .table(table)
        case .details(let summary, let blocks):
            return .details(summary: transform(summary), blocks: blocks.map { $0.mappingText(transform) })
        case .footnotes(let notes):
            return .footnotes(notes.map { NativeMarkdownFootnote(number: $0.number, text: transform($0.text)) })
        }
    }
}
