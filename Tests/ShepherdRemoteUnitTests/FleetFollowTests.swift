import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdRemote

/// What a phone does to its saved Macs when the fleet it reads says what it holds (`FleetFollow.plan`).
@Suite("Fleet follow")
struct FleetFollowTests {
    let laptop = UUID(), mini = UUID(), studio = UUID()
    let group = UUID()

    func member(_ id: UUID, _ name: String, _ hosts: String...) -> FleetViewMember {
        FleetViewMember(hostID: id, name: name, port: 7434, routes: hosts.map { FleetReportedRoute(host: $0, kind: .lan) })
    }

    func saved(_ fleetID: UUID?, _ name: String, _ hosts: String..., group: UUID? = nil, ungrouped: Bool = false, own: Bool = true) -> FleetFollowSaved {
        FleetFollowSaved(id: UUID(), fleetID: fleetID, name: name, routes: hosts.map { RemoteHostRoute(host: $0, port: 7434, kind: .lan) },
                         group: ungrouped ? nil : group ?? self.group, ownsToken: own)
    }

    @Test func aMacThatJoinedTheFleetIsAdded() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Mac mini", "10.77.20.10")], saved: [here]))
        #expect(plan.add.map(\.hostID) == [mini] && plan.update.isEmpty && plan.remove.isEmpty)
        #expect(FleetFollow.routes(of: plan.add[0]) == [RemoteHostRoute(host: "10.77.20.10", port: 7434, kind: .lan)])
    }

    @Test func aRenamedMacAndNewRoutesUpdateTheSavedOne() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5"), there = saved(mini, "Mac mini", "10.77.20.10")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"),
                                                                           member(mini, "Build mini", "10.77.20.99", "10.77.20.10")], saved: [here, there]))
        #expect(plan.update.count == 1 && plan.update[0].id == there.id && plan.update[0].name == "Build mini")
        #expect(plan.update[0].routes.map(\.host) == ["10.77.20.99", "10.77.20.10"], "the fleet's order is kept")
        #expect(plan.add.isEmpty && plan.remove.isEmpty)
    }

    @Test func aMacIsMatchedByItsIdNeverByItsAddress() throws {
        // Two Macs swap addresses: each keeps its own record.
        let here = saved(laptop, "MacBook Pro", "10.77.10.5"), a = saved(mini, "Mac mini", "10.77.20.10"), b = saved(studio, "Mac Studio", "10.77.20.11")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Mac mini", "10.77.20.11"),
                                                                           member(studio, "Mac Studio", "10.77.20.10")], saved: [here, a, b]))
        #expect(plan.add.isEmpty && plan.remove.isEmpty)
        #expect(plan.update.first { $0.id == a.id }?.routes.map(\.host) == ["10.77.20.11"] && plan.update.first { $0.id == b.id }?.routes.map(\.host) == ["10.77.20.10"])
        // An address a saved Mac without an id holds is not a match either: the fleet's Mac is added.
        let blank = saved(nil, "Mac mini", "10.77.20.10")
        let again = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Mac mini", "10.77.20.10")], saved: [here, blank]))
        #expect(again.add.map(\.hostID) == [mini] && again.remove.isEmpty)
    }

    @Test func aMacThatLeftTheFleetIsRemoved() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5"), gone = saved(mini, "Mac mini", "10.77.20.10")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5")], saved: [here, gone]))
        #expect(plan.remove == [gone.id])
    }

    @Test func aMacPairedOutsideTheFleetIsKept() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5")
        let typed = saved(nil, "Home server", "192.168.1.9", ungrouped: true, own: false)
        let pasted = saved(studio, "Mac Studio", "10.77.20.11", ungrouped: true, own: false)
        let other = saved(UUID(), "Office Mac", "172.16.0.2", group: UUID())
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5")], saved: [here, typed, pasted, other]))
        #expect(plan.remove.isEmpty, "no group, a token that isn't the device's, or another fleet's group: none is touched")
        // The fleet lists a Mac the user pasted a token for: it is theirs, not replaced and not added twice.
        let listed = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(studio, "Studio", "10.0.0.1")], saved: [here, pasted]))
        #expect(listed.add.isEmpty && listed.update.isEmpty)
    }

    @Test func aMacTheUserForgotIsNotAddedAgain() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Mac mini", "10.77.20.10")],
                                                saved: [here], ignored: [mini]))
        #expect(plan.add.isEmpty)
    }

    @Test func aMacThatNamesNoRouteIsKeptWhereItWas() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5"), there = saved(mini, "Mac mini", "10.77.20.10")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Mac mini")], saved: [here, there]))
        #expect(plan.isEmpty)
        let added = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(studio, "Mac Studio")], saved: [here]))
        #expect(added.add.isEmpty, "a Mac there is no way to reach isn't added")
    }

    @Test func aMacThatSpeaksForItselfIsNotRewrittenByAnother() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5"), there = saved(mini, "Mac mini", "10.77.20.10")
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Build mini", "10.77.20.99")],
                                                saved: [here, there], views: [there.id: [laptop, mini]]))
        #expect(plan.update.isEmpty)
    }

    @Test func aFleetItDoesNotKnowTheSourceInIsNotFollowed() {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5"), gone = saved(mini, "Mac mini", "10.77.20.10")
        // A host before the capability says nothing; one that leaves itself out can't be right.
        #expect(FleetFollow.plan(source: here.id, members: [], saved: [here, gone]) == nil)
        #expect(FleetFollow.plan(source: here.id, members: [member(mini, "Mac mini", "10.77.20.10")], saved: [here, gone]) == nil)
        // A source on a token the fleet didn't give, or one whose id isn't known yet, is never followed from.
        #expect(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro")], saved: [saved(laptop, "MacBook Pro", own: false)]) == nil)
        let unknown = saved(nil, "MacBook Pro", "10.77.10.5")
        #expect(FleetFollow.plan(source: unknown.id, members: [member(laptop, "MacBook Pro")], saved: [unknown]) == nil)
    }

    @Test func theFirstReadPlacesTheMacsInAGroupAndRemovesNothing() throws {
        // A phone paired before it followed has no groups: the Macs the fleet lists get one, so a later read can remove.
        let here = saved(laptop, "MacBook Pro", "10.77.10.5", ungrouped: true), there = saved(mini, "Mac mini", "10.77.20.10", ungrouped: true), old = saved(studio, "Mac Studio", "10.77.20.11", ungrouped: true)
        let fresh = UUID()
        let plan = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(mini, "Mac mini", "10.77.20.10")],
                                                saved: [here, there, old], newGroup: fresh))
        #expect(plan.group == fresh && plan.remove.isEmpty && Set(plan.update.map(\.id)) == [here.id, there.id] && plan.update.allSatisfy { $0.group == fresh })
    }

    @Test func aMacThatLeftAndStillAnswersDoesNotRemoveTheFleet() throws {
        // Three Macs; the mini left. Read from the mini, which holds a fleet of one, the others are missing, but they hold a bigger one.
        let a = saved(laptop, "MacBook Pro", "10.77.10.5"), b = saved(mini, "Mac mini", "10.77.20.10"), c = saved(studio, "Mac Studio", "10.77.20.11")
        let fromMini = try #require(FleetFollow.plan(source: b.id, members: [member(mini, "Mac mini", "10.77.20.10")], saved: [a, b, c],
                                                    views: [a.id: [laptop, studio], c.id: [laptop, studio]]))
        #expect(fromMini.remove.isEmpty, "the Macs that hold a bigger fleet stay")
        let unread = try #require(FleetFollow.plan(source: b.id, members: [member(mini, "Mac mini", "10.77.20.10")], saved: [a, b, c]))
        #expect(Set(unread.remove) == [a.id, c.id], "Macs that haven't said what they hold are no rival")
        let fromLaptop = try #require(FleetFollow.plan(source: a.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), member(studio, "Mac Studio", "10.77.20.11")],
                                                      saved: [a, b, c], views: [b.id: [mini]]))
        #expect(fromLaptop.remove == [b.id])
    }

    @Test func halvesOfEqualSizeKeepTheOneSavedFirst() throws {
        let a = saved(laptop, "MacBook Pro", "10.77.10.5"), b = saved(mini, "Mac mini", "10.77.20.10")
        let fromFirst = try #require(FleetFollow.plan(source: a.id, members: [member(laptop, "MacBook Pro", "10.77.10.5")], saved: [a, b], views: [b.id: [mini]]))
        let fromSecond = try #require(FleetFollow.plan(source: b.id, members: [member(mini, "Mac mini", "10.77.20.10")], saved: [a, b], views: [a.id: [laptop]]))
        #expect(fromFirst.remove == [b.id] && fromSecond.remove.isEmpty)
    }

    @Test func aFleetIsBounded() throws {
        let here = saved(laptop, "MacBook Pro", "10.77.10.5")
        let many = [member(laptop, "MacBook Pro", "10.77.10.5")] + (0..<100).map { member(UUID(), "Mac \($0)", "10.0.0.\($0)") }
        let plan = try #require(FleetFollow.plan(source: here.id, members: many, saved: [here]))
        #expect(plan.add.count == FleetViewMember.maxMembers - 1)
        // A member that repeats an id, or has a hostile route, is read once or not at all.
        let bad = FleetViewMember(hostID: mini, name: "Mac mini", port: 7434, routes: [FleetReportedRoute(host: "http://evil", kind: .lan)])
        let plan2 = try #require(FleetFollow.plan(source: here.id, members: [member(laptop, "MacBook Pro", "10.77.10.5"), bad, member(studio, "Studio", "1.1.1.1"), member(studio, "Studio again", "2.2.2.2")], saved: [here]))
        #expect(plan2.add.map(\.name) == ["Studio"])
    }
}
