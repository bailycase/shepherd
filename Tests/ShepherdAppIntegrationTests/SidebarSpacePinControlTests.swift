import AppKit
import ShepherdCore
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Sidebar space pin controls", .integrationTimeLimit)
struct SidebarSpacePinControlTests {
    @Test func pinLiftsAChildAboveSpacesAndUnpinRestoresItsParent() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pinning() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor private static func pinning() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Space(name: "Platform", path: app.dir.path)
        let child = Space(name: "Hub", path: app.dir.path + "/hub", parentID: parent.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let agent = Fixture.agent("Hub work", in: child, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, child], agents: [agent]))
        vm.settings.sidebarStyle = .projects
        vm.settings.projectsEnabled = true
        vm.setProject(.local(parent.id), expanded: true)
        vm.setProject(.local(child.id), expanded: true)
        let window = OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 650), dark: true, SidebarView(vm: vm))
        defer { window.close() }

        func row() throws -> SidebarProjectRow {
            try #require(vm.presentedSidebarTree.compactMap { item -> SidebarProjectRow? in
                if case .project(let row) = item, row.space == child.id { return row }; return nil
            }.first)
        }
        func pressMenu(_ title: String) throws {
            let project = try row()
            let menu = OffscreenWindow(size: CGSize(width: 550, height: 500), dark: true,
                                       VStack { SidebarProjectMenu(vm: vm, project: project) })
            defer { menu.close() }
            menu.layout()
            let control = try menu.press(title)
            #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty)
        }

        try pressMenu("Pin")
        vm.setProject(.local(parent.id), expanded: false)
        #expect(vm.spacePins.contains(child.id))
        #expect(try row().depth == 0)
        let headers = vm.presentedSidebarTree.compactMap { item -> String? in
            switch item {
            case .leadHeader: "Projects"
            case .header(.pinnedSpaces): "Pinned"
            case .header(.projects): "Spaces"
            default: nil
            }
        }
        #expect(headers == ["Projects", "Pinned", "Spaces"])
        #expect(vm.sidebarShortcutRows.map(\.title) == ["Hub work"])
        try await eventuallyOnMain("the pinned child to remain visible outside its collapsed parent") {
            window.controls().contains { $0.label == "Hub, 1 thread, pinned" }
        }
        let collapse = try window.press("Hub, 1 thread, pinned")
        #expect(ControlPress.undersized([collapse], minimum: .desktop).isEmpty)
        #expect(vm.collapsedProjects.contains(SidebarProjectID.local(child.id).key))
        #expect(vm.sidebarShortcutRows.isEmpty)
        try await eventuallyOnMain("the pinned child to collapse") {
            window.controls().contains { $0.label == "Hub, 1 thread, pinned" && $0.value == "collapsed" }
        }
        try window.press("Hub, 1 thread, pinned")
        #expect(!vm.collapsedProjects.contains(SidebarProjectID.local(child.id).key))
        try await eventuallyOnMain("the pinned thread to appear") {
            window.controls().contains { $0.label?.hasPrefix("Hub work") == true }
        }
        let thread = try window.press(try #require(window.controls().first { $0.label?.hasPrefix("Hub work") == true }?.label))
        #expect(ControlPress.undersized([thread], minimum: .desktop).isEmpty)
        #expect(vm.selectedAgentID == agent.agent.id)

        try ControlPress.perform("New thread in Hub", onLabelContaining: "Hub, 1 thread, pinned", under: window.host)
        #expect(vm.destination == .newThread)
        #expect(vm.newThread.place?.space == child.id && vm.newThread.place?.host == nil)

        try pressMenu("Unpin")
        #expect(!vm.spacePins.contains(child.id))
        #expect(!vm.sidebarTree.sections.contains { $0.header == .pinnedSpaces })
        #expect(vm.sidebarTree.projects.first { $0.space == child.id }?.ancestorIDs == [.local(parent.id)])
        #expect(app.server.state.spaces.first { $0.id == child.id }?.parentID == parent.id)
        #expect(app.server.state.spaces.map(\.id) == [parent.id, child.id])
    }
}
