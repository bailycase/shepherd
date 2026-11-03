import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Search track's screens: search (iPhone), the ⌘K palette (iPad), and the agent actions' sheets.
extension FixtureCatalog {
    static var search: [FixtureScreen] {
        let preview = FixtureData.ref(FixtureData.preview)
        return [
            FixtureScreen(name: "search", hosts: SearchFixtures.hosts(), routes: [.search(.search(query: "review"))]),
            FixtureScreen(name: "search-idle", hosts: SearchFixtures.hosts(), routes: [.search(.search(query: ""))]),
            FixtureScreen(name: "search-none", hosts: SearchFixtures.hosts(), routes: [.search(.search(query: "zebra"))]),
            FixtureScreen(name: "search-progress", hosts: SearchProgressFixture.hosts(), routes: [.search(.search(query: ""))],
                          prepare: SearchProgressFixture.run),
            FixtureScreen(name: "palette", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.palette(query: "review"))),
            FixtureScreen(name: "palette-actions", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.palette(query: ""))),
            FixtureScreen(name: "rename", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.rename(preview))),
            FixtureScreen(name: "delete", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.delete(FixtureData.ref(FixtureData.extensions)))),
            FixtureScreen(name: "delete-worktree", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.delete(FixtureData.ref(SearchFixtures.worktree)))),
            FixtureScreen(name: "action-problem", hosts: SearchFixtures.hosts(), routes: [.thread(preview)],
                          presented: .search(.problem(title: "Couldn't rename the thread",
                                                      message: "Studio refused it: the agent is gone."))),
        ]
    }
}

/// The actual store, with controlled request completions and real MobileHosts reconnects.
/// The request gate deliberately ignores cancellation so stale callbacks can be tested explicitly.
@MainActor enum SearchProgressFixture {
    @MainActor final class Gate {
        struct Request {
            let id: UUID
            let client: ObjectIdentifier
            let agent: AgentID
            let query: String
        }
        var requests: [Request] = []
        var pending: [UUID: CheckedContinuation<String?, Error>] = [:]
        private var opened = false
        var waiting: [Request] { requests.filter { pending[$0.id] != nil } }

        func search(_ client: RemoteHostClient, agent: AgentID, query: String) async throws -> String? {
            let request = Request(id: UUID(), client: ObjectIdentifier(client), agent: agent, query: query)
            requests.append(request)
            if opened { return nil }
            return try await withCheckedThrowingContinuation { pending[request.id] = $0 }
        }

        func answer(_ request: Request, snippet: String? = nil) {
            pending.removeValue(forKey: request.id)?.resume(returning: snippet)
        }

        func release(where matches: (Request) -> Bool) {
            for request in waiting where matches(request) { answer(request) }
        }

        func open() {
            opened = true
            release { _ in true }
        }
    }

    static func hosts() -> [FixtureHostData] {
        let agents = [FixtureData.agent(FixtureData.preview, "Needle notes", .idle)] + (1...256).map {
            FixtureData.agent(AgentID(rawValue: "search-\($0)"), "Task \($0)", .idle)
        }
        var hosts = [FixtureHostData(id: FixtureData.studio, name: "Studio", state: ShepherdState(
            spaces: [FixtureData.shepherdSpace], agents: agents))]
        hosts.append(FixtureHostData(id: FixtureData.buildBox, name: "build-01", state: ShepherdState(
            spaces: [FixtureData.shepherdSpace], agents: [
                FixtureData.agent(FixtureData.buffer, "Other work", .idle),
                FixtureData.agent(FixtureData.nightly, "More work", .idle),
            ])))
        return hosts
    }

