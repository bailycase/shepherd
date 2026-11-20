import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdSessions

/// What the local app's client says of the workspace pushes waiting for the main thread: the app adopts
/// only the newest of a burst, and learns from `newerStateQueued` which one that is.
@Suite("State push queue", .mainActorExclusive)
@MainActor
struct StatePushQueueTests {
    private struct Rig {
        let scratch: ScratchServer
        let client: RemoteHostClient
        let reporter: ExtensionClient
        let agents: [AgentID]
        /// Each push the client delivered: how many agents it shows working, and whether a newer push was queued.
        let delivered = Locked<[(working: Int, newerQueued: Bool)]>([])

        func report(_ index: Int) throws {
            try reporter.send(.setAgentStatus(agentID: agents[index], status: .working))
        }
    }

    private func rig(agents count: Int) async throws -> Rig {
        let scratch = try ScratchServer.fresh()
        let space = Fixture.space()
        let fixtures = (0..<count).map { Fixture.agent(in: space, name: "agent-\($0)") }
        try await scratch.seed(Fixture.workspace(fixtures, space: space))
        let socket = scratch.dir.appendingPathComponent("h.sock").path
        let tokenURL = scratch.dir.appendingPathComponent("remote-token")
        try scratch.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let port = try scratch.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(localSocket: socket)
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "Shepherd",
                                     capabilities: [RemoteProtocol.localThreadsCapability])
        let rig = Rig(scratch: scratch, client: client, reporter: try ExtensionClient(path: scratch.socketPath),
                      agents: fixtures.map(\.agent.id))
        let delivered = rig.delivered
        client.onStateChanged = { [unowned client] state in
            let working = state.agents.filter { $0.status == .working }.count
            delivered.withValue { $0.append((working, client.newerStateQueued)) }
        }
        return rig
    }

    @Test func aPushWithNewerOnesQueuedBehindItReadsAsNotTheNewest() async throws {
        let rig = try await rig(agents: 6)
        defer { rig.client.disconnect(); rig.scratch.stop() }

        // A thread notice between two states keeps the client from replacing the first with the second.
        // Every push waits behind the busy main thread, so the whole stream is queued at once.
        for index in rig.agents.indices {
            try rig.report(index)
            try holdingMain(until: "state \(index + 1) to reach the client") { rig.client.queuedStateEvents >= index + 1 }
            rig.scratch.server.noticeToLocalApps(agentID: rig.agents[index], message: "acme notice")
        }
        #expect(rig.client.queuedStateEvents == 6)
        #expect(rig.client.newerStateQueued)

        try await eventuallyOnMain("all six pushes to be delivered") { rig.delivered.current.count == 6 }
        #expect(rig.delivered.current.map(\.working) == [1, 2, 3, 4, 5, 6], "every push is delivered, in order")
        #expect(rig.delivered.current.map(\.newerQueued) == [true, true, true, true, true, false])
        #expect(rig.client.queuedStateEvents == 0)
        #expect(!rig.client.newerStateQueued)
    }

    @Test func pushesAClientReplacedLeaveNothingCountedOnceTheyAreDelivered() async throws {
        let rig = try await rig(agents: 6)
        defer { rig.client.disconnect(); rig.scratch.stop() }

        // No event between them: a state still waiting is replaced by the next one, however many arrive.
        for index in rig.agents.indices { try rig.report(index) }
        let server = rig.scratch.server
        try holdingMain(until: "the host to apply every report") { server.state.agents.allSatisfy { $0.status == .working } }

        try await eventuallyOnMain("the newest push to be delivered") { rig.delivered.current.last?.working == 6 }
        try await eventuallyOnMain("the queue to empty") { rig.client.queuedStateEvents == 0 }
        #expect(rig.delivered.current.last?.newerQueued == false)
        #expect(rig.delivered.current.count <= 6)
    }
}
