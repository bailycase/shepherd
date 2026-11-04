import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Issues & PRs (PRReview, IssueReview boards): what the destination's sidebar list and page show,
/// read through the host's forge (`SessionServer.forge` on the Mac). Lists and rows are derived
/// once per change (`items`, `counts`), never in a view's body. Nothing polls: a list or page reads
/// again when it opens, on Refresh, and after a change.
@MainActor
@Observable
final class ForgeStore {
    typealias Transport = @MainActor (RemoteForgeRequest) async -> Result<RemoteForgeResult, ForgeError>

    /// The Summary, Changes and Checks tabs of a pull request's page.
    enum Tab: Hashable, CaseIterable { case summary, changes, checks }

    /// What the merge menu sends (PRReviewMerge).
    struct MergeOptions: Equatable {
        var method: ForgeMergeMethod = .squash
        var whenReady = false
        var deleteBranch = true
        var removeWorktree = true
    }

    @ObservationIgnored private let transport: Transport
    /// The clock rows' ages read (previews pin it).
    @ObservationIgnored var now: () -> Date = { Date() }

    // MARK: Lists

    private(set) var repos: [ForgeRepo] = []
    private(set) var reposLoaded = false
    private(set) var repo: String?
    var kind: ForgeKind = .pullRequest { didSet { if kind != oldValue { kindChanged() } } }
    private(set) var lists: [ForgeKind: ForgeList] = [:]
    private(set) var loadingKinds: Set<ForgeKind> = []
    /// Why the repositories or the list couldn't be read: the page's empty state says it.
    private(set) var error: ForgeError?
    private(set) var openSections: [ForgeKind: Set<ForgeSectionID>] = [:]
    private(set) var loadingSections: [ForgeKind: Set<ForgeSectionID>] = [:]
    var query = "" { didSet { if query.isEmpty, results != nil { results = nil; rebuild() } } }
    private(set) var results: ForgeList?
    private(set) var searching = false
    /// The list's elements and the switch's counts, derived once per change.
    private(set) var items: [ForgeListItem] = []
    private(set) var counts: [ForgeKind: Int] = [:]

    // MARK: The page

    private(set) var selection: ForgeItemRef?
    var tab: Tab = .summary { didSet { if tab == .changes, files == nil { loadFiles() } } }
    private(set) var pullRequest: PullRequestDetail?
    private(set) var issue: IssueDetail?
    /// The body, parsed once per load.
    private(set) var bodyBlocks: [NativeMarkdownBlock] = []
    private(set) var detailLoading = false
    private(set) var detailError: ForgeError?
    private(set) var files: PullRequestFiles?
    private(set) var filesLoading = false
    private(set) var filesError: ForgeError?
    /// Failing jobs' log tails, by job.
    private(set) var logs: [Int: String] = [:]
    private(set) var loadingLogs: Set<Int> = []
    /// A change on its way to GitHub; its buttons wait.
    private(set) var working = false
    /// A change GitHub refused, said over the page.
    var actionError: ForgeError?
    /// What an agent action did ("Sent to Add refund events"), with its thread to open.
    var notice: ForgeNotice?
    var mergeOptions = MergeOptions()
    /// Activity shows every event, or only comments and reviews.
    var commentsOnly = false

    // MARK: The main sidebar

    private(set) var sidebar: ForgeSidebar?

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    var repoName: String { repo.map(ForgeItemRef.name(of:)) ?? "" }
    /// The checkout on this host for `repo` (a thread starts there).
    func path(of repo: String) -> String? { repos.first { $0.nameWithOwner == repo }?.path }
    func isPinned(_ ref: ForgeItemRef) -> Bool { sidebar?.pins.contains { $0.pin.ref == ref } == true }

    // MARK: Loading

    /// The page opened: read the repositories once, then the picked one's lists. `opening` (a pin)
    /// picks its repository and stands in for the list's first row.
    func start(opening ref: ForgeItemRef? = nil) async {
        await loadSidebar()
        guard !reposLoaded else { return }
        switch await transport(.repos) {
        case .success(.repos(let found)):
            repos = found
            reposLoaded = true
            error = nil
            let known = ref.flatMap { ref in found.contains { $0.nameWithOwner == ref.repo } ? ref.repo : nil }
            if let ref, selection == nil { selection = ref }
            if repo == nil, let first = known ?? found.first?.nameWithOwner { await selectRepo(first) }
            rebuild()
        case .failure(let failure):
            error = failure
            rebuild()
        default: break
        }
    }

    /// Picks a repository: its pull requests and issues, from the top.
    func selectRepo(_ name: String) async {
        guard name != repo || lists.isEmpty else { return }
        repo = name
        lists = [:]
        results = nil
        query = ""
        openSections = [:]
        loadingSections = [:]
        if selection.map({ $0.repo != name }) == true { clearSelection() }
        rebuild()
        async let pulls: Void = loadList(.pullRequest)
        async let issues: Void = loadList(.issue)
        _ = await (pulls, issues)
        if selection == nil, let first = firstRow { await open(first) }
    }

