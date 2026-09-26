import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The Changes pane's rows for one file (ChangesSplit, ChangesUnified, FoldRow): unified lines or
// split pairs, with unmodified lines folded. Pure, so the unit tier pins the rules; the pane
// builds a file's rows once per state (its layout, reveals, colors) and never while drawing.

/// How the diff is laid out: side by side, or one column.
enum ChangesLayout: Equatable, Sendable {
    case split, unified
}

/// The pane's choice: split when it is at least 900pt wide, else unified, until the reader picks
/// one (the toolbar's toggle, ⌥U).
enum ChangesLayoutChoice: Equatable, Sendable {
    case automatic, split, unified

    static let splitMinWidth: CGFloat = 900

    func resolved(width: CGFloat) -> ChangesLayout {
        switch self {
        case .automatic: width >= Self.splitMinWidth ? .split : .unified
        case .split: .split
        case .unified: .unified
        }
    }
}

/// A fold of unmodified lines: the old line numbers it hides, and whether they came with the
/// diff (a run inside a full file) or sit between hunks (the file must be fetched whole first).
struct ChangesFoldSpan: Equatable, Sendable {
    let lines: ClosedRange<Int>
    let loaded: Bool

    /// The lines a reveal shows: the 20 at the fold's bottom edge (up), the 20 at its top (down),
    /// or all of them.
    func revealed(_ reveal: NWDiffReveal, step: Int = ChangesRows.revealStep) -> ClosedRange<Int> {
        switch reveal {
        case .all: lines
        case .up: max(lines.lowerBound, lines.upperBound - step + 1)...lines.upperBound
        case .down: lines.lowerBound...min(lines.upperBound, lines.lowerBound + step - 1)
        }
    }
}

enum ChangesRows {
    /// Unchanged lines kept beside a change before the rest fold (git's own context).
    static let context = 3
    /// Lines one reveal arrow shows.
    static let revealStep = 20
    /// The fewest unchanged lines a fold hides; a shorter run shows.
    static let minimumFold = 4

    /// A fold's id: the file's, then the old lines it hides and whether they are loaded.
    static func foldID(fileID: String, span: ChangesFoldSpan) -> String {
        "\(fileID)\u{0}f\(span.lines.lowerBound)-\(span.lines.upperBound)\(span.loaded ? "" : "g")"
    }

    /// The span a fold's id names.
    static func span(ofFold id: String) -> ChangesFoldSpan? {
        guard let marker = id.range(of: "\u{0}f", options: .backwards) else { return nil }
        var tail = id[marker.upperBound...]
        let loaded = !tail.hasSuffix("g")
        if !loaded { tail = tail.dropLast() }
        let bounds = tail.split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
        return ChangesFoldSpan(lines: bounds[0]...bounds[1], loaded: loaded)
    }

    /// `file`'s rows. `revealed` holds old line numbers of unchanged lines the reader opened;
    /// `colors` are syntax colors by line id and `words` word-diff ranges (UTF-16) by line id.
    /// A modified line's changed words sit on a second layer of its tint (`wordTint`).
    @MainActor
    static func rows(_ file: DiffFile, layout: ChangesLayout, revealed: IndexSet = [], truncated: Bool = false,
                     colors: [Int: AttributedString]? = nil, words: [Int: [Range<Int>]]? = nil) -> [NWChangesRow] {
        let tints = (added: Color.nw.doneTint, removed: Color.nw.failedTint)
        return rows(file, layout: layout, revealed: revealed, truncated: truncated, colors: colors, words: words, tints: tints)
    }

    static func rows(_ file: DiffFile, layout: ChangesLayout, revealed: IndexSet, truncated: Bool,
                     colors: [Int: AttributedString]?, words: [Int: [Range<Int>]]?,
                     tints: (added: Color, removed: Color)) -> [NWChangesRow] {
        if file.isBinary { return [.notice(id: "\(file.id)\u{0}binary", text: "Binary file")] }
        var rows: [NWChangesRow] = []
        func content(_ line: DiffLine) -> NWDiffLineContent {
            var text = colors?[line.id] ?? AttributedString(line.text)
            if let ranges = words?[line.id], line.kind != .context {
                let tint = line.kind == .added ? tints.added : tints.removed
                for range in DiffWords.stringRanges(ranges, in: line.text) {
                    if let attributed = Range(range, in: text) { text[attributed].backgroundColor = tint }
                }
            }
            return NWDiffLineContent(id: "\(file.id)\u{0}\(line.id)", key: line.id, kind: line.kind.diffKind,
                                     oldNumber: line.oldLine, newNumber: line.newLine, text: text, source: line.text)
        }
        func fold(_ span: ChangesFoldSpan, up: Bool, down: Bool) {
            rows.append(.fold(NWDiffFold(id: foldID(fileID: file.id, span: span), count: span.lines.count, revealsUp: up, revealsDown: down)))
        }
        // Consecutive shown lines, laid out together (split pairs a run of removals with the
        // additions after it).
        var block: [DiffLine] = []
        func flush() {
            guard !block.isEmpty else { return }
            switch layout {
            case .unified: rows.append(contentsOf: block.map { .line(content($0)) })
            case .split: rows.append(contentsOf: pairs(block).map { old, new in
                .pair(id: "\(file.id)\u{0}p\((old ?? new)!.id)", old: old.map(content), new: new.map(content))
            })
            }
            block = []
        }

        var previousOldEnd = 0
        let hunks = file.hunks.filter { !$0.lines.isEmpty }
        for (hunkIndex, hunk) in hunks.enumerated() {
            // Lines between hunks came without the diff: a fold that fetches the file whole.
            if let firstOld = firstOldLine(hunk), firstOld - 1 > previousOldEnd {
                let span = ChangesFoldSpan(lines: (previousOldEnd + 1)...(firstOld - 1), loaded: false)
                flush()
                fold(span, up: true, down: hunkIndex > 0)
            }
            let lines = hunk.lines
            let near = nearChanges(lines)
            let hasChanges = near.contains(true)
            var hidden: [DiffLine] = []
            func closeHidden(atEnd: Bool) {
                guard !hidden.isEmpty else { return }
                // A run too short to be worth a fold row stays in view.
                guard hidden.count >= minimumFold else {
                    block.append(contentsOf: hidden)
                    hidden = []
                    return
                }
                let numbers = hidden.compactMap(\.oldLine)
                if let first = numbers.first, let last = numbers.last {
                    flush()
                    let atStart = rows.isEmpty
                    fold(ChangesFoldSpan(lines: first...last, loaded: true), up: !atEnd, down: !atStart)
                }
                hidden = []
            }
            for (index, line) in lines.enumerated() {
                let open = line.oldLine.map { revealed.contains($0) } ?? false
                // A hunk without changes is a whole unchanged file: nothing is kept around it.
                if (near[index] && hasChanges) || open {
                    closeHidden(atEnd: false)
                    block.append(line)
                } else {
                    hidden.append(line)
                }
            }
            let last = hunkIndex == hunks.count - 1
            closeHidden(atEnd: last)
            previousOldEnd = lastOldLine(hunk) ?? previousOldEnd
        }
        flush()
        if truncated {
            rows.append(.notice(id: "\(file.id)\u{0}truncated", text: "The rest of this file is left out: it is too long to show."))
        }
        return rows
    }

