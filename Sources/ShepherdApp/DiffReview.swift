import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

/// What a review reads from the host's Changes engine (docs/changes.md): this Mac's
/// `server.changes`, or a remote host's `changes*` queries. A review without one (an older
/// remote host, or an agent's `review_diff` naming a git reference) loads its diff the old way.
struct ChangesEngine {
    var overview: @MainActor () async throws -> ChangesOverview
    var list: @MainActor (ChangesScope, ChangesOptions) async throws -> ChangesList
    /// Every file's hunks from the list's revision, and the ones cut short.
    var diffs: @MainActor (ChangesList, ChangesOptions) async throws -> (files: [DiffFile], truncated: Set<String>)
    /// One file, whole (a fold between hunks opened).
    var file: @MainActor (ChangesRevision, ChangesFile, ChangesOptions) async throws -> ChangesFileDiff
    var branches: @MainActor () async throws -> ChangesBranches
    var patch: @MainActor (ChangesRevision, ChangesOptions) async throws -> (text: String, truncated: Bool)
}

/// Which menu of the Changes pane is open.
enum ChangesMenu: Equatable {
    case scope
    /// The Commits submenu beside the scope menu.
    case commits
    case base
    case options
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
    var cwd: String
    /// The agent's own directory, for a local review. A review of any other directory (an
    /// agent's `review_diff` with `cwd`) says which one in its header.
    let agentCwd: String?
    /// A legacy review's git reference (an agent's `review_diff` reference, or the PR's).
    var reference: String?
    /// A legacy review showing its PR diff.
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
    /// Whether `files` hold the PR diff (legacy reviews). Follows `isPRMode` only once that side's
    /// files land, so the pane swaps one whole diff for the other rather than the old files for a
    /// spinner.
    private(set) var filesArePR = false
    /// Lines added and removed across `files`, kept with them so the header never sums.
    private(set) var addedCount = 0
    private(set) var removedCount = 0
    var loadError: String?
    /// The load found nothing to compare rather than failing ("No turn yet.", not a repository):
    /// the pane says so quietly.
    var loadErrorIsNotice = false
    /// True until the diff arrives; the pane opens immediately and fills in when it does.
    var isLoading: Bool
    var comments: [ReviewComment] {
        didSet { rebuildCommentIndex() }
    }
    /// A legacy review's overall comment (the Changes pane has none: anything else is said in the
    /// thread).
    var summary: String
    /// Files the reviewer marked viewed: folded, their chips dimmed.
    var viewed: Set<String> = []
    /// The file the strip selected or a "review ›" link asked for; the pane scrolls to it.
    var focusFile: String?
    var focusRequest = UUID()
    /// The pane drawing this review, for the side pane's ⋯ menu (Expand and Collapse All Files).
    @ObservationIgnored weak var paneModel: ReviewPaneModel?

    // MARK: Changes

    /// The engine this review reads from; nil for a legacy review.
    @ObservationIgnored var engine: ChangesEngine?
    /// What the pane compares.
    var scope: ChangesScope = .uncommitted
    /// The reader picked the scope (the scope menu, a card's Review): the engine's default and
    /// the Last turn rule no longer move it.
    var scopeChosen = false
    /// The list on screen: its files' letters and counts, its title, the compare row, and the
    /// revision its hunks came from.
    var list: ChangesList?
    /// The scope menu's diffstats, commits and pull request; nil until the engine answers.
    var overview: ChangesOverview?
    /// The base picker's branches; asked for when the picker opens.
    var branches: ChangesBranches?
    var options = ChangesOptions(fullFiles: true)
    var wordDiffs = true
    var layoutChoice: ChangesLayoutChoice = .automatic
    /// Files cut short at `ChangesLimits.fileLines`.
    var truncated: Set<String> = []
    /// When the review was last sent (ms since the epoch): the agent's reply turns the pane to
    /// Last turn, unless the reader picks a scope meanwhile.
    var sentAt: Double?

    /// Comments by file, then by line: a file's section takes one dictionary (unchanged files
    /// compare equal without a scan), and a row finds its comment in O(1).
    private(set) var commentsByFile: [String: [Int: ReviewComment]] = [:]

    struct CommentKey: Hashable {
        let fileID: String
        let lineID: Int
    }

    /// A comment on a whole file (the header's Comment on the file) sits on this line id.
    static let fileLineID = -1

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

    /// The scope's name in the toolbar and the review message: "Branch · vs main", "Last turn",
    /// a legacy review's reference.
    var scopeTitle: String {
        if engine != nil { return list?.title ?? changesTitle(scope: scope, comparison: nil) }
        if isPRMode { return reference.map { "Pull request · \($0)" } ?? "Pull request" }
        return reference ?? "Uncommitted"
    }

