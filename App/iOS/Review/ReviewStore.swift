import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One review per agent, kept while the app runs, so leaving the changes and coming back keeps
/// the scope, comments, viewed marks and folds (as the Mac keeps an open review's session).
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

/// An agent's review on this device (MobileChanges, MobileDiff, iPadReview, iPadReviewSplit):
/// what the host's Changes engine compares (`changes.v1`: a scope, its files, each file's hunks
/// fetched when it is drawn), or on an older host the working tree's (or the PR's) whole diff;
/// the reviewer's line comments, viewed and collapsed files, folds, and the line being
/// commented on. Send to agent sends the comments as the agent's next turn and the review starts
/// over. Rows are derived once per change of a file, its folds or its prepared text (syntax
/// colors and word diffs, computed off the main thread); views read them and compare values.
@MainActor
@Observable
final class ReviewStore {
    enum PadLayout: Hashable { case docked, full }
    enum DiffStyle: Hashable { case unified, split }

    struct LineKey: Hashable {
        let fileID: String
        let lineID: Int
    }

    /// What a file shows before or instead of its lines.
    enum FileState: Equatable {
        case loading
        case failed(String)
        case binary
        case noLines(renamed: Bool)
        case lines
    }

    let ref: AgentRef
    let finalize: FinalizeStore

    // MARK: What is compared

    /// The host answers the Changes engine (`changes.v1`); older hosts review the working tree
    /// or the PR (`pullRequest`) as one diff.
    private(set) var usesChanges = false
    /// Older hosts: the PR's diff rather than the working tree's.
    var pullRequest = false
    /// Older hosts: whether the files hold the PR's diff, and the reference it was diffed against.
    private(set) var filesArePR = false
    private(set) var reference: String?

    private(set) var overview: ChangesOverview? { didSet { deriveMenus() } }
    private(set) var list: ChangesList? { didSet { deriveMenus() } }
    /// The scope the reviewer picked; nil follows the host's default.
    private(set) var pickedScope: ChangesScope?
    private(set) var options = ChangesOptions()
    /// Changed words get a stronger tint (the More menu's Word diffs).
    private(set) var wordDiffs = true
    private(set) var branches: ChangesBranches?
    private(set) var branchesError: String?
    /// The menus, derived once per overview or list.
    private(set) var scopeOptions: [ChangesScopeOption] = []
    private(set) var commitOptions: [ChangesCommitOption] = []
    private(set) var compare: ChangesCompareText?

    private(set) var loading = false
    private(set) var loaded = false
    private(set) var loadError: String?

    // MARK: Files

    /// The files compared, in the host's order: a scope's list, or an older host's diff.
    private(set) var entries: [ChangesFile] = [] { didSet { derive() } }
    /// Each file's hunks once they arrive (all at once from an older host).
    private(set) var diffs: [String: DiffFile] = [:]
    /// Each loaded file's lines, syntax colored with their changed words tinted.
    private(set) var texts: [String: [Int: AttributedString]] = [:]
    private(set) var fileErrors: [String: String] = [:]
    /// Files the host cut short.
    private(set) var truncated: Set<String> = []
    /// Files drawn folded in the iPad's stacked review: viewed ones fold away.
    private(set) var collapsed: Set<String> = []

    private(set) var comments: [ReviewComment] = [] { didSet { derive() } }
    private(set) var viewed: Set<String> = [] { didSet { derive() } }

    /// The file list's rows and the review's totals, derived with each change.
    private(set) var summaries: [ReviewFileSummary] = []
    private(set) var totals = ReviewTotals(files: 0, added: 0, removed: 0, viewed: 0)
    /// The iPad's file chips, one per row.
    private(set) var chips: [NWFileStrip.Item] = []
    /// Comments by file, then line, so a line finds its comment without a scan.
    private(set) var commentsByFile: [String: [Int: ReviewComment]] = [:]
    private(set) var expandedRuns: [String: Set<String>] = [:]

    /// The line being commented on, and the comment as written so far.
    private(set) var selection: LineKey?
    var draft = ""

