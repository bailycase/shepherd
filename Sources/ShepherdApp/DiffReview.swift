import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdSessions
import ShepherdRemote

struct ReviewComment: Identifiable, Hashable {
    let fileID: String
    let lineID: Int
    let filePath: String
    let lineNumber: Int
    let marker: String
    let content: String
    var text: String
    var createdAt = Date()

    var id: String { "\(fileID):\(lineID)" }
    var path: String { filePath }
    var line: Int { lineNumber }

    init(
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
}

@MainActor
@Observable
final class ReviewSession: Identifiable {
    let id = UUID()
    var loadRequestID = UUID()
    var isSubmitting = false
    var hostReviewPane = false
    let agentID: AgentID
    var paneID: PaneID
    let cwd: String
    /// Mutable because PR mode resolves the base branch asynchronously after
    /// the pane is already open.
    var reference: String?
    /// True while showing the PR diff (reference started as "pr"); drives the
    /// header mode toggle after the concrete ref resolves.
    var isPRMode: Bool = false
    var files: [DiffFile] {
        didSet {
            updateTotals()
            filesVersion &+= 1
        }
    }
    /// Bumped whenever `files` is set, so per-file caches check freshness without comparing lines.
    private(set) var filesVersion = 0
    /// Lines added and removed across `files`, kept with them so the header never sums.
    private(set) var addedCount = 0
    private(set) var removedCount = 0
    var loadError: String?
    /// True until GitDiff.load finishes; the pane opens immediately and
    /// fills in when the diff arrives.
    var isLoading: Bool
    var comments: [ReviewComment] {
        didSet { rebuildCommentIndex() }
    }
    var summary: String
    /// Files the reviewer marked viewed: collapsed, their chips dimmed.
    var viewed: Set<String> = []
    /// The file the strip selected or a "review ›" link asked for; the pane scrolls to it.
    var focusFile: String?
    var focusRequest = UUID()

    /// Comments by file, then by line: a file's section takes one dictionary (unchanged files
    /// compare equal without a scan), and a row finds its comment in O(1).
    private(set) var commentsByFile: [String: [Int: ReviewComment]] = [:]

    struct CommentKey: Hashable {
        let fileID: String
        let lineID: Int
    }

    private func rebuildCommentIndex() {
        commentsByFile = comments.reduce(into: [:]) { $0[$1.fileID, default: [:]][$1.lineID] = $1 }
    }

    private func updateTotals() {
        addedCount = files.reduce(0) { $0 + $1.addedCount }
        removedCount = files.reduce(0) { $0 + $1.removedCount }
    }

    /// Replaces (or with nil removes) the comment on a line, in one write.
    func setComment(_ comment: ReviewComment?, fileID: String, lineID: Int) {
        var next = comments.filter { $0.fileID != fileID || $0.lineID != lineID }
        if let comment { next.append(comment) }
        comments = next
    }

    init(
        agentID: AgentID,
        paneID: PaneID,
        cwd: String,
        reference: String?,
        files: [DiffFile] = [],
        loadError: String? = nil,
        isLoading: Bool = false,
        comments: [ReviewComment] = [],
        summary: String = ""
    ) {
        self.isLoading = isLoading
        self.agentID = agentID
        self.paneID = paneID
        self.cwd = cwd
        self.reference = reference
        self.files = files
        self.loadError = loadError
        self.comments = comments
        self.summary = summary
        rebuildCommentIndex()
        updateTotals()
    }
}

func formatReview(files: [DiffFile], comments: [ReviewComment], summary: String, reference: String? = nil) -> String {
    var output = ["Diff review (\(reference ?? "working tree vs HEAD")):", ""]
    let fileOrder = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($0.element.id, $0.offset) })
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

extension DiffLine.Kind {
    var reviewMarker: String {
        switch self {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }

    var diffKind: NWDiffLineKind {
        switch self {
        case .context: .context
        case .added: .added
        case .removed: .removed
        }
    }
}

extension DiffFile {
    /// The strip's status letter: A new, D deleted, R renamed, otherwise M.
    var reviewStatus: NWFileStatus {
        if isNew { return .added }
        if isDeleted { return .deleted }
        if isRenamed { return .renamed }
        return .modified
    }
}

/// "just now", "12m ago", then the clock time: when a comment was written.
func reviewCommentAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    return nativeClockText(date.timeIntervalSince1970 * 1000)
}

// MARK: Rows

/// The diff file `path` names: exact, or either path ending in the other (tool calls report
/// absolute or cwd-relative paths; diff paths are repository-relative).
func reviewFile(matching path: String, in files: [DiffFile]) -> DiffFile? {
    files.first { $0.displayPath == path }
        ?? files.first { path.hasSuffix("/" + $0.displayPath) || $0.displayPath.hasSuffix("/" + path) }
}

/// One rendered row of a file's diff.
struct ReviewRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case hunk(String)
        case line(DiffLine)
        /// A folded run: its key, how many lines, their kind, and "20–32".
        case collapsed(key: String, count: Int, kind: DiffLine.Kind, range: String)
    }

    let id: String
    let kind: Kind
}

