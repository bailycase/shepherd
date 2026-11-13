import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// How this app holds Macs now that Fleet is how they connect: one connection to each Mac its host has paired, on a token of its own, and
/// a Mac it was a client of before is a row to add to the fleet, not a connection.
@Suite("Fleet connections", .mainActorExclusive)
@MainActor
struct FleetConnectionsFlowTests {
    typealias FleetApp = FleetSettingsFlowTests.FleetApp

    @Test func theAppConnectsToEachMacOfTheFleetOnATokenOfItsOwnAndDropsOneThatLeaves() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        let store = RemoteHostStore(defaults: ScratchDefaults())
        defer { for connection in store.allConnections { store.removeHost(id: connection.id) } }
        let connections = FleetConnections(hosts: store, fleet: a.model)
        a.model.onSnapshot = { connections.snapshotChanged($0) }
        #expect(store.pairedConnections.isEmpty, "a Mac that is in no fleet is connected to nothing")

        await b.model.startJoin()
        #expect(await a.model.pair(with: b.found, code: try #require(b.model.join?.code)))
        let miniID = try #require(b.model.snapshot.hostID)
        try await FleetSettingsFlowTests.waitFor("the app to connect to the Mac mini") {
            await a.model.refresh()
            return store.pairedConnections.first?.phase == .connected
        }
        let connection = try #require(store.pairedConnections.first)
        #expect(store.pairedConnections.count == 1 && connection.id == miniID, "the fleet's own id for the Mac")
        #expect(connection.config.name == "Mac mini" && connection.config.fleetManaged && connection.config.ownToken)
        #expect(connection.config.token != b.token && connection.config.token != a.token, "not the shared token of either Mac")
        #expect(connection.fleetID == miniID)

        // The Mac leaves the fleet: so does its connection.
        await a.model.remove(miniID)
        try await FleetSettingsFlowTests.waitFor("the connection to go") { await a.model.refresh(); return store.pairedConnections.isEmpty }
    }

    @Test func aMacTheAppWasAClientOfIsARowToAddToTheFleetAndPairsWithItsCode() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini", serving: true)
        defer { a.stop(); b.stop() }
        // What an earlier version saved: a Mac this app reached with an address and a token, in no fleet.
        let defaults = ScratchDefaults()
        let old = RemoteHostStore.HostConfig(name: "Mac mini", host: "127.0.0.1", port: try #require(b.port), token: b.token)
        defaults.set(try JSONEncoder().encode([old]), forKey: RemoteHostStore.defaultsKey)

        let store = RemoteHostStore(defaults: defaults)
        defer { for connection in store.allConnections { store.removeHost(id: connection.id) } }
        #expect(store.pairedConnections.isEmpty && store.notInFleet.map(\.id) == [old.id], "its connection stops and it waits as a row")
        let mac = try #require(store.notInFleet.first.map { FleetNotInFleetMac(id: $0.id, name: $0.name, host: $0.host, port: $0.port) })
        let bPort = try #require(b.port)
        #expect(mac.row.title == "Mac mini" && mac.row.detail == "127.0.0.1:\(bPort) · not in your fleet" && mac.row.state == .notInFleet)
        #expect(RemoteHostStore(defaults: defaults, connects: false).notInFleet.map(\.id) == [old.id], "it is there at the next launch too, once")

        // Add to fleet…: opens Add a Mac with that Mac picked, and the code is the proof.
        await b.model.startJoin()
        #expect(!(await a.model.pair(with: mac.found, code: "000000")))
        #expect(await a.model.pair(with: mac.found, code: try #require(b.model.join?.code)))
        store.dismissNotInFleet(id: mac.id)
        #expect(store.notInFleet.isEmpty && RemoteHostStore(defaults: defaults, connects: false).notInFleet.isEmpty)
        await a.model.refresh()
        #expect(a.model.rows.map(\.title) == ["This Mac", "Mac mini"], "now it is in the fleet")
    }

    @Test func dismissingARowRemovesItAndAConfigWithoutTheFleetFlagIsOneToo() async throws {
        let defaults = ScratchDefaults()
        let json = Data(#"[{"id":"\#(UUID().uuidString)","name":"Mac studio","host":"studio.local","port":7434,"token":"x"}]"#.utf8)
        defaults.set(json, forKey: RemoteHostStore.defaultsKey)
        let store = RemoteHostStore(defaults: defaults, connects: false)
        #expect(store.pairedConnections.isEmpty && store.notInFleet.map(\.name) == ["Mac studio"])
        store.dismissNotInFleet(id: try #require(store.notInFleet.first?.id))
        #expect(RemoteHostStore(defaults: defaults, connects: false).notInFleet.isEmpty)
    }
}
