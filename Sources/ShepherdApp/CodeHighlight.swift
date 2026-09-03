import Foundation
import SwiftUI
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

@MainActor
enum CodeHighlight {
    struct Style {
        let comment: Color
        let string: Color
        let number: Color
        let keyword: Color
        let type: Color
        let function: Color

        init(palette: [String]) {
            let fallback = palette.first.map { Color(hex: $0) } ?? .clear
            func color(at index: Int) -> Color {
                palette.indices.contains(index) ? Color(hex: palette[index]) : fallback
            }

            comment = color(at: 8)
            string = color(at: 2)
            number = color(at: 3)
            keyword = color(at: 4)
            type = color(at: 5)
            function = color(at: 6)
        }
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

    private struct CachedGrammar {
        let parser: Parser
        let language: Language
        let query: Query
    }

    private static var grammarCache: [GrammarID: CachedGrammar] = [:]

    static func highlightLines(_ lines: [String], path: String, style: Style) -> [AttributedString] {
        guard !lines.isEmpty else { return [] }
        guard let grammarID = GrammarID(path: path),
              let grammar = cachedGrammar(for: grammarID) else {
            return lines.map(AttributedString.init)
        }

        let fullText = lines.joined(separator: "\n") as NSString
        let source = fullText as String
        guard let tree = grammar.parser.parse(source) else {
            return lines.map(AttributedString.init)
        }

        let attributed = NSMutableAttributedString(string: source)
        let foregroundColorKey = NSAttributedString.Key(
            AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.name
        )
        let context = Predicate.Context(string: source)
        let matches = grammar.query.execute(in: tree).resolve(with: context)

        for match in matches {
            for capture in match.captures {
                guard let color = color(for: capture.nameComponents, style: style),
                      let range = clamped(capture.range, to: attributed.length) else {
                    continue
                }
                attributed.addAttribute(foregroundColorKey, value: color, range: range)
            }
        }

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
        if let cached = grammarCache[id] {
            return cached
        }

        let language = id.language
        guard let queryURL = queryURL(for: id),
              let query = try? Query(language: language, url: queryURL) else {
            return nil
        }

        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil else {
            return nil
        }

        let cached = CachedGrammar(parser: parser, language: language, query: query)
        grammarCache[id] = cached
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

    private static func color(for components: [String], style: Style) -> Color? {
        guard let first = components.first else { return nil }
        if first == "constant", components.dropFirst().first == "numeric" {
            return style.number
        }
        switch first {
        case "comment": return style.comment
        case "string": return style.string
        case "number": return style.number
        case "keyword": return style.keyword
        case "type": return style.type
        case "function": return style.function
        default: return nil
        }
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