/// A file's rows with long runs folded (spec §9): more than eight same-kind lines in a row keep
/// a few at each end and fold the middle into one strip. `expandedRuns` nil expands everything.
func reviewRows(_ file: DiffFile, expandedRuns: Set<String>?, threshold: Int = AppLayout.diffCollapseThreshold) -> [ReviewRow] {
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

/// The drawable rows: `reviewRows` with each line's syntax colors once they have arrived (plain
/// text until then). Built once per file state, never per render.
func diffRows(_ rows: [ReviewRow], highlight: [Int: AttributedString]?) -> [NWDiffRow] {
    rows.map { row in
        switch row.kind {
        case .hunk(let header):
            .hunk(id: row.id, header: header)
        case .line(let line):
            .line(NWDiffLineContent(id: row.id, key: line.id, kind: line.kind.diffKind, oldNumber: line.oldLine, newNumber: line.newLine,
                                    text: highlight?[line.id] ?? AttributedString(line.text), source: line.text))
        case .collapsed(let key, let count, let kind, let range):
            .fold(id: key, count: count, kind: kind.diffKind, range: range)
        }
    }
}

/// A file's syntax colors by line id. Hunks are highlighted one at a time (each is a fragment of
/// the file); files without a grammar get none.
func reviewHighlight(_ file: DiffFile, style: CodeHighlight.Style) -> [Int: AttributedString] {
    guard !file.isBinary, CodeHighlight.supports(path: file.displayPath) else { return [:] }
    var lines: [Int: AttributedString] = [:]
    for hunk in file.hunks {
        let colored = CodeHighlight.highlightLines(hunk.lines.map(\.text), path: file.displayPath, style: style)
        for (line, text) in zip(hunk.lines, colored) { lines[line.id] = text }
    }
    return lines
}

/// Syntax colors computed for a file, valid for `version` of the session's files.
final class ReviewHighlight: Sendable {
    let file: DiffFile
    let version: Int
    let lines: [Int: AttributedString]

    init(file: DiffFile, version: Int, lines: [Int: AttributedString]) {
        self.file = file
        self.version = version
        self.lines = lines
    }
}

// MARK: Pane state

/// The review pane's view state and actions: folds, expanded runs, the comment being edited, the
/// current file and hunk, and each file's syntax colors (highlighted off the main thread and
/// assigned once per file). One stable object, so sections and rows call it rather than
/// capturing fresh closures, and a file's rows are built once per state rather than per render.
@MainActor
@Observable
final class ReviewPaneModel {
    @ObservationIgnored let session: ReviewSession
    @ObservationIgnored let actions: ReviewActions
    /// Files folded by hand (viewed files fold too).
    var collapsed: Set<String> = []
    /// Folds opened, by file.
    var expandedRuns: [String: Set<String>] = [:]
    /// Files opened whole (⌥-click on a fold).
    var expandedFiles: Set<String> = []
    var editing: ReviewSession.CommentKey?
    var reverting: DiffFile?
    var currentFile: String?
    var currentHunk: String?
    private(set) var highlights: [String: ReviewHighlight] = [:]
    @ObservationIgnored private var rowCache: [String: CachedRows] = [:]

    private struct CachedRows {
        let file: DiffFile
        var version: Int
        let expanded: Set<String>?
        let highlight: ReviewHighlight?
        let rows: [NWDiffRow]
    }

    init(session: ReviewSession, actions: ReviewActions) {
        self.session = session
        self.actions = actions
    }

    /// The Local | PR control.
    var pullRequestMode: Bool {
        get { session.isPRMode }
        set { actions.setPullRequest(newValue) }
    }

    var isConfirmingRevert: Bool {
        get { reverting != nil }
        set { if !newValue { reverting = nil } }
    }

    func isFolded(_ fileID: String) -> Bool {
        collapsed.contains(fileID) || session.viewed.contains(fileID)
    }

    /// `file`'s rows for its current folds and colors; the same array until one of them changes.
    /// Freshness is a version check; only right after a reload is a file compared line by line,
    /// so unchanged files keep their rows and colors.
    func rows(for file: DiffFile) -> [NWDiffRow] {
        let version = session.filesVersion
        let expanded: Set<String>? = expandedFiles.contains(file.id) ? nil : expandedRuns[file.id] ?? []
        let highlight = highlights[file.id].flatMap { $0.version == version || $0.file == file ? $0 : nil }
        if var cached = rowCache[file.id], cached.expanded == expanded, cached.highlight === highlight,
           cached.version == version || cached.file == file {
            if cached.version != version {
                cached.version = version
                rowCache[file.id] = cached
            }
            return cached.rows
        }
        let rows = diffRows(reviewRows(file, expandedRuns: expanded), highlight: highlight?.lines)
        rowCache[file.id] = CachedRows(file: file, version: version, expanded: expanded, highlight: highlight, rows: rows)
        return rows
    }

    /// Highlights every file without colors for its current content, one file at a time off the
    /// main thread; each file's colors land in one assignment. Unchanged files from a reload keep
    /// their colors.
    func highlightFiles(style: CodeHighlight.Style) async {
        let version = session.filesVersion
        let files = session.files.filter { !$0.isBinary && CodeHighlight.supports(path: $0.displayPath) }
        var missing: [DiffFile] = []
        for file in files {
            guard let existing = highlights[file.id], existing.file == file else { missing.append(file); continue }
            if existing.version != version { highlights[file.id] = ReviewHighlight(file: file, version: version, lines: existing.lines) }
        }
        for file in missing {
            let lines = await Task.detached(priority: .utility) { reviewHighlight(file, style: style) }.value
            if Task.isCancelled { return }
            highlights[file.id] = ReviewHighlight(file: file, version: version, lines: lines)
        }
    }

    // MARK: Files

    func toggleFolded(_ fileID: String) {
        if isFolded(fileID) {
            collapsed.remove(fileID)
            session.viewed.remove(fileID)
        } else {
            collapsed.insert(fileID)
        }
    }

    func toggleViewed(_ fileID: String) {
        if session.viewed.contains(fileID) { session.viewed.remove(fileID) } else { session.viewed.insert(fileID) }
    }

    /// Opens one fold, or with `wholeFile` every fold in the file.
    func expandFold(_ key: String, in fileID: String, wholeFile: Bool) {
        if wholeFile { expandedFiles.insert(fileID) } else { expandedRuns[fileID, default: []].insert(key) }
    }

    func expandAllFiles() {
        collapsed = []
        session.viewed = []
    }

    func collapseAllFiles() {
        collapsed = Set(session.files.map(\.id))
    }

    /// Asks the diff to scroll to a file (the strip, n/p).
    func select(_ fileID: String) {
        session.focusFile = fileID
        session.focusRequest = UUID()
    }

    /// The file a pending focus request names, unfolded and made current; nil when none is
    /// pending or it names no file in the diff.
    func takeFocusRequest() -> String? {
        guard let path = session.focusFile, let file = reviewFile(matching: path, in: session.files) else { return nil }
        session.focusFile = nil
        collapsed.remove(file.id)
        session.viewed.remove(file.id)
        currentFile = file.id
        return file.id
    }

    // MARK: Comments

    func startComment(fileID: String, lineID: Int) {
        editing = ReviewSession.CommentKey(fileID: fileID, lineID: lineID)
    }

    func cancelComment() {
        editing = nil
    }

    /// Saves the comment on a line; blank text removes it.
    func saveComment(_ text: String, fileID: String, lineID: Int) {
        defer { editing = nil }
        guard let file = session.files.first(where: { $0.id == fileID }),
              let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.id == lineID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = trimmed.isEmpty ? nil : ReviewComment(
            fileID: file.id, lineID: line.id, filePath: file.displayPath, lineNumber: line.newLine ?? line.oldLine ?? 0,
            marker: line.kind.reviewMarker, content: line.text, text: trimmed)
        session.setComment(comment, fileID: fileID, lineID: lineID)
    }

    func deleteComment(fileID: String, lineID: Int) {
        session.setComment(nil, fileID: fileID, lineID: lineID)
        if editing == ReviewSession.CommentKey(fileID: fileID, lineID: lineID) { editing = nil }
    }

    // MARK: Keyboard

    /// j/k hunks, n/p files, v viewed, c comment on the current hunk's first changed line.
    /// Returns whether the key was one of them.
    func handleKey(_ key: String) -> Bool {
        let files = session.files
        guard !files.isEmpty else { return false }
        let fileIndex = files.firstIndex { $0.id == currentFile } ?? 0
        switch key {
        case "n", "p":
            let next = min(files.count - 1, max(0, fileIndex + (key == "n" ? 1 : -1)))
            select(files[next].id)
        case "j", "k":
            let hunks = files.flatMap { file in file.hunks.map { (file: file.id, key: "\(file.id)\u{0}\($0.id)") } }
            let current = currentHunk.flatMap { hunk in hunks.firstIndex { $0.key == hunk } } ?? -1
            let next = min(hunks.count - 1, max(0, current + (key == "j" ? 1 : -1)))
            guard hunks.indices.contains(next) else { return true }
            currentHunk = hunks[next].key
            currentFile = hunks[next].file
        case "v":
            toggleViewed(files[fileIndex].id)
        case "c":
            let file = files[fileIndex]
            let hunk = currentHunk.flatMap { key in file.hunks.first { "\(file.id)\u{0}\($0.id)" == key } } ?? file.hunks.first
            if let line = hunk?.lines.first(where: { $0.kind != .context }) ?? hunk?.lines.first {
                collapsed.remove(file.id)
                session.viewed.remove(file.id)
                startComment(fileID: file.id, lineID: line.id)
            }
        default:
            return false
        }
        return true
    }
}
