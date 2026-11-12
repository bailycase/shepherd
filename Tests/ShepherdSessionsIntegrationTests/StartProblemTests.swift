import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// An agent's pi that stops keeps its agent, before it serves its thread or on its own after: the
/// server says so with the exit, and the thread's snapshot says why, locally and to a remote
/// viewer, until Retry binds a new pi. Only deleting the agent retires it.
@Suite("pi start problems", .integrationTimeLimit)
struct StartProblemTests {
    private static let gate = "release-pi"

    private func code(_ body: () async throws -> NativeThreadResult) async -> String? {
        do { return try await body().failureCode } catch let error as RemoteHostClientError {
            if case .rejected(let code, _) = error { return code }
            return String(describing: error)
        } catch { return String(describing: error) }
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let env: [String: String]
        let resuming: String?
        let kind: NativeStartProblem.Kind
        let code: Int32?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "not signed in", env: [
            "STUB_PI_STARTUP_EXIT": "1",
            "STUB_PI_STARTUP_STDERR": "\u{1B}[31mNo models available. Use /login to log into a provider via OAuth or API key. See:\n  /pi/docs/providers.md\u{1B}[39m",
        ], resuming: nil, kind: .notSignedIn, code: 1),
        Case(name: "an extension failed to load", env: [
            "STUB_PI_STARTUP_EXIT": "1",
            "STUB_PI_STARTUP_STDERR": "\u{1B}[31mError: Failed to load extension \"/x/broken.ts\": SyntaxError: Unexpected token\u{1B}[39m\n\u{1B}[33mHint: Start without extensions using \"pi -ne\".\u{1B}[39m",
        ], resuming: nil, kind: .extensionFailed, code: 1),
        Case(name: "no pi to run", env: ["STUB_PI_STARTUP_EXIT": "127", "STUB_PI_STARTUP_STDERR": "zsh:1: command not found: pi"],
             resuming: nil, kind: .engineMissing, code: 127),
        Case(name: "creating a new session in place of the one it resumes", env: [
            "STUB_PI_STARTUP_NEW_SESSION": "1", "STUB_PI_STARTUP_EXIT": "1",
        ], resuming: "abc-123", kind: .resumedAsNew, code: nil),
    ]

    @Test(arguments: cases)
    func aPiThatStopsBeforeItServesKeepsItsAgentAndSaysWhy(_ c: Case) async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let callbacks = Callbacks(r.server)
        let pi = try await PiAgent.launch(on: r.host, env: c.env, resuming: c.resuming)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }

        let exit = try #require(callbacks.sessionExits.current[pi.sessionID])
        #expect(exit.keepsAgent)
        #expect(exit.startProblem?.kind == c.kind)
        if c.kind != .resumedAsNew { #expect(exit.code == c.code && exit.startProblem?.exitCode == c.code) }
        #expect(exit.startProblem?.lines.isEmpty == false)
        #expect(exit.startProblem?.lines.contains { $0.contains("\u{1B}") } == false)

        let client = try await r.typed()
        defer { client.disconnect() }
        // The app retires the dead session once it has handled the exit: the reason outlives it.
        for retired in [false, true] {
            if retired { await r.server.retireSession(sessionID: pi.sessionID) }
            let local = try await pi.request(.snapshot()).snapshotValue
            #expect(local?.startProblem == exit.startProblem, "retired: \(retired)")
            #expect(local?.messages.isEmpty == true && local?.supportedActions.isEmpty == true)
            let remote = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue
            #expect(remote?.startProblem == exit.startProblem, "a remote viewer sees it too (retired: \(retired))")
        }
        #expect(r.server.state.agents.contains { $0.id == pi.agent.id })
        let send = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "hi", delivery: .followUp)
        #expect(await code { try await pi.request(send) } == NativeThreadCode.unavailable)
    }

    /// pi goes on after its warning, as the real one does: Shepherd stops it before anything is
    /// written, and it never reads a thing.
    @Test func aResumedPiAboutToStartANewConversationIsStoppedFirst() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_STARTUP_NEW_SESSION": "1"], resuming: "abc-123")
        try await eventually("Shepherd to stop pi") { callbacks.exited(pi.sessionID) }
        let exit = try #require(callbacks.sessionExits.current[pi.sessionID])
        #expect(exit.keepsAgent && exit.startProblem?.kind == .resumedAsNew)
        #expect(exit.startProblem?.lines.last?.contains("'abc-123'") == true)
        #expect(pi.stdin("prompt").isEmpty)
    }

    /// A fresh agent's pi (nothing to resume) that warns the same goes on as today.
    @Test func aFreshPiThatWarnsGoesOn() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_STARTUP_NEW_SESSION": "1"])
        _ = try await pi.ready()
        #expect(!callbacks.exited(pi.sessionID))
    }

    /// Once pi has served, an exit on its own keeps the agent too: the thread says it stopped, with
    /// pi's last words, to this host and to a remote viewer, before and after the app retires the
    /// dead session.
    @Test func aPiThatExitsAfterItServedKeepsItsAgentAndSaysItStopped() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let callbacks = Callbacks(r.server)
        let pi = try await PiAgent.launch(on: r.host)
        let ready = try await pi.ready()
        _ = try await pi.send("die", from: ready)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }
        let stopped = NativeStartProblem(kind: .stopped, exitCode: 3, lines: ["stub-pi: dying"])
        #expect(callbacks.sessionExits.current[pi.sessionID] == SessionExit(code: 3, keepsAgent: true, startProblem: stopped))

        let client = try await r.typed()
        defer { client.disconnect() }
        for retired in [false, true] {
            if retired { await r.server.retireSession(sessionID: pi.sessionID) }
            let local = try await pi.request(.snapshot()).snapshotValue
            #expect(local?.startProblem == stopped, "retired: \(retired)")
            #expect(local?.messages.isEmpty == true && local?.supportedActions.isEmpty == true)
            let remote = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue
            #expect(remote?.startProblem == stopped, "a remote viewer sees it too (retired: \(retired))")
        }
        #expect(r.server.state.agents.contains { $0.id == pi.agent.id })
        let send = NativeThreadRequest.send(expectedSessionID: "s", generation: "g", operationID: UUID(), text: "hi", delivery: .followUp)
        #expect(await code { try await pi.request(send) } == NativeThreadCode.unavailable)
    }

    /// A viewer that reads previews (`nativeThreadPreviewCapability`) is shown a stopped agent's
    /// conversation under its problem, read from pi's session file with no pi running, and with no
    /// actions; a viewer that does not read previews gets the problem alone, as before. Before and
    /// after the app retires the dead session, and without asking for pi to be started.
    @Test func aStoppedAgentsHistoryGoesToAViewerThatReadsPreviews() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let demanded = Locked<[AgentID]>([])
        r.server.onNativeThreadDemand = { id in demanded.withValue { $0.append(id) } }
        let callbacks = Callbacks(r.server)
        let pi = try await PiAgent.launch(on: r.host)
        let ready = try await pi.ready()
        _ = try await pi.send("die", from: ready)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }
        let stopped = NativeStartProblem(kind: .stopped, exitCode: 3, lines: ["stub-pi: dying"])

        // pi's file for the agent's session, as the stopped pi left it.
        let sessionID = try #require(r.server.state.agents.first { $0.id == pi.agent.id }).effectivePiSessionID
        let cwd = r.host.dir.path
        let folder = r.server.pi.sessionsRoot.appendingPathComponent(PiSessionFolder.name(forCwd: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"2026-09-24T00:00:00.000Z","cwd":"\#(cwd)"}"#,
            #"{"type":"message","id":"e0","parentId":null,"timestamp":"2026-09-24T00:00:00.000Z","message":{"role":"user","content":"hello there","timestamp":1000}}"#,
            #"{"type":"message","id":"e1","parentId":"e0","timestamp":"2026-09-24T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"provider":"anthropic","model":"claude-x","stopReason":"stop","timestamp":2000}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("2026-09-24T00-00-00-000Z_\(sessionID).jsonl"))

        let previewing = try await r.typed(capabilities: RemoteProtocol.clientCapabilities + [RemoteProtocol.nativeThreadPreviewCapability])
        defer { previewing.disconnect() }
        let plain = try await r.typed()
        defer { plain.disconnect() }
        for retired in [false, true] {
            if retired { await r.server.retireSession(sessionID: pi.sessionID) }
            let history = try await previewing.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue
            #expect(history?.messages.map { $0.blocks.first?.text } == ["hello there", "hi"], "retired: \(retired)")
            #expect(history?.startProblem == stopped && history?.isPreview == true, "retired: \(retired)")
            #expect(history?.supportedActions.isEmpty == true && history?.running == false)
            #expect(history?.piSessionID == sessionID)

            let bare = try await plain.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue
            #expect(bare?.startProblem == stopped && bare?.messages.isEmpty == true && bare?.isPreview == false, "retired: \(retired)")
        }
        #expect(demanded.current.isEmpty, "reading a stopped thread starts no pi")
        #expect(r.server.state.agents.contains { $0.id == pi.agent.id })
        let send = NativeThreadRequest.send(expectedSessionID: sessionID, generation: "g", operationID: UUID(), text: "hi", delivery: .followUp)
        #expect(await code { try await previewing.nativeThread(agentID: pi.agent.id, request: send) } == NativeThreadCode.unavailable)
    }

    /// A pi killed by a signal says which, once it has served.
    @Test func aServedPiEndedByASignalSaysWhichSignal() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        let pid = try await h.server.enqueue { try #require(h.server.rpcThread(forAgent: pi.agent.id)).session.processIdentifier }
        #expect(kill(pid, SIGKILL) == 0)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }
        let exit = try #require(callbacks.sessionExits.current[pi.sessionID])
        #expect(exit == SessionExit(code: nil, keepsAgent: true, startProblem: NativeStartProblem(kind: .stopped, signal: 9)))
        #expect(try await pi.request(.snapshot()).snapshotValue?.startProblem == exit.startProblem)
    }

    /// A status report the dead pi's socket still held, read after its agent settled idle, leaves the
    /// agent idle: it would otherwise read as running and hold the host's drain.
    @Test func aLateStatusFromAStoppedPiLeavesItsAgentIdle() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let other = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        _ = try await other.ready()
        let pid = try await h.server.enqueue { try #require(h.server.rpcThread(forAgent: pi.agent.id)).session.processIdentifier }
        #expect(kill(pid, SIGKILL) == 0)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }
        func status(_ agent: Agent) -> AgentStatus? { h.server.state.agents.first { $0.id == agent.id }?.status }

        // The second report is the barrier: one connection is read in order.
        let reporter = try ExtensionClient(path: h.socketPath)
        defer { reporter.closeConnection() }
        try reporter.send(.setAgentStatus(agentID: pi.agent.id, status: .working))
        try reporter.send(.setAgentStatus(agentID: other.agent.id, status: .working))
        try await eventually("the other agent to read working") { status(other.agent) == .working }
        #expect(status(pi.agent) == .idle)
        #expect(try await pi.request(.snapshot()).snapshotValue?.startProblem?.kind == .stopped)
    }

    /// Deleting the agent retires its pi: the agent is gone from state when pi exits, so nothing is kept.
    @Test func deletingAnAgentWhosePiServedRetiresItsSession() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        try await h.server.deleteAgent(pi.agent.id)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }
        let exit = try #require(callbacks.sessionExits.current[pi.sessionID])
        #expect(!exit.keepsAgent && exit.startProblem == nil)
        #expect(!h.server.state.agents.contains { $0.id == pi.agent.id })
    }

    /// A stop Shepherd asks for keeps the agent, with nothing to report: its thread is starting.
    /// `killSession` of an agent's own pi is one (a halted mission's threads stay).
    @Test(arguments: [false, true])
    func aStopShepherdAsksForKeepsTheAgentWithoutAProblem(killed: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        if killed { h.server.killSession(pi.sessionID) } else { await h.server.stopKeepingAgent(sessionID: pi.sessionID) }
        try await eventually("pi to stop") { callbacks.exited(pi.sessionID) }
        let exit = try #require(callbacks.sessionExits.current[pi.sessionID])
        #expect(exit.keepsAgent && exit.startProblem == nil)
        #expect(await code { try await pi.request(.snapshot()) } == NativeThreadCode.starting)
    }

    /// Retry: the thread is starting until the new pi is bound, and a new agent's opening prompt,
    /// which the stopped pi never read, goes to the new one.
    @Test func retryStartsAgainWithTheUnreadOpeningPrompt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let broken = try await PiAgent.launch(on: h, env: ["STUB_PI_STARTUP_GATE": Self.gate, "STUB_PI_STARTUP_EXIT": "1",
                                                           "STUB_PI_STARTUP_STDERR": "No models available."])
        let prompt = try #require(OpeningPrompt("Fix the login redirect", agentID: broken.agent.id))
        await h.server.sendOpeningPrompt(prompt, sessionID: broken.sessionID)
        FileManager.default.createFile(atPath: h.dir.appendingPathComponent(Self.gate).path, contents: nil)
        try await eventually("pi to exit") { callbacks.exited(broken.sessionID) }
        #expect(try await broken.request(.snapshot()).snapshotValue?.startProblem?.kind == .notSignedIn)
        await h.server.retireSession(sessionID: broken.sessionID)

        await h.server.retryStart(sessionID: broken.sessionID)
        #expect(await code { try await broken.request(.snapshot()) } == NativeThreadCode.starting)
        try FileManager.default.removeItem(at: h.dir.appendingPathComponent(Self.gate))

        let log = h.dir.appendingPathComponent("retry.log")
        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: h.dir.path, command: StubPi.command, env: ["STUB_PI_LOG": log.path], runtime: .rpc))
        try await h.server.updatePaneSession(tabID: broken.agent.tabID, paneID: try #require(broken.agent.paneID), sessionID: info.id)
        let retried = PiAgent(host: h, agent: broken.agent, sessionID: info.id, log: log)
        let sent = try await retried.waitForStdin("prompt")
        #expect(sent["message"] as? String == "Fix the login redirect")
        let snapshot = try await retried.snapshot("the new pi to serve") { $0.startProblem == nil && !$0.piSessionID.isEmpty }
        #expect(snapshot.generation != SessionServer.startProblemGeneration)
    }
}
