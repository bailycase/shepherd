import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One review per agent, kept while the app runs, so leaving the changes and coming back keeps
/// the comments, viewed marks and folds (as the Mac keeps an open review's session).
@MainActor
@Observable
final class ReviewStores {
    static let shared = ReviewStores()

    @ObservationIgnored private var stores: [AgentRef: ReviewStore] = [:]

    func store(for ref: AgentRef) -> ReviewStore {
        if let store = stores[ref] { return store }
        let store = ReviewStore(ref: ref)
        stores[ref] = store
        return store
    }
}

/// An agent's review on this device (MobileChanges, MobileDiff, iPadReview boards): the host's
/// diff (working tree vs HEAD, or the PR), the reviewer's line and overall comments, viewed
/// files, folds, and the line being commented on. Request changes and Commit send the agent its
/// next turn, as the Mac's remote review does, and a sent review starts over. Rows are derived
/// once per change of the files or folds; views read them and compare plain values.
@MainActor
@Observable
final class ReviewStore {
    enum PadLayout: Hashable { case docked, full }
    enum DiffStyle: Hashable { case unified, split }

    struct LineKey: Hashable {
        let fileID: String
        let lineID: Int
    }

    let ref: AgentRef

    /// The side the reviewer asked for: the PR (true) or the working tree.
    var pullRequest = false
    private(set) var files: [DiffFile] = [] { didSet { filesVersion &+= 1; derive() } }
    private(set) var reference: String?
    /// Whether `files` hold the PR's diff.
    private(set) var filesArePR = false
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var loadError: String?

    private(set) var comments: [ReviewComment] = [] { didSet { derive() } }
    var summary = ""
    private(set) var viewed: Set<String> = [] { didSet { derive() } }

    /// The file list's rows and the review's totals, derived with each change.
    private(set) var summaries: [ReviewFileSummary] = []
    private(set) var totals = ReviewTotals(files: 0, added: 0, removed: 0, viewed: 0)
    /// Comments by file, then line, so a line finds its comment without a scan.
    private(set) var commentsByFile: [String: [Int: ReviewComment]] = [:]
    private(set) var expandedRuns: [String: Set<String>] = [:]

    /// The line being commented on, and the comment as written so far.
    private(set) var selection: LineKey?
    var draft = ""

    /// iPad: beside the thread or full screen, unified or side by side, and the file shown.
    var padLayout: PadLayout = .docked
    var diffStyle: DiffStyle = .unified
    var currentFile: String?
    /// The path a route asked for, until a file in the diff answers to it.
    @ObservationIgnored private var pendingFocus: String?

    private(set) var submitting = false
    var actionError: String?

    let finalize: FinalizeStore

    @ObservationIgnored private var loadID = UUID()
    /// The connection and side the files were loaded for: showing the review again reloads
    /// only when either changed.
    @ObservationIgnored private var loadedKey: LoadKey?
    @ObservationIgnored private var filesVersion = 0
    @ObservationIgnored private var unifiedCache: [String: CachedRows<NWDiffRow>] = [:]
    @ObservationIgnored private var splitCache: [String: CachedRows<ReviewSplitDisplayRow>] = [:]
    @ObservationIgnored private var highlightCache: [String: (version: Int, lines: [Int: AttributedString])] = [:]

    private struct LoadKey: Equatable {
        let session: UUID?
        let pullRequest: Bool
    }

    private struct CachedRows<Row> {
        let version: Int
        let expanded: Set<String>
        let rows: [Row]
    }

    init(ref: AgentRef) {
        self.ref = ref
        finalize = FinalizeStore(ref: ref)
    }

    // MARK: Loading

    /// Loads unless the files on hand came from this connection and side.
    func loadIfNeeded(hosts: MobileHosts) async {
        guard LoadKey(session: hosts.host(ref.host)?.session, pullRequest: pullRequest) != loadedKey || loadError != nil else { return }
        await load(hosts: hosts)
    }

