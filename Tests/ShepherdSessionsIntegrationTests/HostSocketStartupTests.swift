import Darwin
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

    @Test func startupContinuesWhileTheLocalSocketRetries() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.retryBind() }
        }
    }

    private static func retryBind() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        ShepherdLog.persistHostLog(in: h.dir)
        await blocking { h.server.configureFleet(name: "acme-mac", advertises: false) }
        let parent = h.dir.appendingPathComponent("not-ready")
        let socket = parent.appendingPathComponent("host.sock").path
        let started = Locked(false)
        let serving = Task {
            await SessionHost.serve(h.server, socket: socket, respawn: SessionHostTests.defaults, banners: { _ in
                started.withValue { $0 = true }
                return ThreadBanners.Sink(post: { _ in }, remove: { _ in }, isWatching: { _ in false }, notifyOnTurnFinished: { false })
            }, startFleet: true)
        }
        defer { serving.cancel() }
        try await eventually("two transient bind failures", timeout: .seconds(5)) { failureLines(in: h.dir).count >= 2 }
        try await eventually("banners and Fleet to start before the socket is available", timeout: .seconds(5)) {
            guard started.current else { return false }
            return await h.server.queue.testHop { h.server.fleet != nil }
        }
        #expect(!RemoteHostClient.localSocketAnswers(socket))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let connection = Locked<ExtensionClient?>(nil)
        try await eventually("the first client to connect after a retry", timeout: .seconds(5)) {
            guard let wire = try? ExtensionClient(path: socket) else { return false }
            connection.withValue { $0 = wire }
            return true
        }
        let reply = try await blocking {
            let wire = try #require(connection.current)
            try wire.sendRaw(NDJSON.encode(RemoteRequest.hello(id: 1, token: "", clientName: "test", protocolVersion: RemoteProtocol.version)))
            return try NDJSON.decode(RemoteReply.self, from: wire.readLine(timeout: .seconds(5)))
        }
        guard case .helloOk(1, _, let capabilities, _, let hostID) = reply else {
            Issue.record("expected helloOk, got \(reply)")
            return
        }
        #expect(capabilities.contains(RemoteProtocol.fleetViewCapability))
        #expect(hostID != nil)
    }

    @Test func shutdownCancelsTheLocalBindRetry() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.stopWhileRetrying() }
        }
    }

    private static func stopWhileRetrying() async throws {
        let dir = try makeScratchDirectory("retry")
        defer { try? FileManager.default.removeItem(at: dir) }
        ShepherdLog.persistHostLog(in: dir)
        weak var stoppedServer = try await stopAfterFirstFailure(in: dir)
        try await eventually("the stopped server to be released by the retry", timeout: .seconds(5)) { stoppedServer == nil }
        #expect(!failureLines(in: dir).contains { $0.contains("session server is not started") })
    }

    private static func stopAfterFirstFailure(in dir: URL) async throws -> SessionServer {
        let h = try ScratchServer(dir: dir)
        defer { h.stop(keepFiles: true) }
        let socket = dir.appendingPathComponent("not-ready/host.sock").path
        // Do not cancel serve: stopping the host must end the retry on its own.
        Task { await SessionHost.serve(h.server, socket: socket, recovering: false, respawn: SessionHostTests.defaults) }
        try await eventually("the local bind to fail", timeout: .seconds(5)) { !failureLines(in: dir).isEmpty }
        return h.server
    }

    @Test func addressInUseLogsOnceAndAnAlreadyRunningListenerDoesNotLog() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.occupiedSocket() }
        }
    }

    private static func occupiedSocket() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        ShepherdLog.persistHostLog(in: h.dir)
        await blocking { h.server.configureFleet(name: "acme-mac", advertises: false) }
        // unlink cannot remove a directory; on Darwin bind then returns EADDRINUSE.
        let socket = h.dir.appendingPathComponent("host.sock")
        try FileManager.default.createDirectory(at: socket, withIntermediateDirectories: false)
        let finished = Locked(false)
        let serving = Task {
            await SessionHost.serve(h.server, socket: socket.path, respawn: SessionHostTests.defaults, startFleet: true)
            finished.withValue { $0 = true }
        }
        defer { serving.cancel() }
        try await eventually("startup to finish despite EADDRINUSE", timeout: .seconds(5)) { finished.current }
        #expect(await h.server.queue.testHop { h.server.fleet != nil })
        let failures = failureLines(in: h.dir)
        try #require(failures.count == 1)
        let refusal = failures[0]
        #expect(refusal.contains(String(cString: strerror(EADDRINUSE))))
        #expect(!refusal.contains("retrying"))
        #expect(!RemoteHostClient.localSocketAnswers(socket.path))

        try FileManager.default.removeItem(at: socket)
        try await blocking { try h.server.startLocalListener(path: socket.path) }
        await SessionHost.serve(h.server, socket: socket.path, recovering: false, respawn: SessionHostTests.defaults, startFleet: true)
        #expect(failureLines(in: h.dir) == [refusal], "An already-running listener is not a bind failure")
        #expect(RemoteHostClient.localSocketAnswers(socket.path))
    }

    private static func failureLines(in dir: URL) -> [String] {
        let log = try? String(contentsOf: dir.appendingPathComponent("host.log"), encoding: .utf8)
        return log?.split(separator: "\n").filter { $0.contains("host has no local socket:") }.map(String.init) ?? []
    }
}
