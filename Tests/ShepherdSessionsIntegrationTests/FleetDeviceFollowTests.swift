import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A phone or an iPad paired once keeps up with the fleet (`fleet.follow.v1`), between real scratch hosts and a device client: it is
/// told the fleet's Macs and how each is reached, hears when they change, and reaches a Mac the fleet added with the token it already
/// has. What the phone then does with its saved Macs is `FleetFollow` (unit tests) and `MobileHosts` (`FleetFollowCheck`).
@Suite("Fleet follow for devices", .integrationTimeLimit)
struct FleetDeviceFollowTests {
    typealias Mac = FleetPairingTests.Mac
    typealias Phone = FleetDevicesIntegrationTests.Device

    static let lan = FleetReportedRoute(host: "10.77.20.10", kind: .lan)
    static let name = FleetReportedRoute(host: "mac-mini.local", kind: .hostname)
    static let loopback = FleetReportedRoute(host: "127.0.0.1", kind: .lan)

    /// A Mac that reports `network` as the ways it can be reached.
    static func mac(_ name: String, network: FakeNetwork = FakeNetwork([loopback]), dir: URL? = nil) async throws -> Mac {
        try await Mac(name, dir: dir) { $0.fleetLinkOptions = LinkRouting(network: network).options }
    }

    /// What a phone lists in `hello`: what it did before, and that it follows the fleet.
    static let clientCapabilities = RemoteProtocol.clientCapabilities + [RemoteProtocol.fleetFollowCapability]

    /// A phone paired with `mac`, and connected to it as one that follows the fleet.
    final class Following: @unchecked Sendable {
        let phone = Phone("Ada's iPhone")
        let client = RemoteHostClient()
        /// How many times the Mac said the fleet changed.
        let pushes = Locked(0)
        /// The Mac ended the connection.
        let disconnected = Locked(false)

        init(pairedWith mac: Mac) async throws {
            let code = try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code
            _ = try await phone.pair(with: mac, code: code)
            let pushes = pushes
            client.onFleetViewChanged = { pushes.withValue { $0 += 1 } }
            let ended = disconnected
            client.onDisconnected = { _ in ended.withValue { $0 = true } }
            _ = try await client.connect(host: "127.0.0.1", port: mac.port, token: phone.token, clientName: phone.intro.name, capabilities: FleetDeviceFollowTests.clientCapabilities)
        }

        func stop() { client.disconnect() }

        func members() async throws -> [FleetViewMember] { try await client.fleetRead().snapshot.members }

        /// Waits for the Mac to say the fleet changed, then reads what it holds.
        func next(after seen: Int, _ what: String) async throws -> [FleetViewMember] {
            try await eventually("the Mac to say \(what)") { self.pushes.current > seen }
            return try await members()
        }

        /// Connects to `member` as the phone would: the first of its routes that answers as that Mac, with the token the phone already has.
        func reach(_ member: FleetViewMember) async throws -> (route: RemoteHostRoute, state: ShepherdState, client: RemoteHostClient) {
            for route in FleetFollow.routes(of: member) {
                let client = RemoteHostClient()
                do {
                    let state = try await client.connect(host: route.host, port: route.port, token: phone.token, clientName: phone.intro.name,
                                                         capabilities: FleetDeviceFollowTests.clientCapabilities, expectingHostID: member.hostID)
                    return (route, state, client)
                } catch {
                    client.disconnect()
                }
            }
            throw WireError("no route of \(member.name) answered")
        }
    }

    // MARK: What the phone is told

    @Test func aDeviceIsToldEachMacOfItsFleetWithItsRoutesAndNothingElseOfHowTheyAreReached() async throws {
        let a = try await Self.mac("MacBook Pro", network: FakeNetwork([Self.lan, Self.name])), b = try await Self.mac("Mac mini", network: FakeNetwork([Self.lan, Self.name]))
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        let phone = try await Following(pairedWith: a)
        defer { phone.stop() }
        #expect(phone.client.capabilities.contains(RemoteProtocol.fleetFollowCapability))
        let (aID, bID) = (try #require(try await a.read().hostID), try #require(try await b.read().hostID))

        // The Mac it asks, by what it reports of itself; the other by the address it was given and what that Mac reported.
        try await eventually("the mini's reported routes to reach the MacBook") { try await phone.members().last?.routes.count == 3 }
        let members = try await phone.members()
        #expect(members.map(\.hostID) == [aID, bID] && members.map(\.name) == ["MacBook Pro", "Mac mini"])
        #expect(members[0].port == a.port && members[0].routes == [Self.lan, Self.name])
        #expect(members[1].port == b.port && members[1].routes == [Self.loopback, Self.lan, Self.name])
        #expect(members.allSatisfy { $0.isValid })

        // Still not the rest of how this Mac listens, who is paired or what syncs.
        let view = try await phone.client.fleetRead().snapshot
        #expect(view.addresses.isEmpty && view.port == nil && view.routes.isEmpty && view.devices == nil && view.sync == nil && view.build == nil)
        #expect(view.peers.allSatisfy { $0.host == nil && $0.port == nil && $0.reach == nil })
    }

    @Test func aClientThatDoesNotListTheCapabilityIsNeverPushedTheHint() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let following = try await Following(pairedWith: a)
        defer { following.stop() }
        let quiet = Phone("Old iPhone")
        defer { quiet.stop() }
        _ = try await quiet.pair(with: a, code: try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code)
        let heard = Locked(0)
        quiet.client.onFleetViewChanged = { heard.withValue { $0 += 1 } }
        _ = try await quiet.client.connect(host: "127.0.0.1", port: a.port, token: quiet.token, clientName: "Old iPhone")
        try await a.pair(with: b, code: try await b.startJoin())
        _ = try await following.next(after: 0, "a Mac joined")
        #expect(heard.current == 0, "no capability listed, no push")
        // It still reads the members, which is all a build before this one does with the view.
        #expect(try await quiet.client.fleetRead().snapshot.members.count == 2)
    }

