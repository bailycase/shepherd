import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Access checks remain on the server, but calls never wait for approval UI.
@Suite("Agent approvals", .integrationTimeLimit)
struct AgentApprovalTests {
    enum Call: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case send, spawn, read, steer, interrupt, delete
        var testDescription: String { rawValue }
    }

    final class Scene: @unchecked Sendable {
        let h: ScratchServer
        let lead: Agent
        let worker: Agent
        let leadClient: ExtensionClient
        let workerClient: ExtensionClient
        let prompts = Locked<[AgentApprovalPrompt]>([])
        let done = Locked<[AgentPeerRequest]>([])

        init(_ h: ScratchServer, lead: Agent, worker: Agent, leadClient: ExtensionClient, workerClient: ExtensionClient) {
            self.h = h
            self.lead = lead
            self.worker = worker
            self.leadClient = leadClient
            self.workerClient = workerClient
            h.server.onAgentApprovalRequest = { [prompts] prompt in prompts.withValue { $0.append(prompt) } }
            h.server.onAgentPeerRequest = { [done] request, respond in
                done.withValue { $0.append(request) }
                respond(.ok)
            }
        }

        func message(_ call: Call, id: Int) -> ExtensionMessage {
            switch call {
            case .send: return .sendToAgent(id: id, agentID: lead.id, targetAgentID: worker.id, text: "run the tests")
            case .spawn: return .spawnAgent(id: id, agentID: lead.id, cwd: h.dir.path, prompt: "fix the build")
            case .read: return .coordinateAgent(id: id, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .read))
            case .steer: return .coordinateAgent(id: id, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .steer, text: "use the new API"))
            case .interrupt: return .coordinateAgent(id: id, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .interrupt))
            case .delete: return .coordinateAgent(id: id, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .delete))
            }
        }

        func complete(_ call: Call, id: Int) async throws {
            switch call {
            case .send, .spawn:
                #expect(try await leadClient.reply() == .ok(id: id))
            case .delete:
                #expect(try await leadClient.reply() == .agentResult(id: id, result: .init(
                    text: "deleted agent \(worker.id); process termination requested; worktree and branch kept")))
            case .read, .steer, .interrupt:
                guard case .agentRequest(0, let token, worker.id, let request) = try await workerClient.reply() else {
                    Issue.record("the call never reached the worker")
                    return
                }
                if call == .steer { #expect(request.text == AgentMessageFraming.framed(from: "lead", "use the new API")) }
                try workerClient.send(.agentResponse(agentID: worker.id, requestID: token, result: .init(text: "done")))
                #expect(try await leadClient.reply() == .agentResult(id: id, result: .init(text: "done")))
            }
        }
    }

    private func scene(policy: AgentMessagePolicy? = nil, automation: Bool = false) async throws -> Scene {
        let h = try ScratchServer.fresh()
        if let policy { h.server.setAgentMessagePolicy(policy) }
        let space = Fixture.space("access", path: h.dir.path)
        let lead = Fixture.agent(in: space, name: "lead")
        let worker = Fixture.agent(in: space, name: "worker")
        var state = Fixture.workspace([lead, worker], space: space)
        if automation {
            var watch = Automation(name: "watch", prompt: "watch the build", cwd: space.path, enabled: true)
            watch.agentID = lead.agent.id
            state.automations = [watch]
        }
        try await h.seed(state)
        let leadClient = try ExtensionClient(path: h.socketPath)
        let workerClient = try ExtensionClient(path: h.socketPath)
        for (client, agent) in [(leadClient, lead.agent), (workerClient, worker.agent)] {
            try client.send(.helloAgent(agentID: agent.id))
            try client.send(.coordinateAgent(id: 0, agentID: agent.id, targetAgentID: agent.id, request: .init(operation: .status)))
            guard case .error(0, "self_control", _) = try await client.reply() else { throw WireError("registration barrier was not refused") }
        }
        return Scene(h, lead: lead.agent, worker: worker.agent, leadClient: leadClient, workerClient: workerClient)
    }

    @Test(arguments: Call.allCases)
    func defaultPolicyPerformsEveryCallWithoutApproval(call: Call) async throws {
        let s = try await scene()
        defer { s.h.stop() }
        for id in 1...2 {
            try s.leadClient.send(s.message(call, id: id))
            try await s.complete(call, id: id)
        }
        #expect(s.prompts.current.isEmpty)
        #expect(await !s.h.server.resolveAgentApproval("stale-token", .allowOnce))
    }

    @Test(arguments: Call.allCases)
    func noApprovalHandlerIsNeeded(call: Call) async throws {
        let s = try await scene()
        defer { s.h.stop() }
        s.h.server.onAgentApprovalRequest = nil
        try s.leadClient.send(s.message(call, id: 1))
        try await s.complete(call, id: 1)
    }

    @Test(arguments: Call.allCases)
    func neverStillRefusesEveryCall(call: Call) async throws {
        let s = try await scene(policy: .never)
        defer { s.h.stop() }
        try s.leadClient.send(s.message(call, id: 1))
        let reply = try await s.leadClient.reply()
        switch call {
        case .send, .spawn:
            #expect(reply == .error(id: 1, code: "not_allowed", message: AgentMessageGate.offMessage))
        default:
            #expect(reply == .agentResult(id: 1, result: .init(text: AgentMessageGate.offMessage, code: "not_allowed")))
        }
        #expect(s.prompts.current.isEmpty && s.done.current.isEmpty)
    }

    @Test(arguments: Call.allCases)
    func automationNeedsAlwaysAllowWithoutOpeningADialog(call: Call) async throws {
        let s = try await scene(automation: true)
        defer { s.h.stop() }
        try s.leadClient.send(s.message(call, id: 1))
        let reply = try await s.leadClient.reply()
        switch call {
        case .send, .spawn:
            #expect(reply == .error(id: 1, code: "not_allowed", message: AgentMessageGate.unattendedMessage))
        default:
            #expect(reply == .agentResult(id: 1, result: .init(text: AgentMessageGate.unattendedMessage, code: "not_allowed")))
        }
        #expect(s.prompts.current.isEmpty && s.done.current.isEmpty)
        s.h.server.setAgentMessagePolicy(.always)
        try s.leadClient.send(s.message(call, id: 2))
        try await s.complete(call, id: 2)
    }

    @Test func removingApprovalDoesNotBypassValidation() async throws {
        let s = try await scene()
        defer { s.h.stop() }
        try s.leadClient.send(.sendToAgent(id: 1, agentID: s.lead.id, targetAgentID: AgentID(), text: "hi"))
        guard case .error(1, "no_such_agent", _) = try await s.leadClient.reply() else { Issue.record("unknown target accepted"); return }
        try s.leadClient.send(.spawnAgent(id: 2, agentID: s.lead.id, cwd: "/no/such/directory", prompt: "go"))
        guard case .error(2, "no_such_directory", _) = try await s.leadClient.reply() else { Issue.record("missing folder accepted"); return }
        try s.leadClient.send(.coordinateAgent(id: 3, agentID: s.lead.id, targetAgentID: s.lead.id, request: .init(operation: .delete)))
        guard case .error(3, "self_control", _) = try await s.leadClient.reply() else { Issue.record("self deletion accepted"); return }
        try s.leadClient.send(.coordinateAgent(id: 4, agentID: s.lead.id, targetAgentID: s.worker.id, request: .init(operation: .steer, text: " ")))
        guard case .error(4, "invalid", _) = try await s.leadClient.reply() else { Issue.record("empty steer accepted"); return }
        #expect(s.prompts.current.isEmpty && s.done.current.isEmpty)
    }

    @Test func cancellingAnUnclaimedDeletionStillRevokesItsToken() async throws {
        let s = try await scene()
        defer { s.h.stop() }
        let token = Locked<String?>(nil)
        s.h.server.onAgentPeerRequest = { request, _ in
            if case .delete(_, _, let id) = request { token.withValue { $0 = id } }
        }
        try s.leadClient.send(s.message(.delete, id: 1))
        try await eventually("deletion to reach the app") { token.current != nil }
        try s.leadClient.send(.cancelAgentRequest(id: 1, agentID: s.lead.id))
        #expect(try await s.leadClient.reply() == .agentResult(id: 1, result: .init(text: "request cancelled", code: "cancelled")))
        #expect(await !s.h.server.claimAgentDeletion(try #require(token.current)))
        #expect(s.h.server.state.agents.count == 2)
    }
}
