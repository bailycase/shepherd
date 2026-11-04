import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
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
        editor.test(with: hooks.model)
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

    /// Settings › Hooks for a remote host (studio) through the same model over hooks.v1, from the
    /// fixture's real catalog answered by a stand-in host; one too old to serve hooks; and the
    /// edit sheet's test on that host with its Output open.
    @Test func settingsHooksRemoteHost() async throws {
        let hooks = try HookFixture()
        defer { hooks.remove() }
        let snapshot = hooks.model.catalog!.load(spaceRoots: [hooks.payments, hooks.ledger, hooks.web])
        let id = UUID()
        let stand = HooksStandIn(snapshot)
        let host = SettingsHost(id: id, name: "studio", client: stand, capabilities: [RemoteProtocol.hooksCapability])
        let model = HooksModel(host: id) { host }
        model.reload()
        try await eventuallyOnMain("the host's hooks") { model.snapshot != nil && !model.loading }
        try await Preview.render("settings-hooks-remote", size: CGSize(width: 1100, height: 1100)) { RemoteHooksChrome(model: model) }
        model.tab = .sources
        try await Preview.render("settings-hooks-remote-sources", size: CGSize(width: 1100, height: 1000)) { RemoteHooksChrome(model: model) }

        let older = HooksModel(host: id) { SettingsHost(id: id, name: "studio", client: stand, capabilities: []) }
        try await Preview.render("settings-hooks-remote-older", size: CGSize(width: 1100, height: 400)) { RemoteHooksChrome(model: older) }

        let entry = try #require(model.snapshot?.entries.first { $0.handler.command == HookFixture.noEnv })
        model.edit(entry)
        let editor = try #require(model.editor)
        editor.test(with: model)
        try await eventuallyOnMain("the host's test result") { editor.testResult != nil }
        editor.outputOpen = true
        try await Preview.render("settings-hooks-remote-test-output", size: CGSize(width: 640, height: 840)) {
            HookEditSheet(editor: editor, model: model) {}
        }
        // A save the host refuses because the hook changed there: said, with Reload.
        stand.refuse = true
        editor.outputOpen = false
        #expect(await editor.save(with: model) == false)
        try await Preview.render("settings-hooks-remote-conflict", size: CGSize(width: 640, height: 840)) {
            HookEditSheet(editor: editor, model: model) {}
        }
    }
}

/// A host answering hooks.v1 from one snapshot: a test prints to both streams and blocks; with
/// `refuse`, a change is refused as changed since it was read.
private final class HooksStandIn: SettingsClient, HooksClient, @unchecked Sendable {
    let snapshot: HookCatalogSnapshot
    var refuse = false
    init(_ snapshot: HookCatalogSnapshot) { self.snapshot = snapshot }

    func hooks(_ request: RemoteHooksRequest) async throws -> RemoteHooksResult {
        if refuse, request.changesHooks {
            throw RemoteHostClientError.rejected(code: "hook_changed", message: "This hook changed in its file since you read it. Reload and try again.")
        }
        if case .test = request {
            return .tested(HookTestResult(exit: 2, stdout: "checked .env\nchecked .env.local\n", stderr: "No edits to .env files.\n",
                                          milliseconds: 38, outcome: .blocked(reason: "No edits to .env files.")))
        }
        return .hooks(snapshot)
    }
    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult { throw RemoteHostClientError.disconnected }
    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings { HostSettings() }
    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot { InstructionsSnapshot(directory: "~") }
    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot { SuggestionsSnapshot() }
}

/// The Settings detail with "Host: studio" over the page, as SettingsView draws a remote host's.
private struct RemoteHooksChrome: View {
    let model: HooksModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                HStack(spacing: SH.Space.m) {
                    Text("Host").font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textSecondary)
                    SHPopupMenu("studio", minWidth: AppLayout.settingsPopupWidth) { Button("This Mac") {} }
                    Spacer(minLength: 0)
                }
                HooksSettings(model: model)
            }
            .padding(.top, AppLayout.settingsTop)
            .padding(.horizontal, AppLayout.settingsWideSides)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.sh.bgWindow)
    }
}
