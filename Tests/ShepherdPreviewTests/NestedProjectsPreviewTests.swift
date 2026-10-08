import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdUI
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Nested sidebar previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct NestedProjectsPreviewTests {
    @Test(arguments: ["open", "parent-closed", "child-closed", "empty", "long", "attention", "explicit-parent"])
    func sidebar(state: String) async throws {
        let world = try PreviewWorkspace()
        defer { world.stop() }
        let parent = Space(name: state == "long" ? "Platform with a very long project name that must truncate" : "Platform", path: world.dir.path)
        let hub = Space(name: state == "long" ? "Hub with a very long child project name that must truncate" : "Hub", path: world.dir.appendingPathComponent("hub").path)
        let infra = Space(name: "Infrastructure", path: world.dir.appendingPathComponent("infra").path)
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        if state != "empty" {
            for (index, space) in [parent, hub, infra].enumerated() {
                let row = try await world.agent(index == 0 ? "Platform work" : "Child work \(index)", in: space, order: index,
                                                status: state == "attention" && index == 1 ? .blocked : .working)
                agents.append(row.0); tabs.append(row.1)
            }
        }
        try await world.seed(ShepherdState(spaces: [hub, infra, parent], tabs: tabs, agents: agents))
        let vm = world.vm
        vm.settings.sidebarStyle = .projects
        if state == "explicit-parent" {
            _ = try await vm.handleProjectRequest(.edit(projectID: hub.id, request: .init(parentProjectID: infra.id.rawValue)))
        }
        if state == "parent-closed" || state == "attention" { vm.setProject(.local(parent.id), expanded: false) }
        if state == "child-closed" { vm.setProject(.local(hub.id), expanded: false) }
        try await Preview.renderMatrix("sidebar-nested-\(state)", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 600)) {
            SidebarView(vm: vm)
        }
    }
}