    /// iPad: beside the thread or full screen, and the file shown. `diffStyle` is the reviewer's
    /// choice; nil draws split where the diff is wide enough and unified where it is not.
    var padLayout: PadLayout = .docked
    var diffStyle: DiffStyle?
    var currentFile: String?
    /// The base picker is open (the phone's sheet, the iPad's popover).
    var pickingBase = false
    /// The path a route asked for, until a file in the list answers to it.
    @ObservationIgnored private var pendingFocus: String?

    private(set) var submitting = false
    var actionError: String?

    @ObservationIgnored private weak var hosts: MobileHosts?
    @ObservationIgnored private var loadID = UUID()
    /// The connection and side the files were loaded for: showing the review again reloads
    /// only when either changed.
    @ObservationIgnored private var loadedKey: LoadKey?
    /// Hunks by the revision and options they came from: never stale, so switching back to a
    /// scope whose trees did not move costs no request.
    @ObservationIgnored private var diffCache: [FileKey: ChangesFileDiff] = [:]
    @ObservationIgnored private var fileLoads: Set<String> = []
    @ObservationIgnored private var textLoads: Set<String> = []
    /// Files asked for whole (a gap row tapped): their unchanged lines come with the hunks.
    @ObservationIgnored private var wholeFiles: Set<String> = []
    @ObservationIgnored private var fileVersions: [String: Int] = [:]
    @ObservationIgnored private var unifiedCache: [String: CachedRows<ReviewUnifiedRow>] = [:]
    @ObservationIgnored private var splitCache: [String: CachedRows<ReviewSplitDisplayRow>] = [:]

    private struct LoadKey: Equatable {
        let session: UUID?
        let pullRequest: Bool
    }

    private struct FileKey: Hashable {
        let revision: ChangesRevision
        let path: String
        let options: ChangesOptions
    }

    private struct CachedRows<Row> {
        let version: Int
        let expanded: Set<String>
        let gaps: Bool
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

    /// Loads what the review compares; a later load wins over an earlier one.
    func load(hosts: MobileHosts) async {
        self.hosts = hosts
        guard let host = hosts.host(ref.host), host.connectedClient != nil else {
            loadError = hosts.host(ref.host).map { "\($0.name) is offline." } ?? "This host was forgotten."
            return
        }
        usesChanges = host.supports(RemoteProtocol.changesCapability)
        let id = UUID()
        loadID = id
        loading = true
        loadError = nil
        defer { if loadID == id { loading = false } }
        if usesChanges {
            await loadChanges(id: id, host: host)
        } else {
            await loadWorkingTree(id: id, host: host)
        }
    }

    /// An older host's working tree (or PR) as one diff.
    private func loadWorkingTree(id: UUID, host: MobileHost) async {
        let pullRequest = pullRequest
        do {
            let (files, reference) = try remoteReviewFiles(try await query(.review(pullRequest: pullRequest)))
            guard loadID == id else { return }
            self.reference = reference
            filesArePR = pullRequest
            resetFiles()
            diffs = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            entries = files.map(ChangesFile.init(listing:))
            loaded = true
            loadedKey = LoadKey(session: host.session, pullRequest: pullRequest)
        } catch {
            guard loadID == id else { return }
            loadError = reviewErrorText(error)
        }
    }

    /// The scope's list, with the overview (the scope menu, the default scope) alongside it. A
    /// review nobody pointed anywhere opens where the host says: Branch for a worktree agent.
    private func loadChanges(id: UUID, host: MobileHost) async {
        let agent = host.agent(ref.agent)
        let guess = pickedScope ?? overview?.defaultScope ?? (agent?.worktreeBase != nil ? .branch(base: nil) : .uncommitted)
        async let overviewReply = try? query(.changesOverview)
        do {
            let list = try await changesList(guess)
            guard loadID == id else { return }
            apply(list)
            loadedKey = LoadKey(session: host.session, pullRequest: pullRequest)
        } catch {
            guard loadID == id else { return }
            loadError = reviewErrorText(error)
        }
        if case .changesOverview(let overview)? = await overviewReply, loadID == id {
            self.overview = overview
            // The host's default differs from the guess: show what it would have opened on.
            if pickedScope == nil, overview.defaultScope.kind != guess.kind, let list = try? await changesList(overview.defaultScope),
               loadID == id {
                apply(list)
            }
        }
    }

