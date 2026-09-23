import AppKit
import Foundation
import ShepherdCore
import ShepherdDesign
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
    // MARK: Sidebar and chrome

    /// A space with agents in every status, one with subagents, a worktree agent, an
    /// automation, and an unreachable second machine.
    private func populatedWorkspace() async throws -> (PreviewWorkspace, [Agent]) {
        let workspace = try PreviewWorkspace()
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let other = Space(name: "billing-service", path: workspace.dir.appendingPathComponent("billing").path)
        let rows: [(String, AgentStatus, String?)] = [
            ("Plan shepherd extensions", .working, nil), ("Dock review pane", .working, "worktree/dock-review"),
            ("Fix remote subagent deletion", .idle, nil), ("Investigate SwiftUI live preview", .idle, nil),
            ("Fix remote nightly", .blocked, nil), ("Fix agent deletion workflow", .done, nil),
        ]
        var agents: [Agent] = [], tabs: [ShepherdCore.Tab] = []
        for (index, row) in rows.enumerated() {
            let (agent, tab) = try await workspace.agent(row.0, in: space, order: index, status: row.1, branch: row.2)
            agents.append(agent); tabs.append(tab)
        }
        let (billing, billingTab) = try await workspace.agent("Migrate invoices to v2", in: other, order: 0, status: .idle)
        agents.append(billing); tabs.append(billingTab)
        let automation = Automation(name: "Merge PR #24 after CI", prompt: "watch", cwd: workspace.dir.path, enabled: false)
        try await workspace.seed(ShepherdState(spaces: [space, other], tabs: tabs, agents: agents, automations: [automation]))
        let vm = workspace.vm
        vm.selectedSpaceID = space.id
        vm.selectedAgentID = agents[3].id
        vm.applyAgentChildren(agents[3].id, Array(Threads.liveRuns.prefix(3)))
        vm.applyAgentChildren(agents[5].id, Threads.doneRuns)
        vm.remoteHosts.addHost(name: "Horizon", host: "127.0.0.1", port: 1, token: "x")
        return (workspace, agents)
    }

    @Test func sidebar() async throws {
        let (workspace, _) = try await populatedWorkspace()
        defer { workspace.stop() }
        try await Preview.render("sidebar", size: CGSize(width: 256, height: 720)) {
            SidebarView(vm: workspace.vm).background(Tokens.bgCanvas)
        }
    }

    /// The whole window with the sidebar hidden: the header runs under the traffic lights.
    @Test func sidebarHiddenHeader() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Investigate SwiftUI live preview", in: space, order: 0, live: true)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        workspace.vm.sidebarHidden = true
        workspace.vm.selectAgent(agent.id)
        let store = workspace.vm.threadStores.store(for: agent.id)
        try await Preview.render("sidebar-hidden-header", size: CGSize(width: 1280, height: 800), ready: { store.ready }) {
            RootView(vm: workspace.vm)
        }
    }

    /// The full window over a live (stub) agent after one turn.
    @Test func appWindow() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        let (agent, tab) = try await workspace.agent("Investigate SwiftUI live preview", in: space, order: 0, status: .done, live: true)
        let (other, otherTab) = try await workspace.agent("Dock review pane", in: space, order: 1, status: .working, live: true)
        try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab, otherTab], agents: [agent, other]))
        let server = workspace.server
        try await eventuallyAsync("pi to be ready") {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            return !snapshot.piSessionID.isEmpty
        }
        let snapshot = try await server.nativeThread(agentID: agent.id, request: .snapshot())
        guard case .snapshot(let ready) = snapshot else { return }
        _ = try await server.nativeThread(agentID: agent.id, request: .send(
            expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID(),
            text: "List the files in this checkout.", delivery: .followUp))
        workspace.vm.selectAgent(agent.id)
        let store = workspace.vm.threadStores.store(for: agent.id)
        try await Preview.render("app-window", size: CGSize(width: 1440, height: 900),
                                 ready: { store.ready && store.messages.contains { $0.toolName == "bash" } }) {
            RootView(vm: workspace.vm)
        }
    }

    // MARK: Empty workspace states

    @Test(arguments: ["no-spaces", "space-without-agents", "no-agent-selected"])
    func emptyWorkspace(state: String) async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "Shepherd", path: workspace.dir.path)
        switch state {
        case "space-without-agents":
            try await workspace.seed(ShepherdState(spaces: [space]))
            workspace.vm.selectSpace(space.id)
        case "no-agent-selected":
            let (agent, tab) = try await workspace.agent("Background agent", in: space, order: 0, live: true)
            try await workspace.seed(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
            workspace.vm.selectedAgentID = nil
            workspace.vm.selectedSpaceID = nil
        default: break
        }
        try await Preview.render("empty-\(state)", size: CGSize(width: 1280, height: 760)) {
            RootView(vm: workspace.vm)
        }
    }

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

    @Test func threadSubagentsLive() async throws {
        try await renderThread("thread-subagents-live", ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true)),
                               size: CGSize(width: 800, height: 900))
    }

    @Test func threadSubagentsLedger() async throws {
        try await renderThread("thread-subagents-ledger", ThreadFixture(Threads.subagents(Threads.doneRuns, running: false)),
                               size: CGSize(width: 800, height: 800), inspected: "native-tests")
    }

    @Test func threadSubagentInspector() async throws {
        let fixture = ThreadFixture(Threads.subagents(Array(Threads.liveRuns.prefix(3)), running: true))
        fixture.transcripts["native-worker"] = Threads.workerTranscript
        defer { fixture.store.stop() }
        let panes = RightPaneState()
        panes.runByAgent[AgentID(rawValue: "a")] = "native-worker"
        try await Preview.render("thread-subagent-inspector", size: CGSize(width: 1370, height: 900), ready: { fixture.store.ready }) {
            RightPaneSplit(state: panes, showPane: true) {
                fixture.thread(inspected: "native-worker")
            } pane: {
                SubagentInspector(store: fixture.store, runID: "native-worker", active: true, close: {}, select: { _ in }, fork: { _ in nil })
            }
        }
    }

    @Test func subagentCardsInEveryState() async throws {
        let actions = SubagentActions(inspect: { _ in }, command: { _, _, _, _ in }, enabled: true)
        let many = (0..<12).map { index -> ChildRun in
            var run = Threads.liveRuns[index < 7 ? 2 : index < 10 ? 0 : index == 10 ? 1 : 3]
            run.runID = "strip-\(index)"
            run.startedAt = Double(index)
            return run
        }
        try await Preview.render("subagent-cards", size: CGSize(width: 760, height: 1040)) {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Threads.liveRuns, id: \.id) { SubagentCard(run: $0, actions: actions) }
                Text("MANY PARALLEL RUNS").font(Fonts.section).foregroundStyle(Tokens.textMuted)
                RunsStrip(runs: many, actions: actions, expanded: .constant(false))
                Spacer(minLength: 0)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Tokens.bgSurface)
        }
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

    // MARK: Review, palette, gallery

    @Test func reviewPane() async throws {
        let session = Reviews.session()
        try await Preview.render("review-pane", size: CGSize(width: 760, height: 900)) {
            ReviewPane(session: session, actions: Reviews.actions).background(Tokens.bgSurface)
        }
    }

    @Test func commandPalette() async throws {
        let (workspace, agents) = try await populatedWorkspace()
        defer { workspace.stop() }
        workspace.vm.selectAgent(agents[3].id)
        try await Preview.render("command-palette", size: CGSize(width: 1000, height: 720)) {
            ZStack(alignment: .top) {
                Tokens.bgSurface
                Tokens.scrim
                CommandPaletteView(vm: workspace.vm).padding(.top, Metrics.paletteTop)
            }
        }
    }

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
                    Text("~/Developer/Shepherd-worktree-fix-login").font(Fonts.code).foregroundStyle(Tokens.textSecondary).lineLimit(1)
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
