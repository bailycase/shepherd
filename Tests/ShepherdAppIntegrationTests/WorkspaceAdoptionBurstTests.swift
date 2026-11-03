import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A burst of changed workspace snapshots (a fleet's status reports): every one is adopted in
/// order, and the membership prunes run only when agents, tabs, spaces or designs change.
@Suite("Workspace adoption burst", .mainActorExclusive)
@MainActor
struct WorkspaceAdoptionBurstTests {
    @Test func statusBurstsAdoptEverySnapshotButPruneOnlyOnMembershipChange() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space("one", path: app.dir.appendingPathComponent("one").path)
        let agents = (0..<50).map { Fixture.agent("agent-\($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let adoptions = vm.changedAdoptions, prunes = vm.membershipPrunes
        var seen: [AgentStatus] = []
        for round in 0..<20 {
            var next = vm.state
            let status: AgentStatus = round.isMultiple(of: 2) ? .working : .done
            next.agents[round % 50].status = status
            vm.adopt(next)
            // Each transition is visible as it lands, never merged away.
            seen.append(vm.state.agents[round % 50].status)
        }
        #expect(vm.changedAdoptions == adoptions + 20)
        #expect(seen == (0..<20).map { $0.isMultiple(of: 2) ? .working : .done })
        #expect(vm.membershipPrunes == prunes, "status-only snapshots prune nothing")

        vm.pinThread(.local(agents[3].agent.id))
        var removed = vm.state
        removed.agents.removeAll { $0.id == agents[3].agent.id }
        removed.tabs.removeAll { $0.id == agents[3].tab.id }
        vm.adopt(removed)
        #expect(vm.membershipPrunes == prunes + 1)
        #expect(!vm.isPinned(.local(agents[3].agent.id)), "a deletion still prunes at once")
        #expect(vm.state == removed)
    }
}
