import SwiftUI

/// Inline Markdown in agent prose, styled once per text (and text scale), shared by the Mac and
/// iOS threads:
///
/// - code spans in mono 12 on `lineSubtle`; links, bare URLs and autolinks in `running`
/// - `~~strikethrough~~` struck through
/// - footnote references (`[^1]`) as superscript numbers in `running`
/// - an inline image (`![alt](src)`) as its alt text: a link for a web image, never fetched
/// - inline HTML never raw: `<br>` breaks the line, `<kbd>` is a keycap (`ui` on `bgSelected`),
///   `<b>`, `<i>`, `<s>`, `<code>`, `<sup>`, `<sub>` and `<a href>` style their text, other
///   HTML tags are dropped, and anything that only looks like a tag (`Array<Int>`) stays text
@MainActor
public enum NWProseInline {
    private struct Key: Hashable {
        var text: String
        var scale: CGFloat
    }

    private static var cache: [Key: AttributedString] = [:]

    /// `text` styled, from the cache when it was styled before at this text scale.
    public static func attributed(_ text: String) -> AttributedString {
        let key = Key(text: text, scale: ThemeStore.shared.textScale)
        if let cached = cache[key] { return cached }
        let value = styled(text)
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    /// The footnote references' link scheme, inside this styler only.
    private static let footnoteScheme = "nw-footnote"

    /// `text` styled, uncached.
    static func styled(_ text: String) -> AttributedString {
        let source = text.contains("[^") ? footnoteLinks(text) : text
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        let nw = Color.nw
        var result = AttributedString()
        var open: [HTMLTag] = []
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            var intent = run.inlinePresentationIntent ?? []
            if intent.contains(.inlineHTML) {
                let raw = String(piece.characters)
                if let tag = HTMLTag(raw) {
                    switch tag.name {
                    case "br":
                        result += AttributedString("\n")
                    case "img":
                        if let alt = tag.attribute("alt"), !alt.isEmpty {
                            var image = AttributedString(alt)
                            image.foregroundColor = nw.running
                            if let src = tag.attribute("src"), let url = URL(string: src), ["http", "https"].contains(url.scheme ?? "") {
                                image.link = url
                            }
                            result += image
                        }
                    default:
                        if tag.closing {
                            if let index = open.lastIndex(where: { $0.name == tag.name }) { open.remove(at: index) }
                        } else if HTMLTag.styling.contains(tag.name) {
                            open.append(tag)
                        }
                    }
                    continue
                }
                // Not HTML after all: its text as written.
                intent.remove(.inlineHTML)
                piece.inlinePresentationIntent = intent.isEmpty ? nil : intent
            }
            style(&piece, intent: intent, run: run, open: open)
            result += piece
        }
        return result
    }

    private static func style(_ piece: inout AttributedString, intent: InlinePresentationIntent,
                              run: AttributedString.Runs.Run, open: [HTMLTag]) {
        let nw = Color.nw
        var intent = intent
        for tag in open {
            switch tag.name {
            case "b", "strong": intent.insert(.stronglyEmphasized)
            case "i", "em", "cite", "var": intent.insert(.emphasized)
            case "s", "del", "strike": intent.insert(.strikethrough)
            case "code", "tt", "samp": intent.insert(.code)
            case "a":
                if let href = tag.attribute("href"), let url = URL(string: href) { piece.link = url }
            default: break
            }
        }
        if intent != (run.inlinePresentationIntent ?? []) { piece.inlinePresentationIntent = intent }
        if intent.contains(.code) {
            piece.font = Font.nw(.code)
            piece.backgroundColor = nw.lineSubtle
        }
        if intent.contains(.strikethrough) {
            piece.strikethroughStyle = .single
        }
        if let url = run.imageURL {
            // An inline image reads as its alt text; only a web image is a link.
            piece.foregroundColor = nw.running
            if ["http", "https"].contains(url.scheme ?? "") { piece.link = url }
        }
        if let url = piece.link {
            if url.scheme == footnoteScheme {
                piece.link = nil
                piece.font = Font.nw(.micro)
                piece.baselineOffset = NWTextStyle.body.size * 0.35
                piece.foregroundColor = nw.running
            } else {
                piece.foregroundColor = nw.running
            }
        }
        for tag in open {
            switch tag.name {
            case "kbd":
                piece.font = Font.nw(.ui)
                piece.foregroundColor = nw.textPrimary
                piece.backgroundColor = nw.bgSelected
            case "sup":
                piece.font = Font.nw(.caption)
                piece.baselineOffset = NWTextStyle.body.size * 0.35
            case "sub":
                piece.font = Font.nw(.caption)
                piece.baselineOffset = -NWTextStyle.body.size * 0.2
            case "mark":
                piece.backgroundColor = nw.lanternTint
            case "u", "ins":
                piece.underlineStyle = .single
            default: break
            }
        }
    }