    static func run(_ app: MobileApp) async {
        let gate = Gate()
        let store = MobileSearchStore(includesActions: true, pause: .zero)
        store.searchForTesting = { client, agent, query in try await gate.search(client, agent: agent, query: query) }
        defer { store.detach(); gate.open() }
        func check(_ value: Bool, _ message: String) { FreshnessFixtures.check(value, message) }
        func id(_ request: Gate.Request) -> SearchTarget.ID {
            SearchTarget.ID(host: request.agent == FixtureData.buffer || request.agent == FixtureData.nightly
                            ? FixtureData.buildBox : FixtureData.studio, agent: request.agent)
        }
        func answered(_ count: Int) async {
            await FixtureCheck.wait("search progress \(count)", seconds: 5) { store.progressForTesting.searched == count }
            let total = store.progressForTesting.total
            check(store.status.searching == (count < total ? "Searching conversations · \(count) of \(total)" : nil),
                  "search publishes exact progress \(count)/\(total)")
        }

        store.query = "needle"
        store.attach(app.hosts)
        await FixtureCheck.wait("initial search requests", seconds: 5) { gate.waiting.count == 5 }
        check(store.progressForTesting == SearchProgress(searched: 0, total: 258), "title matches are excluded from progress")
        let prepared = store.preparationCount
        let initialDerivations = store.sectionDerivationCount
        let studio = gate.waiting.filter { id($0).host == FixtureData.studio }.sorted { $0.agent.rawValue < $1.agent.rawValue }
        let first = studio[0], second = studio[1]
        gate.answer(second, snippet: "needle second")
        await answered(1)
        guard let selection = store.entries.first(where: { $0.thread?.agent == second.agent }) else {
            FixtureCheck.fail("missing conversation selection")
        }
        store.select(selection.id)
        gate.answer(first, snippet: "needle first")
        await answered(2)
        check(store.sections.first(where: { $0.kind == .conversations })?.entries.compactMap { $0.thread?.agent }
              == [first.agent, second.agent], "out-of-order matches retain target order")
        check(store.selectionID == selection.id && store.selected == selection, "late matches preserve selection")
        let sections = store.sections
        let derived = store.sectionDerivationCount
        check(derived == initialDerivations + 2, "only found replies derive sections")
        store.replyForTesting(to: id(first))(.found(snippet: "needle first"))
        check(store.sectionDerivationCount == derived, "duplicate match does no work")

        for count in 3...258 {
            await FixtureCheck.wait("next held search request", seconds: 5) { !gate.waiting.isEmpty }
            let request = gate.waiting[0]
            gate.answer(request)
            await answered(count)
            store.replyForTesting(to: id(request))(.none)
            check(store.progressForTesting.searched == count && store.sections == sections
                  && store.selectionID == selection.id && store.selected == selection
                  && store.preparationCount == prepared && store.sectionDerivationCount == derived,
                  "miss \(count) and its duplicate preserve rows, selection and preparation")
        }
        await FixtureCheck.wait("completed searches released", seconds: 5) { store.activeSearchesForTesting == 0 }
        check(gate.pending.isEmpty, "all initial requests completed")
        print("FIXTURE SEARCH PROGRESS streamedMisses=256 additionalPreparations=\(store.preparationCount - prepared) additionalMissDerivations=\(store.sectionDerivationCount - derived)")
        let replace = store.replyForTesting(to: id(first))
        replace(.none)
        check(store.progressForTesting.searched == 258 && store.entries.allSatisfy { $0.thread?.agent != first.agent },
              "replacing a match removes its row without recounting progress")
        replace(.failed("fixture failure"))
        check(store.status.notices == ["Studio couldn’t search: fixture failure"], "replacement failure publishes its notice")
        replace(.none)
        check(store.status.notices.isEmpty && store.selectionID == selection.id, "replacement miss clears the failure, preserving selection")

        // A state push changes eligibility without changing query: one content match becomes a
        // title, and the former title must now be requested. Retained outcomes are recounted.
        guard let server = FixtureHost.running(FixtureData.studio), let host = app.hosts.host(FixtureData.studio) else {
            FixtureCheck.fail("missing search host")
        }
        var state = host.state
        state.agents[0].name = "Other notes"
        state.agents[state.agents.count - 1].name = "Needle promoted"
        server.push(state)
        await FixtureCheck.wait("newly eligible conversation", seconds: 5) {
            gate.waiting.contains { $0.agent == FixtureData.preview }
        }
        check(store.progressForTesting == SearchProgress(searched: 257, total: 258), "changed eligibility recounts retained answers")
        let refreshedDerivations = store.sectionDerivationCount
        gate.answer(gate.waiting.first { $0.agent == FixtureData.preview }!)
        await answered(258)
        check(store.sectionDerivationCount == refreshedDerivations, "newly eligible miss also takes the progress-only path")

        // A second query leaves requests held on both hosts. Reconnect Studio without touching
        // build-01's completed answer or its still-pending request.
        store.query = "again"
        await FixtureCheck.wait("second query requests", seconds: 5) { gate.waiting.count == 5 }
        let buildRequest = gate.waiting.first { id($0).host == FixtureData.buildBox }!
        let oldRequest = gate.waiting.first { id($0).host == FixtureData.studio }!
        gate.answer(buildRequest)
        await answered(1)
        gate.answer(oldRequest)
        await answered(2)
        await FixtureCheck.wait("replacement queued on old session", seconds: 5) { gate.waiting.count == 4 }
        let sibling = gate.waiting.first { id($0).host == FixtureData.buildBox }!
        let siblingRequests = gate.requests.filter { $0.client == sibling.client }.count
        let oldReply = store.replyForTesting(to: id(oldRequest))
        let oldSession = host.session
        let beforeReconnect = store.progressForTesting
        let beforeRows = store.sections
        app.hosts.retry(FixtureData.studio)
        // No yield: the store's Observation callback has NOT adopted the disconnect yet.
        oldReply(.found(snippet: "stale session"))
        check(store.progressForTesting == beforeReconnect && store.sections == beforeRows,
              "authoritative connection fence rejects a reply before Observation adopts reconnect")
        await FixtureCheck.wait("new session requests", seconds: 5) {
            host.session != nil && host.session != oldSession
                && gate.waiting.filter { id($0).host == FixtureData.studio && $0.client != oldRequest.client }.count == 3
        }
        check(store.progressForTesting.searched == 1 && store.status.notices.isEmpty,
              "reconnect clears only its host's outcomes and progress")
        check(gate.pending[sibling.id] != nil && gate.requests.filter { $0.client == sibling.client }.count == siblingRequests,
              "reconnect preserves the other host's pending and completed requests")
        oldReply(.found(snippet: "late stale session"))
        check(store.progressForTesting.searched == 1 && store.sections.isEmpty, "old session cannot publish after adoption either")
        gate.release { $0.client == oldRequest.client }
        let newRequest = gate.waiting.first { $0.agent == oldRequest.agent && $0.client != oldRequest.client }!
        gate.answer(newRequest)
        await answered(2)
        check(newRequest.query == "again", "re-request uses the frozen query and new connection")

        let detachedReply = store.replyForTesting(to: id(newRequest))
        store.detach()
        detachedReply(.found(snippet: "detached"))
        check(store.progressForTesting.searched == 2 && store.sections.isEmpty, "detach fences in-flight deliveries")
        gate.release { _ in true }
        store.attach(app.hosts)
        await FixtureCheck.wait("reattached unanswered requests", seconds: 5) { !gate.waiting.isEmpty }
        check(store.progressForTesting.searched == 2, "reattach retains completed outcomes")
        check(gate.waiting.allSatisfy { $0.agent != newRequest.agent && $0.agent != buildRequest.agent },
              "reattach requests only unanswered targets")

        let lateQuery = store.replyForTesting(to: id(gate.waiting[0]))
        store.query = "changed"
        lateQuery(.found(snippet: "old query"))
        check(store.progressForTesting.searched == 0 && store.sections.isEmpty, "query generation rejects old deliveries")
        gate.open()
        await FixtureCheck.wait("final query complete and jobs released", seconds: 5) {
            store.progressForTesting.searched == store.progressForTesting.total && store.activeSearchesForTesting == 0
        }
        check(store.progressForTesting.total == 259 && gate.pending.isEmpty && store.status.searching == nil,
              "every new-query answer counted, with no held requests or retained jobs")
        check(store.preparationCount > prepared, "query and target changes rebuild preparation")
    }
}