    private func changesList(_ scope: ChangesScope) async throws -> ChangesList {
        guard case .changesList(let list) = try await query(.changesList(scope: scope, options: options)) else {
            throw RemoteReviewError.unexpectedReply
        }
        return list
    }

    /// Shows `list`: its files, and the hunks already fetched for its revision.
    private func apply(_ list: ChangesList) {
        let moved = list.revision != self.list?.revision || list.scope != self.list?.scope
        self.list = list
        if moved {
            resetFiles()
            for file in list.files {
                if let cached = diffCache[fileKey(file, revision: list.revision)] { setDiff(cached, for: file.id) }
            }
        }
        if entries != list.files { entries = list.files }
        loaded = true
    }

    private func resetFiles() {
        diffs = [:]
        texts = [:]
        fileErrors = [:]
        truncated = []
        fileLoads = []
        textLoads = []
        wholeFiles = []
        expandedRuns = [:]
        for id in fileVersions.keys { fileVersions[id, default: 0] &+= 1 }
    }

    /// Asks the host for the scope's files again (Refresh).
    func refresh() {
        guard let hosts else { return }
        Task { await load(hosts: hosts) }
    }

    // MARK: Scope

    /// The scope on screen, or the one on its way.
    var scope: ChangesScope? { list?.scope ?? pickedScope ?? overview?.defaultScope }

    /// "Branch · vs main", "Last turn"; an older host's "working tree vs HEAD".
    var scopeTitle: String {
        if usesChanges { return list?.title ?? scope.map { changesTitle(scope: $0, comparison: nil) } ?? "Changes" }
        return reviewScopeText(pullRequest: filesArePR, reference: reference)
    }

    /// The base Branch compares against now.
    var base: String? {
        if case .branch(let base)? = list?.scope { return base ?? list?.comparison.base }
        if case .branch(let base)? = pickedScope { return base }
        return overview?.defaultBase
    }

    /// Shows `scope`; the files, comments and viewed marks of the scope left behind stay only
    /// where the new one lists the same file.
    func pick(_ scope: ChangesScope) {
        pickedScope = scope
        reloadList()
    }

    /// Compares Branch against `base`.
    func pickBase(_ base: String) { pick(.branch(base: base)) }

    /// A changes card's Review: the turn it ended.
    func show(turn id: UUID) {
        guard pickedScope != .turn(id: id) else { return }
        pickedScope = .turn(id: id)
        loadedKey = nil
    }

    private func reloadList() {
        guard let hosts, let host = hosts.host(ref.host) else { return }
        let id = UUID()
        loadID = id
        loading = true
        Task {
            defer { if loadID == id { loading = false } }
            await loadChanges(id: id, host: host)
        }
    }

    /// The base picker's branches, once per review.
    func loadBranches() async {
        guard usesChanges, branches == nil else { return }
        do {
            guard case .changesBranches(let branches) = try await query(.changesBranches) else { throw RemoteReviewError.unexpectedReply }
            self.branches = branches
            branchesError = nil
        } catch {
            branchesError = reviewErrorText(error)
        }
    }

    func setIgnoreWhitespace(_ on: Bool) {
        guard options.ignoreWhitespace != on else { return }
        options.ignoreWhitespace = on
        reloadList()
    }

    func setFullFiles(_ on: Bool) {
        guard options.fullFiles != on else { return }
        options.fullFiles = on
        reloadList()
    }

    func setWordDiffs(_ on: Bool) {
        guard wordDiffs != on else { return }
        wordDiffs = on
        texts = [:]
        textLoads = []
        for id in diffs.keys {
            fileVersions[id, default: 0] &+= 1
            prepare(id)
        }
    }

    /// The scope's diff as a patch `git apply` takes.
    func patch() async throws -> String {
        guard let revision = list?.revision else { throw RemoteReviewError.notReady }
        guard case .changesPatch(let text, _) = try await query(.changesPatch(revision: revision, options: options)) else {
            throw RemoteReviewError.unexpectedReply
        }
        return text
    }

