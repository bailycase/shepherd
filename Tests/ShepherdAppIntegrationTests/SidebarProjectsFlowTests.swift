import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar organized by project against a real server: hiding and dragging a project are
/// written to state.json, keys follow the open projects, and switching style keeps the thread on
/// screen selected, opening its project and scrolling it into view.
@Suite("Sidebar projects flow", .mainActorExclusive)
@MainActor
struct SidebarProjectsFlowTests {
    private static let size = CGSize(width: AppLayout.sidebarDefaultWidth, height: 600)

    private func spaces(_ app: AppHarness) -> [Space] {
        ["one", "two", "three"].map { Fixture.space($0, path: app.dir.appendingPathComponent($0).path) }
    }

    @Test func hidingAndMovingAProjectReachTheServer() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let spaces = spaces(app)
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: []))
        vm.settings.sidebarStyle = .projects

        vm.moveProject(spaces[2].id, before: spaces[0].id)
        #expect(vm.sidebarTree.projects.map(\.name) == ["three", "one", "two"])
        try await eventuallyOnMain("the move to be written") { app.server.state.spaces.map(\.name) == ["three", "one", "two"] }

        vm.setProjectHiddenFromSidebar(spaces[1].id, true)
        #expect(vm.sidebarTree.projects.map(\.name) == ["three", "one"])
        #expect(vm.sidebarTree.hiddenProjects.map(\.name) == ["two"])
        try await eventuallyOnMain("the hidden flag to be written") {
            app.server.state.spaces.first { $0.id == spaces[1].id }?.sidebarHidden == true
        }
        vm.setProjectHiddenFromSidebar(spaces[1].id, false)
        try await eventuallyOnMain("the project to come back") {
            app.server.state.spaces.first { $0.id == spaces[1].id }?.sidebarHidden == false
        }
        #expect(vm.sidebarTree.hiddenProjects.isEmpty)
    }

    /// ⌘n and ⌘↑/↓ follow the open projects' threads; a closed project's threads are skipped.
    @Test func digitsAndArrowsFollowTheOpenProjects() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let spaces = spaces(app)
        var fixtures = [
            Fixture.agent("one-a", in: spaces[0], order: 0), Fixture.agent("one-b", in: spaces[0], order: 1),
            Fixture.agent("two-a", in: spaces[1], order: 0), Fixture.agent("three-a", in: spaces[2], order: 0),
        ]
        // Active this past minute: well inside Keep idle threads.
        let now = Date().timeIntervalSince1970 * 1000
        for index in fixtures.indices { fixtures[index].agent.lastActiveAt = now - Double(index) * 1000 }
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: fixtures))
        vm.setSidebarStyle(.projects)
        vm.setProject(.local(spaces[1].id), expanded: false)
        #expect(vm.sidebarShortcutRows.map(\.title) == ["one-a", "one-b", "three-a"])
        #expect(MenuState.Snapshot(vm).agents.map(\.title) == ["one-a", "one-b", "three-a"])

        vm.selectAgentDigit(3)
        #expect(vm.selectedAgentID == fixtures[3].agent.id)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == fixtures[0].agent.id, "wrapping past the last open project")
        vm.setAllProjects(expanded: false)
        #expect(vm.sidebarWalkRows.isEmpty)
    }

    /// Switching to Projects keeps the thread on screen selected: its closed project opens and
    /// its row scrolls into view.
    @Test func switchingStyleOpensAndScrollsToTheSelectedThread() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        let window = OffscreenWindow(size: Self.size, dark: true, SidebarView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        vm.settings.sidebarStyle = .projects
        let last = try #require(vm.sidebarTree.projects.last?.rows.last)
        vm.setAllProjects(expanded: false)
        vm.settings.sidebarStyle = .activity
        vm.selectSidebarRow(last.id)
        ListPerf.settle(window)

        vm.setSidebarStyle(.projects)
        try await eventuallyOnMain("the selected thread's project to open and scroll into view") {
            ListPerf.settle(window)
            guard let scroll = ListPerf.scrollView(in: window), let document = scroll.documentView?.bounds.height else { return false }
            return vm.sidebarWalkRows.contains { $0.id == last.id }
                && scroll.contentView.bounds.maxY > document - 8 * NWDensity.standard.rowHeight
        }
        #expect(vm.selectedSidebarRow == last.id)
    }
}
