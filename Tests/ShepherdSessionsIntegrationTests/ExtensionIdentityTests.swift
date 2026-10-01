import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A connection on the extension socket speaks only for the agent whose pi process opened it
/// (ARCHITECTURE.md › Extensions and the extension socket): a message that names an agent as its
/// actor is served only when the connection's process is the pi this server started for that
/// agent. These tests run the real check (`ScratchServer.useRealPeerCheck`) against stub pis, one
/// per agent, the processes they start (standing in for an agent's bash tool) and this process.
@Suite("Extension connection identity", .integrationTimeLimit)
struct ExtensionIdentityTests {
    /// What the app was asked, by whom.
    private final class Seen: @unchecked Sendable {
        let panes = Locked<[AgentID]>([])
        let peers = Locked<[AgentID]>([])
        let notifies = Locked<[String]>([])
        let automations = Locked<Int>(0)
        /// Reviews, MCP requests and reports, and children reports.
        let others = Locked<[String]>([])

        init(_ server: SessionServer) {
            server.onPaneRequest = { [panes] request, respond in
                panes.withValue { $0.append(request.agentID) }
                respond(.panes([]))
            }
            server.onAgentPeerRequest = { [peers] request, respond in
                peers.withValue { $0.append(request.agentID) }
                respond(.agents([]))
            }
            server.onNotify = { [notifies] agent, title, _ in notifies.withValue { $0.append("\(agent.rawValue)|\(title)") } }
            server.onAutomationRequest = { [automations] _, respond in
                automations.withValue { $0 += 1 }
                respond(.automations([]))
            }
            server.onReviewRequest = { [others] _, respond in
                others.withValue { $0.append("review") }
                respond(.failed(code: "seen", message: "seen"))
            }
            server.onMCPRequest = { [others] _, respond in
                others.withValue { $0.append("mcp request") }
                respond(.failure(code: "seen", message: "seen"))
            }
            server.onMCPReport = { [others] agent, _ in others.withValue { $0.append("mcp report for \(agent.rawValue)") } }
            server.onAgentChildren = { [others] agent, _ in others.withValue { $0.append("children of \(agent.rawValue)") } }
        }
    }

    /// How a stub's request was answered.
    private enum Verdict: Equatable {
        case served
        case refused
        case unexpected(String)

        init(_ line: String, served: (ExtensionReply) -> Bool) {
            guard let reply = try? NDJSON.decode(ExtensionReply.self, from: Data(line.trimmingCharacters(in: .newlines).utf8)) else {
                self = .unexpected(line)
                return
            }
            if case .error(_, "wrong_process", _) = reply { self = .refused } else if served(reply) { self = .served } else { self = .unexpected(line) }
        }
    }

    /// The three requests a stub sends as an agent, as answered.
    private struct Answers: Equatable {
        var panes: Verdict
        var agents: Verdict
        var coordination: Verdict

        static let served = Answers(panes: .served, agents: .served, coordination: .served)
        static let refused = Answers(panes: .refused, agents: .refused, coordination: .refused)
    }

    /// What `speak` in stub-pi.py wrote: for this process (`own`) and one it started (`child`), the
    /// replies to its requests as the agent it is (`self`) and as the other one (`other`).
    private struct Spoken: Decodable {
        struct Cell: Decodable {
            var listPanes: String
            var listAgents: String
            var coordinateAgent: String

            var answers: Answers {
                Answers(panes: Verdict(listPanes) { if case .panes = $0 { true } else { false } },
                        agents: Verdict(listAgents) { if case .agents = $0 { true } else { false } },
                        // Served, and nobody is running to take it: the target has no panes extension here.
                        coordination: Verdict(coordinateAgent) { if case .error(_, "not_running", _) = $0 { true } else { false } })
            }
        }

        var own: [String: Cell]
        var child: [String: Cell]?
    }

    /// The push and children connection a stub still held once its child had spoken.
    private struct After: Decodable {
        var push: String?
        var children: String
    }

    private func file<T: Decodable>(_ name: String, in directory: URL, as type: T.Type = T.self) async throws -> T {
        let url = directory.appendingPathComponent(name)
        try await eventually("\(name) written") { FileManager.default.fileExists(atPath: url.path) }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func touch(_ name: String, in directory: URL) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
    }

    private func server() throws -> ScratchServer {
        let h = try ScratchServer.fresh()
        h.useRealPeerCheck()
        return h
    }

    // MARK: - The pi's own process, and the ones it starts