    /// Reads the repositories, the lists and the page on screen again.
    func refresh() async {
        reposLoaded = false
        error = nil
        switch await transport(.repos) {
        case .success(.repos(let found)):
            repos = found
            reposLoaded = true
        case .failure(let failure): error = failure
        default: break
        }
        if repo == nil, let first = repos.first?.nameWithOwner { repo = first }
        async let pulls: Void = loadList(.pullRequest)
        async let issues: Void = loadList(.issue)
        _ = await (pulls, issues)
        if selection != nil { await loadDetail() }
        await loadSidebar()
    }

    private func loadList(_ kind: ForgeKind) async {
        guard let repo else { return }
        loadingKinds.insert(kind)
        rebuild()
        let open = Array(openSections[kind] ?? [])
        let sections = ForgeSectionID.defaults(for: kind) + open
        let result = await transport(.list(kind: kind, repo: repo, sections: ForgeSectionID.all(for: kind).filter(sections.contains)))
        guard repo == self.repo else { return }
        loadingKinds.remove(kind)
        switch result {
        case .success(.list(let list)):
            lists[kind] = list
            error = nil
        case .failure(let failure): error = failure
        default: break
        }
        rebuild()
    }

    /// Needs my team's review or Closed: opened (read then), or closed again.
    func toggleSection(_ id: ForgeSectionID) async {
        let kind = kind
        if openSections[kind, default: []].contains(id) {
            openSections[kind, default: []].remove(id)
            rebuild()
            return
        }
        openSections[kind, default: []].insert(id)
        guard let repo, lists[kind]?.section(id) == nil else { rebuild(); return }
        loadingSections[kind, default: []].insert(id)
        rebuild()
        let result = await transport(.list(kind: kind, repo: repo, sections: [id]))
        loadingSections[kind, default: []].remove(id)
        guard repo == self.repo else { return }
        switch result {
        case .success(.list(let list)):
            if let section = list.section(id) { lists[kind] = Self.merging(section, into: lists[kind], kind: kind, repo: repo) }
        case .failure(let failure): actionError = failure
        default: break
        }
        rebuild()
    }

    /// `section` in `list`, in `ForgeSectionID.all(for:)` order.
    static func merging(_ section: ForgeSection, into list: ForgeList?, kind: ForgeKind, repo: String) -> ForgeList {
        var list = list ?? ForgeList(kind: kind, repo: repo, sections: [])
        list.sections.removeAll { $0.id == section.id }
        list.sections.append(section)
        let order = ForgeSectionID.all(for: kind)
        list.sections.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        return list
    }

