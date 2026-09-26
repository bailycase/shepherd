import Foundation
import ShepherdProtocol

/// One line of the diff between two versions of an instruction file, as the per-host comparison
/// draws it (removed lines with their old number, added ones with their new number).
public struct InstructionsDiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, removed, added }

    public var kind: Kind
    public var text: String
    /// The line's number, from 1: in the old version for context and removed lines, in the new
    /// one for added lines.
    public var number: Int

    public init(kind: Kind, text: String, number: Int) {
        self.kind = kind
        self.text = text
        self.number = number
    }
}

/// A styled stretch of one editor line (UTF-16 offsets within the line, for the text views that
/// draw it). Plain text has no span.
public struct InstructionsSpan: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        /// A heading's `#` marks, in `textTertiary`.
        case headingMarker
        /// A heading's words, semibold `textPrimary`.
        case heading
        /// A list item's bullet or number, in `lanternText`.
        case bullet
        /// A `code` span, in the syntax string color.
        case code
    }

    public var range: Range<Int>
    public var role: Role

    public init(range: Range<Int>, role: Role) {
        self.range = range
        self.role = role
    }
}

/// The text rules Settings ▸ Instructions shares between the Mac, the iPhone and the iPad, and
/// the host's history: a file's size, how two versions differ, which lines a draft changed, what
/// a save changed in words, and the editor's light Markdown highlighting.
public enum InstructionsText {
    /// About four characters a token: rough on purpose, and labelled "~".
    public static func tokenEstimate(_ text: String) -> Int {
        let characters = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard characters > 0 else { return 0 }
        return max(1, (characters + 2) / 4)
    }

    /// "~640 tokens" (tens past a hundred), "~40 tokens", "empty".
    public static func sizeNote(_ text: String) -> String {
        let tokens = tokenEstimate(text)
        guard tokens > 0 else { return "empty" }
        let rounded = tokens >= 100 ? Int((Double(tokens) / 10).rounded()) * 10 : tokens
        return "~\(rounded) \(rounded == 1 ? "token" : "tokens")"
    }

