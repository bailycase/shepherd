import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A client view model driving a second in-process Shepherd over the authenticated TCP
/// remote protocol. The host runs its own view model, which answers host-side requests
/// (reviews, children, worktrees) exactly as a real host does.
@Suite("Remote hosts", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct RemoteHostTests {
    /// Both machines hold an identical workspace, so every id matches across them: nothing
    /// done to the remote agent may land on the local one.
    @Test func remoteNavigationAndActionsNeverTouchTheLocalAgentWithTheSameID() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: local.dir.path)
        let agents = (0..<2).map { Fixture.agent("agent\($0)", in: space, order: $0) }
        let original = Fixture.state(spaces: [space], agents: agents)
        let vm = try await local.start(with: original)
        try await remote.host.start(with: original)
        let connection = try await remote.connect(local.remoteHosts)
        vm.selectAgent(agents[0].agent.id)

        vm.selectRemoteAgent(hostID: connection.id, agentID: agents[0].agent.id)
        vm.selectAdjacentAgent(1)
        let target = try #require(vm.selectedRemoteAgent)

        #expect(target == RemoteAgentRef(hostID: connection.id, agentID: agents[1].agent.id))
        #expect(vm.selectedAgentID == agents[0].agent.id, "the local selection is kept for coming back")
        vm.openUserReview()
        #expect(vm.remoteReviews[target] != nil && vm.reviewSessions.isEmpty)
        #expect(!vm.dropRemoteAgent(payload: ShepherdViewModel.dragPayload(agent: agents[0].agent.id), on: target))

        try await local.remoteHosts.agentAction(target, action: .rename(name: "remote only"))
        try await local.remoteHosts.agentAction(target, action: .deleteKeepingWorktree)

        #expect(remote.host.server.state.agents.map(\.id) == [agents[0].agent.id])
        #expect(local.server.state == original && vm.state == original)
    }

    @Test(arguments: ["available", "hostRemoved", "agentGone"])
    func agentCommandsWhileARemoteAgentIsSelectedLeaveTheLocalWorkspaceAlone(remoteState: String) async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: local.dir.path)
        let agent = Fixture.agent(in: space, auxiliary: 1)
        let original = Fixture.state(spaces: [space], agents: [agent])
        let vm = try await local.start(with: original)
        try await remote.host.start(with: original)
        let connection = try await remote.connect(local.remoteHosts)
        vm.selectAgent(agent.agent.id)
        vm.focusedPaneID = agent.auxiliary[0].id
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.agent.id)
        let selected = vm.selectedRemoteAgent
        switch remoteState {
        case "hostRemoved": local.remoteHosts.removeHost(id: connection.id)
        case "agentGone": connection.state.agents = []
        default: break
        }

        vm.renameSelectedAgent()
        vm.focusSelectedAgent()
        await local.settle()

        #expect(vm.agentRenameTarget == nil)
        #expect(vm.selectedRemoteAgent == selected)
        #expect(vm.remoteFocusedPaneID == (remoteState == "available" ? agent.piPane.id : nil))
        #expect(local.server.state == original && remote.host.server.state == original)
        #expect(vm.selectedAgentID == agent.agent.id && vm.focusedPaneID == agent.auxiliary[0].id)
    }

    @Test func aRemoteAgentsReviewShowsTheHostsDiff() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let repo = try makeScratchRepo(files: ["host.txt": "before\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try "after\n".write(to: repo.appendingPathComponent("host.txt"), atomically: true, encoding: .utf8)
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.agent.id)

        vm.openUserReview()

        let review = try #require(vm.remoteReviews[target])
        try await eventuallyOnMain("the host's diff to arrive") { !review.isLoading }
        #expect(review.loadError == nil)
        #expect(review.files.map(\.displayPath) == ["host.txt"])
        #expect(vm.reviewSessions.isEmpty)
        vm.openUserReview()
        #expect(vm.remoteReviews[target] == nil, "the header button toggles the review closed")
    }

    @Test func remoteSubagentsFollowTheHostAndClearWhenTheAgentOrHostGoes() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent("parent", in: space)
        let hostVM = try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let target = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        vm.collapsedHosts.insert(connection.id)

        hostVM.applyAgentChildren(agent.agent.id, [ChildRun(runID: "run", label: "hidden child", state: "running")])
        try await eventuallyOnMain("the child to reach the client") { vm.remoteChildren[target]?.first?.state == "running" }
        #expect(vm.paletteItems.contains { $0.title == "hidden child" }, "a collapsed host's children stay searchable")

        hostVM.applyAgentChildren(agent.agent.id, [ChildRun(runID: "run", label: "hidden child", state: "blocked", needsAttention: true)])
        try await eventuallyOnMain("the child's attention to reach the client") { vm.remoteChildren[target]?.first?.needsAttention == true }
        #expect(vm.blockedCount == 1)

        try await remote.host.server.deleteAgent(agent.agent.id)
        try await eventuallyOnMain("the retired agent's children to clear") { connection.children[agent.agent.id] == nil }
        local.remoteHosts.removeHost(id: connection.id)
        #expect(connection.children.isEmpty)
        #expect(vm.blockedCount == 0)
    }

    @Test func quickCreateWhileARemoteAgentIsSelectedCreatesOnTheHostOnly() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space("remote", path: "/remote/project")
        let agent = Fixture.agent("remote worker", in: space)
        try await remote.host.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let minted = AgentID()
        let requests = RecordedCreates()
        remote.host.server.onRemoteCreateAgent = { request, completion in
            requests.append(request)
            completion(.success(minted))
        }
        let vm = try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        vm.selectRemoteAgent(hostID: connection.id, agentID: agent.agent.id)

        vm.quickCreateAgent()

        try await eventuallyOnMain("the new remote agent to be selected") {
            vm.selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: minted)
        }
        #expect(requests.all.map(\.spaceID) == [space.id] && requests.all.map(\.cwd) == [space.path])
        #expect(!vm.showNewAgentSheet)
        #expect(local.server.state.agents.isEmpty)
    }

    @Test func aRemoteWorktreeRequestForAnotherRepositoryIsRefusedBeforeAnythingChanges() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let first = try WorktreeSandbox(), second = try WorktreeSandbox()
        defer { first.remove(); second.remove() }
        let space = Fixture.space("first", path: first.repo.path)
        try await remote.host.start(with: ShepherdState(spaces: [space]))
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)

        let error = await #expect(throws: RemoteHostClientError.self) {
            try await local.remoteHosts.createAgent(hostID: connection.id, spaceID: space.id, cwd: second.repo.path, model: nil,
                                                    thinking: nil, initialPrompt: nil, worktreeBranch: "worktree/wrong",
                                                    worktreeBase: "main", worktreeFetchFirst: false)
        }
        #expect(error?.rejectionCode == "create_failed", "the host refused it, not a dropped connection")

        #expect(remote.host.server.state.agents.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: second.path("worktree/wrong")))
        #expect(try second.branches() == ["main"])
    }

    @Test func aDisconnectedOrReplacedHostRejectsActionsApprovedAgainstTheOldConnection() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        try await remote.host.start()
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let endpoint = connection.endpointID, transport = connection.transportID
        let target = RemoteAgentRef(hostID: connection.id, agentID: AgentID())

        connection.phase = .disconnected
        do {
            _ = try await local.remoteHosts.agentQuery(target, query: .deleteKeepingWorktree)
            Issue.record("a disconnected host accepted an action")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "not_sent")
        }
        connection.phase = .connected
        local.remoteHosts.updateHost(id: connection.id, name: "replacement", host: "127.0.0.1", port: remote.port, token: remote.token)
        try await eventuallyOnMain("the replacement connection") { connection.phase == .connected && connection.endpointID != endpoint }

        await #expect(throws: RemoteHostClientError.self) {
            _ = try await local.remoteHosts.agentQuery(target, query: .deleteKeepingWorktree, endpointID: endpoint, transportID: transport)
        }
    }
}

