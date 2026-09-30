import Foundation

/// One find-and-replace of a `board_edit` (docs/designs.md › The design agent).
public struct DesignBoardEdit: Hashable, Sendable, Codable {
    /// The exact text to find, whitespace and line endings included. Never empty.
    public var find: String
    public var replace: String
    /// Replace every match. Without it the text must match exactly once.
    public var all: Bool

    public init(find: String, replace: String, all: Bool = false) {
        self.find = find
        self.replace = replace
        self.all = all
    }

    private enum CodingKeys: String, CodingKey { case find, replace, all }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        find = try c.decode(String.self, forKey: .find)
        replace = try c.decode(String.self, forKey: .replace)
        all = try c.decodeIfPresent(Bool.self, forKey: .all) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(find, forKey: .find)
        try c.encode(replace, forKey: .replace)
        if all { try c.encode(true, forKey: .all) }
    }
}

/// What `board_edit` does to a board's text: its edits, in order, each on what the one before it
/// left. Pure; `DesignStore` runs it on the board's current text on its own queue and hands the
/// result to the same write every board write goes through.
///
/// Matching is exact and on bytes: no regular expressions, no Unicode equivalence (so `é` and
/// `e` + U+0301 differ) and no line-ending folding (`\r\n` is two bytes, and a `find` with a
/// bare `\n` does not match inside it). A `find` that must match once is ambiguous when it
/// matches twice, overlapping or not; with `all` the matches are taken left to right without
/// overlapping, as a replace-all does.
public enum DesignBoardEdits {
    /// Edits one call may carry.
    public static let maxEdits = 64

    public struct Applied: Hashable, Sendable {
        public var source: String
        /// How many matches each edit replaced, in order.
        public var replaced: [Int]
    }

    /// Why a call changed nothing. `index` counts from 1, as the agent counts its edits.
    public enum Failure: Error, Hashable, Sendable, CustomStringConvertible {
        case noEdits
        case tooMany(Int)
        case emptyFind(index: Int)
        case notFound(index: Int, of: Int, find: String, hint: String?)
        case ambiguous(index: Int, of: Int, find: String, lines: [Int], excerpts: [String])
        case tooLarge(index: Int, of: Int, bytes: Int)

        public var code: String {
            switch self {
            case .noEdits, .tooMany, .emptyFind: return "invalid_edit"
            case .notFound: return "edit_not_found"
            case .ambiguous: return "edit_ambiguous"
            case .tooLarge: return "board_too_large"
            }
        }

        public var description: String {
            switch self {
            case .noEdits:
                return "board_edit takes at least one edit: {find, replace}"
            case .tooMany(let count):
                return "board_edit takes at most \(DesignBoardEdits.maxEdits) edits, not \(count); split them across calls"
            case .emptyFind(let index):
                return "edit \(index): find is empty; it names the exact text to replace"
            case .notFound(let index, let total, let find, let hint):
                return "edit \(index) of \(total): find matched nothing: \(DesignBoardEdits.quoted(find, limit: 100)). "
                    + (hint.map { $0 + " " } ?? "")
                    + "Copy find from design_read exactly, whitespace included, and keep it to a line or two."
            case .ambiguous(let index, let total, let find, let lines, let excerpts):
                let places = zip(lines, excerpts).prefix(3).map { "line \($0): \($1)" }.joined(separator: "; ")
                return "edit \(index) of \(total): find matched \(lines.count) times: \(DesignBoardEdits.quoted(find, limit: 100)) (\(places)"
                    + (lines.count > 3 ? "; and \(lines.count - 3) more" : "")
                    + "). Add the text around the one you mean until it matches once, or set all to replace every match."
            case .tooLarge(let index, let total, let bytes):
                return "edit \(index) of \(total) would make the board \(bytes) bytes; a board is at most \(DesignBoardCheck.maxBytes)"
            }
        }
    }

