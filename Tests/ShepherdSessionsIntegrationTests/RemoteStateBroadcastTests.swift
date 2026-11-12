import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The workspace as a client that lists no capabilities is sent it: no designs, Project
/// coordinators, executions or missions, and only the thinking levels it can decode.
private func view(_ state: ShepherdState) -> ShepherdState {
    let shown = state.withoutDesigns.withoutProjectCoordinators.withoutProjectExecutions.withoutMissions
    return shown.usesOnlyLegacyThinkingLevels ? shown : shown.legacyThinkingLevels()
}

private func working(_ state: ShepherdState) -> Int { state.agents.filter { $0.status == .working }.count }

/// How often the host encodes and sends the whole workspace to a client: once for what one
/// server-queue turn changed, not once per change. Counts, never timings.
@Suite("Remote state broadcast", .integrationTimeLimit)
struct RemoteStateBroadcastTests {
    private struct Rig {
        let remote: RemoteHost
        let agents: [AgentID]
        let client: RawRemote
        let reporter: ExtensionClient

        init(agents count: Int) async throws {
            remote = try RemoteHost()
            let space = Fixture.space()
            let fixtures = (0..<count).map { Fixture.agent(in: space, name: "agent-\($0)") }
            try await remote.host.seed(Fixture.workspace(fixtures, space: space))
            agents = fixtures.map(\.agent.id)
            client = try await remote.raw()
            reporter = try ExtensionClient(path: remote.host.socketPath)
        }

        var encoded: Int { remote.server.encodedStateFrames }

        func line(_ index: Int) throws -> Data {
            try NDJSON.encode(ExtensionMessage.setAgentStatus(agentID: agents[index], status: .working))
        }

        /// Every state the client is pushed up to the one that satisfies `last`, and any still on
        /// the way: the reply to a state fetch follows each push made before it.
        func pushes(until last: (ShepherdState) -> Bool) async throws -> [ShepherdState] {
            let first = try await client.frames(until: { reply in
                if case .stateChanged(let state) = reply { return last(state) }
                return false
            })
            try client.send(.stateFetch(id: 900))
            let rest = try await client.frames(until: { reply in
                if case .state(900, _) = reply { return true }
                return false
            })
            return (first + rest).compactMap { reply in
                if case .stateChanged(let state) = reply { return state }
                return nil
            }
        }

        func stop() { remote.stop() }
    }

    @Test func aBurstOfStatusReportsEncodesTheWorkspaceOnce() async throws {
        let rig = try await Rig(agents: 32)
        defer { rig.stop() }
        let before = rig.encoded
        // One write: the host reads every line in one turn of its queue.
        try rig.reporter.sendRaw(try (0..<32).reduce(into: Data()) { $0.append(try rig.line($1)) })
        let pushes = try await rig.pushes(until: { working($0) == 32 })

        let encoded = rig.encoded - before
        #expect((1...2).contains(encoded), "32 reports in one turn encoded the workspace \(encoded) times")
        #expect((1...2).contains(pushes.count), "32 reports in one turn sent \(pushes.count) frames")
        #expect(pushes.last == view(rig.remote.server.state))
    }

    @Test func aStreamOfSeparateReportsNeverSendsAnOlderStateAfterANewerOne() async throws {
        let rig = try await Rig(agents: 32)
        defer { rig.stop() }
        let before = rig.encoded
        for index in rig.agents.indices { try rig.reporter.send(.setAgentStatus(agentID: rig.agents[index], status: .working)) }
        let pushes = try await rig.pushes(until: { working($0) == 32 })

        let counts = pushes.map(working)
        #expect(counts == counts.sorted(), "an older state followed a newer one: \(counts)")
        #expect(counts.last == 32)
        #expect(pushes.last == view(rig.remote.server.state))
        #expect(rig.encoded - before <= 32)
    }

    /// Turns that were already waiting behind a busy queue share the encode: the push goes out
    /// when the backlog is cleared, not after each of its turns.
    @Test func aBacklogOfTurnsEncodesTheWorkspaceOnce() async throws {
        let rig = try await Rig(agents: 32)
        defer { rig.stop() }
        let server = rig.remote.server
        let held = Locked(false), gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        server.queue.async { held.withValue { $0 = true }; gate.wait() }
        try await eventually("the server queue to be held") { held.current }
        let before = rig.encoded
        for agent in rig.agents {
            server.queue.async {
                try? server.mutateState { state in
                    if let index = state.agents.firstIndex(where: { $0.id == agent }) { state.agents[index].status = .working }
                }
            }
        }
        gate.signal()
        let pushes = try await rig.pushes(until: { working($0) == 32 })

        let encoded = rig.encoded - before
        #expect((1...2).contains(encoded), "32 turns in one backlog encoded the workspace \(encoded) times")
        #expect((1...2).contains(pushes.count), "32 turns in one backlog sent \(pushes.count) frames")
        #expect(pushes.last == view(server.state))
    }