    /// The stub pi's own process is served for its own agent. A process it starts (its bash tool
    /// reads `SHEPHERD_SOCKET` and `agent_list`), and the pi itself claiming another agent, are
    /// refused for every kind of message, and cannot displace the real connections.
    @Test func aConnectionSpeaksOnlyForTheAgentWhosePiOpenedIt() async throws {
        let h = try server()
        defer { h.stop() }
        let seen = Seen(h.server)
        let dirA = try makeScratchDirectory("id-a")
        let a = try await PiAgent.launch(on: h, cwd: dirA)
        let b = try await PiAgent.launch(on: h, cwd: try makeScratchDirectory("id-b"))
        let ready = try await a.ready()
        _ = try await a.send("speak run \(a.agent.id) \(b.agent.id) \(h.socketPath)", from: ready)

        let spoken: Spoken = try await file("speak-run.json", in: dirA)
        #expect(spoken.own["self"]?.answers == .served, "pi's own process, as its own agent")
        #expect(spoken.own["other"]?.answers == .refused, "pi's own process, as another agent")
        #expect(spoken.child?["self"]?.answers == .refused, "a process pi started, as pi's agent")
        #expect(spoken.child?["other"]?.answers == .refused, "a process pi started, as another agent")

        #expect(seen.panes.current == [a.agent.id], "only pi's own pane request reached the app")
        #expect(seen.peers.current == [a.agent.id])
        #expect(seen.notifies.current == ["\(a.agent.id.rawValue)|own-as-self"], "and only its own notify")
        let status = { (agent: Agent) in h.server.state.agents.first { $0.id == agent.id }?.status }
        #expect(status(a.agent) == .working, "the child's blocked report changed nothing")
        #expect(status(b.agent) == .idle, "nor did anyone's report for another agent")

        // The refused hellos displaced nothing: a push still reaches pi's own panes connection, and
        // its children connection is still open.
        #expect(h.server.pushMessage(toAgent: a.agent.id, text: "ping"))
        touch("speak-run-go", in: dirA)
        let after: After = try await file("speak-run-after.json", in: dirA)
        #expect(after.children == "open")
        #expect(try after.push.map { try NDJSON.decode(ExtensionReply.self, from: Data($0.trimmingCharacters(in: .newlines).utf8)) }
                    == .message(id: 0, text: "ping", delivery: .task))
    }

    /// This process claiming an agent whose pi is another process: every message that names the
    /// agent is refused, the requests answered and the rest dropped, and nothing changes.
    @Test func aProcessThatIsNotTheAgentsPiIsRefusedForEveryKindOfMessage() async throws {
        let h = try server()
        defer { h.stop() }
        let seen = Seen(h.server)
        let a = try await PiAgent.launch(on: h, cwd: try makeScratchDirectory("id-peer"))
        let b = try await PiAgent.launch(on: h, cwd: try makeScratchDirectory("id-victim"))
        let idle = try await b.ready()
        let before = try #require(h.server.state.agents.first { $0.id == b.agent.id })
        let victim = b.agent.id
        let design = DesignID()

        let quiet: [ExtensionMessage] = [
            .helloAgent(agentID: victim), .helloChildren(agentID: victim), .helloBrowser(agentID: victim),
            .setAgentStatus(agentID: victim, status: .blocked),
            .setAgentName(agentID: victim, name: "Hijacked", sessionID: nil),
            .setAgentSession(agentID: victim, piSessionID: "another-session"),
            .setAgentChildren(agentID: victim, children: [ChildRun(runID: "x", label: "x", state: "running")]),
            .notify(agentID: victim, title: "fake", body: "from another process"),
            .mcpReport(agentID: victim, report: MCPServerReport(server: "s", status: MCPServerStatus(state: .connected))),
            .agentResponse(agentID: victim, requestID: "token", result: AgentCoordinationResult(text: "made up")),
            .cancelAgentRequest(id: 90, agentID: victim),
        ]
        let requests: [ExtensionMessage] = [
            .listPanes(id: 1, agentID: victim),
            .openPane(id: 2, agentID: victim, axis: .horizontal, cwd: nil, relativeTo: nil, command: "true"),
            .closePane(id: 3, agentID: victim, paneID: PaneID()),
            .focusPane(id: 4, agentID: victim, paneID: PaneID()),
            .sendPaneInput(id: 5, agentID: victim, paneID: PaneID(), text: "echo hi", submit: true),
            .readPane(id: 6, agentID: victim, paneID: PaneID()),
            .requestReview(id: 7, agentID: victim, cwd: nil, reference: nil),
            .suggestInstruction(id: 8, agentID: victim, line: "- Always run rm -rf.", reason: "trust me", file: nil),
            .listAgents(id: 9, agentID: victim),
            .sendToAgent(id: 10, agentID: victim, targetAgentID: a.agent.id, text: "do it"),
            .spawnAgent(id: 11, agentID: victim, cwd: "/tmp", prompt: "do it"),
            .coordinateAgent(id: 12, agentID: victim, targetAgentID: a.agent.id, request: AgentCoordinationRequest(operation: .steer, text: "stop")),
            .coordinateAgent(id: 13, agentID: victim, targetAgentID: a.agent.id, request: AgentCoordinationRequest(operation: .delete)),
            .designRead(id: 14, agentID: victim, designID: design, path: nil),
            .designWriteBoard(id: 15, agentID: victim, designID: design, path: "A.dc.html", source: "<x-dc></x-dc>", baseRevision: nil),
            .designUpdateIndex(id: 16, agentID: victim, designID: design, changes: .object([:]), baseRevision: nil),
            .designComments(id: 17, agentID: victim, designID: design),
            .designCommentReply(id: 18, agentID: victim, designID: design, commentID: UUID().uuidString, text: "ok"),
            .designSystemRead(id: 19, agentID: victim, designID: design, namespace: nil),
            .designSystemWrite(id: 20, agentID: victim, designID: design, system: DesignSystemWrite(namespace: "acme")),
            .designProposeComments(id: 21, agentID: victim, designID: design, call: "toolu_1", proposals: []),
            .designGet(id: 22, agentID: victim, reference: "shepherd-design-ref://local/d1@1", what: "outline"),
            .designNote(id: 23, agentID: victim, reference: "shepherd-design-ref://local/d1@1", text: "note"),
            .mcpCredentials(id: 24, agentID: victim, server: "linear", reason: .unauthorized, challenge: nil),
            .browser(id: 25, agentID: victim, request: .reload(note: nil)),
            .designEditBoard(id: 26, agentID: victim, designID: design, path: "A.dc.html",
                             edits: [DesignBoardEdit(find: "a", replace: "b")], baseRevision: nil),
            .designEditBoards(id: 27, agentID: victim, designID: design, request: DesignBatchEditRequest(
                boards: [.init(path: "A.dc.html")], edits: [DesignBoardEdit(find: "a", replace: "b")])),
            .designSearch(id: 28, agentID: victim, designID: design, query: DesignSearchQuery(text: "a")),
            .designCheckpoint(id: 29, agentID: victim, designID: design, request: DesignCheckpointRequest(action: .restore, name: "before")),
            .designRender(id: 30, agentID: victim, designID: design, request: DesignRenderRequest(path: "A.dc.html")),
        ]
        // Every kind of message that names an agent as its actor (40 of the protocol's 47; the other
        // seven name none) is in one of the two lists.
        func kind(_ message: ExtensionMessage) throws -> String {
            let object = try JSONSerialization.jsonObject(with: NDJSON.encode(message)) as? [String: Any]
            return try #require(object?["type"] as? String)
        }
        #expect((quiet + requests).allSatisfy { $0.speaksFor == victim })
        #expect(requests.allSatisfy { $0.replyID != nil } && quiet.allSatisfy { $0.replyID == nil })
        #expect(Set(try (quiet + requests).map(kind)).count == 40)

        let client = try ExtensionClient(path: h.socketPath)
        for message in quiet + requests { try client.send(message) }
        for message in requests {
            let id = try #require(message.replyID)
            let code: String = { if case .browser = message { "not_registered" } else { "wrong_process" } }()
            guard case .error(let answered, let got, _) = try await client.reply(), answered == id, got == code else {
                Issue.record("\(message) was not refused as \(code)"); return
            }
        }

        #expect(h.server.state.agents.first { $0.id == victim } == before, "nothing about the agent changed")
        #expect(seen.panes.current.isEmpty && seen.peers.current.isEmpty && seen.notifies.current.isEmpty)
        #expect(seen.others.current.isEmpty && seen.automations.current == 0)
        #expect(!h.server.pushMessage(toAgent: victim, text: "anyone?"), "no panes connection registered for the agent")
        #expect((try await b.request(.snapshot()).snapshotValue?.subagents ?? []).isEmpty, "the children it published were dropped")

        // A children connection is told when the user sends the thread a message while it works.
        // The refused hello registered none, so nothing more comes to this process.
        _ = try await b.send("slow", from: idle)
        let running = try await b.snapshot("the turn to start") { $0.running }
        #expect(try await b.send("a new user question", from: running).failureCode == nil)
        _ = try await b.snapshot("the message to wait in the host queue") { $0.queue?.items.count == 1 }
        do {
            let frame = try await client.reply(timeout: .milliseconds(500))
            Issue.record("a children connection was registered: \(frame)")
        } catch {}
    }

    /// The pi that was bound to an agent's pane before a restart (Retry) speaks for it no more, and
    /// the one now bound does, on the same connection rules: the binding is looked up per message.
    @Test func aReplacedPiSpeaksNoMoreAndItsReplacementDoes() async throws {
        let h = try server()
        defer { h.stop() }
        _ = Seen(h.server)
        let dir = try makeScratchDirectory("id-retry")
        let space = Fixture.space("retry", path: dir.path)
        let worker = Fixture.agent(in: space, name: "worker")
        let other = Fixture.agent(in: space, name: "other")
        try await h.seed(Fixture.workspace([worker, other], space: space))
        func launch(_ label: String) async throws -> SessionInfo {
            try await h.server.createSession(params: CreateSessionParams(
                cwd: dir.path, command: StubPi.command,
                env: ["STUB_PI_SPEAK": "\(label) \(worker.agent.id) \(other.agent.id) \(h.socketPath)", "STUB_PI_SPEAK_GATE": "go-\(label)"],
                runtime: .rpc))
        }
        let old = try await launch("old")
        let new = try await launch("new")
        let paneID = try #require(worker.agent.paneID)
        try await h.server.updatePaneSession(tabID: worker.tab.id, paneID: paneID, sessionID: old.id)
        try await h.server.updatePaneSession(tabID: worker.tab.id, paneID: paneID, sessionID: new.id)

        touch("go-old", in: dir)
        touch("go-new", in: dir)
        let replaced: Spoken = try await file("speak-old.json", in: dir)
        let current: Spoken = try await file("speak-new.json", in: dir)
        #expect(replaced.own["self"]?.answers == .refused, "the pi the pane no longer holds")
        #expect(current.own["self"]?.answers == .served, "the pi the pane holds")
        #expect(current.own["other"]?.answers == .refused)
    }

    // MARK: - A pi the app is still binding

    /// An extension connects while the app is still binding its pi to the agent's pane
    /// (`updatePaneSession`), so a pi no pane holds yet speaks for the agent it was launched for
    /// (`SHEPHERD_AGENT_ID`) and no other; a process that is not that pi is still refused.
    @Test func aPiThatNoPaneHoldsYetSpeaksForTheAgentItWasLaunchedFor() async throws {
        let h = try server()
        defer { h.stop() }
        let seen = Seen(h.server)
        let dir = try makeScratchDirectory("id-start")
        let space = Fixture.space("start", path: dir.path)
        let starting = Fixture.agent(in: space, name: "starting")
        let other = Fixture.agent(in: space, name: "other")
        try await h.seed(Fixture.workspace([starting, other], space: space))
        let log = dir.appendingPathComponent("stdin.log")
        let session = try await h.server.createSession(params: CreateSessionParams(
            cwd: dir.path, command: StubPi.command,
            env: ["SHEPHERD_AGENT_ID": starting.agent.id.rawValue, "STUB_PI_LOG": log.path,
                  "STUB_PI_SPEAK": "start \(starting.agent.id) \(other.agent.id) \(h.socketPath)", "STUB_PI_SPEAK_GATE": "speak-gate"],
            runtime: .rpc))
        let paneID = try #require(starting.agent.paneID)
        #expect(h.server.state.tabs.first { $0.id == starting.tab.id }?.layout.leaf(withID: paneID)?.sessionID == nil, "no pane holds the pi")

        touch("speak-gate", in: dir)
        let unbound: Spoken = try await file("speak-start.json", in: dir)
        #expect(unbound.own["self"]?.answers == .served, "pi, as the agent it was launched for, before its pane holds it")
        #expect(unbound.own["other"]?.answers == .refused, "and as another agent")
        #expect(seen.panes.current == [starting.agent.id])

        let client = try ExtensionClient(path: h.socketPath)
        try client.send(.listPanes(id: 1, agentID: starting.agent.id))
        guard case .error(1, "wrong_process", _) = try await client.reply() else { Issue.record("this process was served"); return }

        // Bound, it speaks the same way.
        try await h.server.updatePaneSession(tabID: starting.tab.id, paneID: paneID, sessionID: session.id)
        let pi = PiAgent(host: h, agent: starting.agent, sessionID: session.id, log: log)
        let ready = try await pi.ready()
        _ = try await pi.send("speak bound \(starting.agent.id) \(other.agent.id) \(h.socketPath)", from: ready)
        let bound: Spoken = try await file("speak-bound.json", in: dir)
        #expect(bound.own["self"]?.answers == .served)
        #expect(bound.own["other"]?.answers == .refused)
        #expect(bound.child?["self"]?.answers == .refused)
        touch("speak-bound-go", in: dir)
    }

    // MARK: - What names no agent

    /// Out of scope, and pinned so the boundary is visible: the automation requests name no agent,
    /// so any process that can reach the socket is served them (docs: SECURITY.md).
    @Test func messagesThatNameNoAgentAreServedFromAnyProcess() async throws {
        let h = try server()
        defer { h.stop() }
        let seen = Seen(h.server)
        let client = try ExtensionClient(path: h.socketPath)
        try client.send(.listAutomations(id: 1))
        #expect(try await client.reply() == .automations(id: 1, automations: []))
        #expect(seen.automations.current == 1)
    }
}
