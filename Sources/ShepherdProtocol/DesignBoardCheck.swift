import Foundation

/// The checks a board's source passes before it is written (docs/designs.md › Writing a board).
/// A refusal names what to fix; a warning is passed back with the write.
public enum DesignBoardCheck {
    /// A board written through the extension socket travels in one frame, capped at 1 MiB.
    public static let maxBytes = 900_000
    /// The head line every board keeps exactly: Shepherd serves its own runtime at that path.
    public static let supportScript = #"<script src="./support.js"></script>"#

    public enum Refusal: Error, Hashable, Sendable, CustomStringConvertible {
        case tooLarge(bytes: Int)
        case missingSupportScript
        case missingTemplate
        case forbiddenTag(String)
        case dataURI
        case sizeMismatch(root: Size, preview: Size)

        public var code: String {
            switch self {
            case .tooLarge: return "board_too_large"
            case .missingSupportScript: return "missing_support_script"
            case .missingTemplate: return "missing_template"
            case .forbiddenTag: return "forbidden_tag"
            case .dataURI: return "data_uri"
            case .sizeMismatch: return "size_mismatch"
            }
        }

        public var description: String {
            switch self {
            case .tooLarge(let bytes):
                return "the board is \(bytes) bytes; a board is at most \(DesignBoardCheck.maxBytes)"
            case .missingSupportScript:
                return "keep the head line \(DesignBoardCheck.supportScript) exactly"
            case .missingTemplate:
                return "the board's markup goes between <x-dc> and </x-dc>"
            case .forbiddenTag(let tag):
                return "boards never hold <\(tag)>"
            case .dataURI:
                return "boards never hold data: URIs; upload the file and use its /_blob/ url"
            case .sizeMismatch(let root, let preview):
                return "the root element is \(root) but $preview is \(preview); they match the board's w and h"
            }
        }
    }

    public struct Size: Hashable, Sendable, CustomStringConvertible {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }

        public var description: String { "\(Self.format(width))×\(Self.format(height))" }

