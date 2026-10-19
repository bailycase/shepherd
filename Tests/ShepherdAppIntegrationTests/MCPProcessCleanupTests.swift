import Foundation
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("MCP probe process cleanup", .integrationTimeLimit)
struct MCPProcessCleanupTests {
    @Test(arguments: [false, true])
    func cancellationAndTimeoutCleanDetachedServers(cancel: Bool) async throws {
        let dir = try makeScratchDirectory("mcp-stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = PiEngine(command: ["/usr/bin/false"], packageDirectory: nil, version: nil, node: .executable("/usr/bin/false"))
        let home = PiHome(directory: dir, engine: engine, userHome: dir.path)
        try FileManager.default.createDirectory(at: home.launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/usr/bin/python3
        import os,pathlib,signal,subprocess,sys,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        child = 'import os,pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path("child.pid").write_text(str(os.getpid())); time.sleep(60)'
        subprocess.Popen([sys.executable,'-c',child],start_new_session=True,stdin=subprocess.DEVNULL)
        pathlib.Path('root.pid').write_text(str(os.getpid()))
        time.sleep(60)
        """
        try script.write(to: home.launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.launcher.path)
        let runner = PiMCPCLI(home: home)
        let task = Task { await runner.run(["list", "--json"], environment: ["HOME": dir.path], timeout: cancel ? 60 : 5, onLine: nil) }
        defer { task.cancel() }
        let childFile = dir.appendingPathComponent("child.pid")
        let rootFile = dir.appendingPathComponent("root.pid")
        try await eventually("scratch MCP probe and detached server ready") {
            (try? String(contentsOf: childFile, encoding: .utf8)).flatMap(Int32.init) != nil &&
                (try? String(contentsOf: rootFile, encoding: .utf8)).flatMap(Int32.init) != nil
        }
        let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
        let root = try #require(Int32(String(contentsOf: rootFile, encoding: .utf8)))
        defer { _ = kill(child, SIGKILL); _ = kill(root, SIGKILL) }
        if cancel { task.cancel() }
        let result = await task.value
        #expect(result.timedOut == !cancel)
        try await eventually("probe and detached server to exit") { kill(root, 0) != 0 && kill(child, 0) != 0 }
    }
}
