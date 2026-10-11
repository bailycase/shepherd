import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Remove project previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct RemoveProjectPreviewTests {
    @Test(arguments: ["empty", "parent", "child", "long"])
    func dialog(state: String) async throws {
        let world = try PreviewWorkspace()
        defer { world.stop() }
        let parent = Space(name: state == "long" ? String(repeating: "Long platform name ", count: 8) : "Platform", path: world.dir.path)
        let child = Space(name: "Hub", path: world.dir.appendingPathComponent("hub").path)
        let target = state == "child" ? child : parent
        let count = state == "empty" ? 0 : state == "long" ? 3 : 1
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        for index in 0..<count {
            let pair = try await world.agent("Work \(index)", in: target, order: index)
            agents.append(pair.0); tabs.append(pair.1)
        }
        try await world.seed(ShepherdState(spaces: [parent, child], tabs: tabs, agents: agents))
        try await Preview.renderMatrix("remove-project-\(state)", size: CGSize(width: 700, height: 620)) {
            SpaceDeleteDialog(vm: world.vm, space: target)
        }
    }
}