        private static func format(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }
    }

    /// What passed but is worth fixing.
    public enum Warning: String, Hashable, Sendable, Codable {
        /// UI built by script instead of markup.
        case innerHTML = "inner_html"
        /// A keydown or keyup handler on the window or document.
        case globalKeyHandler = "global_key_handler"
        /// No `$preview` in `data-props`, so the size can't be checked.
        case missingPreview = "missing_preview"
    }

    /// Checks `source`, throwing the first refusal, and returns the warnings.
    public static func check(_ source: String) throws(Refusal) -> [Warning] {
        let count = source.utf8.count
        guard count <= maxBytes else { throw .tooLarge(bytes: count) }
        guard source.contains(supportScript) else { throw .missingSupportScript }
        let lowered = source.utf8.map(HTMLBytes.lower)
        for tag in ["iframe", "object", "embed"] where containsTag(tag, in: lowered) {
            throw .forbiddenTag(tag)
        }
        if containsDataURI(lowered) { throw .dataURI }
        guard let template = DesignTemplate(board: source) else { throw .missingTemplate }
        var warnings: [Warning] = []
        let preview = previewSize(of: source)
        if let preview, let root = rootSize(of: source, template: template), root != preview {
            throw .sizeMismatch(root: root, preview: preview)
        }
        if preview == nil { warnings.append(.missingPreview) }
        if !occurrences(of: "innerhtml", in: lowered).isEmpty { warnings.append(.innerHTML) }
        if hasGlobalKeyHandler(lowered) { warnings.append(.globalKeyHandler) }
        return warnings
    }

    /// Where `needle` (lower-case ASCII) starts in `bytes`.
    static func occurrences(of needle: String, in bytes: [UInt8]) -> [Int] {
        let needle = Array(needle.utf8)
        guard let first = needle.first, bytes.count >= needle.count else { return [] }
        var found: [Int] = []
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            guard let at = bytes[i...last].firstIndex(of: first) else { break }
            if bytes[at..<(at + needle.count)].elementsEqual(needle) { found.append(at) }
            i = at + 1
        }
        return found
    }

    /// `<tag` followed by a space, `>` or `/`: a tag, not a word that starts the same.
    static func containsTag(_ tag: String, in lowered: [UInt8]) -> Bool {
        let length = tag.utf8.count + 1
        return occurrences(of: "<" + tag, in: lowered).contains { at in
            let next = at + length
            return next >= lowered.count || HTMLBytes.isSpace(lowered[next]) || lowered[next] == UInt8(ascii: ">")
                || lowered[next] == UInt8(ascii: "/")
        }
    }

    /// Attributes (and script properties) that take a URL.
    static let urlAttributes: Set<String> = ["src", "href", "srcset", "poster", "action", "formaction", "xlink:href", "background", "data"]

    /// A `data:` URI where a URL goes: a URL attribute's value (or a script setting one), a CSS
    /// `url(…)` or an `@import`. A `data:` elsewhere in script or text (an object key) is not one.
    static func containsDataURI(_ lowered: [UInt8]) -> Bool {
        for at in occurrences(of: "data:", in: lowered) {
            var j = at - 1
            func skipSpaces() { while j >= 0, HTMLBytes.isSpace(lowered[j]) { j -= 1 } }
            skipSpaces()
            let quoted = j >= 0 && (lowered[j] == UInt8(ascii: "\"") || lowered[j] == UInt8(ascii: "'"))
            if quoted { j -= 1; skipSpaces() }
            guard j >= 0 else { continue }
            if lowered[j] == UInt8(ascii: "(") {
                if j >= 3, lowered[(j - 3)..<j].elementsEqual("url".utf8) { return true }
            } else if lowered[j] == UInt8(ascii: "=") {
                j -= 1
                skipSpaces()
                var name: [UInt8] = []
                while j >= 0, HTMLBytes.isAlpha(lowered[j]) || lowered[j] == UInt8(ascii: ":") || lowered[j] == UInt8(ascii: "-") {
                    name.insert(lowered[j], at: 0)
                    j -= 1
                }
                if urlAttributes.contains(String(decoding: name, as: UTF8.self)) { return true }
            } else if quoted, j >= 6, lowered[(j - 6)...j].elementsEqual("@import".utf8) {
                return true
            }
        }
        return false
    }

    static func hasGlobalKeyHandler(_ lowered: [UInt8]) -> Bool {
        let targets = #"(window|document|document\.body)\s*\.\s*"#
        let patterns = [
            targets + #"addeventlistener\s*\(\s*["']key(down|up|press)["']"#,
            targets + #"onkey(down|up|press)\s*="#,
        ]
        guard !occurrences(of: "addeventlistener", in: lowered).isEmpty || !occurrences(of: "onkey", in: lowered).isEmpty else {
            return false
        }
        let text = String(decoding: lowered, as: UTF8.self)
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    /// `$preview` from the board's `<script type="text/x-dc" data-dc-script data-props='…'>`.
    public static func previewSize(of source: String) -> Size? {
        let bytes = Array(source.utf8)
        var tokenizer = HTMLTokenizer(bytes: bytes, range: 0..<bytes.count)
        while let tag = tokenizer.next() {
            guard !tag.isEnd else { continue }
            if tag.name == "script" {
                if tag.attribute("data-dc-script") != nil, let props = tag.attribute("data-props"),
                   let json = try? JSONDecoder().decode(JSONValue.self, from: Data(props.utf8)),
                   let preview = json["$preview"],
                   let width = preview["width"]?.doubleValue, let height = preview["height"]?.doubleValue {
                    return Size(width: width, height: height)
                }
                tokenizer.skipRawText(of: "script")
            } else if ["style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"].contains(tag.name) {
                tokenizer.skipRawText(of: tag.name)
            }
        }
        return nil
    }

    /// The fixed pixel size on the template's root: the first top-level element after `<helmet>`,
    /// when its inline style sets both `width` and `height` in px.
    static func rootSize(of source: String, template: DesignTemplate) -> Size? {
        guard let root = template.elements.first(where: { $0.parent == nil && $0.name != "helmet" }),
              let range = root.tagRange else { return nil }
        let bytes = Array(source.utf8)
        var tokenizer = HTMLTokenizer(bytes: bytes, range: range)
        guard let style = tokenizer.next()?.attribute("style") else { return nil }
        return inlineSize(style)
    }

    static func inlineSize(_ style: String) -> Size? {
        var width: Double?
        var height: Double?
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard value.hasSuffix("px"), let number = Double(value.dropLast(2)) else { continue }
            if property == "width" { width = number }
            if property == "height" { height = number }
        }
        guard let width, let height else { return nil }
        return Size(width: width, height: height)
    }
}
