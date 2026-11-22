import Foundation
import Testing
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Host socket startup", .integrationTimeLimit)
struct HostSocketStartupTests {
    @Test func theLocalSocketRecoversAfterAnInitialBindFailure() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.retryBind() }
        }
    }

    private static func retryBind() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        ShepherdLog.persistHostLog(in: h.dir)
        let log = h.dir.appendingPathComponent("host.log")
        let parent = h.dir.appendingPathComponent("not-ready")
        let socket = parent.appendingPathComponent("host.sock").path
        let serving = Task { await SessionHost.serve(h.server, socket: socket, recovering: false, respawn: SessionHostTests.defaults) }
        defer { serving.cancel() }
        try await eventually("the first local bind to fail") {
            (try? String(contentsOf: log, encoding: .utf8))?.contains("host has no local socket:") == true
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try await eventually("the local socket to accept connections after a retry", timeout: .seconds(5)) {
            RemoteHostClient.localSocketAnswers(socket)
        }
    }
}
