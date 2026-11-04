import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A forge read: what it last brought, whether one is under way, and why the last one failed.
struct ForgeLoad<Value: Equatable>: Equatable {
    var value: Value?
    var loading = false
    var error: ForgeError?
}

/// A repository on one host: the picker's row.
struct ForgeRepoChoice: Hashable, Identifiable {
    let host: UUID
    let hostName: String
    let repo: ForgeRepo

    var id: String { "\(host.uuidString)|\(repo.nameWithOwner)" }
}

/// A pull request page's tab.
enum ForgeTab: Hashable { case summary, changes, checks }

/// A sheet over an item: Review, Merge, Comment.
struct ForgeSheet: Identifiable, Equatable {
    enum Kind: Equatable { case review, merge, comment }
    let key: ForgeItemKey
    let kind: Kind
    var id: String { "\(key.ref.id)|\(kind)" }
}

/// Every host's Issues & PRs (`issuesAndPRs.v1`): the repositories, each list, each item's page,
/// and the changes sent from here. Rows and pages are derived once per read (`ForgeRows`), never
/// in a view's body. Nothing polls: a screen reads when it appears and after a change.
@MainActor
@Observable
final class ForgeStore {
    struct ListKey: Hashable {
        var host: UUID
        var repo: String
        var kind: ForgeKind
    }

    /// Issues or Pull requests.
    var kind: ForgeKind = .pullRequest
    private(set) var repos: [ForgeRepoChoice] = []
    private(set) var reposLoading = false
    /// The repository the list shows; the first one when nil or gone.
    var repoID: String?
    /// Connected hosts that don't serve Issues & PRs (an older Shepherd): the "update the Mac" state.
    private(set) var olderHosts: [String] = []
    /// Why reading the repositories failed on every host that serves them (gh missing, signed out).
    private(set) var reposError: ForgeError?
    private(set) var lists: [ListKey: ForgeLoad<ForgeListModel>] = [:]
    /// On-demand sections opened (Needs my team's review, Closed).
    var expanded: Set<ForgeSectionID> = []
    /// A search's matches, while the field holds the query it ran.
    private(set) var results: ForgeLoad<ForgeListModel>?
    private(set) var resultsQuery = ""
    private(set) var pullRequests: [ForgeItemKey: ForgeLoad<ForgePullRequestModel>] = [:]
    private(set) var issues: [ForgeItemKey: ForgeLoad<ForgeIssueModel>] = [:]
    private(set) var files: [ForgeItemKey: ForgeLoad<ForgeFilesModel>] = [:]
    /// A failing job's log tail, by host, repository and job.
    private(set) var logs: [String: ForgeLoad<String>] = [:]
    private(set) var sidebars: [UUID: ForgeSidebar] = [:]
    /// Each host's signed-in gh user, as its last list or page said (a pin's "review").
    private(set) var viewers: [UUID: String] = [:]
    /// The item the iPad shows beside the list.
    private(set) var chosen: ForgeItemKey?
    /// Items with a change on its way: their actions wait.
    private(set) var busy: Set<ForgeItemKey> = []
    /// The last change a host refused, in its words.
    var failure: String?
    /// Each pull request page's tab, the sheet over an item, and the file the iPad shows beside a
    /// pull request (iPadPRChanges): kept here so every way in (a pin, a link, a fixture) lands on
    /// the same place.
    var tabs: [ForgeItemKey: ForgeTab] = [:]
    var sheet: ForgeSheet?
    var padFile: String?
    /// An item opened from elsewhere (a pin, a link) on iPad: a list too narrow for its detail
    /// pushes it (`ForgeSplit`), a wide one shows it beside the list.
    var reveal: ForgeItemKey?
    /// Files marked viewed in a pull request's Changes, on this device.
    private(set) var viewed: [ForgeItemKey: Set<String>] = [:]

    @ObservationIgnored private let hosts: MobileHosts
    private static var stores: [ObjectIdentifier: ForgeStore] = [:]

    static func of(_ hosts: MobileHosts) -> ForgeStore {
        if let store = stores[ObjectIdentifier(hosts)] { return store }
        let store = ForgeStore(hosts: hosts)
        stores[ObjectIdentifier(hosts)] = store
        return store
    }

    init(hosts: MobileHosts) {
        self.hosts = hosts
    }

    // MARK: Derived

    var repo: ForgeRepoChoice? { repos.first { $0.id == repoID } ?? repos.first }
    func listKey(_ kind: ForgeKind) -> ListKey? { repo.map { ListKey(host: $0.host, repo: $0.repo.nameWithOwner, kind: kind) } }
    func list(_ kind: ForgeKind) -> ForgeLoad<ForgeListModel>? { listKey(kind).flatMap { lists[$0] } }

