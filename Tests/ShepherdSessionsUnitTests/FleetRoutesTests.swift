import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// A peer's routes: the addresses this host was given and the ones the peer reported, in the order they are tried.
@Suite("Fleet routes")
struct FleetRoutesTests {
    static let given = FleetAddress(host: "10.77.20.10", port: 7434)

    static func record(addresses: [FleetAddress] = [given]) -> FleetPeerRecord {
        FleetPeerRecord(hostID: UUID(), name: "Mac mini", addresses: addresses, myToken: "t", peerTokenHash: FleetProtocol.hash("theirs"), pairedAt: 1)
    }

    static func report(_ routes: [(String, FleetRouteKind)], port: UInt16 = 7434) -> FleetRouteReport {
        FleetRouteReport(port: port, routes: routes.map { FleetReportedRoute(host: $0.0, kind: $0.1) })
    }

    @Test func theRoutesAreWhatWasGivenThenWhatTheMacReported() {
        var record = Self.record()
        #expect(record.routes == [FleetRoute(host: "10.77.20.10", port: 7434, kind: .lan, learned: false)])
        let changed = record.learn(Self.report([("mac-mini.local", .hostname), ("100.101.102.103", .tailscale), ("10.8.0.4", .vpn)]))
        #expect(changed)
        #expect(record.routes.map(\.host) == ["10.77.20.10", "mac-mini.local", "100.101.102.103", "10.8.0.4"])
        #expect(record.routes.map(\.learned) == [false, true, true, true])
        #expect(record.routes.map(\.kind) == [.lan, .hostname, .tailscale, .vpn])
    }

    @Test func aReportReplacesTheLastAndWhatItDropsIsGone() {
        var record = Self.record()
        record.learn(Self.report([("10.77.20.11", .lan), ("mac-mini.local", .hostname)]))
        let dropped = record.learn(Self.report([("mac-mini.local", .hostname)]))
        #expect(dropped)
        #expect(record.routes.map(\.host) == ["10.77.20.10", "mac-mini.local"])
        let emptied = record.learn(Self.report([]))
        #expect(emptied)
        #expect(record.routes.map(\.host) == ["10.77.20.10"], "an address that was given is never dropped by a report")
    }

    @Test func aReportThatChangesNothingSaysSo() {
        var record = Self.record()
        let report = Self.report([("mac-mini.local", .hostname)])
        let first = record.learn(report)
        let again = record.learn(report)
        let newPort = record.learn(Self.report([("mac-mini.local", .hostname)], port: 7435))
        #expect(first && !again && newPort, "a new port is news")
    }

    @Test func aRouteThatWasGivenIsNotLearnedAgainAndNoRouteIsTwice() {
        var record = Self.record()
        record.learn(Self.report([("10.77.20.10", .lan), ("mac-mini.local", .hostname), ("mac-mini.local", .hostname)]))
        #expect(record.routes.map(\.host) == ["10.77.20.10", "mac-mini.local"])
        #expect(record.routes.map(\.learned) == [false, true], "the address it was given stays what it was")
    }

    @Test func aReportIsHeldToTheMostARouteListMayHold() {
        var record = Self.record()
        let many = (0..<(FleetRouteReport.maxRoutes + 10)).map { ("10.77.30.\($0)", FleetRouteKind.lan) }
        record.learn(FleetRouteReport(port: 7434, routes: many.map { FleetReportedRoute(host: $0.0, kind: $0.1) }))
        #expect(record.learned.count == FleetRouteReport.maxRoutes)
    }

    @Test func aRemovedPeerKeepsNoRoute() {
        var peers = FleetPeers()
        var record = Self.record()
        record.learn(Self.report([("mac-mini.local", .hostname)]))
        peers.upsert(record)
        peers.revoke(record.hostID, at: 100)
        #expect(peers.record(record.hostID)?.learned.isEmpty == true)
    }

    @Test func routesSurviveTheirFileAndAFileFromBeforeHasNone() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var record = Self.record()
        record.learn(Self.report([("mac-mini.local", .hostname)]))
        var peers = FleetPeers()
        peers.upsert(record)
        try peers.save(to: dir)
        #expect(try FleetPeers.load(from: dir).record(record.hostID)?.routes == record.routes)

