import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A pi that stops before it serves its thread keeps its agent (DESIGN.md › Thread › Can't
/// start): the server says so with the exit, and the thread's snapshot says why, locally and to
/// a remote viewer, until Retry binds a new pi. A pi that served and then exited does not.
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

    /// Once pi has served, its exit is a lost connection: the app retires the agent as before.
    @Test func aPiThatExitsAfterItServedDoesNotKeepItsAgent() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        _ = try await pi.send("die", from: ready)
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }
        #expect(callbacks.sessionExits.current[pi.sessionID] == SessionExit(code: 3))
    }

    /// A stop Shepherd asks for keeps the agent, with nothing to report: its thread is starting.
    @Test func aStopShepherdAsksForKeepsTheAgentWithoutAProblem() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.ready()
        await h.server.stopKeepingAgent(sessionID: pi.sessionID)
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