    /// Connected hosts that serve Issues & PRs.
    var servingHosts: [MobileHost] {
        hosts.hosts.filter { $0.connectedClient != nil && $0.supports(RemoteProtocol.forgeCapability) }
    }

    /// Changes whenever a host connects, drops or reconnects: what re-reads the repositories.
    var sessionsKey: String { hosts.hosts.map { $0.session?.uuidString ?? "-" }.joined(separator: ",") }

    /// Pull requests and issues that need you, across hosts (the sidebar's count).
    var needsYou: Int { sidebars.values.reduce(0) { $0 + $1.needsYou } }

    /// Pins across hosts, newest first.
    var pins: [ForgePinRow] {
        sidebars.flatMap { host, sidebar in
            sidebar.pins.map { ForgePinRow(host: host, item: $0, viewer: viewers[host]) }
        }
        .sorted { $0.pinnedAt > $1.pinnedAt }
    }

    func isPinned(_ key: ForgeItemKey) -> Bool { sidebars[key.host]?.pins.contains { $0.pin.ref == key.ref } == true }

    func hostName(_ id: UUID) -> String { hosts.host(id)?.name ?? "the host" }

    /// The checkout this host keeps for a repository, for a new thread's folder.
    func repoPath(_ key: ForgeItemKey) -> String? {
        repos.first { $0.host == key.host && $0.repo.nameWithOwner == key.ref.repo }?.repo.path
    }

    // MARK: Reading

    /// The repositories of every connected host that serves Issues & PRs, and the sidebar's pins
    /// and count.
    func loadRepos() async {
        let serving = servingHosts
        olderHosts = hosts.hosts.filter { $0.connectedClient != nil && !$0.supports(RemoteProtocol.forgeCapability) }.map(\.name)
        reposLoading = true
        defer { reposLoading = false }
        var choices: [ForgeRepoChoice] = []
        var lastError: ForgeError?
        for host in serving {
            switch await send(.repos, to: host.id) {
            case .success(.repos(let repos)):
                choices += repos.map { ForgeRepoChoice(host: host.id, hostName: host.name, repo: $0) }
            case .failure(let error): lastError = error
            default: break
            }
        }
        repos = choices
        reposError = choices.isEmpty ? lastError : nil
        await loadSidebars()
    }

    func loadSidebars() async {
        var next: [UUID: ForgeSidebar] = [:]
        for host in servingHosts {
            if case .success(.sidebar(let sidebar)) = await send(.sidebar, to: host.id) { next[host.id] = sidebar }
        }
        if next != sidebars { sidebars = next }
    }

    /// Both lists of the chosen repository, with whatever on-demand sections are open.
    func loadLists() async {
        async let pulls: Void = loadList(.pullRequest)
        async let issues: Void = loadList(.issue)
        _ = await (pulls, issues)
    }

    func loadList(_ kind: ForgeKind) async {
        guard let key = listKey(kind) else { return }
        let sections = ForgeSectionID.defaults(for: kind) + ForgeSectionID.all(for: kind).filter { expanded.contains($0) }
        lists[key, default: ForgeLoad()].loading = true
        let answer = await send(.list(kind: kind, repo: key.repo, sections: sections), to: key.host)
        var load = lists[key] ?? ForgeLoad()
        load.loading = false
        switch answer {
        case .success(.list(let list)):
            if let viewer = list.viewer, viewers[key.host] != viewer { viewers[key.host] = viewer }
            load.value = ForgeRows.list(list, host: key.host, hostName: hostName(key.host))
            load.error = nil
        case .failure(let error): load.error = error
        default: break
        }
        lists[key] = load
    }

    /// Opens an on-demand section (Needs my team's review, Closed) and reads it.
    func expand(_ section: ForgeSectionID) async {
        expanded.insert(section)
        await loadList(kind)
    }

    func collapse(_ section: ForgeSectionID) {
        expanded.remove(section)
        Task { await loadList(kind) }
    }

