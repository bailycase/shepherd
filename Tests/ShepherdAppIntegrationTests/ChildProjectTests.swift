import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Child projects", .mainActorExclusive)
@MainActor
struct ChildProjectTests {
    @Test func childToolsCreateAndRegisterWithoutStartingThreadsOrReplacingExistingFolders() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let own = getpid()
        app.server.extensionPeerCheck = { _, peer in peer == own }
        let parent = Fixture.space("Parent", path: app.dir.path)
        let agent = Fixture.agent("requester", in: parent, order: 0)
        let vm = try await app.start(with: Fixture.state(spaces: [parent], agents: [agent]))
        let client = try ExtensionClient(path: app.scratch.socketPath)
        let path = app.dir.appendingPathComponent("child").path
        try client.send(.addChildProject(id: 1, agentID: agent.agent.id, parentPath: parent.path, path: path, name: "Child", create: true))
        let reply = try await Task.detached { try client.readReply() }.value
        guard case .projectResult(1, let child?, true) = reply else { Issue.record("Unexpected result: \(reply)"); return }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(vm.state.spaces.contains(child))
        #expect(vm.sidebarTree.projects.contains { $0.name == "Child" })
        #expect(vm.projects.visible.first { $0.project.name == "Child" }?.parentName == "Parent")
        #expect(app.server.state.agents.count == 1)
        let keep = URL(fileURLWithPath: path).appendingPathComponent("keep.txt")
        try Data("untouched".utf8).write(to: keep)
        let reused = try await app.server.addChildProject(parentPath: parent.path, path: path, name: "Other", create: true)
        #expect(reused.space == child && !reused.created)
        let duplicate = try await app.server.addChildProject(parentPath: parent.path, path: path, name: "Other", create: false)
        #expect(!duplicate.created && duplicate.space == child)
        #expect(try String(contentsOf: keep, encoding: .utf8) == "untouched")
        #expect(try JSONDecoder().decode(ShepherdState.self, from: Data(contentsOf: app.scratch.stateURL)) == app.server.state)
    }

    @Test func childPathsCannotEscapeOrCreateIntermediateFolders() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = app.dir.appendingPathComponent("parent")
        let outside = app.dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = parent.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        for (path, create) in [(parent.path, false), (outside.path, false), (link.path, false),
                               (outside.appendingPathComponent("new").path, true),
                               (parent.appendingPathComponent("missing/deep").path, true),
                               (link.appendingPathComponent("new").path, true)] {
            await #expect(throws: ProjectFileError.self) {
                try await app.server.addChildProject(parentPath: parent.path, path: path, name: "Child", create: create)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(app.server.state.spaces.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("missing").path))
    }

    @Test func aRegistrationFailureLeavesTheNewFolderAndReportsHowToRetry() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Parent", path: app.dir.path)
        _ = try await app.start(with: Fixture.state(spaces: [parent], agents: []))
        // Make only this scratch state's destination unwritable as a file.
        try FileManager.default.removeItem(at: app.scratch.stateURL)
        try FileManager.default.createDirectory(at: app.scratch.stateURL, withIntermediateDirectories: false)
        let path = app.dir.appendingPathComponent("created-before-failure").path
        do {
            _ = try await app.server.addChildProject(parentPath: parent.path, path: path, name: "Child", create: true)
            Issue.record("Expected state persistence to fail")
        } catch let error as ProjectFileError {
            #expect(error.code == "registration_failed")
            #expect(error.description.contains("Existing folder"))
            #expect(error.description.contains("left in place"))
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(app.server.state.spaces == [parent])
    }

    @Test func busyControlsRefuseDuplicateSubmission() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressBusy() }
        }
    }

    private static func pressBusy() async throws {
        AccessibilityNode.enable()
        var pending: CheckedContinuation<Void, Never>?
        var calls = 0
        let model = ChildProjectModel(parentPath: "/example", parentName: "Parent") { _ in
            calls += 1
            await withCheckedContinuation { pending = $0 }
        }
        model.folder = "child"
        let window = OffscreenWindow(size: CGSize(width: 700, height: 600), dark: true,
                                     ChildProjectSheet(model: model, dismiss: {}))
        defer { window.close() }
        window.layout()
        try window.press("Create and add")
        try await eventuallyOnMain("busy model") { model.busy && pending != nil }
        window.layout()
        for label in ["Cancel", "Create and add", "New folder", "Existing folder"] {
            #expect(window.controls().contains { $0.label == label && !$0.isEnabled })
        }
        #expect(throws: ControlPressError.self) { try window.press("Create and add") }
        #expect(await model.submit() == false)
        #expect(calls == 1)
        pending?.resume()
        try await eventuallyOnMain("submission finishes") { !model.busy }
        #expect(calls == 1)
    }

    @Test func controlsCreateChooseRetryAndCancel() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressControls() }
        }
    }

    @Test func settingsAndSidebarOpenTheChildDialog() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressEntryPoints() }
        }
    }

    private static func pressEntryPoints() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let directory = app.dir.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let parent = Fixture.space("Parent", path: directory.path)
        let vm = try await app.start(with: Fixture.state(spaces: [parent], agents: []))
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true,
                                     ProjectsSettings(vm: vm, model: vm.projects))
        defer { window.close() }
        try await eventuallyOnMain("settings parent row") { vm.projects.visible.count == 1 }
        window.layout()
        let add = try window.press("Add subproject to Parent")
        #expect(ControlPress.undersized([add], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("child sheet from Settings") { window.window.attachedSheet?.contentView != nil }
        let content = try #require(window.window.attachedSheet?.contentView)
        #expect(ControlPress.controls(in: content).contains { $0.label == "Create and add" })
        func folderField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Folder name" || field.accessibilityLabel() == "Folder name" { return field }
            return view.subviews.lazy.compactMap(folderField).first
        }
        let field = try #require(folderField(content))
        field.stringValue = "from-settings"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await eventuallyOnMain("create enabled") { ControlPress.controls(in: content).contains { $0.label == "Create and add" && $0.isEnabled } }
        try ControlPress.press("Create and add", under: content)
        try await eventuallyOnMain("settings child sheet closed after creation") { window.window.attachedSheet == nil }
        #expect(vm.projects.visible.contains { $0.project.name == "from-settings" && $0.parentName == "Parent" })
        let row = try #require(vm.sidebarTree.items(collapsed: [], selected: nil, shortcuts: false, connected: []).compactMap {
            if case .project(let row) = $0, row.name == "Parent" { return row }; return nil
        }.first)
        let menu = OffscreenWindow(size: CGSize(width: 700, height: 500), dark: true,
                                   VStack { SidebarProjectMenu(vm: vm, project: row) })
        defer { menu.close() }
        menu.layout()
        try menu.press("Add Child Project…")
        #expect(vm.addingChildProject?.parentPath == parent.path)
        #expect(vm.addingChildProject?.parentName == parent.name)
        vm.addingChildProject = nil
        #expect(vm.state.spaces.count == 2)
        #expect(vm.state.agents.isEmpty)
    }

    private static func pressControls() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let parent = Fixture.space("Parent", path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [parent], agents: []))
        let model = vm.childProjectModel(path: parent.path, name: parent.name)
        var dismissed = false
        let window = OffscreenWindow(size: CGSize(width: 700, height: 600), dark: true,
                                     ChildProjectSheet(model: model, dismiss: { dismissed = true }))
        defer { window.close() }
        window.layout()
        #expect(window.controls().contains { $0.label == "Create and add" && !$0.isEnabled })
        model.folder = "child"; model.displayName = "Child"
        window.layout()
        let create = try window.press("Create and add")
        #expect(ControlPress.undersized([create], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("child created and adopted") { dismissed }
        #expect(vm.state.spaces.contains { $0.name == "Child" })
        #expect(vm.state.agents.isEmpty)

        dismissed = false
        model.folder = "../escape"
        window.layout()
        try window.press("Create and add")
        try await eventuallyOnMain("invalid folder error") { model.error != nil && !model.busy }
        model.folder = "child"
        #expect(!dismissed)
        window.layout()
        let existing = try window.press("Existing folder", role: ControlRole.radioButton)
        #expect(ControlPress.undersized([existing], minimum: .desktop).isEmpty)
        #expect(!model.create)
        window.layout()
        try window.press("Browse…")
        try await eventuallyOnMain("directory browser") { !window.window.sheets.isEmpty }
        let cancelledPicker = try #require(window.window.sheets.first?.contentView)
        try ControlPress.press("Cancel", under: cancelledPicker)
        try await eventuallyOnMain("browser cancelled") { !model.browsing && window.window.attachedSheet == nil }
        #expect(model.folder == "child")
        window.layout()
        let browse = try window.press("Browse…")
        #expect(ControlPress.undersized([browse], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("directory browser reopened") { window.window.attachedSheet?.contentView != nil }
        let content = try #require(window.window.attachedSheet?.contentView)
        try await eventuallyOnMain("directory browser loaded") {
            ControlPress.controls(in: content).contains { $0.label == "Choose" && $0.isEnabled }
        }
        try ControlPress.press("child", under: content)
        try await eventuallyOnMain("child directory loaded") {
            ControlPress.controls(in: content).contains { $0.label == "Choose" && $0.isEnabled }
        }
        try ControlPress.press("Choose", under: content)
        try await eventuallyOnMain("chosen folder") { !model.browsing && model.folder.hasSuffix("/child") }
        window.layout()
        let add = try window.press("Add project")
        #expect(ControlPress.undersized([add], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("existing child registered") { dismissed }
        #expect(vm.state.spaces.count == 2)
        dismissed = false
        window.layout()
        try window.press("New folder", role: ControlRole.radioButton)
        #expect(model.create)
        model.folder = "not-created"
        window.layout()
        let cancel = try window.press("Cancel")
        #expect(ControlPress.undersized([cancel], minimum: .desktop).isEmpty)
        #expect(dismissed)
        #expect(!FileManager.default.fileExists(atPath: app.dir.appendingPathComponent("not-created").path))
    }
}