    /// Points the review at another repository or worktree. Comments, viewed marks and the list
    /// belonged to the old diff, so they go with it; the pane starts over (`ReviewPane` keys its
    /// state on `cwd`).
    func retarget(cwd: String) {
        self.cwd = cwd
        files = []
        comments = []
        summary = ""
        viewed = []
        loadError = nil
        focusFile = nil
        list = nil
        overview = nil
        branches = nil
        truncated = []
    }

    /// Replaces (or with nil removes) the comment on a line, in one write.
    func setComment(_ comment: ReviewComment?, fileID: String, lineID: Int) {
        var next = comments.filter { $0.fileID != fileID || $0.lineID != lineID }
        if let comment { next.append(comment) }
        comments = next
    }

    /// Takes a newly loaded diff: the files, which were cut short, and the comments re-anchored
    /// to the lines they were written on (the lines' ids differ from one load to the next).
    func adopt(files: [DiffFile], truncated: Set<String>) {
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var anchored = comments
        for (fileID, file) in byID where anchored.contains(where: { $0.fileID == fileID }) {
            anchored = ChangesRows.reanchor(anchored, in: file)
        }
        if anchored != comments { comments = anchored }
        if truncated != self.truncated { self.truncated = truncated }
        self.files = files
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

extension ChangesScope {
    /// The toolbar's glyph for the scope.
    var glyph: NWChangesScopeGlyph {
        switch kind {
        case .lastTurn: .lastTurn
        case .uncommitted, .unstaged: .uncommitted
        case .staged: .staged
        case .commits: .commits
        case .branch: .branch
        case .pullRequest: .pullRequest
        }
    }

    /// Whether the new side is the working tree, which Commit… and a file's Revert act on.
    var comparesWorkingTree: Bool {
        switch self {
        case .uncommitted, .unstaged, .branch: true
        case .lastTurn, .turn, .staged, .commits, .pullRequest: false
        }
    }
}

/// "just now", "12m ago", then the clock time: when a comment was written.
func reviewCommentAge(_ date: Date, now: Date = Date()) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
    return nativeClockText(date.timeIntervalSince1970 * 1000)
}

/// A file's syntax colors by line id. Hunks are highlighted one at a time (each is a fragment of
/// the file, or the whole file when it came whole); files without a grammar get none.
func reviewHighlight(_ file: DiffFile, style: CodeHighlight.Style) -> [Int: AttributedString] {
    guard !file.isBinary, CodeHighlight.supports(path: file.displayPath) else { return [:] }
    var lines: [Int: AttributedString] = [:]
    for hunk in file.hunks {
        let colored = CodeHighlight.highlightLines(hunk.lines.map(\.text), path: file.displayPath, style: style)
        for (line, text) in zip(hunk.lines, colored) { lines[line.id] = text }
    }
    return lines
}

/// Syntax colors and word diffs computed for a file, valid for `version` of the session's files.
final class ReviewHighlight: Sendable {
    let file: DiffFile
    let version: Int
    let lines: [Int: AttributedString]
    let words: [Int: [Range<Int>]]

    init(file: DiffFile, version: Int, lines: [Int: AttributedString], words: [Int: [Range<Int>]] = [:]) {
        self.file = file
        self.version = version
        self.lines = lines
        self.words = words
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

/// The Changes pane's view state and actions: its layout, open menus, folded files, revealed
/// lines, the comment being edited, the current file and change, and each file's syntax colors
/// and word diffs (computed off the main thread and assigned once per file). One stable object,
/// so sections and rows call it rather than capturing fresh closures, and a file's rows are built
/// once per state rather than per render.
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
    /// Unchanged lines the reader opened, by file (old line numbers).
    var revealed: [String: IndexSet] = [:]
    var editing: ReviewSession.CommentKey?
    var reverting: DiffFile?
    /// The Commit… sheet while it is open.
    var commitStore: ReviewCommitStore?
    var currentFile: String?
    /// The change j/k… n/p last moved to: its first row's id.
    var currentChange: String?
    var menu: ChangesMenu?
    /// The resolved layout for the pane's width and the reader's choice.
    private(set) var layout: ChangesLayout = .unified
    private(set) var highlights: [String: ReviewHighlight] = [:]
    /// Counts the changes the diff eases open or shut in place: a file folding, a fold opening, a
    /// comment or its editor coming or going. A big file, a file scrolled up under its pinned
    /// header, and Expand or Collapse All land at once.
    private(set) var disclosures = 0
    /// Whether the current file last moved by the keyboard: keyboard navigation lands at once,
    /// where a click or a "review ›" link scrolls there.
    @ObservationIgnored private(set) var movedByKey = false
    @ObservationIgnored private var keyFocusRequest: UUID?
    @ObservationIgnored private var rowCache: [String: CachedRows] = [:]
    @ObservationIgnored private var width: CGFloat = 0
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
        let layout: ChangesLayout
        let revealed: IndexSet
        let truncated: Bool
        let wordDiffs: Bool
        let highlight: ReviewHighlight?
        let rows: [NWChangesRow]
    }

