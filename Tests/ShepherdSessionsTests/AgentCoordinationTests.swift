import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

@Suite("Agent coordination", .serialized)
struct AgentCoordinationTests {
    @Test func correlatesLiveRequestsAndRejectsOtherConnections() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(socketPath: dir.appendingPathComponent("s").path, stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let space = Space(name: "test", path: dir.path)
        let tabs = (0..<2).map { Tab(spaceID: space.id, order: $0, layout: .leaf(LeafPane(cwd: dir.path))) }
        let agents = tabs.map { Agent(name: "peer", spaceID: space.id, tabID: $0.id) }
        try await server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let caller = try ExtensionClient(path: dir.appendingPathComponent("s").path)
        let target = try ExtensionClient(path: dir.appendingPathComponent("s").path)
        let impostor = try ExtensionClient(path: dir.appendingPathComponent("s").path)
        defer { caller.closeConnection(); target.closeConnection(); impostor.closeConnection() }
        try caller.send(.helloAgent(agentID: agents[0].id))
        try target.send(.helloAgent(agentID: agents[1].id))
        try target.send(.coordinateAgent(id: 1, agentID: agents[1].id, targetAgentID: agents[1].id, request: .init(operation: .status)))
        guard case .error(_, "self_control", _) = try target.readReply() else { Issue.record("self wait allowed"); return }

        try caller.send(.coordinateAgent(id: 7, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .steer, text: "new plan")))
        guard case .agentRequest(0, let token, let targetID, let forwarded) = try target.readReply() else {
            Issue.record("missing correlated target request"); return
        }
        #expect(targetID == agents[1].id)
        #expect(UUID(uuidString: token) != nil)
        #expect(forwarded.text == "[from: peer] new plan")
        try impostor.send(.helloAgent(agentID: agents[1].id))
        try impostor.send(.agentResponse(agentID: agents[1].id, requestID: token, result: .init(text: "forged")))
        try target.send(.agentResponse(agentID: agents[0].id, requestID: token, result: .init(text: "wrong identity")))
        try target.send(.agentResponse(agentID: agents[1].id, requestID: token, result: .init(text: "dispatch requested")))
        #expect(try caller.readReply() == .agentResult(id: 7, result: .init(text: "dispatch requested")))
        impostor.closeConnection()

        try caller.send(.coordinateAgent(id: 8, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .read)))
        guard case .agentRequest(_, let cancelToken, _, _) = try target.readReply() else { Issue.record("missing read"); return }
        try caller.send(.cancelAgentRequest(id: 8, agentID: agents[0].id))
        #expect(try caller.readReply() == .agentResult(id: 8, result: .init(text: "request cancelled", code: "cancelled")))
        try target.send(.agentResponse(agentID: agents[1].id, requestID: cancelToken, result: .init(text: "late")))

        try caller.send(.coordinateAgent(id: 9, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .interrupt)))
        guard case .agentRequest = try target.readReply() else { Issue.record("missing interrupt"); return }
        target.closeConnection()
        #expect(try caller.readReply() == .agentResult(id: 9, result: .init(text: "agent connection closed", code: "disconnected")))
        try caller.send(.coordinateAgent(id: 10, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .status)))
        guard case .error(10, "not_running", _) = try caller.readReply() else { Issue.record("disconnected target allowed"); return }
        try caller.send(.coordinateAgent(id: 11, agentID: agents[0].id, targetAgentID: agents[0].id, request: .init(operation: .delete)))
        guard case .error(11, "self_control", _) = try caller.readReply() else { Issue.record("self delete allowed"); return }
        try caller.send(.coordinateAgent(id: 12, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .delete)))
        #expect(try caller.readReply() == .agentResult(id: 12, result: .init(text: "native confirmation unavailable", code: "unsupported")))
        #expect(server.state.agents == agents)
    }

    @Test func recipientTimeoutAndOversizedResultAreCorrelated() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(socketPath: dir.appendingPathComponent("s").path, stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let space = Space(name: "test", path: dir.path)
        let tabs = (0..<2).map { Tab(spaceID: space.id, order: $0, layout: .leaf(LeafPane(cwd: dir.path))) }
        let agents = tabs.map { Agent(name: "peer", spaceID: space.id, tabID: $0.id) }
        try await server.putState(ShepherdState(spaces: [space], tabs: tabs, agents: agents))
        let caller = try ExtensionClient(path: dir.appendingPathComponent("s").path)
        let target = try ExtensionClient(path: dir.appendingPathComponent("s").path)
        defer { caller.closeConnection(); target.closeConnection() }
        try caller.send(.helloAgent(agentID: agents[0].id))
        try target.send(.helloAgent(agentID: agents[1].id))
        try target.send(.coordinateAgent(id: 1, agentID: agents[1].id, targetAgentID: agents[1].id, request: .init(operation: .status)))
        _ = try target.readReply()
        try caller.send(.coordinateAgent(id: 2, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .read)))
        guard case .agentRequest(_, let token, _, _) = try target.readReply() else { Issue.record("missing read"); return }
        try target.send(.agentResponse(agentID: agents[1].id, requestID: token, result: .init(text: String(repeating: "x", count: 65537))))
        #expect(try caller.readReply() == .agentResult(id: 2, result: .init(text: "agent response exceeds 64 KiB", code: "reply_too_large")))
        try caller.send(.coordinateAgent(id: 3, agentID: agents[0].id, targetAgentID: agents[1].id, request: .init(operation: .status)))
        _ = try target.readReply()
        #expect(try caller.readReply() == .agentResult(id: 3, result: .init(text: "agent request timed out", code: "timeout")))
    }
}
