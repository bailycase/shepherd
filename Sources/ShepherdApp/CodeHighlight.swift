import Foundation
import os
import SwiftUI
import ShepherdUI
import SwiftTreeSitter
import TreeSitterSwift
import TreeSitterPython
import TreeSitterGo
import TreeSitterRust
import TreeSitterJavaScript
import TreeSitterTypeScript
import TreeSitterTSX
import TreeSitterC
import TreeSitterCPP
import TreeSitterBash
import TreeSitterRuby
import TreeSitterJSON

private final class CodeHighlightBundleToken: NSObject {}

/// Tree-sitter syntax colors. Not main-actor bound: the review's diff and the thread's code
/// blocks highlight off the main thread. Compiled grammars are shared (a `Query` is
/// thread-safe); each call parses with its own `Parser`.
enum CodeHighlight {
    /// Highlight colors, from the theme's syntax roles (dynamic: they follow light/dark).
    struct Style: Sendable {
        let comment: Color
        let string: Color
        let number: Color
        let keyword: Color
        let type: Color
        let function: Color

        @MainActor static var theme: Style {
            Style(comment: Color.sh.synComment, string: Color.sh.synString, number: Color.sh.synNumber,
                  keyword: Color.sh.synKeyword, type: Color.sh.synType, function: Color.sh.synFunction)
        }
    }

    /// A pseudo path whose extension picks the grammar for a Markdown fence's language word.
    static func path(forFenceLanguage language: String?) -> String? {
        guard let language = language?.lowercased() else { return nil }
        let ext: String? = switch language {
        case "swift": "swift"
        case "python", "py": "py"
        case "go", "golang": "go"
        case "rust", "rs": "rs"
        case "javascript", "js", "jsx", "mjs": "js"
        case "typescript", "ts": "ts"
        case "tsx": "tsx"
        case "c", "h": "c"
        case "cpp", "c++", "cc", "hpp": "cpp"
        case "bash", "sh", "zsh", "shell", "console": "sh"
        case "ruby", "rb": "rb"
        case "json", "jsonc": "json"
        default: nil
        }
        return ext.map { "fence.\($0)" }
    }

    private enum GrammarID: Hashable {
        case swift
        case python
        case go
        case rust
        case javascript
        case typescript
        case tsx
        case c
        case cpp
        case bash
        case ruby
        case json

        init?(path: String) {
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "swift": self = .swift
            case "py", "pyw": self = .python
            case "go": self = .go
            case "rs": self = .rust
            case "js", "jsx", "mjs", "cjs": self = .javascript
            case "ts": self = .typescript
            case "tsx": self = .tsx
            case "c", "h": self = .c
            case "cc", "cpp", "cxx", "hh", "hpp", "hxx": self = .cpp
            case "sh", "bash", "zsh": self = .bash
            case "rb": self = .ruby
            case "json": self = .json
            default: return nil
            }
        }

        var bundleName: String {
            switch self {
            case .swift: return "TreeSitterSwift_TreeSitterSwift"
            case .python: return "TreeSitterPython_TreeSitterPython"
            case .go: return "TreeSitterGo_TreeSitterGo"
            case .rust: return "TreeSitterRust_TreeSitterRust"
            case .javascript: return "TreeSitterJavaScript_TreeSitterJavaScript"
            case .typescript: return "TreeSitterTypeScript_TreeSitterTypeScript"
            case .tsx: return "TreeSitterTypeScript_TreeSitterTSX"
            case .c: return "TreeSitterC_TreeSitterC"
            case .cpp: return "TreeSitterCPP_TreeSitterCPP"
            case .bash: return "TreeSitterBash_TreeSitterBash"
            case .ruby: return "TreeSitterRuby_TreeSitterRuby"
            case .json: return "TreeSitterJSON_TreeSitterJSON"
            }
        }

