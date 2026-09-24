import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A thread's availability while its pi starts: an agent whose pi is not serving yet is
/// `native_starting` (never an error), and one whose pi is gone is `native_unavailable` with
/// the reason. The stub's startup gate holds pi before it reads stdin, as a slow pi does.
@Suite("Native thread startup", .integrationTimeLimit)
struct ThreadStartupTests {
    private static let gate = "release-pi"

    private func code(_ body: () async throws -> NativeThreadResult) async -> String? {
        do { return try await body().failureCode } catch let error as RemoteHostClientError {
            if case .rejected(let code, _) = error { return code }
            return String(describing: error)
        } catch { return String(describing: error) }
    }

    /// The app adds an agent before it spawns and binds its pi, and a restored agent keeps
    /// the previous run's session in its pane until its pi respawns.
    @Test(arguments: [nil, SessionID()])
    func anAgentWhosePaneHasNoLivePiYetIsStarting(_ binding: SessionID?) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, sessionID: binding)
        try await h.seed(Fixture.workspace([worker], space: space))

        let error = await #expect(throws: RemoteHostClientError.self) {
            _ = try await h.server.nativeThread(agentID: worker.agent.id, request: .snapshot())
        }
        guard case .rejected(NativeThreadCode.starting, _)? = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func aPiThatHasNotAnsweredYetIsStartingUntilItServes() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_STARTUP_GATE": Self.gate])

        #expect(try await pi.request(.snapshot()) == .failure(code: NativeThreadCode.starting, message: "pi is starting."))
        #expect(try await pi.request(.snapshot()).failureCode == NativeThreadCode.starting, "still starting, not failed")

        FileManager.default.createFile(atPath: h.dir.appendingPathComponent(Self.gate).path, contents: nil)
        let ready = try await pi.ready()
        #expect(ready.piSessionID == "stub-session")
    }

    /// The server tells the app the moment an agent's pi serves its thread, once, whether the
    /// agent's pane was bound to that pi before it served or only after.
    @Test(arguments: [true, false])
    func theServerAnnouncesOnceWhenAnAgentsPiServes(boundBeforeServing: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let announced = Locked<[AgentID]>([])
        h.server.onNativeThreadServable = { id in announced.withValue { $0.append(id) } }
        let session = try await h.server.createSession(params: CreateSessionParams(
            cwd: h.dir.path, command: StubPi.command, env: ["STUB_PI_STARTUP_GATE": Self.gate], runtime: .rpc))
        let space = Space(name: "rpc", path: h.dir.path)
        try await h.server.addSpace(space)
        let pane = LeafPane(sessionID: session.id, cwd: h.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(name: "rpc", spaceID: space.id, tabID: tab.id, paneID: pane.id)

        if boundBeforeServing { try await h.server.addAgent(agent, withTab: tab) }
        FileManager.default.createFile(atPath: h.dir.appendingPathComponent(Self.gate).path, contents: nil)
        if !boundBeforeServing {
            try await eventually("the unbound pi to serve") { await h.server.threadServes(sessionID: session.id) }
            await drainMainQueue()
            #expect(announced.current.isEmpty, "nothing to announce until an agent is bound to it")
            try await h.server.addAgent(agent, withTab: tab)
        }

        try await eventually("the server to announce the agent's thread") { announced.current == [agent.id] }
        #expect(try await h.server.nativeThread(agentID: agent.id, request: .snapshot()).snapshotValue?.piSessionID == "stub-session")
        try await h.server.renameAgent(agent.id, to: "renamed")
        await drainMainQueue()
        #expect(announced.current == [agent.id], "announced once")
    }

    /// pi answers `get_state` before `get_messages`, and a long history takes a moment to
    /// arrive. A resumed thread served in between would show as a new, empty one.
    @Test func aResumedThreadIsStartingUntilItsHistoryHasArrived() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_HISTORY_BYTES": String(6 * 1024 * 1024)])

        var first: NativeThreadSnapshot?
        try await eventually("pi to serve its thread", timeout: .seconds(30)) {
            let answer = try await pi.request(.snapshot())
            first = answer.snapshotValue
            if first == nil { #expect(answer.failureCode == NativeThreadCode.starting) }
            return first != nil
        }
        let messages = try #require(first).messages
        #expect(messages.contains { $0.blocks.contains { $0.text == "seeded reply" } }, "the first snapshot carries the history")
    }

    /// A pi that exits while it starts (not installed, a broken config) is gone, with its exit
    /// code, before and after the app retires its session: never an endless start.
    @Test func aPiThatExitsWhileStartingIsUnavailableWithItsExitCode() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let callbacks = Callbacks(h.server)
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_STARTUP_EXIT": "127"])
        try await eventually("pi to exit") { callbacks.exited(pi.sessionID) }

        for retired in [false, true] {
            if retired { await h.server.retireSession(sessionID: pi.sessionID) }
            let error = await #expect(throws: RemoteHostClientError.self) { _ = try await pi.request(.snapshot()) }
            guard case .rejected(NativeThreadCode.unavailable, let message)? = error else {
                Issue.record("expected unavailable (retired: \(retired)), got \(String(describing: error))"); return
            }
            #expect(message.contains("code 127"))
        }
    }

    @Test func aRemovedAgentIsUnavailable() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        #expect(await code { try await h.server.nativeThread(agentID: AgentID(), request: .snapshot()) } == NativeThreadCode.unavailable)
    }

    /// Over TCP the host answers the same codes, and advertises that it does.
    @Test func aRemoteClientSeesStartingFromTheHost() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let pi = try await PiAgent.launch(on: r.host, env: ["STUB_PI_STARTUP_GATE": Self.gate])
        let space = try #require(r.server.state.spaces.first)
        let unbound = Fixture.agent(in: space)
        try await r.server.addAgent(unbound.agent, withTab: unbound.tab)
        let client = try await r.typed()
        defer { client.disconnect() }

        #expect(client.capabilities.contains(RemoteProtocol.nativeThreadStartingCapability))
        #expect(await code { try await client.nativeThread(agentID: unbound.agent.id, request: .snapshot()) } == NativeThreadCode.starting)
        #expect(await code { try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()) } == NativeThreadCode.starting)

        FileManager.default.createFile(atPath: r.host.dir.appendingPathComponent(Self.gate).path, contents: nil)
        try await eventually("the host's pi to serve the client") {
            try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue?.piSessionID == "stub-session"
        }
    }
}
