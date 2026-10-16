import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Thread moves", .integrationTimeLimit)
struct ThreadMoveTests {
    private func destination(_ h: ScratchServer, parent: SpaceID? = nil) async throws -> Space {
        let directory = h.dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let space = Space(name: "Destination", path: directory.path, parentID: parent, parentIsExplicit: true)
        try await h.server.addSpace(space)
        return space
    }

    private func ready(_ pi: PiAgent) async throws -> NativeThreadSnapshot {
        let snapshot = try await pi.ready()
        var agent = try #require(pi.server.state.agents.first { $0.id == pi.agent.id })
        agent.piSessionID = snapshot.piSessionID
        try await pi.server.updateAgent(agent)
        return snapshot
    }

    private func seed(_ h: ScratchServer, agent: Agent, cwd: String) throws -> (URL, Data) {
        let directory = h.server.pi.sessionsRoot.appendingPathComponent(PiSessionFolder.name(forCwd: cwd))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test_\(agent.effectivePiSessionID).jsonl")
        let header: [String: Any] = ["type": "session", "id": agent.effectivePiSessionID, "version": 3, "cwd": cwd]
        let body = Data("\n{\"type\":\"message\",\"id\":\"entry-1\",\"message\":{\"role\":\"user\",\"content\":\"Keep my conversation\"}}\n".utf8)
        try (JSONSerialization.data(withJSONObject: header) + body).write(to: url)
        return (url, body)
    }

