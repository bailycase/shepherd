import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Live agent coordination over the extension socket (`agent_read`, `agent_steer`,
/// `agent_interrupt`, `agent_wait`, `agent_delete`): the server relays each request to the
/// target's registered panes connection under its own token and correlates the answer back to
/// the caller's id. Deletion never reaches the target; it waits for the app's confirmation.
@Suite("Agent coordination", .integrationTimeLimit)
struct AgentCoordinationTests {
    /// Two agents in one space, "lead" and "worker", each with its own layout.
    private func pair(_ h: ScratchServer) async throws -> (lead: Agent, worker: Agent) {
        let space = Fixture.space()
        let lead = Fixture.agent(in: space, name: "lead")
        let worker = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([lead, worker], space: space))
        return (lead.agent, worker.agent)
    }

    /// Registers `client` as `agentID`'s panes connection. Connections are served
    /// independently, so a self-directed status request (always refused) is the barrier that
    /// proves the registration landed before another connection relies on it.
    private func register(_ client: ExtensionClient, as agentID: AgentID) async throws {
        try client.send(.helloAgent(agentID: agentID))
        try client.send(.coordinateAgent(id: 0, agentID: agentID, targetAgentID: agentID, request: .init(operation: .status)))
        guard case .error(0, "self_control", _) = try await client.reply() else {
            Issue.record("the registration barrier was not refused")
            return
        }
    }

    @Test func aLiveRequestReachesOnlyTheTargetAndOnlyTheTargetsAnswerCounts() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        let impostor = try ExtensionClient(path: h.socketPath)
        try await register(caller, as: lead.id)
        try await register(target, as: worker.id)

        try caller.send(.coordinateAgent(id: 7, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .steer, text: "new plan")))
        guard case .agentRequest(0, let token, worker.id, let forwarded) = try await target.reply() else {
            Issue.record("the target never received the relayed request")
            return
        }
        #expect(UUID(uuidString: token) != nil, "the server issues its own token, never the caller's id")
        #expect(forwarded == .init(operation: .steer, text: "[from: lead] new plan"))

        try impostor.send(.helloAgent(agentID: worker.id))
        try impostor.send(.agentResponse(agentID: worker.id, requestID: token, result: .init(text: "forged")))
        try target.send(.agentResponse(agentID: lead.id, requestID: token, result: .init(text: "wrong identity")))
        try target.send(.agentResponse(agentID: worker.id, requestID: token, result: .init(text: "dispatch requested")))
        #expect(try await caller.reply() == .agentResult(id: 7, result: .init(text: "dispatch requested")))
    }

    @Test(arguments: [AgentCoordinationRequest.Operation.steer, .interrupt, .status, .delete])
    func anAgentCannotControlWaitForOrDeleteItself(_ operation: AgentCoordinationRequest.Operation) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, _) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        try caller.send(.coordinateAgent(id: 3, agentID: lead.id, targetAgentID: lead.id, request: .init(operation: operation, text: "x")))

        guard case .error(3, "self_control", _) = try await caller.reply() else { Issue.record("self \(operation) allowed"); return }
        #expect(h.server.state.agents.count == 2)
    }

    @Test func anAgentMayReadItsOwnThread() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, _) = try await pair(h)
        let client = try ExtensionClient(path: h.socketPath)
        try await register(client, as: lead.id)

        try client.send(.coordinateAgent(id: 4, agentID: lead.id, targetAgentID: lead.id, request: .init(operation: .read)))

        guard case .agentRequest(0, _, lead.id, let request) = try await client.reply() else {
            Issue.record("a self read was not relayed")
            return
        }
        #expect(request.operation == .read)
    }

    /// Only a registered sender may coordinate, and only with an agent that exists.
    @Test func anUnregisteredSenderOrAnUnknownTargetIsRejected() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let unregistered = try ExtensionClient(path: h.socketPath)
        try unregistered.send(.coordinateAgent(id: 1, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
        guard case .error(1, "no_such_agent", _) = try await unregistered.reply() else { Issue.record("unregistered sender served"); return }

        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))
        try caller.send(.coordinateAgent(id: 2, agentID: lead.id, targetAgentID: AgentID(), request: .init(operation: .status)))
        guard case .error(2, "no_such_agent", _) = try await caller.reply() else { Issue.record("unknown target served"); return }
    }

    @Test(arguments: ["", "  \n", String(repeating: "x", count: 32 * 1024 + 1)])
    func steeringTextMustHoldOneTo32KiB(_ text: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        try caller.send(.coordinateAgent(id: 5, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .steer, text: text)))

        guard case .error(5, "invalid", _) = try await caller.reply() else { Issue.record("steer of \(text.utf8.count) bytes allowed"); return }
    }

    /// A duplicate id would make the answer ambiguous; more than 16 in flight is refused.
    @Test func aDuplicateIDOrTooManyPendingRequestsIsBusy() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        try await register(caller, as: lead.id)
        try await register(target, as: worker.id)

        func relay(_ id: Int) async throws -> Bool {
            try caller.send(.coordinateAgent(id: id, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
            if case .agentRequest = try await target.reply() { return true }
            return false
        }
        for id in 1...15 { #expect(try await relay(id)) }
        try caller.send(.coordinateAgent(id: 15, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
        guard case .error(15, "busy", _) = try await caller.reply() else { Issue.record("a duplicate id was relayed"); return }
        #expect(try await relay(16))
        try caller.send(.coordinateAgent(id: 17, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
        guard case .error(17, "busy", _) = try await caller.reply() else { Issue.record("a 17th pending request was relayed"); return }
    }

    @Test func cancellingARequestAnswersTheCallerAndIgnoresTheLateResponse() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        try await register(caller, as: lead.id)
        try await register(target, as: worker.id)
        try caller.send(.coordinateAgent(id: 8, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .read)))
        guard case .agentRequest(_, let token, _, _) = try await target.reply() else { Issue.record("missing read"); return }

        try caller.send(.cancelAgentRequest(id: 8, agentID: lead.id))
        #expect(try await caller.reply() == .agentResult(id: 8, result: .init(text: "request cancelled", code: "cancelled")))

        try target.send(.agentResponse(agentID: worker.id, requestID: token, result: .init(text: "late")))
        try caller.send(.coordinateAgent(id: 9, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
        guard case .agentRequest(_, let next, _, _) = try await target.reply() else { Issue.record("missing status"); return }
        try target.send(.agentResponse(agentID: worker.id, requestID: next, result: .init(text: "live", idle: true)))
        #expect(try await caller.reply() == .agentResult(id: 9, result: .init(text: "live", idle: true)),
                "the late answer to the cancelled read never reaches the caller")
    }

    @Test func aTargetThatDisconnectsFailsWhatItOwedAndIsNotRunningAfterward() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        try await register(caller, as: lead.id)
        try await register(target, as: worker.id)
        try caller.send(.coordinateAgent(id: 9, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .interrupt)))
        guard case .agentRequest = try await target.reply() else { Issue.record("missing interrupt"); return }

        target.closeConnection()

        #expect(try await caller.reply() == .agentResult(id: 9, result: .init(text: "agent connection closed", code: "disconnected")))
        try caller.send(.coordinateAgent(id: 10, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
        guard case .error(10, "not_running", _) = try await caller.reply() else { Issue.record("a disconnected target was served"); return }
    }

    @Test func anOversizedResponseAndASilentTargetBecomeCorrelatedFailures() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        let target = try ExtensionClient(path: h.socketPath)
        try await register(caller, as: lead.id)
        try await register(target, as: worker.id)

        try caller.send(.coordinateAgent(id: 2, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .read)))
        guard case .agentRequest(_, let token, _, _) = try await target.reply() else { Issue.record("missing read"); return }
        try target.send(.agentResponse(agentID: worker.id, requestID: token, result: .init(text: String(repeating: "x", count: 64 * 1024 + 1))))
        #expect(try await caller.reply() == .agentResult(id: 2, result: .init(text: "agent response exceeds 64 KiB", code: "reply_too_large")))

        // Live requests time out after five seconds.
        try caller.send(.coordinateAgent(id: 3, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
        guard case .agentRequest = try await target.reply() else { Issue.record("missing status"); return }
        #expect(try await caller.reply(timeout: .seconds(20)) == .agentResult(id: 3, result: .init(text: "agent request timed out", code: "timeout")))
    }

    // MARK: - Deletion

    /// A headless server has nobody to ask, so nothing is deleted.
    @Test func aDeletionWithoutTheAppIsUnsupportedAndDeletesNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        try caller.send(.coordinateAgent(id: 12, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete)))

        #expect(try await caller.reply() == .agentResult(id: 12, result: .init(text: "native confirmation unavailable", code: "unsupported")))
        #expect(h.server.state.agents.map(\.id) == [lead.id, worker.id])
    }

    /// Deletion goes to the app (never the target's extension) under a token only a confirmed
    /// dialog can claim, once; the app's outcome answers the caller.
    @Test func aDeletionAsksTheAppAndItsOutcomeAnswersTheCaller() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let asked = Locked<[(request: AgentPeerRequest, respond: (AgentPeerOutcome) -> Void)]>([])
        h.server.onAgentPeerRequest = { request, respond in asked.withValue { $0.append((request, respond)) } }
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        try caller.send(.coordinateAgent(id: 13, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete)))

        try await eventually("the app to be asked") { asked.current.count == 1 }
        let pending = try #require(asked.current.first)
        guard case .delete(lead.id, worker.id, let token) = pending.request else { Issue.record("unexpected \(pending.request)"); return }
        #expect(await h.server.claimAgentDeletion(token))
        #expect(await !h.server.claimAgentDeletion(token), "a confirmation is claimed once")
        pending.respond(.ok)
        guard case .agentResult(13, let result) = try await caller.reply() else { Issue.record("missing deletion result"); return }
        #expect(result.code == nil && result.text.contains("worktree and branch kept"))
    }

    /// Cancel, a disconnect, or a failed deletion reach the app as a lapsed token: the dialog
    /// closes and a late confirmation can no longer delete.
    @Test func aCancelledDeletionLapsesItsTokenAndClosesTheDialog() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (lead, worker) = try await pair(h)
        let asked = Locked<[AgentPeerRequest]>([])
        let lapsed = Locked<[String]>([])
        h.server.onAgentPeerRequest = { request, _ in asked.withValue { $0.append(request) } }
        h.server.onAgentPeerCancellation = { token in lapsed.withValue { $0.append(token) } }
        let caller = try ExtensionClient(path: h.socketPath)
        try caller.send(.helloAgent(agentID: lead.id))

        try caller.send(.coordinateAgent(id: 14, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete)))
        try await eventually("the app to be asked") { asked.current.count == 1 }
        guard case .delete(_, _, let token) = try #require(asked.current.first) else { Issue.record("not a deletion"); return }
        try caller.send(.cancelAgentRequest(id: 14, agentID: lead.id))

        #expect(try await caller.reply() == .agentResult(id: 14, result: .init(text: "request cancelled", code: "cancelled")))
        try await eventually("the dialog to be told") { lapsed.current == [token] }
        #expect(await !h.server.claimAgentDeletion(token))

        try caller.send(.coordinateAgent(id: 15, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete)))
        try await eventually("the app to be asked again") { asked.current.count == 2 }
        guard case .delete(_, _, let second) = asked.current[1] else { Issue.record("not a deletion"); return }
        caller.closeConnection()
        try await eventually("the dialog to be told of the disconnect") { lapsed.current == [token, second] }
        #expect(await !h.server.claimAgentDeletion(second))
    }
}