    /// Loads the host's diff for the side asked for; a later load wins over an earlier one.
    func load(hosts: MobileHosts) async {
        guard let host = hosts.host(ref.host), let client = host.connectedClient else {
            loadError = hosts.host(ref.host).map { "\($0.name) is offline." } ?? "This host was forgotten."
            return
        }
        let id = UUID()
        let pullRequest = pullRequest
        loadID = id
        loading = true
        loadError = nil
        do {
            let result = try await client.agentQuery(agentID: ref.agent, query: .review(pullRequest: pullRequest))
            guard loadID == id else { return }
            let (files, reference) = try remoteReviewFiles(result)
            self.reference = reference
            filesArePR = pullRequest
            self.files = files
            loaded = true
            loadedKey = LoadKey(session: host.session, pullRequest: pullRequest)
        } catch {
            guard loadID == id else { return }
            loadError = reviewErrorText(error)
        }
        loading = false
    }

    // MARK: Files

    func file(_ id: String?) -> DiffFile? {
        guard let id else { return nil }
        return files.first { $0.id == id }
    }

    /// The file a path names (a tool call's path, a route's).
    func file(matching path: String?) -> DiffFile? {
        guard let path else { return nil }
        return reviewFile(matching: path, in: files)
    }

    /// Shows the file `path` names once the diff has it (the changes card's file, an edit line).
    func focus(_ path: String?) {
        guard let path else { return }
        pendingFocus = path
        resolveFocus()
    }

    private func resolveFocus() {
        if let path = pendingFocus, let match = file(matching: path) {
            pendingFocus = nil
            if currentFile != match.id { currentFile = match.id }
        } else if file(currentFile) == nil, currentFile != files.first?.id {
            currentFile = files.first?.id
        }
    }

    func index(of fileID: String) -> Int? { files.firstIndex { $0.id == fileID } }

    /// The file after `fileID`, wrapping to the first; nil with one file or none.
    func file(after fileID: String) -> DiffFile? {
        guard files.count > 1, let index = index(of: fileID) else { return nil }
        return files[(index + 1) % files.count]
    }

    func toggleViewed(_ fileID: String) {
        if viewed.contains(fileID) { viewed.remove(fileID) } else { viewed.insert(fileID) }
    }

    func expand(_ key: String, in fileID: String) {
        expandedRuns[fileID, default: []].insert(key)
    }

    /// A file's unified rows with its current folds, syntax colored; the same array until the
    /// files or its folds change.
    func unifiedRows(_ fileID: String) -> [NWDiffRow] {
        guard let file = file(fileID) else { return [] }
        let expanded = expandedRuns[fileID] ?? []
        if let cached = unifiedCache[fileID], cached.version == filesVersion, cached.expanded == expanded { return cached.rows }
        let colors = highlight(file)
        let rows: [NWDiffRow] = reviewRows(file, expandedRuns: expanded).map { row in
            switch row.kind {
            case .hunk(let header): return .hunk(id: row.id, header: header)
            case .line(let line): return .line(content(line, id: row.id, colors: colors))
            case .collapsed(let key, let count, let kind, let range): return .fold(id: key, count: count, kind: NWDiffLineKind(kind), range: range)
            }
        }
        unifiedCache[fileID] = CachedRows(version: filesVersion, expanded: expanded, rows: rows)
        return rows
    }

