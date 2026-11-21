import Darwin
import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite(.integrationTimeLimit, .enabled(if: EngineSmoke.engine != nil, "needs the staged pi engine"))
struct ChildProcessLifecycleTests {
    @Test func closingAThreadStopsItsSubagentsEscapedBashJob() async throws {
        let pi = try await RealPi.launch(engine: #require(EngineSmoke.engine), nativeChildren: true)
        defer { pi.stop() }
        let project = pi.host.dir.appendingPathComponent("project")
        defer { try? Data().write(to: project.appendingPathComponent("wren.release")) }
        _ = try await pi.send("launch orphan job wren", from: try await pi.ready())

        let receipt = project.appendingPathComponent("wren.pid")
        func adopted() -> pid_t? {
            guard let text = try? String(contentsOf: receipt, encoding: .utf8),
                  let pid = pid_t(text), pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_ppid == 1 ? pid : nil
        }
        try await eventually("the subagent's detached job to be adopted by launchd") { adopted() != nil }
        let pid = try #require(adopted())
        let token = try #require(ThreadProcessSweep.token(pid))
        #expect(getsid(pid) == pid)
        try await pi.host.server.deleteAgent(pi.agent.agent.id)
        #expect(ThreadProcessSweep.token(pid)?.val.7 != token.val.7, "the escaped child job is still alive after close")
    }
}
