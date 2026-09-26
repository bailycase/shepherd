import Foundation

/// A board's path inside a design's `project/` folder, as canvas.json keys it
/// ("Main.dc.html", "flows/Cart.dc.html"). Only a path that passes the grammar names a file, so
/// nothing read from an index, an agent or a remote client can reach outside the folder
/// (docs/designs.md › Paths).
public struct DesignPath: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// The longest path accepted, which the view record's file grammar also caps.
    public static let maxLength = 200
    public static let fileExtension = ".dc.html"

    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case empty
        case tooLong
        case notABoard
        case absolute
        case backslash
        case parentReference
        case badSegment(String)
        case reservedFolder

        public var description: String {
            switch self {
            case .empty: return "a board path is empty"
            case .tooLong: return "a board path is longer than \(DesignPath.maxLength) characters"
            case .notABoard: return "a board path ends in .dc.html"
            case .absolute: return "a board path never starts with /"
            case .backslash: return "a board path never holds \\"
            case .parentReference: return "a board path never holds .."
            case .badSegment(let segment):
                return "\"\(segment)\" is not a path segment: start with a letter, digit or _, then only those, . and -"
            case .reservedFolder: return "ds/ holds design systems, never boards"
            }
        }
    }

    /// Checks `raw` against the grammar: segments of `[A-Za-z0-9_][A-Za-z0-9_.-]*` joined by `/`,
    /// ending in `.dc.html`, with no `..`, `\` or leading `/`, and outside `ds/`.
    public static func validate(_ raw: String) throws(Problem) -> DesignPath {
        guard !raw.isEmpty else { throw .empty }
        guard raw.utf8.count <= maxLength else { throw .tooLong }
        guard !raw.hasPrefix("/") else { throw .absolute }
        guard !raw.contains("\\") else { throw .backslash }
        guard !raw.contains("..") else { throw .parentReference }
        guard raw.hasSuffix(fileExtension), raw.utf8.count > fileExtension.utf8.count else { throw .notABoard }
        let segments = raw.split(separator: "/", omittingEmptySubsequences: false)
        for segment in segments where !isSegment(segment) {
            throw .badSegment(String(segment))
        }
        guard segments.count == 1 || segments[0] != "ds" else { throw .reservedFolder }
        return DesignPath(rawValue: raw)
    }

    public init?(_ raw: String) {
        guard let path = try? Self.validate(raw) else { return nil }
        self = path
    }

    private init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The file name without its folders or `.dc.html` ("Cart" for "flows/Cart.dc.html"): what
    /// a `<dc-import name>` names, unique within a design regardless of case.
    public var stem: String {
        let name = rawValue.split(separator: "/").last.map(String.init) ?? rawValue
        return String(name.dropLast(Self.fileExtension.count))
    }

    /// The name a view record uses for it: everything before `.dc.html` percent-encoded the way
    /// `encodeURIComponent` does, so a folder's `/` reads `%2F` (view-state.md).
    public var viewName: String {
        let base = rawValue.dropLast(Self.fileExtension.count)
        return DesignElementID.encodeComponent(String(base)) + Self.fileExtension
    }

    public var description: String { rawValue }

    public static func < (lhs: DesignPath, rhs: DesignPath) -> Bool { lhs.rawValue < rhs.rawValue }

    private static func isSegment(_ segment: Substring) -> Bool {
        guard let first = segment.utf8.first, isWordByte(first) else { return false }
        return segment.utf8.allSatisfy { isWordByte($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    /// Whether `name` may be a design system's folder under `ds/`: `[a-z0-9][a-z0-9_-]{0,63}`.
    public static func isSystemNamespace(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        func lowerAlnum(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) }
        guard lowerAlnum(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy { lowerAlnum($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// Whether `id` may name a page or a note: `[A-Za-z0-9_-]{1,40}`.
    public static func isIndexID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...40).contains(bytes.count) else { return false }
        return bytes.allSatisfy { isWordByte($0) || $0 == UInt8(ascii: "-") }
    }
}

extension DesignPath: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        do {
            self = try Self.validate(raw)
        } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: error.description)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
