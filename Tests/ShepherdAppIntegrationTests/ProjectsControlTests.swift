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
        if let field = view as? NSTextField, field.accessibilityLabel() == label || field.placeholderString == label { return field }
        return view.subviews.lazy.compactMap { nativeTextField(under: $0, label: label) }.first
    }

    private static func pressControls() async throws {
        AccessibilityNode.enable()
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let root = scratch.dir.appendingPathComponent("dashboard")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Original instructions\n".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let skills = root.appendingPathComponent(".shepherd/skills/check/SKILL.md")
        try FileManager.default.createDirectory(at: skills.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Check\n".utf8).write(to: skills)
        try await scratch.server.putState(ShepherdState(spaces: [Space(name: "dashboard", path: root.path)]))
        let defaults = ScratchDefaults()
        let vm = ShepherdViewModel(pi: scratch.server.pi, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in })
        try await connectAsHost(vm, to: scratch)
        #expect(vm.hooks.catalog.home == TestProcess.hooksHome.path, "a default view model's hooks never read this machine's home")
        var openedFile: String?
        vm.madeProjects = ProjectsModel { _, request in
            if case .open(_, let file) = request { openedFile = file; return .opened }
            return try await scratch.server.projects.request(request, state: vm.state)
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
            if category != .instructions {
                try ControlPress.press("Space category \(label)", under: window.host)
            }
            try await eventuallyOnMain("the category to load") { model.category == category && !model.fileLoading }
            if category == .pi {
                let file = root.appendingPathComponent(".shepherd/settings.json")
                func saved() throws -> [String: Any] {
                    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                }
                func save(_ what: String) async throws {
                    window.layout()
                    try ControlPress.press("Save changes", under: window.host)
                    try await eventuallyOnMain(what) { !model.saving && !model.dirty }
                }
                #expect(model.projectCodemode == .inherit)
                for (label, expected) in [("Off", false as Bool?), ("On", true as Bool?), ("Follow global", nil as Bool?)] {
                    window.layout()
                    let choice = try ControlPress.press(label, role: ControlRole.radioButton, in: "Codemode", under: window.host)
                    _ = choice
                    #expect(model.dirty)
                    try await save("codemode saved")
                    #expect(PiCodemode.projectOverride(in: try saved()) == expected)
                }
                // The form writes the file's keys: a space tool selection, one tool off, then back to global.
                window.layout()
                try ControlPress.press("Space selection", role: ControlRole.radioButton, in: "Built-in tools", under: window.host)
                window.layout()
                try ControlPress.press("bash", role: ControlRole.checkBox, under: window.host)
                try await save("tools saved")
                #expect(try saved()["defaultTools"] as? [String] == ["read", "edit", "write"])
                window.layout()
                try ControlPress.press("Reset Built-in tools to global", under: window.host)
                try await save("tools reset")
                #expect(try saved()["defaultTools"] == nil)
                // Edit JSON… opens the raw editor over the same draft, for keys the form doesn't show.
                window.layout()
                try ControlPress.press("Edit JSON…", under: window.host)
                try await eventuallyOnMain("the JSON editor") { model.showingSettingsJSON }
                window.layout()
                let json = try #require(AccessibilityNode.all(under: window.host).first { $0.label == "Space file editor" })
                _ = json.object.perform(NSSelectorFromString("setAccessibilityValue:"), with: "{\n  \"enabledModels\": [\"claude-*\"]\n}\n")
                if let textView = json.object as? NSTextView { NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView) }
                try await eventuallyOnMain("the JSON edit") { model.dirty }
                window.layout()
                try ControlPress.press("Save", under: window.host)
                try await eventuallyOnMain("the JSON save") { !model.saving && !model.dirty }
                #expect(try saved()["enabledModels"] as? [String] == ["claude-*"])
                window.layout()
                try ControlPress.press("Back to form", under: window.host)
                #expect(!model.showingSettingsJSON)
            }
            if category == .skills {
                let resources = model.resources
                try await eventuallyOnMain("the space resources") { resources.loadedOnce && !resources.loading }
                let settings = root.appendingPathComponent(".shepherd/settings.json")
                func saveResources(_ what: String) async throws {
                    window.layout()
                    try ControlPress.press("Save changes", under: window.host)
                    try await eventuallyOnMain(what) { !resources.saving && !resources.dirty && !resources.loading }
                }
                window.layout()
                let toggle = try ControlPress.press("Enable check in dashboard", role: ControlRole.checkBox, under: window.host)
                #expect(ControlPress.undersized([toggle], minimum: .desktop).isEmpty)
                try await eventuallyOnMain("the toggle in the draft") { resources.dirty }
                try await saveResources("the toggle saved")
                let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
                #expect(object["skills"] as? [String] == ["-../.shepherd/skills/check/SKILL.md"] || object["skills"] as? [String] == ["-skills/check/SKILL.md"])
                window.layout()
                try ControlPress.press("Remove check from dashboard", under: window.host)
                try await eventuallyOnMain("the remove confirmation") { resources.removing != nil }
                window.layout()
                try ControlPress.press("Remove", under: window.host)
                try await saveResources("the removal saved")
                #expect(!FileManager.default.fileExists(atPath: skills.path))
                window.layout()
                try ControlPress.press("Slash commands", role: ControlRole.radioButton, under: window.host)
                window.layout()
                try ControlPress.press("New command", under: window.host)
                try await eventuallyOnMain("the editor") { resources.editor != nil }
                resources.editor?.name = "review"; resources.editor?.body = "Review the changes."
                window.layout()
                try ControlPress.press("Create command", under: window.host)
                try await eventuallyOnMain("the new command in the draft") { resources.editor == nil && resources.dirty }
                try await saveResources("the command saved")
                #expect(try String(contentsOf: root.appendingPathComponent(".pi/prompts/review.md"), encoding: .utf8) == "Review the changes.\n")
            }
            if category != .instructions {
                window.layout()
                try ControlPress.press("Back to dashboard", under: window.host)
                try await eventuallyOnMain("the overview") { model.overview && model.category == .instructions && model.fileLoaded }
            }
        }
        window.layout()
        try ControlPress.press("Space category Browser", under: window.host)
        try await eventuallyOnMain("the project Browser page") { model.showingBrowser && vm.projectCookies.scope != nil && !vm.projectCookies.loading }
        window.layout()
        try ControlPress.press("Back to dashboard", under: window.host)
        try await eventuallyOnMain("instructions to load") { model.overview && model.category == .instructions && model.fileLoaded }
        // The files of the card's menu.
        for path in ["AGENTS.override.md", ".shepherd/SYSTEM.md", ".shepherd/APPEND_SYSTEM.md", "AGENTS.md"] {
            let file = try #require(model.selectedFiles.first { $0.path == path })
            await model.navigate(.file(file))
            try await eventuallyOnMain("\(path) to load") { model.selectedFile?.path == path && model.fileLoaded }
            if path == ".shepherd/APPEND_SYSTEM.md" { #expect(model.saved == nil) }
        }
        window.layout()
        try ControlPress.press("Open in editor", under: window.host)
        try await eventuallyOnMain("the project editor open request") { openedFile == "AGENTS.md" }
        window.layout()
        // The native editor's accessibility value is the text a screen reader edits.
        let editor = try #require(AccessibilityNode.all(under: window.host).first { $0.label == "Space file editor" })
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(editor.object.responds(to: setter))
        _ = editor.object.perform(setter, with: "# Changed instructions\n")
        if let textView = editor.object as? NSTextView { NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView) }
        try await eventuallyOnMain("the native edit") { model.dirty }
        window.layout()
        try ControlPress.press("Save", under: window.host)
        try await eventuallyOnMain("the project save") { !model.saving && !model.dirty && model.notice != nil }
        #expect(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "# Changed instructions\n")
        // The save reloads the space, which may redraw the editor: edit the one on screen now, until it takes.
        try await eventuallyOnMain("the second native edit") {
            window.layout()
            if let current = AccessibilityNode.all(under: window.host).first(where: { $0.label == "Space file editor" }) {
                _ = current.object.perform(setter, with: "Discard this\n")
                if let textView = current.object as? NSTextView { NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView) }
            }
            return model.dirty
        }
        window.layout()
        try ControlPress.press("Back to Spaces", under: window.host)
        try await eventuallyOnMain("discard confirmation") { model.pending != nil }
        window.layout()
        try ControlPress.press("Keep editing", under: window.host)
        #expect(model.pending == nil && model.dirty)
        try ControlPress.press("Back to Spaces", under: window.host)
        try await eventuallyOnMain("the second discard confirmation") { model.pending != nil }
        window.layout()
        try ControlPress.press("Discard", under: window.host)
        try await eventuallyOnMain("the project list") { model.selected == nil }
        #expect(try String(contentsOf: root.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "# Changed instructions\n")
        window.layout()
        func type(_ text: String) throws {
            let field = try #require(nativeTextField(under: window.host, label: "Filter spaces"), "the Filter spaces field")
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        try type("dash")
        try await eventuallyOnMain("a real match") { model.filter == "dash" && model.visible.map(\.project.name) == ["dashboard"] }
        try type("does-not-exist")
        try await eventuallyOnMain("no match") { model.visible.isEmpty }
        try type("")
        try await eventuallyOnMain("the cleared project filter") { model.filter.isEmpty && model.visible.count == 1 }
        window.layout()
        let add = try ControlPress.press("Add space", under: window.host)
        #expect(ControlPress.undersized([add], minimum: .desktop).isEmpty)
        try await eventuallyOnMain("the Add space dialog") { window.window.attachedSheet != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        try ControlPress.press("Cancel", under: sheet)
        try await eventuallyOnMain("the Add space dialog to close") { window.window.attachedSheet == nil }
        // Add a root space by typing its name and folder, the board's way.
        let landing = scratch.dir.appendingPathComponent("landing")
        try FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true)
        window.layout()
        try ControlPress.press("Add space", under: window.host)
        try await eventuallyOnMain("the Add space dialog again") { window.window.attachedSheet != nil }
        let form = try #require(window.window.attachedSheet?.contentView)
        form.layoutSubtreeIfNeeded()
        for (label, value) in [("Space name", "landing-docs"), ("Space folder", landing.path)] {
            let node = try #require(AccessibilityNode.all(under: form).first { $0.label == label && $0.role == "AXTextField" })
            _ = node.object.perform(setter, with: value)
            if let field = nativeTextField(under: form, label: label) {
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
        }
        try await eventuallyOnMain("the typed entries") {
            form.layoutSubtreeIfNeeded()
            return ControlPress.controls(in: form).contains { $0.label == "Add space" && $0.isEnabled }
        }
        try ControlPress.press("Add space", under: form)
        try await eventuallyOnMain("the new space") { vm.state.spaces.contains { $0.name == "landing-docs" } && window.window.attachedSheet == nil }
        window.layout()
        let settingsSearch = try #require(AccessibilityNode.all(under: window.host).first { $0.label == "Search" && $0.role == "AXTextField" })
        let settingsSetter = NSSelectorFromString("setAccessibilityValue:")
        #expect(settingsSearch.object.responds(to: settingsSetter))
        _ = settingsSearch.object.perform(settingsSetter, with: "Filter spaces")
        let settingsField = try #require(nativeTextField(under: window.host, label: "Search"))
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

    /// The tree on Settings ▸ Spaces: a folder inside another sits under it; the row's actions, as VoiceOver's action
    /// menu offers them (the context menu's), fold it away and back, add a subspace, rename and remove.
    @Test func theRowActionsCollapseAddSubspaceRenameAndRemove() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pressRowActions() }
        }
    }

    private static func pressRowActions() async throws {
        AccessibilityNode.enable()
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let acme = scratch.dir.appendingPathComponent("acme").resolvingSymlinksInPath()
        let web = acme.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: acme.appendingPathComponent(".shepherd"), withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"docs": {"command": "true"}, "shared": {"command": "true"}}}"#.utf8).write(to: acme.appendingPathComponent(".shepherd/mcp.json"))
        let space = Space(name: "acme", path: acme.path)
        try await scratch.server.putState(ShepherdState(spaces: [space, Space(name: "web", path: web.path)]))
        let defaults = ScratchDefaults()
        let vm = ShepherdViewModel(pi: scratch.server.pi, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
                                   themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
                                   remoteHosts: RemoteHostStore(defaults: defaults), sidebarDefaults: defaults, themeInstaller: { _ in })
        try await connectAsHost(vm, to: scratch)
        vm.showSettings = true; vm.settingsSection = .projects
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 1000), dark: true, RootView(vm: vm))
        defer { window.close() }
        let model = vm.projects
        try await eventuallyOnMain("the tree") { model.visible.map(\.project.name) == ["acme", "web"] }
        #expect(model.visible[1].configuration == "2 inherited MCP servers")

        try await eventuallyOnMain("the row's actions") { window.layout(); return !ControlPress.actions(onLabelContaining: "Open acme", under: window.host).isEmpty }
        #expect(ControlPress.actions(onLabelContaining: "Open acme", under: window.host).contains("Add subspace…"))
        try ControlPress.perform("Collapse", onLabelContaining: "Open acme", under: window.host)
        try await eventuallyOnMain("web folded away") { model.visible.map(\.project.name) == ["acme"] }
        window.layout()
        try ControlPress.perform("Expand", onLabelContaining: "Open acme", under: window.host)
        try await eventuallyOnMain("web back") { model.visible.count == 2 }

        window.layout()
        try ControlPress.perform("Add subspace…", onLabelContaining: "Open acme", under: window.host)
        try await eventuallyOnMain("the child-project dialog") {
            guard let sheet = window.window.attachedSheet?.contentView else { return false }
            sheet.layoutSubtreeIfNeeded()
            return ControlPress.controls(in: sheet).contains { $0.label == "Create and add" }
        }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        try ControlPress.press("Cancel", under: sheet)
        try await eventuallyOnMain("the child dialog to close") { window.window.attachedSheet == nil }

        window.layout()
        try ControlPress.perform("Rename Space…", onLabelContaining: "Open acme", under: window.host)
        try await eventuallyOnMain("the rename target") { vm.spaceRenameTarget == space.id }
        vm.spaceRenameTarget = nil

        window.layout()
        try ControlPress.perform("Remove Space…", onLabelContaining: "Open acme", under: window.host)
        try await eventuallyOnMain("the remove confirmation") { vm.spaceDeleteTarget == space.id }
        #expect(vm.state.spaces.contains { $0.id == space.id }, "Remove asks first")

        // A subspace's row opens its space.
        window.layout()
        try ControlPress.press("Open web under acme", under: window.host)
        try await eventuallyOnMain("web's detail") { model.selected?.project.name == "web" }
    }
}
