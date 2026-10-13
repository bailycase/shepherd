import AppKit
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar's Automations group (Sidebar › Automations): runs sit under their own header, never
/// among Working, Done or Recents, and the header and each run do what they say.
@Suite("Sidebar automations controls", .integrationTimeLimit)
struct SidebarAutomationsControlTests {
    @Test func runsHaveTheirOwnGroupAndItsControlsWork() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressGroup() }
        }
    }

    @MainActor
    private static func pressGroup() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("one", path: app.dir.path)
        var thread = Fixture.agent("a thread", in: space, order: 0)
        thread.agent.status = .working
        var run = Fixture.agent("nightly-deps", in: space, order: 1)
        run.agent.status = .working
        var state = Fixture.state(spaces: [space], agents: [thread, run])
        state.automations = [Automation(name: "nightly-deps", prompt: "p", cwd: app.dir.path, agentID: run.agent.id)]
        let vm = try await app.start(with: state)
        #expect(vm.sidebarLists.automations.map(\.title) == ["nightly-deps"])
        #expect(vm.sidebarLists.working.map(\.title) == ["a thread"], "a run is never in Working")

        let window = OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 600), dark: true, SidebarView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        let labels = window.controls().compactMap(\.label)
        #expect(labels.contains { $0.hasPrefix("nightly-deps") }, "the run's row is drawn: \(labels)")

        // The run opens its thread.
        let row = try window.press(try #require(labels.first { $0.hasPrefix("nightly-deps") }))
        #expect(ControlPress.undersized([row], minimum: .desktop).isEmpty)
        #expect(vm.selectedAgentID == run.agent.id)

        // The header folds the group: its count stays, its row goes.
        try window.press("Automations, 1, expanded")
        ListPerf.settle(window)
        #expect(vm.collapsedActivitySections.contains(.automations))
        #expect(!window.controls().contains { $0.label?.hasPrefix("nightly-deps") == true })
        try window.press("Automations, 1, collapsed")
        ListPerf.settle(window)
        #expect(!vm.collapsedActivitySections.contains(.automations))
    }
}
