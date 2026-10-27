import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// View-model behaviour from the 2026-10 audit: an equal snapshot adopts nothing, a covered
/// thread is not watched, and deleting an agent confirms first.
@Suite("Audit view model flow", .mainActorExclusive)
@MainActor
struct AuditViewModelFlowTests {
    private func fleet(_ app: AppHarness) -> (ShepherdState, [AgentFixture]) {
        let space = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let fixtures = (0..<2).map { Fixture.agent("agent-\($0)", in: space, order: $0) }
        return (Fixture.state(spaces: [space], agents: fixtures), fixtures)
    }

    @Test func adoptingAnEqualSnapshotInvalidatesNoReaderOfState() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, _) = fleet(app)
        let vm = try await app.start(with: state)

        let invalidated = ChangeFlag()
        withObservationTracking { _ = vm.state.agents.count } onChange: { invalidated.fired = true }
        vm.adopt(app.server.state)
        #expect(!invalidated.fired, "an equal broadcast must not touch `state`")

        var changed = app.server.state
        changed.agents[0].name = "renamed"
        vm.adopt(changed)
        #expect(invalidated.fired)
        #expect(vm.state.agents[0].name == "renamed")
    }

    @Test func aPageOrSettingsOverTheSelectedThreadStopsWatchingIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app)
        let vm = try await app.start(with: state)
        vm.selectAgent(agents[0].agent.id)
        #expect(vm.threadIsOnScreen)

        vm.showSettings = true
        #expect(!vm.threadIsOnScreen)
        vm.showSettings = false

        vm.openDestination(.automations)
        #expect(!vm.threadIsOnScreen)
        #expect(vm.selectedAgentID == agents[0].agent.id, "the selection stays; only the watch ends")
    }

    @Test func deletingTheSelectedAgentAsksFirst() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, agents) = fleet(app)
        let vm = try await app.start(with: state)
        vm.selectAgent(agents[1].agent.id)

        vm.deleteSelectedAgent()
        #expect(vm.agentDeleteTarget == agents[1].agent.id)
        #expect(vm.worktreeDeleteTarget == nil)
        #expect(vm.state.agents.count == 2, "nothing goes before the dialog is confirmed")

        // Confirmed: the deletion waits for the sheet's dismissal, then runs.
        vm.afterDialogDismiss = { vm.deleteAgent(agents[1].agent.id) }
        vm.agentDeleteTarget = nil
        vm.runAfterDialogDismiss()
        #expect(vm.afterDialogDismiss == nil)
        try await eventuallyOnMain("the agent to be deleted") { vm.state.agents.map(\.id) == [agents[0].agent.id] }
    }

    /// Every row-menu command is in the Agent menu's snapshot and in ⌘K's This thread section.
    @Test func theAgentMenuAndPaletteOfferTheRowMenusCommands() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let plain = Fixture.agent("plain", in: space, order: 0)
        var worktree = Fixture.agent("tree", in: space, order: 1)
        worktree.agent.worktreeBranch = "feat/x"
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [plain, worktree]))

        vm.selectAgent(plain.agent.id)
        var menu = MenuState.Snapshot(vm)
        #expect(menu.selectedLocalAgent == plain.agent.id)
        #expect(menu.threadCommands == [.fork, .copyTranscript, .reviewChanges, .openInFinder, .delete])
        #expect(menu.canCloseTerminal == false, "the thread's own pane is not a terminal")
        #expect(menu.saveTitle == nil, "no Save item outside Settings")
        let ids = Set(vm.paletteItems.map(\.id))
        for command in ThreadCommand.commands(for: plain.agent) where command != .reviewChanges {
            #expect(ids.contains("action.thread.\(command.rawValue)"), "\(command) in ⌘K")
        }
        #expect(!ids.contains("action.thread.finalizeWorktree"))
        #expect(ids.contains("action.stop") == (vm.visibleThread != nil))
        #expect(vm.paletteItems.first { $0.id == "action.reviewDiff" }?.shortcut == "⌃1", "Review diff shows the Changes tab's chord")

        vm.selectAgent(worktree.agent.id)
        menu = MenuState.Snapshot(vm)
        #expect(menu.threadCommands.contains(.finalizeWorktree))
        #expect(!vm.paletteItems.contains { $0.id.hasPrefix("action.move.") }, "a worktree thread does not move")

        let delete = try #require(vm.paletteItems.first { $0.id == "action.thread.delete" })
        vm.runPaletteItem(delete)
        #expect(vm.worktreeDeleteTarget == worktree.agent.id, "⌘K's delete confirms like the menu's")
        #expect(vm.state.agents.count == 2)
    }

    /// A person's own edit that the server refuses says so instead of snapping back in silence.
    @Test func aRefusedRenameReportsItsFailure() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (state, _) = fleet(app)
        let vm = try await app.start(with: state)
        // An agent the server never had: its rename is refused and the optimistic edit reconciles away.
        let ghost = Fixture.agent("ghost", in: state.spaces[0], order: 9)
        vm.state.agents.append(ghost.agent)
        vm.renameAgent(ghost.agent.id, to: "named")
        await app.settle()
        #expect(vm.actionError?.title == "Couldn’t rename the agent")
        #expect(vm.actionError?.message.contains("rawValue") == false)
        #expect(!vm.state.agents.contains { $0.id == ghost.agent.id }, "the server's snapshot wins")
    }

    /// A restored agent's remembered failure shows in its row until this run reports a status.
    @Test func aPersistedFailureSeedsTheRowUntilALiveReport() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        var (state, agents) = fleet(app)
        state.agents[0].lastFailure = "529 overloaded"
        let vm = try await app.start(with: state)
        let failed = agents[0].agent.id, clean = agents[1].agent.id
        #expect(vm.failedTurns == [failed])
        var row = try #require(vm.sidebarLists.all.first { $0.id == .local(failed) })
        #expect(row.leading == .dot(.failed) && row.section == .done && row.accessibilityLabel.contains("failed"))
        #expect(vm.sidebarLists.all.first { $0.id == .local(clean) }?.leading == .dot(.idle))

        // A turn starting is the live report that replaces it.
        let status = try ExtensionClient(path: app.scratch.socketPath)
        defer { status.closeConnection() }
        try status.send(.setAgentStatus(agentID: failed, status: .working))
        try await eventuallyOnMain("the live report to clear the remembered failure") { vm.failedTurns.isEmpty }
        try await eventuallyOnMain("the server to forget it") { vm.state.agents[0].lastFailure == nil }
        row = try #require(vm.sidebarLists.all.first { $0.id == .local(failed) })
        #expect(row.leading == .dot(.running))
    }
}

private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