    @Test func anIdleThreadMovesBetweenParentAndChildAndKeepsItsConversation() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let source = try #require(h.server.state.spaces.first)
        let child = try await destination(h, parent: source.id)
        let agent = try #require(h.server.state.agents.first)
        let (file, body) = try seed(h, agent: agent, cwd: source.path)
        try await h.server.moveThread(agent.id, to: child.id)
        #expect(h.server.state.agents.first?.spaceID == child.id)
        #expect(h.server.state.tabs.first?.spaceID == child.id)
        #expect(h.server.state.tabs.first?.layout.firstLeaf.cwd == PiSessionFolder.realPath(child.path))
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == false)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let moved = h.server.pi.sessionsRoot.appendingPathComponent(PiSessionFolder.name(forCwd: child.path)).appendingPathComponent(file.lastPathComponent)
        let data = try Data(contentsOf: moved)
        #expect(data.suffix(body.count) == body)
        let header = try #require(try JSONSerialization.jsonObject(with: data.prefix { $0 != 10 }) as? [String: Any])
        #expect(header["cwd"] as? String == PiSessionFolder.realPath(child.path))
        #expect(header["id"] as? String == agent.effectivePiSessionID)
        try await h.server.moveThread(agent.id, to: source.id)
        #expect(h.server.state.agents.first?.id == agent.id)
        #expect(h.server.state.agents.first?.spaceID == source.id)
        #expect(try Data(contentsOf: file).suffix(body.count) == body)
    }

    @Test func activeTurnsAndQueuedMessagesAreRefusedWithoutStoppingPi() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await ready(pi)
        let space = try await destination(h)
        _ = try await pi.send("slow", from: idle)
        let running = try await pi.snapshot { $0.running }
        _ = try await pi.send("next", from: running)
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: space.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
        #expect(h.server.state.agents.first?.spaceID == pi.agent.spaceID)
        let queued = try await pi.snapshot { $0.queue?.items.count == 1 }
        let message = try #require(queued.queue?.items.first?.id)
        _ = try await pi.queue(.hold(id: message, held: true), from: queued)
        pi.release(1)
        pi.release(2)
        _ = try await pi.snapshot { !$0.running && $0.queue?.items.count == 1 }
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: space.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true, "A held message blocks moving even after the turn is idle")
    }

    @Test func aBufferedPeerTaskPreventsMovingUntilItIsTrackedAndSettled() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        let agent = try #require(h.server.state.agents.first)
        _ = try seed(h, agent: agent, cwd: h.dir.path)
        let receiver = try ExtensionClient(path: h.socketPath)
        defer { receiver.closeConnection() }
        try receiver.send(.helloAgent(agentID: agent.id))
        try await eventually("peer connection registration") { h.server.pushMessage(toAgent: agent.id, text: "slow") }
        // Leave delivery unread on the separate socket. RPC reports idle but the message is not lost.
        #expect(try await pi.snapshot().running == false)
        do {
            try await h.server.moveThread(agent.id, to: space.id)
            Issue.record("Moved past a buffered peer task")
        } catch let error as ProjectFileError { #expect(error.code == "thread_active") }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
        guard case .message(let deliveryID, "slow", .task) = try receiver.readReply() else { Issue.record("Peer task lost"); return }
        let forged = try ExtensionClient(path: h.socketPath)
        defer { forged.closeConnection() }
        // Even the test's permissive process identity does not bypass exact connection ownership.
        try forged.send(.peerMessageReceived(agentID: agent.id, deliveryID: deliveryID))
        try forged.send(.listAgents(id: 999, agentID: agent.id))
        _ = try forged.readReply()
        #expect(pi.stdin("prompt").isEmpty)
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(agent.id, to: space.id) }
        try receiver.send(.peerMessageReceived(agentID: agent.id, deliveryID: deliveryID))
        _ = try await pi.snapshot { $0.running }
        try receiver.send(.peerMessageReceived(agentID: agent.id, deliveryID: deliveryID)) // duplicate is inert
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(agent.id, to: space.id) }
        #expect(pi.stdin("prompt").count == 1)
        pi.release(1); pi.release(2)
        _ = try await pi.snapshot { !$0.running && $0.queue?.items.isEmpty != false }
        try await eventually("the delivered peer turn and its capture to settle") {
            do { return try await h.server.moveThread(agent.id, to: space.id) }
            catch let error as ProjectFileError where error.code == "thread_active" { return false }
        }
    }

    @Test func aPendingReportStaysFencedAcrossDisconnectionUntilItsProcessExits() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        let receiver = try ExtensionClient(path: h.socketPath)
        try receiver.send(.helloAgent(agentID: pi.agent.id))
        try await eventually("peer report connection") { h.server.pushMessage(toAgent: pi.agent.id, text: "report", delivery: .report) }
        guard case .message(let deliveryID, _, .report) = try receiver.readReply() else { Issue.record("Report lost"); return }
        receiver.closeConnection()
        let replacement = try ExtensionClient(path: h.socketPath)
        defer { replacement.closeConnection() }
        try replacement.send(.helloAgent(agentID: pi.agent.id))
        try replacement.send(.peerMessageReceived(agentID: pi.agent.id, deliveryID: deliveryID))
        try replacement.send(.listAgents(id: 1000, agentID: pi.agent.id))
        _ = try replacement.readReply()
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: space.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }

    @Test func peerDeliveryAdmissionIsBoundedAndNeverExpiresIntoPermissionToMove() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let destination = try await destination(h)
        let receiver = try ExtensionClient(path: h.socketPath)
        defer { receiver.closeConnection() }
        try receiver.send(.helloAgent(agentID: pi.agent.id))
        try await eventually("peer registration") { h.server.pushMessage(toAgent: pi.agent.id, text: "report", delivery: .report) }
        for _ in 1..<64 { #expect(h.server.pushMessage(toAgent: pi.agent.id, text: "report", delivery: .report)) }
        #expect(!h.server.pushMessage(toAgent: pi.agent.id, text: "overflow", delivery: .report))
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: destination.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }

    @Test func missingFoldersAndWorktreesAreRefusedWithoutStoppingPi() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let missing = Space(name: "Missing", path: h.dir.appendingPathComponent("absent").path)
        try await h.server.addSpace(missing)
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: missing.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
        var agent = try #require(h.server.state.agents.first)
        agent.worktreePath = h.dir.path
        agent.worktreeBranch = "feature"
        try await h.server.updateAgent(agent)
        let space = try await destination(h)
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: space.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }

    @Test(arguments: ["running", "paused", "needsReply"])
    func unfinishedChildWorkPreventsMoving(state: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        let children = try ExtensionClient(path: h.socketPath)
        defer { children.closeConnection() }
        try children.send(.helloChildren(agentID: pi.agent.id))
        try children.send(.setAgentChildren(agentID: pi.agent.id, children: [ChildRun(runID: "child", label: "Child", state: state)]))
        _ = try await pi.snapshot { $0.subagents?.first?.state == state }
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: space.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }

    @Test func aWaitingQuestionPreventsMoving() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await ready(pi)
        let space = try await destination(h)
        _ = try await pi.send("ask", from: idle)
        _ = try await pi.snapshot { !$0.dialogs.isEmpty }
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(pi.agent.id, to: space.id) }
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }

    @Test func anExistingThreadWithoutItsConversationCannotSilentlyStartFresh() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        do {
            try await h.server.moveThread(pi.agent.id, to: space.id)
            Issue.record("A missing conversation was silently replaced")
        } catch let error as ProjectFileError { #expect(error.code == "missing_session") }
        #expect(h.server.state.agents.first?.spaceID == pi.agent.spaceID)
    }

    @Test func linkedConversationFilesAreRefusedWithoutTouchingTheirTarget() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        let agent = try #require(h.server.state.agents.first)
        let from = try #require(h.server.state.spaces.first { $0.id == agent.spaceID })
        let (original, _) = try seed(h, agent: agent, cwd: from.path)
        let saved = h.dir.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: original, to: saved)
        let bytes = try Data(contentsOf: saved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: saved)
        do {
            try await h.server.moveThread(agent.id, to: space.id)
            Issue.record("A linked conversation was moved")
        } catch let error as ProjectFileError { #expect(error.code == "unsafe_session") }
        #expect(try Data(contentsOf: saved) == bytes)
        #expect(h.server.state.agents.first?.spaceID == from.id)
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }

    @Test func persistenceFailureKeepsTheOriginalConversationAndRollsBackTheCopy() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        let agent = try #require(h.server.state.agents.first)
        let from = try #require(h.server.state.spaces.first { $0.id == agent.spaceID })
        let (original, _) = try seed(h, agent: agent, cwd: from.path)
        let bytes = try Data(contentsOf: original)
        try FileManager.default.removeItem(at: h.stateURL)
        try FileManager.default.createDirectory(at: h.stateURL, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await h.server.moveThread(agent.id, to: space.id) }
        #expect(h.server.state.agents.first?.spaceID == from.id)
        #expect(try Data(contentsOf: original) == bytes)
        let copied = h.server.pi.sessionsRoot.appendingPathComponent(PiSessionFolder.name(forCwd: space.path)).appendingPathComponent(original.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: copied.path))
    }

    @Test(.enabled(if: EngineSmoke.engine != nil, "set SHEPHERD_ENGINE_SMOKE to a staged engine"))
    func theRealEngineResumesHistoryAndLoadsDestinationInstructions() async throws {
        let engine = try #require(EngineSmoke.engine)
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let source = h.dir.appendingPathComponent("source"), target = h.dir.appendingPathComponent("target")
        let home = h.dir.appendingPathComponent("engine-home")
        for directory in [source, target, home] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try "SourceContextMarkerOnly".write(to: source.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "DestinationContextMarkerOnly".write(to: target.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let report = h.dir.appendingPathComponent("context.txt")
        let probe = h.dir.appendingPathComponent("probe.mjs")
        try "import fs from 'node:fs'; export default function(pi) { pi.registerCommand('inspect-context', { handler: async (_, ctx) => fs.writeFileSync(\(String(reflecting: report.path)), ctx.getSystemPrompt()) }); }".write(to: probe, atomically: true, encoding: .utf8)
        let id = UUID().uuidString
        let root = home.appendingPathComponent("sessions")
        let directory = root.appendingPathComponent(PiSessionFolder.name(forCwd: source.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("2026-01-01T00-00-00-000Z_\(id).jsonl")
        let header: [String: Any] = ["type": "session", "version": 3, "id": id, "cwd": source.path, "timestamp": "2026-01-01T00:00:00.000Z"]
        let message: [String: Any] = ["type": "message", "id": "m1", "parentId": NSNull(), "timestamp": "2026-01-01T00:00:01.000Z", "message": ["role": "user", "content": "Keep this conversation", "timestamp": 1767225601000]]
        try (JSONSerialization.data(withJSONObject: header) + Data([10]) + JSONSerialization.data(withJSONObject: message) + Data([10])).write(to: file)
        let environment = ["HOME": home.path, "TMPDIR": h.dir.path, "PATH": "/usr/bin:/bin", "PI_CODING_AGENT_DIR": home.path, "PI_OFFLINE": "1"]
        func launch(_ cwd: URL) throws -> RPCProcess {
            try RPCProcess(executable: engine.node.path, arguments: [engine.entry.path, "--mode", "rpc", "--approve", "--session-id", id,
                           "--session-dir", root.appendingPathComponent(PiSessionFolder.name(forCwd: cwd.path)).path, "-e", probe.path],
                           directory: cwd, environment: environment)
        }
        let original = try launch(source)
        defer { original.stop() }
        #expect(try await original.request(["type": "get_state"])["success"] as? Bool == true)
        _ = try await original.request(["type": "prompt", "message": "/inspect-context"])
        #expect(try String(contentsOf: report, encoding: .utf8).contains("SourceContextMarkerOnly"))
        let before = try await original.request(["type": "get_messages"])
        #expect(try await original.finish() == 0)
        let move = try #require(try ThreadSessionMove.prepare(sessionID: id, from: source.path, to: target.path, root: root))
        try move.finish()
        let resumed = try launch(target)
        defer { resumed.stop() }
        #expect(try await resumed.request(["type": "get_state"])["success"] as? Bool == true)
        _ = try await resumed.request(["type": "prompt", "message": "/inspect-context"])
        let prompt = try String(contentsOf: report, encoding: .utf8)
        #expect(prompt.contains("DestinationContextMarkerOnly"))
        #expect(!prompt.contains("SourceContextMarkerOnly"))
        let after = try await resumed.request(["type": "get_messages"])
        #expect(NSDictionary(dictionary: try #require(before["data"] as? [String: Any])) == NSDictionary(dictionary: try #require(after["data"] as? [String: Any])))
        #expect(try await resumed.finish() == 0)
    }

    @Test func aConflictingConversationIsNeverOverwritten() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await ready(pi)
        let space = try await destination(h)
        let agent = try #require(h.server.state.agents.first)
        let from = try #require(h.server.state.spaces.first { $0.id == agent.spaceID })
        let (original, _) = try seed(h, agent: agent, cwd: from.path)
        let (conflict, _) = try seed(h, agent: agent, cwd: space.path)
        let originalBytes = try Data(contentsOf: original), conflictBytes = try Data(contentsOf: conflict)
        await #expect(throws: ProjectFileError.self) { try await h.server.moveThread(agent.id, to: space.id) }
        #expect(try Data(contentsOf: original) == originalBytes)
        #expect(try Data(contentsOf: conflict) == conflictBytes)
        #expect(h.server.state.agents.first?.spaceID == from.id)
        #expect(await h.server.sessionInfo(sessionID: pi.sessionID)?.isAlive == true)
    }
}
