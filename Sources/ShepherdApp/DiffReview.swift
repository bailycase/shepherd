import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

@MainActor
@Observable
final class ReviewSession: Identifiable {
    let id = UUID()
    var loadRequestID = UUID()
    var isSubmitting = false
    var hostReviewPane = false
    let agentID: AgentID
    var paneID: PaneID
    var cwd: String
    /// The agent's own directory, for a local review. A review of any other directory (an
    /// agent's `review_diff` with `cwd`) says which one in its header.
    let agentCwd: String?
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
            if filesArePR != isPRMode { filesArePR = isPRMode }
        }
    }
    /// Bumped whenever `files` is set, so per-file caches check freshness without comparing lines.
    private(set) var filesVersion = 0
    /// Whether `files` hold the PR diff. Follows `isPRMode` only once that side's files land, so
    /// the pane swaps one whole diff for the other rather than the old files for a spinner.
    private(set) var filesArePR = false
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

    /// The reviewed directory's name while it is not the agent's own, else nil.
    var otherDirectoryName: String? {
        guard let agentCwd, (cwd as NSString).standardizingPath != (agentCwd as NSString).standardizingPath else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    /// Points the review at another repository or worktree. Comments, the summary, and viewed
    /// marks belonged to the old diff, so they go with it; the pane starts over (`ReviewPane`
    /// keys its state on `cwd`).
    func retarget(cwd: String) {
        self.cwd = cwd
        files = []
        comments = []
        summary = ""
        viewed = []
        loadError = nil
        focusFile = nil
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
        agentCwd: String? = nil,
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
        self.agentCwd = agentCwd
        self.reference = reference
        self.files = files
        self.loadError = loadError
        self.comments = comments
        self.summary = summary
        rebuildCommentIndex()
        updateTotals()
    }
}

extension DiffLine.Kind {
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

// MARK: Touched files

/// The files the running agent is editing (`nativeTouchedPaths`), reparsed only when the turn's
/// edit and write calls change. The review's host re-renders on every thread publish (each
/// streamed token, each keystroke in the thread's composer), and a write call's arguments hold
/// the whole file.
@MainActor
final class ReviewTouchedPaths {
    private struct Call: Equatable {
        let entryID: String
        let arguments: String?
    }

    private let compute: ([NativeThreadMessage], Bool) -> Set<String>
    private var calls: [Call]?
    private var paths: Set<String> = []

    init(compute: @escaping ([NativeThreadMessage], Bool) -> Set<String> = nativeTouchedPaths) {
        self.compute = compute
    }

    func paths(_ messages: [NativeThreadMessage], running: Bool) -> Set<String> {
        guard running else {
            calls = nil
            return []
        }
        let turn = messages.lastIndex { $0.role == "user" }.map { messages.index(after: $0) } ?? messages.startIndex
        let calls = messages[turn...].compactMap { message in
            message.toolName == "edit" || message.toolName == "write" ? Call(entryID: message.entryID, arguments: message.argumentsText) : nil
        }
        if calls != self.calls {
            self.calls = calls
            paths = compute(messages, true)
        }
        return paths
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
    /// The directory this pane's diff came from. The pane starts over when the review is
    /// retargeted (`ReviewPane`), so a confirmed Revert acts on the diff the user saw.
    @ObservationIgnored let cwd: String
    /// Files folded by hand (viewed files fold too).
    var collapsed: Set<String> = []
    /// Folds opened, by file.
    var expandedRuns: [String: Set<String>] = [:]
    /// Files opened whole (⌥-click on a fold).
    var expandedFiles: Set<String> = []
    var editing: ReviewSession.CommentKey?
    var reverting: DiffFile?
    /// The Commit… sheet while it is open.
    var commitStore: ReviewCommitStore?
    var currentFile: String?
    var currentHunk: String?
    private(set) var highlights: [String: ReviewHighlight] = [:]
    /// Counts the changes the diff eases open or shut in place: a file folding, a fold of hidden
    /// lines opening, a comment or its editor coming or going. A big file, a file scrolled up
    /// under its pinned header, a whole file opened at once, and Expand or Collapse All land at
    /// once.
    private(set) var disclosures = 0
    /// Whether the current file last moved by j/k/n/p: keyboard navigation lands at once, where
    /// a click or a "review ›" link scrolls there.
    @ObservationIgnored private(set) var movedByKey = false
    @ObservationIgnored private var keyFocusRequest: UUID?
    @ObservationIgnored private var rowCache: [String: CachedRows] = [:]
    /// Where each file's rows start in the diff's visible area, while its section is loaded, and
    /// the height of a file header: a file sits in its place when its rows start below its
    /// header, and has scrolled up under its pinned header when they start above.
    @ObservationIgnored private var rowsTops: [String: CGFloat] = [:]
    @ObservationIgnored private var headerHeight: CGFloat?

    /// The most rows a fold eases open or shut; past it the diff changes at once.
    static let easedRowLimit = 60

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
        cwd = session.cwd
    }

