import Foundation
import Testing
@testable import ShepherdProtocol

/// What a phone is told of the fleet's Macs (`fleet.follow.v1`): the routes it reaches each by, nothing else of the fleet.
@Suite("Fleet follow wire")
struct FleetFollowWireTests {
    static let mini = FleetViewMember(hostID: UUID(), name: "Mac mini", port: 7434,
                                      routes: [FleetReportedRoute(host: "10.77.20.10", kind: .lan), FleetReportedRoute(host: "mac-mini.local", kind: .hostname)])

    @Test func aMemberRoundTripsAndAFleetReadCarriesIt() throws {
        #expect(try JSONDecoder().decode(FleetViewMember.self, from: JSONEncoder().encode(Self.mini)) == Self.mini)
        let snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", members: [Self.mini])
        #expect(try JSONDecoder().decode(FleetSnapshot.self, from: JSONEncoder().encode(snapshot)).members == [Self.mini])
    }

    @Test func aClientViewKeepsTheMembersAndStillNothingElseOfHowTheMacListens() throws {
        let snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", build: "1.9.0", addresses: ["192.168.1.40"], port: 7434,
                                     routes: [FleetReportedRoute(host: "192.168.1.40", kind: .lan)], members: [Self.mini])
        let view = snapshot.clientView
        #expect(view.members == [Self.mini])
        #expect(view.routes.isEmpty && view.addresses.isEmpty && view.port == nil && view.build == nil)
    }

    @Test func aHostBeforeTheCapabilityNamesNoMembers() throws {
        let json = #"{"enabled":true,"name":"MacBook Pro","addresses":[],"advertising":false,"peers":[]}"#
        #expect(try JSONDecoder().decode(FleetSnapshot.self, from: Data(json.utf8)).members.isEmpty)
    }

    @Test func aMemberWithoutRoutesStillDecodes() throws {
        let json = #"{"hostID":"\#(UUID().uuidString)","name":"Mac mini","port":7434}"#
        #expect(try JSONDecoder().decode(FleetViewMember.self, from: Data(json.utf8)).routes.isEmpty)
    }

    @Test func aMemberIsOnlyActedOnWhenItIsSane() {
        #expect(Self.mini.isValid)
        var member = Self.mini
        member.port = 0
        #expect(!member.isValid)
        member = Self.mini
        member.routes = [FleetReportedRoute(host: "http://evil", kind: .lan)]
        #expect(!member.isValid)
        member.routes = Array(repeating: Self.mini.routes[0], count: FleetRouteReport.maxRoutes + 1)
        #expect(!member.isValid)
    }

    @Test func theCapabilityIsOfferedToADevice() {
        let follow = RemoteProtocol.fleetFollowCapability
        #expect(RemoteProtocol.capabilities.contains(follow) && FleetAccess.device.isOffered(follow))
        #expect(!RemoteProtocol.fleetMemberCapabilities.contains(follow))
    }
}
