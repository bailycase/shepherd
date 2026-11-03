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
        /// A host's design (designs track).
        case openDesign(HostDesignRef)
        /// New design with the query as its brief (iPhone; MobileSearch).
        case newDesign(brief: String)
    }

    let id: String
    let action: Action
    let leading: SHSearchResultRow.Leading
    let title: [SHHighlightRun]
    let detail: [SHHighlightRun]
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
    enum Kind: Hashable { case threads, designs, conversations, actions }

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
    @ObservationIgnored private var tasks: [UUID: (host: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private let pause: Duration
    @ObservationIgnored private var prepared = CrossHostSearch.Prepared("", targets: [], hosts: [])
    @ObservationIgnored private var results = SearchResults.empty

    #if DEBUG
    @ObservationIgnored private(set) var preparationCount = 0
    @ObservationIgnored private(set) var sectionDerivationCount = 0
    @ObservationIgnored var searchForTesting: (@Sendable (RemoteHostClient, AgentID, String) async throws -> String?)?
    var progressForTesting: SearchProgress { results.progress }
    var activeSearchesForTesting: Int { tasks.count }

    /// Captures the same fences as an in-flight delivery, including deliberately late/duplicate replies.
    func replyForTesting(to id: SearchTarget.ID) -> @MainActor @Sendable (SearchOutcome) -> Void {
        let generation = generation
        let session = inputs.sessions[id.host]
        let client = hosts?.host(id.host)?.connectedClient
        return { [weak self] outcome in
            guard let session, let client else { return }
            self?.receive(id, outcome: outcome, generation: generation, session: session, client: client)
        }
    }
    #endif

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
        /// The designs of hosts that serve them (MobileSearch's Designs section).
        var designs: [RemoteDesignTile] = []
        var designsServed = false
    }

    /// Starts following `hosts`; `thread` is the thread on screen, for the palette's actions.
    /// Coming back to search (Back from a thread it opened) asks whatever a detach left
    /// unanswered.
    func attach(_ hosts: MobileHosts, thread: AgentRef? = nil) {
        self.hosts = hosts
        self.thread = thread
        tracking = UUID()
        observe()
        derive()
        if pauseTask == nil { searchConversations() }
    }

    /// Stops following the hosts and cancels every request in flight. Answers already in are
    /// kept, so the results survive a thread pushed over search.
    func detach() {
        tracking = UUID()
        generation = UUID()
        pauseTask?.cancel()
        pauseTask = nil
        for job in tasks.values { job.task.cancel() }
        tasks = [:]
        asked = Set(outcomes.keys)
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
        let needsPreparation = next.targets != inputs.targets || next.hosts != inputs.hosts
        inputs = next
        if needsPreparation { prepare() }
        derive()
        if pauseTask == nil { searchConversations() }
    }

    private func forgetOutcomes(host: UUID) {
        for (id, job) in tasks where job.host == host {
            job.task.cancel()
            tasks.removeValue(forKey: id)
        }
        outcomes = outcomes.filter { $0.key.host != host }
        asked = asked.filter { $0.host != host }
    }

    private func queryChanged() {
        cancelSearch()
        prepare()
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
        for job in tasks.values { job.task.cancel() }
        tasks = [:]
        outcomes = [:]
        asked = []
    }

    /// Asks every agent not yet asked for the current query, a few at a time per host.
    private func searchConversations() {
        let pending = prepared.contentTargets.filter { !asked.contains($0.id) }
        guard !pending.isEmpty, let hosts else { return }
        let query = prepared.query
        let generation = generation
        #if DEBUG
        let search = searchForTesting ?? Self.search
        #else
        let search = Self.search
        #endif
        for (hostID, targets) in Dictionary(grouping: pending, by: \.host) {
            // Freeze the client, session, targets and query together before reserving requests.
            // Observation may not yet have adopted a reconnect; it will retry with its new inputs.
            guard let host = hosts.host(hostID), let session = inputs.sessions[hostID],
                  host.session == session, let client = host.connectedClient else { continue }
            asked.formUnion(targets.map(\.id))
            let jobID = UUID()
            let task = Task { [weak self] in
                await CrossHostSearch.fanOut(targets, search: { target in
                    try await search(client, target.agent, query)
                }, deliver: { [weak self] id, outcome in
                    self?.receive(id, outcome: outcome, generation: generation, session: session, client: client)
                })
                self?.tasks.removeValue(forKey: jobID)
            }
            tasks[jobID] = (hostID, task)
        }
        deriveStatus()
    }

    private func receive(_ id: SearchTarget.ID, outcome: SearchOutcome, generation: UUID, session: UUID,
                         client: RemoteHostClient) {
        guard self.generation == generation, inputs.sessions[id.host] == session,
              let host = hosts?.host(id.host), host.session == session, host.connectedClient === client else { return }
        let previous = outcomes[id]
        guard previous != outcome else { return }
        outcomes[id] = outcome
        if previous == nil, outcome == .none {
            guard prepared.contentIDs.contains(id) else { return }
            results.progress.searched += 1
            deriveStatus()
        } else {
            derive()
        }
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

    private func prepare() {
        prepared = CrossHostSearch.Prepared(query, targets: inputs.targets, hosts: inputs.hosts)
        #if DEBUG
        preparationCount += 1
        #endif
    }

    private func derive() {
        #if DEBUG
        sectionDerivationCount += 1
        #endif
        results = prepared.results(outcomes: outcomes)
        var next: [SearchEntrySection] = results.sections.map { section in
            SearchEntrySection(kind: section.kind == .threads ? .threads : .conversations, title: section.title,
                               entries: section.rows.map(Self.entry))
        }
        let designs = Self.designEntries(inputs.designs, query: query)
        if !designs.isEmpty {
            // After the threads whose titles match, before the conversations (MobileSearch).
            let at = next.firstIndex { $0.kind != .threads } ?? next.count
            next.insert(SearchEntrySection(kind: .designs, title: "Designs", entries: designs), at: at)
        }
        if includesActions {
            let actions = Self.actions(inputs.actions, query: query)
            if !actions.isEmpty { next.append(SearchEntrySection(kind: .actions, title: "Actions", entries: actions)) }
        } else if inputs.designsServed, !isIdle {
            // The phone's results end in New design with the query as its brief; the iPad palette draws none.
            next.append(SearchEntrySection(kind: .actions, title: "Actions", entries: [Self.newDesign(query)]))
        }
        if next != sections {
            sections = next
            entries = next.flatMap(\.entries)
            reconcileSelection()
        }
        deriveStatus()
    }

    private func deriveStatus() {
        let searching: String? = results.progress.isSearching || pauseTask != nil && results.searchesConversations
            ? "Searching conversations" + (results.progress.total > 0 ? " · \(results.progress.searched) of \(results.progress.total)" : "…")
            : nil
        let line = SearchStatusLine(searching: searching, notices: results.notices)
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

    private static func run(_ segment: SearchSegment) -> SHHighlightRun {
        SHHighlightRun(segment.text, highlighted: segment.highlighted)
    }

    // MARK: Hosts

    private static func inputs(_ hosts: MobileHosts, thread: AgentRef?) -> Inputs {
        var inputs = Inputs()
        let designs = MobileDesigns.of(hosts)
        for host in hosts.hosts {
            let online = host.phase.isConnected
            let searchable = online && host.supports(RemoteProtocol.agentInspectionCapability)
            let spaces = Dictionary(host.state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            // A design's agent is no thread: its design is found under Designs. A mission's is its mission's.
            let state = host.threadState
            let threads = state.agents.filter { !state.isDesignAgent($0) }
            for agent in threads {
                inputs.targets.append(SearchTarget(host: host.id, hostName: host.name, agent: agent.id, title: agent.name,
                                                   status: agent.status, space: spaces[agent.spaceID], online: online,
                                                   searchable: searchable))
            }
            inputs.hosts.append(SearchHost(id: host.id, name: host.name, online: online, searchable: searchable,
                                           agentCount: threads.count))
            if let session = host.session { inputs.sessions[host.id] = session }
        }
        if let thread, let host = hosts.host(thread.host), let agent = host.agent(thread.agent) {
            inputs.actions = ThreadActions(ref: thread, agent: agent, host: host)
        }
        inputs.designs = designs.model.tiles
        inputs.designsServed = designs.model.available
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
    /// The designs whose names match `query`, best first: the nib, the name with the match
    /// marked, and "acme-web · 4 boards" (MobileSearch).
    static func designEntries(_ designs: [RemoteDesignTile], query: String) -> [SearchEntry] {
        let needle = CrossHostSearch.normalized(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(entry: SearchEntry, rank: Int, index: Int)] = []
        for (index, design) in designs.enumerated() {
            guard let rank = CrossHostSearch.rank(query: needle, in: design.name) else { continue }
            let detail = RemoteDesignPresentation.searchDetail(system: design.system, boards: design.boards)
            let entry = SearchEntry(id: "design:\(design.ref.host.uuidString)/\(design.ref.design.rawValue)", action: .openDesign(design.ref),
                                    leading: .symbol("pencil.tip"),
                                    title: CrossHostSearch.segments(design.name, highlighting: needle).map(run),
                                    detail: [SHHighlightRun(detail)], host: design.hostTag, dimmed: false,
                                    spoken: "\(design.name), design, \(detail)", thread: nil, snippet: nil)
            ranked.append((entry, rank, index))
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
        return ranked.map(\.entry)
    }

    /// New design, "“funnel” as the brief".
    static func newDesign(_ query: String) -> SearchEntry {
        let brief = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchEntry(id: "action:New design", action: .newDesign(brief: brief), leading: .symbol("pencil.tip"),
                           title: [SHHighlightRun("New design")],
                           detail: RemoteDesignPresentation.briefParts(brief).map { SHHighlightRun($0.text, highlighted: $0.highlighted) },
                           host: nil, dimmed: false, spoken: "New design, “\(brief)” as the brief", thread: nil, snippet: nil)
    }

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
