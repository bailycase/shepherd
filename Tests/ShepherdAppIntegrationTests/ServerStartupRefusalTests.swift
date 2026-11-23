import Darwin
import Foundation
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("App startup ownership", .mainActorExclusive)
@MainActor
struct ServerStartupRefusalTests {
    final class Model {}

    @Test func quittingWhileTheOwnersBindIsBlockedLeavesItsAgentRunning() async throws {
        let h = try ScratchServer()
        defer { h.stop() }
        let socket = h.dir.appendingPathComponent("host.sock")
        // A directory at host.sock cannot be replaced by bind. The host can still run agents.
        try FileManager.default.createDirectory(at: socket, withIntermediateDirectories: false)
        await #expect(throws: SessionServerError.self) { try await h.server.listenLocal(path: socket.path) }
        let session = try await h.server.createSession(params: .init(cwd: h.dir.path, command: StubPi.command, runtime: .rpc))
        let pids = await h.server.resourceState().piPIDs
        let pid = try #require(pids.first)

        let elapsed = Locked(Duration.zero)
        let release = DispatchSemaphore(value: 0)
        let lock = h.dir.appendingPathComponent("server.lock").path
        var configuration = HostSupervisor.Configuration(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
            socket: socket.path, lock: lock)
        configuration.sleep = { step in
            elapsed.withValue { $0 += step }
            if elapsed.current >= .seconds(8) { release.wait() }
        }
        let supervisor = HostSupervisor(configuration)
        defer { supervisor.stop(); release.signal() }
        var failure: Error?
        let launch = ShepherdLaunch<Model>(start: { try supervisor.start() }, makeModel: { Model() }, failed: { failure = $0 })
        launch.begin()
        try await eventuallyOnMain("eight seconds of silence") { elapsed.current >= .seconds(8) }
        #expect(!RemoteHostClient.localSocketAnswers(socket.path))
        #expect(launch.model == nil)
        #expect(failure == nil)
        #expect(supervisor.childPID == nil, "the owner's workspace is not contested")
        #expect(!supervisor.ownsAgents)

        supervisor.stop()
        try await eventuallyOnMain("launch wait ends after stop") { failure != nil }
        #expect(failure is CancellationError, "launch ended with \(String(describing: failure))")
        #expect(launch.model == nil)

        let fd = open(lock, O_RDWR | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) != 0, "the owner kept the workspace lock")
        #expect(await h.server.sessionInfo(sessionID: session.id)?.isAlive == true)
        #expect(kill(pid, 0) == 0, "the owner's original pi is still alive")
    }
}
