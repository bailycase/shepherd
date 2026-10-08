import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Project rename previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct ProjectRenamePreviewTests {
    @Test func logicalOrganizationKeepsPhysicalInheritanceLabels() async throws {
        let world = try await ProjectsPreviewWorld(empty: true)
        defer { world.stop() }
        let a = Space(name: "Platform A", path: world.local.dir.appendingPathComponent("a").path)
        let b = Space(name: "Platform B", path: world.local.dir.appendingPathComponent("b").path)
        let child = Space(name: "docs", path: a.path + "/docs", parentID: b.id, parentIsExplicit: true)
        for space in [a, b, child] { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(atPath: a.path + "/.pi", withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"docs":{"command":"true"}}}"#.utf8).write(to: URL(fileURLWithPath: a.path + "/.pi/mcp.json"))
        try await world.local.server.putState(ShepherdState(spaces: [a, b, child]))
        world.vm.adopt(world.local.server.state)
        await world.vm.projects.load(world.vm.projectsSources, force: true)
        try await Preview.renderMatrix("projects-explicit-organization", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }

    @Test(arguments: ["parent", "child", "long", "empty", "invalid"])
    func rename(state: String) async throws {
        let world = try PreviewWorkspace()
        defer { world.stop() }
        let parent = Space(name: "Platform", path: world.dir.path)
        var child = Space(name: state == "long" ? String(repeating: "Long child project name ", count: 8) : state == "empty" ? "" : "docs", path: world.dir.appendingPathComponent("docs").path)
        child.parentID = parent.id; child.parentIsExplicit = true
        try await world.seed(ShepherdState(spaces: [parent, child]))
        try await Preview.renderMatrix("rename-project-\(state)", size: CGSize(width: 650, height: 460)) {
            ProjectRenameDialog(vm: world.vm, space: state == "parent" ? parent : child,
                                error: state == "invalid" ? ProjectRenameDialog.problem(String(repeating: "x", count: 257)) : nil)
        }
    }
}
