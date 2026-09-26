import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings and every sheet and dialog, in light and dark: see `PreviewTests` for how to run.
@Suite("Settings and dialog previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SettingsPreviewTests {
    // MARK: Settings

    @Test(arguments: SettingsSection.allCases)
    func settings(section: SettingsSection) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.settingsSection = section
        // Tall enough for the whole page.
        let height: CGFloat = switch section {
        case .pi: 1480
        case .keyboard: 2200
        case .remote, .worktrees: 1000
        default: 900
        }
        try await Preview.render("settings-\(section.rawValue)", size: CGSize(width: 1280, height: height)) {
            SettingsView(vm: workspace.vm)
        }
    }

    /// Skills with a sourced skill waiting on an update, two used only through /skill (one off),
    /// and the page's rail: installed from a scratch repository on this Mac, no network.
    @Test func settingsSkillsInstalled() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let repo = try makeScratchRepo(files: [
            "skills/pdf/SKILL.md": "---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n# PDF\n",
            "skills/pdf/reference.md": "# Reference\n",
            "skills/pdf/scripts/fill.py": "print('fill')\n",
            "skills/frontend-design/SKILL.md": "---\nname: frontend-design\ndescription: Production-grade UI that doesn’t look generic.\n---\n",
            "skills/webapp-testing/SKILL.md": "---\nname: webapp-testing\ndescription: Tests local web apps with Playwright.\n---\n",
        ])
        let store = workspace.server.skills
        let url = "file://" + repo.path
        try store.install(repo: url, paths: ["skills/pdf", "skills/frontend-design", "skills/webapp-testing"], commit: nil,
                          invocation: nil)
        try "---\nname: pdf\ndescription: Read, fill, merge and split PDFs.\n---\n# PDF\n\nFill forms first.\n"
            .write(to: repo.appendingPathComponent("skills/pdf/SKILL.md"), atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "Fill forms first"], in: repo)
        try store.checkUpdates()
        for (name, description) in [("go-table-tests", "House style for table-driven Go tests."),
                                    ("changelog", "Drafts a CHANGELOG entry since the last tag.")] {
            let text = "---\nname: \(name)\ndescription: \(description)\n---\n"
            try store.installFiles(name: name, files: [SkillFile(path: "SKILL.md", contents: Data(text.utf8))], invocation: .slashOnly)
        }
        try store.setOn("changelog", on: false)
        let vm = workspace.vm
        vm.settingsSection = .skills
        try await Preview.render("settings-skills-installed", size: CGSize(width: 1440, height: 900),
                                 ready: { vm.skills.row("pdf", in: vm.skillsHosts)?.skill.update != nil }) {
            SettingsView(vm: vm)
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

    /// A host for each way a connection fails (nothing listening, a refused token, another
    /// protocol): the word says which, and the sentence under it says what to do.
    @Test func settingsRemoteHostFailures() async throws {
        let failures: [(String, RemoteHostClientError)] = [
            ("horizon", .system(call: "connect", errno: ECONNREFUSED)),
            ("studio", .rejected(code: RemoteProtocol.unauthorizedCode, message: "bad token")),
            ("build-01", .rejected(code: RemoteProtocol.versionMismatchCode, message: "host speaks protocol \(RemoteProtocol.version + 1)")),
        ]
        let connections = failures.map { name, error in
            let connection = RemoteHostStore.Connection(config: .init(name: name, host: "\(name).internal", port: 7433, token: "x"))
            connection.phase = .failed(RemoteHostFailure(error))
            return connection
        }
        let size = CGSize(width: AppLayout.settingsContentWidth + 2 * AppLayout.settingsGutter, height: 360)
        try await Preview.render("settings-remote-host-failures", size: size) {
            SettingsGroup(title: "Hosts") {
                ForEach(connections) { connection in
                    RemoteHostRow(connection: connection, remove: {}, reconnect: {}, edit: {})
                }
            }
            .padding(AppLayout.settingsGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    private nonisolated static let instructionsSample = """
        # How I work

        ## Stack
        - Swift 6 and SwiftUI on macOS 26. Packages build with `swift build`.
        - Tests use Swift Testing, never XCTest.

        ## Before you say you're done
        - `swift test` passes.
        - Small commits, imperative subjects, no emoji.

        """

    /// Instructions with both files saved and an unsaved edit: the changed line tinted, "● edited"
    /// in the header, Save lit.
    @Test func settingsInstructionsEdited() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try workspace.server.instructions.save(.agents, content: Self.instructionsSample)
        try workspace.server.instructions.save(.appendSystem, content: "Never force-push to main.\n")
        let model = workspace.vm.instructions
        await model.refresh()
        model.setText(Self.instructionsSample.replacingOccurrences(of: "passes.", with: "passes and `swiftformat --lint .` is clean."),
                      file: .agents, on: .local)
        workspace.vm.settingsSection = .instructions
        try await Preview.render("settings-instructions-edited", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: workspace.vm)
        }
    }

    /// Experiments with Suggested instructions on: three lines waiting (a thread's, an
    /// automation's for APPEND_SYSTEM.md, and one being edited first) and one already added.
    @Test func settingsExperimentsWithSuggestions() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let store = workspace.server.suggestions
        try store.configure(SuggestedInstructionsSettings(enabled: true, files: [.agents, .appendSystem]))
        let now = Date().timeIntervalSince1970
        let lines: [(String, String, InstructionFile, SuggestionSource, Double)] = [
            ("Prefer table-driven tests in Go.", "Three tests repeated one setup.", .agents,
             SuggestionSource(kind: .thread, name: "Ledger cleanup"), 200_000),
            ("Don't skip or retry a flaky test; find the race.", "You corrected the agent after it added t.Skip().", .agents,
             SuggestionSource(kind: .thread, name: "Fix flaky ledger test"), 90_000),
            ("Run `go mod tidy` and commit go.sum with any dependency bump.", "CI failed twice on a stale go.sum.", .appendSystem,
             SuggestionSource(kind: .automation, name: "Nightly dependency bump"), 7_200),
            ("Ask for join keys before adding an event.", "A missing checkout_id made two services re-run their steps.", .agents,
             SuggestionSource(kind: .thread, name: "Checkout funnel events"), 600),
        ]
        for (line, reason, file, source, ago) in lines {
            _ = try store.suggest(line: line, reason: reason, file: file, source: source, now: Date(timeIntervalSince1970: now - ago))
        }
        let oldest = try #require(store.snapshot().waiting.last)
        try store.add(oldest.id)
        let model = workspace.vm.suggestions
        await model.refresh()
        let editing = try #require(model.snapshot.waiting.first)
        model.edit(editing)
        workspace.vm.settingsSection = .experiments
        try await Preview.render("settings-experiments-suggestions", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: workspace.vm)
        }
    }

    /// Settings ▸ Advanced ▸ Updates as each app shows it. Sparkle only runs in a bundled app,
    /// so the Advanced page above renders without this group.
    @Test func updateChannelRows() async throws {
        let size = CGSize(width: AppLayout.settingsContentWidth + 2 * AppLayout.settingsGutter, height: 300)
        try await Preview.render("settings-update-channel", size: size) {
            VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
                SettingsGroup(title: "Shepherd") {
                    UpdateChannelRow(edition: .main, channel: .constant(.beta))
                }
                SettingsGroup(title: "Shepherd Nightly") {
                    UpdateChannelRow(edition: .nightly, channel: .constant(.nightly))
                }
            }
            .padding(AppLayout.settingsGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    // MARK: Creation sheets

    /// `sheet-new-agent` with a model that reasons; `-plain-model` with pi's default one that
    /// takes no thinking level, so the sheet offers no Thinking row.
    @Test(arguments: [("sheet-new-agent", true), ("sheet-new-agent-plain-model", false)])
    func newAgentSheet(name: String, reasons: Bool) async throws {
        let workspace = try PreviewWorkspace(modelCatalog: {
            ModelListing(entries: [PiModelCatalog.Entry(id: "qa/gemini-3.1-flash-lite", reasoning: reasons)],
                         defaultModel: "qa/gemini-3.1-flash-lite")
        })
        defer { workspace.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try await workspace.seed(ShepherdState(spaces: [Space(name: "Shepherd", path: repo.path)]))
        workspace.vm.selectedSpaceID = workspace.vm.state.spaces.first?.id
        try await Preview.render(name, size: CGSize(width: AppLayout.newAgentSheetWidth, height: 640),
                                 untilGone: reasons ? nil : "Thinking") {
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

    private nonisolated static let prBody = """
        ## Summary
        Keeps the return URL through the OAuth round trip, so signing in lands where you started.

        ## Testing
        - swift test --filter LoginRedirectTests
        """

    /// The finalize form, and the sheet once the pipeline finished or stopped. Staged: nothing
    /// runs git, gh or the network.
    @Test(arguments: ["input", "done", "failed"])
    func finalizeSheet(state: String) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: "/Users/ada/Developer/Shepherd")
        var (agent, _) = try await workspace.agent("Fix the login redirect", in: space, order: 0, branch: "worktree/fix-login")
        agent.worktreePath = "/Users/ada/Developer/Shepherd-worktree-fix-login"
        let done: [WorktreeFinalizer.Step: WorktreeFinalizer.StepState] = [
            .commit: .done("committed"), .push: .done("pushed"), .pullRequest: .done("https://github.com/ada/shepherd/pull/128"),
            .verifyClean: .done("clean"), .removeWorktree: .done("removed"), .deleteBranch: .done("deleted"),
        ]
        let rejected = """
            To github.com:ada/shepherd.git
             ! [rejected]        worktree/fix-login -> worktree/fix-login (fetch first)
            error: failed to push some refs to 'github.com:ada/shepherd.git'
            """
        let staged: FinalizeWorktreeSheet.Staged = switch state {
        case "input": .init(phase: .input, title: agent.name, body: Self.prBody, includedCommits: 3)
        case "done": .init(phase: .done, steps: done, prURL: "https://github.com/ada/shepherd/pull/128")
        default: .init(phase: .failed, steps: [.commit: .done("committed"),
                                               .push: .failed(WorktreeFinalizer.failureDetail(.init(status: 1, stdout: "", stderr: rejected)))])
        }
        try await Preview.render("sheet-finalize-\(state)", size: CGSize(width: AppLayout.finalizeSheetWidth, height: 560)) {
            FinalizeWorktreeSheet(vm: workspace.vm, agent: agent, space: space, staged: staged)
        }
    }

    /// The remote sheet's finalize form as a ready host fills it. Staged: no host is asked.
    @Test func remoteFinalizeSheet() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.vm.remoteHosts.addHost(name: "horizon", host: "127.0.0.1", port: 1, token: "x")
        let host = try #require(workspace.vm.remoteHosts.connections.first)
        let target = RemoteAgentRef(hostID: host.id, agentID: AgentID())
        let defaults = RemoteFinalizeOptions(base: "main", title: "Fix the login redirect", body: Self.prBody, autoCommit: true,
                                             deleteLocalBranch: true, autoMergePR: false, mergeMethod: "squash")
        let info = RemoteWorktreeInfo(path: "/Users/ada/Developer/Shepherd-worktree-fix-login", branch: "worktree/fix-login", warning: nil,
                                      defaults: defaults, generateDescription: true)
        try await Preview.render("sheet-remote-finalize", size: CGSize(width: AppLayout.remoteWorktreeSheetWidth, height: 720)) {
            RemoteWorktreeSheet(vm: workspace.vm, target: target, finalize: true, staged: .init(info: info, includedCommits: 3))
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

    /// An agent's `agent_delete`, waiting for the user: an agent in its space's directory, and
    /// one in a worktree (named by its branch; the banner says the worktree is kept).
    @Test func peerDeleteDialog() async throws {
        try await Preview.render("sheet-peer-delete", size: CGSize(width: NWDialogMetrics.width, height: 400)) {
            PeerDeleteDialog(requester: "Coordinate the release", agent: "Flaky integration tests",
                             space: "billing-service", directory: "~/Developer/billing-service", delete: {}, cancel: {})
        }
        try await Preview.render("sheet-peer-delete-worktree", size: CGSize(width: NWDialogMetrics.width, height: 400)) {
            PeerDeleteDialog(requester: "Coordinate the release", agent: "Flaky integration tests",
                             space: "billing-service", branch: "fix/flaky-integration-tests", delete: {}, cancel: {})
        }
    }

    @Test func stopAllDialog() async throws {
        try await Preview.render("sheet-stop-all", size: CGSize(width: NWDialogMetrics.width, height: 180)) {
            StopAllDialog(runningSubagents: 3, stopAgent: {}, stopAll: {}, cancel: {})
        }
    }

    /// Quit while agents work: five named (one waiting on an answer), the rest counted.
    @Test func quitDialog() async throws {
        let space = Space(name: "shepherd", path: "/tmp/shepherd")
        let names = ["Fix the login redirect", "Night Watch tokens", "Review the sidebar", "Flaky integration tests",
                     "Release notes", "Remote listener", "Docs pass"]
        let agents = names.enumerated().map { index, name in
            Agent(name: name, spaceID: space.id, tabID: TabID(), status: index == 1 ? .blocked : .working)
        }
        let prompt = try #require(QuitPrompt(agents: agents))
        try await Preview.render("sheet-quit", size: CGSize(width: NWDialogMetrics.width, height: 330)) {
            QuitDialog(prompt: prompt, quit: {}, cancel: {})
        }
        let one = try #require(QuitPrompt(agents: [agents[0]]))
        try await Preview.render("sheet-quit-one", size: CGSize(width: NWDialogMetrics.width, height: 200)) {
            QuitDialog(prompt: one, quit: {}, cancel: {})
        }
    }

    @Test func revertFileDialog() async throws {
        try await Preview.render("sheet-revert-file", size: CGSize(width: NWDialogMetrics.width, height: 200)) {
            RevertFileDialog(path: "Sources/ShepherdApp/SidebarView.swift", repository: "~/Developer/Shepherd", isNew: false,
                             revert: {}, cancel: {})
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
