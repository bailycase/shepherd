import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Stop all working threads against a real host and three running stub pis: the thread whose turn runs stops through
/// its own Stop, an idle one is never asked, one the workspace still lists as working but that has finished is not
/// counted, and the result says so.
@Suite("Stop all working threads in the app", .mainActorExclusive)
@MainActor
struct StopAllWorkingAppTests {
    @Test func stopsTheWorkingThreadAndLeavesTheIdleOneAlone() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let busyLog = app.dir.appendingPathComponent("busy.log"), idleLog = app.dir.appendingPathComponent("idle.log")
        let busy = try await app.liveAgent("busy", in: space, order: 0, log: busyLog)
        let idle = try await app.liveAgent("idle", in: space, order: 1, log: idleLog)
        var finished = try await app.liveAgent("finished", in: space, order: 2)
        // The workspace lists both as working; only the first has a turn running.
        var working = busy
        working.agent.status = .working
        finished.agent.status = .working
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [working, idle, finished]))
        let snapshot = try await app.readyThread(busy.agent.id)
        _ = try await app.readyThread(idle.agent.id)
        _ = try await app.readyThread(finished.agent.id)

        // "slow" holds the turn open until `continue-1` appears, so the thread is working when Stop all runs.
        _ = try await app.server.nativeThread(agentID: busy.agent.id, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), text: "slow", delivery: .followUp))
        let server = app.server, busyID = busy.agent.id
        try await eventuallyAsync("the busy thread's turn to run") {
            if case .snapshot(let value)? = try? await server.nativeThread(agentID: busyID, request: .snapshot()) { return value.running }
            return false
        }
        #expect(vm.workingThreads.map(\.agent) == [busy.agent.id, finished.agent.id])
        let menu = MenuState()
        menu.apply(MenuState.Snapshot(vm))
        #expect(menu.stopAllTitle == "Stop All Working Threads (2)…" && menu.canStopAll, "the Agent menu's item counts them")

        vm.requestStopAll()
        let asked = try #require(vm.stopAllConfirm)
        #expect(asked.map(\.agent) == [busy.agent.id, finished.agent.id], "the idle thread is not named")
        vm.confirmStopAll(asked)

        try await eventuallyOnMain("the result") { vm.actionError != nil }
        #expect(vm.actionError?.title == "Stopped 1 thread")
        #expect(vm.actionError?.message == "1 thread had already finished.")
        let aborts = { (log: URL) in ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("\"type\":\"abort\"") || $0.contains("\"type\": \"abort\"") }.count }
        #expect(aborts(busyLog) >= 1, "the working thread's pi was told to abort")
        #expect(aborts(idleLog) == 0, "the idle thread's pi was never asked")
    }
}