    /// `source` with `edits` applied in order. Throws at the first edit that matches nothing, or
    /// several times without `all`; nothing is applied then, since the result is returned whole.
    public static func apply(_ edits: [DesignBoardEdit], to source: String) throws(Failure) -> Applied {
        guard !edits.isEmpty else { throw .noEdits }
        guard edits.count <= maxEdits else { throw .tooMany(edits.count) }
        var bytes = Array(source.utf8)
        var replaced: [Int] = []
        for (offset, edit) in edits.enumerated() {
            let index = offset + 1
            let needle = Array(edit.find.utf8)
            guard !needle.isEmpty else { throw .emptyFind(index: index) }
            let starts = matches(of: needle, in: bytes, overlapping: !edit.all)
            if starts.isEmpty {
                throw .notFound(index: index, of: edits.count, find: edit.find, hint: hint(for: edit.find, in: bytes))
            }
            if !edit.all, starts.count > 1 {
                let lines = starts.map { line(of: $0, in: bytes) }
                throw .ambiguous(index: index, of: edits.count, find: edit.find, lines: lines,
                                 excerpts: starts.prefix(3).map { quoted(lineText(at: $0, in: bytes), limit: 60) })
            }
            let with = Array(edit.replace.utf8)
            let size = bytes.count + starts.count * (with.count - needle.count)
            guard size <= DesignBoardCheck.maxBytes else { throw .tooLarge(index: index, of: edits.count, bytes: size) }
            var next: [UInt8] = []
            next.reserveCapacity(size)
            var from = 0
            for start in starts {
                next.append(contentsOf: bytes[from..<start])
                next.append(contentsOf: with)
                from = start + needle.count
            }
            next.append(contentsOf: bytes[from...])
            bytes = next
            replaced.append(starts.count)
        }
        return Applied(source: String(decoding: bytes, as: UTF8.self), replaced: replaced)
    }

    /// Where `needle` starts in `bytes`: every start when `overlapping`, else left to right
    /// without overlapping.
    static func matches(of needle: [UInt8], in bytes: [UInt8], overlapping: Bool) -> [Int] {
        guard let first = needle.first, bytes.count >= needle.count else { return [] }
        var found: [Int] = []
        var i = 0
        let last = bytes.count - needle.count
        while i <= last {
            guard let at = bytes[i...last].firstIndex(of: first) else { break }
            if bytes[at..<(at + needle.count)].elementsEqual(needle) {
                found.append(at)
                i = overlapping ? at + 1 : at + needle.count
            } else {
                i = at + 1
            }
        }
        return found
    }

    /// Where a failed `find` went wrong, when that can be said: a board of CRLF lines against a
    /// `find` of LF ones, or the place its first line does appear.
    private static func hint(for find: String, in bytes: [UInt8]) -> String? {
        let crlf = matches(of: Array("\r\n".utf8), in: bytes, overlapping: false).isEmpty == false
        if crlf, find.contains("\n"), !find.contains("\r\n") {
            return "The board's lines end in CRLF (\\r\\n) and find's in LF (\\n): give find the \\r\\n line endings, or keep it to one line."
        }
        let firstLine = find.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard firstLine.utf8.count >= 3, firstLine != find else { return nil }
        guard let at = matches(of: Array(firstLine.utf8), in: bytes, overlapping: false).first else { return nil }
        return "Its first line does appear, at line \(line(of: at, in: bytes)) (\(quoted(lineText(at: at, in: bytes), limit: 80))), so the text after it differs."
    }

    private static func line(of offset: Int, in bytes: [UInt8]) -> Int {
        1 + bytes[..<offset].reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    /// The line that holds `offset`, trimmed.
    private static func lineText(at offset: Int, in bytes: [UInt8]) -> String {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = offset
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        return String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `text` on one line between quotes, cut at `limit` characters.
    static func quoted(_ text: String, limit: Int) -> String {
        var flat = text.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: " ")
        if flat.count > limit { flat = String(flat.prefix(limit - 1)) + "…" }
        return "\"" + flat + "\""
    }
}

/// What a `board_edit` left behind: the write as any board write reports it, and how many
/// matches each edit replaced.
public struct DesignBoardEdited: Hashable, Sendable {
    public var result: DesignWriteResult
    public var replaced: [Int]

    public init(result: DesignWriteResult, replaced: [Int]) {
        self.result = result
        self.replaced = replaced
    }
}
