import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

/// Add space (ProjectAdd board): a root space, a child space with its inherited summary, a refused
/// folder, and another host, where no parent can be chosen.
@Suite("Add space previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct AddSpacePreviewTests {
    @Test(arguments: ["root", "child", "error", "remote"])
    func addSpace(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let vm = world.vm
        let hostRow = try #require(vm.projects.rows.first { $0.host.id == "local" })
        let parent = try #require(vm.projects.rows.first { $0.host.id == "local" && $0.project.name == "payments" })
        let model = vm.addSpaceModel(host: hostRow.host)
        switch state {
        case "child":
            model.name = "payments-refunds"; model.path = "~/code/payments-refunds"; model.parentID = parent.project.projectID
        case "error":
            model.name = "payments-docs"; model.path = "code/payments-docs"
            _ = await model.submit()
        case "remote":
            model.hostID = try #require(vm.projects.hosts.first { $0.id != "local" }?.id)
            model.name = "daemon"; model.path = "/srv/daemon"
        default:
            model.name = "payments-docs"; model.path = "~/code/payments-docs"
        }
        try await Preview.renderMatrix("add-space-\(state)", size: CGSize(width: AppLayout.spaceAddWidth, height: state == "child" ? 480 : 400)) {
            AddSpaceSheet(model: model, list: { _, _ in throw ProjectFileError("preview", "") }, dismiss: {})
                .background(Color.sh.bgWindow)
        }
    }
}
