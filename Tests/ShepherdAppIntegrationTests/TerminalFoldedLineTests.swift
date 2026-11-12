import AppKit
import Foundation
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A thread whose terminal panel is maximized shows as one folded line with its state (TerminalStates). A status
/// report for that thread redraws the line alone, not the layout around it, and another thread's report redraws nothing.
@Suite("Terminal folded line", .mainActorExclusive)
@MainActor
struct TerminalFoldedLineTests {
    @Test func aStatusEdgeRedrawsOnlyTheFoldedLine() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let shown = try await app.liveAgent("shown", in: space, order: 0, auxiliary: 1)
        let other = try await app.liveAgent("other", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [shown, other]))
        vm.selectAgent(shown.agent.id)
        MountedWorkspace.markEveryLayoutShown(vm)
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true, WorkspaceView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("both layouts to mount") { vm.mountedTabs.count == 2 }
        let key = TerminalPanelKey(host: nil, tab: shown.tab.id)
        vm.toggleTerminalMaximized()
        #expect(vm.terminalPanels.panel(key).shown && vm.terminalPanels.panel(key).maximized)
        try await quiet(window, keys: ["terminal.foldedThread", "layout.agentLayout"])

        func report(_ agent: AgentFixture, _ status: AgentStatus) -> [String: Int] {
            var next = vm.state
            next.agents[next.agents.firstIndex { $0.id == agent.agent.id }!].status = status
            return ListPerf.counting { ListPerf.time(window) { vm.adopt(next) } }
        }

        let own = report(shown, .working)
        #expect(own["terminal.foldedThread", default: 0] >= 1, "the folded line takes its thread's status: \(own)")
        #expect(own["layout.agentLayout", default: 0] == 0, "\(own)")
        #expect(vm.agentLive(shown.agent.id).status == .working)

        let elsewhere = report(other, .working)
        #expect(elsewhere["terminal.foldedThread", default: 0] == 0, "\(elsewhere)")
        #expect(elsewhere["layout.agentLayout", default: 0] == 0, "\(elsewhere)")
        #expect(vm.agentLive(other.agent.id).status == .working)

        // Unfolded, the line reads nothing: the report reaches no view.
        vm.toggleTerminalMaximized()
        #expect(!vm.terminalPanels.panel(key).maximized)
        try await quiet(window, keys: ["terminal.foldedThread", "layout.agentLayout"])
        let unfolded = report(shown, .done)
        #expect(unfolded["terminal.foldedThread", default: 0] == 0, "\(unfolded)")
        #expect(unfolded["layout.agentLayout", default: 0] == 0, "\(unfolded)")
        #expect(vm.agentLive(shown.agent.id).status == .done)
    }

    /// Settles until `keys` stop ticking.
    private func quiet(_ window: OffscreenWindow, keys: [String]) async throws {
        var calm = 0
        try await eventuallyOnMain("the folded layout to settle", timeout: .seconds(60)) {
            ListPerf.settle(window)
            let counts = ListPerf.counting { ListPerf.settle(window) }
            calm = keys.allSatisfy { counts[$0, default: 0] == 0 } ? calm + 1 : 0
            return calm >= 5
        }
    }
}