    /// Whether each line is a change or within `context` lines of one: two passes, so a whole
    /// file costs its length, not its length times its changes.
    static func nearChanges(_ lines: [DiffLine]) -> [Bool] {
        var distance = Array(repeating: Int.max, count: lines.count)
        var last = Int.min / 2
        for index in lines.indices {
            if lines[index].kind != .context { last = index }
            distance[index] = index - last
        }
        last = Int.max / 2
        for index in lines.indices.reversed() {
            if lines[index].kind != .context { last = index }
            distance[index] = min(distance[index], last - index)
        }
        return distance.map { $0 <= context }
    }

    /// Each unchanged line beside itself; each run of removals beside the additions after it,
    /// line for line, the longer side's extra lines against filler (the pairing `DiffWords` uses).
    static func pairs(_ lines: [DiffLine]) -> [(DiffLine?, DiffLine?)] {
        var result: [(DiffLine?, DiffLine?)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            switch line.kind {
            case .context:
                result.append((line, line))
                index += 1
            case .removed, .added:
                var removed: [DiffLine] = []
                while index < lines.count, lines[index].kind == .removed { removed.append(lines[index]); index += 1 }
                var added: [DiffLine] = []
                while index < lines.count, lines[index].kind == .added { added.append(lines[index]); index += 1 }
                for offset in 0..<max(removed.count, added.count) {
                    result.append((offset < removed.count ? removed[offset] : nil, offset < added.count ? added[offset] : nil))
                }
            }
        }
        return result
    }

    /// The old line number a hunk starts at: its first line with one, less the additions before it.
    static func firstOldLine(_ hunk: DiffHunk) -> Int? {
        guard let index = hunk.lines.firstIndex(where: { $0.oldLine != nil }), let number = hunk.lines[index].oldLine else {
            // Only additions: they follow the old line the header names.
            return oldStart(hunk.header).map { $0 + 1 }
        }
        return number
    }

    static func lastOldLine(_ hunk: DiffHunk) -> Int? {
        hunk.lines.last { $0.oldLine != nil }?.oldLine ?? oldStart(hunk.header)
    }

    /// "@@ -12,5 +12,6 @@" → 12.
    static func oldStart(_ header: String) -> Int? {
        guard let minus = header.firstIndex(of: "-") else { return nil }
        let digits = header[header.index(after: minus)...].prefix { $0.isNumber }
        return Int(digits)
    }

    /// Re-anchors comments to `file` after its lines were fetched again (a whole file, another
    /// scope): the same side's line with the same number and text keeps the comment; others keep
    /// their text and cite, but anchor to no line.
    static func reanchor(_ comments: [ReviewComment], in file: DiffFile) -> [ReviewComment] {
        let lines = file.hunks.flatMap(\.lines)
        return comments.map { comment in
            guard comment.fileID == file.id, comment.lineID >= 0 else { return comment }
            let match = lines.first { line in
                line.kind.reviewMarker == comment.marker && line.text == comment.content
                    && (line.kind == .removed ? line.oldLine : line.newLine) == comment.lineNumber
            }
            guard let match, match.id != comment.lineID else { return comment }
            var moved = ReviewComment(fileID: comment.fileID, lineID: match.id, filePath: comment.filePath, lineNumber: comment.lineNumber,
                                      marker: comment.marker, content: comment.content, text: comment.text)
            moved.createdAt = comment.createdAt
            return moved
        }
    }
}

/// A file's diff in a Changes list: the status letter and counts the list gave, for files whose
/// hunks have not arrived yet.
extension ChangesFile {
    var nwStatus: NWFileStatus {
        switch status {
        case .added: .added
        case .deleted: .deleted
        case .renamed: .renamed
        case .modified: .modified
        }
    }
}