    private func deriveMenus() {
        let options = overview.map { changesScopeOptions($0, selected: scope, base: base) } ?? []
        if options != scopeOptions { scopeOptions = options }
        let commits = overview.map { changesCommitOptions($0, selected: scope) } ?? []
        if commits != commitOptions { commitOptions = commits }
        let compare = list.map(changesCompareText)
        if compare != self.compare { self.compare = compare }
    }

    // MARK: Files

    func entry(_ id: String?) -> ChangesFile? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    /// The file a path names (a tool call's path, a route's): exact, then by its end.
    func entry(matching path: String?) -> ChangesFile? {
        guard let path, !path.isEmpty else { return nil }
        if let exact = entries.first(where: { $0.path == path || $0.oldPath == path }) { return exact }
        return entries.first { path.hasSuffix("/" + $0.path) || $0.path.hasSuffix("/" + path) }
    }

    func diff(_ id: String?) -> DiffFile? { id.flatMap { diffs[$0] } }

    func state(of id: String) -> FileState {
        if let diff = diffs[id] {
            if diff.isBinary { return .binary }
            return diff.hunks.isEmpty ? .noLines(renamed: diff.isRenamed) : .lines
        }
        if let error = fileErrors[id] { return .failed(error) }
        if entry(id)?.isBinary == true, usesChanges { return .binary }
        return .loading
    }

    /// Shows the file `path` names once the list has it (the changes card's file, an edit line).
    func focus(_ path: String?) {
        guard let path else { return }
        pendingFocus = path
        resolveFocus()
    }

    private func resolveFocus() {
        if let path = pendingFocus, let match = entry(matching: path) {
            pendingFocus = nil
            if currentFile != match.id { currentFile = match.id }
        } else if entry(currentFile) == nil, currentFile != entries.first?.id {
            currentFile = entries.first?.id
        }
    }

    func index(of fileID: String) -> Int? { entries.firstIndex { $0.id == fileID } }

    /// The file after `fileID`, wrapping to the first; nil with one file or none.
    func entry(after fileID: String) -> ChangesFile? {
        guard entries.count > 1, let index = index(of: fileID) else { return nil }
        return entries[(index + 1) % entries.count]
    }

    /// Fetches a file's hunks (and prepares its text) unless it has them or is fetching them.
    func ensure(_ id: String) {
        if diffs[id] != nil {
            prepare(id)
            return
        }
        guard usesChanges, let list, let file = entry(id), !file.isBinary, !fileLoads.contains(id) else { return }
        fileLoads.insert(id)
        let key = fileKey(file, revision: list.revision)
        Task { await loadFile(file, key: key) }
    }

    private func fileKey(_ file: ChangesFile, revision: ChangesRevision) -> FileKey {
        var options = options
        if wholeFiles.contains(file.id) { options.fullFiles = true }
        return FileKey(revision: revision, path: file.path, options: options)
    }

    private func loadFile(_ file: ChangesFile, key: FileKey) async {
        defer { fileLoads.remove(file.id) }
        do {
            let reply = try await query(.changesFile(revision: key.revision, path: file.path, oldPath: file.oldPath, options: key.options))
            guard case .changesFile(let diff) = reply else { throw RemoteReviewError.unexpectedReply }
            diffCache[key] = diff
            guard list?.revision == key.revision, entry(file.id) != nil else { return }
            setDiff(diff, for: file.id)
        } catch {
            guard list?.revision == key.revision else { return }
            fileErrors[file.id] = reviewErrorText(error)
        }
    }

    private func setDiff(_ diff: ChangesFileDiff, for id: String) {
        diffs[id] = diff.file
        if diff.truncated { truncated.insert(id) } else { truncated.remove(id) }
        fileErrors[id] = nil
        texts[id] = nil
        textLoads.remove(id)
        fileVersions[id, default: 0] &+= 1
        prepare(id)
    }

    /// A gap row tapped: asks for the file whole, so every unchanged line comes with it.
    func loadWhole(_ id: String) {
        guard usesChanges, !wholeFiles.contains(id), let list, let file = entry(id) else { return }
        wholeFiles.insert(id)
        fileLoads.insert(id)
        let key = fileKey(file, revision: list.revision)
        Task { await loadFile(file, key: key) }
    }

    /// Whether a gap row can open (the host sends whole files).
    var opensGaps: Bool { usesChanges && !options.fullFiles }

