import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

@Suite("Session server end to end", .serialized)
struct ServerEndToEndTests {
    /// M1 acceptance: attach returns a screen snapshot that renders the
    /// session's output on a fresh terminal; detach/reattach replays again
    /// (the theme-switch path); output streams only while attached.
    @Test func attachReplayAndStreaming() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        // Unknown session is rejected.
        do {
            _ = try await server.attach(sessionID: SessionID(), replay: true)
            Issue.record("expected no_such_session")
        } catch {}

        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "printf marker123"]
        ))
        #expect(info.isAlive)

        // Output is NOT delivered before attach.
        let output = Locked<Data>(Data())
        server.onOutput = { _, data in output.withValue { $0.append(data) } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(output.current.isEmpty)

        // Attach replays the snapshot (the command may already have finished;
        // the headless screen retains final state).
        let replay = try await server.attach(sessionID: info.id, replay: true)
        let text = String(decoding: replay, as: UTF8.self)
        #expect(text.contains("marker123"))

        // Reattach (detach + attach) replays the same snapshot.
        server.detach(sessionID: info.id)
        let replay2 = try await server.attach(sessionID: info.id, replay: true)
        #expect(String(decoding: replay2, as: UTF8.self).contains("marker123"))
    }

    /// A long-lived session streams live output to the attached client.
    @Test func liveOutputStreamsWhileAttached() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "printf one; sleep 0.2; printf two; sleep 0.5"]
        ))
        let output = Locked<Data>(Data())
        server.onOutput = { _, data in output.withValue { $0.append(data) } }

        _ = try await server.attach(sessionID: info.id, replay: false)

        // `one` arrives while attached...
        try await waitUntil(timeout: .seconds(10)) { String(decoding: output.current, as: UTF8.self).contains("one") }
        // ...and `two` too, but only because we're still attached.
        try await waitUntil(timeout: .seconds(10)) { String(decoding: output.current, as: UTF8.self).contains("two") }

        // After the child exits, the session reports exit and stops streaming.
        let exited = Locked<Int32?>(nil)
        server.onSessionExited = { _, code in exited.withValue { $0 = code } }
        try await waitUntil(timeout: .seconds(10)) { exited.current != nil }
        #expect(exited.current == 0)
    }

    /// Session lifecycle: SIGTERM kill, then SIGKILL escalation for stubborn
    /// children, and dead sessions ignore writes.
    @Test func killEscalatesForStubbornChildren() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        // trap '' TERM makes SIGTERM a no-op, forcing the SIGKILL escalation.
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "trap '' TERM; sleep 100"]
        ))
        // Signaled children exit with a nil code, so track receipt separately.
        let received = Locked(false)
        let exited = Locked<Int32?>(nil)
        server.onSessionExited = { _, code in
            exited.withValue { $0 = code }
            received.withValue { $0 = true }
        }

        server.killSession(info.id)
        try await waitUntil(timeout: .seconds(30)) { received.current }
        // Killed by signal: no exit code.
        #expect(exited.current == nil)

        // Writes to a dead session are ignored.
        server.write(sessionID: info.id, data: Data("echo nope\r".utf8))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await server.listSessions().first?.isAlive == false)
    }

    @Test func processGroupKillCleansUpAStubbornDescendant() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let pidURL = dir.appendingPathComponent("child.pid")
        let script = "trap '' TERM; (trap '' TERM; sleep 100) & child=$!; echo $child > \(pidURL.path); wait"
        let exited = Locked(false)
        server.onSessionExited = { _, _ in exited.withValue { $0 = true } }
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", script]
        ))

        #expect(try await waitUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: pidURL.path)
        })
        let childPID = pid_t(Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)

        server.killSession(info.id)
        #expect(try await waitUntil(timeout: .seconds(10)) { exited.current })
        #expect(try await waitUntil(timeout: .seconds(10)) { kill(childPID, 0) != 0 })
    }

    @Test func stopKillsTheEntireProcessGroup() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pidURL = dir.appendingPathComponent("child.pid")
        let script = "trap '' HUP TERM; (trap '' HUP TERM; sleep 100) & child=$!; echo $child > \(pidURL.path); wait"
        _ = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", script]
        ))
        #expect(try await waitUntil(timeout: .seconds(5)) {
            FileManager.default.fileExists(atPath: pidURL.path)
        })
        let childPID = pid_t(Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!)

        server.stop()
        #expect(try await waitUntil(timeout: .seconds(5)) { kill(childPID, 0) != 0 })
    }

    @Test func deadSessionCanBeAttachedUntilRetired() async throws {
        let dir = try makeScratchDirectory()
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let exited = Locked(false)
        server.onSessionExited = { _, _ in exited.withValue { $0 = true } }
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "printf late-snapshot"]
        ))
        #expect(try await waitUntil { exited.current })

        let replay = try await server.attach(sessionID: info.id, replay: true)
        #expect(String(decoding: replay, as: UTF8.self).contains("late-snapshot"))

        await server.retireSession(sessionID: info.id)
        #expect(await server.listSessions().isEmpty)
        await server.retireSession(sessionID: info.id)
        do {
            _ = try await server.attach(sessionID: info.id, replay: true)
            Issue.record("expected retired session to reject attach")
        } catch let error as SessionServerError {
            guard case .noSuchSession = error else {
                Issue.record("expected noSuchSession, got \(error)")
                return
            }
        }
    }

    @Test func extensionSocketAndDirectoryUseOwnerOnlyPermissions() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let directoryMode = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        let socketMode = (try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber)?.intValue
        #expect(directoryMode.map { $0 & 0o777 } == 0o700)
        #expect(socketMode.map { $0 & 0o777 } == 0o600)
    }

    @Test func oversizedInboundFrameDisconnectsTheClient() throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let client = try ExtensionClient(path: socketPath)
        defer { client.closeConnection() }
        let oversized = Data(repeating: 0x78, count: NDJSON.maxPayloadBytes + 1)
        try? client.sendRaw(oversized)
        #expect(try client.waitForDisconnect(timeout: .seconds(10)))
    }

    /// The status extension socket: fire-and-forget reports update persisted
    /// agent status; the app learns via onAgentStatus.
    @Test func statusExtensionReportsOverSocket() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let space = Space(name: "s", path: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let agent = Agent(name: "a1", spaceID: space.id, tabID: tab.id, status: .idle)
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))

        let client = try ExtensionClient(path: socketPath)
        defer { client.closeConnection() }

        let reported = Locked<AgentStatus?>(nil)
        server.onAgentStatus = { _, status in reported.withValue { $0 = status } }

        // Exactly what Extensions/shepherd-status.ts writes.
        try client.send(.setAgentStatus(agentID: agent.id, status: .working))
        try await waitUntil { reported.current == .working }
        #expect(server.state.agents.first?.status == .working)

        // Reconnect: the extension reconnects with backoff; the server accepts
        // a fresh connection and keeps applying reports.
        client.closeConnection()
        let client2 = try ExtensionClient(path: socketPath)
        defer { client2.closeConnection() }
        try client2.send(.setAgentStatus(agentID: agent.id, status: .done))
        try await waitUntil { reported.current == .done }
        #expect(server.state.agents.first?.status == .done)

        // An unchanged report (what a reconnecting extension re-sends) still
        // reaches the app but does not rewrite state.json.
        let stateURL = dir.appendingPathComponent("state.json")
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date
        try await Task.sleep(for: .milliseconds(20))
        reported.withValue { $0 = nil }
        try client2.send(.setAgentStatus(agentID: agent.id, status: .done))
        try await waitUntil { reported.current == .done }
        let modifiedAfter = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.modificationDate] as? Date
        #expect(modifiedBefore == modifiedAfter)
    }

    /// The notify tool: fire-and-forget over the same socket; the app learns
    /// via onNotify. Nothing is persisted.
    @Test func notifyReportsOverSocket() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let client = try ExtensionClient(path: socketPath)
        defer { client.closeConnection() }

        let received = Locked<(AgentID, String, String)?>(nil)
        server.onNotify = { agentID, title, body in received.withValue { $0 = (agentID, title, body) } }

        let agentID = AgentID()
        // Exactly what the notify tool in Extensions/shepherd-panes.ts writes.
        try client.send(.notify(agentID: agentID, title: "CI passed", body: "PR #42 is green"))
        try await waitUntil { received.current != nil }
        let (id, title, body) = received.current!
        #expect(id == agentID)
        #expect(title == "CI passed")
        #expect(body == "PR #42 is green")
    }

    /// helloAgent registers a connection for pushes; pushMessage delivers an
    /// unsolicited message frame there, and reports unreachable agents.
    @Test func peerMessagePushesToRegisteredConnection() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let target = AgentID()
        // No registration yet: the push reports unreachable.
        #expect(server.pushMessage(toAgent: target, text: "hello") == false)

        let client = try ExtensionClient(path: socketPath)
        defer { client.closeConnection() }
        try client.send(.helloAgent(agentID: target))
        // Registration is fire-and-forget; poll until the server indexed it.
        try await waitUntil { server.pushMessage(toAgent: target, text: "[from: tester] ping") }

        // The pushed frame arrives as a normal NDJSON reply line.
        let pushed = try client.readReply()
        #expect(pushed == .message(id: 0, text: "[from: tester] ping"))

        // Disconnect deregisters: pushes report unreachable again.
        client.closeConnection()
        try await waitUntil { server.pushMessage(toAgent: target, text: "gone?") == false }
    }

    /// Agent-peer requests route to the GUI handler like pane requests, and
    /// blank sends are rejected before the handler runs.
    @Test func agentPeerRequestsRouteOverSocket() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let received = Locked<[AgentPeerRequest]>([])
        server.onAgentPeerRequest = { request, completion in
            received.withValue { $0.append(request) }
            switch request {
            case .list:
                completion(.agents([AgentPeerInfo(
                    id: AgentID(rawValue: "a2"), name: "worker", status: "working", cwd: "/tmp", isSelf: false
                )]))
            default:
                completion(.ok)
            }
        }

        let client = try ExtensionClient(path: socketPath)
        defer { client.closeConnection() }
        let sender = AgentID(rawValue: "a1")
        let target = AgentID(rawValue: "a2")

        try client.send(.listAgents(id: 1, agentID: sender))
        if case .agents(let id, let rows) = try client.readReply() {
            #expect(id == 1)
            #expect(rows.first?.name == "worker")
        } else {
            Issue.record("expected an agents reply")
        }

        try client.send(.sendToAgent(id: 2, agentID: sender, targetAgentID: target, text: "CI is green"))
        #expect(try client.readReply() == .ok(id: 2))
        if case .send(let from, let to, let text) = received.current.last {
            #expect(from == sender)
            #expect(to == target)
            #expect(text == "CI is green")
        } else {
            Issue.record("expected a send request")
        }

        // Blank text never reaches the handler.
        try client.send(.sendToAgent(id: 3, agentID: sender, targetAgentID: target, text: "  "))
        if case .error(let id, let code, _) = try client.readReply() {
            #expect(id == 3)
            #expect(code == "invalid")
        } else {
            Issue.record("expected an invalid reply for blank text")
        }
        #expect(received.current.count == 2)

        try client.send(.spawnAgent(id: 4, agentID: sender, cwd: "/tmp/repo", prompt: "do the thing"))
        #expect(try client.readReply() == .ok(id: 4))
    }

    /// createAutomation: request/reply from any pi session (the automation
    /// skill). The GUI handler persists + answers; without one it errors.
    @Test func createAutomationRoundTripsOverSocket() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let server = SessionServer(
            socketPath: socketPath,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        // No handler installed (headless): the request must error, not hang.
        let bare = try ExtensionClient(path: socketPath)
        try bare.send(.createAutomation(id: 1, name: "w", prompt: "p", cwd: "/tmp", enabled: true, start: false))
        if case .error(let id, let code, _) = try bare.readReply() {
            #expect(id == 1)
            #expect(code == "unsupported")
        } else {
            Issue.record("expected an error reply without a handler")
        }
        bare.closeConnection()

        // Handler installed: requests route through and answers relay.
        // Blank fields are rejected before the handler runs.
        let received = Locked<[AutomationRequest]>([])
        server.onAutomationRequest = { request, completion in
            received.withValue { $0.append(request) }
            switch request {
            case .list:
                completion(.automations([AutomationInfo(
                    id: AutomationID(rawValue: "au1"), name: "w", prompt: "p", cwd: "/tmp",
                    enabled: true, agentStatus: "working"
                )]))
            default:
                completion(.ok)
            }
        }
        let client = try ExtensionClient(path: socketPath)
        defer { client.closeConnection() }
        try client.send(.createAutomation(
            id: 2, name: " pr-watch ", prompt: "watch the PR", cwd: "/tmp/repo", enabled: true, start: false
        ))
        #expect(try client.readReply() == .ok(id: 2))
        if case .create(let automation, let start) = received.current.first {
            #expect(automation.name == "pr-watch")
            #expect(automation.cwd == "/tmp/repo")
            #expect(start == false)
        } else {
            Issue.record("expected a create request")
        }

        // The full management surface routes the same way.
        let automationID = AutomationID(rawValue: "au1")
        try client.send(.listAutomations(id: 10))
        if case .automations(let id, let rows) = try client.readReply() {
            #expect(id == 10)
            #expect(rows.first?.agentStatus == "working")
        } else {
            Issue.record("expected an automations reply")
        }
        try client.send(.updateAutomation(id: 11, automationID: automationID, name: nil, prompt: nil, cwd: nil, enabled: false))
        #expect(try client.readReply() == .ok(id: 11))
        try client.send(.startAutomation(id: 12, automationID: automationID))
        #expect(try client.readReply() == .ok(id: 12))
        try client.send(.stopAutomation(id: 13, automationID: automationID))
        #expect(try client.readReply() == .ok(id: 13))
        try client.send(.deleteAutomation(id: 14, automationID: automationID))
        #expect(try client.readReply() == .ok(id: 14))
        #expect(received.current.count == 6)

        try client.send(.createAutomation(id: 3, name: "", prompt: "p", cwd: "/tmp", enabled: true, start: true))
        if case .error(let id, let code, _) = try client.readReply() {
            #expect(id == 3)
            #expect(code == "invalid")
        } else {
            Issue.record("expected an invalid reply for a blank name")
        }
    }

    /// start() clears stale statuses from the previous run (sessions died with
    /// the app) and refuses to bind over a live socket.
    @Test func startResetsStaleStatusesAndRefusesLiveSocket() async throws {
        let dir = try makeScratchDirectory()
        let socketPath = dir.appendingPathComponent("d.sock").path
        let stateURL = dir.appendingPathComponent("state.json")

        // Pre-seed state with a stale "working" agent.
        let space = Space(name: "s", path: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let agent = Agent(name: "a1", spaceID: space.id, tabID: tab.id, status: .working)
        let state = ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(encoder.encode(state)).write(to: stateURL)

        let server = SessionServer(socketPath: socketPath, stateURL: stateURL)
        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(server.state.agents.first?.status == .idle)

        // A second server cannot bind the same socket while the first lives.
        let second = SessionServer(socketPath: socketPath, stateURL: stateURL)
        do {
            try second.start()
            Issue.record("expected bind failure on live socket")
        } catch {}
    }
}
