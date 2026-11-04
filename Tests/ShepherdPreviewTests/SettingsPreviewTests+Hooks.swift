import AppKit
import Foundation
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings › Hooks (HooksSettings, HooksSources, HooksEdit boards) in light and dark,
/// from hooks files in a scratch home read through the real catalog.
extension SettingsPreviewTests {
    @Test func settingsHooks() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        let workspace = try PreviewWorkspace(hooks: hooks.model)
        defer { workspace.stop() }
        try await hooks.load()
        workspace.vm.settingsSection = .hooks
        try await Preview.render("settings-hooks", size: CGSize(width: 1440, height: 1100)) { SettingsView(vm: workspace.vm) }
        hooks.model.filter = "PreToolUse"
        try await Preview.render("settings-hooks-filtered", size: CGSize(width: 1440, height: 700)) { SettingsView(vm: workspace.vm) }
        hooks.model.filter = nil
        hooks.model.tab = .sources
        try await Preview.render("settings-hooks-sources", size: CGSize(width: 1440, height: 1000)) { SettingsView(vm: workspace.vm) }
        // A reader switched off: its files say so and dim.
        hooks.model.setReader(.claude, false)
        let model = hooks.model
        try await eventuallyOnMain("the Claude Code reader to be off") { !model.readers.claude && !model.loading }
        try await Preview.render("settings-hooks-sources-reader-off", size: CGSize(width: 1440, height: 1000)) { SettingsView(vm: workspace.vm) }
    }

    @Test func settingsHooksEmpty() async throws {
        let hooks = try HookFixture(empty: true)
        defer { hooks.remove() }
        let workspace = try PreviewWorkspace(hooks: hooks.model)
        defer { workspace.stop() }
        try await hooks.load()
        workspace.vm.settingsSection = .hooks
        try await Preview.render("settings-hooks-empty", size: CGSize(width: 1440, height: 600)) { SettingsView(vm: workspace.vm) }
    }

    @Test func settingsHooksEdit() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        try await hooks.load()
        let entry = try #require(hooks.model.snapshot?.entries.first { $0.handler.command == HookFixture.noEnv })
        hooks.model.edit(entry)
        let editor = try #require(hooks.model.editor)
        // The test runs the real script against a sample edit: it blocks with its reason.
        editor.test()
        try await eventuallyOnMain("the test to finish", timeout: .seconds(20)) { editor.testResult != nil }
        #expect(editor.testResult?.outcome == .blocked(reason: "No edits to .env files."))
        try await Preview.render("settings-hooks-edit-form", size: CGSize(width: 640, height: 840)) {
            HookEditSheet(editor: editor, model: hooks.model) {}
        }
        editor.pane = .json
        try await Preview.render("settings-hooks-edit-json", size: CGSize(width: 640, height: 840)) {
            HookEditSheet(editor: editor, model: hooks.model) {}
        }
        // Add, with a matcher that isn't an expression.
        hooks.model.add()
        let adding = try #require(hooks.model.editor)
        adding.matcher = "Edit|("
        try await Preview.render("settings-hooks-add-invalid", size: CGSize(width: 640, height: 840)) {
            HookEditSheet(editor: adding, model: hooks.model) {}
        }
    }
}