        var language: Language {
            switch self {
            case .swift: return Language(language: tree_sitter_swift())
            case .python: return Language(language: tree_sitter_python())
            case .go: return Language(language: tree_sitter_go())
            case .rust: return Language(language: tree_sitter_rust())
            case .javascript: return Language(language: tree_sitter_javascript())
            case .typescript: return Language(language: tree_sitter_typescript())
            case .tsx: return Language(language: tree_sitter_tsx())
            case .c: return Language(language: tree_sitter_c())
            case .cpp: return Language(language: tree_sitter_cpp())
            case .bash: return Language(language: tree_sitter_bash())
            case .ruby: return Language(language: tree_sitter_ruby())
            case .json: return Language(language: tree_sitter_json())
            }
        }
    }

    private struct CachedGrammar: Sendable {
        let language: Language
        let query: Query
    }

    private static let grammarCache = OSAllocatedUnfairLock<[GrammarID: CachedGrammar]>(initialState: [:])

    /// Whether `path`'s extension has a grammar (other files stay plain).
    static func supports(path: String) -> Bool { GrammarID(path: path) != nil }

    /// `isCancelled` is checked between the parse, the captures, and the lines: once it holds,
    /// the lines come back empty and the caller drops them.
    static func highlightLines(_ lines: [String], path: String, style: Style,
                               isCancelled: () -> Bool = { false }) -> [AttributedString] {
        guard !lines.isEmpty else { return [] }
        guard let grammarID = GrammarID(path: path),
              let grammar = cachedGrammar(for: grammarID) else {
            return lines.map(AttributedString.init)
        }

        let source = lines.joined(separator: "\n")
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil, let tree = parser.parse(source) else {
            return lines.map(AttributedString.init)
        }
        if isCancelled() { return [] }

        let attributed = NSMutableAttributedString(string: source)
        let foregroundColorKey = NSAttributedString.Key(
            AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.name
        )
        let context = Predicate.Context(string: source)
        let matches = grammar.query.execute(in: tree).resolve(with: context)

        for (index, match) in matches.enumerated() {
            if index.isMultiple(of: 64), isCancelled() { return [] }
            for capture in match.captures {
                guard let color = color(for: capture.nameComponents, style: style),
                      let range = clamped(capture.range, to: attributed.length) else {
                    continue
                }
                attributed.addAttribute(foregroundColorKey, value: color, range: range)
            }
        }
        if isCancelled() { return [] }

        var location = 0
        return lines.map { line in
            let length = (line as NSString).length
            guard location <= attributed.length else { return AttributedString(line) }
            let safeLength = min(length, attributed.length - location)
            let range = NSRange(location: location, length: safeLength)
            location += length + 1
            return AttributedString(attributed.attributedSubstring(from: range))
        }
    }

    private static func cachedGrammar(for id: GrammarID) -> CachedGrammar? {
        if let cached = grammarCache.withLock({ $0[id] }) {
            return cached
        }

        let language = id.language
        guard let queryURL = queryURL(for: id),
              let query = try? Query(language: language, url: queryURL) else {
            return nil
        }

        // Two threads racing here both compile the query; the second write is harmless.
        let cached = CachedGrammar(language: language, query: query)
        grammarCache.withLock { $0[id] = cached }
        return cached
    }

    private static func queryURL(for id: GrammarID) -> URL? {
        let bundleName = id.bundleName
        var bundleURLs: [URL] = []
        let hostBundles = [Bundle.main, Bundle(for: CodeHighlightBundleToken.self)]

        for hostBundle in hostBundles {
            if let url = hostBundle.url(forResource: bundleName, withExtension: "bundle") {
                bundleURLs.append(url)
            }
            if let resourceURL = hostBundle.resourceURL {
                bundleURLs.append(resourceURL.appendingPathComponent("\(bundleName).bundle"))
            }
            bundleURLs.append(hostBundle.bundleURL.appendingPathComponent("\(bundleName).bundle"))
            bundleURLs.append(
                hostBundle.bundleURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(bundleName).bundle")
            )
        }

        for bundleURL in bundleURLs {
            guard let bundle = Bundle(url: bundleURL) else { continue }
            if let queryURL = bundle.url(
                forResource: "highlights",
                withExtension: "scm",
                subdirectory: "queries"
            ) {
                return queryURL
            }
        }
        return nil
    }

    /// The captures that take a color.
    private enum Role: UInt8 {
        case comment = 1, string, number, keyword, type, function
    }

    private static func role(for components: [String]) -> Role? {
        guard let first = components.first else { return nil }
        if first == "constant", components.dropFirst().first == "numeric" {
            return .number
        }
        switch first {
        case "comment": return .comment
        case "string": return .string
        case "number": return .number
        case "keyword": return .keyword
        case "type": return .type
        case "function": return .function
        default: return nil
        }
    }

    private static func color(for role: Role, style: Style) -> Color {
        switch role {
        case .comment: return style.comment
        case .string: return style.string
        case .number: return style.number
        case .keyword: return style.keyword
        case .type: return style.type
        case .function: return style.function
        }
    }

    private static func color(for components: [String], style: Style) -> Color? {
        role(for: components).map { color(for: $0, style: style) }
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange? {
        guard range.location >= 0, range.length > 0, range.location < length else {
            return nil
        }
        return NSRange(
            location: range.location,
            length: min(range.length, length - range.location)
        )
    }
}

extension CodeHighlight {
    /// Colors a fence as a reply writes it. It keeps the text and the parse tree between calls: each
    /// call hands tree-sitter only the lines added since, which re-parses what they touch, and colors
    /// from the first line the new tree changed. The work follows the lines added, not the fence.
    /// One call at a time: not thread-safe.
    final class Session: @unchecked Sendable {
        struct Update {
            /// The text colored now: the fence's first lines.
            var text: String
            /// The UTF-16 offset in `text` from which the colors differ from the last update's.
            var from: Int
            /// The colors of `text` from `from` on.
            var spans: [SHCodeColors.Span]
        }

