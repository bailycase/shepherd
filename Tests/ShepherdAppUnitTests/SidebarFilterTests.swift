import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

@MainActor
struct SidebarFilterTests {
    private let space = Fixture.space("acme-web")
    private let build = UUID()
    private let offline = UUID()

    private func thread(_ title: String, _ status: AgentStatus, at: Double, changed: Int = 0, worktree: Bool = false) -> Agent {
        var agent = Fixture.agent(title, in: space).agent
        agent.status = status
        agent.lastActiveAt = at
        agent.checkout = AgentCheckout(branch: "main", changedFiles: changed)
        if worktree { agent.worktreeBranch = "feat/acme" }
        return agent
    }

    @Test func filtersUseStatusAcrossGroupsAndNarrowByCheckoutAndHost() {
        let ask = thread("acme-api", .blocked, at: 5, changed: 1, worktree: true)
        let running = thread("acme-web", .working, at: 4)
        let remote = thread("acme-search", .working, at: 3, changed: 2, worktree: true)
        let idle = thread("acme-docs", .idle, at: 2, changed: 1, worktree: true)
        let stale = thread("acme-tools", .working, at: 1, changed: 1, worktree: true)
        let source = SidebarSource(local: ShepherdState(spaces: [space], agents: [ask, running]), hosts: [
            .init(id: build, name: "acme-build", state: ShepherdState(spaces: [space], agents: [remote, idle])),
            .init(id: offline, name: "acme-spare", state: ShepherdState(spaces: [space], agents: [stale]), offline: true),
        ])
        let lists = SidebarDerivation.lists(source, pins: SidebarPins([.local(ask.id)]))
        func titles(_ chips: Set<SidebarThreadFilters.Chip>, host: UUID? = nil) -> [String] {
            lists.presented(selected: nil, shortcuts: false, filters: .init(chips: chips, host: host)).all.map(\.title)
        }
        #expect(titles([.running]) == ["acme-web", "acme-search"])
        #expect(titles([.needsYou, .hasChanges]) == ["acme-api"])
        #expect(titles([.running, .needsYou, .hasChanges, .worktree]) == ["acme-search", "acme-api"])
        #expect(titles([.hasChanges, .worktree], host: build) == ["acme-search", "acme-docs"])
        #expect(titles([.worktree], host: offline) == ["acme-tools"])
        let empty = lists.presented(selected: nil, shortcuts: false, filters: .init(chips: [.needsYou], host: build))
        #expect(empty.hasNoMatches)
        #expect(empty.items(collapsed: []) == [.noMatches])
        #expect(!lists.presented(selected: nil, shortcuts: false).hasNoMatches)
    }

    @Test func aSentThreadThatMatchesIsGroupedByItsOwnStatusNotItsSenders() {
        let thisMac = UUID()
        let sender = thread("acme-api", .done, at: 1)
        var child = thread("acme-search", .working, at: 3)
        child.dispatchedFrom = DispatchedFrom(hostID: thisMac, hostName: "acme-laptop", agentID: sender.id,
                                              agentTitle: sender.name, dispatchID: UUID(), at: 3)
        let other = thread("acme-web", .working, at: 4)
        let lists = SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [space], agents: [sender, child, other]),
                                                          localFleetID: thisMac))
        #expect(lists.done.contains { $0.fleetNested }, "unfiltered, the child nests under its Done sender")
        let running = lists.presented(selected: nil, shortcuts: false, filters: .init(chips: [.running]))
        #expect(running.working.map(\.title) == ["acme-web", "acme-search"])
        #expect(running.done.isEmpty)
        // Collapsing Done must not hide a running match.
        #expect(running.items(collapsed: [.done]).contains { if case .row(let row) = $0 { row.title == "acme-search" } else { false } })
    }

    @Test func theHostPickerOffersOnlyConnectedHosts() {
        func names(_ hosts: [SidebarSource.Host]) -> [String] {
            SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [space]), hosts: hosts)).filterHosts.map(\.name)
        }
        let connected = SidebarSource.Host(id: build, name: "acme-build", state: ShepherdState(spaces: [space]))
        let spare = SidebarSource.Host(id: offline, name: "acme-spare", state: ShepherdState(spaces: [space]), offline: true)
        #expect(names([spare]) == ["This Mac"], "one connected and one disconnected host: no picker")
        #expect(names([connected, spare]) == ["This Mac", "acme-build"])
    }

    @Test func digitsFollowTheSameDisplayedMatchesAndSkipCollapsedSections() {
        let ask = thread("acme-api", .blocked, at: 40, changed: 1)
        let unmatched = thread("acme-clean", .working, at: 39)
        let running = (1...10).map { thread("acme-\($0)", .working, at: Double(30 - $0), changed: 1) }
        let lists = SidebarDerivation.lists(SidebarSource(local: ShepherdState(spaces: [space], agents: [ask, unmatched] + running)))
        let filters = SidebarThreadFilters(chips: [.hasChanges])
        let view = lists.presented(selected: .local(running[0].id), shortcuts: true, filters: filters)
        let targets = Array(view.shortcutRows.prefix(9))
        #expect(targets.map(\.id) == ([ask] + Array(running.prefix(8))).map { .local($0.id) })
        #expect(targets.map(\.accessory) == (1...9).map { .shortcut("⌘\($0)") })
        #expect(targets[1].selected)
        #expect(view.working[8].accessory == .none)
        let collapsed = lists.presented(selected: nil, shortcuts: true, filters: filters, collapsed: [.needsYou])
        #expect(collapsed.shortcutRows(collapsed: [.needsYou]).first?.accessory == .shortcut("⌘1"))
        #expect(collapsed.shortcutRows(collapsed: [.needsYou]).first?.id == .local(running[0].id))
        #expect(lists.presented(selected: nil, shortcuts: true).shortcutRows.first?.id == .local(unmatched.id))
    }

    @Test func checkoutProjectionRetainsOnlyDirtyVersusClean() {
        var state = ShepherdState(agents: [thread("acme-web", .working, at: 1, changed: 1)])
        let first = SidebarSource.presentationState(state, children: [:])
        state.agents[0].checkout = AgentCheckout(branch: "feat/new", changedFiles: 10)
        #expect(SidebarSource.presentationState(state, children: [:]) == first)
        state.agents[0].checkout?.changedFiles = 0
        #expect(SidebarSource.presentationState(state, children: [:]) != first)
    }
}