/// Worktree queries a remote client sends to the host that owns the checkout.
@Suite("Remote worktrees", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct RemoteWorktreeTests {
    @MainActor private struct Setup {
        let local: AppHarness
        let remote: RemoteHostHarness
        let sandbox: WorktreeSandbox
        let agent: AgentFixture
        let target: RemoteAgentRef
        let checkout: String
        func stop() { local.stop(); remote.stop(); sandbox.remove() }
    }

    /// A host worktree agent on `worktree/remote` with one commit beyond main.
    private func setUp() async throws -> Setup {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        let sandbox = try WorktreeSandbox(origin: true)
        let checkout = try GitWorktree.add(repo: sandbox.repo.path, branch: "worktree/remote", from: "origin/main")
        try git(["commit", "-q", "--allow-empty", "-m", "feature"], in: URL(fileURLWithPath: checkout))
        let space = Fixture.space("proj", path: sandbox.repo.path)
        var agent = Fixture.agent("host feature", in: space, cwd: checkout)
        agent.agent.worktreeBranch = "worktree/remote"
        agent.agent.worktreePath = checkout
        agent.agent.worktreeBase = "origin/main"
        remote.host.settings.worktreeGeneratePRDescription = false
        remote.host.settings.worktreeAutoCommit = false
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        return Setup(local: local, remote: remote, sandbox: sandbox, agent: agent,
                     target: RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id), checkout: checkout)
    }

    @Test func theFinalizePreviewDescribesTheHostCheckoutWithTheHostsSettings() async throws {
        let s = try await setUp()
        defer { s.stop() }
        let remotes = s.local.remoteHosts

        guard case .worktreeInfo(let info) = try await remotes.agentQuery(s.target, query: .worktreeInfo) else {
            Issue.record("expected worktree info"); return
        }

        #expect(info.path == canonical(URL(fileURLWithPath: s.checkout)) && info.branch == "worktree/remote")
        #expect(info.defaults.base == "main" && info.defaults.title == "host feature")
        #expect(!info.defaults.autoCommit && info.generateDescription == false)
        #expect(info.warning == "1 commits not on a remote")
        #expect(try await remotes.agentQuery(s.target, query: .worktreeCommitCount(base: "main")) == .worktreeCommitCount(1))
        #expect(try await remotes.agentQuery(s.target, query: .worktreeCommitCount(base: "missing")) == .worktreeCommitCount(nil))
        #expect(try await remotes.agentQuery(s.target, query: .worktreeDescription(base: "main", title: "feature")) == .worktreeDescription(body: ""))
    }

    @Test func aConfirmedRemoteDeletionRetiresTheAgentAndRemovesTheCheckoutAndBranch() async throws {
        let s = try await setUp()
        defer { s.stop() }
        let remotes = s.local.remoteHosts
        guard case .worktreeInfo(let info) = try await remotes.agentQuery(s.target, query: .worktreeInfo) else {
            Issue.record("expected worktree info"); return
        }
        let operation = UUID()

        _ = try await remotes.agentQuery(s.target, query: .deleteWorktree(operationID: operation, confirmedWarning: info.warning, fingerprint: info.fingerprint))

        var status: RemoteWorktreeOperation?
        try await eventuallyAsync("the host to finish the deletion", timeout: .seconds(20)) {
            guard case .worktreeOperation(let current) = try await remotes.agentQuery(s.target, query: .worktreeStatus(operationID: operation)) else { return false }
            status = current
            return current.finished
        }
        #expect(status?.error == nil)
        #expect(!FileManager.default.fileExists(atPath: s.checkout))
        #expect(try s.sandbox.branches() == ["main"])
        #expect(s.remote.host.server.state.agents.isEmpty)
    }

    @Test func aRemoteDeletionIsRefusedWhenTheCheckoutChangedAfterConfirmation() async throws {
        let s = try await setUp()
        defer { s.stop() }
        let remotes = s.local.remoteHosts
        guard case .worktreeInfo(let info) = try await remotes.agentQuery(s.target, query: .worktreeInfo) else {
            Issue.record("expected worktree info"); return
        }
        try "late".write(toFile: s.checkout + "/late.txt", atomically: true, encoding: .utf8)

        let error = await #expect(throws: RemoteHostClientError.self) {
            _ = try await remotes.agentQuery(s.target, query: .deleteWorktree(operationID: UUID(), confirmedWarning: info.warning, fingerprint: info.fingerprint))
        }
        #expect(error?.rejectionCode == "query_failed", "the host refused it, not a dropped connection")

        #expect(FileManager.default.fileExists(atPath: s.checkout + "/late.txt"))
        #expect(s.remote.host.server.state.agents.count == 1)
    }
}

