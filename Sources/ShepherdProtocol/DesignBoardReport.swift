import Foundation

// The report after a write (docs/designs.md › Write reports): what the design agent can't see
// from a green "Updated A.dc.html" — a dropped `</span>`, a second root, a root that no longer
// matches its frame, how much changed, an import of a board that isn't there, and the
// off-system values the write introduced. Pure over the board's text; the store builds one per
// board a write changed and the extension words it.

/// A compact line diff: what changed, a few of the changed lines, and how many more there were.
public struct DesignTextDiff: Hashable, Sendable, Codable {
    public var added: Int
    public var removed: Int
    /// Changed lines as `-14 <old text>` and `+14 <new text>`, in order, each cut short.
    public var lines: [String]
    /// Changed lines past the ones shown.
    public var more: Int

    public init(added: Int, removed: Int, lines: [String], more: Int) {
        self.added = added
        self.removed = removed
        self.lines = lines
        self.more = more
    }

    /// Past this many lines on either side a diff is counted, not listed.
    static let maxLines = 60_000

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private struct Changes {
        var old: [String]
        var new: [String]
        var removed: Set<Int>
        var inserted: Set<Int>
    }

    private static func changes(_ old: String, _ new: String) -> Changes {
        let o = split(old), n = split(new)
        guard o.count <= maxLines, n.count <= maxLines else {
            return Changes(old: o, new: n, removed: Set(1...max(1, o.count)), inserted: Set(1...max(1, n.count)))
        }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in n.difference(from: o) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset + 1)
            case .insert(let offset, _, _): inserted.insert(offset + 1)
            }
        }
        return Changes(old: o, new: n, removed: removed, inserted: inserted)
    }

    /// The lines (from 1) `old` loses and `new` gains.
    public static func changedLines(old: String, new: String) -> (removed: Set<Int>, inserted: Set<Int>) {
        let found = changes(old, new)
        return (found.removed, found.inserted)
    }

    /// The change from `old` to `new`, showing at most `shown` lines, each cut to `width` characters.
    public static func between(_ old: String, _ new: String, shown: Int = 5, width: Int = 100) -> DesignTextDiff {
        let found = changes(old, new)
        var lines: [String] = []
        var i = 0, j = 0
        func text(_ line: String) -> String {
            let flat = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
            return flat.count > width ? String(flat.prefix(width - 1)) + "…" : flat
        }
        while i < found.old.count || j < found.new.count {
            if i < found.old.count, found.removed.contains(i + 1) {
                lines.append("-\(i + 1) \(text(found.old[i]))")
                i += 1
            } else if j < found.new.count, found.inserted.contains(j + 1) {
                lines.append("+\(j + 1) \(text(found.new[j]))")
                j += 1
            } else {
                i += 1
                j += 1
            }
        }
        return DesignTextDiff(added: found.inserted.count, removed: found.removed.count, lines: Array(lines.prefix(shown)),
                              more: max(0, lines.count - shown))
    }
}

/// What the store tells the agent about one board it just wrote.
public struct DesignBoardReport: Hashable, Sendable, Codable {
    /// The write made the board's file.
    public var created: Bool
    public var bytes: Int
    /// Bytes against the version it replaced; nil for a new board.
    public var delta: Int?
    /// The first place the template's tags stop balancing; nil when they balance.
    public var imbalance: DesignMarkupImbalance?
    /// Top-level elements besides `<helmet>`: a board has exactly one.
    public var roots: Int
    /// The root's fixed px size, `$preview` and the canvas frame's size, as far as the board and
    /// canvas.json give them.
    public var root: DesignBoardCheck.Size?
    public var preview: DesignBoardCheck.Size?
    public var frame: DesignBoardCheck.Size?
    /// Against the version it replaced; nil for a new or unchanged board.
    public var diff: DesignTextDiff?
    /// `<dc-import>` names that no board answers to.
    public var missingImports: [String]
    /// What the write was held to: the systems' names; nil when the design has no tokens to check against.
    public var tokenSource: String?
    /// Off-system values the write introduced and left in the board.
    public var offSystem: [DesignTokenFinding]
    /// Values a snap replaced.
    public var snapped: [DesignTokenReplacement]

    public init(created: Bool, bytes: Int, delta: Int? = nil, imbalance: DesignMarkupImbalance? = nil, roots: Int = 1,
                root: DesignBoardCheck.Size? = nil, preview: DesignBoardCheck.Size? = nil, frame: DesignBoardCheck.Size? = nil,
                diff: DesignTextDiff? = nil, missingImports: [String] = [], tokenSource: String? = nil,
                offSystem: [DesignTokenFinding] = [], snapped: [DesignTokenReplacement] = []) {
        self.created = created
        self.bytes = bytes
        self.delta = delta
        self.imbalance = imbalance
        self.roots = roots
        self.root = root
        self.preview = preview
        self.frame = frame
        self.diff = diff
        self.missingImports = missingImports
        self.tokenSource = tokenSource
        self.offSystem = offSystem
        self.snapped = snapped
    }

    /// Whether anything in it is worth the agent's attention: a refusal in all but name.
    public var hasProblem: Bool {
        imbalance != nil || roots != 1 || !missingImports.isEmpty || !offSystem.isEmpty
            || (root != nil && preview != nil && root != preview) || (root != nil && frame != nil && root != frame)
    }
}

public enum DesignBoardReporter {
    /// The report for `new`, the text a write left in `path`, against `old` (nil: a new board).
    /// `boards` are the board files the design has (imports are checked against them); `frame`
    /// is the board's entry in canvas.json when it has one; `enforcement` is what holding the
    /// write to the design's tokens found (nil: no tokens to hold it to).
    public static func report(path: DesignPath, old: String?, new: String, frame: DesignIndex.Board?, boards: Set<DesignPath>,
                              tokens: DesignTokenSet?, enforcement: DesignTokenCheck.Enforcement?) -> DesignBoardReport {
        var report = DesignBoardReport(created: old == nil, bytes: new.utf8.count)
        if let old { report.delta = new.utf8.count - old.utf8.count }
        if let old, old != new { report.diff = DesignTextDiff.between(old, new) }
        report.preview = DesignBoardCheck.previewSize(of: new)
        if let frame { report.frame = DesignBoardCheck.Size(width: frame.w, height: frame.h) }
        if let tree = DesignBoardTree(source: new) {
            report.imbalance = tree.imbalance
            report.roots = tree.roots.count
            report.root = DesignBoardCheck.rootSize(of: new, template: tree.template)
            var missing: [String] = []
            for reference in DesignImports.references(in: tree, of: path) where !reference.isDynamic {
                if let target = reference.target, boards.contains(target) { continue }
                if !missing.contains(reference.name) { missing.append(reference.name) }
            }
            report.missingImports = missing
        } else {
            report.roots = 0
        }
        if let tokens, !tokens.isEmpty {
            report.tokenSource = tokens.source
            report.offSystem = enforcement?.remaining ?? []
            report.snapped = enforcement?.replacements ?? []
        }
        return report
    }
}