    /// Colors a file's lines and tints its changed words, off the main thread, once.
    private func prepare(_ id: String) {
        guard texts[id] == nil, !textLoads.contains(id), let file = diffs[id], !file.isBinary else { return }
        textLoads.insert(id)
        let palette = ReviewTextPalette(Color.nw)
        let words = wordDiffs
        Task {
            let lines = await Task.detached(priority: .userInitiated) { ReviewText.prepare(file, palette: palette, words: words) }.value
            guard textLoads.contains(id), diffs[id] == file else { return }
            textLoads.remove(id)
            texts[id] = lines
            fileVersions[id, default: 0] &+= 1
        }
    }

    func toggleViewed(_ fileID: String) {
        if viewed.contains(fileID) {
            viewed.remove(fileID)
            collapsed.remove(fileID)
        } else {
            viewed.insert(fileID)
            collapsed.insert(fileID)
        }
    }

    func toggleCollapsed(_ fileID: String) {
        if collapsed.contains(fileID) { collapsed.remove(fileID) } else { collapsed.insert(fileID) }
    }

    /// Collapse all, or expand all once every file is collapsed.
    func toggleCollapseAll() {
        collapsed = allCollapsed ? [] : Set(entries.map(\.id))
    }

    var allCollapsed: Bool { !entries.isEmpty && entries.allSatisfy { collapsed.contains($0.id) } }

    func expand(_ key: String, in fileID: String) {
        expandedRuns[fileID, default: []].insert(key)
    }

    /// A file's unified rows with its current folds; with `gaps`, a hunk's head is the count of
    /// unchanged lines before it (the iPad's), else its header (the phone's). The same array
    /// until the file, its text or its folds change.
    func unifiedRows(_ fileID: String, gaps: Bool) -> [ReviewUnifiedRow] {
        guard let file = diffs[fileID] else { return [] }
        let expanded = expandedRuns[fileID] ?? []
        let version = fileVersions[fileID] ?? 0
        if let cached = unifiedCache[fileID], cached.version == version, cached.expanded == expanded, cached.gaps == gaps { return cached.rows }
        let colors = texts[fileID] ?? [:]
        let gapsBefore = gaps ? reviewHunkGaps(file) : [:]
        let rows: [ReviewUnifiedRow] = reviewRows(file, expandedRuns: expanded).map { row in
            switch row.kind {
            case .hunk(let header): return .hunk(id: row.id, header: header, gap: gaps ? gapsBefore[row.id] ?? 0 : nil)
            case .line(let line): return .line(content(line, id: row.id, colors: colors))
            case .collapsed(let key, let count, let kind, let range): return .fold(id: key, count: count, kind: NWDiffLineKind(kind), range: range)
            }
        }
        unifiedCache[fileID] = CachedRows(version: version, expanded: expanded, gaps: gaps, rows: rows)
        return rows
    }

    /// A file's rows side by side.
    func splitRows(_ fileID: String) -> [ReviewSplitDisplayRow] {
        guard let file = diffs[fileID] else { return [] }
        let expanded = expandedRuns[fileID] ?? []
        let version = fileVersions[fileID] ?? 0
        if let cached = splitCache[fileID], cached.version == version, cached.expanded == expanded { return cached.rows }
        let colors = texts[fileID] ?? [:]
        let gapsBefore = reviewHunkGaps(file)
        let rows: [ReviewSplitDisplayRow] = reviewSplitRows(file, expandedRuns: expanded).map { row in
            switch row.kind {
            case .hunk(let header): return .hunk(id: row.id, header: header, gap: gapsBefore[row.id] ?? 0)
            case .pair(let old, let new):
                return .pair(id: row.id, old: old.map { content($0, id: "\(row.id)\u{0}o", colors: colors) },
                             new: new.map { content($0, id: "\(row.id)\u{0}n", colors: colors) })
            case .collapsed(let key, let count, let kind, let range, let side):
                return .fold(id: row.id, key: key, count: count, kind: NWDiffLineKind(kind), range: range, side: NWSplitFoldRow.Side(side))
            }
        }
        splitCache[fileID] = CachedRows(version: version, expanded: expanded, gaps: true, rows: rows)
        return rows
    }

