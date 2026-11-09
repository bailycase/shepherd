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
    private func host() throws -> (ScratchServer, path: String, token: String) {
        let h = try ScratchServer.fresh()
        h.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
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
        guard case .agents(1, let peers) = try await caller.reply() else { Issue.record("agent_list not served"); return }
        #expect(Set(peers.map(\.id)) == [lead.id, worker.id] && peers.first { $0.isSelf }?.id == lead.id)

        try caller.send(.spawnAgent(id: 2, agentID: lead.id, cwd: space.path, prompt: "Check the build"))
        guard case .agents(2, let spawned) = try await caller.reply(), let id = spawned.first?.id else {
            Issue.record("agent_spawn not served"); return
        }
        #expect(h.server.state.agents.first { $0.id == id }?.spaceID == space.id)
        try await eventuallyOnMain("the spawned pi to launch") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == id.rawValue } }

        try caller.send(.coordinateAgent(id: 3, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete)))
        guard case .agentResult(3, let result) = try await caller.reply(), result.code == nil else { Issue.record("agent_delete not served"); return }
        #expect(!h.server.state.agents.contains { $0.id == worker.id })
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
}
