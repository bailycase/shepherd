import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

@Suite("Local native thread", .serialized)
struct LocalNativeThreadTests {
    private struct Harness {
        let dir: URL
        let server: SessionServer
        let agent: Agent
        let sessionID: SessionID

        init() async throws {
            dir = try makeScratchDirectory()
            server = SessionServer(socketPath: dir.appendingPathComponent("n.sock").path,
                                   stateURL: dir.appendingPathComponent("state.json"))
            try server.start()
            let space = Space(name: "native", path: dir.path)
            let session = try await server.createSession(params: .init(cwd: dir.path, command: ["/bin/cat"], cols: 80, rows: 24))
            sessionID = session.id
            let pane = LeafPane(sessionID: session.id, cwd: dir.path)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            agent = Agent(name: "native", spaceID: space.id, tabID: tab.id, paneID: pane.id)
            try await server.addSpace(space)
            try await server.addAgent(agent, withTab: tab)
        }

        func bridge() throws -> ExtensionClient {
            let client = try ExtensionClient(path: dir.appendingPathComponent("n.sock").path)
            try client.send(.helloNativeAgent(agentID: agent.id))
            // Same-connection barrier makes registration observable without sleeps.
            try client.send(.listPanes(id: 900, agentID: agent.id))
            _ = try client.readReply()
            return client
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func localDispatchUsesDedicatedBridgeAndPiSessionBindingWithoutTCPOrPTYInput() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        do {
            _ = try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot())
            Issue.record("Missing bridge accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "native_unavailable") }
        let bridge = try h.bridge()
        let peers = try ExtensionClient(path: h.dir.appendingPathComponent("n.sock").path)
        try peers.send(.helloAgent(agentID: h.agent.id))
        try peers.send(.listPanes(id: 901, agentID: h.agent.id))
        _ = try peers.readReply()
        #expect(h.server.pushMessage(toAgent: h.agent.id, text: "peer channel intact"))
        #expect(try peers.readReply() == .message(id: 0, text: "peer channel intact"))

        let result = NativeThreadResult.unchanged(piSessionID: "pi-current-session", generation: "current-generation", revision: 1)
        let snapshot = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        guard case .nativeThreadCommand(let id, .snapshot) = try bridge.readReply() else {
            Issue.record("Missing local snapshot command"); return
        }
        try peers.send(.nativeThreadResult(id: id, result: .failure(code: "spoof", message: "wrong peer")))
        try peers.send(.listPanes(id: 902, agentID: h.agent.id))
        _ = try peers.readReply()
        try bridge.send(.nativeThreadResult(id: id + 1000, result: .failure(code: "wrong_id", message: "wrong correlation")))
        try bridge.send(.nativeThreadResult(id: id, result: result))
        #expect(try await snapshot.value == result)
        // A duplicate reply cannot settle another request or resume a continuation twice.
        try bridge.send(.nativeThreadResult(id: id, result: result))

        for binding in ["stale-session", "pi-current-session"] {
            let operation = UUID()
            let request = NativeThreadRequest.send(expectedSessionID: binding, generation: "current-generation",
                                                   operationID: operation, text: "Native-only prompt", delivery: .steer)
            let pending = Task { try await h.server.nativeThread(agentID: h.agent.id, request: request) }
            guard case .nativeThreadCommand(let actionID, let forwarded) = try bridge.readReply() else {
                Issue.record("Missing local action"); return
            }
            #expect(forwarded == request)
            // The bridge owns current pi session checks, not the persisted agent ID.
            let outcome: NativeThreadResult = binding == "stale-session"
                ? .failure(code: "stale_session", message: "Refresh") : .accepted(operationID: operation)
            try bridge.send(.nativeThreadResult(id: actionID, result: outcome))
            #expect(try await pending.value == outcome)
        }
        do {
            _ = try await h.server.nativeThread(agentID: h.agent.id, request: .send(
                expectedSessionID: "s", generation: "g", operationID: UUID(),
                text: String(repeating: "😀", count: 16 * 1024), delivery: .followUp))
            Issue.record("Oversize local request accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "native_limit") }
        let oversized = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        guard case .nativeThreadCommand(let largeID, _) = try bridge.readReply() else {
            Issue.record("Missing result-limit command"); return
        }
        try bridge.send(.nativeThreadResult(id: largeID, result: .failure(code: "large", message: String(repeating: "x", count: 256 * 1024))))
        do {
            _ = try await oversized.value
            Issue.record("Oversize local result accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "native_limit") }
        #expect(await h.server.screenText(sessionID: h.sessionID)?.joined().contains("Native-only prompt") == false)
        h.server.killSession(h.sessionID)
        let deadline = ContinuousClock.now + .seconds(10)
        while await h.server.sessionInfo(sessionID: h.sessionID)?.isAlive == true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        do {
            _ = try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot())
            Issue.record("Dead PTY accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "native_unavailable") }
    }

    @Test func localPendingSettlesOnReplacementDisconnectTimeoutAndShutdown() async throws {
        let h = try await Harness()
        defer { h.tearDown() }
        let bridge = try h.bridge()
        let replaced = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        _ = try bridge.readReply()
        let replacement = try h.bridge()
        #expect(try bridge.waitForDisconnect())
        do {
            _ = try await replaced.value
            Issue.record("Replacement did not settle local request")
        } catch RemoteHostClientError.outcomeUnknown { }

        let disconnected = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        _ = try replacement.readReply()
        replacement.closeConnection()
        do {
            _ = try await disconnected.value
            Issue.record("Disconnect did not settle local request")
        } catch RemoteHostClientError.outcomeUnknown { }

        let current = try h.bridge()
        let timedOut = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        guard case .nativeThreadCommand(let expiredID, _) = try current.readReply() else {
            Issue.record("Missing timeout command"); return
        }
        do {
            _ = try await timedOut.value
            Issue.record("Local request did not time out")
        } catch RemoteHostClientError.outcomeUnknown(let message) { #expect(message.contains("timed out")) }
        try current.send(.nativeThreadResult(id: expiredID, result: .failure(code: "late", message: "expired")))

        // Cancellation, like TCP, abandons observation rather than undoing dispatch.
        let cancelled = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        guard case .nativeThreadCommand(let cancelledID, _) = try current.readReply() else {
            Issue.record("Missing cancellation command"); return
        }
        cancelled.cancel()
        let result = NativeThreadResult.unchanged(piSessionID: "s", generation: "g", revision: 2)
        try current.send(.nativeThreadResult(id: cancelledID, result: result))
        #expect(try await cancelled.value == result)

        let stopped = Task { try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot()) }
        _ = try current.readReply()
        h.server.stop()
        do {
            _ = try await stopped.value
            Issue.record("Shutdown left local request pending")
        } catch RemoteHostClientError.outcomeUnknown { }
        do {
            _ = try await h.server.nativeThread(agentID: h.agent.id, request: .snapshot())
            Issue.record("Stopped server accepted request")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == "native_unavailable") }
    }
}
