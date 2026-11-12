import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A thread another Mac runs for a thread nests under its sender (FleetSidebar): one level, in the same list, keeping its Mac tag. Where the
/// sender isn't in that list it is an ordinary row.
@Suite("Fleet sidebar nesting")
@MainActor
struct FleetNestingTests {
    static let thisMac = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let miniFleet = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let miniLink = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let studioFleet = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!

    let space = Fixture.space("acme-web")
    let remoteSpace = Fixture.space("acme-web", path: "/srv/acme-web")

    func agent(_ name: String, _ status: AgentStatus, in space: Space, at: Double, from: (host: UUID, name: String, agent: AgentID?)? = nil) -> Agent {
        var agent = Fixture.agent(name, in: space).agent
        agent.status = status
        agent.lastActiveAt = at
        agent.dispatchedFrom = from.map {
            DispatchedFrom(hostID: $0.host, hostName: $0.name, agentID: $0.agent, agentTitle: "Speed up checkout CI", dispatchID: UUID(), at: 1)
        }
        return agent
    }

    func host(_ agents: [Agent], fleetID: UUID? = FleetNestingTests.miniFleet, offline: Bool = false) -> SidebarSource.Host {
        SidebarSource.Host(id: Self.miniLink, name: "Mac mini", state: ShepherdState(spaces: [remoteSpace], agents: agents), offline: offline,
                           fleetID: fleetID)
    }

    func lists(local: [Agent], hosts: [SidebarSource.Host]) -> SidebarLists {
        SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [space], agents: local), localFleetID: Self.thisMac, hosts: hosts))
    }

    @Test func aThreadAnotherMacRunsSitsUnderItsSenderWithItsTag() {
        let sender = agent("Speed up checkout CI", .working, in: space, at: 10)
        let other = agent("Migrate orders", .working, in: space, at: 30)
        let child = agent("Fix flaky payment test", .working, in: remoteSpace, at: 50, from: (Self.thisMac, "MacBook Pro", sender.id))
        let built = lists(local: [sender, other], hosts: [host([child])])
        // Newest first would put the dispatched thread on top; it sits right under its sender instead.
        #expect(built.working.map(\.title) == ["Migrate orders", "Speed up checkout CI", "Fix flaky payment test"])
        let nested = built.working.last
        #expect(nested?.fleetNested == true && nested?.accessory == .tag("mini"))
        #expect(built.working.dropLast().allSatisfy { !$0.fleetNested })
    }

    @Test func aSenderOnAnotherConnectedMacIsFoundByItsFleetID() {
        let sender = agent("Speed up checkout CI", .working, in: remoteSpace, at: 10)
        let child = agent("Fix flaky payment test", .working, in: space, at: 50, from: (Self.miniFleet, "Mac mini", sender.id))
        let built = lists(local: [child], hosts: [host([sender])])
        #expect(built.working.map(\.title) == ["Speed up checkout CI", "Fix flaky payment test"])
        #expect(built.working.map(\.fleetNested) == [false, true])
    }

    @Test func aDeletedOrUnreachableSenderLeavesAnOrdinaryRow() {
        let gone = agent("Fix flaky payment test", .working, in: remoteSpace, at: 5, from: (Self.thisMac, "MacBook Pro", AgentID()))
        let elsewhere = agent("Profile cold launch", .working, in: remoteSpace, at: 6, from: (Self.studioFleet, "Mac Studio", AgentID()))
        let byYou = agent("Regenerate API client", .working, in: remoteSpace, at: 7, from: (Self.thisMac, "MacBook Pro", nil))
        let built = lists(local: [agent("Speed up checkout CI", .working, in: space, at: 10)], hosts: [host([gone, elsewhere, byYou])])
        #expect(built.working.count == 4)
        #expect(built.working.allSatisfy { !$0.fleetNested })
        #expect(built.working.filter { $0.accessory == .tag("mini") }.count == 3, "each keeps its Mac tag")
    }

    @Test func aThreadInAnotherGroupThanItsSenderIsOrdinary() {
        let sender = agent("Speed up checkout CI", .working, in: space, at: 10)
        let child = agent("Fix flaky payment test", .done, in: remoteSpace, at: 5, from: (Self.thisMac, "MacBook Pro", sender.id))
        let built = lists(local: [sender], hosts: [host([child])])
        #expect(built.working.map(\.title) == ["Speed up checkout CI"])
        #expect(built.all.filter(\.fleetNested).isEmpty)
    }

    @Test func nestingGoesOneLevelDeep() {
        let first = agent("Speed up checkout CI", .working, in: space, at: 10)
        let second = agent("Fix flaky payment test", .working, in: remoteSpace, at: 8, from: (Self.thisMac, "MacBook Pro", first.id))
        let third = agent("Profile cold launch", .working, in: remoteSpace, at: 6, from: (Self.miniFleet, "Mac mini", second.id))
        let built = lists(local: [first], hosts: [host([second, third])])
        #expect(built.working.map(\.fleetNested) == [false, true, false], "a thread two Macs deep is an ordinary row, never a second indent")
    }

    @Test func theProjectTreeNestsTheSameWay() {
        let sender = agent("Speed up checkout CI", .working, in: space, at: 10)
        let child = agent("Fix flaky payment test", .working, in: remoteSpace, at: 5, from: (Self.thisMac, "MacBook Pro", sender.id))
        let tree = SidebarDerivation.tree(SidebarSource(local: ShepherdState(spaces: [space], agents: [sender]), localFleetID: Self.thisMac,
                                                        hosts: [host([child])]),
                                          options: SidebarTreeOptions())
        let rows = tree.projects.first?.rows ?? []
        #expect(rows.map(\.title) == ["Speed up checkout CI", "Fix flaky payment test"])
        #expect(rows.map(\.fleetNested) == [false, true])
    }
}