    // MARK: A Mac joins, leaves and moves

    @Test func aMacThatJoinsTheFleetIsReachedWithTheTokenThePhoneAlreadyHasAndOneThatLeavesIsDropped() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        let phone = try await Following(pairedWith: a)
        defer { phone.stop() }
        #expect(try await phone.members().map(\.name) == ["MacBook Pro"], "a fleet of one Mac")

        // B joins A's fleet: the phone is told, and B accepts the token it has, though the phone never paired with B.
        try await a.pair(with: b, code: try await b.startJoin())
        let joined = try await phone.next(after: 0, "a Mac joined")
        let mini = try #require(joined.first { $0.name == "Mac mini" })
        #expect(joined.count == 2 && mini.routes.first?.host == "127.0.0.1" && mini.port == b.port)
        try await eventually("the mini to know the phone") { try await FleetDevicesIntegrationTests.devices(b).map(\.name) == ["Ada's iPhone"] }
        let atB = try await phone.reach(mini)
        defer { atB.client.disconnect() }
        #expect(atB.route.host == "127.0.0.1" && atB.client.hostID == mini.hostID, "its threads are read with the same token")

        // B leaves: the phone is told, and it is no longer listed.
        _ = try await a.local.fleetAction(.remove(hostID: mini.hostID))
        let left = try await phone.next(after: 1, "a Mac left")
        #expect(left.map(\.name) == ["MacBook Pro"])
    }

    @Test func aMacThatChangesItsAddressIsReachedAtTheRouteItReports() async throws {
        let a = try await Self.mac("MacBook Pro")
        let network = FakeNetwork([Self.loopback])
        var b = try await Self.mac("Mac mini", network: network)
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        let phone = try await Following(pairedWith: a)
        defer { phone.stop() }
        let before = try #require(try await phone.members().first { $0.name == "Mac mini" })
        let atB = try await phone.reach(before)
        atB.client.disconnect()

        // B comes back at another address: A learns it from B's own report, and tells the phone, which reaches B there.
        let (dir, id) = (b.host.dir, before.hostID)
        let seen = phone.pushes.current
        b.stop(keepFiles: true)
        b = try await Self.mac("Mac mini", network: network, dir: dir)
        #expect(try await b.read().hostID == id && b.port != before.port, "the same Mac, listening somewhere else")
        try await eventually("the phone to be told where the mini is") {
            guard phone.pushes.current > seen, let mini = try await phone.members().first(where: { $0.hostID == id }) else { return false }
            return mini.port == b.port
        }
        let now = try #require(try await phone.members().first { $0.hostID == id })
        let reached = try await phone.reach(now)
        defer { reached.client.disconnect() }
        #expect(reached.client.hostID == id && reached.route.port == b.port, "reached at the new address with the same token")
    }

    // MARK: Revoked

    @Test func aDeviceRevokedOnAnyMacIsRefusedByEveryMacAndLearnsNothingMore() async throws {
        let a = try await Self.mac("MacBook Pro"), b = try await Self.mac("Mac mini")
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        let phone = try await Following(pairedWith: a)
        defer { phone.stop() }
        let mini = try #require(try await phone.members().first { $0.name == "Mac mini" })
        try await eventually("the mini to know the phone") { try await FleetDevicesIntegrationTests.devices(b).count == 1 }

        let id = try #require(try await FleetDevicesIntegrationTests.devices(b).first).deviceID
        _ = try await b.local.fleetAction(.revokeDevice(id))
        try await eventually("the phone's connection to end") { phone.disconnected.current }
        for mac in [a, b] {
            let refused = await FleetDevicesIntegrationTests.refused(phone.phone.token, by: mac)
            #expect(refused, "\(mac.name) refuses it")
        }
        // Nothing to read from, and no route is reached with that token.
        do { _ = try await phone.reach(mini); Issue.record("a revoked device reached a Mac") } catch is WireError {}
    }
}
