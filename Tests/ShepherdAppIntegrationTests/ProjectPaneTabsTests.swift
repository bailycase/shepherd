import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Project page's tabs as VoiceOver reads them: the tab already on screen is selected text (activating it would do nothing), and
/// Overview, which toggles the pane, is a button even while it is selected. Read from the accessibility tree of an offscreen window;
/// each scenario runs in its own process (`ControlPress`).
@Suite("Project pane tabs", .mainActorExclusive)
@MainActor
struct ProjectPaneTabsTests {
    private struct TabsError: Error { let message: String }

    @Test func theCurrentTabIsSelectedAndNotAButtonWhileSelectedOverviewStillPresses() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.reading() } }
        expectScenarioCompleted(result)
    }

    private static func reading() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let vm = try await app.start(with: Fixture.state(spaces: [], agents: []))
        let id = ProjectID()
        guard case .project(let project) = try await app.server.logicalProjects(.create(projectID: id, name: "Sample App", goal: "", linkedSpaceIDs: [])) else {
            throw TabsError(message: "no project")
        }
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == project.revision }
        vm.openLogicalProject(LogicalProjectRef(home: .local, id: id))
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the pane header") {
            window.layout()
            return AccessibilityNode.all(under: window.host).contains { $0.label == "Threads" }
        }
        func node(_ label: String) throws -> AccessibilityNode {
            let found = AccessibilityNode.all(under: window.host).filter { $0.label == label }
            guard found.count == 1 else { throw TabsError(message: "\(found.count) elements are labelled \(label)") }
            return found[0]
        }

        // Threads is the pane's current tab: selected, and not a button.
        #expect(vm.logicalProjectPaneTab == .threads && vm.logicalProjectPaneOpen)
        let threads = try node("Threads")
        #expect(threads.isSelected, "the current tab says it is selected")
        #expect(threads.role != ControlRole.button, "the current tab is not a button: \(threads.role ?? "no role")")
        // The other tabs switch the pane, so they are buttons and not selected.
        let files = try node("Files")
        #expect(files.role == ControlRole.button && !files.isSelected)

        // Overview is the pane's switch: selected while the pane is open, and still a button that closes it.
        let overview = try node("Overview")
        #expect(overview.isSelected && overview.role == ControlRole.button)
        try ControlPress.press("Overview", under: window.host)
        try await eventuallyOnMain("the pane to close") { !vm.logicalProjectPaneOpen }
    }
}
