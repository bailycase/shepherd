import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdUI
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Thread move previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor struct ThreadMovePreviewTests {
    @Test(arguments: ["before", "after", "long", "empty", "refused"])
    func movedThread(state: String) async throws {
        let world = try PreviewWorkspace()
        defer { world.stop() }
        let parent = Space(name: "Platform", path: world.dir.path)
        let child = Space(name: state == "long" ? "Website with a long space name that must truncate" : "Website",
                          path: world.dir.path + "/website", parentID: parent.id, parentIsExplicit: true)
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let (agent, tab) = try await world.agent(state == "long" ? "Investigate a long thread title before moving it into the project" : "Investigate login", in: parent, order: 0,
                                               status: state == "refused" ? .working : .idle)
        try await world.seed(ShepherdState(spaces: [parent, child], tabs: state == "empty" ? [] : [tab], agents: state == "empty" ? [] : [agent]))
        world.vm.settings.sidebarStyle = .projects
        world.vm.collapsedProjects = []
        if state == "after" || state == "long" { try await world.vm.moveThread(agent.id, to: child.id) }
        if state == "refused" {
            do { try await world.vm.moveThread(agent.id, to: child.id) }
            catch { world.vm.remoteActionError = String(describing: error) }
            let message = try #require(world.vm.remoteActionError)
            try await Preview.renderMatrix("thread-move-refused", size: CGSize(width: 540, height: 280)) {
                ActionErrorDialog(message: message) {}
            }
        } else {
            try await Preview.renderMatrix("thread-move-\(state)", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 550)) {
                SidebarView(vm: world.vm)
            }
        }
        if state == "before" {
            try await Preview.renderMatrix("thread-move-menu", size: CGSize(width: 300, height: 140)) {
                VStack { ThreadMoveMenu(vm: world.vm, row: .local(agent.id)).items }
                    .padding(NW.Space.m).background(Color.nw.bgBase)
            }
        }
    }
}
