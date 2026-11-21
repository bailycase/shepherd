import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite(.integrationTimeLimit, .enabled(if: EngineSmoke.engine != nil, "needs the staged pi engine"))
struct ChildProcessLifecycleTests {
    @Test(arguments: [false, true])
    func closingAThreadStopsItsSubagentsEscapedBashJob(fleetClose: Bool) async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine, nativeChildren: true)
        defer { pi.stop() }
        let other = try await RealPi.launch(engine: engine, nativeChildren: true)
        defer { other.stop() }

        let rootDecoy = try await job("finch", in: other, prompt: "orphan job finch finish")
        let childDecoy = try await job("linnet", in: other, prompt: "launch orphan job linnet")
        let escaped = try await job("wren", in: pi, prompt: "launch orphan job wren")

        if fleetClose {
            let server = pi.host.server
            server.configureFleet(name: "Juniper", advertises: false)
            server.startFleet()
            let close = try await server.enqueue { try #require(server.fleet?.dispatch.host.closeThread) }
            _ = try await pi.snapshot("the parent turn to settle") { !$0.running }
            let dispatchID = UUID()
            var agent = try #require(server.state.agents.first { $0.id == pi.agent.agent.id })
            agent.dispatchedFrom = DispatchedFrom(hostID: UUID(), hostName: "Alder", agentTitle: "Fixture", dispatchID: dispatchID, at: 1)
            try await server.updateAgent(agent)
            let receipt = try await close(agent.id, dispatchID)
            #expect(receipt.sessionsStopped)
            #expect(receipt.sweep?.exited == 1, "the receipt counts the subagent's escaped job")
            #expect(receipt.sweep?.unconfirmed == 0)
        } else {
            try await pi.host.server.deleteAgent(pi.agent.agent.id)
        }
        #expect(!escaped.isAlive, "the escaped child job is still alive after close")
        #expect(rootDecoy.isAlive && childDecoy.isAlive)
    }

    @Test func childCancelAndFinishSweepOnlyTheirAttemptAndParentStopLeavesOtherJobs() async throws {
        let pi = try await RealPi.launch(engine: #require(EngineSmoke.engine), nativeChildren: true)
        defer { pi.stop() }
        let parentJob = try await job("finch", in: pi, prompt: "orphan job finch finish")
        let sibling = try await job("linnet", in: pi, prompt: "launch orphan job linnet")
        let cancelled = try await job("wren", in: pi, prompt: "launch orphan job wren")
        let active = try await pi.snapshot("the child to appear") { $0.subagents?.contains { $0.name == "wren" } == true }
        let run = try #require(active.subagents?.first { $0.name == "wren" })
        let op = UUID()
        #expect(try await pi.request(.subagentCommand(expectedSessionID: active.piSessionID, generation: active.generation,
            operationID: op, runID: run.runID, action: .cancel)) == .accepted(operationID: op))
        try await eventually("the cancelled child's job to exit", timeout: .seconds(8)) { !cancelled.isAlive }
        #expect(parentJob.isAlive && sibling.isAlive)

        // A fast child may finish before the test picks up its PID receipt. Hold its provider
        // response until the test has observed the job, then let the child settle normally.
        let finished = try await job("robin", in: pi, prompt: "launch orphan job robin gated")
        try Data().write(to: pi.host.dir.appendingPathComponent("project/robin.finish"))
        _ = try await pi.snapshot("the second child to finish") { $0.subagents?.contains { $0.name == "robin" && $0.state == "complete" } == true }
        try await eventually("the finished child's job to exit", timeout: .seconds(8)) { !finished.isAlive }
        #expect(parentJob.isAlive && sibling.isAlive)

        _ = try await pi.send("slow", from: try await pi.ready())
        let busy = try await pi.snapshot("a turn in progress") { $0.running }
        #expect(try await pi.request(.abort(expectedSessionID: busy.piSessionID, generation: busy.generation, operationID: UUID())).failureCode == nil)
        _ = try await pi.snapshot("the parent Stop to settle") { !$0.running }
        #expect(parentJob.isAlive && sibling.isAlive)
        try await pi.host.server.deleteAgent(pi.agent.agent.id)
        #expect(!parentJob.isAlive && !sibling.isAlive)
    }

    @Test func sweepSignalRejectsAStalePIDVersion() async throws {
        let pi = try await RealPi.launch(engine: #require(EngineSmoke.engine), nativeChildren: true)
        defer { pi.stop() }
        let decoy = try await job("wren", in: pi, prompt: "orphan job wren finish")
        // Stand in for the old identity after PID reuse. The PID is still the test's own job.
        var stale = decoy.identity
        stale.val.7 &-= 1
        #expect(ThreadProcessSweep.signal(SIGTERM, to: stale) != 0)
        #expect(decoy.isAlive)
        try await pi.host.server.deleteAgent(pi.agent.agent.id)
        #expect(!decoy.isAlive)
    }

    private struct Job {
        let pid: pid_t
        let identity: audit_token_t
        var isAlive: Bool { ThreadProcessSweep.token(pid)?.val.7 == identity.val.7 }
    }

    private func job(_ name: String, in pi: RealPi, prompt: String) async throws -> Job {
        let receipt = pi.host.dir.appendingPathComponent("project/\(name).pid")
        let op = UUID()
        #expect(try await pi.send(prompt, operationID: op, from: try await pi.ready()) == .accepted(operationID: op))
        func adopted() -> pid_t? {
            guard let text = try? String(contentsOf: receipt, encoding: .utf8),
                  let pid = pid_t(text), pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_ppid == 1 ? pid : nil
        }
        try await eventually("\(name)'s detached job to be adopted by launchd") { adopted() != nil }
        let pid = try #require(adopted())
        #expect(getsid(pid) == pid)
        return Job(pid: pid, identity: try #require(ThreadProcessSweep.token(pid)))
    }
}