    /// The Local | PR control.
    var pullRequestMode: Bool {
        get { session.isPRMode }
        set { actions.setPullRequest(newValue) }
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
        easeFold(of: fileID)
        if isFolded(fileID) {
            collapsed.remove(fileID)
            session.viewed.remove(fileID)
        } else {
            collapsed.insert(fileID)
        }
    }

    /// Marking a file viewed folds it; unmarking it opens it again.
    func toggleViewed(_ fileID: String) {
        easeFold(of: fileID)
        if session.viewed.contains(fileID) { session.viewed.remove(fileID) } else { session.viewed.insert(fileID) }
    }

    /// Opens one fold.
    func expandFold(_ key: String, in fileID: String) {
        let hidden = session.files.first { $0.id == fileID }.flatMap { file in
            rows(for: file).lazy.compactMap { row -> Int? in
                if case .fold(key, let count, _, _) = row { count } else { nil }
            }.first
        }
        if let hidden, hidden <= Self.easedRowLimit { disclosures += 1 }
        expandedRuns[fileID, default: []].insert(key)
    }

    /// Eases a file's fold when its rows are few enough and the file sits in its place. Folding a
    /// file read under its pinned header moves the diff under the reader (the rows below take
    /// the folded rows' place), which only reads as a jump, so it lands at once.
    private func easeFold(of fileID: String) {
        guard sitsInPlace(fileID), let file = session.files.first(where: { $0.id == fileID }),
              rows(for: file).count <= Self.easedRowLimit else { return }
        disclosures += 1
    }

    private func sitsInPlace(_ fileID: String) -> Bool {
        guard let top = rowsTops[fileID], let headerHeight else { return false }
        return top >= headerHeight - 0.5
    }

    /// Where a file's rows start in the diff's visible area (its section reports it while loaded).
    func noteRowsTop(_ top: CGFloat, of fileID: String) {
        rowsTops[fileID] = top
    }

    func noteHeaderHeight(_ height: CGFloat) {
        headerHeight = height
    }

    /// Opens every fold in a file (⌥-click on a fold).
    func expandFile(_ fileID: String) {
        expandedFiles.insert(fileID)
    }

    func expandAllFiles() {
        collapsed = []
        session.viewed = []
    }

    func collapseAllFiles() {
        collapsed = Set(session.files.map(\.id))
    }

    /// Asks the diff to scroll to a file (a click on its chip).
    func select(_ fileID: String) {
        requestFocus(fileID, byKey: false)
    }

    private func requestFocus(_ fileID: String, byKey: Bool) {
        session.focusFile = fileID
        session.focusRequest = UUID()
        keyFocusRequest = byKey ? session.focusRequest : nil
    }

    /// A click on a file's header makes it current.
    func point(at fileID: String) {
        movedByKey = false
        currentFile = fileID
    }

    /// The file a pending focus request names, unfolded and made current; nil when none is
    /// pending or it names no file in the diff. `movedByKey` then says whether n/p asked.
    func takeFocusRequest() -> String? {
        guard let path = session.focusFile, let file = reviewFile(matching: path, in: session.files) else { return nil }
        movedByKey = keyFocusRequest == session.focusRequest
        keyFocusRequest = nil
        session.focusFile = nil
        collapsed.remove(file.id)
        session.viewed.remove(file.id)
        currentFile = file.id
        return file.id
    }

    // MARK: Comments

    func startComment(fileID: String, lineID: Int) {
        disclosures += 1
        editing = ReviewSession.CommentKey(fileID: fileID, lineID: lineID)
    }

    func cancelComment() {
        disclosures += 1
        editing = nil
    }

    /// Saves the comment on a line; blank text removes it.
    func saveComment(_ text: String, fileID: String, lineID: Int) {
        disclosures += 1
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
        disclosures += 1
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
            requestFocus(files[next].id, byKey: true)
        case "j", "k":
            let hunks = files.flatMap { file in file.hunks.map { (file: file.id, key: "\(file.id)\u{0}\($0.id)") } }
            let current = currentHunk.flatMap { hunk in hunks.firstIndex { $0.key == hunk } } ?? -1
            let next = min(hunks.count - 1, max(0, current + (key == "j" ? 1 : -1)))
            guard hunks.indices.contains(next) else { return true }
            movedByKey = true
            currentHunk = hunks[next].key
            currentFile = hunks[next].file
        case "v":
            toggleViewed(files[fileIndex].id)
        case "c":
            let file = files[fileIndex]
            let hunk = currentHunk.flatMap { key in file.hunks.first { "\(file.id)\u{0}\($0.id)" == key } } ?? file.hunks.first
            if let line = hunk?.lines.first(where: { $0.kind != .context }) ?? hunk?.lines.first {
                // Opening a folded file for the comment follows the fold's own rule.
                if isFolded(file.id) { easeFold(of: file.id) }
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
