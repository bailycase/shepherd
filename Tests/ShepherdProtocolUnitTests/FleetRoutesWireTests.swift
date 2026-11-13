import Foundation
import Testing
@testable import ShepherdProtocol

/// Routes on the wire: what a report of them may hold, and how a peer's reach reads from a host that predates it.
@Suite("Fleet routes wire")
struct FleetRoutesWireTests {
    static let lan = FleetReportedRoute(host: "10.77.20.10", kind: .lan)

    @Test(arguments: ["10.77.20.10", "mac-mini.local", "mac.mini.example.com", "fd00::1", "2001:db8::1", "fe80::1%en0", "100.101.102.103"])
    func aHostIsAnAddressOrAName(_ host: String) {
        #expect(FleetRouteReport(port: 7434, routes: [FleetReportedRoute(host: host, kind: .lan)]).isValid)
    }

    @Test(arguments: ["", "10.0.0.1/evil", "http://mac.local", "mac mini.local", "mac\n.local", "mac.local:7434\u{0}", "é.local", String(repeating: "a", count: 254)])
    func anythingElseIsNotAHost(_ host: String) {
        #expect(!FleetRouteReport(port: 7434, routes: [FleetReportedRoute(host: host, kind: .hostname)]).isValid)
    }

    @Test func aReportNeedsAPortAndIsBounded() {
        #expect(!FleetRouteReport(port: 0, routes: [Self.lan]).isValid)
        #expect(FleetRouteReport(port: 7434, routes: []).isValid, "a Mac with no route says so")
        #expect(FleetRouteReport(port: 7434, routes: Array(repeating: Self.lan, count: FleetRouteReport.maxRoutes)).isValid)
        #expect(!FleetRouteReport(port: 7434, routes: Array(repeating: Self.lan, count: FleetRouteReport.maxRoutes + 1)).isValid)
    }

    @Test func aReportRoundTrips() throws {
        let report = FleetRouteReport(port: 7434, routes: [Self.lan, FleetReportedRoute(host: "mac-mini.local", kind: .hostname),
                                                           FleetReportedRoute(host: "100.101.102.103", kind: .tailscale), FleetReportedRoute(host: "10.8.0.4", kind: .vpn)])
        #expect(try JSONDecoder().decode(FleetRouteReport.self, from: JSONEncoder().encode(report)) == report)
    }

    @Test func eachKindHasWordsForThePage() {
        #expect([FleetRouteKind.lan, .tailscale, .vpn, .hostname].map(\.label) == ["LAN", "Tailscale", "VPN", "name"])
    }

    /// A host from before links sends a peer without `reach`; it decodes as nothing, and a client's view never carries one.
    @Test func aPeerFromAHostBeforeLinksHasNoReach() throws {
        let id = UUID()
        let json = #"{"hostID":"\#(id.uuidString)","name":"Mac mini","kind":"mac","pairedAt":5,"link":"connected"}"#
        let peer = try JSONDecoder().decode(FleetPeerStatus.self, from: Data(json.utf8))
        #expect(peer.reach == nil && peer.link == .connected)

        let reached = FleetPeerStatus(hostID: id, name: "Mac mini", host: "10.77.20.10", port: 7434, pairedAt: 5, link: .connected, reach: FleetPeerReach(host: "10.77.20.10", kind: .lan))
        #expect(try JSONDecoder().decode(FleetPeerStatus.self, from: JSONEncoder().encode(reached)) == reached)
        let snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", peers: [reached])
        #expect(snapshot.clientView.peers.first?.reach == nil && snapshot.clientView.peers.first?.host == nil, "a phone is never told how a Mac is reached")
    }
}
