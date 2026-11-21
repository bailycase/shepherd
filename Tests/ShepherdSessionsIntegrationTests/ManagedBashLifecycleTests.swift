import Darwin
import Foundation
import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport
import Testing

@Suite(.enabled(if: TestNode.url != nil, "needs node 22.6 or later"))
struct ManagedBashLifecycleTests {
    @Test func normalReturnKeepsAnIntentionalBackgroundJob() async throws {
        let dir = try makeScratchDirectory("bash-lifecycle")
        defer { try? FileManager.default.removeItem(at: dir) }
        try EmbeddedExtensions.install("shepherd-bash.mjs", at: dir.appendingPathComponent("shepherd-bash.mjs"))
        let script = dir.appendingPathComponent("run.mjs")
        try """
        import { writeFileSync } from 'node:fs';
        import { managedBash } from './shepherd-bash.mjs';
        const bash = managedBash(() => writeFileSync('unexpected-sweep', ''));
        let pid = '';
        const reply = await bash.exec('/bin/sleep 20 </dev/null >/dev/null 2>&1 & echo $!', process.cwd(),
          { onData: (chunk) => { pid += chunk; } });
        if (reply.exitCode !== 0) process.exit(1);
        writeFileSync('returned', pid.trim());
        process.stdin.on('end', () => bash.stopAll()).resume();
        """.write(to: script, atomically: true, encoding: .utf8)
        let node = Process(), input = Pipe()
        node.executableURL = try #require(TestNode.url)
        node.arguments = [script.path]
        node.currentDirectoryURL = dir
        node.environment = ["SHEPHERD_OWNED_THREAD": UUID().uuidString]
        node.standardInput = input
        try node.run()
        defer { if node.isRunning { node.terminate() } }
        let receipt = dir.appendingPathComponent("returned")
        try await eventually("Bash to return") { FileManager.default.fileExists(atPath: receipt.path) }
        let pid = try #require(pid_t(String(contentsOf: receipt, encoding: .utf8)))
        try #require(pid > 1)
        #expect(kill(pid, 0) == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("unexpected-sweep").path))
        try input.fileHandleForWriting.close()
        try await eventually("the explicit stop to terminate the background job") { kill(pid, 0) != 0 }
    }
}
