import Foundation
import ShepherdProtocol

/// A tool call's arguments while the model is still writing them. pi streams the JSON as
/// fragments (`toolcall_delta`, each a few characters of the text), and a big write's `content`
/// runs to many kilobytes. The thread needs only the few fields an activity line names ("Writing
/// src/big.txt"), so this reads the fragments as they come, keeps those top-level string fields,
/// and lets the rest go by unheld: a fragment costs its own length, never the call's so far.
///
/// A string still open when the fragments pause is kept as far as it got (a path being typed
/// reads "src/big"); an escape that is not finished is not, so the value never holds half of one.
/// Malformed JSON keeps whatever came before it.
struct StreamingToolArguments {
    /// The arguments an activity line reads (`NativeActivityCall`).
    static let fields: Set<String> = ["path", "command", "pattern", "query", "url"]
    /// A field is kept up to this many bytes: the line shows its first line, and the row stays
    /// small however long a command runs.
    static let fieldBytes = 2048
    private static let keyScalars = 32

    /// The kept fields so far.
    private(set) var values: [String: String] = [:]

    private enum Phase { case beforeKey, afterKey, beforeValue, inValue }
    private enum Reading: Equatable {
        case key
        /// A string value, the field it is kept in (nil: skipped).
        case value(String?)
    }
    private enum Escape { case none, backslash, unicode(digits: Int, value: UInt32) }

    /// Open `{` and `[`; the call's own object is depth 1.
    private var depth = 0
    private var inObject = false
    private var phase = Phase.beforeKey
    private var key = ""
    private var keyIsLong = false
    private var reading: Reading?
    private var escape = Escape.none
    private var highSurrogate: UInt32?

    /// The kept fields as the call's arguments; nil until one has a character.
    var arguments: JSONValue? {
        values.isEmpty ? nil : .object(values.mapValues { .string($0) })
    }

    /// Reads the next fragment. True when a kept field grew.
    mutating func append(_ fragment: String) -> Bool {
        var changed = false
        for scalar in fragment.unicodeScalars {
            if let reading {
                if consume(scalar, in: reading) { changed = true }
            } else {
                structure(scalar)
            }
        }
        return changed
    }

    /// The same fields out of a call's complete arguments (`toolcall_end`); nil when it has none.
    static func named(in arguments: JSONValue) -> JSONValue? {
        var found: [String: JSONValue] = [:]
        for field in fields {
            if case .string(let text)? = arguments[field], !text.isEmpty { found[field] = .string(clipped(text)) }
        }
        return found.isEmpty ? nil : .object(found)
    }

    private static func clipped(_ text: String) -> String {
        guard text.utf8.count > fieldBytes else { return text }
        var bytes = 0
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            bytes += UTF8.width(scalar)
            if bytes > fieldBytes { break }
            kept.append(scalar)
        }
        return String(kept)
    }

    // MARK: Structure

    private mutating func structure(_ scalar: Unicode.Scalar) {
        let top = depth == 1 && inObject
        switch scalar {
        case "\"":
            if top, phase == .beforeKey {
                reading = .key
                key = ""
                keyIsLong = false
            } else if top, phase == .beforeValue {
                let field = Self.fields.contains(key) && !keyIsLong ? key : nil
                if let field { values[field] = nil }
                reading = .value(field)
                phase = .inValue
            } else {
                reading = .value(nil)
            }
        case "{", "[":
            if depth == 0 {
                inObject = scalar == "{"
                phase = .beforeKey
            } else if top, phase == .beforeValue {
                phase = .inValue
            }
            depth += 1
        case "}", "]":
            if depth > 0 { depth -= 1 }
        case ":":
            if top, phase == .afterKey { phase = .beforeValue }
        case ",":
            if top { phase = .beforeKey }
        default:
            // A number, true, false or null.
            if top, phase == .beforeValue, !scalar.properties.isWhitespace { phase = .inValue }
        }
    }

    // MARK: Strings

    /// A character of a string. True when it grew a kept field.
    private mutating func consume(_ scalar: Unicode.Scalar, in reading: Reading) -> Bool {
        switch escape {
        case .none:
            if scalar == "\\" {
                escape = .backslash
                return false
            }
            if scalar == "\"" {
                finishString(reading)
                return false
            }
            highSurrogate = nil
            return add(scalar, to: reading)
        case .backslash:
            escape = .none
            switch scalar {
            case "n": return add("\n", to: reading)
            case "t": return add("\t", to: reading)
            case "r": return add("\r", to: reading)
            case "b": return add("\u{8}", to: reading)
            case "f": return add("\u{C}", to: reading)
            case "u":
                escape = .unicode(digits: 0, value: 0)
                return false
            default: return add(scalar, to: reading)
            }
        case .unicode(let digits, let value):
            guard let digit = Character(scalar).hexDigitValue else {
                escape = .none
                return false
            }
            let next = value * 16 + UInt32(digit)
            if digits + 1 < 4 {
                escape = .unicode(digits: digits + 1, value: next)
                return false
            }
            escape = .none
            return add(code: next, to: reading)
        }
    }

    private mutating func finishString(_ reading: Reading) {
        self.reading = nil
        highSurrogate = nil
        if reading == .key { phase = .afterKey }
    }

    /// A `\uXXXX` escape; a pair of them makes one character.
    private mutating func add(code: UInt32, to reading: Reading) -> Bool {
        if (0xD800...0xDBFF).contains(code) {
            highSurrogate = code
            return false
        }
        var scalar = Unicode.Scalar(code)
        if (0xDC00...0xDFFF).contains(code) {
            scalar = highSurrogate.flatMap { Unicode.Scalar(0x10000 + (($0 - 0xD800) << 10) + (code - 0xDC00)) }
        }
        highSurrogate = nil
        return add(scalar ?? "\u{FFFD}", to: reading)
    }

    private mutating func add(_ scalar: Unicode.Scalar, to reading: Reading) -> Bool {
        switch reading {
        case .key:
            if key.unicodeScalars.count < Self.keyScalars { key.unicodeScalars.append(scalar) } else { keyIsLong = true }
            return false
        case .value(let field?):
            guard (values[field]?.utf8.count ?? 0) + UTF8.width(scalar) <= Self.fieldBytes else { return false }
            values[field, default: ""].unicodeScalars.append(scalar)
            return true
        case .value(nil):
            return false
        }
    }
}
