import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdApp

/// Add space (ProjectAdd board): a root space, a child inside its parent's folder (it inherits), one
/// elsewhere (listed under it only), a refused folder, and another host, where no parent can be chosen.
@Suite("Add space previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct AddSpacePreviewTests {
    @Test(arguments: ["root", "child", "elsewhere", "error", "remote"])
    func addSpace(state: String) async throws {
        let local = ProjectsHost(id: "local", name: "This Mac", known: []), build = ProjectsHost(id: "build", name: "Build-01", known: [])
        let payments = SpaceID()
        let rows = [ProjectsRow(host: local, project: ProjectSummary(directory: "/code/payments", name: "payments", displayPath: "~/code/payments", summary: "", projectID: payments)),
                    ProjectsRow(host: build, project: ProjectSummary(directory: "/srv/daemon", name: "daemon", displayPath: "/srv/daemon", summary: "", projectID: SpaceID()))]
        let model = AddSpaceModel(hosts: [local, build], rows: rows, hostID: "local") { _ in }
        switch state {
        case "child": model.name = "payments-refunds"; model.path = "/code/payments/refunds"; model.parentID = payments
        case "elsewhere": model.name = "payments-docs"; model.path = "/code/payments-docs"; model.parentID = payments
        case "error":
            model.name = "payments-docs"; model.path = "code/payments-docs"
            _ = await model.submit()
        case "remote": model.hostID = "build"; model.name = "worker"; model.path = "/srv/worker"
        default: model.name = "payments-docs"; model.path = "~/code/payments-docs"
        }
        try await Preview.renderMatrix("add-space-\(state)", size: CGSize(width: AppLayout.spaceAddWidth, height: state == "child" || state == "elsewhere" ? 480 : 400)) {
            AddSpaceSheet(model: model, list: { _, _ in throw ProjectFileError("preview", "") }, dismiss: {})
                .background(Color.sh.bgWindow)
        }
    }
}
