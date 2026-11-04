import Foundation
import ShepherdProtocol

/// The part of Codex's `config.toml` that holds hooks, read into the shape every hooks file has
/// (`{"hooks": {"<Event>": [{"matcher": …, "hooks": [{…}]}]}}`):
///
/// ```toml
/// [[hooks.PreToolUse]]
/// matcher = "Edit|Write"
/// [[hooks.PreToolUse.hooks]]
/// type = "command"
/// command = 'npm run lint'
/// timeout = 10
/// ```
///
/// Everything outside `hooks` tables is skipped.
// ponytail: a subset of TOML. Inside hooks tables only `key = value` with basic or literal
// single-line strings, decimal numbers and booleans; arrays, inline tables, dotted keys, sub-tables
// (an mcp_tool's `input`) and multi-line strings there are reported as unreadable. Outside them a
// line starting with `[` inside a multi-line array can be mistaken for a table header.
// Add a real TOML parser if Codex files start using more.
enum HookTOML {
    static func parse(_ text: String) throws -> HookJSON {
        var events: [String] = []
        var groups: [String: [HookJSON]] = [:]
        enum Target { case none, other, group(String), handler(String) }
        var target = Target.none
        var multiline: String?

        for (offset, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = offset + 1
            func fail(_ message: String) -> HookJSON.ParseError { HookJSON.ParseError(line: lineNumber, message: message) }
            var line = Substring(raw)
            if line.hasSuffix("\r") { line = line.dropLast() }
            if let delimiter = multiline {
                if line.components(separatedBy: delimiter).count % 2 == 0 { multiline = nil }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("[") {
                let isArray = trimmed.hasPrefix("[[")
                guard let close = trimmed.range(of: isArray ? "]]" : "]"),
                      let path = dottedKey(String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: isArray ? 2 : 1)..<close.lowerBound])) else {
                    target = .other; continue
                }
                let rest = trimmed[close.upperBound...].trimmingCharacters(in: .whitespaces)
                guard rest.isEmpty || rest.hasPrefix("#") else { target = .other; continue }
                guard path.first == "hooks" else { target = .other; continue }
                if isArray && path.count == 2 {
                    let event = path[1]
                    if groups[event] == nil { events.append(event); groups[event] = [] }
                    groups[event]!.append(.object([HookJSON.Member]()))
                    target = .group(event)
                } else if isArray && path.count == 3 && path[2] == "hooks" {
                    let event = path[1]
                    guard var list = groups[event], var group = list.popLast() else {
                        throw fail("[[hooks.\(event).hooks]] comes before any [[hooks.\(event)]]")
                    }
                    var handlers = group["hooks"]?.arrayValue ?? []
                    handlers.append(.object([HookJSON.Member]()))
                    group["hooks"] = .array(handlers)
                    list.append(group)
                    groups[event] = list
                    target = .handler(event)
                } else {
                    throw fail("only [[hooks.<Event>]] and [[hooks.<Event>.hooks]] tables are supported")
                }
                continue
            }

            switch target {
            case .none, .other:
                // Skip, but don't read a multi-line string's lines as headers.
                for delimiter in ["\"\"\"", "'''"] where line.components(separatedBy: delimiter).count % 2 == 0 {
                    multiline = delimiter
                }
            case .group(let event), .handler(let event):
                guard let equals = trimmed.firstIndex(of: "="), let key = dottedKey(String(trimmed[..<equals])), key.count == 1 else {
                    throw fail("expected key = value")
                }
                var scanner = Scanner(text: Substring(trimmed[trimmed.index(after: equals)...]))
                guard let value = try scanner.value(fail) else { throw fail("only strings, numbers and booleans are supported here") }
                guard scanner.restIsEmpty else { throw fail("unexpected text after the value") }
                var list = groups[event]!
                var group = list.removeLast()
                if case .handler = target {
                    var handlers = group["hooks"]!.arrayValue!
                    var handler = handlers.removeLast()
                    handler[key[0]] = value
                    handlers.append(handler)
                    group["hooks"] = .array(handlers)
                } else {
                    group[key[0]] = value
                }
                list.append(group)
                groups[event] = list
            }
        }
        guard !events.isEmpty else { return .object([HookJSON.Member]()) }
        return .object([HookJSON.Member("hooks", .object(events.map { HookJSON.Member($0, .array(groups[$0]!)) }))])
    }

    /// `a.b."c d"` as its parts, or nil when it isn't a key.
    static func dottedKey(_ text: String) -> [String]? {
        var parts: [String] = []
        var scanner = Scanner(text: Substring(text))
        while true {
            scanner.skipSpace()
            if scanner.peek == "\"" || scanner.peek == "'" {
                guard let part = try? scanner.quoted() else { return nil }
                parts.append(part)
            } else {
                let bare = scanner.take { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" }
                guard !bare.isEmpty else { return nil }
                parts.append(bare)
            }
            scanner.skipSpace()
            if scanner.restIsEmpty { return parts }
            guard scanner.peek == "." else { return nil }
            scanner.advance()
        }
    }

    private struct Scanner {
        var text: Substring
        var peek: Character? { text.first }
        mutating func advance() { text = text.dropFirst() }
        mutating func skipSpace() { text = text.drop { $0 == " " || $0 == "\t" } }
        var restIsEmpty: Bool {
            let rest = text.drop { $0 == " " || $0 == "\t" }
            return rest.isEmpty || rest.hasPrefix("#")
        }
        mutating func take(while keep: (Character) -> Bool) -> String {
            let taken = text.prefix(while: keep)
            text = text.dropFirst(taken.count)
            return String(taken)
        }

        struct Unterminated: Error {}

        mutating func quoted() throws -> String {
            let quote = peek!
            advance()
            var out = ""
            while let c = peek {
                advance()
                if c == quote { return out }
                guard quote == "\"", c == "\\" else { out.append(c); continue }
                guard let e = peek else { break }
                advance()
                switch e {
                case "b": out += "\u{08}"
                case "t": out += "\t"
                case "n": out += "\n"
                case "f": out += "\u{0C}"
                case "r": out += "\r"
                case "e": out += "\u{1B}"
                case "\"": out += "\""
                case "\\": out += "\\"
                case "u", "U":
                    let hex = String(text.prefix(e == "u" ? 4 : 8))
                    guard hex.count == (e == "u" ? 4 : 8), let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { throw Unterminated() }
                    text = text.dropFirst(hex.count)
                    out.unicodeScalars.append(scalar)
                default: throw Unterminated()
                }
            }
            throw Unterminated()
        }

        /// A string, number or boolean, or nil when the value is something else.
        mutating func value(_ fail: (String) -> HookJSON.ParseError) throws -> HookJSON? {
            skipSpace()
            guard let c = peek else { throw fail("expected a value") }
            if c == "\"" || c == "'" {
                if text.hasPrefix("\"\"\"") || text.hasPrefix("'''") { return nil }
                do { return .string(try quoted()) } catch { throw fail("unterminated or invalid string") }
            }
            if text.hasPrefix("true") { text = text.dropFirst(4); return .bool(true) }
            if text.hasPrefix("false") { text = text.dropFirst(5); return .bool(false) }
            let word = take { !$0.isWhitespace && $0 != "#" }
            guard !word.isEmpty, word.first!.isNumber || "+-".contains(word.first!) else { return nil }
            let digits = word.replacingOccurrences(of: "_", with: "")
            guard digits.range(of: #"^[+-]?\d+(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
                  let number = Double(digits), number.isFinite else { throw fail("invalid number") }
            return .number(number)
        }
    }
}
