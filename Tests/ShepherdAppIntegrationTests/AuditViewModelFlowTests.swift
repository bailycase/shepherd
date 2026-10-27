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
}

private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
