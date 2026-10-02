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

@Suite("Projects controls", .mainActorExclusive)
@MainActor
struct ProjectsControlTests {
    @Test func theRenderedControlsReachProjectFilesThroughAccessibility() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressControls() }
        }
    }

    private static func nativeTextField(under view: NSView, label: String) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == label || field.placeholderString == label || field.stringValue == "does-not-exist" { return field }
        return view.subviews.lazy.compactMap { nativeTextField(under: $0, label: label) }.first
    }

    private static func pressControls() async throws {
        AccessibilityNode.enable()
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let root = scratch.dir.appendingPathComponent("dashboard")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Original instructions\n".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let skills = root.appendingPathComponent(".pi/skills/check/SKILL.md")
        try FileManager.default.createDirectory(at: skills.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Check\n".utf8).write(to: skills)
        try await scratch.server.putState(ShepherdState(spaces: [Space(name: "dashboard", path: root.path)]))
        let defaults = ScratchDefaults()
        let vm = ShepherdViewModel(server: scratch.server, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in },
                                   restoresAgentsAtLaunch: false, checkoutReader: nil)
        vm.showSettings = true; vm.settingsSection = .projects
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: true, SettingsView(vm: vm))
        defer { window.close() }
        let model = vm.projects
        try await eventuallyOnMain("the project row") { model.visible.count == 1 }
        window.layout()
        let open = try ControlPress.press("Open dashboard on This Mac", under: window.host)
        #expect(ControlPress.undersized([open], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the first project file") { model.fileLoaded }
        for category in ProjectFile.Category.allCases {
            window.layout()
            let control = try ControlPress.press("Project category \(category.title)", under: window.host)
            #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(category.title) hit area is \(String(describing: control.frame))")
            try await eventuallyOnMain("the category to load") { model.category == category && !model.fileLoading }
        }
        window.layout()
        try ControlPress.press("Project category Instructions", under: window.host)
        try await eventuallyOnMain("instructions to load") { model.category == .instructions && model.fileLoaded }
        window.layout()
        try ControlPress.press(".pi/APPEND_SYSTEM.md", under: window.host)
        try await eventuallyOnMain("the missing instruction file") { model.selectedFile?.path == ".pi/APPEND_SYSTEM.md" && model.fileLoaded }
        #expect(model.saved == nil)
        window.layout()
        try ControlPress.press("AGENTS.md", under: window.host)
        try await eventuallyOnMain("AGENTS.md to load") { model.selectedFile?.path == "AGENTS.md" && model.fileLoaded }
        // The native editor's accessibility value is the text a screen reader edits.
        let editor = try #require(AccessibilityNode.all(under: window.host).first { $0.label == "Project file editor" })
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(editor.object.responds(to: setter))
        _ = editor.object.perform(setter, with: "# Changed instructions\n")
        if let textView = editor.object as? NSTextView { NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView) }
        try await eventuallyOnMain("the native edit") { model.dirty }
        window.layout()
        try ControlPress.press("Save", under: window.host)
        try await eventuallyOnMain("the project save") { !model.saving && !model.dirty && model.notice != nil }
        #expect(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "# Changed instructions\n")
        _ = editor.object.perform(setter, with: "Discard this\n")
        if let textView = editor.object as? NSTextView { NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView) }
        try await eventuallyOnMain("the second native edit") { model.dirty }
        window.layout()
        try ControlPress.press("Back to Projects", under: window.host)
        try await eventuallyOnMain("discard confirmation") { model.pending != nil }
        window.layout()
        try ControlPress.press("Keep editing", under: window.host)
        #expect(model.pending == nil && model.dirty)
        try ControlPress.press("Revert", under: window.host)
        try await eventuallyOnMain("the reverted file") { !model.dirty && model.fileLoaded }
        window.layout()
        try ControlPress.press("Back to Projects", under: window.host)
        try await eventuallyOnMain("the project list") { model.selected == nil }
        window.layout()
        let host = try ControlPress.press("This Mac", role: ControlRole.radioButton, under: window.host)
        #expect(ControlPress.undersized([host], minimum: .desktop).isEmpty)
        #expect(model.host == "local")
        try ControlPress.press("All hosts", role: ControlRole.radioButton, under: window.host)
        #expect(model.host == "all")
        let filterNodes = AccessibilityNode.all(under: window.host)
        let filterNode = filterNodes.first { $0.label == "Filter projects" && $0.role == "AXTextField" }
        let filter = try #require(filterNode)
        #expect(filter.object.responds(to: setter))
        _ = filter.object.perform(setter, with: "does-not-exist")
        if let field = nativeTextField(under: window.host, label: "Filter projects") {
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        try await eventuallyOnMain("the native filter") { model.filter == "does-not-exist" && model.visible.isEmpty }
        window.layout()
        try ControlPress.press("Clear search", under: window.host)
        try await eventuallyOnMain("the cleared project filter") { model.filter.isEmpty && model.visible.count == 1 }
        window.layout()
        let add = try ControlPress.press("Add project…", under: window.host)
        #expect(ControlPress.undersized([add], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the folder picker") { window.window.attachedSheet != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        try ControlPress.press("Cancel", under: sheet)
        try await eventuallyOnMain("the folder picker to close") { window.window.attachedSheet == nil }
        try ControlPress.press("Back to Shepherd", under: window.host)
        #expect(!vm.showSettings)
    }
}
