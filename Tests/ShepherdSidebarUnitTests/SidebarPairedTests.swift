import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import Testing
@testable import ShepherdSidebar

/// The sidebar on a client with no thread host of its own (the iPhone and iPad): every Mac it is paired with is a host, and the
/// pins, completions and seen generations are `FleetSidebarState`'s. The Mac's own derivation groups them.
@MainActor
struct SidebarPairedTests {
    private let studio = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    private let build = UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!

    private func agent(_ name: String, _ status: AgentStatus = .idle, at: Double = 1) -> Agent {
        var agent = Agent(name: name, spaceID: SpaceID(), tabID: TabID(), paneID: PaneID(), status: status)
        agent.lastActiveAt = at
        return agent
    }

    private func lists(_ hosts: [SidebarSource.Host], state: FleetSidebarState = FleetSidebarState()) -> SidebarLists {
        SidebarDerivation.lists(SidebarPaired.source(hosts: hosts, state: state), pins: SidebarPaired.pins(state),
                                seen: SidebarPaired.seen(state))
    }

    @Test func groupsFollowTheMacsOrderAndRules() {
        var asking = agent("asks", .blocked, at: 5)
        asking.waitingOn = "Which database?"
        asking.waitingReason = "database?"
        let host = SidebarSource.Host(id: studio, name: "Studio", state: ShepherdState(agents: [
            agent("idle", at: 1), asking, agent("running", .working, at: 4), agent("finished", .done, at: 3),
        ]))
        let result = lists([host])
        #expect(result.sections.map(\.section) == [.designs, .automations, .needsYou, .working, .done, .pinned, .recents])
        #expect(result.needsYou.map(\.title) == ["asks"])
        #expect(result.working.map(\.title) == ["running"])
        #expect(result.done.map(\.title) == ["finished"])
        #expect(result.recents.map(\.title) == ["idle"])
        #expect(result.needsYou.first?.accessory == .reason("database?"))
        #expect(result.working.first?.accessory == .tag("Studio"), "a thread on a paired Mac is tagged with it")
        let headers = result.presented(selected: nil, shortcuts: false).items(collapsed: [], showsProjects: false).compactMap { item -> String? in
            if case .header(let section, let count, _) = item { "\(section.title) \(count)" } else { nil }
        }
        #expect(headers == ["Needs you 1", "Working 1", "Done 1", "Recents 1"])
    }

    @Test func markAllSeenMovesDoneToRecentsAndALaterCompletionComesBack() {
        let ref = FleetRef(host: studio, agent: AgentID(rawValue: "finished"))
        var finished = agent("finished", .done, at: 3)
        finished.id = ref.agent
        let fleet = FleetHost(id: studio, name: "Studio", address: "127.0.0.1", port: 1, phase: .connected,
                              state: ShepherdState(agents: [finished]))
        var state = FleetSidebarState()
        state.reconcile([fleet], sessions: [:])
        let host = SidebarSource.Host(id: studio, name: "Studio", state: fleet.state)
        #expect(lists([host], state: state).done.map(\.title) == ["finished"])
        state.markSeen([ref])
        let seen = lists([host], state: state)
        #expect(seen.done.isEmpty)
        #expect(seen.recents.map(\.title) == ["finished"])
    }

    @Test func pinsKeepTheirOrderAndTheirThreadLeavesItsGroup() {
        let first = agent("first", .working, at: 2), second = agent("second", at: 1)
        let host = SidebarSource.Host(id: studio, name: "Studio", state: ShepherdState(agents: [first, second]))
        var state = FleetSidebarState()
        state.pin(FleetRef(host: studio, agent: second.id))
        state.pin(FleetRef(host: studio, agent: first.id))
        let result = lists([host], state: state)
        #expect(result.pinned.map(\.title) == ["second", "first"], "oldest pin first, whatever the status")
        #expect(result.working.isEmpty && result.recents.isEmpty)
        #expect(result.pinned.allSatisfy { $0.pinned })
    }

    @Test func aThreadOnAnOfflineHostStaysInRecentsDimmed() {
        let host = SidebarSource.Host(id: build, name: "build-01", state: ShepherdState(agents: [agent("busy", .working)]), offline: true)
        let result = lists([host])
        #expect(result.working.isEmpty)
        #expect(result.recents.map(\.title) == ["busy"])
        #expect(result.recents.first?.offline == true)
    }

    @Test func aThreadAThreadStartedNestsUnderItsSenderWhileItWorks() {
        let sender = agent("sender", .working, at: 5)
        var sent = agent("sent", .working, at: 6)
        sent.startedBy = StartedBy(agentID: sender.id, agentTitle: "sender", at: 10, depth: 1)
        let host = SidebarSource.Host(id: studio, name: "Studio", state: ShepherdState(agents: [sender, sent]))
        let result = lists([host])
        #expect(result.working.map(\.title) == ["sender", "sent"])
        #expect(result.working.map(\.fleetNested) == [false, true])
        let headers = result.presented(selected: nil, shortcuts: false).items(collapsed: [], showsProjects: false)
        #expect(headers.first == .header(.working, count: 1, collapsed: false), "a nested thread is counted with its sender")
    }

    @Test func completionsAreTheOnesFleetStateObserved() {
        let ref = FleetRef(host: studio, agent: AgentID(rawValue: "done"))
        var done = agent("done", .done, at: 9)
        done.id = ref.agent
        let fleet = FleetHost(id: studio, name: "Studio", address: "127.0.0.1", port: 1, phase: .connected, state: ShepherdState(agents: [done]))
        var state = FleetSidebarState()
        state.reconcile([fleet], sessions: [:])
        let completions = SidebarPaired.completions(state)
        #expect(completions[.remote(RemoteAgentRef(hostID: studio, agentID: ref.agent))]?.finished == true)
        #expect(SidebarPaired.seen(state).isEmpty)
        state.markSeen([ref])
        #expect(SidebarPaired.seen(state).count == 1)
    }
}
