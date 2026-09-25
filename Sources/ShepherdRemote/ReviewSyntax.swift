import Foundation

/// Syntax colors for a diff line, by a small lexer: comments, strings, numbers, keywords, types
/// and calls. A client without the Mac's tree-sitter grammars colors its diffs with it. It reads
/// one line at a time, so a block comment or string that spans lines colors only where it opens
/// and closes on the same line.
public enum ReviewSyntax {
    public enum Kind: Sendable, Hashable {
        case keyword, type, string, number, function, comment
    }

    /// A run of a line's text and its color (nil for plain).
    public struct Span: Equatable, Sendable {
        public let text: String
        public let kind: Kind?

        public init(_ text: String, _ kind: Kind? = nil) {
            self.text = text
            self.kind = kind
        }
    }

    public enum Language: Sendable, Hashable {
        case swift, javaScript, go, rust, c, python, ruby, shell, json

        var lineComment: String {
            switch self {
            case .python, .ruby, .shell: return "#"
            case .json: return ""
            default: return "//"
            }
        }

        var blockComments: Bool {
            switch self {
            case .swift, .javaScript, .go, .rust, .c: return true
            default: return false
            }
        }

        /// Swift and Rust read ' as something other than a string (Rust's lifetimes).
        var singleQuoteStrings: Bool {
            switch self {
            case .swift, .rust: return false
            default: return true
            }
        }

        var keywords: Set<String> {
            switch self {
            case .swift: return ReviewSyntax.swiftKeywords
            case .javaScript: return ReviewSyntax.javaScriptKeywords
            case .go: return ReviewSyntax.goKeywords
            case .rust: return ReviewSyntax.rustKeywords
            case .c: return ReviewSyntax.cKeywords
            case .python: return ReviewSyntax.pythonKeywords
            case .ruby: return ReviewSyntax.rubyKeywords
            case .shell: return ReviewSyntax.shellKeywords
            case .json: return ["true", "false", "null"]
            }
        }
    }

    /// The language a path's extension names, or nil for a file this lexer leaves plain.
    public static func language(forPath path: String) -> Language? {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "java", "kt", "kts", "cs", "dart", "scala": return .javaScript
        case "go": return .go
        case "rs": return .rust
        case "c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh": return .c
        case "py": return .python
        case "rb": return .ruby
        case "sh", "bash", "zsh": return .shell
        case "json", "jsonc": return .json
        default: return nil
        }
    }

    /// `line` as colored runs that join back into it exactly.
    public static func spans(_ line: String, language: Language) -> [Span] {
        let chars = Array(line)
        var spans: [Span] = []
        var plain = ""
        func emit(_ text: String, _ kind: Kind?) {
            guard !text.isEmpty else { return }
            if kind == nil { plain += text; return }
            if !plain.isEmpty { spans.append(Span(plain)); plain = "" }
            spans.append(Span(text, kind))
        }
        func text(_ range: Range<Int>) -> String { String(chars[range]) }
        func starts(_ token: String, at index: Int) -> Bool {
            guard !token.isEmpty else { return false }
            let token = Array(token)
            return index + token.count <= chars.count && Array(chars[index..<(index + token.count)]) == token
        }

        // A continuation line of a block comment (" * text", " */").
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if language.blockComments, trimmed.hasPrefix("* ") || trimmed == "*" || trimmed.hasPrefix("*/") {
            return [Span(line, .comment)]
        }

        let keywords = language.keywords
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if starts(language.lineComment, at: i) {
                emit(text(i..<chars.count), .comment)
                break
            }
            if language.blockComments, starts("/*", at: i) {
                var end = i + 2
                while end < chars.count, !starts("*/", at: end) { end += 1 }
                end = min(chars.count, end + 2)
                emit(text(i..<end), .comment)
                i = end
                continue
            }
            if c == "\"" || c == "`" || (c == "'" && language.singleQuoteStrings) {
                var end = i + 1
                while end < chars.count, chars[end] != c {
                    end += chars[end] == "\\" ? 2 : 1
                }
                if end < chars.count {
                    emit(text(i..<(end + 1)), .string)
                    i = end + 1
                    continue
                }
                // Unclosed on this line: the rest is the string's.
                emit(text(i..<chars.count), .string)
                break
            }
            if c.isNumber, i == 0 || !isIdentifier(chars[i - 1]) {
                var end = i + 1
                while end < chars.count, chars[end].isHexDigit || "xXoObB_.".contains(chars[end]) {
                    // A range ("0..<n") ends the number.
                    if chars[end] == ".", end + 1 < chars.count, chars[end + 1] == "." { break }
                    end += 1
                }
                emit(text(i..<end), .number)
                i = end
                continue
            }
            if isIdentifierStart(c) || ((c == "@" || c == "#") && i + 1 < chars.count && isIdentifierStart(chars[i + 1]) && language == .swift) {
                var end = i + 1
                while end < chars.count, isIdentifier(chars[end]) { end += 1 }
                let word = text(i..<end)
                var next = end
                while next < chars.count, chars[next] == " " { next += 1 }
                let kind: Kind?
                if c == "@" || c == "#" || keywords.contains(word) {
                    kind = .keyword
                } else if next < chars.count, chars[next] == "(" {
                    kind = c.isUppercase ? .type : .function
                } else if c.isUppercase {
                    kind = .type
                } else {
                    kind = nil
                }
                emit(word, kind)
                i = end
                continue
            }
            emit(String(c), nil)
            i += 1
        }
        if !plain.isEmpty { spans.append(Span(plain)) }
        return spans
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || (c.isLetter && c.isASCII)
    }

    private static func isIdentifier(_ c: Character) -> Bool {
        isIdentifierStart(c) || (c.isNumber && c.isASCII)
    }

    static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated",
        "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self",
        "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
        "weak", "where", "while",
    ]
    static let javaScriptKeywords: Set<String> = [
        "abstract", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import",
        "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "readonly", "return",
        "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "val", "var", "void",
        "while", "yield",
    ]
    static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for", "func",
        "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select", "struct", "switch",
        "true", "type", "var",
    ]
    static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for",
        "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static",
        "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    static let cKeywords: Set<String> = [
        "auto", "bool", "break", "case", "char", "class", "const", "continue", "default", "delete", "do", "double", "else",
        "enum", "extern", "false", "float", "for", "if", "inline", "int", "long", "namespace", "new", "nullptr", "private",
        "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this",
        "true", "typedef", "union", "unsigned", "using", "virtual", "void", "while", "NULL", "nil", "self",
    ]
    static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
        "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or",
        "pass", "raise", "return", "self", "True", "try", "while", "with", "yield",
    ]
    static let rubyKeywords: Set<String> = [
        "alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false", "for",
        "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then",
        "true", "undef", "unless", "until", "when", "while", "yield",
    ]
    static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "return",
        "then", "until", "while",
    ]
}
