import SwiftUI
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// One row search draws, on the phone's cards and in the iPad palette: a thread to open, or an
/// action. Plain values, derived by `MobileSearchStore` once per change.
struct SearchEntry: Identifiable, Equatable {
    enum Action: Equatable {
        case open(AgentRef)
        case rename(AgentRef)
        case move(AgentRef, AgentReorder.Direction)
        case delete(AgentRef)
        case newThread
        case settings
    }

    let id: String
    let action: Action
    let leading: NWSearchResultRow.Leading
    let title: [NWHighlightRun]
    let detail: [NWHighlightRun]
    let host: String?
    let dimmed: Bool
    /// What VoiceOver reads.
    let spoken: String
    /// The thread it concerns, for the palette's preview.
    let thread: AgentRef?
    /// A conversation's snippet, shown under the palette's preview.
    let snippet: String?
}

struct SearchEntrySection: Identifiable, Equatable {
    enum Kind: Hashable { case threads, conversations, actions }

    let kind: Kind
    let title: String
    let entries: [SearchEntry]

    var id: Kind { kind }
}

/// Where the conversation search stands, for the line under the results.
struct SearchStatusLine: Equatable {
    var searching: String?
    var notices: [String]
}

/// Search across every agent on every host (MobileSearch, iPadPalette boards). Titles match at
/// once from the hosts' pushed state; after a short pause the conversations of every agent on
/// a connected host are searched, a few requests per host at a time, and results stream in.
/// A new query cancels what is in flight. It follows the hosts itself (Observation), so a
/// state push, a new connection or a forgotten host re-derives the rows without the view.
@MainActor
@Observable
final class MobileSearchStore {
    /// The typed query. Setting it re-derives the title matches now and restarts the
    /// conversation search after `pause`.
    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }

    private(set) var sections: [SearchEntrySection] = []
    private(set) var status = SearchStatusLine(searching: nil, notices: [])
    /// Every entry in order, for the palette's keyboard selection.
    private(set) var entries: [SearchEntry] = []
    /// The palette's selection: it stays on its entry while results stream in, and falls to
    /// the first entry when that one goes away.
    private(set) var selectionID: String?
    private(set) var selected: SearchEntry?
    /// The query is empty: the screen says what search does instead of listing results.
    var isIdle: Bool { CrossHostSearch.normalized(query).isEmpty }

    /// The palette lists actions (for `thread`, the one on screen, and the app's own); the
    /// phone's search lists threads only.
    @ObservationIgnored let includesActions: Bool
    @ObservationIgnored private(set) var thread: AgentRef?
    @ObservationIgnored private weak var hosts: MobileHosts?
    @ObservationIgnored private var inputs = Inputs()
    @ObservationIgnored private var outcomes: [SearchTarget.ID: SearchOutcome] = [:]
    @ObservationIgnored private var asked: Set<SearchTarget.ID> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var tracking = UUID()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private let pause: Duration

    init(includesActions: Bool = false, pause: Duration = .milliseconds(250)) {
        self.includesActions = includesActions
        self.pause = pause
    }

    /// What search reads from the hosts: every agent as a target, each host's reach, the
    /// connection each is on, and what the palette's actions need to know about `thread`.
    struct Inputs: Equatable {
        var targets: [SearchTarget] = []
        var hosts: [SearchHost] = []
        var sessions: [UUID: UUID] = [:]
        var actions: ThreadActions?
    }

    /// Starts following `hosts`; `thread` is the thread on screen, for the palette's actions.
    func attach(_ hosts: MobileHosts, thread: AgentRef? = nil) {
        self.hosts = hosts
        self.thread = thread
        tracking = UUID()
        observe()
    }

    /// Stops following the hosts and cancels every request.
    func detach() {
        tracking = UUID()
        cancelSearch()
        hosts = nil
    }

    private func observe() {
        guard let hosts else { return }
        let token = tracking
        let thread = thread
        let includesActions = includesActions
        let next = withObservationTracking {
            Self.inputs(hosts, thread: includesActions ? thread : nil)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.tracking == token else { return }
                self.observe()
            }
        }
        adopt(next)
    }

    private func adopt(_ next: Inputs) {
        guard next != inputs else { return }
        // A host that reconnected (or dropped) answers again from scratch.
        for (host, session) in inputs.sessions where next.sessions[host] != session {
            forgetOutcomes(host: host)
        }
        for host in next.sessions.keys where inputs.sessions[host] == nil {
            forgetOutcomes(host: host)
        }
        inputs = next
        derive()
        if pauseTask == nil { searchConversations() }
    }

    private func forgetOutcomes(host: UUID) {
        outcomes = outcomes.filter { $0.key.host != host }
        asked = asked.filter { $0.host != host }
    }

    private func queryChanged() {
        cancelSearch()
        derive()
        guard CrossHostSearch.searchesConversations(query) else { return }
        let pause = pause
        pauseTask = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled, let self else { return }
            self.pauseTask = nil
            self.searchConversations()
        }
    }

    private func cancelSearch() {
        generation = UUID()
        pauseTask?.cancel()
        pauseTask = nil
        for task in tasks { task.cancel() }
        tasks = []
        outcomes = [:]
        asked = []
    }

    /// Asks every agent not yet asked for the current query, a few at a time per host.
    private func searchConversations() {
        let pending = CrossHostSearch.contentTargets(query, in: inputs.targets).filter { !asked.contains($0.id) }
        guard !pending.isEmpty, let hosts else { return }
        asked.formUnion(pending.map(\.id))
        var clients: [UUID: RemoteHostClient] = [:]
        for host in Set(pending.map(\.host)) {
            clients[host] = hosts.host(host)?.connectedClient
        }
        let query = CrossHostSearch.normalized(query)
        let generation = generation
        let task = Task { [weak self, clients] in
            await CrossHostSearch.fanOut(pending, search: { target in
                guard let client = clients[target.host] else { throw SearchFailure("the host disconnected") }
                return try await Self.search(client, agent: target.agent, query: query)
            }, deliver: { [weak self] id, outcome in
                guard let self, self.generation == generation else { return }
                self.outcomes[id] = outcome
                self.derive()
            })
        }
        tasks.append(task)
        derive()
    }

    /// One agent's answer. An agent the host no longer has, or any refusal about that agent
    /// alone, is simply no match; an old host, a dropped connection or a timeout fails the host.
    nonisolated private static func search(_ client: RemoteHostClient, agent: AgentID, query: String) async throws -> String? {
        do {
            guard case .search(let snippet) = try await client.agentQuery(agentID: agent, query: .search(query: query)) else { return nil }
            return snippet
        } catch RemoteHostClientError.rejected(let code, let message) {
            if code == "update_required" { throw SearchFailure(message) }
            return nil
        } catch let error as RemoteHostClientError {
            throw SearchFailure(error.description)
        }
    }

    // MARK: Deriving

    private func derive() {
        let results = CrossHostSearch.results(query, targets: inputs.targets, hosts: inputs.hosts, outcomes: outcomes)
        var next: [SearchEntrySection] = results.sections.map { section in
            SearchEntrySection(kind: section.kind == .threads ? .threads : .conversations, title: section.title,
                               entries: section.rows.map(Self.entry))
        }
        if includesActions {
            let actions = Self.actions(inputs.actions, query: query)
            if !actions.isEmpty { next.append(SearchEntrySection(kind: .actions, title: "Actions", entries: actions)) }
        }
        let searching: String? = results.progress.isSearching || pauseTask != nil && results.searchesConversations
            ? "Searching conversations" + (results.progress.total > 0 ? " · \(results.progress.searched) of \(results.progress.total)" : "…")
            : nil
        let line = SearchStatusLine(searching: searching, notices: results.notices)
        if next != sections {
            sections = next
            entries = next.flatMap(\.entries)
            reconcileSelection()
        }
        if line != status { status = line }
    }

    // MARK: Selection

    func select(_ id: String) {
        guard id != selectionID, entries.contains(where: { $0.id == id }) else { return }
        selectionID = id
        reconcileSelection()
    }

    /// Up or down a row, stopping at either end (arrow keys).
    func moveSelection(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == selectionID } ?? 0
        let next = min(max(index + delta, 0), entries.count - 1)
        select(entries[next].id)
    }

    private func reconcileSelection() {
        let entry = entries.first { $0.id == selectionID } ?? entries.first
        if selectionID != entry?.id { selectionID = entry?.id }
        if selected != entry { selected = entry }
    }

    private static func entry(_ row: SearchResultRow) -> SearchEntry {
        let ref = AgentRef(host: row.target.host, agent: row.target.agent)
        let snippet = row.kind == .conversation ? row.detail.map(\.text).joined() : nil
        return SearchEntry(id: row.id, action: .open(ref),
                           leading: row.kind == .thread ? .status(AgentState(row.status)) : .symbol("text.bubble"),
                           title: row.title.map(Self.run), detail: row.detail.map(Self.run), host: row.hostName,
                           dimmed: !row.online, spoken: row.spokenText, thread: ref, snippet: snippet)
    }

    private static func run(_ segment: SearchSegment) -> NWHighlightRun {
        NWHighlightRun(segment.text, highlighted: segment.highlighted)
    }

    // MARK: Hosts

    private static func inputs(_ hosts: MobileHosts, thread: AgentRef?) -> Inputs {
        var inputs = Inputs()
        for host in hosts.hosts {
            let online = host.phase.isConnected
            let searchable = online && host.supports(RemoteProtocol.agentInspectionCapability)
            let spaces = Dictionary(host.state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            for agent in host.state.agents {
                inputs.targets.append(SearchTarget(host: host.id, hostName: host.name, agent: agent.id, title: agent.name,
                                                   status: agent.status, space: spaces[agent.spaceID], online: online,
                                                   searchable: searchable))
            }
            inputs.hosts.append(SearchHost(id: host.id, name: host.name, online: online, searchable: searchable,
                                           agentCount: host.state.agents.count))
            if let session = host.session { inputs.sessions[host.id] = session }
        }
        if let thread, let host = hosts.host(thread.host), let agent = host.agent(thread.agent) {
            inputs.actions = ThreadActions(ref: thread, agent: agent, host: host)
        }
        return inputs
    }
}

