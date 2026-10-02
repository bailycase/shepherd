import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
import Testing
@testable import ShepherdApp

@Suite("Sidebar activity groups")
@MainActor
struct SidebarActivityTests {
    @Test func groupsAreExclusiveAndPinnedAlwaysWins() {
        let space = Fixture.space("workspace")
        let pinned = Fixture.agent("pinned", in: space).agent
        let idle = Fixture.agent("idle", in: space).agent
        var asking = Fixture.agent("asking", in: space).agent
        asking.status = .blocked
        asking.waitingOn = "Approve?"
        var working = Fixture.agent("working", in: space).agent
        working.status = .working
        var done = Fixture.agent("done", in: space).agent
        done.status = .done
        let design = Design(name: "Dashboard", createdAt: 1, lastActiveAt: 2, boardCount: 4)
        for status in AgentStatus.allCases {
            var pin = pinned
            pin.status = status
            let lists = SidebarDerivation.lists(SidebarSource(
                local: ShepherdState(spaces: [space], agents: [pin, idle, asking, working, done], designs: [design]), designs: true),
                pins: SidebarPins([.local(pin.id)]))
            #expect(lists.sections.map(\.section) == [.done, .pinned, .needsYou, .working, .recents, .designs])
            #expect(lists.all.map(\.title) == ["done", "pinned", "asking", "working", "idle", "Dashboard"])
            #expect(lists.items(collapsed: []).first == .header(.done, count: 1, collapsed: false))
            #expect(Set(lists.all.map(\.id)).count == 6)
            #expect(lists.pinned.first?.leading == .dot(AgentState(status)))
            let items = lists.items(collapsed: [.working, .recents, .designs])
            #expect(items.count == 9, "six headers, three visible rows")
            #expect(lists.visibleRows(collapsed: [.working, .recents, .designs]).map(\.title) == ["done", "pinned", "asking"])
            #expect(lists.shortcutRows(collapsed: [.working, .recents, .designs]).map(\.title) == ["done", "pinned"])
        }
        #expect(SidebarLists().items(collapsed: Set(SidebarActivitySection.allCases)).isEmpty)
    }

    @Test func completionGenerationsIgnoreRepeatedDoneAndRefusedSendButCountAnotherTurn() throws {
        var agent = Fixture.agent("worker", in: Fixture.space("workspace")).agent
        agent.status = .done
        agent.lastActiveAt = 1000
        var source = SidebarSource(local: ShepherdState(agents: [agent]))
        var completions = SidebarCompletions()
        completions.reconcile(source, endpoints: [:])
        let id = SidebarRowID.local(agent.id)
        let first = try #require(completions.records[id])
        completions.reconcile(source, endpoints: [:])
        #expect(completions.records[id] == first)
        source.local.agents[0].lastActiveAt = 2000
        completions.reconcile(source, endpoints: [:])
        #expect(completions.records[id]?.generation == first.generation)
        #expect(completions.records[id]?.completedAt == 1000, "a rejected send does not change the completion age")
        source.completions = completions.records
        #expect(SidebarDerivation.lists(source, seen: [id: first.generation]).done.isEmpty)
        source.local.agents[0].status = .working
        completions.reconcile(source, endpoints: [:])
        source.local.agents[0].status = .done
        completions.reconcile(source, endpoints: [:])
        source.completions = completions.records
        #expect(SidebarDerivation.lists(source, seen: [id: first.generation]).done.map(\.id) == [id])
        #expect(completions.records[id]?.completedAt == 2000, "status edges work even within one millisecond")
    }

    @Test func completionAgeIsOnlyAnActivityAccessoryNotAProjectTreeChange() {
        var agent = Fixture.agent("done", in: Fixture.space("workspace")).agent
        agent.status = .done
        agent.lastActiveAt = 1000
        let sharedRow = SidebarDerivation.localRow(agent, automation: nil, run: nil, needsYou: false, failed: false, since: nil)
        #expect(sharedRow.accessory == .none, "the project tree keeps its existing accessory")
        let lists = SidebarDerivation.lists(SidebarSource(local: ShepherdState(agents: [agent])))
        #expect(lists.done.first?.accessory == .age(since: Date(timeIntervalSince1970: 1)))
    }

    @Test func automationTimesUseSecondsButActivityUsesMilliseconds() {
        var agent = Fixture.agent("run", in: Fixture.space("workspace")).agent
        agent.status = .done
        let automation = Automation(name: "watch", prompt: "p", cwd: "/tmp", agentID: agent.id)
        var source = SidebarSource(local: ShepherdState(agents: [agent], automations: [automation]),
            openRuns: [automation.id: AutomationRun(startedAt: 10, settledAt: 12, result: .finished, agentID: agent.id)])
        var completions = SidebarCompletions()
        completions.reconcile(source, endpoints: [:])
        source.completions = completions.records
        #expect(SidebarDerivation.lists(source).done.first?.accessory == .age(since: Date(timeIntervalSince1970: 12)))
        source.local.agents[0].status = .working
        completions.reconcile(source, endpoints: [:])
        source.local.agents[0].status = .done
        source.local.agents[0].lastActiveAt = 20_000
        completions.reconcile(source, endpoints: [:])
        #expect(completions.records[.local(agent.id)]?.completedAt == 20_000, "a later turn uses its own activity stamp")
    }

    @Test func remoteReconnectKeepsSeenAndDetectsCatchUpAndDeletion() throws {
        let host = UUID(), endpoint = UUID()
        var agent = Fixture.agent("remote", in: Fixture.space("workspace")).agent
        agent.status = .done
        agent.lastActiveAt = 1000
        var source = SidebarSource(local: ShepherdState(), hosts: [
            .init(id: host, name: "horizon", state: ShepherdState(agents: [agent]))
        ])
        let id = SidebarRowID.remote(.init(hostID: host, agentID: agent.id))
        var completions = SidebarCompletions()
        completions.reconcile(source, endpoints: [host: endpoint])
        let first = try #require(completions.records[id]?.generation)
        source.hosts[0].offline = true
        source.hosts[0].state = ShepherdState()
        completions.reconcile(source, endpoints: [host: endpoint])
        #expect(completions.records[id]?.generation == first, "an offline snapshot is not authoritative deletion")
        source.hosts[0].state = ShepherdState(agents: [agent])
        source.hosts[0].offline = false
        completions.reconcile(source, endpoints: [host: endpoint])
        #expect(completions.records[id]?.generation == first)
        source.hosts[0].offline = true
        completions.reconcile(source, endpoints: [host: endpoint])
        source.hosts[0].state.agents[0].lastActiveAt = 2000
        source.hosts[0].offline = false
        completions.reconcile(source, endpoints: [host: endpoint])
        let second = try #require(completions.records[id]?.generation)
        #expect(second != first)
        completions.reconcile(source, endpoints: [host: endpoint])
        #expect(completions.records[id]?.generation == second)
        completions.reconcile(source, endpoints: [host: UUID()])
        #expect(completions.records[id]?.generation != second, "a changed endpoint is another host")
        source.hosts[0].state.agents = []
        completions.reconcile(source, endpoints: [host: endpoint])
        #expect(completions.records[id] == nil)
    }
}