    /// A file's rows side by side.
    func splitRows(_ fileID: String) -> [ReviewSplitDisplayRow] {
        guard let file = file(fileID) else { return [] }
        let expanded = expandedRuns[fileID] ?? []
        if let cached = splitCache[fileID], cached.version == filesVersion, cached.expanded == expanded { return cached.rows }
        let colors = highlight(file)
        let rows: [ReviewSplitDisplayRow] = reviewSplitRows(file, expandedRuns: expanded).map { row in
            switch row.kind {
            case .hunk(let header): return .hunk(id: row.id, header: header)
            case .pair(let old, let new):
                return .pair(id: row.id, old: old.map { content($0, id: "\(row.id)\u{0}o", colors: colors) },
                             new: new.map { content($0, id: "\(row.id)\u{0}n", colors: colors) })
            case .collapsed(let key, let count, let kind, let range, let side):
                return .fold(id: row.id, key: key, count: count, kind: NWDiffLineKind(kind), range: range, side: NWSplitFoldRow.Side(side))
            }
        }
        splitCache[fileID] = CachedRows(version: filesVersion, expanded: expanded, rows: rows)
        return rows
    }

    private func content(_ line: DiffLine, id: String, colors: [Int: AttributedString]) -> NWDiffLineContent {
        NWDiffLineContent(id: id, key: line.id, kind: NWDiffLineKind(line.kind), oldNumber: line.oldLine, newNumber: line.newLine,
                          text: colors[line.id] ?? AttributedString(line.text), source: line.text)
    }

    private func highlight(_ file: DiffFile) -> [Int: AttributedString] {
        if let cached = highlightCache[file.id], cached.version == filesVersion { return cached.lines }
        var lines: [Int: AttributedString] = [:]
        if !file.isBinary, let language = ReviewSyntax.language(forPath: file.displayPath) {
            for line in file.hunks.lazy.flatMap(\.lines) {
                lines[line.id] = Self.colored(ReviewSyntax.spans(line.text, language: language))
            }
        }
        highlightCache[file.id] = (filesVersion, lines)
        return lines
    }

    private static func colored(_ spans: [ReviewSyntax.Span]) -> AttributedString {
        let nw = Color.nw
        var text = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            switch span.kind {
            case .keyword?: part.foregroundColor = nw.synKeyword
            case .type?: part.foregroundColor = nw.synType
            case .string?: part.foregroundColor = nw.synString
            case .number?: part.foregroundColor = nw.synNumber
            case .function?: part.foregroundColor = nw.synFunction
            case .comment?: part.foregroundColor = nw.synComment
            case nil: break
            }
            text += part
        }
        return text
    }

    // MARK: Comments

    func comment(fileID: String, lineID: Int) -> ReviewComment? { commentsByFile[fileID]?[lineID] }

    /// Selects a line to comment on, with its comment (if any) as the draft.
    func select(fileID: String, lineID: Int) {
        let key = LineKey(fileID: fileID, lineID: lineID)
        guard selection != key else { return }
        selection = key
        draft = comment(fileID: fileID, lineID: lineID)?.text ?? ""
    }

    /// The draft as a binding, for an editor.
    var draftBinding: Binding<String> {
        Binding(get: { self.draft }, set: { self.draft = $0 })
    }

    func clearSelection() {
        selection = nil
        draft = ""
    }

    /// Saves the draft on the selected line; a blank draft removes its comment.
    func saveDraft() {
        guard let selection, let file = file(selection.fileID),
              let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.id == selection.lineID }) else { return }
        setComment(ReviewComment(text: draft, line: line, in: file), fileID: selection.fileID, lineID: selection.lineID)
        clearSelection()
    }

    func deleteComment(fileID: String, lineID: Int) {
        setComment(nil, fileID: fileID, lineID: lineID)
        if selection == LineKey(fileID: fileID, lineID: lineID) { clearSelection() }
    }

    /// Replaces (or with nil removes) a line's comment, in one write.
    func setComment(_ comment: ReviewComment?, fileID: String, lineID: Int) {
        var next = comments.filter { $0.fileID != fileID || $0.lineID != lineID }
        if let comment { next.append(comment) }
        comments = next
    }

    /// "line 16": the number a reader cites for the selected line.
    var selectionLabel: String? {
        guard let selection, let line = file(selection.fileID)?.hunks.lazy.flatMap(\.lines).first(where: { $0.id == selection.lineID }) else {
            return nil
        }
        return "line \(line.newLine ?? line.oldLine ?? 0)"
    }

    // MARK: Sending

    var hasNotes: Bool { reviewHasNotes(comments: comments, summary: summary) }
    var canRequestChanges: Bool { !submitting && hasNotes }
    /// Commit asks the agent to commit its working tree: never from the PR's diff.
    var canCommit: Bool { !submitting && !files.isEmpty && !filesArePR }

    /// Sends the comments as the agent's next turn; true once the host took it.
    func requestChanges(hosts: MobileHosts) async -> Bool {
        await send(formatReview(files: files, comments: comments, summary: summary, reference: reference), hosts: hosts)
    }

    /// Asks the agent to commit what is under review, with the review's notes.
    func commit(hosts: MobileHosts) async -> Bool {
        await send(formatCommitRequest(files: files, comments: comments, summary: summary, reference: reference), hosts: hosts)
    }

    private func send(_ text: String, hosts: MobileHosts) async -> Bool {
        guard !submitting else { return false }
        guard let client = hosts.host(ref.host)?.connectedClient else {
            actionError = "The host is offline. Your review is kept."
            return false
        }
        submitting = true
        defer { submitting = false }
        let agentID = ref.agent
        do {
            try await remoteReviewSend(text) { request in try await client.nativeThread(agentID: agentID, request: request) }
        } catch {
            actionError = reviewErrorText(error)
            return false
        }
        // Sent: the review closes, as the Mac's does; the next one starts from the new diff.
        comments = []
        summary = ""
        viewed = []
        expandedRuns = [:]
        clearSelection()
        return true
    }

    // MARK: Derived

    private func derive() {
        let (rows, totals) = reviewSummaries(files: files, comments: comments, viewed: viewed)
        if summaries != rows { summaries = rows }
        if self.totals != totals { self.totals = totals }
        let byFile = comments.reduce(into: [String: [Int: ReviewComment]]()) { $0[$1.fileID, default: [:]][$1.lineID] = $1 }
        if commentsByFile != byFile { commentsByFile = byFile }
        resolveFocus()
    }
}

