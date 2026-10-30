import AppKit
import ShepherdCore
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The sidebar's Automations group (Sidebar › Automations): one row per active automation, its run folded under it and
/// never among Working, Done or Recents, and the header, the row, its chevron and the run each do what they say.
@Suite("Sidebar automations controls", .integrationTimeLimit)
struct SidebarAutomationsControlTests {
    @Test func activeAutomationsHaveTheirOwnGroupAndItsControlsWork() async {
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
        var run = Fixture.agent("nightly-deps run", in: space, order: 1)
        run.agent.status = .working
        var state = Fixture.state(spaces: [space], agents: [thread, run])
        let automation = Automation(name: "nightly-deps", prompt: "p", cwd: app.dir.path, agentID: run.agent.id)
        state.automations = [automation]
        let vm = try await app.start(with: state)
        let key = AutomationKey(host: PageHost.localID, automation: automation.id)
        #expect(vm.sidebarLists.automationRows.map(\.name) == ["nightly-deps"])
        #expect(vm.sidebarLists.automations.map(\.title) == ["nightly-deps run"])
        #expect(vm.sidebarLists.working.map(\.title) == ["a thread"], "a run is never in Working")

        let window = OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 600), dark: true, SidebarView(vm: vm))
        defer { window.close() }
        ListPerf.settle(window)
        let labels = window.controls().compactMap(\.label)
        let rowLabel = "nightly-deps, automation, running, 1 run"
        #expect(labels.contains(rowLabel), "the automation's row is drawn: \(labels)")
        #expect(!labels.contains { $0.hasPrefix("nightly-deps run") }, "its run starts folded")

        // The row opens the automation on its page.
        let row = try window.press(rowLabel)
        #expect(ControlPress.undersized([row], minimum: .desktop).isEmpty)
        #expect(vm.shownDestination == .automations && vm.automationsPageSelection == key)

        // Its fold shows the run, which opens its thread.
        let fold = try #require(AccessibilityNode.all(under: window.host).first { $0.label == rowLabel })
        #expect(fold.value == "runs hidden" && fold.perform(action: "Show runs"))
        try await eventuallyOnMain("the run to unfold") { window.controls().contains { $0.label?.hasPrefix("nightly-deps run") == true } }
        try window.press(try #require(window.controls().compactMap(\.label).first { $0.hasPrefix("nightly-deps run") }))
        #expect(vm.selectedAgentID == run.agent.id)

        // The header folds the group: its count stays, its row goes.
        let collapse = try window.press("Automations, 1, expanded")
        #expect(ControlPress.undersized([collapse], minimum: .desktop).isEmpty)
        #expect(vm.collapsedActivitySections.contains(.automations))
        try await eventuallyOnMain("the folded automation row to leave the accessibility tree") {
            !window.controls().contains { $0.label?.hasPrefix("nightly-deps") == true }
                && window.controls().contains { $0.label == "Automations, 1, collapsed" }
        }
        let expand = try window.press("Automations, 1, collapsed")
        #expect(ControlPress.undersized([expand], minimum: .desktop).isEmpty)
        #expect(!vm.collapsedActivitySections.contains(.automations))
        try await eventuallyOnMain("the expanded automation row to return to the accessibility tree") {
            window.controls().contains { $0.label == rowLabel } && window.controls().contains { $0.label == "Automations, 1, expanded" }
        }
    }
}
