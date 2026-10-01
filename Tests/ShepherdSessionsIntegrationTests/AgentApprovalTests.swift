import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Pi ▸ Agent-to-agent messages, enforced by the server: what an agent asks to do to
/// another thread (message, steer, interrupt, read, start one) waits for the user's answer, is
/// refused outright, or goes through, whatever its extension says. The app is a recorder here: it
/// is asked (`onAgentApprovalRequest`), and it answers with `resolveAgentApproval`.
@Suite("Agent approvals", .integrationTimeLimit)
struct AgentApprovalTests {
    /// The gated calls, each as the extension sends it.
    enum Call: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case send, spawn, read, steer, interrupt
        var testDescription: String { rawValue }
    }

    /// A lead and a worker, each with a panes connection, and everything the app was told.
    final class Scene: @unchecked Sendable {
        let h: ScratchServer
        let lead: Agent
        let worker: Agent
        /// A third thread no pi has connected for.
        let ghost: Agent
        let leadClient: ExtensionClient
        let workerClient: ExtensionClient
        /// The dialogs the app was asked to open.
        let prompts = Locked<[AgentApprovalPrompt]>([])
        /// The tokens whose dialogs the app was told to close.
        let lapsed = Locked<[String]>([])
        /// What reached the app's own handler: the sends and spawns that were done.
        let done = Locked<[AgentPeerRequest]>([])

        init(_ h: ScratchServer, lead: Agent, worker: Agent, ghost: Agent, leadClient: ExtensionClient, workerClient: ExtensionClient) {
            self.h = h
            self.lead = lead
            self.worker = worker
            self.ghost = ghost
            self.leadClient = leadClient
            self.workerClient = workerClient
            h.server.onAgentApprovalRequest = { [prompts] prompt in prompts.withValue { $0.append(prompt) } }
            h.server.onAgentPeerCancellation = { [lapsed] token in lapsed.withValue { $0.append(token) } }
            h.server.onAgentPeerRequest = { [done] request, respond in
                done.withValue { $0.append(request) }
                respond(.ok)
            }
        }

        func stop() { h.stop() }

        /// The message an agent sends for `call`, naming `target`.
        func message(_ call: Call, id: Int, from sender: Agent? = nil, to target: Agent? = nil) -> ExtensionMessage {
            let from = (sender ?? lead).id, to = (target ?? worker).id
            switch call {
            case .send: return .sendToAgent(id: id, agentID: from, targetAgentID: to, text: "run the tests")
            case .spawn: return .spawnAgent(id: id, agentID: from, cwd: h.dir.path, prompt: "fix the build")
            case .read: return .coordinateAgent(id: id, agentID: from, targetAgentID: to, request: .init(operation: .read))
            case .steer: return .coordinateAgent(id: id, agentID: from, targetAgentID: to, request: .init(operation: .steer, text: "use the new API"))
            case .interrupt: return .coordinateAgent(id: id, agentID: from, targetAgentID: to, request: .init(operation: .interrupt))
            }
        }

        /// The action a prompt for `call` shows.
        func action(_ call: Call) -> AgentGatedAction {
            switch call {
            case .send: return .send(targetAgentID: worker.id, text: "run the tests", delivery: .task)
            case .spawn: return .spawn(cwd: h.dir.path, prompt: "fix the build")
            case .read: return .read(targetAgentID: worker.id)
            case .steer: return .steer(targetAgentID: worker.id, text: "use the new API")
            case .interrupt: return .interrupt(targetAgentID: worker.id)
            }
        }

        func asked(_ count: Int = 1) async throws -> [AgentApprovalPrompt] {
            try await eventually("the app to be asked \(count) time\(count == 1 ? "" : "s")") { prompts.current.count >= count }
            return prompts.current
        }

        /// Whatever the app's main queue was handed before now has run.
        func settleMain() async {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }

        /// The calls that reach the worker's own connection come in order, so once a status poll is
        /// the first thing it is handed, no earlier call was done after all. The poll is answered.
        func workerHasBeenHandedNothingBefore(_ barrier: Int) async throws {
            try leadClient.send(.coordinateAgent(id: barrier, agentID: lead.id, targetAgentID: worker.id, request: .init(operation: .status)))
            guard case .agentRequest(_, let token, _, let request) = try await workerClient.reply() else {
                Issue.record("the worker's connection was handed something other than the status poll")
                return
            }
            #expect(request.operation == .status, "the call was never relayed to the worker")
            try workerClient.send(.agentResponse(agentID: worker.id, requestID: token, result: .init(text: "live", idle: true)))
            #expect(try await leadClient.reply() == .agentResult(id: barrier, result: .init(text: "live", idle: true)))
        }
    }

    private func scene(policy: AgentMessagePolicy? = nil, leadRunsAnAutomation: Bool = false) async throws -> Scene {
        let h = try ScratchServer.fresh()
        if let policy { h.server.setAgentMessagePolicy(policy) }
        let space = Fixture.space("approvals", path: h.dir.path)
        let lead = Fixture.agent(in: space, name: "lead")
        let worker = Fixture.agent(in: space, name: "worker")
        let ghost = Fixture.agent(in: space, name: "ghost")
        var state = Fixture.workspace([lead, worker, ghost], space: space)
        if leadRunsAnAutomation {
            var automation = Automation(name: "watch", prompt: "watch the build", cwd: space.path, enabled: true)
            automation.agentID = lead.agent.id
            state.automations = [automation]
        }
        try await h.seed(state)
        let leadClient = try ExtensionClient(path: h.socketPath)
        let workerClient = try ExtensionClient(path: h.socketPath)
        // Connections are served independently: a self-directed status request (always refused) is
        // the barrier that proves each registration landed before another connection relies on it.
        for (client, agent) in [(leadClient, lead.agent), (workerClient, worker.agent)] {
            try client.send(.helloAgent(agentID: agent.id))
            try client.send(.coordinateAgent(id: 0, agentID: agent.id, targetAgentID: agent.id, request: .init(operation: .status)))
            guard case .error(0, "self_control", _) = try await client.reply() else { throw WireError("the registration barrier was not refused") }
        }
        return Scene(h, lead: lead.agent, worker: worker.agent, ghost: ghost.agent, leadClient: leadClient, workerClient: workerClient)
    }

    // MARK: - Ask

    /// Until the app says otherwise the server asks, and nothing is done while the dialog is up.
    @Test func theServerAsksByDefaultAndDoesNothingUntilTheUserAllows() async throws {
        let s = try await scene()
        defer { s.stop() }

        try s.leadClient.send(s.message(.send, id: 1))
        let prompt = try #require(try await s.asked().first)

        #expect(prompt.senderID == s.lead.id)
        #expect(prompt.action == .send(targetAgentID: s.worker.id, text: "run the tests", delivery: .task))
        await s.settleMain()
        #expect(s.done.current.isEmpty, "waiting for the user")
        #expect(await s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce))
        #expect(try await s.leadClient.reply() == .ok(id: 1))
        #expect(s.done.current == [.send(agentID: s.lead.id, targetAgentID: s.worker.id, text: "run the tests", delivery: .task)])
    }

    /// Allow once does the call once: a repeated or late answer, or the same call again, is another dialog.
    @Test func allowingOnceDoesTheCallOnceAndTheNextCallAsksAgain() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.send, id: 1))
        let first = try #require(try await s.asked().first)

        #expect(await s.h.server.resolveAgentApproval(first.requestID, .allowOnce))
        #expect(await !s.h.server.resolveAgentApproval(first.requestID, .allowOnce), "the token is claimed once")
        #expect(await !s.h.server.resolveAgentApproval(first.requestID, .allowForThread))
        #expect(try await s.leadClient.reply() == .ok(id: 1))
        try s.leadClient.send(s.message(.send, id: 2))
        let second = try await s.asked(2)[1]

        #expect(second.requestID != first.requestID)
        #expect(s.done.current.count == 1, "the second call waits")
    }

    /// An approved steer, read or interrupt reaches the target's own connection once, steering under
    /// the header that says an agent wrote it.
    @Test(arguments: [Call.read, .steer, .interrupt])
    func anApprovedLiveRequestIsRelayedToTheTargetOnce(call: Call) async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(call, id: 1))
        let prompt = try #require(try await s.asked().first)
        #expect(prompt.action == s.action(call))

        #expect(await s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce))

        guard case .agentRequest(0, let token, s.worker.id, let request) = try await s.workerClient.reply() else {
            Issue.record("the approved \(call) never reached the worker")
            return
        }
        if call == .steer { #expect(request.text == AgentMessageFraming.framed(from: "lead", "use the new API")) }
        try s.workerClient.send(.agentResponse(agentID: s.worker.id, requestID: token, result: .init(text: "done")))
        #expect(try await s.leadClient.reply() == .agentResult(id: 1, result: .init(text: "done")))
        #expect(await !s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce))
    }

    // MARK: - Refusals: deny, time out, cancel, disconnect

    /// Deny answers the caller with the message the model reads, and does nothing: for every gated call.
    @Test(arguments: Call.allCases)
    func denyingAnswersTheCallerAndDoesNothing(call: Call) async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(call, id: 1))
        let prompt = try #require(try await s.asked().first)

        #expect(await s.h.server.resolveAgentApproval(prompt.requestID, .deny))

        let reply = try await s.leadClient.reply()
        switch call {
        case .send, .spawn:
            #expect(reply == .error(id: 1, code: "not_approved", message: AgentMessageGate.deniedMessage))
        case .read, .steer, .interrupt:
            #expect(reply == .agentResult(id: 1, result: .init(text: AgentMessageGate.deniedMessage, code: "not_approved")))
        }
        #expect(AgentMessageGate.deniedMessage == "The user did not approve. Don't message other agents unless the user asks you to.")
        await s.settleMain()
        #expect(s.done.current.isEmpty)
        #expect(await !s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce), "an allow after the deny does nothing")
        try await s.workerHasBeenHandedNothingBefore(50)
    }

    /// No answer in time refuses the call and closes the dialog; a late Allow cannot do it.
    @Test(arguments: Call.allCases)
    func noAnswerInTimeRefusesTheCallAndClosesTheDialog(call: Call) async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        s.h.server.setAgentApprovalTimeout(0.2)
        try s.leadClient.send(s.message(call, id: 1))
        let prompt = try #require(try await s.asked().first)

        let reply = try await s.leadClient.reply()

        switch call {
        case .send, .spawn:
            #expect(reply == .error(id: 1, code: "not_approved", message: AgentMessageGate.timedOutMessage))
        case .read, .steer, .interrupt:
            #expect(reply == .agentResult(id: 1, result: .init(text: AgentMessageGate.timedOutMessage, code: "not_approved")))
        }
        try await eventually("the dialog to be told") { s.lapsed.current == [prompt.requestID] }
        #expect(await !s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce))
        await s.settleMain()
        #expect(s.done.current.isEmpty)
        try await s.workerHasBeenHandedNothingBefore(51)
    }

    /// The caller giving up (Stop cancels the tool call) closes the dialog and the call is never done.
    @Test(arguments: Call.allCases)
    func aCancelledCallClosesItsDialogAndIsNeverDone(call: Call) async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(call, id: 1))
        let prompt = try #require(try await s.asked().first)

        try s.leadClient.send(.cancelAgentRequest(id: 1, agentID: s.lead.id))

        let reply = try await s.leadClient.reply()
        switch call {
        case .send, .spawn: #expect(reply == .error(id: 1, code: "cancelled", message: "request cancelled"))
        case .read, .steer, .interrupt: #expect(reply == .agentResult(id: 1, result: .init(text: "request cancelled", code: "cancelled")))
        }
        try await eventually("the dialog to be told") { s.lapsed.current == [prompt.requestID] }
        #expect(await !s.h.server.resolveAgentApproval(prompt.requestID, .allowForThread))
        await s.settleMain()
        #expect(s.done.current.isEmpty)
        try await s.workerHasBeenHandedNothingBefore(52)
    }

    @Test func aCallerThatDisconnectsHasItsWaitingCallsDroppedAndNeverDone() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.send, id: 1))
        try s.leadClient.send(s.message(.steer, id: 2))
        let prompts = try await s.asked(2)

        s.leadClient.closeConnection()

        try await eventually("both dialogs to be told") { Set(s.lapsed.current) == Set(prompts.map(\.requestID)) }
        for prompt in prompts { #expect(await !s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce)) }
        await s.settleMain()
        #expect(s.done.current.isEmpty)
    }

    /// The setting turning to Never refuses what already waits, and its dialogs close.
    @Test func turningTheSettingToNeverRefusesWhatIsWaiting() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.send, id: 1))
        let prompt = try #require(try await s.asked().first)

        s.h.server.setAgentMessagePolicy(.never)

        #expect(try await s.leadClient.reply() == .error(id: 1, code: "not_allowed", message: AgentMessageGate.offMessage))
        try await eventually("the dialog to be told") { s.lapsed.current == [prompt.requestID] }
        #expect(await !s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce))
        await s.settleMain()
        #expect(s.done.current.isEmpty)
    }

    // MARK: - Allow for this thread

    /// Allow for this thread lets that agent's later calls through without a dialog, to any thread
    /// and for every gated call, and no other agent's.
    @Test func allowingForTheThreadSkipsTheDialogForThatAgentOnly() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.send, id: 1))
        let prompt = try #require(try await s.asked().first)
        #expect(await s.h.server.resolveAgentApproval(prompt.requestID, .allowForThread))
        #expect(try await s.leadClient.reply() == .ok(id: 1))

        try s.leadClient.send(s.message(.spawn, id: 2))
        #expect(try await s.leadClient.reply() == .ok(id: 2))
        try s.leadClient.send(s.message(.read, id: 3))
        guard case .agentRequest(0, let token, _, let request) = try await s.workerClient.reply() else { Issue.record("not relayed"); return }
        #expect(request.operation == .read)
        try s.workerClient.send(.agentResponse(agentID: s.worker.id, requestID: token, result: .init(text: "messages")))
        #expect(try await s.leadClient.reply() == .agentResult(id: 3, result: .init(text: "messages")))
        #expect(s.prompts.current.count == 1, "only the first call asked")

        // The worker was not allowed: it asks.
        try s.workerClient.send(s.message(.send, id: 4, from: s.worker, to: s.lead))
        let other = try await s.asked(2)[1]
        #expect(other.senderID == s.worker.id)
    }

    /// The same answer allows what the agent already has waiting, and closes those dialogs.
    @Test func allowingForTheThreadAlsoAllowsWhatTheSameAgentHasWaiting() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.send, id: 1))
        try s.leadClient.send(s.message(.spawn, id: 2))
        let waiting = try await s.asked(2)

        #expect(await s.h.server.resolveAgentApproval(waiting[0].requestID, .allowForThread))

        var replies: [ExtensionReply] = []
        for _ in 0..<2 { replies.append(try await s.leadClient.reply()) }
        #expect(Set(replies) == [.ok(id: 1), .ok(id: 2)])
        try await eventually("the second dialog to be told") { s.lapsed.current == [waiting[1].requestID] }
        #expect(await !s.h.server.resolveAgentApproval(waiting[1].requestID, .allowOnce))
        #expect(s.done.current.count == 2)
    }

    /// What was allowed is for as long as the pi that was running: a restarted pi (a new session
    /// bound to the agent's pane) asks again, and so does a new setting.
    @Test func whatWasAllowedForAThreadIsForgottenWhenItsPiRestartsOrTheSettingChanges() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let dir = try makeScratchDirectory("appr-restart")
        let space = Fixture.space("restart", path: dir.path)
        let lead = Fixture.agent(in: space, name: "lead")
        let worker = Fixture.agent(in: space, name: "worker")
        let ghost = Fixture.agent(in: space, name: "ghost")
        try await h.seed(Fixture.workspace([lead, worker, ghost], space: space))
        let s = Scene(h, lead: lead.agent, worker: worker.agent, ghost: ghost.agent,
                      leadClient: try ExtensionClient(path: h.socketPath), workerClient: try ExtensionClient(path: h.socketPath))
        let paneID = try #require(lead.agent.paneID)
        func launch() async throws -> SessionInfo {
            try await h.server.createSession(params: CreateSessionParams(cwd: dir.path, command: StubPi.command, runtime: .rpc))
        }
        let first = try await launch()
        let second = try await launch()
        try await h.server.updatePaneSession(tabID: lead.tab.id, paneID: paneID, sessionID: first.id)

        try s.leadClient.send(s.message(.send, id: 1))
        #expect(await h.server.resolveAgentApproval(try #require(try await s.asked().first).requestID, .allowForThread))
        #expect(try await s.leadClient.reply() == .ok(id: 1))
        try s.leadClient.send(s.message(.send, id: 2))
        #expect(try await s.leadClient.reply() == .ok(id: 2))
        #expect(s.prompts.current.count == 1, "allowed for the thread while its pi runs")

        try await h.server.updatePaneSession(tabID: lead.tab.id, paneID: paneID, sessionID: second.id)
        try s.leadClient.send(s.message(.send, id: 3))
        let again = try await s.asked(2)[1]
        #expect(await h.server.resolveAgentApproval(again.requestID, .allowForThread))
        #expect(try await s.leadClient.reply() == .ok(id: 3))

        h.server.setAgentMessagePolicy(.always)
        h.server.setAgentMessagePolicy(.ask)
        try s.leadClient.send(s.message(.send, id: 4))
        _ = try await s.asked(3)
        #expect(s.prompts.current.count == 3, "a new setting starts the allowances over")
    }

    // MARK: - Never, Always, and runs nobody watches

    /// Never refuses every gated call, and deleting, without opening a dialog.
    @Test(arguments: Call.allCases)
    func neverRefusesEveryGatedCallWithoutADialog(call: Call) async throws {
        let s = try await scene(policy: .never)
        defer { s.stop() }

        try s.leadClient.send(s.message(call, id: 1))

        let reply = try await s.leadClient.reply()
        switch call {
        case .send, .spawn: #expect(reply == .error(id: 1, code: "not_allowed", message: AgentMessageGate.offMessage))
        case .read, .steer, .interrupt: #expect(reply == .agentResult(id: 1, result: .init(text: AgentMessageGate.offMessage, code: "not_allowed")))
        }
        await s.settleMain()
        #expect(s.prompts.current.isEmpty && s.done.current.isEmpty)
        try await s.workerHasBeenHandedNothingBefore(53)
    }

    @Test func neverAlsoRefusesDeletingAnotherAgentAndAlwaysLeavesItsOwnDialog() async throws {
        let s = try await scene(policy: .never)
        defer { s.stop() }
        try s.leadClient.send(.coordinateAgent(id: 1, agentID: s.lead.id, targetAgentID: s.worker.id, request: .init(operation: .delete)))
        #expect(try await s.leadClient.reply() == .agentResult(id: 1, result: .init(text: AgentMessageGate.offMessage, code: "not_allowed")))
        await s.settleMain()
        #expect(s.done.current.isEmpty, "the Delete agent dialog was never asked")

        s.h.server.setAgentMessagePolicy(.always)
        try s.leadClient.send(.coordinateAgent(id: 2, agentID: s.lead.id, targetAgentID: s.worker.id, request: .init(operation: .delete)))
        try await eventually("the Delete agent dialog to be asked") {
            s.done.current.contains { if case .delete = $0 { true } else { false } }
        }
        #expect(s.prompts.current.isEmpty, "Always allow does not answer for the deletion dialog")
    }

    /// Always allow does what agents did before: every call goes through, with no dialog.
    @Test(arguments: [Call.send, .spawn])
    func alwaysAllowGoesStraightThrough(call: Call) async throws {
        let s = try await scene(policy: .always)
        defer { s.stop() }

        try s.leadClient.send(s.message(call, id: 1))

        #expect(try await s.leadClient.reply() == .ok(id: 1))
        #expect(s.prompts.current.isEmpty)
        #expect(s.done.current.count == 1)
    }

    /// A run nobody watches cannot be asked: under Ask it is refused, and only Always allow lets it through.
    @Test(arguments: [Call.send, .spawn, .steer])
    func anAutomationRunUnderAskIsRefusedAndUnderAlwaysIsAllowed(call: Call) async throws {
        let s = try await scene(policy: .ask, leadRunsAnAutomation: true)
        defer { s.stop() }

        try s.leadClient.send(s.message(call, id: 1))

        let reply = try await s.leadClient.reply()
        switch call {
        case .send, .spawn: #expect(reply == .error(id: 1, code: "not_allowed", message: AgentMessageGate.unattendedMessage))
        default: #expect(reply == .agentResult(id: 1, result: .init(text: AgentMessageGate.unattendedMessage, code: "not_allowed")))
        }
        await s.settleMain()
        #expect(s.prompts.current.isEmpty && s.done.current.isEmpty, "no dialog for an unattended run")

        s.h.server.setAgentMessagePolicy(.always)
        try s.leadClient.send(s.message(.send, id: 2))
        #expect(try await s.leadClient.reply() == .ok(id: 2))
    }

    // MARK: - What is never gated, and what is checked before anyone is asked

    @Test func listingWaitingAndReadingYourOwnThreadNeverAsk() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }

        try s.leadClient.send(.listAgents(id: 1, agentID: s.lead.id))
        #expect(try await s.leadClient.reply() == .ok(id: 1))
        try s.leadClient.send(.coordinateAgent(id: 2, agentID: s.lead.id, targetAgentID: s.worker.id, request: .init(operation: .status)))
        guard case .agentRequest(0, let token, _, let status) = try await s.workerClient.reply() else { Issue.record("a status poll was held"); return }
        #expect(status.operation == .status)
        try s.workerClient.send(.agentResponse(agentID: s.worker.id, requestID: token, result: .init(text: "live", idle: true)))
        #expect(try await s.leadClient.reply() == .agentResult(id: 2, result: .init(text: "live", idle: true)))
        try s.leadClient.send(.coordinateAgent(id: 3, agentID: s.lead.id, targetAgentID: s.lead.id, request: .init(operation: .read)))
        guard case .agentRequest(0, _, s.lead.id, let own) = try await s.leadClient.reply() else { Issue.record("an own read was held"); return }
        #expect(own.operation == .read)
        #expect(s.prompts.current.isEmpty)
    }

    /// Nobody is asked about a call that could not be done anyway.
    @Test func aCallThatCouldNotBeDoneIsRefusedBeforeAnyoneIsAsked() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        let stranger = AgentID()

        try s.leadClient.send(.sendToAgent(id: 1, agentID: s.lead.id, targetAgentID: stranger, text: "hi"))
        guard case .error(1, "no_such_agent", _) = try await s.leadClient.reply() else { Issue.record("asked about a stranger"); return }
        try s.leadClient.send(.sendToAgent(id: 2, agentID: s.lead.id, targetAgentID: s.lead.id, text: "hi"))
        guard case .error(2, "self_send", _) = try await s.leadClient.reply() else { Issue.record("asked about itself"); return }
        try s.leadClient.send(.spawnAgent(id: 3, agentID: s.lead.id, cwd: "/no/such/directory", prompt: "go"))
        guard case .error(3, "no_such_directory", _) = try await s.leadClient.reply() else { Issue.record("asked about a missing folder"); return }
        try s.leadClient.send(.coordinateAgent(id: 4, agentID: s.lead.id, targetAgentID: s.worker.id, request: .init(operation: .steer, text: " ")))
        guard case .error(4, "invalid", _) = try await s.leadClient.reply() else { Issue.record("asked about an empty steer"); return }
        try s.leadClient.send(.coordinateAgent(id: 5, agentID: s.lead.id, targetAgentID: s.ghost.id, request: .init(operation: .interrupt)))
        guard case .error(5, "not_running", _) = try await s.leadClient.reply() else { Issue.record("asked about a thread with no pi"); return }

        #expect(s.prompts.current.isEmpty)
    }

    /// The user answers a call a moment later and its target is gone: nothing is relayed, and the caller is told.
    @Test func anApprovedCallWhoseTargetWentAwayIsAnsweredNotRelayed() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.steer, id: 1))
        let prompt = try #require(try await s.asked().first)
        var state = s.h.server.state
        state.agents.removeAll { $0.id == s.worker.id }
        state.tabs.removeAll { $0.id == s.worker.tabID }
        try await s.h.server.putState(state)

        #expect(await s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce))

        #expect(try await s.leadClient.reply() == .error(id: 1, code: "no_such_agent", message: "registered sender and existing target required"))
    }

    // MARK: - The extension cannot answer for the user

    /// An agent's connection has no way to answer a dialog: a forged response, or a cancel from
    /// another connection, leaves the call waiting for the user.
    @Test func noMessageOnTheSocketAnswersADialogOrCancelsAnotherAgentsCall() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        try s.leadClient.send(s.message(.steer, id: 7))
        let prompt = try #require(try await s.asked().first)
        let impostor = try ExtensionClient(path: s.h.socketPath)
        try impostor.send(.helloAgent(agentID: s.ghost.id))

        // The token is the server's: no response on the socket is an answer to a dialog.
        try impostor.send(.agentResponse(agentID: s.ghost.id, requestID: prompt.requestID, result: .init(text: "approved")))
        try s.workerClient.send(.agentResponse(agentID: s.worker.id, requestID: prompt.requestID, result: .init(text: "approved")))
        try s.workerClient.send(.cancelAgentRequest(id: 7, agentID: s.worker.id))
        try impostor.send(.cancelAgentRequest(id: 7, agentID: s.ghost.id))
        try impostor.send(.cancelAgentRequest(id: 7, agentID: s.lead.id))
        try s.workerClient.send(.coordinateAgent(id: 99, agentID: s.worker.id, targetAgentID: s.worker.id, request: .init(operation: .status)))
        guard case .error(99, "self_control", _) = try await s.workerClient.reply() else { Issue.record("barrier"); return }

        #expect(s.lapsed.current.isEmpty, "the dialog is still up")
        await s.settleMain()
        #expect(s.done.current.isEmpty)
        #expect(await s.h.server.resolveAgentApproval(prompt.requestID, .allowOnce), "only the app's answer counts")
        guard case .agentRequest(0, _, _, let request) = try await s.workerClient.reply() else { Issue.record("not relayed"); return }
        #expect(request.operation == .steer)
    }

    /// More than one call may wait, each with its own dialog and its own answer, up to a limit per agent.
    @Test func severalCallsMayWaitAndOneAgentMayNotFloodTheDialogs() async throws {
        let s = try await scene(policy: .ask)
        defer { s.stop() }
        for id in 1...AgentMessageGate.pendingLimitPerAgent { try s.leadClient.send(s.message(.send, id: id)) }
        let waiting = try await s.asked(AgentMessageGate.pendingLimitPerAgent)
        #expect(Set(waiting.map(\.requestID)).count == waiting.count)

        try s.leadClient.send(s.message(.send, id: 50))
        #expect(try await s.leadClient.reply() == .error(id: 50, code: "busy", message: AgentMessageGate.busyMessage))
        try s.leadClient.send(s.message(.send, id: 1))
        #expect(try await s.leadClient.reply() == .error(id: 1, code: "busy", message: AgentMessageGate.busyMessage), "a duplicate id")

        #expect(await s.h.server.resolveAgentApproval(waiting[3].requestID, .allowOnce))
        #expect(try await s.leadClient.reply() == .ok(id: 4))
        #expect(s.prompts.current.count == AgentMessageGate.pendingLimitPerAgent)
    }

    /// With no app to ask, an asked call is refused rather than done or left hanging.
    @Test func withNoAppToAskACallIsRefusedUnsupported() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space("headless", path: h.dir.path)
        let lead = Fixture.agent(in: space, name: "lead")
        let worker = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([lead, worker], space: space))
        let client = try ExtensionClient(path: h.socketPath)
        h.server.onAgentPeerRequest = { _, respond in respond(.ok) }

        try client.send(.sendToAgent(id: 1, agentID: lead.agent.id, targetAgentID: worker.agent.id, text: "hi"))

        #expect(try await client.reply() == .error(id: 1, code: "unsupported", message: "native approval unavailable"))
    }
}