    /// `[^2]` → a link the styler draws as a superscript "2", outside code spans and unless
    /// escaped (`\[^x]` reads as written).
    private static func footnoteLinks(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inCode: Int?
        while index < text.endIndex {
            let c = text[index]
            if c == "`" {
                let run = text[index...].prefix(while: { $0 == "`" }).count
                if inCode == run { inCode = nil } else if inCode == nil { inCode = run }
                result += String(repeating: "`", count: run)
                index = text.index(index, offsetBy: run)
                continue
            }
            if c == "\\", inCode == nil, text.index(after: index) < text.endIndex {
                result.append(c)
                result.append(text[text.index(after: index)])
                index = text.index(index, offsetBy: 2)
                continue
            }
            if inCode == nil, text[index...].hasPrefix("[^") {
                let digits = text[text.index(index, offsetBy: 2)...].prefix(while: \.isNumber)
                let close = text.index(index, offsetBy: 2 + digits.count)
                if !digits.isEmpty, close < text.endIndex, text[close] == "]" {
                    result += "[\(digits)](\(footnoteScheme):\(digits))"
                    index = text.index(after: close)
                    continue
                }
            }
            result.append(c)
            index = text.index(after: index)
        }
        return result
    }
}

/// An inline HTML tag the styler understands.
struct HTMLTag {
    /// Tags that style the text up to their closing tag.
    static let styling: Set<String> = [
        "b", "strong", "i", "em", "cite", "var", "s", "del", "strike", "code", "tt", "samp", "kbd", "sup", "sub", "a", "mark",
        "u", "ins",
    ]
    /// Tags dropped without a trace; their text stays.
    static let known: Set<String> = styling.union([
        "br", "img", "span", "small", "big", "abbr", "font", "q", "p", "div", "center", "wbr", "summary", "details",
    ])

    let name: String
    let closing: Bool
    private let raw: String

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), trimmed.hasSuffix(">") else { return nil }
        var rest = trimmed.dropFirst()
        closing = rest.first == "/"
        if closing { rest = rest.dropFirst() }
        let name = rest.prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
        guard HTMLTag.known.contains(name) else { return nil }
        self.name = name
        self.raw = trimmed
    }

    /// `href="…"`, `alt='…'`, or `src=…`.
    func attribute(_ name: String) -> String? {
        var start = raw.startIndex
        while let range = raw.range(of: name + "=", options: .caseInsensitive, range: start..<raw.endIndex) {
            start = range.upperBound
            if range.lowerBound > raw.startIndex, !raw[raw.index(before: range.lowerBound)].isWhitespace { continue }
            let value = raw[range.upperBound...]
            if let quote = value.first, quote == "\"" || quote == "'" {
                return String(value.dropFirst().prefix(while: { $0 != quote }))
            }
            return String(value.prefix(while: { !$0.isWhitespace && $0 != ">" }))
        }
        return nil
    }
}