    /// The file's lines as the editor numbers them: a final newline ends the last line rather
    /// than starting another.
    public static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    /// The line diff from `old` to `new` (a longest common subsequence of lines). Past about two
    /// million line pairs it reports every old line removed and every new one added.
    public static func diff(from old: String, to new: String) -> [InstructionsDiffLine] {
        let a = lines(old), b = lines(new)
        guard a.count * b.count <= 2_000_000 else {
            return a.enumerated().map { InstructionsDiffLine(kind: .removed, text: $0.element, number: $0.offset + 1) }
                + b.enumerated().map { InstructionsDiffLine(kind: .added, text: $0.element, number: $0.offset + 1) }
        }
        // lcs[i][j]: the longest common subsequence of a[i...] and b[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [InstructionsDiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                result.append(InstructionsDiffLine(kind: .context, text: a[i], number: i + 1))
                i += 1; j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                result.append(InstructionsDiffLine(kind: .added, text: b[j], number: j + 1))
                j += 1
            } else {
                result.append(InstructionsDiffLine(kind: .removed, text: a[i], number: i + 1))
                i += 1
            }
        }
        // Within each run of changes, removed lines read first, as the review's diff draws them.
        return regrouped(result)
    }

    /// The draft's lines (from 0) that differ from the saved version: the editor tints them.
    public static func changedLines(saved: String, draft: String) -> Set<Int> {
        Set(diff(from: saved, to: draft).filter { $0.kind == .added }.map { $0.number - 1 })
    }

    /// How many lines differ between two versions ("differs · 2 lines"): a changed line counts
    /// once, however it changed.
    public static func differingLineCount(_ a: String, _ b: String) -> Int {
        var count = 0, removed = 0, added = 0
        for line in diff(from: a, to: b) {
            switch line.kind {
            case .removed: removed += 1
            case .added: added += 1
            case .context:
                count += max(removed, added)
                removed = 0; added = 0
            }
        }
        return count + max(removed, added)
    }

    /// What a save changed, for the host's history: "Added “Never force-push.”", "Removed 2
    /// lines", "Edited 3 lines".
    public static func summary(from old: String, to new: String) -> String {
        let changes = diff(from: old, to: new)
        let added = changes.filter { $0.kind == .added && !isBlank($0.text) }.map(\.text)
        let removed = changes.filter { $0.kind == .removed && !isBlank($0.text) }.map(\.text)
        switch (added.count, removed.count) {
        case (0, 0): return old == new ? "No changes" : "Changed blank lines"
        case (1, 0): return "Added “\(gist(added[0]))”"
        case (let count, 0): return "Added \(count) lines"
        case (0, 1): return "Removed “\(gist(removed[0]))”"
        case (0, let count): return "Removed \(count) lines"
        case (1, 1): return "Edited “\(gist(added[0]))”"
        case (let a, let r): return "Edited \(max(a, r)) lines"
        }
    }

    /// The editor's light Markdown: heading marks and words, a list item's bullet, and code
    /// spans. Everything else is plain.
    public static func highlight(line: String) -> [InstructionsSpan] {
        let units = Array(line.utf16)
        var spans: [InstructionsSpan] = []
        var index = 0
        while index < units.count, units[index] == space { index += 1 }
        let indent = index
        var hashes = 0
        while index < units.count, units[index] == hash, hashes < 7 { index += 1; hashes += 1 }
        if (1...6).contains(hashes), indent < 4, index == units.count || units[index] == space {
            let marker = min(units.count, index + 1)
            spans.append(InstructionsSpan(range: indent..<marker, role: .headingMarker))
            if marker < units.count { spans.append(InstructionsSpan(range: marker..<units.count, role: .heading)) }
            return spans
        }
        index = indent
        if index < units.count, [dash, star, plus].contains(units[index]), index + 1 < units.count, units[index + 1] == space {
            spans.append(InstructionsSpan(range: index..<(index + 1), role: .bullet))
        } else {
            var digits = index
            while digits < units.count, (zero...nine).contains(units[digits]) { digits += 1 }
            if digits > index, digits + 1 < units.count, units[digits] == dot, units[digits + 1] == space {
                spans.append(InstructionsSpan(range: index..<(digits + 1), role: .bullet))
            }
        }
        var open: Int?
        for (offset, unit) in units.enumerated() where unit == backtick {
            if let start = open {
                spans.append(InstructionsSpan(range: start..<(offset + 1), role: .code))
                open = nil
            } else {
                open = offset
            }
        }
        return spans
    }

    // MARK: Suggested lines

    /// The longest line an agent may suggest.
    public static let suggestionLimit = 300

    /// Why a suggested line can't be taken, in words the agent reads; nil when it can.
    public static func suggestionProblem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Suggest the line to add." }
        if trimmed.contains(where: \.isNewline) { return "Suggest one line at a time." }
        if trimmed.count > suggestionLimit { return "Keep the line under \(suggestionLimit) characters." }
        return nil
    }

    /// A suggested line as it goes into a file: trimmed, and a Markdown list item ("- …") unless
    /// it already is one.
    public static func listItem(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let units = Array(trimmed.utf16)
        if units.count > 1, [dash, star, plus].contains(units[0]), units[1] == space { return trimmed }
        var digits = 0
        while digits < units.count, (zero...nine).contains(units[digits]) { digits += 1 }
        if digits > 0, digits + 1 < units.count, units[digits] == dot, units[digits + 1] == space { return trimmed }
        return "- " + trimmed
    }

    /// What makes two lines the same lesson: their words without Markdown marks, case, spacing
    /// or a closing period ("- Never force-push." and "never  force-push" match).
    public static func lineKey(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#-*+>".contains(first) { text.removeFirst() }
        if let dot = text.firstIndex(of: "."), dot > text.startIndex, text[..<dot].allSatisfy(\.isNumber) {
            text = String(text[text.index(after: dot)...])
        }
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.reversed().drop { ".!;:".contains($0) }.reversed())
    }

    /// Whether `text` already has the lesson `line` teaches, on a line of its own.
    public static func holds(_ line: String, in text: String) -> Bool {
        let key = lineKey(line)
        return !key.isEmpty && lines(text).contains { lineKey($0) == key }
    }

    /// `text` with `line` added as its last line.
    public static func appending(_ line: String, to text: String) -> String {
        if text.isEmpty { return line + "\n" }
        return text + (text.hasSuffix("\n") ? "" : "\n") + line + "\n"
    }

    /// `text` without its last line that teaches `line`'s lesson; nil when none does.
    public static func removing(_ line: String, from text: String) -> String? {
        let key = lineKey(line)
        var all = text.components(separatedBy: "\n")
        guard !key.isEmpty, let index = all.lastIndex(where: { lineKey($0) == key }) else { return nil }
        all.remove(at: index)
        return all.joined(separator: "\n")
    }

    /// A draft made on `old` when the saved file became `new` underneath it: lines added at the
    /// end (a suggestion) join the draft's end, so saving the draft keeps them. Any other change
    /// leaves the draft as it is.
    public static func rebased(_ draft: String, from old: String, to new: String) -> String {
        guard new.count > old.count, new.hasPrefix(old), old.isEmpty || old.hasSuffix("\n") else { return draft }
        let added = String(new.dropFirst(old.count))
        if draft.hasSuffix(added) { return draft }
        return draft.isEmpty || draft.hasSuffix("\n") ? draft + added : draft + "\n" + added
    }

    // MARK: Helpers

    private static let space: UInt16 = 0x20, hash: UInt16 = 0x23, dash: UInt16 = 0x2D, star: UInt16 = 0x2A
    private static let plus: UInt16 = 0x2B, dot: UInt16 = 0x2E, backtick: UInt16 = 0x60
    private static let zero: UInt16 = 0x30, nine: UInt16 = 0x39

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A line as the history quotes it: Markdown marks off, at most 48 characters.
    static func gist(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "#-*+>".contains(first) { text.removeFirst() }
        if let dot = text.firstIndex(of: "."), dot > text.startIndex, text[..<dot].allSatisfy(\.isNumber),
           text.index(after: dot) < text.endIndex, text[text.index(after: dot)] == " " {
            text = String(text[text.index(after: dot)...])
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 48 ? String(text.prefix(47)) + "…" : text
    }

    /// Moves each run of changes' removed lines ahead of its added ones, keeping their order.
    private static func regrouped(_ lines: [InstructionsDiffLine]) -> [InstructionsDiffLine] {
        var result: [InstructionsDiffLine] = []
        var removed: [InstructionsDiffLine] = [], added: [InstructionsDiffLine] = []
        func flush() {
            result += removed + added
            removed = []; added = []
        }
        for line in lines {
            switch line.kind {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .context:
                flush()
                result.append(line)
            }
        }
        flush()
        return result
    }
}