        /// What tree-sitter was given, in UTF-16 units: read to parse, and colored.
        struct Work: Equatable {
            var parsed = 0
            var colored = 0
        }

        private static let readUnits = 512

        let path: String
        private(set) var work = Work()
        private let grammar: CachedGrammar
        private let parser = Parser()
        private var tree: MutableTree?
        private var units: [UInt16] = []
        private var text = ""
        private var lines = 0
        private var row = 0
        private var column = 0

        init?(path: String) {
            guard let id = GrammarID(path: path), let grammar = CodeHighlight.cachedGrammar(for: id) else { return nil }
            self.path = path
            self.grammar = grammar
            guard (try? parser.setLanguage(grammar.language)) != nil else { return nil }
        }

        /// Extends the text to the first `target` lines of `code` and colors what that changed. The
        /// session starts over when `code` no longer begins with the text it holds. nil when there is
        /// nothing new: fewer than `target` lines in `code`, or no more than the session holds.
        func advance(code: String, lines target: Int, style: Style) -> Update? {
            var code = code
            return code.withUTF8 { advance(utf8: $0, lines: target, style: style) }
        }

        private func reset() {
            tree = nil
            units = []
            text = ""
            lines = 0
            row = 0
            column = 0
            parser.reset()
        }

        private func advance(utf8 bytes: UnsafeBufferPointer<UInt8>, lines target: Int, style: Style) -> Update? {
            var held = text.utf8.count
            var extendsText = held == 0
            if held > 0, held <= bytes.count, held == bytes.count || bytes[held] == UInt8(ascii: "\n") {
                var heldText = text
                extendsText = heldText.withUTF8 { memcmp($0.baseAddress, bytes.baseAddress, held) == 0 }
            }
            if !extendsText {
                reset()
                held = 0
            }
            guard target > lines else { return nil }
            // The held text ends before the newline that completes its last line.
            var newlines = max(lines - 1, 0)
            var end: Int?
            var index = held
            while index < bytes.count {
                if bytes[index] == UInt8(ascii: "\n") {
                    newlines += 1
                    if newlines == target { end = index; break }
                }
                index += 1
            }
            guard let end else { return nil }

            let added = String(decoding: UnsafeBufferPointer(rebasing: bytes[held..<end]), as: UTF8.self)
            let oldLength = units.count
            let oldPoint = Point(row: row, column: column * 2)
            for unit in added.utf16 {
                units.append(unit)
                if unit == 10 { row += 1; column = 0 } else { column += 1 }
            }
            text += added
            lines = target

            let previous = tree
            previous?.edit(InputEdit(startByte: UInt32(oldLength * 2), oldEndByte: UInt32(oldLength * 2),
                                     newEndByte: UInt32(units.count * 2), startPoint: oldPoint,
                                     oldEndPoint: oldPoint, newEndPoint: Point(row: row, column: column * 2)))
            let parsed = parser.parse(tree: previous) { [self] byteOffset, _ in
                let start = byteOffset / 2
                guard start < units.count else { return nil }
                let stop = min(start + Self.readUnits, units.count)
                work.parsed += stop - start
                return units[start..<stop].withUnsafeBytes { Data($0) }
            }
            guard let parsed else {
                reset()
                return nil
            }
            // Colors can change where the tree did, before the lines added (a comment or string they close).
            var changed = oldLength
            if let previous {
                for range in previous.changedRanges(from: parsed) { changed = min(changed, Int(range.bytes.lowerBound) / 2) }
            }
            tree = parsed

            var start = min(changed, units.count)
            while start > 0, units[start - 1] != 10 { start -= 1 }
            let length = units.count
            work.colored += length - start
            SHRenderProbe.add("highlight.units", length - start)
            var roles = [UInt8](repeating: 0, count: length - start)
            let cursor = grammar.query.execute(in: parsed)
            cursor.setByteRange(range: UInt32(start * 2)..<UInt32(length * 2))
            let context = Predicate.Context(textProvider: { [self] range, _ in
                guard range.location >= 0, range.location + range.length <= units.count else { return nil }
                return String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
            })
            for match in cursor.resolve(with: context) {
                for capture in match.captures {
                    guard let role = CodeHighlight.role(for: capture.nameComponents) else { continue }
                    let low = max(capture.range.location, start), high = min(capture.range.location + capture.range.length, length)
                    // A whole highlight colors each line apart, so the breaks between them stay plain.
                    if low < high { for unit in low..<high where units[unit] != 10 { roles[unit - start] = role.rawValue } }
                }
            }

            var spans: [SHCodeColors.Span] = []
            var from = 0
            while from < roles.count {
                let value = roles[from]
                var stop = from + 1
                while stop < roles.count, roles[stop] == value { stop += 1 }
                if let role = Role(rawValue: value) {
                    spans.append(SHCodeColors.Span(range: (start + from)..<(start + stop), color: CodeHighlight.color(for: role, style: style)))
                }
                from = stop
            }
            return Update(text: text, from: start, spans: spans)
        }
    }
}
