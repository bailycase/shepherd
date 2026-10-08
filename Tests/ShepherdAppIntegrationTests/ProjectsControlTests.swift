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
        var openedFile: String?
        vm.madeProjects = ProjectsModel { _, request in
            if case .open(_, let file) = request { openedFile = file; return .opened }
            return try await vm.server.projects.request(request, state: vm.state)
        }
        vm.showSettings = true; vm.settingsSection = .projects
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1100), dark: true, RootView(vm: vm))
        defer { window.close() }
        let model = vm.projects
        try await eventuallyOnMain("the project row") { model.visible.count == 1 }
        window.layout()
        let open = try ControlPress.press("Open dashboard", under: window.host)
        #expect(ControlPress.undersized([open], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the first project file") { model.fileLoaded }
        for (category, label) in [(ProjectFile.Category.instructions, "Instructions"), (.pi, "Settings"), (.skills, "Resources"), (.mcp, "MCP servers")] {
            window.layout()
            let control = try ControlPress.press("Project category \(label)", under: window.host)
            #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(label) hit area is \(String(describing: control.frame))")
            try await eventuallyOnMain("the category to load") { model.category == category && !model.fileLoading }
            if category == .pi {
                #expect(model.projectCodemode == .inherit)
                for (label, expected) in [("Off", false as Bool?), ("On", true as Bool?), ("Use global default", nil as Bool?)] {
                    window.layout()
                    let choice = try window.press(label, role: ControlRole.radioButton)
                    #expect(ControlPress.undersized([choice], minimum: .desktop).isEmpty)
                    #expect(model.dirty)
                    window.layout()
                    try window.press("Save")
                    try await eventuallyOnMain("codemode saved") { !model.saving && !model.dirty }
                    let contents = try Data(contentsOf: root.appendingPathComponent(".pi/settings.json"))
                    let settings = try #require(JSONSerialization.jsonObject(with: contents) as? [String: Any])
                    #expect(PiCodemode.projectOverride(in: settings) == expected)
                }
            }
        }
        window.layout()
        let browser = try ControlPress.press("Project category Browser", under: window.host)
        #expect(ControlPress.undersized([browser], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the project Browser page") { model.showingBrowser && vm.projectCookies.scope != nil && !vm.projectCookies.loading }
        window.layout()
        try ControlPress.press("Project category Instructions", under: window.host)
        try await eventuallyOnMain("instructions to load") { model.category == .instructions && model.fileLoaded }
        for path in ["AGENTS.override.md", ".pi/SYSTEM.md"] {
            window.layout()
            let file = try ControlPress.press(path, under: window.host)
            #expect(ControlPress.undersized([file], minimum: .desktop).isEmpty)
            try await eventuallyOnMain("\(path) to load") { model.selectedFile?.path == path && model.fileLoaded }
        }
        window.layout()
        try ControlPress.press(".pi/APPEND_SYSTEM.md", under: window.host)
        try await eventuallyOnMain("the missing instruction file") { model.selectedFile?.path == ".pi/APPEND_SYSTEM.md" && model.fileLoaded }
        #expect(model.saved == nil)
        window.layout()
        try ControlPress.press("AGENTS.md", under: window.host)
        try await eventuallyOnMain("AGENTS.md to load") { model.selectedFile?.path == "AGENTS.md" && model.fileLoaded }
        window.layout()
        try ControlPress.press("Open in editor", under: window.host)
        try await eventuallyOnMain("the project editor open request") { openedFile == "AGENTS.md" }
        window.layout()
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
        try ControlPress.press("Back to Projects", under: window.host)
        try await eventuallyOnMain("the second discard confirmation") { model.pending != nil }
        window.layout()
        try ControlPress.press("Discard", under: window.host)
        try await eventuallyOnMain("the project list") { model.selected == nil }
        #expect(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "# Changed instructions\n")
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
        let add = try ControlPress.press("Add project", under: window.host)
        #expect(ControlPress.undersized([add], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the folder picker") { window.window.attachedSheet != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        try ControlPress.press("Cancel", under: sheet)
        try await eventuallyOnMain("the folder picker to close") { window.window.attachedSheet == nil }
        window.layout()
        let settingsSearch = try #require(AccessibilityNode.all(under: window.host).first { $0.label == "Search settings" && $0.role == "AXTextField" })
        let settingsSetter = NSSelectorFromString("setAccessibilityValue:")
        #expect(settingsSearch.object.responds(to: settingsSetter))
        _ = settingsSearch.object.perform(settingsSetter, with: "Filter projects")
        let settingsField = try #require(nativeTextField(under: window.host, label: "Search settings"))
        settingsField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: settingsField))
        try await eventuallyOnMain("the Settings search to narrow navigation") {
            window.layout()
            return !AccessibilityNode.all(under: window.host).contains { $0.label == "Appearance" && $0.role == "AXButton" }
        }
        _ = settingsSearch.object.perform(settingsSetter, with: "")
        settingsField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: settingsField))
        try await eventuallyOnMain("the Settings search to restore navigation") {
            window.layout()
            return AccessibilityNode.all(under: window.host).contains { $0.label == "Appearance" && $0.role == "AXButton" }
        }
        try ControlPress.press("Back to Shepherd", under: window.host)
        #expect(!vm.showSettings)
    }

    /// The tree (SettingsProjects, parents and subprojects): a folder inside another project sits
    /// under it, the disclosure folds it away and back, Add subproject opens the create-or-add
    /// dialog for the parent, and a subproject's Open project opens it.
    @Test func theTreesDisclosureAddSubprojectAndOpenProjectWorkThroughAccessibility() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressTree() }
        }
    }

    private static func pressTree() async throws {
        AccessibilityNode.enable()
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let acme = scratch.dir.appendingPathComponent("acme").resolvingSymlinksInPath()
        let web = acme.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: acme.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"docs": {"command": "true"}, "shared": {"command": "true"}}}"#.utf8).write(to: acme.appendingPathComponent(".pi/mcp.json"))
        try await scratch.server.putState(ShepherdState(spaces: [Space(name: "acme", path: acme.path), Space(name: "web", path: web.path)]))
        let defaults = ScratchDefaults()
        let vm = ShepherdViewModel(server: scratch.server, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in },
                                   restoresAgentsAtLaunch: false, checkoutReader: nil)
        vm.showSettings = true; vm.settingsSection = .projects
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1000), dark: true, RootView(vm: vm))
        defer { window.close() }
        let model = vm.projects
        try await eventuallyOnMain("the tree") { model.visible.map(\.project.name) == ["acme", "web"] }
        #expect(model.visible[1].configuration == "2 inherited MCP servers")

        try await eventuallyOnMain("the disclosure") { window.layout(); return window.controls().contains { $0.label == "Collapse acme" } }
        let collapse = try window.press("Collapse acme")
        #expect(ControlPress.undersized([collapse], minimum: .desktop).isEmpty, "the disclosure's hit area is \(collapse.frame)")
        try await eventuallyOnMain("web folded away") { model.visible.map(\.project.name) == ["acme"] }
        try await eventuallyOnMain("the disclosure to read Expand") { window.controls().contains { $0.label == "Expand acme" } }
        try window.press("Expand acme")
        try await eventuallyOnMain("web back") { model.visible.count == 2 }

        try await eventuallyOnMain("Add subproject") { window.controls().contains { $0.label == "Add subproject to acme" } }
        let add = try window.press("Add subproject to acme")
        #expect(ControlPress.undersized([add], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the child-project dialog") {
            guard let sheet = window.window.attachedSheet?.contentView else { return false }
            sheet.layoutSubtreeIfNeeded()
            return ControlPress.controls(in: sheet).contains { $0.label == "Create and add" }
        }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        try ControlPress.press("Existing folder", role: ControlRole.radioButton, under: sheet)
        sheet.layoutSubtreeIfNeeded()
        try ControlPress.press("Browse…", under: sheet)
        try await eventuallyOnMain("the folder picker in acme's folder") {
            guard let picker = window.window.attachedSheet?.attachedSheet?.contentView else { return false }
            return AccessibilityNode.all(under: picker).contains { $0.label == "apps" }
        }
        let picker = try #require(window.window.attachedSheet?.attachedSheet?.contentView)
        try ControlPress.press("Cancel", under: picker)
        try await eventuallyOnMain("the folder picker to close") { window.window.attachedSheet?.attachedSheet == nil }
        try ControlPress.press("Cancel", under: sheet)
        try await eventuallyOnMain("the child dialog to close") { window.window.attachedSheet == nil }

        try await eventuallyOnMain("Open project") { window.controls().contains { $0.label == "Open project" } }
        let open = try window.press("Open project")
        #expect(ControlPress.undersized([open], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("web's detail") { model.selected?.project.name == "web" }
    }
}
