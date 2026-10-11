import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdUI
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Nested project sidebar", .mainActorExclusive)
@MainActor
struct NestedProjectsFlowTests {
    @Test func addingAChildOpensItsParentWithoutChangingSelection() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Platform", path: app.dir.path)
        let fixture = Fixture.agent("Parent work", in: parent, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [parent], agents: [fixture]))
        vm.settings.sidebarStyle = .projects
        vm.selectAgent(fixture.agent.id)
        vm.setProject(.local(parent.id), expanded: false)
        _ = try await vm.handleProjectRequest(.child(parentPath: parent.path, path: app.dir.appendingPathComponent("hub").path, name: "Hub", create: true))
        #expect(!vm.collapsedProjects.contains(SidebarProjectID.local(parent.id).key))
        #expect(vm.presentedSidebarTree.contains { if case .project(let row) = $0 { return row.name == "Hub" && row.parentID == .local(parent.id) }; return false })
        #expect(vm.selectedAgentID == fixture.agent.id)
    }

    @Test func parentAndChildDisclosuresNestRowsAndSelectionReopensBoth() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressTree() }
        }
    }

    private static func pressTree() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Platform", path: app.dir.path)
        let child = Fixture.space("Hub", path: app.dir.appendingPathComponent("hub").path)
        let fixture = Fixture.agent("Child work", in: child, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [child, parent], agents: [fixture]))
        vm.settings.sidebarStyle = .projects
        let window = OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 600), dark: true, SidebarProjectsList(vm: vm))
        defer { window.close() }
        window.layout()
        let parentControl = try #require(window.controls().first { $0.label == "Platform, 1 thread" })
        let childControl = try #require(window.controls().first { $0.label == "Hub, 1 thread" })
        #expect(childControl.frame.minX - parentControl.frame.minX == NWProjectMetrics.chevronSlot + NWProjectMetrics.gap)
        #expect(ControlPress.undersized([parentControl, childControl], minimum: .desktop).isEmpty)
        try window.press("Platform, 1 thread")
        #expect(vm.sidebarShortcutRows.isEmpty)
        // Layout alone does not finish SwiftUI's animated accessibility-tree update.
        try await eventuallyOnMain("the collapsed parent to hide its child") {
            !window.controls().contains { $0.label == "Hub, 1 thread" }
        }
        #expect(!window.controls().contains { $0.label == "Hub, 1 thread" })
        try window.press("Platform, 1 thread")
        try await eventuallyOnMain("the reopened parent to show its child") {
            window.controls().contains { $0.label == "Hub, 1 thread" }
        }
        try window.press("Hub, 1 thread")
        window.layout()
        #expect(vm.sidebarShortcutRows.isEmpty)
        #expect(window.controls().contains { $0.label == "Hub, 1 thread" })
        try window.press("Platform, 1 thread")
        vm.selectAgent(fixture.agent.id)
        vm.openProjectHoldingSelection()
        window.layout()
        #expect(!vm.collapsedProjects.contains(SidebarProjectID.local(parent.id).key))
        #expect(!vm.collapsedProjects.contains(SidebarProjectID.local(child.id).key))
        #expect(vm.sidebarShortcutRows.map(\.title) == ["Child work"])
        try await eventuallyOnMain("selection to reveal the child project") {
            window.controls().contains { $0.label == "Hub, 1 thread" }
        }
        #expect(window.controls().contains { $0.label == "Hub, 1 thread" })
        try ControlPress.perform("New thread in Hub", onLabelContaining: "Hub, 1 thread", under: window.host)
        #expect(vm.selectedSpaceID == child.id)
    }
}
