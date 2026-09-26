import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A design's agent is no thread (docs/designs.md › Design agents and ordinary threads). The
/// server refuses every peer request from or to one, even over a panes connection an older
/// installed extension opened, and sends remote clients neither designs nor their agents.
@Suite("Design isolation", .integrationTimeLimit)
struct DesignIsolationTests {
    /// A thread, and a design drawn by its own agent.
    private func workspace(_ h: ScratchServer) async throws -> (thread: Agent, drawer: Agent, design: DesignID) {
        let space = Fixture.space()
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Landing hero")
        drawer.agent.designID = designID
        let thread = Fixture.agent(in: space, name: "Fix login bug")
        try await h.seed(Fixture.workspace([thread, drawer], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Landing hero", agentID: drawer.agent.id, createdAt: 1_000))
        return (thread.agent, drawer.agent, designID)
    }

    /// Registers `client` as `agentID`'s panes connection; the refused self-status request is
    /// the barrier that proves it landed.
    private func register(_ client: ExtensionClient, as agentID: AgentID) async throws {
        try client.send(.helloAgent(agentID: agentID))
        try client.send(.coordinateAgent(id: 0, agentID: agentID, targetAgentID: agentID, request: .init(operation: .status)))
        guard case .error(0, _, _) = try await client.reply() else {
            Issue.record("the registration barrier was not refused")
            return
        }
    }

    @Test(arguments: [AgentCoordinationRequest.Operation.read, .steer, .interrupt, .status, .delete])
    func aThreadCannotReadOrControlADesignsAgent(_ operation: AgentCoordinationRequest.Operation) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (thread, drawer, _) = try await workspace(h)
        let asked = Locked(0)
        h.server.onAgentPeerRequest = { _, _ in asked.withValue { $0 += 1 } }
        let caller = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        try await register(caller, as: thread.id)
        try await register(target, as: drawer.id)

        try caller.send(.coordinateAgent(id: 7, agentID: thread.id, targetAgentID: drawer.id, request: .init(operation: operation, text: "x")))

        guard case .error(7, "not_a_thread", _) = try await caller.reply() else { Issue.record("\(operation) reached a design's agent"); return }
        try caller.send(.sendToAgent(id: 8, agentID: thread.id, targetAgentID: drawer.id, text: "the hero is ready"))
        guard case .error(8, "not_a_thread", _) = try await caller.reply() else { Issue.record("a message reached a design's agent"); return }
        #expect(asked.current == 0, "nothing reaches the app")
    }

    @Test func aDesignsAgentCannotListMessageSpawnOrControlThreads() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (thread, drawer, _) = try await workspace(h)
        let asked = Locked(0)
        h.server.onAgentPeerRequest = { _, _ in asked.withValue { $0 += 1 } }
        let designer = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        try await register(designer, as: drawer.id)
        try await register(target, as: thread.id)

        let requests: [ExtensionMessage] = [
            .listAgents(id: 1, agentID: drawer.id),
            .sendToAgent(id: 2, agentID: drawer.id, targetAgentID: thread.id, text: "the hero board is ready"),
            .spawnAgent(id: 3, agentID: drawer.id, cwd: h.dir.path, prompt: "build this"),
            .coordinateAgent(id: 4, agentID: drawer.id, targetAgentID: thread.id, request: .init(operation: .steer, text: "stop")),
            .coordinateAgent(id: 5, agentID: drawer.id, targetAgentID: thread.id, request: .init(operation: .read)),
        ]
        for (index, request) in requests.enumerated() {
            try designer.send(request)
            guard case .error(index + 1, "not_a_thread", _) = try await designer.reply() else {
                Issue.record("a design's agent was served \(request)")
                return
            }
        }
        #expect(asked.current == 0, "nothing reaches the app")
        #expect(h.server.state.agents.count == 2)
    }

    /// A remote client (another Mac, an iPhone) has no design screen: it is sent the threads only.
    @Test func aRemoteClientIsSentNoDesignOrDesignAgent() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let (thread, drawer, _) = try await workspace(r.host)
        let client = try await r.raw()

        try client.send(.stateFetch(id: 2))
        var fetched: ShepherdState?
        var pushes: [ShepherdState] = []
        while fetched == nil {
            switch try await client.next() {
            case .state(2, let state): fetched = state
            case .stateChanged(let state): pushes.append(state)
            default: break
            }
        }
        #expect(fetched?.agents.map(\.id) == [thread.id])
        #expect(fetched?.designs.isEmpty == true && fetched?.tabs.contains { $0.id == drawer.tabID } == false)

        try await r.server.renameAgent(thread.id, to: "renamed")
        while !(pushes.last?.agents.contains { $0.name == "renamed" } ?? false) {
            if case .stateChanged(let state) = try await client.next() { pushes.append(state) }
        }
        for pushed in pushes {
            #expect(pushed.agents.map(\.id) == [thread.id])
            #expect(pushed.designs.isEmpty)
        }
        #expect(r.server.state.agents.count == 2, "the host keeps its design's agent")
    }
}