/// A row of a file's diff side by side, ready to draw.
enum ReviewSplitDisplayRow: Identifiable, Equatable {
    case hunk(id: String, header: String)
    case pair(id: String, old: NWDiffLineContent?, new: NWDiffLineContent?)
    case fold(id: String, key: String, count: Int, kind: NWDiffLineKind, range: String, side: NWSplitFoldRow.Side)

    var id: String {
        switch self {
        case .hunk(let id, _), .pair(let id, _, _), .fold(let id, _, _, _, _, _): id
        }
    }
}

extension NWDiffLineKind {
    init(_ kind: DiffLine.Kind) {
        switch kind {
        case .context: self = .context
        case .added: self = .added
        case .removed: self = .removed
        }
    }
}

extension NWFileStatus {
    init(_ status: ReviewFileStatus) {
        switch status {
        case .modified: self = .modified
        case .added: self = .added
        case .deleted: self = .deleted
        case .renamed: self = .renamed
        }
    }
}

extension NWSplitFoldRow.Side {
    init(_ side: ReviewSplitRow.Side) {
        switch side {
        case .old: self = .old
        case .new: self = .new
        case .both: self = .both
        }
    }
}

extension NWReviewFileRow.Item {
    init(_ summary: ReviewFileSummary) {
        self.init(name: summary.name, directory: summary.directory, status: NWFileStatus(summary.status), added: summary.added,
                  removed: summary.removed, comments: summary.comments, viewed: summary.viewed)
    }
}

/// A host's refusal says what went wrong in its message; anything else describes itself.
func reviewErrorText(_ error: Error) -> String {
    if case RemoteHostClientError.rejected(_, let message) = error { return message }
    return String(describing: error)
}