/// Remote pane streams: attach at the viewer's settled grid, and detaching releases the
/// viewport without killing the host process.
@Suite("Remote pane streams", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct RemotePaneStreamTests {
    @Test func theFirstAttachUsesTheViewersSettledGrid() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let info = try await remote.host.server.createSession(params: CreateSessionParams(cwd: remote.host.dir.path, command: ["/bin/cat"], cols: 80, rows: 24))
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let pane = try #require(local.remoteHosts.paneSession(connection: connection, sessionID: info.id))

        pane.noteGrid(cols: 97, rows: 34)
        pane.noteGrid(cols: 139, rows: 34)

        try await eventuallyOnMain("the pane to go live") { pane.phase == .live }
        let server = remote.host.server
        try await eventuallyAsync("the host PTY to take the settled grid") {
            guard let current = await server.sessionInfo(sessionID: info.id) else { return false }
            return (current.cols, current.rows) == (139, 34)
        }
    }

    @Test func closingARemotePaneReleasesItsViewportAndKeepsTheHostProcess() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let server = remote.host.server
        let info = try await server.createSession(params: CreateSessionParams(cwd: remote.host.dir.path, command: ["/bin/cat"], cols: 120, rows: 40))
        server.reportLocalViewport(sessionID: info.id, cols: 120, rows: 40)
        try await local.start()
        let connection = try await remote.connect(local.remoteHosts)
        let pane = try #require(local.remoteHosts.paneSession(connection: connection, sessionID: info.id))
        pane.noteGrid(cols: 80, rows: 24)
        try await eventuallyAsync("the remote viewer's smaller grid to win") { await server.sessionInfo(sessionID: info.id)?.cols == 80 }

        local.remoteHosts.closePane(connection: connection, sessionID: info.id)

        #expect(connection.pane(for: info.id) == nil)
        try await eventuallyAsync("the host's own viewport to return") {
            guard let current = await server.sessionInfo(sessionID: info.id) else { return false }
            return current.cols == 120 && current.rows == 40
        }
        #expect(await server.sessionInfo(sessionID: info.id)?.isAlive == true)
    }
}

final class RecordedCreates: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RemoteCreateAgentRequest] = []
    func append(_ request: RemoteCreateAgentRequest) { lock.withLock { requests.append(request) } }
    var all: [RemoteCreateAgentRequest] { lock.withLock { requests } }
}
