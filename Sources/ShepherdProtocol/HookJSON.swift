import Foundation

/// A JSON value that keeps object keys in file order, so a hooks file can be read, changed and
/// written back with every unknown key where it was (docs/hooks.md › Files). Numbers are
/// `Double`s, as `JSON.parse` holds them, so hashes match the runtime's.
public indirect enum HookJSON: Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([HookJSON])
    /// Members in file order; keys are unique (a repeated key keeps its first place and last value).
    case object([Member])

    public struct Member: Equatable, Hashable, Sendable {
        public var key: String
        public var value: HookJSON
        public init(_ key: String, _ value: HookJSON) { self.key = key; self.value = value }
    }

    /// An object from pairs in order.
    public static func object(_ pairs: KeyValuePairs<String, HookJSON>) -> HookJSON {
        var value = HookJSON.object([Member]())
        for (key, member) in pairs { value[key] = member }
        return value
    }

    /// The member named `key` of an object, else nil. Setting nil removes it; setting a new key
    /// appends it; setting on a non-object makes it an object.
    public subscript(key: String) -> HookJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            var members: [Member]
            if case .object(let current) = self { members = current } else { members = [] }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [HookJSON]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [Member]? { if case .object(let o) = self { return o }; return nil }

    // MARK: Text

    /// Canonical JSON (docs/hooks.md › Identity and the off switch): keys sorted by UTF-16 code units, no
    /// whitespace, `JSON.stringify` escaping and number format.
    public var canonical: String {
        var out = ""
        writeCanonical(into: &out)
        return out
    }

    private func writeCanonical(into out: inout String) {
        switch self {
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() { if i > 0 { out += "," }; item.writeCanonical(into: &out) }
            out += "]"
        case .object(let members):
            out += "{"
            let sorted = members.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            for (i, member) in sorted.enumerated() {
                if i > 0 { out += "," }
                Self.writeString(member.key, into: &out); out += ":"
                member.value.writeCanonical(into: &out)
            }
            out += "}"
        default: writeScalar(into: &out)
        }
    }

    /// `JSON.stringify(value, null, 2)` plus a newline: keys in their order, two-space indent.
    public var pretty: String {
        var out = ""
        writePretty(into: &out, indent: "")
        return out + "\n"
    }

    private func writePretty(into out: inout String, indent: String) {
        let inner = indent + "  "
        switch self {
        case .array(let items) where !items.isEmpty:
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += inner; item.writePretty(into: &out, indent: inner)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += indent + "]"
        case .object(let members) where !members.isEmpty:
            out += "{\n"
            for (i, member) in members.enumerated() {
                out += inner; Self.writeString(member.key, into: &out); out += ": "
                member.value.writePretty(into: &out, indent: inner)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += indent + "}"
        case .array: out += "[]"
        case .object: out += "{}"
        default: writeScalar(into: &out)
        }
    }

    private func writeScalar(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.jsNumber(n)
        case .string(let s): Self.writeString(s, into: &out)
        case .array, .object: break
        }
    }

    /// `JSON.stringify`'s string escaping: `\"`, `\\`, `\b \f \n \r \t`, other code points below
    /// U+0020 as lowercase `\u00xx`, nothing else.
    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0..<0x20: out += "\\u00" + (scalar.value < 0x10 ? "0" : "") + String(scalar.value, radix: 16)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    /// A finite number as JavaScript's `Number.prototype.toString` prints it (ECMA-262
    /// Number::toString), from Swift's shortest round-trip digits.
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        // Swift prints the same shortest digits; only the layout differs. Split it into digits and exponent.
        let text = abs(value).description
        let mantissa = text.split(separator: "e").first.map(String.init) ?? text
        let exponent = text.split(separator: "e").dropFirst().first.flatMap { Int($0) } ?? 0
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(parts[0]), fraction = parts.count > 1 ? String(parts[1]) : ""
        var digits = whole + fraction
        var n = whole.count + exponent // value = 0.digits × 10^n
        while digits.hasPrefix("0") && digits.count > 1 { digits.removeFirst(); n -= 1 }
        while digits.hasSuffix("0") && digits.count > 1 { digits.removeLast() }
        let k = digits.count
        let body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            body = String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let e = n - 1
            body = String(digits.prefix(1)) + (k > 1 ? "." + String(digits.dropFirst()) : "") + "e" + (e < 0 ? "-" : "+") + String(abs(e))
        }
        return (value < 0 ? "-" : "") + body
    }

    // MARK: Parsing

    /// Why a file didn't parse: the 1-based line and a short message.
    public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        public var line: Int
        public var message: String
        public var description: String { "line \(line), \(message)" }
        public init(line: Int, message: String) { self.line = line; self.message = message }
    }

    /// Parses JSON text (a leading BOM is ignored), keeping key order.
    public static func parse(_ text: String) throws -> HookJSON {
        var parser = Parser(bytes: Array(text.utf8))
        if parser.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { parser.index = 3 }
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.error("unexpected text after the JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var line = 1

        func error(_ message: String) -> ParseError { ParseError(line: line, message: message) }

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x0A: line += 1; index += 1
                case 0x20, 0x09, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func expect(_ byte: UInt8, _ what: String) throws {
            skipSpace()
            guard index < bytes.count, bytes[index] == byte else { throw error("expected \(what)") }
            index += 1
        }

        mutating func value(depth: Int) throws -> HookJSON {
            guard depth < 128 else { throw error("nested too deeply") }
            skipSpace()
            guard index < bytes.count else { throw error("unexpected end of file") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var object = HookJSON.object([Member]())
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return object }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key in quotes") }
                    let key = try string()
                    try expect(UInt8(ascii: ":"), "“:” after a key")
                    object[key] = try value(depth: depth + 1)
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end of file, expected “}”") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return object }
                    throw error("expected “,” or “}”")
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [HookJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw error("unexpected end of file, expected “]”") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                    throw error("expected “,” or “]”")
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try word("true"); return .bool(true)
            case UInt8(ascii: "f"): try word("false"); return .bool(false)
            case UInt8(ascii: "n"): try word("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw error("unexpected character")
            }
        }

        mutating func word(_ text: String) throws {
            let expected = Array(text.utf8)
            guard bytes[index...].starts(with: expected) else { throw error("unexpected word") }
            index += expected.count
        }

        mutating func number() throws -> Double {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            func digits() -> Int {
                let from = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - from
            }
            let intStart = index
            guard digits() > 0 else { throw error("invalid number") }
            if bytes[intStart] == UInt8(ascii: "0") && index - intStart > 1 { throw error("invalid number (leading zero)") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("invalid number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("invalid number") }
            }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else { throw error("invalid number") }
            return value
        }

        mutating func string() throws -> String {
            index += 1 // opening quote
            var scalars = String.UnicodeScalarView()
            var run = index
            func flush() { scalars.append(contentsOf: String(decoding: bytes[run..<index], as: UTF8.self).unicodeScalars) }
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") { flush(); index += 1; return String(scalars) }
                if byte < 0x20 { throw error(byte == 0x0A ? "line break inside a string" : "control character inside a string") }
                guard byte == UInt8(ascii: "\\") else { index += 1; continue }
                flush()
                index += 1
                guard index < bytes.count else { throw error("unterminated string") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var unit = try hex4()
                    if (0xD800..<0xDC00).contains(unit), bytes[index...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "u")]) {
                        index += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) { unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00) }
                        else { index -= 6 }
                    }
                    // ponytail: a lone surrogate becomes U+FFFD; JS would keep it, so such a hash differs.
                    scalars.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
                default: throw error("invalid escape in a string")
                }
                run = index
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("invalid \\u escape")
            }
            index += 4
            return value
        }
    }
}

/// On the wire (`hooks.v1`) a value travels as its JSON text, so an object keeps its key order.
extension HookJSON: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = try HookJSON.parse(text)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(pretty)
    }
}