enum SearchFixtures {
    static let worktree = AgentID(rawValue: "agent-worktree")

    /// The shared hosts, with a worktree agent on Studio and every host answering conversation
    /// search (the host lowercases what it matched, as a Mac does) and the worktree's details.
    static func hosts() -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        hosts[0].state.agents.append(Agent(id: worktree, name: "Queue steering polish", spaceID: FixtureData.shepherdSpace.id,
                                           tabID: TabID(rawValue: "tab-worktree"), status: .done, nameIsFinal: true,
                                           worktreeBranch: "worktree/calm-stone-3831", worktreeBase: "origin/nightly",
                                           worktreePath: "/Users/dev/Shepherd/.worktrees/calm-stone-3831"))
        hosts[0].threads[worktree] = FixtureData.thread()
        hosts[0].reply = { request in
            answer(request, snippets: [
                FixtureData.preview: "open the review pane beside the thread once the preview settles, then",
                FixtureData.extensions: "the review extension reads the diff before it asks you",
            ])
        }
        hosts[1].reply = { request in
            answer(request, snippets: [FixtureData.buffer: "a review of the buffer flush found two copies of each"])
        }
        return hosts
    }

    private static func answer(_ request: RemoteRequest, snippets: [AgentID: String]) -> RemoteReply? {
        guard case .agentQuery(let id, let agent, let query) = request else { return nil }
        switch query {
        case .search(let text):
            let needle = text.lowercased()
            let snippet = snippets[agent].flatMap { $0.contains(needle) ? "…" + $0 + "…" : nil }
            return .agentResult(id: id, result: .search(snippet: snippet))
        case .worktreeInfo where agent == worktree:
            return .agentResult(id: id, result: .worktreeInfo(RemoteWorktreeInfo(
                path: "/Users/dev/Shepherd/.worktrees/calm-stone-3831", branch: "worktree/calm-stone-3831",
                warning: "2 uncommitted files and 1 unpushed commit",
                defaults: RemoteFinalizeOptions(base: "nightly", title: "Queue steering polish", body: "", autoCommit: true,
                                                deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash"),
                fingerprint: "fixture")))
        default:
            return nil
        }
    }
}
