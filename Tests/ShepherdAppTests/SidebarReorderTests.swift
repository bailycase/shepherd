import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
@testable import ShepherdApp

@Suite("Sidebar reordering", .serialized)
@MainActor
struct SidebarReorderTests {
    private struct Fixture {
        let dir: URL
        let server: SessionServer

        init() throws {
            dir = URL(fileURLWithPath: "/tmp/shepherd-reorder-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Two spaces, three agents in the first, one in the second.
    private func seed(on server: SessionServer) async throws -> (spaces: [Space], agents: [Agent]) {
        let s1 = Space(name: "one", path: "/tmp/one")
        let s2 = Space(name: "two", path: "/tmp/two")
        let tabs = [
            Tab(spaceID: s1.id, order: 0, layout: .leaf(LeafPane(cwd: s1.path))),
            Tab(spaceID: s2.id, order: 0, layout: .leaf(LeafPane(cwd: s2.path))),
        ]
        let a = Agent(name: "a", spaceID: s1.id, tabID: tabs[0].id)
        let b = Agent(name: "b", spaceID: s1.id, tabID: tabs[0].id)
        let c = Agent(name: "c", spaceID: s1.id, tabID: tabs[0].id)
        let d = Agent(name: "d", spaceID: s2.id, tabID: tabs[1].id)
        try await server.putState(ShepherdState(spaces: [s1, s2], tabs: tabs, agents: [a, b, c, d]))
        return ([s1, s2], [a, b, c, d])
    }

    @Test func agentDropReordersWithinSpaceAndPersists() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (_, agents) = try await seed(on: fixture.server)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 4 })

        // Drag c onto a: order becomes c, a, b.
        let accepted = vm.dropAgent(
            payload: ShepherdViewModel.dragPayload(agent: agents[2].id), on: agents[0].id
        )
        #expect(accepted)
        #expect(vm.state.agents.map(\.name) == ["c", "a", "b", "d"])
        // Persisted to the server too.
        #expect(await waitUntil { fixture.server.state.agents.map(\.name) == ["c", "a", "b", "d"] })
    }

    @Test func crossSpaceAgentDropIsRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (_, agents) = try await seed(on: fixture.server)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 4 })

        // d lives in space two; dropping it on a (space one) must not move it.
        let accepted = vm.dropAgent(
            payload: ShepherdViewModel.dragPayload(agent: agents[3].id), on: agents[0].id
        )
        #expect(!accepted)
        #expect(vm.state.agents.map(\.name) == ["a", "b", "c", "d"])
    }

    @Test func spaceDropReordersDeclarationOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (spaces, _) = try await seed(on: fixture.server)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.spaces.count == 2 })

        let accepted = vm.dropSpace(
            payload: ShepherdViewModel.dragPayload(space: spaces[1].id), on: spaces[0].id
        )
        #expect(accepted)
        #expect(vm.state.spaces.map(\.name) == ["two", "one"])
        #expect(await waitUntil { fixture.server.state.spaces.map(\.name) == ["two", "one"] })
    }

    @Test func selfAndGarbagePayloadsAreRejected() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (spaces, agents) = try await seed(on: fixture.server)
        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.agents.count == 4 })

        #expect(!vm.dropAgent(payload: ShepherdViewModel.dragPayload(agent: agents[0].id), on: agents[0].id))
        #expect(!vm.dropAgent(payload: "space:\(spaces[0].id.rawValue)", on: agents[0].id))
        #expect(!vm.dropAgent(payload: "garbage", on: agents[0].id))
        #expect(!vm.dropSpace(payload: "agent:whatever", on: spaces[0].id))
        #expect(vm.state.agents.map(\.name) == ["a", "b", "c", "d"])
        #expect(vm.state.spaces.map(\.name) == ["one", "two"])
    }
}
