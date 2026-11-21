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

    @Test func closingOneThreadOnAHostLeavesTheOtherThreadsChildJobAlive() async throws {
        let engine = try #require(EngineSmoke.engine)
        let pi = try await RealPi.launch(engine: engine, nativeChildren: true)
        defer { pi.stop() }
        let other = try await RealPi.launch(engine: engine, nativeChildren: true, on: pi.host)
        defer { other.stop() }

        let escaped = try await job("wren", in: pi, prompt: "launch orphan job wren")
        let decoy = try await job("wren", in: other, prompt: "launch orphan job wren")
        try await pi.host.server.deleteAgent(pi.agent.agent.id)
        #expect(!escaped.isAlive && decoy.isAlive)
        try await other.host.server.deleteAgent(other.agent.agent.id)
        #expect(!decoy.isAlive)
    }

    @Test func childCancelSweepsOnlyItsAttemptAndParentStopLeavesOtherJobs() async throws {
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

        _ = try await pi.send("slow", from: try await pi.ready())
        let busy = try await pi.snapshot("a turn in progress") { $0.running }
        #expect(try await pi.request(.abort(expectedSessionID: busy.piSessionID, generation: busy.generation, operationID: UUID())).failureCode == nil)
        _ = try await pi.snapshot("the parent Stop to settle") { !$0.running }
        #expect(parentJob.isAlive && sibling.isAlive)
        try await pi.host.server.deleteAgent(pi.agent.agent.id)
        #expect(!parentJob.isAlive && !sibling.isAlive)
    }

    @Test(arguments: [false, true])
    func childExitLeavesItsEscapedJobAliveUntilThreadClose(failure: Bool) async throws {
        let pi = try await RealPi.launch(engine: #require(EngineSmoke.engine), nativeChildren: true)
        defer { pi.stop() }
        let escaped = try await job("robin", in: pi, prompt: "launch orphan job robin \(failure ? "failure" : "gated")")
        try Data().write(to: pi.project.appendingPathComponent("robin.finish"))
        let state = failure ? "failed" : "complete"
        _ = try await pi.snapshot("the child to report \(state)") { $0.subagents?.contains { $0.name == "robin" && $0.state == state } == true }
        try await survivesSweepWindow(escaped, "exiting with state \(state)")
        try await pi.host.server.deleteAgent(pi.agent.agent.id)
        #expect(!escaped.isAlive)
    }

    @Test func childQuestionAndResumeLeaveItsEscapedJobAlive() async throws {
        let pi = try await RealPi.launch(engine: #require(EngineSmoke.engine), nativeChildren: true)
        defer { pi.stop() }
        let escaped = try await job("robin", in: pi, prompt: "launch orphan job robin question")
        try Data().write(to: pi.project.appendingPathComponent("robin.finish"))
        let waiting = try await pi.settled("the child to exit and wait for its answer") {
            $0.subagents?.contains { $0.name == "robin" && $0.state == "complete" && $0.question != nil } == true
        }
        let child = try #require(waiting.subagents?.first { $0.name == "robin" })
        try await survivesSweepWindow(escaped, "waiting for an answer")

        let op = UUID()
        #expect(try await pi.request(.subagentCommand(expectedSessionID: waiting.piSessionID, generation: waiting.generation,
            operationID: op, runID: child.runID, action: .resume, text: "Use alpha")) == .accepted(operationID: op))
        _ = try await pi.snapshot("the resumed child to finish") {
            $0.subagents?.contains { $0.runID == child.runID && $0.attempt != child.attempt && $0.state == "complete" && $0.question == nil } == true
        }
        try await survivesSweepWindow(escaped, "finishing the resumed attempt")
    }

    @Test func parentStopSweepsOnlyTheWorkflowChildItAborts() async throws {
        let pi = try await RealPi.launch(engine: #require(EngineSmoke.engine), nativeChildren: true)
        defer { pi.stop() }
        let background = try await job("linnet", in: pi, prompt: "launch orphan job linnet")
        _ = try await pi.settled("the background launch to return") { $0.subagents?.contains { $0.name == "linnet" } == true }
        let workflow = try await job("wren", in: pi, prompt: "workflow orphan job wren")
        let busy = try await pi.snapshot("the parent to wait on its workflow") { $0.running && $0.subagents?.contains { $0.name == "wren" } == true }
        #expect(try await pi.request(.abort(expectedSessionID: busy.piSessionID, generation: busy.generation, operationID: UUID())).failureCode == nil)
        try await eventually("the aborted workflow child's job to exit", timeout: .seconds(8)) { !workflow.isAlive }
        #expect(background.isAlive)
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

    private func survivesSweepWindow(_ job: Job, _ activity: String) async throws {
        // The host batches for one second before signalling, so checking only at report time misses the regression.
        let deadline = ContinuousClock.now + .seconds(3)
        try await eventually("the job to outlive the sweep window", timeout: .seconds(5)) {
            try #require(job.isAlive, "the escaped job was stopped after \(activity)")
            return ContinuousClock.now >= deadline
        }
    }

    private func job(_ name: String, in pi: RealPi, prompt: String) async throws -> Job {
        let receipt = pi.project.appendingPathComponent("\(name).pid")
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
