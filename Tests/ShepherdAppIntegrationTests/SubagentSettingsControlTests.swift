import AppKit
import Foundation
import SwiftUI
import Testing
import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Subagent settings controls", .mainActorExclusive)
@MainActor
struct SubagentSettingsControlTests {
    @Test func nativeControlsReadSaveDeleteRestoreAndProtectDirtyNavigation() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressControls() }
        }
    }
    private static func pressControls() async throws {
        AccessibilityNode.enable()
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let files = try SubagentFixtures.store(in: scratch.dir, populated: true)
        let model = SubagentDefinitionsModel(store: files)
        let defaults = ScratchDefaults()
        let vm = ShepherdViewModel(server: scratch.server, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in },
                                   restoresAgentsAtLaunch: false, checkoutReader: nil)
        vm.madeSubagentDefinitions = model; vm.showSettings = true; vm.settingsSection = .subagents
        var revealed: URL?, opened: URL?
        model.reveal = { revealed = $0 }; model.openEditor = { opened = $0 }
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("owned profiles") { model.loaded && !model.busy }
        #expect(model.definitions.count == 7)
        #expect(model.problem == nil)
        window.layout()
        let finder = try window.press("Show in Finder")
        #expect(revealed == files.directory)
        #expect(ControlPress.undersized([finder], minimum: .desktop).isEmpty)
        let invalid = try window.press("Open reviewer-strict")
        #expect(ControlPress.undersized([invalid], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("invalid profile editor") { model.editing && !model.busy }
        #expect(model.draft.contains("runner: strict"))
        window.layout()
        try window.press("Open in editor")
        try await eventuallyOnMain("native editor request") { opened != nil && !model.busy }
        let editorURL = try #require(opened)
        #expect(try String(contentsOf: editorURL, encoding: .utf8) == files.open("reviewer-strict.md").text, "the native editor opens the verified file's real contents")
        try setEditor(to: model.draft + "\nMore review instructions.\n", under: window.host)
        window.layout(); try window.press("Save")
        try await eventuallyOnMain("invalid save refused") { !model.busy && model.problem != nil }
        #expect(model.problem?.contains("Unsupported agent fields: runner") == true)
        let unchangedInvalid = try files.open("reviewer-strict.md")
        #expect(model.dirty && !unchangedInvalid.text.contains("More review instructions."))
        try setEditor(to: model.draft.replacingOccurrences(of: "runner: strict\n", with: ""), under: window.host)
        window.layout()
        let save = try window.press("Save")
        #expect(ControlPress.undersized([save], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("repaired file saved") { !model.busy && !model.dirty }
        #expect(try files.open("reviewer-strict.md").text == model.draft)
        window.layout()
        try window.press("Back to Subagents")
        window.layout()
        try window.press("New subagent")
        #expect(model.original == nil && model.dirty)
        try setField("Subagent filename", to: "check.md", under: window.host)
        try setEditor(to: "---\nname: check\ndescription: Real created profile\ntools: [read]\n---\nInspect the assigned code.\n", under: window.host)
        #expect(model.filename == "check.md")
        window.layout()
        try window.press("Back to Subagents")
        let discardSheet = try await sheet(window)
        try ControlPress.press("Cancel", under: discardSheet)
        try await eventuallyOnMain("cancelled dirty navigation") { window.window.attachedSheet == nil }
        #expect(model.editing && model.dirty)
        window.layout()
        try window.press("Save")
        try await eventuallyOnMain("created file saved") { !model.busy && !model.dirty }
        #expect(try files.open("check.md").text.contains("name: check"))
        window.layout()
        try window.press("Delete")
        let deleteSheet = try await sheet(window)
        try ControlPress.press("Cancel", under: deleteSheet)
        try await eventuallyOnMain("cancelled deletion") { window.window.attachedSheet == nil }
        #expect(FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("check.md").path))
        window.layout()
        try window.press("Delete")
        let confirmedDelete = try await sheet(window)
        let delete = try ControlPress.press("Delete subagent", under: confirmedDelete)
        #expect(ControlPress.undersized([delete], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("confirmed deletion") { !model.editing && !model.busy && window.window.attachedSheet == nil }
        #expect(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("check.md").path))
        window.layout()
        try window.press("Restore defaults")
        let restoreSheet = try await sheet(window)
        try ControlPress.press("Cancel", under: restoreSheet)
        try await eventuallyOnMain("cancelled restore") { window.window.attachedSheet == nil }
        window.layout()
        try window.press("Restore defaults")
        let confirmedRestore = try await sheet(window)
        let restore = try ControlPress.press("Restore", under: confirmedRestore)
        #expect(ControlPress.undersized([restore], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("restored defaults") { !model.busy && window.window.attachedSheet == nil }
        #expect(try files.snapshot().count == 7)
        try setField("Filter subagents", to: "api-review", under: window.host)
        #expect(model.visible.map(\.name) == ["api-review"])
        try setField("Filter subagents", to: "no-match", under: window.host)
        #expect(model.visible.isEmpty)
        try setField("Filter subagents", to: "", under: window.host)
        window.layout()
        try window.press("New subagent")
        window.layout()
        try window.press("Appearance")
        let navigationSheet = try await sheet(window)
        try ControlPress.press("Cancel", under: navigationSheet)
        try await eventuallyOnMain("dirty navigation cancelled") { window.window.attachedSheet == nil }
        #expect(vm.settingsSection == .subagents && model.editing && model.dirty)
        window.layout()
        try window.press("Appearance")
        let discardedNavigation = try await sheet(window)
        let discard = try ControlPress.press("Discard", under: discardedNavigation)
        #expect(ControlPress.undersized([discard], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("dirty navigation discarded") { vm.settingsSection == .appearance && window.window.attachedSheet == nil }
        #expect(!model.editing && !FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("new-subagent.md").path))
        window.layout()
        try window.press("Subagents")
        try await eventuallyOnMain("subagents reopened") { !model.busy }
        window.layout()
        try window.press("New subagent")
        window.layout()
        try window.press("Back to Shepherd")
        let backSheet = try await sheet(window)
        try ControlPress.press("Discard", under: backSheet)
        try await eventuallyOnMain("dirty settings exit discarded") { !vm.showSettings && window.window.attachedSheet == nil }
        #expect(!model.editing)
    }
    private static func sheet(_ window: OffscreenWindow) async throws -> NSView {
        try await eventuallyOnMain("confirmation sheet") { window.window.attachedSheet?.contentView != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        return sheet
    }
    private static func setField(_ label: String, to text: String, under root: NSView) throws {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityLabel() == label || field.placeholderString == label { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        let field = try #require(find(root), "native text field \(label)")
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    private static func setEditor(to text: String, under root: NSView) throws {
        func find(_ view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView, editor.accessibilityLabel() == "Subagent definition editor" { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        let editor = try #require(find(root))
        #expect(editor.isEditable)
        editor.string = text; editor.didChangeText()
    }
}