    /// What the field holds on submit: a pasted link opens its item, anything else searches.
    /// Returns the item a link named.
    func submit(_ text: String) async -> ForgeItemKey? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ref = ForgeItemRef(link: query) {
            let host = repos.first { $0.repo.nameWithOwner == ref.repo }?.host ?? repo?.host ?? servingHosts.first?.id
            return host.map { ForgeItemKey(host: $0, ref: ref) }
        }
        guard !query.isEmpty, let key = listKey(kind) else {
            clearSearch()
            return nil
        }
        resultsQuery = query
        results = ForgeLoad(value: results?.value, loading: true)
        let answer = await send(.search(kind: kind, repo: key.repo, query: query), to: key.host)
        guard resultsQuery == query else { return nil }
        switch answer {
        case .success(.list(let list)): results = ForgeLoad(value: ForgeRows.list(list, host: key.host, hostName: hostName(key.host)))
        case .failure(let error): results = ForgeLoad(error: error)
        default: results = nil
        }
        return nil
    }

    func clearSearch() {
        results = nil
        resultsQuery = ""
    }

    func choose(_ key: ForgeItemKey) {
        if chosen != key { padFile = nil }
        chosen = key
        kind = key.ref.kind
        if let repo = repos.first(where: { $0.host == key.host && $0.repo.nameWithOwner == key.ref.repo }) { repoID = repo.id }
    }

    func loadPullRequest(_ key: ForgeItemKey) async {
        pullRequests[key, default: ForgeLoad()].loading = true
        let answer = await send(.pullRequest(ref: key.ref), to: key.host)
        var load = pullRequests[key] ?? ForgeLoad()
        load.loading = false
        switch answer {
        case .success(.pullRequest(let detail)):
            let model = ForgeRows.pullRequest(detail, hostName: hostName(key.host))
            load.value = model
            load.error = nil
            if let current = files[key]?.value, current.comments != model.commentCounts {
                files[key]?.value = ForgeFilesModel(current.source, comments: model.commentCounts, viewed: viewed[key] ?? [])
            }
        case .failure(let error): load.error = error
        default: break
        }
        pullRequests[key] = load
    }

    func loadFiles(_ key: ForgeItemKey) async {
        files[key, default: ForgeLoad()].loading = true
        let answer = await send(.pullRequestFiles(ref: key.ref), to: key.host)
        var load = files[key] ?? ForgeLoad()
        load.loading = false
        switch answer {
        case .success(.files(let files)):
            load.value = ForgeFilesModel(files, comments: pullRequests[key]?.value?.commentCounts ?? [:], viewed: viewed[key] ?? [])
            load.error = nil
        case .failure(let error): load.error = error
        default: break
        }
        files[key] = load
    }

    func loadIssue(_ key: ForgeItemKey) async {
        issues[key, default: ForgeLoad()].loading = true
        let answer = await send(.issue(ref: key.ref), to: key.host)
        var load = issues[key] ?? ForgeLoad()
        load.loading = false
        switch answer {
        case .success(.issue(let detail)):
            load.value = ForgeRows.issue(detail)
            load.error = nil
        case .failure(let error): load.error = error
        default: break
        }
        issues[key] = load
    }

    static func logKey(host: UUID, repo: String, jobID: Int) -> String { "\(host.uuidString)|\(repo)|\(jobID)" }

    func loadLog(host: UUID, repo: String, jobID: Int) async {
        let key = Self.logKey(host: host, repo: repo, jobID: jobID)
        guard logs[key]?.value == nil, logs[key]?.loading != true else { return }
        logs[key] = ForgeLoad(loading: true)
        switch await send(.checkLog(repo: repo, jobID: jobID), to: host) {
        case .success(.checkLog(let text)): logs[key] = ForgeLoad(value: text)
        case .failure(let error): logs[key] = ForgeLoad(error: error)
        default: logs[key] = ForgeLoad()
        }
    }

    // MARK: Changing

    /// Sends a change for `key` and reads the item again; false (with `failure` set) when the host
    /// refused it.
    @discardableResult
    func change(_ request: RemoteForgeRequest, for key: ForgeItemKey) async -> Bool {
        guard !busy.contains(key) else { return false }
        busy.insert(key)
        defer { busy.remove(key) }
        switch await send(request, to: key.host) {
        case .failure(let error):
            failure = error.message
            return false
        case .success(.sidebar(let sidebar)):
            sidebars[key.host] = sidebar
            return true
        case .success:
            failure = nil
            if key.ref.kind == .pullRequest { await loadPullRequest(key) } else { await loadIssue(key) }
            await loadList(key.ref.kind)
            return true
        }
    }

    func setPinned(_ key: ForgeItemKey, title: String, pinned: Bool) async {
        await change(.setPinned(ref: key.ref, title: title, pinned: pinned), for: key)
    }

    func toggleViewed(_ key: ForgeItemKey, path: String) {
        if viewed[key, default: []].contains(path) { viewed[key]?.remove(path) } else { viewed[key, default: []].insert(path) }
        if let current = files[key]?.value {
            files[key]?.value = ForgeFilesModel(current.source, comments: current.comments, viewed: viewed[key] ?? [])
        }
    }

    private func send(_ request: RemoteForgeRequest, to host: UUID) async -> Result<RemoteForgeResult, ForgeError> {
        guard let client = hosts.host(host)?.connectedClient else {
            return .failure(ForgeError(.unreachable, "\(hostName(host)) isn't connected."))
        }
        return await client.forge(request)
    }
}
