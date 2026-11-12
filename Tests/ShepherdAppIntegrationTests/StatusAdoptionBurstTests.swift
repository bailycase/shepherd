import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A fleet's status reports reach the app as a stream of whole-workspace pushes with other events between
/// them. Held behind a busy main thread (a long frame), the stream is adopted once: each push but the last
/// is skipped because a newer one is already queued, while every status change still runs its effects.
@Suite("Status adoption burst", .mainActorExclusive)
@MainActor
struct StatusAdoptionBurstTests {
    private struct Fleet {
        let app: AppHarness
        let vm: ShepherdViewModel
        let ids: [AgentID]
        let host: RemoteHostStore.Connection
    }

    private func fleet(_ count: Int, _ app: AppHarness) async throws -> Fleet {
        let space = Fixture.space("acme-web", path: app.dir.appendingPathComponent("acme-web").path)
        let agents = (0..<count).map { Fixture.agent("agent-\($0)", in: space, order: $0) }
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: agents))
        let host = try #require(vm.localHost)
        return Fleet(app: app, vm: vm, ids: agents.map(\.agent.id), host: host)
    }

    /// Sends `reports` in order while the main thread is busy: each is seen to reach the app's queue, and a thread
    /// notice follows it, so the host's pushes alternate between whole workspaces and other events and none
    /// replaces another in the queue.
    private func report(_ reports: [(AgentID, AgentStatus)], to fleet: Fleet) throws {
        let reporter = try ExtensionClient(path: fleet.app.scratch.socketPath)
        let queued = fleet.host.queuedStateEvents
        for (index, (id, status)) in reports.enumerated() {
            try reporter.send(.setAgentStatus(agentID: id, status: status))
            try holdingMain(until: "report \(index + 1) of \(reports.count) to reach the app") {
                fleet.host.queuedStateEvents >= queued + index + 1
            }
            fleet.app.server.noticeToLocalApps(agentID: id, message: "acme notice")
        }
    }

    /// Lets the held main thread go and waits until the app has taken everything the host pushed.
    private func drained(_ fleet: Fleet) async throws {
        let server = fleet.app.server, vm = fleet.vm, host = fleet.host
        try await eventuallyOnMain("the app to take the host's workspace") {
            host.queuedStateEvents == 0 && vm.state == server.state
        }
    }

    @Test func aBurstOfStatusReportsAdoptsOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(32, app)
        let vm = fleet.vm
        let (adopted, skipped, edges) = (vm.changedAdoptions, vm.skippedAdoptions, vm.statusEdges)

        try report(fleet.ids.map { ($0, .working) }, to: fleet)
        #expect(fleet.host.queuedStateEvents == 32, "every report is queued behind the busy main thread")
        try await drained(fleet)

        #expect(vm.changedAdoptions == adopted + 1)
        #expect(vm.skippedAdoptions == skipped + 31)
        #expect(vm.statusEdges == edges + 32, "every report still ran its effects")
        #expect(vm.state.agents.filter { $0.status == .working }.count == 32)
        #expect(fleet.ids.allSatisfy { vm.statusSince[$0] != nil })
    }

    @Test func aBurstEndsInTheServersStateWithEveryEdgeApplied() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(8, app)
        let vm = fleet.vm
        let (adopted, skipped, edges) = (vm.changedAdoptions, vm.skippedAdoptions, vm.statusEdges)

        // Working, done, then working again: each agent's turn ended and began another inside one drain.
        let rounds: [AgentStatus] = [.working, .done, .working]
        let lives = fleet.ids.map { vm.agentLive($0) }
        try report(rounds.flatMap { status in fleet.ids.map { ($0, status) } }, to: fleet)
        try await drained(fleet)

        #expect(vm.changedAdoptions == adopted + 1)
        #expect(vm.skippedAdoptions == skipped + 23)
        #expect(vm.statusEdges == edges + 24, "the end of each turn and the start of the next were both seen")
        #expect(vm.state.agents.map(\.status) == Array(repeating: .working, count: 8))
        #expect(lives.map(\.status) == Array(repeating: .working, count: 8), "each agent's box follows its newest status")
        #expect(fleet.ids.allSatisfy { vm.statusSince[$0] != nil })
        #expect(vm.failedTurns.isEmpty)
    }

    @Test func aRepeatedReportChangesNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(2, app)
        let vm = fleet.vm
        let reporter = try ExtensionClient(path: app.scratch.socketPath)
        try reporter.send(.setAgentStatus(agentID: fleet.ids[0], status: .working))
        try await eventuallyOnMain("the first report to be adopted") { vm.state.agents[0].status == .working }
        let (adopted, skipped, edges) = (vm.changedAdoptions, vm.skippedAdoptions, vm.statusEdges)

        // The repeat pushes nothing; the other agent's report after it is the next push the app sees.
        try reporter.send(.setAgentStatus(agentID: fleet.ids[0], status: .working))
        try reporter.send(.setAgentStatus(agentID: fleet.ids[1], status: .working))
        try await eventuallyOnMain("the second agent's report to be adopted") { vm.state.agents[1].status == .working }

        #expect(vm.changedAdoptions == adopted + 1)
        #expect(vm.skippedAdoptions == skipped)
        #expect(vm.statusEdges == edges + 1)
    }
}
