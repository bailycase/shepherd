import Foundation
import ShepherdCore
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The new Projects in the sidebar (ProjectLead-Activity, -AddsSpace): where the group sits in
/// Activity, that a Project is never a thread row, and that nothing is invented for a Project that
/// has no lifecycle yet.
@Suite("Logical projects in the sidebar")
@MainActor
struct LogicalProjectSidebarTests {
    private func project(_ name: String) -> SidebarLogicalProject {
        SidebarLogicalProject(ref: LogicalProjectRef(home: .local, id: ProjectID()), name: name, hostName: nil)
    }

    private func lists() -> SidebarLists {
        let space = Fixture.space("work")
        var asking = Fixture.agent("asking", in: space).agent
        asking.status = .blocked
        asking.waitingOn = "Approve?"
        var working = Fixture.agent("working", in: space).agent
        working.status = .working
        var done = Fixture.agent("done", in: space).agent
        done.status = .done
        let idle = Fixture.agent("idle", in: space).agent
        let design = Design(name: "Dashboard", createdAt: 1, lastActiveAt: 2, boardCount: 4)
        return SidebarDerivation.lists(SidebarSource(
            local: ShepherdState(spaces: [space], agents: [asking, working, done, idle], designs: [design]), designs: true))
    }

    /// The final board order with the user's override: Designs, Needs you, Working, Done, Projects, Recents.
    @Test func activityListsDesignsNeedsYouWorkingDoneProjectsRecents() {
        let items = lists().items(collapsed: [], projects: [project("Gamecards")])
        let headers = items.compactMap { item -> SidebarActivitySection? in
            if case .header(let section, _, _) = item { section } else { nil }
        }
        #expect(headers == [.designs, .needsYou, .working, .done, .projects, .recents])
    }

    @Test func projectsSitBetweenDoneAndRecentsEvenWithNone() {
        let items = lists().items(collapsed: [], projects: [])
        let headers = items.compactMap { item -> (SidebarActivitySection, Int)? in
            if case .header(let section, let count, _) = item { (section, count) } else { nil }
        }
        let index = try! #require(headers.firstIndex { $0.0 == .projects })
        #expect(headers[index - 1].0 == .done && headers[index + 1].0 == .recents)
        #expect(headers[index].1 == 0, "the header and its New project chip are how the first one is made")
    }

    @Test func withTheExperimentOffActivityDrawsNoProjectsHeaderRowsOrChipEvenWithNone() {
        let threads = lists()
        for shown in [[], [project("A")]] {
            let items = threads.items(collapsed: [], projects: shown, showsProjects: false)
            #expect(!items.contains { if case .header(.projects, _, _) = $0 { true } else if case .project = $0 { true } else { false } })
            #expect(items == threads.items(collapsed: [], projects: [], showsProjects: false), "stored Projects change nothing while off")
        }
        // Nothing but threads: an empty workspace has no items at all, not a lone Projects header.
        #expect(SidebarLists().items(collapsed: [], projects: [project("A")], showsProjects: false).isEmpty)
        #expect(threads.items(collapsed: [], projects: []).contains(.header(.projects, count: 0, collapsed: false)), "on is unchanged")
    }

    @Test func pinnedNeverDisplacesADrawnGroup() {
        let space = Fixture.space("work")
        let pinned = Fixture.agent("pinned", in: space).agent
        let working = { () -> Agent in var a = Fixture.agent("working", in: space).agent; a.status = .working; return a }()
        let lists = SidebarDerivation.lists(
            SidebarSource(local: ShepherdState(spaces: [space], agents: [pinned, working])),
            pins: SidebarPins([.local(pinned.id)]))
        let headers = lists.items(collapsed: [], projects: [project("P")]).compactMap { item -> SidebarActivitySection? in
            if case .header(let section, _, _) = item { section } else { nil }
        }
        #expect(headers == [.working, .pinned, .projects, .recents].filter { headers.contains($0) })
        #expect(headers.firstIndex(of: .projects)! > headers.firstIndex(of: .working)!)
    }

    @Test func aFoldedProjectsGroupKeepsItsCountAndHidesItsRows() {
        let two = [project("A"), project("B")]
        let items = SidebarLists().items(collapsed: [.projects], projects: two)
        #expect(items == [.header(.projects, count: 2, collapsed: true)])
        let open = SidebarLists().items(collapsed: [], projects: two)
        #expect(open.count == 3)
    }

    @Test func aProjectIsNeverAThreadRowAndHasNoInventedStatus() {
        let all = lists()
        #expect(!all.all.contains { $0.title == "Gamecards" })
        let fresh = project("Gamecards")
        #expect(fresh.summary == nil && fresh.needsYou == false, "status comes from a real lifecycle, never a placeholder")
    }
}
