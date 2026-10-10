import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Remove project controls", .mainActorExclusive)
@MainActor
struct RemoveProjectTests {
    @Test func removingAParentKeepsItsFoldersAndChildProject() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.remove(parent: true) }
        }
    }

    @Test func removingAChildKeepsItsFoldersParentAndSibling() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.remove(parent: false) }
        }
    }

    private static func remove(parent removingParent: Bool) async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let root = app.dir.appendingPathComponent("platform")
        let childURL = root.appendingPathComponent("hub")
        let siblingURL = root.appendingPathComponent("infra")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: true)
        let files = [root.appendingPathComponent("AGENTS.md"), childURL.appendingPathComponent("source.txt"), siblingURL.appendingPathComponent("config.txt")]
        let bytes = Data("keep this file exactly\n".utf8)
        for file in files { try bytes.write(to: file) }
        let parent = Fixture.space("Platform", path: root.path)
        let child = Fixture.space("Hub", path: childURL.path)
        let sibling = Fixture.space("Infrastructure", path: siblingURL.path)
        let parentAgent = try await app.liveAgent("parent work", in: parent)
        let childAgent = try await app.liveAgent("child work", in: child)
        let siblingAgent = Fixture.agent("sibling work", in: sibling)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, child, sibling], agents: [parentAgent, childAgent, siblingAgent]))
        vm.settings.sidebarStyle = .projects
        let target = removingParent ? parent : child
        let doomed = removingParent ? parentAgent : childAgent
        let kept = removingParent ? childAgent : parentAgent
        vm.selectAgent(doomed.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        let project = try #require(vm.presentedSidebarTree.compactMap {
            if case .project(let row) = $0, row.space == target.id { return row }; return nil
        }.first)
        let menu = OffscreenWindow(size: CGSize(width: 550, height: 450), dark: true,
                                   VStack { SidebarProjectMenu(vm: vm, project: project) })
        defer { menu.close() }
        menu.layout()
        try menu.press("Remove Space…")
        #expect(vm.spaceDeleteTarget == target.id)
        try await eventuallyOnMain("remove confirmation") { window.window.attachedSheet?.contentView != nil }
        let first = try #require(window.window.attachedSheet?.contentView)
        #expect(AccessibilityNode.all(under: first).contains { ($0.value ?? $0.label ?? "").contains("The local folder and all its files are kept") })
        let cancel = try ControlPress.press("Cancel", under: first)
        #expect(ControlPress.undersized([cancel], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("cancelled removal") { window.window.attachedSheet == nil }
        #expect(vm.state.spaces.count == 3 && app.server.state.spaces.count == 3)
        for file in files { #expect(try Data(contentsOf: file) == bytes) }

        // The Settings row's accessibility action reaches its actual context-menu operation.
        let settingsAction = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true,
                                             ProjectsSettings(vm: vm, model: vm.projects))
        defer { settingsAction.close() }
        try await eventuallyOnMain("settings registrations loaded") { vm.projects.visible.count == 3 }
        settingsAction.layout()
        try ControlPress.perform("Remove Space…", onLabelContaining: "Open \(target.name)", under: settingsAction.host)
        try await eventuallyOnMain("remove confirmation again") { window.window.attachedSheet?.contentView != nil }
        let second = try #require(window.window.attachedSheet?.contentView)
        let remove = try ControlPress.press("Remove space", under: second)
        #expect(ControlPress.undersized([remove], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("project removed and persisted") {
            !app.server.state.spaces.contains { $0.id == target.id } && !vm.state.spaces.contains { $0.id == target.id }
        }
        #expect(app.server.state.spaces.count == 2)
        #expect(app.server.state.spaces.contains(sibling))
        #expect(app.server.state.spaces.contains(removingParent ? child : parent))
        #expect(!app.server.state.agents.contains { $0.id == doomed.agent.id })
        #expect(app.server.state.agents.contains { $0.id == kept.agent.id })
        let server = app.server
        let deadSession = try #require(doomed.piPane.sessionID)
        let liveSession = try #require(kept.piPane.sessionID)
        try await eventuallyAsync("removed project's process stopped") { await server.sessionInfo(sessionID: deadSession)?.isAlive != true }
        #expect(await server.sessionInfo(sessionID: liveSession)?.isAlive == true)
        if removingParent { #expect(vm.sidebarTree.projects.allSatisfy { $0.parentID == nil }) }
        for file in files { #expect(try Data(contentsOf: file) == bytes) }
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: childURL.path))
        await vm.projects.load(vm.projectsSources, force: true)
        #expect(vm.projects.rows.contains { $0.project.directory == target.path && $0.project.projectID == nil })
    }
}
