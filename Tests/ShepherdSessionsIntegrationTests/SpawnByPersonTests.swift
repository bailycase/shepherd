import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// What agent_spawn reads while Threads can start threads is off (`SessionServer.spawnByPerson`): whether the latest message
/// a thread was handed came from a person's send.
@Suite("agent_spawn's person check", .integrationTimeLimit)
struct SpawnByPersonTests {
    @Test func aPersonsSendMarksTheTurnAndAnAgentsMessageUnmarksIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        let id = pi.agent.id
        // Nothing handed to it yet: a thread the person started.
        #expect(try await h.server.enqueue { h.server.spawnByPerson(id) })
        // An agent's message (another thread's task, a Fleet result) leaves it unmarked...
        _ = try await pi.thread { $0.lastInputFromPerson = false }
        #expect(try await h.server.enqueue { !h.server.spawnByPerson(id) })
        // ...until the person sends.
        _ = try await pi.send("Open a thread to split the UI tests.", from: ready)
        #expect(try await h.server.enqueue { h.server.spawnByPerson(id) })
    }
}
