import Foundation

// Word diffs (ChangesUnified, ChangesSplit): the words that changed inside a modified line.
// A run of removed lines pairs, line for line, with the additions that follow it (the split
// view's rows pair them the same way); each pair is diffed token by token (Myers), and the
// tokens that differ come back as UTF-16 ranges of each line's text. Pure and deterministic, so
// the host never sends them: whoever draws a file computes them once, off the main thread.

public enum DiffWords {
    /// Lines longer than this (UTF-16 units) get no word diff: the whole line is the change.
    public static let maxLineLength = 2_000
    /// Lines with more tokens than this get none either.
    public static let maxTokens = 500
    /// A pair whose edit script needs more steps than this is too different to highlight.
    public static let maxEditDistance = 200
    /// Pairs sharing less than this share of the shorter line's text (ignoring whitespace) are
    /// different lines, not an edit of one line: no word diff.
    public static let minSimilarity = 0.3

    /// The changed ranges of every paired line in `file`, by `DiffLine.id`. Lines without a pair
    /// or too different from theirs are absent (draw them as wholly changed).
    public static func changes(in file: DiffFile) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        for hunk in file.hunks { changes(in: hunk, into: &result) }
        return result
    }

    public static func changes(in hunk: DiffHunk) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        changes(in: hunk, into: &result)
        return result
    }

    /// Each removed line with the added line it pairs with, as the split view draws them.
    public static func pairs(in hunk: DiffHunk) -> [(removed: DiffLine, added: DiffLine)] {
        var pairs: [(DiffLine, DiffLine)] = []
        let lines = hunk.lines
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            let count = min(removedEnd - index, addedEnd - removedEnd)
            for offset in 0..<count { pairs.append((lines[index + offset], lines[removedEnd + offset])) }
            index = addedEnd
        }
        return pairs
    }

    private static func changes(in hunk: DiffHunk, into result: inout [Int: [Range<Int>]]) {
        for (removed, added) in pairs(in: hunk) {
            guard let ranges = ranges(old: removed.text, new: added.text) else { continue }
            result[removed.id] = ranges.old
            result[added.id] = ranges.new
        }
    }

    /// The UTF-16 ranges that differ between two versions of a line; nil when they are too long,
    /// too different, or identical.
    public static func ranges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old != new, old.utf16.count <= maxLineLength, new.utf16.count <= maxLineLength else { return nil }
        let a = tokens(old), b = tokens(new)
        guard a.count <= maxTokens, b.count <= maxTokens,
              let script = editScript(a.map(\.text), b.map(\.text)) else { return nil }
        var common = 0
        for (i, _) in script.matches where !a[i].isSpace { common += a[i].range.count }
        let oldSize = a.reduce(0) { $0 + ($1.isSpace ? 0 : $1.range.count) }
        let newSize = b.reduce(0) { $0 + ($1.isSpace ? 0 : $1.range.count) }
        guard min(oldSize, newSize) > 0, Double(common) / Double(min(oldSize, newSize)) >= minSimilarity else { return nil }
        let oldChanged = merge(a, changed: script.oldChanged)
        let newChanged = merge(b, changed: script.newChanged)
        guard !oldChanged.isEmpty || !newChanged.isEmpty else { return nil }
        return (oldChanged, newChanged)
    }

    /// `ranges`' offsets as indices of `text`.
    public static func stringRanges(_ ranges: [Range<Int>], in text: String) -> [Range<String.Index>] {
        let utf16 = text.utf16
        return ranges.compactMap { range in
            guard range.lowerBound >= 0, range.upperBound <= utf16.count else { return nil }
            let lower = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
            let upper = utf16.index(lower, offsetBy: range.count)
            return lower..<upper
        }
    }

    // MARK: Tokens

    struct Token {
        let text: Substring
        /// UTF-16 offsets in the line.
        let range: Range<Int>
        let isSpace: Bool
    }

    private enum Class { case word, space, other }

    /// Words (letters, digits, underscores), runs of whitespace, and every other character alone.
    static func tokens(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var start = line.startIndex
        var startOffset = 0
        var offset = 0
        var current: Class?
        func classify(_ c: Character) -> Class {
            if c.isWhitespace { return .space }
            if c == "_" || c.isLetter || c.isNumber { return .word }
            return .other
        }
        var index = line.startIndex
        while index < line.endIndex {
            let c = line[index]
            let kind = classify(c)
            if let current, current != kind || kind == .other {
                tokens.append(Token(text: line[start..<index], range: startOffset..<offset, isSpace: current == .space))
                start = index
                startOffset = offset
            }
            current = kind
            offset += c.utf16.count
            index = line.index(after: index)
        }
        if let current, start < line.endIndex {
            tokens.append(Token(text: line[start...], range: startOffset..<offset, isSpace: current == .space))
        }
        return tokens
    }

    /// Changed token indices as ranges, with changes separated only by whitespace joined into one.
    private static func merge(_ tokens: [Token], changed: [Int]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var lastToken = -2
        for index in changed.sorted() {
            let range = tokens[index].range
            if let last = ranges.last {
                let gap = (lastToken + 1)..<index
                if gap.isEmpty || gap.allSatisfy({ tokens[$0].isSpace }) {
                    ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
                    lastToken = index
                    continue
                }
            }
            ranges.append(range)
            lastToken = index
        }
        return ranges
    }

    // MARK: Myers

    struct Script {
        var matches: [(Int, Int)] = []
        var oldChanged: [Int] = []
        var newChanged: [Int] = []
    }

    /// Myers' O(ND) shortest edit script between `a` and `b`; nil past `maxEditDistance`.
    static func editScript(_ a: [Substring], _ b: [Substring]) -> Script? {
        let n = a.count, m = b.count
        let maxD = min(n + m, maxEditDistance)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break outer
                }
            }
        }
        guard found else { return nil }
        // Walk the trace back from (n, m), collecting snakes and edits.
        var script = Script()
        var x = n, y = m
        for d in stride(from: trace.count - 1, through: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = d == 0 ? 0 : v[offset + prevK]
            let prevY = d == 0 ? 0 : prevX - prevK
            while x > prevX, y > prevY, x > 0, y > 0 {
                x -= 1
                y -= 1
                script.matches.append((x, y))
            }
            if d > 0 {
                if x == prevX { script.newChanged.append(prevY) } else { script.oldChanged.append(prevX) }
            }
            x = prevX
            y = prevY
        }
        return script
    }
}
