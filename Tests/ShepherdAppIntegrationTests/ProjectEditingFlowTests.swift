import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Project edit tools and controls", .mainActorExclusive)
@MainActor
struct ProjectEditingFlowTests {
    @Test func editToolsMoveOrganizationButNotFoldersAndDeletionOnlyRequestsConfirmation() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let own = getpid()
        app.server.extensionPeerCheck = { _, peer in peer == own }
        let a = Fixture.space("A", path: app.dir.appendingPathComponent("a").path)
        let b = Fixture.space("B", path: app.dir.appendingPathComponent("b").path)
        let child = Fixture.space("docs", path: a.path + "/docs")
        for space in [a, b, child] { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
        try FileManager.default.createDirectory(atPath: a.path + "/.pi", withIntermediateDirectories: false)
        try Data(#"{"mcpServers":{"physical-parent":{"command":"true"}}}"#.utf8).write(to: URL(fileURLWithPath: a.path + "/.pi/mcp.json"))
        let agent = Fixture.agent("requester", in: a, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [a, b, child], agents: [agent]))
        vm.settings.sidebarStyle = .projects
        vm.selectAgent(agent.agent.id)
        func ask(_ message: ExtensionMessage) async throws -> ExtensionReply {
            let client = try ExtensionClient(path: app.scratch.socketPath)
            try client.send(message)
            return try await Task.detached { try client.readReply() }.value
        }
        let reply = try await ask(.editProject(id: 1, agentID: agent.agent.id, projectID: child.id, request: ProjectEdit(name: "Documentation", parentProjectID: b.id.rawValue)))
        guard case .projectResult(1, let edited?, false) = reply else { Issue.record("Unexpected result \(reply)"); return }
        #expect(edited.path == child.path && edited.parentID == b.id)
        #expect(vm.sidebarTree.projects.first { $0.space == child.id }?.parentID == .local(b.id))
        let row = try #require(vm.projects.visible.first { $0.project.projectID == child.id })
        #expect(row.parentName == "B" && row.project.inheritedFromName == "A")
        #expect(row.project.inheritedMCP == ["physical-parent"])
        #expect(vm.selectedAgentID == agent.agent.id)
        #expect(FileManager.default.fileExists(atPath: child.path))
        #expect(!FileManager.default.fileExists(atPath: b.path + "/docs"))
        let deletion = try await ask(.deleteProject(id: 2, agentID: agent.agent.id, projectID: child.id))
        #expect(deletion == .projectResult(id: 2, space: edited, created: false))
        #expect(vm.spaceDeleteTarget == child.id)
        #expect(app.server.state.spaces.contains(edited), "The tool has not deleted anything")
        vm.spaceDeleteTarget = nil
        app.server.extensionPeerCheck = { _, _ in false }
        let refused = try await ask(.editProject(id: 3, agentID: agent.agent.id, projectID: child.id, request: ProjectEdit(name: "spoofed")))
        guard case .error(3, _, _) = refused else { Issue.record("Unowned caller was accepted"); return }
        #expect(app.server.state.spaces.contains(edited))
    }

    @Test func projectListingDoesNotImportAnotherHarnessSessionHistory() async throws {
        let other = try AppHarness(pi: .app)
        defer { other.stop() }
        let sessions = other.server.pi.sessionDirectory(forCwd: other.dir.path)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let header = try JSONSerialization.data(withJSONObject: ["type": "session", "cwd": other.dir.path])
        try header.write(to: sessions.appendingPathComponent("isolation.jsonl"))

        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("Only this project", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        _ = try await vm.handleProjectRequest(.refresh)
        #expect(vm.projects.visible.map(\.project.directory) == [canonical(app.dir)])

        // Import is intentional when a caller explicitly shares that pi home.
        let shared = try AppHarness(pi: .app)
        defer { shared.stop() }
        guard case .listing(let listing) = try await shared.server.projects.request(.list(), state: ShepherdState()) else {
            Issue.record("Expected project listing"); return
        }
        #expect(listing.projects.contains { $0.directory == canonical(other.dir) })
    }

    @Test func explicitNestedParentsAppearAtEveryLevelAndRootOverrideDoesNotMoveData() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Parent", path: app.dir.appendingPathComponent("parent").path)
        let child = Fixture.space("Child", path: app.dir.appendingPathComponent("child").path)
        let leaf = Fixture.space("Leaf", path: app.dir.appendingPathComponent("leaf").path)
        for space in [parent, child, leaf] { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
        let agent = Fixture.agent("leaf thread", in: leaf, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [leaf, parent, child], agents: [agent]))
        vm.settings.sidebarStyle = .projects
        _ = try await vm.handleProjectRequest(.edit(projectID: child.id, request: ProjectEdit(parentProjectID: parent.id.rawValue)))
        _ = try await vm.handleProjectRequest(.edit(projectID: leaf.id, request: ProjectEdit(parentProjectID: child.id.rawValue)))
        #expect(vm.sidebarTree.projects.map(\.name) == ["Parent", "Child", "Leaf"])
        #expect(vm.projects.visible.map(\.ancestorIDs.count) == [0, 1, 2])
        vm.setProject(.local(parent.id), expanded: false)
        #expect(vm.sidebarShortcutRows.isEmpty)
        vm.selectAgent(agent.agent.id)
        vm.openProjectHoldingSelection()
        #expect(vm.sidebarShortcutRows.map(\.title) == ["leaf thread"])
        _ = try await vm.handleProjectRequest(.edit(projectID: leaf.id, request: ProjectEdit(parentProjectID: "")))
        #expect(vm.sidebarTree.projects.first { $0.space == leaf.id }?.ancestorIDs.isEmpty == true)
        #expect(app.server.state.spaces.first { $0.id == leaf.id }?.path == leaf.path)
    }