    private func content(_ line: DiffLine, id: String, colors: [Int: AttributedString]) -> NWDiffLineContent {
        NWDiffLineContent(id: id, key: line.id, kind: NWDiffLineKind(line.kind), oldNumber: line.oldLine, newNumber: line.newLine,
                          text: colors[line.id] ?? AttributedString(line.text), source: line.text)
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

    private func line(_ key: LineKey) -> DiffLine? {
        diffs[key.fileID]?.hunks.lazy.flatMap(\.lines).first { $0.id == key.lineID }
    }

    /// Saves the draft on the selected line; a blank draft removes its comment.
    func saveDraft() {
        guard let selection, let line = line(selection) else { return }
        let path = entry(selection.fileID)?.path ?? selection.fileID
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let comment = text.isEmpty ? nil : ReviewComment(fileID: selection.fileID, lineID: line.id, filePath: path,
                                                         lineNumber: line.newLine ?? line.oldLine ?? 0, marker: line.kind.reviewMarker,
                                                         content: line.text, text: text)
        setComment(comment, fileID: selection.fileID, lineID: selection.lineID)
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

    /// Discard: every comment not yet sent.
    func discardComments() {
        comments = []
        clearSelection()
    }

    /// "line 16": the number a reader cites for the selected line.
    var selectionLabel: String? {
        guard let selection, let line = line(selection) else { return nil }
        return "line \(line.newLine ?? line.oldLine ?? 0)"
    }

    // MARK: Sending

    var canSend: Bool { !submitting && !comments.isEmpty }
    /// "Send 1 comment".
    var sendTitle: String { comments.isEmpty ? "Send comments" : reviewSendTitle(comments: comments.count) }
    /// Commit asks for the working tree's files: never from an older host's PR diff.
    var canCommit: Bool { !submitting && (usesChanges || (!entries.isEmpty && !filesArePR)) }

    /// Sends the comments as the agent's next turn; true once the host took it. The next review
    /// opens on what the agent does with them (Last turn).
    func sendComments(hosts: MobileHosts) async -> Bool {
        let text = usesChanges
            ? formatChangesReview(fileIDs: entries.map(\.id), comments: comments, scopeTitle: scopeTitle)
            : formatReview(fileIDs: entries.map(\.id), comments: comments, summary: "", reference: reference)
        return await send(text, hosts: hosts)
    }

    /// Asks the agent to commit what is under review, with the review's comments.
    func commit(hosts: MobileHosts) async -> Bool {
        let files = entries.map { diffs[$0.id] ?? DiffFile(listing: $0) }
        return await send(formatCommitRequest(files: files, comments: comments, summary: "", reference: usesChanges ? scopeTitle : reference),
                          hosts: hosts)
    }

    private func send(_ text: String, hosts: MobileHosts) async -> Bool {
        guard !submitting else { return false }
        guard let client = hosts.host(ref.host)?.connectedClient else {
            actionError = "The host is offline. Your comments are kept."
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
        // Sent: the review closes, as the Mac's does; the next one starts over, on the agent's reply.
        loadedKey = nil
        comments = []
        viewed = []
        collapsed = []
        expandedRuns = [:]
        if usesChanges { pickedScope = .lastTurn }
        clearSelection()
        return true
    }

    private func query(_ query: RemoteAgentQuery) async throws -> RemoteAgentResult {
        guard let client = hosts?.host(ref.host)?.connectedClient else {
            throw RemoteHostClientError.rejected(code: "not_sent", message: "The host is offline.")
        }
        return try await client.agentQuery(agentID: ref.agent, query: query)
    }

    // MARK: Derived

    private func derive() {
        let (rows, totals) = reviewSummaries(listed: entries, comments: comments, viewed: viewed)
        if summaries != rows {
            summaries = rows
            chips = rows.map {
                NWFileStrip.Item(id: $0.id, path: $0.path, status: NWFileStatus($0.status), added: $0.added, removed: $0.removed, isViewed: $0.viewed)
            }
        }
        if self.totals != totals { self.totals = totals }
        let byFile = comments.reduce(into: [String: [Int: ReviewComment]]()) { $0[$1.fileID, default: [:]][$1.lineID] = $1 }
        if commentsByFile != byFile { commentsByFile = byFile }
        resolveFocus()
    }
}

/// A row of a file's unified diff, ready to draw: a hunk's head (its header, or on iPad the
/// unchanged lines before it), a line, or a fold.
enum ReviewUnifiedRow: Identifiable, Equatable {
    case hunk(id: String, header: String, gap: Int?)
    case line(NWDiffLineContent)
    case fold(id: String, count: Int, kind: NWDiffLineKind, range: String)

    var id: String {
        switch self {
        case .hunk(let id, _, _), .fold(let id, _, _, _): id
        case .line(let line): line.id
        }
    }
}

/// A row of a file's diff side by side, ready to draw.
enum ReviewSplitDisplayRow: Identifiable, Equatable {
    case hunk(id: String, header: String, gap: Int)
    case pair(id: String, old: NWDiffLineContent?, new: NWDiffLineContent?)
    case fold(id: String, key: String, count: Int, kind: NWDiffLineKind, range: String, side: NWSplitFoldRow.Side)

    var id: String {
        switch self {
        case .hunk(let id, _, _), .pair(let id, _, _), .fold(let id, _, _, _, _, _): id
        }
    }
}

/// The colors a file's prepared text uses, read on the main actor.
struct ReviewTextPalette: Sendable {
    let keyword, type, string, number, function, comment: Color
    let addedWord, removedWord: Color

    @MainActor init(_ nw: NWPalette) {
        keyword = nw.synKeyword
        type = nw.synType
        string = nw.synString
        number = nw.synNumber
        function = nw.synFunction
        comment = nw.synComment
        // Changed words take the line's tint again, over the line's own: a stronger tint.
        addedWord = nw.doneTint
        removedWord = nw.failedTint
    }
}

/// A file's lines as drawn: syntax colors, and each changed word's stronger tint.
enum ReviewText {
    static func prepare(_ file: DiffFile, palette: ReviewTextPalette, words: Bool) -> [Int: AttributedString] {
        let language = ReviewSyntax.language(forPath: file.displayPath)
        let changed = words ? DiffWords.changes(in: file) : [:]
        var lines: [Int: AttributedString] = [:]
        for line in file.hunks.lazy.flatMap(\.lines) {
            let ranges = changed[line.id] ?? []
            guard language != nil || !ranges.isEmpty else { continue }
            var text = language.map { colored(ReviewSyntax.spans(line.text, language: $0), palette) } ?? AttributedString(line.text)
            let tint = line.kind == .added ? palette.addedWord : palette.removedWord
            for range in DiffWords.stringRanges(ranges, in: line.text) {
                guard let lower = AttributedString.Index(range.lowerBound, within: text),
                      let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
                text[lower..<upper].backgroundColor = tint
            }
            lines[line.id] = text
        }
        return lines
    }

    private static func colored(_ spans: [ReviewSyntax.Span], _ palette: ReviewTextPalette) -> AttributedString {
        var text = AttributedString()
        for span in spans {
            var part = AttributedString(span.text)
            switch span.kind {
            case .keyword?: part.foregroundColor = palette.keyword
            case .type?: part.foregroundColor = palette.type
            case .string?: part.foregroundColor = palette.string
            case .number?: part.foregroundColor = palette.number
            case .function?: part.foregroundColor = palette.function
            case .comment?: part.foregroundColor = palette.comment
            case nil: break
            }
            text += part
        }
        return text
    }
}

extension ChangesFile {
    /// An older host's file as a list entry.
    init(listing file: DiffFile) {
        let status: ChangesFileStatus = file.isNew ? .added : file.isDeleted ? .deleted : file.isRenamed ? .renamed : .modified
        self.init(path: file.id, oldPath: file.isRenamed ? file.oldPath : nil, status: status, added: file.addedCount,
                  removed: file.removedCount, isBinary: file.isBinary)
    }
}

extension DiffFile {
    /// A listed file without its hunks, for the message that names the files.
    init(listing file: ChangesFile) {
        self.init(oldPath: file.oldPath ?? file.path, newPath: file.path, displayPath: file.path, isNew: file.status == .added,
                  isDeleted: file.status == .deleted, isRenamed: file.status == .renamed, isBinary: file.isBinary, hunks: [])
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
