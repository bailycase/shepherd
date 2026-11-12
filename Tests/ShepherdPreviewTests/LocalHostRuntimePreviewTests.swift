import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Projects run on the host (`RuntimeHosting`) and draw as This Mac's own, as the in-process
/// app drew them.
extension PreviewTests {
    /// The Projects page and the sidebar with a Project's working threads, its workers started by the
    /// runtime on the stub engine.
    @Test func localHostProjectsMatchTheInProcessBaseline() async throws {
        try StubPi.installAsEngine()
        let folder = try makeScratchDirectory("sample-app")
        let space = Space(name: "sample-app", path: folder.path)
        let projectID = ProjectID()
        let prompts = [("Reading list research", "slow"), ("Library API draft", "slow")]
        let workspace = try PreviewWorkspace()
        workspace.settings.projectsEnabled = true
        defer { workspace.stop() }
        try await workspace.seed(ShepherdState(spaces: [space]))
        _ = try await workspace.server.logicalProjects(.create(projectID: projectID, name: "Sample App",
                                                               goal: "Build a shared reading list for a small team", linkedSpaceIDs: [space.id]))
        let vm = workspace.vm, server = workspace.server
        try await eventuallyOnMain("the Project arrives") { vm.state.projects == server.state.projects }
        let ref = LogicalProjectRef(home: .local, id: projectID)
        vm.openLogicalProject(ref)
        try await Preview.render("this-mac-project", size: CGSize(width: 1368, height: 900)) {
            LogicalProjectDestination(vm: vm).frame(width: 1368).background(Color.sh.bgWindow)
        }
        // Two workers the host's runtime starts, from the app's own Project model.
        for (index, (title, prompt)) in prompts.enumerated() {
            try await eventuallyOnMain("the app's copy is current") { vm.logicalProjects.project(ref) != nil && !vm.logicalProjects.busy.contains(ref) }
            #expect(await vm.logicalProjects.run(ref, .assign(operationID: UUID(), spaceID: space.id, title: title, prompt: prompt)),
                    "\(vm.logicalProjects.failure?.message ?? "")")
            try await eventuallyOnMain("worker \(index + 1) works", timeout: .seconds(30)) {
                vm.state.projects.first?.tasks.count == index + 1 && vm.state.projects.first?.tasks.allSatisfy { $0.phase == .running } == true
            }
        }
        // Each worker's own thread, read through the host, says when it started.
        let workers = (vm.state.projects.first?.tasks ?? []).map(\.workerAgentID)
        for id in workers { Task { await vm.threadStores.store(for: id).run(request: { try await vm.nativeThread(id, request: $0) }) } }
        try await Preview.render("this-mac-project-working", size: CGSize(width: 1368, height: 900),
                                 ready: { workers.allSatisfy { vm.workerStarted($0) != nil } }) {
            LogicalProjectDestination(vm: vm).frame(width: 1368).background(Color.sh.bgWindow)
        }
        vm.destination = nil
        for style in [SHSidebarStyle.activity, .projects] {
            vm.settings.sidebarStyle = style
            try await Preview.render("this-mac-project-sidebar-\(style.rawValue)", size: CGSize(width: 232, height: 820)) { SidebarView(vm: vm) }
        }
        for surface in ["project", "project-working", "project-sidebar-activity", "project-sidebar-projects"] { try expectBaseline("this-mac-\(surface)") }
    }
}
