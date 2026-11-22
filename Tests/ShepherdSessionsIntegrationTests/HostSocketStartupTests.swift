import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Host socket startup", .integrationTimeLimit)
struct HostSocketStartupTests {
    @Test func aTCPHelloBeforeFleetStartsGetsARetriableRefusal() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        // Open the TCP listener without the fixture that installs a token and starts Fleet.
        let port = try await blocking { try h.server.startRemoteListener(port: 0) }
        let client = try RawRemote(port: port)
        try client.send(.hello(id: 1, token: "acme-device-token", clientName: "test", protocolVersion: RemoteProtocol.version))
        let reply = try await client.next()
        guard case .error(1, let code, _) = reply else {
            Issue.record("expected a Fleet startup refusal, got \(reply)")
            return
        }
        #expect(code == FleetProtocol.Code.off)
        #expect(try await client.disconnected())
    }

    @Test(arguments: ["path too long", "already listening"])
    func aPermanentLocalBindFailureDoesNotHoldFleetStartup(reason: String) async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        await blocking { h.server.configureFleet(name: "acme-mac", advertises: false) }
        let socket = h.dir.appendingPathComponent(reason == "already listening" ? "host.sock" : String(repeating: "x", count: 104)).path
        if reason == "already listening" {
            try await blocking { try h.server.startLocalListener(path: socket) }
        }
        let serving = Task {
            await SessionHost.serve(h.server, socket: socket, recovering: false, respawn: SessionHostTests.defaults, startFleet: true)
        }
        defer { serving.cancel() }
        try await eventually("Fleet to start despite \(reason)", timeout: .seconds(5)) {
            await h.server.queue.testHop { h.server.fleet != nil }
        }
        _ = await serving.value
    }

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