        let id = UUID()
        let json = #"{"peers":[{"hostID":"\#(id.uuidString)","name":"Mac mini","pairedAt":5,"addresses":[{"host":"10.77.20.10","port":7434}]}]}"#
        let older = try #require(try JSONDecoder().decode(FleetPeers.self, from: Data(json.utf8)).record(id))
        #expect(older.learned.isEmpty && older.routes.map(\.host) == ["10.77.20.10"])
    }

    @Test func anAddressIsKnownByItsForm() {
        #expect(FleetRoute.kind(ofAddress: "10.77.20.10") == .lan)
        #expect(FleetRoute.kind(ofAddress: "192.168.1.40") == .lan)
        #expect(FleetRoute.kind(ofAddress: "100.64.0.1") == .tailscale && FleetRoute.kind(ofAddress: "100.127.255.254") == .tailscale)
        #expect(FleetRoute.kind(ofAddress: "100.63.255.255") == .lan && FleetRoute.kind(ofAddress: "100.128.0.1") == .lan, "the range is 100.64.0.0/10")
        #expect(FleetRoute.kind(ofAddress: "fd00::1") == .lan)
        #expect(FleetRoute.kind(ofAddress: "mac-mini.local") == .hostname)
    }

    // MARK: Presence routes (iCloud)

    @Test func theRoutesOfAPresenceRecordComeAfterTheGivenAndTheReportedOnes() {
        var record = Self.record()
        record.learn(Self.report([("mac-mini.local", .hostname)]))
        let adopted = record.adoptPresence([FleetRoute(host: "10.77.30.5", port: 7434, kind: .lan, learned: false),
                                            FleetRoute(host: "mac-mini.local", port: 7434, kind: .hostname, learned: false),
                                            FleetRoute(host: "10.77.20.10", port: 7434, kind: .lan, learned: false)])
        #expect(adopted)
        #expect(record.routes.map(\.host) == ["10.77.20.10", "mac-mini.local", "10.77.30.5"], "known, then reported, then presence; each address once")
        #expect(record.routes.map(\.learned) == [false, true, true])
        let again = record.adoptPresence(record.presence)
        #expect(!again, "the same record is not news")
    }

    @Test func aNewPresenceRecordReplacesTheLastAndARemovedPeerKeepsNone() {
        var record = Self.record()
        record.adoptPresence([FleetRoute(host: "10.77.30.5", port: 7434, kind: .lan, learned: false)])
        record.adoptPresence([FleetRoute(host: "10.77.40.5", port: 7500, kind: .tailscale, learned: false)])
        #expect(record.presence == [FleetRoute(host: "10.77.40.5", port: 7500, kind: .tailscale, learned: true)])
        record.adoptPresence([FleetRoute(host: "10.0.0.1/evil", port: 7434, kind: .lan, learned: false), FleetRoute(host: "10.0.0.2", port: 0, kind: .lan, learned: false)])
        #expect(record.presence.isEmpty, "a host or port no Mac could have said is dropped")
        record.adoptPresence([FleetRoute(host: "10.77.30.5", port: 7434, kind: .lan, learned: false)])
        var peers = FleetPeers()
        peers.upsert(record)
        peers.revoke(record.hostID, at: 100)
        #expect(peers.record(record.hostID)?.presence.isEmpty == true)
    }

    @Test func aRouteKeepsItsKindAndFlagThroughAFileAndAnOlderRecordHoldsBareAddresses() throws {
        let routes = [FleetRoute(host: "100.101.102.103", port: 7434, kind: .tailscale, learned: true), FleetRoute(host: "mac-mini.local", port: 7434, kind: .hostname, learned: false)]
        #expect(try JSONDecoder().decode([FleetRoute].self, from: JSONEncoder().encode(routes)) == routes)
        // What an iCloud record of the build before routes holds: host and port.
        let older = try JSONDecoder().decode([FleetRoute].self, from: Data(#"[{"host":"10.77.20.10","port":7434},{"host":"mac-mini.local","port":7434},{"host":"100.64.0.9","port":7434}]"#.utf8))
        #expect(older.map(\.kind) == [.lan, .hostname, .tailscale] && older.allSatisfy { !$0.learned })
        let id = UUID()
        var record = Self.record()
        record.hostID = id
        record.adoptPresence(routes)
        var peers = FleetPeers()
        peers.upsert(record)
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try peers.save(to: dir)
        #expect(try FleetPeers.load(from: dir).record(id)?.presence == record.presence)
    }
}