    @Test func renameIsAvailableAfterAddingAParentOrChildAndChangesOnlyLabels() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.renameControls() } }
    }

    private static func renameControls() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Platform", path: app.dir.appendingPathComponent("platform").path)
        let child = Fixture.space("docs", path: parent.path + "/docs")
        try FileManager.default.createDirectory(atPath: child.path, withIntermediateDirectories: true)
        let bytes = Data("keep".utf8)
        let file = URL(fileURLWithPath: child.path + "/guide.md")
        try bytes.write(to: file)
        let vm = try await app.start(with: Fixture.state(spaces: [parent, child], agents: []))
        vm.settings.sidebarStyle = .projects
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        for space in [parent, child] {
            let project = try #require(vm.presentedSidebarTree.compactMap { if case .project(let row) = $0, row.space == space.id { row } else { nil } }.first)
            let menu = OffscreenWindow(size: CGSize(width: 550, height: 500), dark: true, VStack { SidebarProjectMenu(vm: vm, project: project) })
            menu.layout()
            try menu.press("Rename Project…")
            try await eventuallyOnMain("rename dialog") { window.window.attachedSheet?.contentView != nil }
            let cancelSheet = try #require(window.window.attachedSheet?.contentView)
            try ControlPress.press("Cancel", under: cancelSheet)
            try await eventuallyOnMain("rename cancelled") { window.window.attachedSheet == nil }
            #expect(app.server.state.spaces.first { $0.id == space.id }?.name == space.name)
            menu.close()
            let settings = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, ProjectsSettings(vm: vm, model: vm.projects))
            defer { settings.close() }
            try await eventuallyOnMain("settings rows") { vm.projects.visible.count == 2 }
            settings.layout()
            try ControlPress.perform("Rename Project…", onLabelContaining: "Open \(space.name)", under: settings.host)
            try await eventuallyOnMain("rename from Settings") { window.window.attachedSheet?.contentView != nil }
            let content = try #require(window.window.attachedSheet?.contentView)
            func field(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.placeholderString == "Name" || field.accessibilityLabel() == "Name" { return field }
                return view.subviews.lazy.compactMap(field).first
            }
            let input = try #require(field(content))
            input.stringValue = ""
            input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
            try await eventuallyOnMain("empty name disabled") { ControlPress.controls(in: content).contains { $0.label == "Rename" && !$0.isEnabled } }
            input.stringValue = String(repeating: "x", count: 257)
            input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
            try await eventuallyOnMain("long name is submitted for validation") { ControlPress.controls(in: content).contains { $0.label == "Rename" && $0.isEnabled } }
            try ControlPress.press("Rename", under: content)
            try await eventuallyOnMain("name error stays in dialog") {
                AccessibilityNode.all(under: content).contains { ($0.label ?? $0.value ?? "").contains("1–256") }
            }
            #expect(app.server.state.spaces.first { $0.id == space.id }?.name == space.name)
            input.stringValue = "Renamed \(space.name)"
            input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
            try await eventuallyOnMain("rename enabled") { ControlPress.controls(in: content).contains { $0.label == "Rename" && $0.isEnabled } }
            let rename = try ControlPress.press("Rename", under: content)
            #expect(ControlPress.undersized([rename], minimum: .desktop).isEmpty)
            try await eventuallyOnMain("rename persisted") { app.server.state.spaces.first { $0.id == space.id }?.name == "Renamed \(space.name)" }
            try await eventuallyOnMain("renamed Settings row") { vm.projects.visible.contains { $0.project.projectID == space.id && $0.project.name == "Renamed \(space.name)" } }
            #expect(app.server.state.spaces.first { $0.id == space.id }?.path == space.path)
            try await eventuallyOnMain("rename closed") { window.window.attachedSheet == nil }
            #expect(try Data(contentsOf: file) == bytes)
        }
    }
}
