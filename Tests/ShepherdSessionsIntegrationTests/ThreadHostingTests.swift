import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Threads and terminals served by `SessionServer` with no app (`serveThreads`), to the app as
/// a client over `host.sock`: a new thread, its actions, a dormant thread started by opening it,
/// and its terminals (open, start, rename, read, close).
@Suite("Threads hosted by the server", .mainActorExclusive)
@MainActor
struct ThreadHostingTests {
    private func host(threadsStartThreads: Bool = false) throws -> (ScratchServer, path: String, token: String) {
        let h = try ScratchServer.fresh()
        h.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false, threadsStartThreads: threadsStartThreads)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let path = h.dir.appendingPathComponent("h.sock").path
        let tokenURL = h.dir.appendingPathComponent("remote-token")
        try h.server.startLocalListener(path: path, tokenURL: tokenURL)
        return (h, path, try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func connect(_ path: String, _ token: String) async throws -> RemoteHostClient {
        let client = RemoteHostClient(localSocket: path)
        _ = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
        return client
    }

    @Test func theAppStartsRenamesAndDeletesAThread() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(space)
        let client = try await connect(path, token)
        defer { client.disconnect() }

        let options = try await client.creationOptions(spaceID: space.id, cwd: nil, fetchFirst: nil)
        #expect(options.model == "stub/model-a" && options.thinking == .medium)
        let id = try await client.createAgent(spaceID: space.id, cwd: nil, model: nil, thinking: nil, initialPrompt: "Check the build")
        let agent = try #require(h.server.state.agents.first { $0.id == id })
        #expect(agent.spaceID == space.id)
        try await eventuallyOnMain("the stub pi to launch") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == id.rawValue } }

        try await client.agentAction(agentID: id, action: .rename(name: "Build check"))
        #expect(h.server.state.agents.first { $0.id == id }?.name == "Build check")
        await #expect(throws: RemoteHostClientError.self, "no such space") { try await client.agentAction(agentID: id, action: .move(spaceID: SpaceID())) }
        try await client.agentAction(agentID: id, action: .deleteKeepingWorktree)
        #expect(!h.server.state.agents.contains { $0.id == id })
    }

    /// Another Mac starts a thread with no space here: an empty space id, as This Mac's own No space, in a folder of its own.
    @Test func aClientStartsAThreadWithNoSpace() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let client = try await connect(path, token)
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.createAgentNoSpaceCapability))

        let options = try await client.creationOptions(spaceID: SpaceID(rawValue: ""), cwd: nil, fetchFirst: nil)
        #expect(options.model == "stub/model-a" && options.base.isEmpty)
        await #expect(throws: RemoteHostClientError.self, "no repository to branch") {
            try await client.createAgent(spaceID: SpaceID(rawValue: ""), cwd: nil, model: nil, thinking: nil, initialPrompt: "x",
                                         worktreeBranch: "worktree/x")
        }
        let id = try await client.createAgent(spaceID: SpaceID(rawValue: ""), cwd: "/etc", model: nil, thinking: nil, initialPrompt: "Look around")
        let agent = try #require(h.server.state.agents.first { $0.id == id })
        let space = try #require(h.server.state.spaces.first { $0.id == agent.spaceID })
        #expect(space.holdsThreads)
        let cwd = h.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaves.first?.cwd
        #expect(cwd?.hasSuffix("/threads/\(id.rawValue)") == true)
        try await eventuallyOnMain("the stub pi to launch") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == id.rawValue } }
    }

    /// Done is the host's: a finished thread opened on the iPhone (over TCP) leaves the Mac's Done (its app over
    /// host.sock), and the host keeps what was seen. A later completion is unseen everywhere again.
    @Test func openingAFinishedThreadOnOneDeviceClearsDoneOnTheOther() async throws {
        let (h, path, token) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        let agents = ["finished", "other"].map { name in
            let pane = LeafPane(cwd: h.dir.path, agentID: AgentID())
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            return (Agent(id: pane.agentID!, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id), tab)
        }
        try await h.server.putState(ShepherdState(spaces: [space], tabs: agents.map(\.1), agents: agents.map(\.0)))
        let finished = agents[0].0.id, other = agents[1].0.id
        let mac = try await connect(path, token)
        defer { mac.disconnect() }
        let remoteTokenURL = h.dir.appendingPathComponent("remote-token")
        let port = try h.server.startRemoteListener(port: 0, tokenURL: remoteTokenURL)
        let remoteToken = try String(contentsOf: remoteTokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let phone = RemoteHostClient()
        _ = try await phone.connect(host: "127.0.0.1", port: port, token: remoteToken, clientName: "iPhone")
        defer { phone.disconnect() }
        #expect(phone.capabilities.contains(RemoteProtocol.completionSeenCapability))
        let macState = Locked(ShepherdState()), phoneState = Locked(ShepherdState())
        mac.onStateChanged = { state in macState.withValue { $0 = state } }
        phone.onStateChanged = { state in phoneState.withValue { $0 = state } }
        let hostID = UUID()
        func done(_ sidebar: inout FleetSidebarState, _ state: ShepherdState) -> [AgentID] {
            let hosts = [FleetHost(id: hostID, name: "studio", address: "", port: 0, phase: .connected, state: state)]
            sidebar.reconcile(hosts, sessions: [:])
            return sidebar.groups(FleetModel(hosts: hosts, digests: [:])).done.map(\.ref.agent)
        }

        let reporter = try ExtensionClient(path: h.socketPath)
        defer { reporter.closeConnection() }
        try reporter.send(.setAgentStatus(agentID: finished, status: .working))
        try reporter.send(.setAgentStatus(agentID: finished, status: .done))
        var macSidebar = FleetSidebarState(), phoneSidebar = FleetSidebarState()
        try await eventuallyOnMain("both devices to list it in Done") {
            done(&macSidebar, macState.current) == [finished] && done(&phoneSidebar, phoneState.current) == [finished]
        }

        // The phone opens it, then another thread: the completion it read is seen.
        phoneSidebar.select(FleetRef(host: hostID, agent: finished))
        let marks = phoneSidebar.select(FleetRef(host: hostID, agent: other))
        #expect(marks.count == 1)
        for (ref, stamp) in marks { try await phone.agentAction(agentID: ref.agent, action: .markSeen(upTo: stamp)) }
        try await eventuallyOnMain("the Mac's Done to drop it") { done(&macSidebar, macState.current).isEmpty }
        let seen = try #require(h.server.state.agents.first { $0.id == finished })
        #expect(seen.completionSeen == true && seen.seenCompletedAt == seen.completedAt)
        // Negative control: a stale mark never lowers what was seen, and a later completion is unseen everywhere.
        try await phone.agentAction(agentID: finished, action: .markSeen(upTo: 1))
        #expect(h.server.state.agents.first { $0.id == finished }?.seenCompletedAt == seen.seenCompletedAt)
        try reporter.send(.setAgentStatus(agentID: finished, status: .working))
        try await eventuallyOnMain("the next turn") { h.server.state.agents.first { $0.id == finished }?.status == .working }
        try reporter.send(.setAgentStatus(agentID: finished, status: .done))
        try await eventuallyOnMain("the next completion in the Mac's Done") { done(&macSidebar, macState.current) == [finished] }
    }

    /// An agent's agent_* tools on the background host: list its peers, spawn one, delete one.
    /// Before the host served peers they all answered `agent peers unavailable (unsupported)`.
    @Test func anAgentListsSpawnsAndDeletesPeersOnTheHost() async throws {
        try StubPi.installAsEngine()
        let (h, _, _) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(space)
        var agents: [Agent] = []
        for name in ["lead", "worker"] {
            let pane = LeafPane(cwd: space.path)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: agents.count, layout: .leaf(pane))
            let agent = Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
            try await h.server.addAgent(agent, withTab: tab)
            agents.append(agent)
        }
        let (lead, worker) = (agents[0], agents[1])
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        try caller.send(.listAgents(id: 1, agentID: lead.id))
        guard case .agents(1, let peers, _) = try await caller.reply() else { Issue.record("agent_list not served"); return }
        #expect(Set(peers.map(\.id)) == [lead.id, worker.id] && peers.first { $0.isSelf }?.id == lead.id)

        try caller.send(.spawnAgent(id: 2, agentID: lead.id, cwd: space.path, prompt: "Check the build",
                                    model: "claude-fable-5-1", thinking: "low"))
        guard case .agents(2, let spawned, _) = try await caller.reply(), let id = spawned.first?.id else {
            Issue.record("agent_spawn not served"); return
        }
        let created = h.server.state.agents.first { $0.id == id }
        #expect(created?.spaceID == space.id)
        // It records the thread that started it, one deeper; nothing else about it changes.
        #expect(created?.startedBy?.agentID == lead.id && created?.startedBy?.depth == 1 && created?.worktreeBranch == nil)
        // The pinned model and reasoning level land on the new thread; its defaults are not used.
        #expect(created?.model == "claude-fable-5-1" && created?.thinkingLevel == .low)
        try await eventuallyOnMain("the spawned pi to launch") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == id.rawValue } }

        try caller.send(.coordinateAgent(id: 3, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete)))
        guard case .agentResult(3, let result) = try await caller.reply(), result.code == nil else { Issue.record("agent_delete not served"); return }
        #expect(!h.server.state.agents.contains { $0.id == worker.id })
    }

    /// agent_list names the space of every thread, in every space, with its last activity and whether it is asking. Listing a thread in another
    /// space widens nothing: agent_read, agent_send and agent_delete reach a thread by id, in any space, exactly as before (the host checks the
    /// caller's identity and that the target is an ordinary thread, never its space). Pinned so a change to either shows.
    @Test func agentListNamesEverySpaceAndAThreadInAnotherSpaceIsReachedExactlyAsBefore() async throws {
        try StubPi.installAsEngine()
        let (h, _, _) = try host()
        defer { h.stop() }
        h.server.setAgentMessagePolicy(.always)
        let (web, docs) = (Space(name: "acme-web", path: h.dir.path), Space(name: "acme-docs", path: h.dir.appendingPathComponent("docs").path))
        try await h.server.addSpace(web)
        try await h.server.addSpace(docs)
        func thread(_ name: String, in space: Space, lastActiveAt: Double? = nil, waitingOn: String? = nil) async throws -> Agent {
            let pane = LeafPane(cwd: space.path)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            let agent = Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true, lastActiveAt: lastActiveAt, waitingOn: waitingOn)
            try await h.server.addAgent(agent, withTab: tab)
            return agent
        }
        let lead = try await thread("lead", in: web, lastActiveAt: 2_000)
        let far = try await thread("far", in: docs, lastActiveAt: 1_000, waitingOn: "Which branch?")
        let caller = try ExtensionClient(path: h.socketPath), target = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))
        try target.send(.helloAgent(agentID: far.id))
        // The target's registration landed once a request addressed to it is answered by the barrier below.
        try target.send(.coordinateAgent(id: 0, agentID: far.id, targetAgentID: far.id, request: .init(operation: .status)))
        guard case .error(0, "self_control", _) = try await target.reply() else { Issue.record("no registration barrier"); return }

        try caller.send(.listAgents(id: 1, agentID: lead.id))
        guard case .agents(1, let peers, _) = try await caller.reply() else { Issue.record("agent_list not served"); return }
        let byName = Dictionary(uniqueKeysWithValues: peers.map { ($0.name, $0) })
        #expect(byName["lead"]?.space == "acme-web" && byName["lead"]?.lastActiveAt == 2_000 && byName["lead"]?.asking == false && byName["lead"]?.isSelf == true)
        #expect(byName["far"]?.space == "acme-docs" && byName["far"]?.lastActiveAt == 1_000 && byName["far"]?.asking == true && byName["far"]?.isSelf == false)

        // The detailed list, over the wire: newest first, and the plain one above stays in the order of the state.
        try caller.send(.listAgents(id: 5, agentID: lead.id, details: true))
        guard case .agents(5, let detailed, let omitted) = try await caller.reply() else { Issue.record("detailed agent_list not served"); return }
        #expect(detailed.map(\.name) == ["lead", "far"] && omitted == 0)

        // agent_read: relayed to the other space's thread.
        try caller.send(.coordinateAgent(id: 2, agentID: lead.id, targetAgentID: far.id, request: .init(operation: .read)))
        guard case .agentRequest(0, let token, far.id, let relayed) = try await target.reply() else { Issue.record("a read of a thread in another space was refused"); return }
        #expect(relayed.operation == .read)
        try target.send(.agentResponse(agentID: far.id, requestID: token, result: .init(text: "no messages")))
        #expect(try await caller.reply() == .agentResult(id: 2, result: .init(text: "no messages")))
        // agent_send: delivered to it.
        try caller.send(.sendToAgent(id: 3, agentID: lead.id, targetAgentID: far.id, text: "ping", delivery: .report))
        guard case .message(_, let delivered, .report) = try await target.reply() else { Issue.record("a message to a thread in another space was not delivered"); return }
        #expect(delivered.contains("ping"))
        #expect(try await caller.reply() == .ok(id: 3))
        // agent_delete: deletes it.
        try caller.send(.coordinateAgent(id: 4, agentID: lead.id, targetAgentID: far.id, request: .init(operation: .delete)))
        guard case .agentResult(4, let deleted) = try await caller.reply(), deleted.code == nil else { Issue.record("agent_delete of a thread in another space was refused"); return }
        #expect(!h.server.state.agents.contains { $0.id == far.id })
    }

    @Test func detailedAgentListReportsCheckoutStatusWithoutFilenamesOrAttribution() async throws {
        let (h, _, _) = try host()
        defer { h.stop() }
        let dirty = try makeScratchRepo(files: ["sub/tracked.txt": "base\n"])
        try git(["branch", "base"], in: dirty)
        try git(["branch", "--set-upstream-to=base"], in: dirty)
        try git(["commit", "--allow-empty", "-qm", "one ahead"], in: dirty)
        let clean = h.dir.appendingPathComponent("linked-checkout")
        try git(["worktree", "add", "-q", "--detach", clean.path], in: dirty)
        let nonGit = try makeScratchDirectory("not-git")
        let unexpected = "private-untracked-name"
        try "not disclosed".write(to: dirty.appendingPathComponent(unexpected), atomically: true, encoding: .utf8)

        func thread(_ name: String, in directory: URL, expected: PeerCheckoutStatus) async throws -> (AgentID, PeerCheckoutStatus) {
            let space = Space(name: name, path: directory.path)
            try await h.server.addSpace(space)
            let pane = LeafPane(cwd: directory.path)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            let agent = Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
            try await h.server.addAgent(agent, withTab: tab)
            return (agent.id, expected)
        }
        let expected = [try await thread("lead", in: dirty, expected: .dirty),
                        try await thread("shared", in: dirty.appendingPathComponent("sub"), expected: .dirty),
                        try await thread("clean", in: clean, expected: .clean),
                        try await thread("unknown", in: nonGit, expected: .unknown)]
        let caller = try ExtensionClient(path: h.socketPath)
        let agentID = expected[0].0
        try caller.send(.listAgents(id: 1, agentID: agentID))
        guard case .agents(1, let plain, _) = try await caller.reply() else { Issue.record("plain list not served"); return }
        #expect(plain.count == expected.count && plain.allSatisfy { $0.checkoutStatus == nil && $0.commitsAheadOfLocalUpstream == nil })
        try caller.send(.listAgents(id: 2, agentID: agentID, details: true))
        let reply = try await caller.reply()
        guard case .agents(2, let detailed, _) = reply else { Issue.record("detailed list not served"); return }
        #expect(detailed.count == expected.count)
        for (id, checkout) in expected {
            let row = try #require(detailed.first { $0.id == id })
            #expect(row.checkoutStatus == checkout)
            #expect(row.commitsAheadOfLocalUpstream == (checkout == .dirty ? 1 : nil))
        }
        #expect(!String(decoding: try NDJSON.encode(reply), as: UTF8.self).contains(unexpected))
        #expect(h.server.state.agents.count == expected.count)
    }

    /// agent_spawn with place worktree: a new branch from the starter's commit, in the same folder of the repository. A thread three deep
    /// starts none.
    @Test func aThreadStartsAnotherInANewWorktreeAndDepthStopsAChain() async throws {
        try StubPi.installAsEngine()
        // The threads here were started by threads, so no person started their turns: the setting lets them start more.
        let (h, _, _) = try host(threadsStartThreads: true)
        defer { h.stop() }
        let repo = try makeScratchRepo(files: ["README.md": "# acme\n", "web/index.html": "<p>hi</p>\n"])
        let head = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Space(name: "acme-web", path: repo.path)
        try await h.server.addSpace(space)
        let pane = LeafPane(cwd: space.path)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var lead = Agent(name: "lead", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
        lead.startedBy = StartedBy(agentID: AgentID(), agentTitle: "top", at: 1, depth: 2)
        try await h.server.addAgent(lead, withTab: tab)
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        let web = repo.appendingPathComponent("web").path
        // A branch belongs to a new worktree: asked for with the checkout as it is, it is refused, not quietly made a worktree.
        try caller.send(.spawnAgent(id: 9, agentID: lead.id, cwd: web, prompt: "x", place: .checkout, branch: "agent/x"))
        guard case .error(9, "invalid", _) = try await caller.reply() else { Issue.record("a branch with place checkout was accepted"); return }
        try caller.send(.spawnAgent(id: 1, agentID: lead.id, cwd: web, prompt: "Shard the UI tests", place: .worktree, branch: "agent/shard-ui"))
        guard case .agents(1, let spawned, _) = try await caller.reply(), let id = spawned.first?.id else { Issue.record("agent_spawn not served"); return }
        let child = try #require(h.server.state.agents.first { $0.id == id })
        #expect(child.worktreeBranch == "agent/shard-ui" && child.worktreeBase == head && child.startedBy?.depth == 3)
        let path = try #require(child.worktreePath)
        try await eventuallyOnMain("its worktree") { FileManager.default.fileExists(atPath: path + "/web/index.html") }
        #expect(spawned.first?.cwd.hasSuffix("/web") == true, "it starts in the same folder of its worktree")

        // The child is three below the thread the person started: it starts none, here or on another Mac.
        let childCaller = try ExtensionClient(path: h.socketPath)
        try childCaller.send(.helloAgent(agentID: id))
        try childCaller.send(.spawnAgent(id: 2, agentID: id, cwd: space.path, prompt: "Go deeper"))
        guard case .error(2, FleetDispatchCode.tooDeep, _) = try await childCaller.reply() else { Issue.record("a thread three deep started another"); return }
        #expect(h.server.state.agents.count == 2)
    }

    /// With Threads can start threads off, a thread whose turn a person didn't start is refused; one whose turn a person started may start
    /// threads, at most three running at once.
    @Test func agentSpawnNeedsAPersonsTurnAndHoldsToTheCap() async throws {
        try StubPi.installAsEngine()
        let (h, _, _) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(space)
        func thread(_ name: String, startedBy: StartedBy? = nil, order: Int) async throws -> Agent {
            let pane = LeafPane(cwd: space.path)
            let tab = ShepherdCore.Tab(spaceID: space.id, order: order, layout: .leaf(pane))
            var agent = Agent(name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
            agent.startedBy = startedBy
            try await h.server.addAgent(agent, withTab: tab)
            return agent
        }
        let lead = try await thread("lead", order: 0)
        let sent = try await thread("sent", startedBy: StartedBy(agentID: lead.id, agentTitle: "lead", at: 1, depth: 1), order: 1)
        let sentCaller = try ExtensionClient(path: h.socketPath)
        try sentCaller.send(.helloAgent(agentID: sent.id))
        try sentCaller.send(.spawnAgent(id: 1, agentID: sent.id, cwd: space.path, prompt: "Go on"))
        guard case .error(1, "not_asked", _) = try await sentCaller.reply() else { Issue.record("a thread no person prompted started one"); return }

        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))
        for id in 2...4 {
            try caller.send(.spawnAgent(id: id, agentID: lead.id, cwd: space.path, prompt: "Part \(id)"))
            guard case .agents(id, _, _) = try await caller.reply() else { Issue.record("spawn \(id) refused"); return }
        }
        try caller.send(.spawnAgent(id: 5, agentID: lead.id, cwd: space.path, prompt: "One too many"))
        guard case .error(5, "held_limit", _) = try await caller.reply() else { Issue.record("a fourth thread started while three ran"); return }
        #expect(h.server.state.agents.count { $0.startedBy?.agentID == lead.id } == 4, "the three and the idle one")
    }

    @Test func theAppMovesADormantThreadToAnotherSpaceAndItStaysDormant() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let source = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(source)
        let folder = h.dir.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = Space(name: "acme-docs", path: folder.path, parentID: source.id, parentIsExplicit: true)
        try await h.server.addSpace(destination)
        let pane = LeafPane(cwd: source.path)
        let tab = ShepherdCore.Tab(spaceID: source.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "Docs pass", spaceID: source.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true)
        try await h.server.addAgent(agent, withTab: tab)
        let sessions = h.server.pi.sessionsRoot.appendingPathComponent(PiSessionFolder.name(forCwd: source.path))
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let header: [String: Any] = ["type": "session", "id": agent.effectivePiSessionID, "version": 3, "cwd": source.path]
        try (JSONSerialization.data(withJSONObject: header) + Data("\n".utf8))
            .write(to: sessions.appendingPathComponent("test_\(agent.effectivePiSessionID).jsonl"))
        let client = try await connect(path, token)
        defer { client.disconnect() }

        try await client.agentAction(agentID: agent.id, action: .move(spaceID: destination.id))

        #expect(h.server.state.agents.first { $0.id == agent.id }?.spaceID == destination.id)
        #expect(h.server.state.tabs.first { $0.id == tab.id }?.spaceID == destination.id)
        #expect(!StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue }, "a dormant thread stays dormant")
    }

    /// The branch card's "move here" on This Mac: the host re-points a live thread at the worktree
    /// that has the branch, its pi starting again there, then back to the main checkout as an
    /// ordinary thread. No git runs, and the worktree it left stays.
    @Test func theAppMovesAThreadToTheCheckoutThatHasABranchAndItsPiRestartsThere() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let repo = try makeScratchRepo()
        let worktree = repo.deletingLastPathComponent().appendingPathComponent(repo.lastPathComponent + "-payout")
        defer { for url in [repo, worktree] { try? FileManager.default.removeItem(at: url) } }
        try git(["worktree", "add", "-q", "-b", "agent/payout-ui", worktree.path], in: repo)
        let (main, linked) = (PiSessionFolder.realPath(repo.path), PiSessionFolder.realPath(worktree.path))
        let space = Space(name: "acme-web", path: main)
        try await h.server.addSpace(space)
        let agentID = AgentID()
        let pane = LeafPane(cwd: main, agentID: agentID)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "Payout screen", spaceID: space.id, tabID: tab.id, paneID: pane.id, nameIsFinal: true,
                          piSessionID: "stub-session")
        try await h.server.addAgent(agent, withTab: tab)
        PiSessionFile.seedIfMissing(sessionID: "stub-session", cwd: main, sessionsRoot: h.server.pi.sessionsRoot)
        let client = try await connect(path, token)
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.worktreeMoveCapability))

        func serving(in cwd: String) async throws {
            try await eventually("pi to serve in \(cwd)") { @Sendable in
                guard let session = h.server.state.tabs.first?.layout.firstLeaf.sessionID,
                      let info = await h.server.sessionInfo(sessionID: session), info.isAlive, info.cwd == cwd else { return false }
                return await h.server.threadServes(sessionID: session)
            }
        }
        // Started as opening the thread would.
        _ = try await h.server.respawnAgent(AgentSpawn(agent: agent, cwd: "", settings: AgentLaunchSettings()))
        try await serving(in: main)

        var busy = try #require(h.server.state.agents.first)
        busy.status = .working
        try await h.server.updateAgent(busy)
        await #expect(throws: RemoteHostClientError.self, "a running thread stays") {
            _ = try await client.agentQuery(agentID: agent.id, query: .moveToCheckout(path: linked, branch: "agent/payout-ui"))
        }
        busy.status = .idle
        try await h.server.updateAgent(busy)
        await #expect(throws: RemoteHostClientError.self, "a checkout on another branch is refused") {
            _ = try await client.agentQuery(agentID: agent.id, query: .moveToCheckout(path: linked, branch: "main"))
        }
        #expect(h.server.state.tabs.first?.layout.firstLeaf.cwd == main)

        #expect(try await client.agentQuery(agentID: agent.id, query: .moveToCheckout(path: linked, branch: "agent/payout-ui")) == .ok)
        let moved = try #require(h.server.state.agents.first)
        #expect(moved.worktreeBranch == "agent/payout-ui" && moved.worktreePath == linked)
        #expect(h.server.state.tabs.first?.layout.firstLeaf.cwd == linked)
        try await serving(in: linked)
        #expect(PiSessionFile.exists(sessionID: "stub-session", cwd: linked, sessionsRoot: h.server.pi.sessionsRoot))

        #expect(try await client.agentQuery(agentID: agent.id, query: .moveToCheckout(path: main, branch: "main")) == .ok)
        let back = try #require(h.server.state.agents.first)
        #expect(back.worktreeBranch == nil && back.worktreePath == nil)
        try await serving(in: main)
        #expect(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("README.md").path), "the worktree it left stays")
        #expect(try git(["branch", "--show-current"], in: worktree).trimmingCharacters(in: .whitespacesAndNewlines) == "agent/payout-ui")
    }

    @Test func theAppMakesADesignAndItsAgentStartsInTheDesignsFolder() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        h.server.setDesignsServed(true)
        let client = try await connect(path, token)
        defer { client.disconnect() }
        try await eventuallyOnMain("the host to serve designs") { client.capabilities.contains(RemoteProtocol.designsCapability) }

        guard case .created(let designID, let agentID?) = try await client.design(.create(RemoteDesignCreate(brief: "A pricing page for acme-web"))) else {
            Issue.record("expected a design with its agent"); return
        }
        let agent = try #require(h.server.state.agents.first { $0.id == agentID })
        #expect(agent.designID == designID && h.server.state.designs.first { $0.id == designID }?.agentID == agentID)
        let folder = try #require(h.server.designs.folder(for: designID))
        #expect(h.server.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd == folder.path)
        try await eventuallyOnMain("the stub pi to launch") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == agentID.rawValue } }
        // Open on it answers the running agent rather than starting another.
        #expect(try await client.design(.ensureAgent(designID: designID)) == .agent(agentID))
    }

    @Test func openingADormantThreadStartsItsPi() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        let agentID = AgentID()
        let threadPane = LeafPane(cwd: h.dir.path, agentID: agentID)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(threadPane))
        let agent = Agent(id: agentID, name: "worker", spaceID: space.id, tabID: tab.id, paneID: threadPane.id)
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let client = try await connect(path, token)
        defer { client.disconnect() }

        await #expect(throws: RemoteHostClientError.self) { _ = try await client.nativeThread(agentID: agent.id, request: .snapshot()) }
        try await eventuallyOnMain("its pi to start and bind", timeout: .seconds(20)) {
            h.server.state.tabs.first?.layout.leaf(withID: threadPane.id)?.sessionID != nil
        }
    }

    /// A hosted thread (no app consumer: Shepherd Nightly's background host) whose pi is killed
    /// from outside keeps its agent and says it stopped. It reads idle, so a draining host is not
    /// held for it, and opening it again never starts another pi: only Retry does.
    @Test func aHostedThreadWhosePiStopsOnItsOwnWaitsAndNeverRestarts() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        func dormant(_ name: String) -> (Agent, Tab) {
            let agentID = AgentID()
            let pane = LeafPane(cwd: h.dir.path, agentID: agentID)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            return (Agent(id: agentID, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id), tab)
        }
        let (stopped, stoppedTab) = dormant("worker"), (control, controlTab) = dormant("control")
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [stoppedTab, controlTab], agents: [stopped, control]))
        let client = try await connect(path, token)
        defer { client.disconnect() }
        func launches(_ agent: Agent) -> Int { StubPi.launches().filter { $0.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue }.count }
        @Sendable func snapshot(_ agent: Agent) async throws -> NativeThreadSnapshot? { try await client.nativeThread(agentID: agent.id, request: .snapshot()).snapshotValue }

        // Opening a dormant thread starts its pi.
        _ = try? await snapshot(stopped)
        try await eventually("its pi to serve", timeout: .seconds(20)) { @Sendable in (try? await snapshot(stopped))?.piSessionID.isEmpty == false }
        // Polls that arrive while the first pi starts can each ask for one; once it serves, none do.
        let started = launches(stopped)
        #expect(started >= 1)
        let reporter = try ExtensionClient(path: h.socketPath)
        defer { reporter.closeConnection() }
        try reporter.send(.setAgentStatus(agentID: stopped.id, status: .working))
        try await eventuallyOnMain("the thread to read working") { h.server.state.agents.first { $0.id == stopped.id }?.status == .working }
        #expect(!h.server.quietForDrain)

        let pid = try await h.server.enqueue { @Sendable in try #require(h.server.rpcThread(forAgent: stopped.id)).session.processIdentifier }
        #expect(kill(pid, SIGKILL) == 0)
        try await eventually("the client to read that it stopped") { @Sendable in
            (try? await snapshot(stopped))?.startProblem == NativeStartProblem(kind: .stopped, signal: 9)
        }
        try await eventuallyOnMain("the thread to read idle") { h.server.state.agents.first { $0.id == stopped.id }?.status == .idle }
        #expect(h.server.quietForDrain, "a stopped thread does not hold the host's drain")

        for _ in 0..<3 { #expect(try await snapshot(stopped)?.startProblem?.kind == .stopped) }
        // A thread opened after them starts: whatever demand the stopped one raised has been served by now.
        _ = try? await snapshot(control)
        try await eventuallyOnMain("the other thread's pi to launch") { launches(control) == 1 }
        #expect(launches(stopped) == started, "no pi starts for a thread that stopped on its own")

        // Retry (`restartPi`) starts it again.
        try await client.agentAction(agentID: stopped.id, action: .restartPi(newConversation: false))
        try await eventually("its pi to serve again", timeout: .seconds(20)) { @Sendable in
            let thread = try? await snapshot(stopped)
            return thread?.startProblem == nil && thread?.piSessionID.isEmpty == false
        }
        #expect(launches(stopped) == started + 1)
    }

    @Test func theAppOpensStartsRenamesReadsAndClosesATerminal() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(space)
        let client = try await connect(path, token)
        defer { client.disconnect() }
        let id = try await client.createAgent(spaceID: space.id, cwd: nil, model: nil, thinking: nil, initialPrompt: nil)
        let agent = try #require(h.server.state.agents.first { $0.id == id })
        func leaf(_ paneID: PaneID) -> LeafPane? { h.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: paneID) }

        // A new tab's shell starts with it.
        let opened = try await client.openPane(agentID: id, relativeTo: agent.paneID!, axis: .vertical)
        let session = try #require(leaf(opened)?.sessionID)
        #expect(await h.server.sessionInfo(sessionID: session)?.isAlive == true)
        client.write(sessionID: session, data: Data("echo HOSTED_SHELL\n".utf8))
        try await h.waitForScreen(session, toContain: "HOSTED_SHELL")

        try await client.agentAction(agentID: id, action: .renameTerminal(paneID: opened, title: "server"))
        #expect(leaf(opened)?.title == "server")

        // A terminal restored with no shell starts on demand, once.
        h.server.killSession(session)
        try await h.server.updatePaneSession(tabID: agent.tabID, paneID: opened, sessionID: nil)
        try await client.agentAction(agentID: id, action: .startTerminal(paneID: opened))
        let restarted = try #require(leaf(opened)?.sessionID)
        #expect(restarted != session)
        try await client.agentAction(agentID: id, action: .startTerminal(paneID: opened))
        #expect(leaf(opened)?.sessionID == restarted, "a running shell is kept")

        // Two demands while it starts (a view shown again, a phone) share the one start, neither fails.
        h.server.killSession(restarted)
        try await h.server.updatePaneSession(tabID: agent.tabID, paneID: opened, sessionID: nil)
        async let first: Void = client.agentAction(agentID: id, action: .startTerminal(paneID: opened))
        async let second: Void = client.agentAction(agentID: id, action: .startTerminal(paneID: opened))
        _ = try await (first, second)
        let shared = try #require(leaf(opened)?.sessionID)
        #expect(shared != restarted)
        #expect(await h.server.sessionInfo(sessionID: shared)?.isAlive == true)

        // The thread itself is never a terminal.
        await #expect(throws: RemoteHostClientError.self) {
            try await client.agentAction(agentID: id, action: .startTerminal(paneID: agent.paneID!))
        }
        // An agent's own terminal tools.
        let listed = await h.server.handleTerminalRequest(.list(agentID: id), hosting: ThreadHosting(
            defaults: { fatalError() }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        #expect(listed == .panes([PaneInfo(id: opened, cwd: h.dir.path, isAgentPane: false, isFocused: false, isAlive: true)]))

        try await client.closePane(agentID: id, paneID: opened)
        #expect(leaf(opened) == nil)
    }

    /// The app tells the host which pane has its keyboard (`focusThread`) and its terminals report
    /// their grid: `terminal_list` marks the focused one, and a terminal no view measured starts at
    /// the last grid this Mac's app reported, not 80×24. The focus goes with the app.
    @Test func theAppsFocusedTerminalAndLastGridReachTheHost() async throws {
        try StubPi.installAsEngine()
        let (h, path, token) = try host()
        defer { h.stop() }
        let space = Space(name: "acme-web", path: h.dir.path)
        try await h.server.addSpace(space)
        let client = try await connect(path, token)
        let id = try await client.createAgent(spaceID: space.id, cwd: nil, model: nil, thinking: nil, initialPrompt: nil)
        let agent = try #require(h.server.state.agents.first { $0.id == id })
        let hosting = ThreadHosting(defaults: { fatalError() }, launch: { AgentLaunchSettings() },
                                    shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) })
        func focused() async -> [PaneID] {
            guard case .panes(let panes) = await h.server.handleTerminalRequest(.list(agentID: id), hosting: hosting) else { return [] }
            return panes.filter(\.isFocused).map(\.id)
        }

        let measured = try await client.openPane(agentID: id, relativeTo: agent.paneID!, axis: .vertical)
        let session = try #require(h.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: measured)?.sessionID)
        _ = try await client.attach(sessionID: session, cols: 132, rows: 41)
        try await client.focusThread(id, pane: measured)
        #expect(await focused() == [measured])

        guard case .opened(let unseen) = await h.server.handleTerminalRequest(
            .open(agentID: id, axis: .vertical, cwd: nil, relativeTo: nil, command: "stty size"), hosting: hosting) else {
            Issue.record("no terminal opened")
            return
        }
        let unseenSession = try #require(h.server.state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: unseen.id)?.sessionID)
        try await h.waitForScreen(unseenSession, toContain: "41 132")

        client.disconnect()
        let server = h.server
        try await eventually("the app's focus to go with it") { @Sendable in
            await server.enqueueValue { @Sendable in server.localFocusedPane } == nil
        }
        #expect(await focused().isEmpty)
    }
}
