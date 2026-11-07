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
        await #expect(throws: RemoteHostClientError.self) { try await client.agentAction(agentID: id, action: .move(spaceID: SpaceID())) }
        try await client.agentAction(agentID: id, action: .deleteKeepingWorktree)
        #expect(!h.server.state.agents.contains { $0.id == id })
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
