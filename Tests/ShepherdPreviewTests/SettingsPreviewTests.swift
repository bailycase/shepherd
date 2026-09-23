import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings and every sheet and dialog, in light and dark: see `PreviewTests` for how to run.
@Suite("Settings and dialog previews", .serialized, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SettingsPreviewTests {
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

    /// Remote with a configured host that cannot be reached.
    @Test func settingsRemoteWithHosts() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.remoteHosts.addHost(name: "horizon", host: "127.0.0.1", port: 1, token: "x")
        workspace.vm.settingsSection = .remote
        try await Preview.render("settings-remote-hosts", size: CGSize(width: 1280, height: 1000)) {
            SettingsView(vm: workspace.vm)
        }
    }

    // MARK: Creation sheets

    @Test func newAgentSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await workspace.seed(ShepherdState(spaces: [Space(name: "Shepherd", path: repo.path)]))
        workspace.vm.selectedSpaceID = workspace.vm.state.spaces.first?.id
        try await Preview.render("sheet-new-agent", size: CGSize(width: AppLayout.newAgentSheetWidth, height: 640)) {
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
        try await Preview.render("sheet-new-worktree", size: CGSize(width: AppLayout.newWorktreeSheetWidth, height: 360),
                                 untilGone: "resolving") {
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
        try await Preview.render("sheet-finalize-setup", size: CGSize(width: AppLayout.finalizeSheetWidth, height: 620), untilGone: "Checking") {
            FinalizeWorktreeSheet(vm: workspace.vm, agent: agent, space: space)
        }
    }

    /// The pipeline rows as Finalize draws them mid-run: done, skipped, running, pending.
    @Test func finalizePipeline() async throws {
        let states: [WorktreeFinalizer.StepState] = [.done("2 files"), .done("worktree/fix-login → origin"), .running, .pending, .pending, .pending]
        let steps = WorktreeFinalizer.Step.allCases.filter { $0 != .mergePR }
        try await Preview.render("sheet-finalize-pipeline", size: CGSize(width: AppLayout.finalizeSheetWidth, height: 380)) {
            NWDialog("Finalize worktree",
                     message: "Working — each step must succeed before the next runs. Nothing is deleted until the worktree is verified clean.",
                     width: AppLayout.finalizeSheetWidth) {
                ForEach(Array(zip(steps, states)), id: \.0) { step, state in
                    let status = state.checklist
                    NWChecklistRow(step.label, state: status.state, stateLabel: status.word, detail: status.detail)
                }
            } status: {
                HStack(spacing: NW.Space.s) {
                    ProgressView().progressViewStyle(.nwSpinner)
                    NWDialogStatus("Working…")
                }
            } actions: {
                EmptyView()
            }
        }
    }

    @Test func directoryPicker() async throws {
        let root = try makeScratchDirectory("picker")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Shepherd", "billing-service", "dotfiles", ".config", "notes"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try await Preview.render("sheet-directory-picker", size: CGSize(width: AppLayout.directoryPickerWidth, height: 480),
                                 untilGone: "Loading") {
            RemoteDirectoryPicker(hostName: "this Mac", startPath: root.path,
                                  list: { try await LocalDirectoryLister.load(path: $0) }, choose: { _ in }, cancel: {})
        }
    }

    /// A remote worktree deletion whose host is gone: the sheet explains instead of acting.
    @Test func remoteWorktreeSheetWithoutHost() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let target = RemoteAgentRef(hostID: UUID(), agentID: AgentID())
        try await Preview.render("sheet-remote-worktree-unavailable", size: CGSize(width: AppLayout.remoteWorktreeSheetWidth, height: 300)) {
            RemoteWorktreeSheet(vm: workspace.vm, target: target, finalize: false)
        }
    }

    // MARK: Dialogs

    @Test func renameDialog() async throws {
        try await Preview.render("sheet-rename", size: CGSize(width: AppLayout.renameSheetWidth, height: 180)) {
            RenameDialog(title: "Rename agent", name: "Fix the login redirect", onRename: { _ in }, onCancel: {})
        }
    }

    @Test func renameSpaceDialog() async throws {
        try await Preview.render("sheet-rename-space", size: CGSize(width: AppLayout.renameSheetWidth, height: 210)) {
            RenameDialog(title: "Rename space", caption: "Sidebar label only — the folder on disk is not renamed.",
                         name: "Shepherd", onRename: { _ in }, onCancel: {})
        }
    }

    /// Delete Worktree Agent over a worktree with uncommitted work: the warning arrives from
    /// git off the main thread.
    @Test func deleteWorktreeAgentDialog() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "changed\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let space = Space(name: "Shepherd", path: repo.path)
        let (seeded, tab) = try await workspace.agent("Fix the login redirect", in: space, order: 0, branch: "worktree/fix-login")
        var agent = seeded
        agent.worktreePath = repo.path
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        try await Preview.render("sheet-delete-worktree", size: CGSize(width: AppLayout.confirmSheetWideWidth, height: 360),
                                 untilGone: "Checking") {
            WorktreeDeleteDialog(vm: workspace.vm, agent: agent)
        }
    }

    @Test func removeSpaceDialog() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "billing-service", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Migrate invoices to v2", in: space, order: 0)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        try await Preview.render("sheet-remove-space", size: CGSize(width: NWDialogMetrics.width, height: 220)) {
            SpaceDeleteDialog(vm: workspace.vm, space: space)
        }
    }

    @Test func stopAllDialog() async throws {
        try await Preview.render("sheet-stop-all", size: CGSize(width: NWDialogMetrics.width, height: 180)) {
            StopAllDialog(runningSubagents: 3, stopAgent: {}, stopAll: {}, cancel: {})
        }
    }

    @Test func revertFileDialog() async throws {
        try await Preview.render("sheet-revert-file", size: CGSize(width: NWDialogMetrics.width, height: 200)) {
            RevertFileDialog(path: "Sources/ShepherdApp/SidebarView.swift", isNew: false, revert: {}, cancel: {})
        }
    }

    @Test func actionErrorDialog() async throws {
        try await Preview.render("sheet-action-error", size: CGSize(width: NWDialogMetrics.width, height: 200)) {
            ActionErrorDialog(message: "horizon rejected the rename: agent_busy — the agent is mid-turn. Try again once it settles.") {}
        }
    }

    @Test func resetSettingsDialog() async throws {
        try await Preview.render("sheet-reset-settings", size: CGSize(width: NWDialogMetrics.width, height: 180)) {
            ResetSettingsDialog(reset: {}, cancel: {})
        }
    }
}

extension SettingsSection: CustomTestStringConvertible {
    public var testDescription: String { rawValue }
}
