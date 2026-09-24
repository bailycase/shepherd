import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The Unix socket the bundled pi extensions talk to: fire-and-forget reports that mutate agent
/// records, and request/reply traffic routed to GUI handlers by correlation id.
@Suite("Extension socket", .integrationTimeLimit)
struct ExtensionSocketTests {
    private func inode(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue
    }

    // MARK: - Status

    @Test func aStatusReportIsPersistedBroadcastAndForwarded() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("the status callback") { callbacks.statuses.current.contains { $0 == (worker.agent.id, .working) } }
        await drainMainQueue()
        #expect(h.server.state.agents.first?.status == .working)
        #expect(try h.persisted().agents.first?.status == .working)
        #expect(h.broadcasts.current.map { $0.agents.first?.status } == [.working])
    }

    /// Real lifecycles are messier than the transition table: a violation is logged and applied.
    @Test func aStatusOutsideTheTransitionTableIsStillApplied() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, status: .done)
        try await h.seed(Fixture.workspace([worker], space: space))
        #expect(!AgentStatus.done.canTransition(to: .blocked))
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .blocked))
        try await eventually("the blocked status to apply") { h.server.state.agents.first?.status == .blocked }
    }

    /// A reconnecting extension re-sends its current status: the app still hears it (launch UI
    /// learns pi is up) but state.json is not rewritten and nothing is broadcast.
    @Test func anUnchangedStatusIsForwardedWithoutAWrite() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, status: .idle)
        try await h.seed(Fixture.workspace([worker], space: space))
        let fileBefore = try inode(h.stateURL)
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .idle))
        try await eventually("the unchanged status callback") { !callbacks.statuses.current.isEmpty }
        await drainMainQueue()
        #expect(try inode(h.stateURL) == fileBefore)
        #expect(h.broadcasts.current.isEmpty)
    }

    @Test func reportsForUnknownAgentsAreDroppedAndTheConnectionKeepsServing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentStatus(agentID: AgentID(), status: .working))
        try client.send(.setAgentName(agentID: AgentID(), name: "Ghost"))
        try client.send(.setAgentSession(agentID: AgentID(), piSessionID: "ghost"))
        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("the known agent's report") { h.server.state.agents.first?.status == .working }
        await drainMainQueue()
        #expect(callbacks.statuses.current.map { $0.0 } == [worker.agent.id])
        #expect(h.broadcasts.current.count == 1)
    }

    @Test func malformedLinesAreIgnoredWithoutDroppingTheConnection() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let client = try ExtensionClient(path: h.socketPath)

        try client.sendRaw(Data("not json\n{\"type\":\"noSuchMessage\"}\n".utf8))
        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("a valid report after garbage") { h.server.state.agents.first?.status == .working }
    }

    /// At launch every pi's extensions connect while the queue may be busy: the backlog holds
    /// them until the queue accepts, rather than refusing them. A backlog of 16 held 25; the
    /// count stays well under a 256-descriptor limit, since both ends are in this process.
    @Test func extensionsConnectingWhileTheQueueIsBusyAreAllAccepted() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let connections = 64
        let release = DispatchSemaphore(value: 0)
        await h.server.holdQueue(until: release)
        var clients: [ExtensionClient] = []
        var refused = 0
        for _ in 0..<connections {
            do { clients.append(try ExtensionClient(path: h.socketPath)) } catch { refused += 1 }
        }
        release.signal()
        #expect(refused == 0)

        // Each connection is served: an incomplete request gets its correlated error.
        var answered = 0
        for (index, client) in clients.enumerated() {
            try client.send(.sendToAgent(id: index, agentID: AgentID(rawValue: "a"), targetAgentID: AgentID(rawValue: "b"), text: " "))
            if case .error(index, "invalid", _) = try await client.reply() { answered += 1 }
        }
        #expect(answered == connections)
    }

    @Test func anOversizedFrameDisconnectsTheClient() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let client = try ExtensionClient(path: h.socketPath)
        try? client.sendRaw(Data(repeating: UInt8(ascii: "x"), count: NDJSON.maxPayloadBytes + 1))
        #expect(try await client.disconnected())
    }

    // MARK: - Session and name

    /// `/new` and `/resume` move pi to another conversation: relaunch reopens it, and its old
    /// title no longer applies, so naming reopens.
    @Test func aSessionReportMovesTheAgentAndReopensNaming() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, nameIsFinal: true)
        try await h.seed(Fixture.workspace([worker], space: space))
        #expect(h.server.state.agents.first?.effectivePiSessionID == worker.agent.id.rawValue)
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentSession(agentID: worker.agent.id, piSessionID: "  after-new \n"))
        try await eventually("the new session to be recorded") { h.server.state.agents.first?.piSessionID == "after-new" }
        #expect(h.server.state.agents.first?.nameIsFinal == false)
        #expect(try h.persisted().agents.first?.piSessionID == "after-new")
    }

    @Test func blankOrRepeatedSessionReportsChangeNothing() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        var worker = Fixture.agent(in: space, nameIsFinal: true)
        worker.agent.piSessionID = "current"
        try await h.seed(Fixture.workspace([worker], space: space))
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentSession(agentID: worker.agent.id, piSessionID: "   "))
        try client.send(.setAgentSession(agentID: worker.agent.id, piSessionID: "current"))
        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("the barrier report") { h.server.state.agents.first?.status == .working }
        #expect(h.server.state.agents.first?.piSessionID == "current")
        #expect(h.server.state.agents.first?.nameIsFinal == true)
    }

    /// The namer titles a provisional agent exactly once; a landed or hand-typed name wins.
    @Test func theNamerTitlesOnlyProvisionalAgentsAndOnlyOnce() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let pending = Fixture.agent(in: space, name: "clean up the naming code…", nameIsFinal: false)
        let manual = Fixture.agent(in: space, name: "prod-hotfix", nameIsFinal: true)
        try await h.seed(Fixture.workspace([pending, manual], space: space))
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentName(agentID: pending.agent.id, name: "   "))
        try client.send(.setAgentName(agentID: pending.agent.id, name: " Fix plan mode over SSH "))
        try client.send(.setAgentName(agentID: pending.agent.id, name: "Something else"))
        try client.send(.setAgentName(agentID: manual.agent.id, name: "Refactor sidebar"))
        try client.send(.setAgentStatus(agentID: manual.agent.id, status: .working))
        try await eventually("the barrier report") { h.server.state.agents.last?.status == .working }

        let agents = h.server.state.agents
        #expect(agents.first?.name == "Fix plan mode over SSH")
        #expect(agents.first?.nameIsFinal == true)
        #expect(agents.last?.name == "prod-hotfix")
    }

    // MARK: - Children, notify, pushes

    @Test func childRunsAreForwardedToTheAppWithoutTouchingState() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let received = Locked<[(AgentID, [ChildRun])]>([])
        h.server.onAgentChildren = { id, rows in received.withValue { $0.append((id, rows)) } }
        let agentID = AgentID()
        let rows = [ChildRun(runID: "native-1", label: "worker: restyle", state: "running")]
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.setAgentChildren(agentID: agentID, children: rows))
        try await eventually("the children callback") { !received.current.isEmpty }
        #expect(received.current.first?.0 == agentID)
        #expect(received.current.first?.1 == rows)
        #expect(h.broadcasts.current.isEmpty)
    }

    @Test func notifyIsForwardedToTheApp() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let received = Locked<[String]>([])
        h.server.onNotify = { id, title, body in received.withValue { $0.append("\(id.rawValue)|\(title)|\(body)") } }
        let agentID = AgentID()
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.notify(agentID: agentID, title: "CI passed", body: "PR #42 is green"))
        try await eventually("the notify callback") { received.current == ["\(agentID.rawValue)|CI passed|PR #42 is green"] }
    }

    @Test func pushedMessagesReachOnlyARegisteredConnection() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let target = AgentID()
        #expect(!h.server.pushMessage(toAgent: target, text: "nobody home"))

        let client = try ExtensionClient(path: h.socketPath)
        try client.send(.helloAgent(agentID: target))
        try await eventually("the registration") { h.server.pushMessage(toAgent: target, text: "[from: tester] ping") }
        #expect(try await client.reply() == .message(id: 0, text: "[from: tester] ping"))

        client.closeConnection()
        try await eventually("the registration to lapse") { !h.server.pushMessage(toAgent: target, text: "gone?") }
    }

    /// One children control channel per agent: a newer helloChildren replaces the old connection.
    @Test func aNewChildrenConnectionReplacesTheOldOne() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await h.seed(Fixture.workspace([worker], space: space))
        let first = try ExtensionClient(path: h.socketPath)
        try first.send(.helloChildren(agentID: worker.agent.id))
        let second = try ExtensionClient(path: h.socketPath)
        try second.send(.helloChildren(agentID: worker.agent.id))
        #expect(try await first.disconnected())
    }

    // MARK: - Request routing

    @Test func paneRequestsRouteToTheHandlerWithTheirFieldsAndRepliesKeepTheID() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agentID = AgentID()
        let paneID = PaneID()
        let pane = PaneInfo(id: paneID, cwd: "/tmp", isAgentPane: true, isFocused: true, isAlive: true)
        let seen = Locked<[PaneRequest]>([])
        h.server.onPaneRequest = { request, respond in
            seen.withValue { $0.append(request) }
            switch request {
            case .list: respond(.panes([pane]))
            case .open: respond(.opened(pane))
            case .read: respond(.content(paneID: paneID, lines: ["listening on :3000"]))
            default: respond(.ok)
            }
        }
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.listPanes(id: 41, agentID: agentID))
        #expect(try await client.reply() == .panes(id: 41, panes: [pane]))
        try client.send(.openPane(id: 42, agentID: agentID, axis: .horizontal, cwd: "/tmp/work", relativeTo: paneID, command: "npm test"))
        #expect(try await client.reply() == .paneOpened(id: 42, pane: pane))
        try client.send(.readPane(id: 43, agentID: agentID, paneID: paneID))
        #expect(try await client.reply() == .paneContent(id: 43, paneID: paneID, lines: ["listening on :3000"]))
        try client.send(.focusPane(id: 44, agentID: agentID, paneID: paneID))
        #expect(try await client.reply() == .ok(id: 44))
        try client.send(.sendPaneInput(id: 45, agentID: agentID, paneID: paneID, text: "ls", submit: true))
        #expect(try await client.reply() == .ok(id: 45))
        try client.send(.closePane(id: 46, agentID: agentID, paneID: paneID))
        #expect(try await client.reply() == .ok(id: 46))

        #expect(seen.current == [
            .list(agentID: agentID),
            .open(agentID: agentID, axis: .horizontal, cwd: "/tmp/work", relativeTo: paneID, command: "npm test"),
            .read(agentID: agentID, paneID: paneID),
            .focus(agentID: agentID, paneID: paneID),
            .sendInput(agentID: agentID, paneID: paneID, text: "ls", submit: true),
            .close(agentID: agentID, paneID: paneID),
        ])
    }

    @Test func aHandlerFailureBecomesACorrelatedErrorReply() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.onPaneRequest = { _, respond in respond(.failed(code: "not_closable", message: "an agent cannot close its own pi pane")) }
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.closePane(id: 7, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.reply() == .error(id: 7, code: "not_closable", message: "an agent cannot close its own pi pane"))
    }

    /// A headless server still answers every request, so an extension never waits out its timeout.
    @Test func requestsWithoutAHandlerAreAnsweredUnsupported() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let client = try ExtensionClient(path: h.socketPath)
        let agentID = AgentID()
        let requests: [(ExtensionMessage, String)] = [
            (.listPanes(id: 1, agentID: agentID), "pane control unavailable"),
            (.requestReview(id: 2, agentID: agentID, cwd: nil, reference: nil), "no review handler"),
            (.listAutomations(id: 3), "automations unavailable"),
            (.listAgents(id: 4, agentID: agentID), "agent peers unavailable"),
        ]
        for (message, text) in requests {
            try client.send(message)
            let reply = try await client.reply()
            guard case .error(_, "unsupported", let got) = reply else { Issue.record("expected unsupported, got \(reply)"); continue }
            #expect(got == text)
        }
    }

    @Test func reviewRequestsRouteAndReturnTheSubmittedText() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let seen = Locked<[ReviewRequest]>([])
        h.server.onReviewRequest = { request, respond in
            seen.withValue { $0.append(request) }
            respond(.submitted(text: "Summary: ready to merge."))
        }
        let agentID = AgentID()
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.requestReview(id: 51, agentID: agentID, cwd: "/tmp/repo", reference: "HEAD~2"))
        #expect(try await client.reply() == .reviewResult(id: 51, text: "Summary: ready to merge."))
        #expect(seen.current == [.start(agentID: agentID, cwd: "/tmp/repo", reference: "HEAD~2")])
    }

    @Test func automationRequestsRouteTheFullManagementSurface() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let info = AutomationInfo(id: AutomationID(rawValue: "au1"), name: "w", prompt: "p", cwd: "/tmp", enabled: true, agentStatus: "working")
        let seen = Locked<[AutomationRequest]>([])
        h.server.onAutomationRequest = { request, respond in
            seen.withValue { $0.append(request) }
            if case .list = request { respond(.automations([info])) } else { respond(.ok) }
        }
        let client = try ExtensionClient(path: h.socketPath)
        let id = info.id

        try client.send(.createAutomation(id: 1, name: " pr-watch ", prompt: " watch the PR ", cwd: "/tmp/repo", enabled: true, start: true))
        #expect(try await client.reply() == .ok(id: 1))
        try client.send(.listAutomations(id: 2))
        #expect(try await client.reply() == .automations(id: 2, automations: [info]))
        for (n, message) in [
            ExtensionMessage.updateAutomation(id: 3, automationID: id, name: nil, prompt: "new", cwd: nil, enabled: false),
            .startAutomation(id: 4, automationID: id),
            .stopAutomation(id: 5, automationID: id),
            .deleteAutomation(id: 6, automationID: id),
        ].enumerated() {
            try client.send(message)
            #expect(try await client.reply() == .ok(id: n + 3))
        }

        let requests = seen.current
        #expect(requests.count == 6)
        guard case .create(let automation, let start)? = requests.first else { Issue.record("expected create"); return }
        #expect(automation.name == "pr-watch" && automation.prompt == "watch the PR" && automation.cwd == "/tmp/repo")
        #expect(start)
        #expect(Array(requests.dropFirst()) == [
            .list,
            .update(automationID: id, name: nil, prompt: "new", cwd: nil, enabled: false),
            .start(automationID: id), .stop(automationID: id), .delete(automationID: id),
        ])
    }

    @Test(arguments: [
        ExtensionMessage.createAutomation(id: 9, name: "  ", prompt: "p", cwd: "/tmp", enabled: true, start: false),
        .createAutomation(id: 9, name: "n", prompt: "", cwd: "/tmp", enabled: true, start: false),
        .createAutomation(id: 9, name: "n", prompt: "p", cwd: "", enabled: true, start: false),
        .sendToAgent(id: 9, agentID: AgentID(rawValue: "a"), targetAgentID: AgentID(rawValue: "b"), text: " \n"),
        .spawnAgent(id: 9, agentID: AgentID(rawValue: "a"), cwd: "", prompt: "go"),
        .spawnAgent(id: 9, agentID: AgentID(rawValue: "a"), cwd: "/tmp", prompt: "  "),
    ])
    func incompleteRequestsAreRejectedBeforeTheHandler(message: ExtensionMessage) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let reached = Locked(false)
        h.server.onAutomationRequest = { _, respond in reached.withValue { $0 = true }; respond(.ok) }
        h.server.onAgentPeerRequest = { _, respond in reached.withValue { $0 = true }; respond(.ok) }
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(message)
        let reply = try await client.reply()
        guard case .error(9, "invalid", _) = reply else { Issue.record("expected invalid, got \(reply)"); return }
        #expect(!reached.current)
    }

    @Test func agentPeerRequestsRoute() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let peer = AgentPeerInfo(id: AgentID(rawValue: "a2"), name: "worker", status: "working", cwd: "/tmp", isSelf: false)
        let seen = Locked<[AgentPeerRequest]>([])
        h.server.onAgentPeerRequest = { request, respond in
            seen.withValue { $0.append(request) }
            if case .list = request { respond(.agents([peer])) } else { respond(.ok) }
        }
        let (sender, target) = (AgentID(rawValue: "a1"), AgentID(rawValue: "a2"))
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.listAgents(id: 1, agentID: sender))
        #expect(try await client.reply() == .agents(id: 1, agents: [peer]))
        try client.send(.sendToAgent(id: 2, agentID: sender, targetAgentID: target, text: "CI is green"))
        #expect(try await client.reply() == .ok(id: 2))
        try client.send(.spawnAgent(id: 3, agentID: sender, cwd: "/tmp/repo", prompt: "do the thing"))
        #expect(try await client.reply() == .ok(id: 3))
        #expect(seen.current == [
            .list(agentID: sender),
            .send(agentID: sender, targetAgentID: target, text: "CI is green"),
            .spawn(agentID: sender, cwd: "/tmp/repo", prompt: "do the thing"),
        ])
    }

    @Test func aReplyOverThePayloadLimitBecomesACorrelatedError() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.onPaneRequest = { _, respond in
            respond(.content(paneID: PaneID(), lines: [String(repeating: "x", count: NDJSON.maxPayloadBytes)]))
        }
        let client = try ExtensionClient(path: h.socketPath)

        try client.send(.readPane(id: 17, agentID: AgentID(), paneID: PaneID()))
        #expect(try await client.reply() == .error(id: 17, code: "reply_too_large", message: "reply exceeds the maximum payload size"))
    }

    /// A reply near the limit drains through a tiny receive buffer instead of blocking the server.
    @Test func aNearLimitReplySurvivesASlowReader() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let paneID = PaneID()
        let line = String(repeating: "x", count: NDJSON.maxPayloadBytes - 256 * 1024)
        h.server.onPaneRequest = { _, respond in respond(.content(paneID: paneID, lines: [line])) }
        let client = try ExtensionClient(path: h.socketPath, receiveBufferSize: 16 * 1024)

        try client.send(.readPane(id: 18, agentID: AgentID(), paneID: paneID))
        let reply = try await client.reply(timeout: .seconds(30))
        // Never hand a megabyte to #expect(==): its failure diff is quadratic.
        let intact = reply == .paneContent(id: 18, paneID: paneID, lines: [line])
        #expect(intact)
    }
}
