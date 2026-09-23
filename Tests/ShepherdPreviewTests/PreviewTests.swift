import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Renders every surface in light and dark to `$SHEPHERD_PREVIEW_DIR/<surface>-<light|dark>.png`
/// so a person or an agent can look at them:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ShepherdPreviewTests
///
/// Fixtures and a scripted stub pi only: no real model, no user files. Serialized so each
/// render has the main thread to itself.
@Suite("Previews", .serialized, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct PreviewTests {
    // MARK: Threads

    private func renderThread(_ surface: String, _ fixture: ThreadFixture, size: CGSize = CGSize(width: 1180, height: 1000),
                              inspected: String? = nil) async throws {
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready }) {
            fixture.thread(inspected: inspected)
        }
    }

    @Test func threadIdle() async throws {
        try await renderThread("thread-idle", ThreadFixture(Threads.idle))
    }

    @Test func threadRunning() async throws {
        try await renderThread("thread-running", ThreadFixture(Threads.running))
    }

    @Test func threadQuestion() async throws {
        try await renderThread("thread-question", ThreadFixture(Threads.question))
    }

    @Test func threadEmpty() async throws {
        try await renderThread("thread-empty", ThreadFixture(Threads.empty), size: CGSize(width: 1180, height: 700))
    }

    // MARK: Composer menus

    @Test func composerSlashMenu() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        fixture.store.draft = "/"
        try await Preview.render("composer-slash-menu", size: CGSize(width: 1000, height: 760), ready: { fixture.store.ready }) {
            fixture.thread()
        }
    }

    @Test func composerModelPicker() async throws {
        let fixture = ThreadFixture(Threads.idle)
        defer { fixture.store.stop() }
        let entries = [("anthropic/claude-opus-4-5", "200K"), ("anthropic/claude-sonnet-4-5", "1M"), ("anthropic/claude-haiku-4-5", "200K"),
                       ("openai/gpt-5", "400K"), ("google/gemini-2.5-pro", "1M")].map { PiModelCatalog.Entry(id: $0.0, context: $0.1) }
        try await Preview.render("composer-model-picker", size: CGSize(width: 1000, height: 820), ready: { fixture.store.ready },
                                 afterReady: { fixture.commands.send(.modelPicker, to: "preview") }) {
            fixture.thread(listModels: { entries })
        }
    }

    // MARK: Gallery (the palette is in NavigationPreviewTests, the review pane in ReviewPreviewTests)

    @Test func componentGallery() async throws {
        try await Preview.render("components", size: CGSize(width: 1440, height: 1320)) {
            ComponentGallery()
        }
    }

    // MARK: Settings

    @Test(arguments: SettingsSection.allCases)
    func settings(section: SettingsSection) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = section
        try await Preview.render("settings-\(section.rawValue)", size: CGSize(width: 1280, height: 900)) {
            SettingsView(vm: workspace.vm)
        }
    }

    // MARK: Sheets and dialogs

    @Test func newAgentSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await workspace.seed(ShepherdState(spaces: [Space(name: "Shepherd", path: repo.path)]))
        workspace.vm.selectedSpaceID = workspace.vm.state.spaces.first?.id
        try await Preview.render("sheet-new-agent", size: CGSize(width: 620, height: 660)) {
            NewAgentSheet(vm: workspace.vm)
        }
    }

    @Test func newWorktreeSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Space(name: "Shepherd", path: repo.path)
        try await workspace.seed(ShepherdState(spaces: [space]))
        try await Preview.render("sheet-new-worktree", size: CGSize(width: 560, height: 440)) {
            NewWorktreeSheet(vm: workspace.vm, space: space)
        }
    }

    /// The finalize sheet's setup checklist: the scratch repo has no origin, so the wizard
    /// stops on the checks instead of reaching the PR form.
    @Test func finalizeSetupSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Space(name: "Shepherd", path: repo.path)
        let (agent, tab) = try await workspace.agent("Fix the login redirect", in: space, order: 0, branch: "worktree/fix-login")
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        try await Preview.render("sheet-finalize-setup", size: CGSize(width: 560, height: 600), untilGone: "Checking") {
            FinalizeWorktreeSheet(vm: workspace.vm, agent: agent, space: space)
        }
    }

    @Test func renameDialog() async throws {
        try await Preview.render("sheet-rename", size: CGSize(width: 420, height: 180)) {
            RenameDialog(title: "Rename agent", text: .constant("Fix the login redirect"), onRename: {}, onCancel: {})
        }
    }

    @Test func deleteWorktreeAgentDialog() async throws {
        try await Preview.render("sheet-delete-worktree", size: CGSize(width: 460, height: 280)) {
            DialogSheet(title: "Delete “Fix the login redirect”?", subtitle: "The agent stops and its thread is removed from Shepherd.",
                        actions: [DialogAction("Cancel", kind: .cancel) {}, DialogAction("Delete Agent and Worktree", kind: .destructive) {}]) {
                DialogWarning(text: "3 uncommitted changes and 2 commits only on worktree/fix-login will be lost.")
                SheetRow("Worktree") {
                    Text("~/Developer/Shepherd-worktree-fix-login").font(Font.nw(.mono)).foregroundStyle(Color.nw.textSecondary).lineLimit(1)
                }
            }
        }
    }
}

extension SettingsSection: CustomTestStringConvertible {
    public var testDescription: String { rawValue }
}

/// `eventually` for main-actor previews whose condition awaits the server.
@MainActor
func eventuallyAsync(_ what: String, timeout: Duration = .seconds(20), _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    if try await condition() { return }
    Issue.record("timed out waiting for \(what)")
}
