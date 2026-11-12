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

    /// The runs of the view model's host projection, counted beside the work.
    @MainActor private final class Projections {
        var runs = 0
    }

    private func countProjections(of fleet: Fleet) -> Projections {
        let projections = Projections()
        let hosts = fleet.vm.remoteHosts
        let projection = hosts.onProjectionChanged
        hosts.onProjectionChanged = {
            projections.runs += 1
            projection?()
        }
        return projections
    }

    /// Waits until the host connection has read every thread's subagents once (its first poll publishes an
    /// empty list for each, and each of those runs the projection), so none comes during a burst.
    private func pollsSettled(_ fleet: Fleet) async throws {
        try await eventuallyOnMain("the host's subagents to be read for every thread") {
            fleet.host.children.count == fleet.ids.count
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

    @Test func aBurstOfStatusReportsRunsTheProjectionOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(32, app)
        let vm = fleet.vm
        try await pollsSettled(fleet)
        let projections = countProjections(of: fleet)

        try report(fleet.ids.map { ($0, .working) }, to: fleet)
        #expect(fleet.host.queuedStateEvents == 32, "every report is queued behind the busy main thread")
        try await drained(fleet)

        #expect(projections.runs == 1, "the push that was adopted ran it for all 32")
        #expect(fleet.host.state == app.server.state, "the connection ends on the host's last state")
        #expect(vm.state == app.server.state)
        #expect(vm.state.agents.filter { $0.status == .working }.count == 32)
    }

    @Test func aLongBurstRunsTheProjectionWithEveryAdoption() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let count = StateAdoption.maxSkips + 8
        let fleet = try await fleet(count, app)
        let vm = fleet.vm
        try await pollsSettled(fleet)
        let projections = countProjections(of: fleet)
        let adopted = vm.changedAdoptions

        try report(fleet.ids.map { ($0, .working) }, to: fleet)
        try await drained(fleet)

        // 32 are skipped, the 33rd is adopted though a newer one waits, and the last of the burst is too.
        #expect(vm.changedAdoptions == adopted + 2)
        #expect(projections.runs == 2, "a push is projected exactly when it is adopted")
        #expect(fleet.host.state == app.server.state)
    }

    /// The order the app's readers of the connection's state rely on (`pruneSidebarPins`, `deleteAgentPersisted`'s
    /// and `reconcileFromServer`'s adoption of `localHost.state`): the connection holds each push before the app
    /// receives it, skipped or not, so it is never older than the newest push the app knows; and an adopted push is
    /// projected before the app adopts it, as it always was.
    @Test func theConnectionHoldsEachPushBeforeTheAppReceivesIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(8, app)
        let (vm, host) = (fleet.vm, fleet.host)
        try await pollsSettled(fleet)
        let projections = countProjections(of: fleet)
        let projected = projections.runs

        struct Receipt { var held: Bool; var projections: Int; var newerQueued: Bool; var newest: Bool }
        var receipts: [Receipt] = []
        let received = try #require(vm.remoteHosts.onLocalHostState)
        vm.remoteHosts.onLocalHostState = { state, newerQueued in
            let held = host.state == state, before = projections.runs
            received(state, newerQueued)
            receipts.append(Receipt(held: held, projections: before - projected, newerQueued: newerQueued, newest: vm.latestState == state))
        }

        try report(fleet.ids.map { ($0, .working) }, to: fleet)
        try await drained(fleet)

        #expect(receipts.count == 8)
        #expect(receipts.allSatisfy { $0.held }, "the connection holds the push when the app receives it")
        #expect(receipts.allSatisfy { $0.newest }, "so the newest push the app knows is the connection's")
        #expect(receipts.dropLast().allSatisfy { $0.newerQueued })
        #expect(receipts.dropLast().map(\.projections) == Array(repeating: 0, count: 7), "a skipped push is not projected")
        #expect(receipts.last?.projections == 1, "the adopted push was projected before the app received it")
    }

    /// `deleteAgentPersisted` and `reconcileFromServer` adopt the connection's state. In the middle of a burst that
    /// is the newest push, which the app already knows: no older state comes back and no status change runs twice
    /// or backwards.
    @Test func adoptingTheConnectionsStateInTheMiddleOfABurstChangesNothing() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(8, app)
        let (vm, host) = (fleet.vm, fleet.host)
        let edges = vm.statusEdges

        var adoptedMidBurst: (state: ShepherdState, edges: Int)?
        let received = try #require(vm.remoteHosts.onLocalHostState)
        var pushes = 0
        vm.remoteHosts.onLocalHostState = { state, newerQueued in
            received(state, newerQueued)
            pushes += 1
            guard pushes == 4 else { return }
            vm.adopt(host.state)
            adoptedMidBurst = (vm.state, vm.statusEdges)
        }

        try report(fleet.ids.map { ($0, .working) }, to: fleet)
        try await drained(fleet)

        let midBurst = try #require(adoptedMidBurst)
        #expect(midBurst.state.agents.filter { $0.status == .working }.count == 4, "the state the fourth push carried, not an older one")
        #expect(midBurst.edges == edges + 4, "nothing ran twice or backwards")
        #expect(vm.statusEdges == edges + 8)
        #expect(vm.state == app.server.state)
    }

    @Test func aStatusChangeInASkippedPushStillRunsItsEffects() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let fleet = try await fleet(3, app)
        let vm = fleet.vm
        try await pollsSettled(fleet)
        let projections = countProjections(of: fleet)
        let edges = vm.statusEdges
        let (first, second, third) = (fleet.ids[0], fleet.ids[1], fleet.ids[2])

        // The first agent's turn ends in the second push; the third push is the one that is adopted.
        try report([(first, .working), (first, .done), (second, .working), (third, .working)], to: fleet)
        try await drained(fleet)

        #expect(projections.runs == 1)
        #expect(vm.statusEdges == edges + 4, "each report ran its effects, those in skipped pushes included")
        #expect(vm.agentLive(first).status == .done)
        #expect(vm.statusSince[first] != nil)
        #expect(vm.sidebarCompletions.records[.local(first)]?.finished == true, "the finished turn is a completion")
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