    init(session: ReviewSession, actions: ReviewActions) {
        self.session = session
        self.actions = actions
        cwd = session.cwd
        layout = session.layoutChoice.resolved(width: 0)
    }

    /// A legacy review's Local | PR control.
    var pullRequestMode: Bool {
        get { session.isPRMode }
        set { actions.setPullRequest(newValue) }
    }

    func isFolded(_ fileID: String) -> Bool {
        collapsed.contains(fileID) || session.viewed.contains(fileID)
    }

    // MARK: Layout

    /// The pane's width changed: split at 900pt and up, unless the reader chose.
    func noteWidth(_ width: CGFloat) {
        self.width = width
        updateLayout()
    }

    /// The toolbar's toggle and ⌥U: the other layout, kept from now on.
    func toggleLayout() {
        session.layoutChoice = layout == .split ? .unified : .split
        updateLayout()
    }

    private func updateLayout() {
        let resolved = session.layoutChoice.resolved(width: width)
        if resolved != layout { layout = resolved }
    }

    // MARK: Rows

    /// `file`'s rows for its current layout, reveals and colors; the same array until one of
    /// them changes. Freshness is a version check; only right after a reload is a file compared
    /// line by line, so unchanged files keep their rows and colors.
    func rows(for file: DiffFile) -> [NWChangesRow] {
        let version = session.filesVersion
        let revealed = revealed[file.id] ?? []
        let truncated = session.truncated.contains(file.id)
        let words = session.wordDiffs
        let highlight = highlights[file.id].flatMap { $0.version == version || $0.file == file ? $0 : nil }
        if var cached = rowCache[file.id], cached.layout == layout, cached.revealed == revealed, cached.truncated == truncated,
           cached.wordDiffs == words, cached.highlight === highlight, cached.version == version || cached.file == file {
            if cached.version != version {
                cached.version = version
                rowCache[file.id] = cached
            }
            return cached.rows
        }
        let rows = ChangesRows.rows(file, layout: layout, revealed: revealed, truncated: truncated,
                                    colors: highlight?.lines, words: words ? highlight?.words : nil)
        rowCache[file.id] = CachedRows(file: file, version: version, layout: layout, revealed: revealed, truncated: truncated,
                                       wordDiffs: words, highlight: highlight, rows: rows)
        return rows
    }

