import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar's lists against a real server: keyboard selection scrolls a row that was never
/// built into view, ⌘1–9 are the first nine Recents rows, a turn starting moves its thread up
/// Recents, and a question moves it to Needs you with the question's words.
@Suite("Sidebar list", .mainActorExclusive)
@MainActor
struct SidebarListTests {
    private static let size = CGSize(width: AppLayout.sidebarDefaultWidth, height: 600)

    @Test func selectingAnAgentFarDownRecentsScrollsItsRowIntoView() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start(with: ListFixtures.fleet(in: app.dir))
        let window = OffscreenWindow(size: Self.size, dark: true, SidebarView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        let scroll = try #require(ListPerf.scrollView(in: window))
        #expect(scroll.contentView.bounds.minY < 1)

        // The last row in sidebar order, as ⌘↑ from the first row reaches it.
        let last = try #require(vm.sidebarLists.recents.last)
        vm.selectSidebarRow(last.id)

        try await eventuallyOnMain("the sidebar to scroll to the last row") {
            window.layout()
            let document = scroll.documentView?.bounds.height ?? 0
            // The lazy stack's estimate of the rows under the last one it built leaves some slack.
            return scroll.contentView.bounds.maxY > document - 8 * NWDensity.standard.rowHeight
        }
    }

    /// ⌘n selects the nth Recents row, and ⌘↑/↓ walk Needs you then Recents, wrapping.
    @Test func digitsAndArrowsFollowTheSidebarsRows() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        var fixtures = (0..<4).map { Fixture.agent("agent-\($0)", in: space, order: $0) }
        for index in fixtures.indices { fixtures[index].agent.lastActiveAt = Double(100 - index) }
        fixtures[3].agent.status = .blocked
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: fixtures))
        #expect(vm.sidebarLists.needsYou.map(\.title) == ["agent-3"])
        #expect(vm.sidebarLists.recents.map(\.title) == ["agent-0", "agent-1", "agent-2"])

        vm.selectAgentDigit(2)
        #expect(vm.selectedAgentID == fixtures[1].agent.id)
        vm.selectAgentDigit(9)
        #expect(vm.selectedAgentID == fixtures[1].agent.id, "no ninth row: nothing moves")
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == fixtures[2].agent.id)
        vm.selectAdjacentAgent(1)
        #expect(vm.selectedAgentID == fixtures[3].agent.id, "past Recents' end, wrapping to Needs you")
        #expect(MenuState.Snapshot(vm).agents.map(\.title) == ["agent-0", "agent-1", "agent-2"], "the Agent menu's ⌘1–9")
    }

    /// The status extension reports a turn starting: the thread moves up Recents. A repeated
    /// report moves nothing; the question pi asks puts it in Needs you with the question's words.
    @Test func aTurnStartingMovesItsThreadUpAndAQuestionMovesItToNeedsYou() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("one", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let quiet = try await app.liveAgent("quiet", in: space, order: 0)
        let asker = try await app.liveAgent("asker", in: space, order: 1)
        try await app.server.putState(Fixture.state(spaces: [space], agents: [quiet, asker]))
        try await eventuallyOnMain("both agents in Recents") { vm.sidebarLists.recents.count == 2 }
        #expect(vm.sidebarLists.recents.map(\.title) == ["asker", "quiet"], "untimed: newest first")

        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: quiet.agent.id, status: .working))
        try await eventuallyOnMain("the working thread to lead Recents") {
            vm.sidebarLists.recents.map(\.title) == ["quiet", "asker"]
        }
        let started = try #require(app.server.state.agents.first { $0.id == quiet.agent.id }?.lastActiveAt)
        try reporter.send(.setAgentStatus(agentID: quiet.agent.id, status: .working))
        // The socket keeps order: once a later report lands, the repeated one has.
        try reporter.send(.setAgentStatus(agentID: asker.agent.id, status: .done))
        try await eventuallyOnMain("the later report to land") {
            app.server.state.agents.first { $0.id == asker.agent.id }?.status == .done
        }
        #expect(app.server.state.agents.first { $0.id == quiet.agent.id }?.lastActiveAt == started)

        let ready = try await app.readyThread(asker.agent.id)
        _ = try await app.server.nativeThread(agentID: asker.agent.id, request: .send(
            expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID(),
            text: "ask", delivery: .followUp))
        try reporter.send(.setAgentStatus(agentID: asker.agent.id, status: .blocked))
        try await eventuallyOnMain("the question to reach Needs you") {
            guard let row = vm.sidebarLists.needsYou.first, row.id == .local(asker.agent.id),
                  case .reason(let reason) = row.accessory else { return false }
            return reason == "Clear session?"
        }
        #expect(vm.sidebarLists.recents.map(\.title) == ["quiet"])
    }
}