/// What can be done to the thread on screen, as its host allows it.
struct ThreadActions: Equatable {
    var ref: AgentRef
    var name: String
    var hostName: String
    var canRename: Bool
    var canDelete: Bool
    var worktree: Bool
    var canMoveUp: Bool
    var canMoveDown: Bool

    @MainActor init(ref: AgentRef, agent: Agent, host: MobileHost) {
        self.ref = ref
        name = agent.name
        hostName = host.name
        let live = host.phase.isConnected
        let actions = live && host.supports(RemoteProtocol.agentActionsCapability)
        worktree = agent.worktreeBranch != nil
        canRename = actions
        canDelete = worktree ? live && host.supports(RemoteProtocol.worktreeActionsCapability) : actions
        canMoveUp = actions && !AgentReorder.moves(host.state.agents, moving: agent.id, .up).isEmpty
        canMoveDown = actions && !AgentReorder.moves(host.state.agents, moving: agent.id, .down).isEmpty
    }
}

extension MobileSearchStore {
    /// The palette's actions, filtered and ranked by `query` (all of them while it is empty).
    static func actions(_ thread: ThreadActions?, query: String) -> [SearchEntry] {
        var all: [(title: String, detail: String?, symbol: String, action: SearchEntry.Action)] = []
        if let thread {
            if thread.canRename { all.append(("Rename…", thread.name, "pencil", .rename(thread.ref))) }
            if thread.canMoveUp { all.append(("Move up", thread.name, "arrow.up", .move(thread.ref, .up))) }
            if thread.canMoveDown { all.append(("Move down", thread.name, "arrow.down", .move(thread.ref, .down))) }
            if thread.canDelete {
                all.append((thread.worktree ? "Delete worktree agent…" : "Delete agent…", thread.name, "trash", .delete(thread.ref)))
            }
        }
        all.append(("New thread", nil, "square.and.pencil", .newThread))
        all.append(("Settings", nil, "gearshape", .settings))
        let needle = CrossHostSearch.normalized(query)
        var ranked: [(entry: SearchEntry, rank: Int, index: Int)] = []
        for (index, item) in all.enumerated() {
            guard let rank = CrossHostSearch.rank(query: needle, in: item.title)
                ?? item.detail.flatMap({ CrossHostSearch.rank(query: needle, in: $0) }).map({ $0 + 4 }) else { continue }
            let title = CrossHostSearch.segments(item.title, highlighting: needle).map(run)
            let detail = item.detail.map { CrossHostSearch.segments($0, highlighting: needle).map(run) } ?? []
            let entry = SearchEntry(id: "action:" + item.title, action: item.action, leading: .symbol(item.symbol), title: title,
                                    detail: detail, host: nil, dimmed: false,
                                    spoken: [item.title, item.detail].compactMap { $0 }.joined(separator: ", "),
                                    thread: thread.flatMap { item.detail == nil ? nil : $0.ref }, snippet: nil)
            ranked.append((entry, rank, index))
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
        return ranked.map(\.entry)
    }
}

/// Why a host could not search, as the notice says it.
struct SearchFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
