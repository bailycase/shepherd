import Foundation

/// One element of a board, as a view record names it: `File.dc.html#<tid>:<path>`
/// (view-state.md). `tid` numbers every element of the board's template depth-first from 0;
/// `path` is the same element by child position, the top-level index first. Both name one node,
/// so an id whose two halves disagree with the board's source does not resolve.
public struct DesignElementID: Hashable, Sendable, CustomStringConvertible {
    /// The board's view name: the part before `.dc.html` percent-encoded (`DesignPath.viewName`).
    public var board: String
    public var tid: Int
    public var path: [Int]
    /// Which rendering of an element inside `<sc-for>` (`@k`). Read, never written today.
    public var instance: Int?

    /// The largest tid, child index, and path length the grammar can express. An element past
    /// them has no id.
    public static let maxTid = 9999
    public static let maxChildIndex = 99
    public static let maxPathLength = 9
    /// The longest board view name the grammar accepts.
    public static let maxBoardLength = 220

    public init?(board: String, tid: Int, path: [Int], instance: Int? = nil) {
        guard Self.isBoardName(board), Self.isExpressible(tid: tid, path: path) else { return nil }
        if let instance, !(0...999).contains(instance) { return nil }
        self.board = board
        self.tid = tid
        self.path = path
        self.instance = instance
    }

    /// The id of an element of the board at `path`, or nil when the grammar cannot express it.
    public init?(board: DesignPath, element: DesignTemplateElement) {
        self.init(board: board.viewName, tid: element.tid, path: element.path)
    }

    /// Parses an id, refusing anything outside the view record's grammar.
    public init?(_ raw: String) {
        guard let hash = raw.firstIndex(of: "#") else { return nil }
        let board = String(raw[..<hash])
        var rest = raw[raw.index(after: hash)...]
        var instance: Int?
        if let at = rest.firstIndex(of: "@") {
            guard let k = Self.number(rest[rest.index(after: at)...], maxDigits: 3) else { return nil }
            instance = k
            rest = rest[..<at]
        }
        guard let colon = rest.firstIndex(of: ":"),
              let tid = Self.number(rest[..<colon], maxDigits: 4) else { return nil }
        let parts = rest[rest.index(after: colon)...].split(separator: "/", omittingEmptySubsequences: false)
        var path: [Int] = []
        for part in parts {
            guard let index = Self.number(part, maxDigits: 2) else { return nil }
            path.append(index)
        }
        self.init(board: board, tid: tid, path: path, instance: instance)
    }

    public var description: String {
        var text = "\(board)#\(tid):" + path.map(String.init).joined(separator: "/")
        if let instance { text += "@\(instance)" }
        return text
    }

    static func isExpressible(tid: Int, path: [Int]) -> Bool {
        (0...maxTid).contains(tid) && (1...maxPathLength).contains(path.count)
            && path.allSatisfy { (0...maxChildIndex).contains($0) }
    }

    /// `(?:[A-Za-z0-9_.!~*'()-]|%[0-9A-F]{2}){1,200}\.dc\.html`, at most 220 characters.
    static func isBoardName(_ name: String) -> Bool {
        guard name.utf8.count <= maxBoardLength, name.hasSuffix(DesignPath.fileExtension) else { return false }
        let base = Array(name.utf8.dropLast(DesignPath.fileExtension.utf8.count))
        var count = 0
        var i = 0
        while i < base.count {
            if base[i] == UInt8(ascii: "%") {
                guard i + 2 < base.count, isUpperHex(base[i + 1]), isUpperHex(base[i + 2]) else { return false }
                i += 3
            } else {
                guard isUnreserved(base[i]) else { return false }
                i += 1
            }
            count += 1
        }
        return (1...200).contains(count)
    }

    /// `encodeURIComponent`: every byte outside `A-Za-z0-9-_.!~*'()` as `%XX`.
    public static func encodeComponent(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            if isUnreserved(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return out
    }

    private static func isUnreserved(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return "-_.!~*'()".utf8.contains(b)
        }
    }

    private static func isUpperHex(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b)
    }

    private static func number(_ text: Substring, maxDigits: Int) -> Int? {
        guard (1...maxDigits).contains(text.utf8.count), text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int(text)
    }
}

extension DesignElementID: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let id = DesignElementID(raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a design element id: \(raw)")
        }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