    /// Colors and word diffs for every file without them for its current content, one file at a
    /// time off the main thread; each file's land in one assignment. Unchanged files from a
    /// reload keep theirs.
    func highlightFiles(style: CodeHighlight.Style) async {
        let version = session.filesVersion
        let files = session.files.filter { !$0.isBinary }
        var missing: [DiffFile] = []
        for file in files {
            guard let existing = highlights[file.id], existing.file == file else { missing.append(file); continue }
            if existing.version != version {
                highlights[file.id] = ReviewHighlight(file: file, version: version, lines: existing.lines, words: existing.words)
            }
        }
        for file in missing {
            let (lines, words) = await Task.detached(priority: .utility) {
                (reviewHighlight(file, style: style), DiffWords.changes(in: file))
            }.value
            if Task.isCancelled { return }
            highlights[file.id] = ReviewHighlight(file: file, version: version, lines: lines, words: words)
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

    /// Opens a fold: 20 lines up or down, or all of them. Lines between hunks came without the
    /// diff, so the file is fetched whole first (`ReviewActions.loadWholeFile`).
    func reveal(_ foldID: String, _ direction: NWDiffReveal, in fileID: String) {
        guard let span = ChangesRows.span(ofFold: foldID) else { return }
        let lines = span.revealed(direction)
        if lines.count <= Self.easedRowLimit { disclosures += 1 }
        revealed[fileID, default: []].insert(integersIn: lines.lowerBound..<(lines.upperBound + 1))
        if !span.loaded { actions.loadWholeFile(fileID) }
    }

    /// Every unchanged line of a file (its header's Show Whole File). Lines between hunks come
    /// with the file fetched whole.
    func revealWholeFile(_ fileID: String) {
        guard let file = session.files.first(where: { $0.id == fileID }) else { return }
        let rows = rows(for: file)
        let spans = rows.compactMap { row -> ChangesFoldSpan? in
            if case .fold(let fold) = row { ChangesRows.span(ofFold: fold.id) } else { nil }
        }
        guard !spans.isEmpty else { return }
        var lines = revealed[fileID] ?? []
        for span in spans { lines.insert(integersIn: span.lines.lowerBound..<(span.lines.upperBound + 1)) }
        revealed[fileID] = lines
        if spans.contains(where: { !$0.loaded }) { actions.loadWholeFile(fileID) }
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

    func expandAllFiles() {
        collapsed = []
        session.viewed = []
    }

    func collapseAllFiles() {
        collapsed = Set(session.files.map(\.id))
    }

    /// The toolbar's Collapse all: folds every file, or opens them all when they are folded.
    var allFolded: Bool { !session.files.isEmpty && session.files.allSatisfy { isFolded($0.id) } }

    func toggleAllFolded() {
        if allFolded { expandAllFiles() } else { collapseAllFiles() }
    }

    /// Asks the diff to scroll to a file (a click on its chip or row).
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
    /// pending or it names no file in the diff. `movedByKey` then says whether j/k asked.
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

    /// The header's Comment on the file.
    func startFileComment(_ fileID: String) {
        collapsed.remove(fileID)
        startComment(fileID: fileID, lineID: ReviewSession.fileLineID)
    }

    func cancelComment() {
        disclosures += 1
        editing = nil
    }

    /// Saves the comment on a line (or the file); blank text removes it.
    func saveComment(_ text: String, fileID: String, lineID: Int) {
        disclosures += 1
        defer { editing = nil }
        guard let file = session.files.first(where: { $0.id == fileID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lineID == ReviewSession.fileLineID {
            let comment = trimmed.isEmpty ? nil : ReviewComment(fileID: file.id, lineID: lineID, filePath: file.displayPath, lineNumber: 0,
                                                                 marker: " ", content: "", text: trimmed)
            session.setComment(comment, fileID: fileID, lineID: lineID)
            return
        }
        guard let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.id == lineID }) else { return }
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

    // MARK: Menus

    func toggleMenu(_ menu: ChangesMenu) {
        self.menu = self.menu == menu || (menu == .scope && self.menu == .commits) ? nil : menu
    }

    func closeMenu() {
        if menu != nil { menu = nil }
    }

    // MARK: Keyboard

    /// The changes in `file` as the diff draws them: each run of changed rows, by its first row's
    /// id and its first changed line.
    func changes(in file: DiffFile) -> [(row: String, line: Int)] {
        var result: [(String, Int)] = []
        var inChange = false
        for row in rows(for: file) {
            let changed = row.lines.first { $0.kind != .context }
            if let changed, !inChange { result.append((row.id, changed.key)) }
            inChange = changed != nil
        }
        return result
    }

    /// j/k files, n/p changes, v viewed, c comment on the current change's first changed line,
    /// ⌥U the other layout. Returns whether the key was one of them.
    func handleKey(_ key: String, option: Bool = false) -> Bool {
        let files = session.files
        if option {
            guard key == "u" || key == "ü" else { return false }
            toggleLayout()
            return true
        }
        guard !files.isEmpty else { return false }
        let fileIndex = files.firstIndex { $0.id == currentFile } ?? 0
        switch key {
        case "j", "k":
            let next = min(files.count - 1, max(0, fileIndex + (key == "j" ? 1 : -1)))
            currentChange = nil
            requestFocus(files[next].id, byKey: true)
        case "n", "p":
            let all = files.filter { !isFolded($0.id) }.flatMap { file in changes(in: file).map { (file: file.id, row: $0.row) } }
            let current = currentChange.flatMap { change in all.firstIndex { $0.row == change } }
                ?? (key == "n" ? all.firstIndex { $0.file == currentFile }.map { $0 - 1 } : all.firstIndex { $0.file == currentFile }) ?? -1
            let next = min(all.count - 1, max(0, current + (key == "n" ? 1 : -1)))
            guard all.indices.contains(next) else { return true }
            movedByKey = true
            currentChange = all[next].row
            currentFile = all[next].file
        case "v":
            toggleViewed(files[fileIndex].id)
        case "c":
            let file = files[fileIndex]
            let changes = changes(in: file)
            let line = changes.first { $0.row == currentChange }?.line ?? changes.first?.line
            if let line {
                // Opening a folded file for the comment follows the fold's own rule.
                if isFolded(file.id) { easeFold(of: file.id) }
                collapsed.remove(file.id)
                session.viewed.remove(file.id)
                startComment(fileID: file.id, lineID: line)
            }
        default:
            return false
        }
        return true
    }
}