    @Test func anIsolatedChangeStillArrives() async throws {
        let rig = try await Rig(agents: 3)
        defer { rig.stop() }
        let before = rig.encoded
        try rig.reporter.send(.setAgentStatus(agentID: rig.agents[1], status: .working))
        let pushes = try await rig.pushes(until: { working($0) == 1 })

        #expect(pushes.count == 1)
        #expect(rig.encoded - before == 1)
        #expect(pushes.last == view(rig.remote.server.state))
    }

    /// A paired device and this Mac's app are two views of the one workspace: a burst encodes
    /// each once.
    @Test func aBurstEncodesOncePerViewAcrossTheLocalAppAndAPairedDevice() async throws {
        let rig = try await Rig(agents: 32)
        defer { rig.stop() }
        let socket = rig.remote.host.dir.appendingPathComponent("h.sock").path
        try rig.remote.server.startLocalListener(path: socket, tokenURL: rig.remote.host.dir.appendingPathComponent("remote-token"))
        let app = RemoteHostClient(localSocket: socket)
        defer { app.disconnect() }
        let delivered = Locked<[Int]>([])
        app.onStateChanged = { state in delivered.withValue { $0.append(working(state)) } }
        _ = try await app.connect(host: "", port: 0, token: rig.remote.token, clientName: "Shepherd",
                                  capabilities: [RemoteProtocol.localThreadsCapability])

        let before = rig.encoded
        try rig.reporter.sendRaw(try (0..<32).reduce(into: Data()) { $0.append(try rig.line($1)) })
        let pushes = try await rig.pushes(until: { working($0) == 32 })
        try await eventually("the app to read the last state") { delivered.current.last == 32 }

        let encoded = rig.encoded - before
        #expect((2...4).contains(encoded), "two views of a 32-report burst encoded \(encoded) times")
        #expect((1...2).contains(pushes.count) && (1...2).contains(delivered.current.count),
                "frames sent: device \(pushes.count), app \(delivered.current.count)")
    }

    /// The reply to a request that changed the workspace follows the state that shows the change.
    @Test func aMutationsReplyFollowsItsState() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let folder = try makeScratchDirectory("project")
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = try await r.raw()
        try client.send(.addSpace(id: 1, path: folder.path))
        let frames = try await client.frames(until: { if case .spaceAdded = $0 { true } else { false } })

        guard case .spaceAdded(1, let spaceID) = try #require(frames.last) else { return }
        let shown = frames.firstIndex { reply in
            if case .stateChanged(let state) = reply { return state.spaces.contains { $0.id == spaceID } }
            return false
        }
        #expect(shown != nil && shown! < frames.count - 1, "the reply came before a state that shows its space")
    }

    /// A thread notice for the app, made in the turn that changed the workspace, comes after the state.
    @Test func aNoticeFollowsTheStateItWasMadeBehind() async throws {
        let rig = try await Rig(agents: 2)
        defer { rig.stop() }
        let socket = rig.remote.host.dir.appendingPathComponent("h.sock").path
        try rig.remote.server.startLocalListener(path: socket, tokenURL: rig.remote.host.dir.appendingPathComponent("remote-token"))
        let app = RemoteHostClient(localSocket: socket)
        defer { app.disconnect() }
        let events = Locked<[String]>([])
        app.onStateChanged = { state in events.withValue { $0.append("state \(working(state))") } }
        app.onThreadNotice = { _, message in events.withValue { $0.append(message) } }
        _ = try await app.connect(host: "", port: 0, token: rig.remote.token, clientName: "Shepherd",
                                  capabilities: [RemoteProtocol.localThreadsCapability])

        let server = rig.remote.server, agent = rig.agents[0]
        try await server.enqueue {
            try server.mutateState { state in
                if let index = state.agents.firstIndex(where: { $0.id == agent }) { state.agents[index].status = .working }
            }
            server.sendToLocalApps(.threadNotice(agentID: agent, message: "acme notice"))
        }
        try await eventually("the notice to reach the app") { events.current.contains("acme notice") }

        #expect(events.current.last == "acme notice")
        #expect(events.current.dropLast().last == "state 1", "events: \(events.current)")
    }
}