    /// The search field's Return: a pasted link opens its item; anything else searches the
    /// repository's pull requests or issues.
    func submitSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = ForgeItemRef(link: text) {
            query = ""
            await open(ref)
            return
        }
        guard !text.isEmpty, let repo else { return }
        searching = true
        rebuild()
        let result = await transport(.search(kind: kind, repo: repo, query: text))
        searching = false
        guard query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { rebuild(); return }
        switch result {
        case .success(.list(let list)): results = list
        case .failure(let failure): actionError = failure
        default: break
        }
        rebuild()
    }

    /// Paste a link (PRReviewEmpty): opens the GitHub link on the clipboard.
    func pasteLink() async {
        guard let text = NSPasteboard.general.string(forType: .string), let ref = ForgeItemRef(link: text) else {
            actionError = ForgeError(.invalid, "Copy a link to a GitHub pull request or issue, then choose Paste a link.")
            return
        }
        await open(ref)
    }

    // MARK: The page

    /// Shows an item: a row, a pin or a pasted link. Its repository's lists follow when this host
    /// knows it.
    func open(_ ref: ForgeItemRef) async {
        let shown = selection == ref && (pullRequest != nil || issue != nil || detailLoading)
        // Picked first, so switching the kind or the repository doesn't open their first row.
        selection = ref
        if ref.kind != kind { kind = ref.kind }
        if ref.repo != repo, repos.contains(where: { $0.nameWithOwner == ref.repo }) { await selectRepo(ref.repo) }
        guard !shown else { rebuild(); return }
        tab = .summary
        pullRequest = nil
        issue = nil
        bodyBlocks = []
        files = nil
        filesError = nil
        logs = [:]
        mergeOptions = MergeOptions()
        rebuild()
        await loadDetail()
    }

    private func clearSelection() {
        selection = nil
        pullRequest = nil
        issue = nil
        bodyBlocks = []
        files = nil
        detailError = nil
    }

    func loadDetail() async {
        guard let ref = selection else { return }
        detailLoading = true
        detailError = nil
        let result = await transport(ref.kind == .pullRequest ? .pullRequest(ref: ref) : .issue(ref: ref))
        guard selection == ref else { return }
        detailLoading = false
        switch result {
        case .success(.pullRequest(let detail)):
            if detail.body != pullRequest?.body { bodyBlocks = nativeMarkdownBlocks(detail.body) }
            if pullRequest?.ref != detail.ref {
                mergeOptions = MergeOptions(method: detail.defaultMergeMethod ?? detail.mergeMethods.first ?? .squash,
                                            whenReady: !detail.blockers.isEmpty, deleteBranch: !detail.deletesBranchOnMerge,
                                            removeWorktree: detail.summary.thread?.worktreePath != nil)
            }
            pullRequest = detail
        case .success(.issue(let detail)):
            if detail.body != issue?.body { bodyBlocks = nativeMarkdownBlocks(detail.body) }
            issue = detail
        case .failure(let failure): detailError = failure
        default: break
        }
        if tab == .changes { loadFiles() }
    }

    func loadFiles() {
        guard let ref = selection, ref.kind == .pullRequest, !filesLoading else { return }
        filesLoading = true
        filesError = nil
        Task {
            let result = await transport(.pullRequestFiles(ref: ref))
            filesLoading = false
            guard selection == ref else { return }
            switch result {
            case .success(.files(let loaded)): files = loaded
            case .failure(let failure): filesError = failure
            default: break
            }
        }
    }

    /// A failing job's last lines (the Checks tab).
    func loadLog(_ check: ForgeCheck) async -> String? {
        guard let jobID = check.jobID, let ref = selection else { return nil }
        if let log = logs[jobID] { return log }
        guard !loadingLogs.contains(jobID) else { return nil }
        loadingLogs.insert(jobID)
        defer { loadingLogs.remove(jobID) }
        guard case .success(.checkLog(let log)) = await transport(.checkLog(repo: ref.repo, jobID: jobID)) else { return nil }
        logs[jobID] = log
        return log
    }

    // MARK: Changes

    /// Sends a change to GitHub, then reads the page and its list again. False when GitHub
    /// refused it (`actionError` says why).
    @discardableResult
    func perform(_ request: RemoteForgeRequest) async -> Bool {
        working = true
        actionError = nil
        let result = await transport(request)
        working = false
        switch result {
        case .success(.sidebar(let next)):
            sidebar = ForgeSidebar(pins: next.pins, needsYou: sidebar?.needsYou ?? next.needsYou)
            return true
        case .success:
            await loadDetail()
            await loadList(kind)
            return true
        case .failure(let failure):
            actionError = failure
            return false
        }
    }

    func togglePin() async {
        guard let ref = selection else { return }
        let title = pullRequest?.summary.title ?? issue?.summary.title ?? ""
        await perform(.setPinned(ref: ref, title: title, pinned: !isPinned(ref)))
    }

    /// Pins and the Needs you count, for the main sidebar.
    func loadSidebar() async {
        if case .success(.sidebar(let next)) = await transport(.sidebar) { sidebar = next }
    }

    // MARK: Deriving

    private func kindChanged() {
        results = nil
        query = ""
        rebuild()
        // The other kind's page shows its first row, unless something picked one meanwhile.
        guard selection?.kind != kind else { return }
        let before = selection, kind = kind
        Task {
            guard selection == before, self.kind == kind else { return }
            if let first = firstRow { await open(first) } else { clearSelection(); rebuild() }
        }
    }

    private var firstRow: ForgeItemRef? {
        items.lazy.compactMap { item -> ForgeItemRef? in
            if case .row(let row) = item { return row.ref }
            return nil
        }.first
    }

    private func rebuild() {
        let now = now()
        let next = Self.items(list: lists[kind], kind: kind, open: openSections[kind] ?? [], loading: loadingSections[kind] ?? [],
                              results: results, query: query, selection: selection, repoName: repoName, now: now)
        if next != items { items = next }
        var nextCounts: [ForgeKind: Int] = [:]
        for (kind, list) in lists { nextCounts[kind] = Self.count(list) }
        if nextCounts != counts { counts = nextCounts }
    }

    /// The items a list's default sections hold, each once (the switch's count).
    static func count(_ list: ForgeList) -> Int {
        let defaults = Set(ForgeSectionID.defaults(for: list.kind))
        return Set(list.sections.filter { defaults.contains($0.id) }.flatMap { $0.pullRequests.map(\.ref) + $0.issues.map(\.ref) }).count
    }

    /// The sidebar list (PRReview, PRReviewTeam, PRReviewEmpty, IssueReview): each section's header
    /// and rows in `ForgeSectionID.all(for:)` order, an item only in the first section holding it;
    /// a section that loads on demand is one "Needs my team's review ›" row until opened; an empty
    /// list says so above them. A search shows its results instead.
    static func items(list: ForgeList?, kind: ForgeKind, open: Set<ForgeSectionID>, loading: Set<ForgeSectionID>, results: ForgeList?,
                      query: String, selection: ForgeItemRef?, repoName: String, now: Date) -> [ForgeListItem] {
        var seen = Set<ForgeItemRef>()
        func rows(_ section: ForgeSection) -> [ForgeListItem] {
            let rows = section.pullRequests.map { ForgeRow($0, viewer: list?.viewer, now: now) }
                + section.issues.map { ForgeRow($0, viewer: list?.viewer, now: now) }
            return rows.filter { seen.insert($0.ref).inserted }.map { row in
                var row = row
                row.selected = row.ref == selection
                return .row(row)
            }
        }
        if let results {
            let section = results.section(.results) ?? ForgeSection(id: .results)
            let found = rows(section)
            if found.isEmpty { return [.message("No matches for “\(query)”")] }
            return [.header(id: "results", title: ForgePresentation.title(.results, kind: kind), count: found.count)] + found
        }
        guard let list else { return [] }
        var items: [ForgeListItem] = []
        var anyDefault = false
        var emptyAt: Int?
        for id in ForgeSectionID.all(for: kind) {
            if id.loadsOnDemand, !open.contains(id) {
                if emptyAt == nil { emptyAt = items.count }
                items.append(.more(id, title: ForgePresentation.title(id, kind: kind), loading: loading.contains(id)))
                continue
            }
            guard let section = list.section(id) else {
                if loading.contains(id) { items.append(.more(id, title: ForgePresentation.title(id, kind: kind), loading: true)) }
                continue
            }
            let sectionRows = rows(section)
            if !id.loadsOnDemand, !sectionRows.isEmpty { anyDefault = true }
            guard !sectionRows.isEmpty || id.loadsOnDemand else { continue }
            if id.loadsOnDemand, emptyAt == nil { emptyAt = items.count }
            items.append(.header(id: id.rawValue, title: ForgePresentation.title(section, kind: kind), count: sectionRows.count,
                                 section: id.loadsOnDemand ? id : nil))
            items += sectionRows
        }
        if !anyDefault {
            items.insert(.empty(title: ForgePresentation.emptyTitle(kind), detail: ForgePresentation.emptyDetail(kind, repoName: repoName)),
                         at: emptyAt ?? items.count)
        }
        return items
    }
}

