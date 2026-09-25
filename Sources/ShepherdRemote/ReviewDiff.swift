import Foundation
import ShepherdProtocol

// What a review makes of a diff, shared by the Mac's review pane and the iOS client: line
// comments, the message Request changes and Commit send the agent, a file for a path a tool call
// named, and a file's rows with long runs folded.

/// A reviewer's comment on one diff line.
public struct ReviewComment: Identifiable, Hashable, Sendable {
    public let fileID: String
    public let lineID: Int
    public let filePath: String
    public let lineNumber: Int
    public let marker: String
    public let content: String
    public var text: String
    public var createdAt = Date()

    public var id: String { "\(fileID):\(lineID)" }
    public var path: String { filePath }
    public var line: Int { lineNumber }

    public init(
        fileID: String,
        lineID: Int,
        filePath: String,
        lineNumber: Int,
        marker: String = " ",
        content: String = "",
        text: String
    ) {
        self.fileID = fileID
        self.lineID = lineID
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.marker = marker
        self.content = content
        self.text = text
    }

    /// The comment on `line` of `file`; nil for blank text (saving a blank comment removes it).
    public init?(text: String, line: DiffLine, in file: DiffFile) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(fileID: file.id, lineID: line.id, filePath: file.displayPath, lineNumber: line.newLine ?? line.oldLine ?? 0,
                  marker: line.kind.reviewMarker, content: line.text, text: trimmed)
    }
}

/// The review as the agent's next message: every comment in file then line order, quoting its
/// line, then the overall comment.
public func formatReview(files: [DiffFile], comments: [ReviewComment], summary: String, reference: String? = nil) -> String {
    formatReview(fileIDs: files.map(\.id), comments: comments, summary: summary, reference: reference)
}

/// `formatReview` ordered by file ids (`DiffFile.id`, `ChangesFile.id`: the path) rather than
/// loaded diffs: the Changes pane lists files before it loads their hunks.
public func formatReview(fileIDs: [String], comments: [ReviewComment], summary: String, reference: String? = nil) -> String {
    var output = ["Diff review (\(reference ?? "working tree vs HEAD")):", ""]
    let fileOrder = Dictionary(fileIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    let orderedComments = comments.filter {
        !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.sorted { lhs, rhs in
        let leftFile = fileOrder[lhs.fileID] ?? Int.max
        let rightFile = fileOrder[rhs.fileID] ?? Int.max
        if leftFile != rightFile { return leftFile < rightFile }
        if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber < rhs.lineNumber }
        return lhs.lineID < rhs.lineID
    }

    if orderedComments.isEmpty {
        output.append("No line comments.")
    } else {
        for (index, comment) in orderedComments.enumerated() {
            if index > 0 { output.append("") }
            output.append("\(comment.filePath):\(comment.lineNumber) [\(comment.marker) \(comment.content)]")
            output.append(contentsOf: comment.text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "  \($0)" }
            )
        }
    }

    let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedSummary.isEmpty {
        output.append("")
        output.append("Overall: \(trimmedSummary)")
    }
    return output.joined(separator: "\n")
}

/// The most files a commit request names; the rest are counted.
public let reviewCommitRequestFileLimit = 50

/// Commit: the agent commits the files under review, named so it can't decide there is nothing
/// left (a new file it never staged), addressing the review first when it has notes.
public func formatCommitRequest(files: [DiffFile], comments: [ReviewComment], summary: String, reference: String? = nil) -> String {
    var output = files.isEmpty ? ["Commit these changes."] : ["Commit these changes:"]
    output += files.prefix(reviewCommitRequestFileLimit).map { file in
        switch ReviewFileStatus(file) {
        case .added: "- \(file.displayPath) (new)"
        case .deleted: "- \(file.displayPath) (deleted)"
        case .renamed: "- \(file.displayPath) (renamed from \(file.oldPath ?? "?"))"
        case .modified: "- \(file.displayPath)"
        }
    }
    if files.count > reviewCommitRequestFileLimit {
        output.append("- and \(files.count - reviewCommitRequestFileLimit) more")
    }
    let hasNotes = !comments.isEmpty || !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if hasNotes {
        output += ["", "Before committing, address the review below.", "",
                   formatReview(files: files, comments: comments, summary: summary, reference: reference)]
    }
    return output.joined(separator: "\n")
}

extension DiffLine.Kind {
    /// The sign a review quotes a line with.
    public var reviewMarker: String {
        switch self {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }
}

/// The diff file `path` names: exact, or either path ending in the other (tool calls report
/// absolute or cwd-relative paths; diff paths are repository-relative).
public func reviewFile(matching path: String, in files: [DiffFile]) -> DiffFile? {
    files.first { $0.displayPath == path }
        ?? files.first { path.hasSuffix("/" + $0.displayPath) || $0.displayPath.hasSuffix("/" + path) }
}

// MARK: Rows

/// Runs of more same-kind lines than this fold (DESIGN.md › Right pane).
public let reviewCollapseThreshold = 8

/// One rendered row of a file's diff.
public struct ReviewRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case hunk(String)
        case line(DiffLine)
        /// A folded run: its key, how many lines, their kind, and "20–32".
        case collapsed(key: String, count: Int, kind: DiffLine.Kind, range: String)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// A file's rows with long runs folded (DESIGN.md › Right pane): more than eight same-kind lines
/// in a row keep a few at each end and fold the middle into one strip. `expandedRuns` nil
/// expands everything.
public func reviewRows(_ file: DiffFile, expandedRuns: Set<String>?, threshold: Int = reviewCollapseThreshold) -> [ReviewRow] {
    var rows: [ReviewRow] = []
    for hunk in file.hunks {
        let hunkKey = "\(file.id)\u{0}\(hunk.id)"
        rows.append(ReviewRow(id: hunkKey, kind: .hunk(hunk.header)))
        var index = 0
        let lines = hunk.lines
        while index < lines.count {
            var end = index
            while end + 1 < lines.count, lines[end + 1].kind == lines[index].kind { end += 1 }
            let run = index...end
            let key = "\(hunkKey)\u{0}\(index)"
            let head = lines[index].kind == .context ? 3 : 5
            let tail = lines[index].kind == .context ? 3 : 1
            if run.count > threshold, run.count > head + tail + 1, !(expandedRuns?.contains(key) ?? true) {
                for i in index..<(index + head) { rows.append(line(hunkKey: hunkKey, lines[i])) }
                let folded = (index + head)...(end - tail)
                let numbers = folded.compactMap { lines[$0].newLine ?? lines[$0].oldLine }
                let range = numbers.first.map { first in "\(first)–\(numbers.last ?? first)" } ?? ""
                rows.append(ReviewRow(id: key, kind: .collapsed(key: key, count: folded.count, kind: lines[index].kind, range: range)))
                for i in (end - tail + 1)...end { rows.append(line(hunkKey: hunkKey, lines[i])) }
            } else {
                for i in run { rows.append(line(hunkKey: hunkKey, lines[i])) }
            }
            index = end + 1
        }
    }
    return rows

    func line(hunkKey: String, _ line: DiffLine) -> ReviewRow {
        ReviewRow(id: "\(hunkKey)\u{0}l\(line.id)", kind: .line(line))
    }
}