/// The banner after an agent action: what happened, and the thread it went to.
struct ForgeNotice: Equatable {
    let text: String
    let agentID: AgentID?
}

/// One element of the destination's sidebar list.
enum ForgeListItem: Identifiable, Equatable {
    /// A section's caption and count; `section` is set for one that loads on demand (it folds).
    case header(id: String, title: String, count: Int, section: ForgeSectionID? = nil)
    case row(ForgeRow)
    /// A section that loads on demand, folded: "Needs my team's review ›".
    case more(ForgeSectionID, title: String, loading: Bool)
    /// Nothing waiting, and why.
    case empty(title: String, detail: String)
    case message(String)

    var id: String {
        switch self {
        case .header(let id, _, _, _): "header.\(id)"
        case .row(let row): row.ref.id
        case .more(let id, _, _): "more.\(id.rawValue)"
        case .empty: "empty"
        case .message: "message"
        }
    }
}

/// A pull request's or issue's row: its title, the author's initial and "baily · 2h", and its dot.
struct ForgeRow: Equatable, Identifiable {
    let ref: ForgeItemRef
    let title: String
    let author: String
    let byline: String
    let tone: ForgeTone
    /// The dot's word, for VoiceOver ("Failing", "In PR").
    let word: String
    /// The author is the signed-in gh user (the avatar is lantern).
    let viewerIsAuthor: Bool
    var selected = false

    var id: String { ref.id }

    init(_ pull: PullRequestSummary, viewer: String?, now: Date) {
        let state = PullRequestRowState(pull)
        ref = pull.ref
        title = pull.title
        author = pull.author
        byline = ForgePresentation.byline(author: pull.author, updatedAt: pull.updatedAt, now: now)
        tone = state.tone
        word = state.label
        viewerIsAuthor = viewer.map { $0.caseInsensitiveCompare(pull.author) == .orderedSame } ?? false
    }

    init(_ issue: IssueSummary, viewer: String?, now: Date) {
        ref = issue.ref
        title = issue.title
        author = issue.author
        byline = ForgePresentation.byline(author: issue.author, updatedAt: issue.updatedAt, automation: issue.automationName, now: now)
        tone = ForgePresentation.tone(issue.progress)
        word = ForgePresentation.label(issue.progress)
        viewerIsAuthor = viewer.map { $0.caseInsensitiveCompare(issue.author) == .orderedSame } ?? false
    }
}
