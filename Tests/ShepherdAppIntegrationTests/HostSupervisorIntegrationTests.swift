import Darwin
import Foundation
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// `HostSupervisor` against a stand-in host: a small Python script that takes the workspace lock
/// (exiting owned when it can't), answers on the socket (not in `silent` mode), and stops at its stdin's end of file.
@Suite("Host supervisor", .integrationTimeLimit)
struct HostSupervisorIntegrationTests {
    static let standIn = """
    import fcntl, os, signal, socket, sys, threading
    mode, path, folder = sys.argv[1:4]
    if mode == "crash":
        sys.exit(1)
    if mode == "stubborn":
        signal.signal(signal.SIGTERM, lambda *_: open(os.path.join(folder, "term"), "w").close())
    lock = open(os.path.join(folder, "server.lock"), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(\(SessionHost.ownedExitStatus))
    if mode == "silent":
        while True:
            signal.pause()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen(8)
    def accept():
        while True:
            listener.accept()[0].close()
    threading.Thread(target=accept, daemon=True).start()
    if mode == "owner":
        while True:
            signal.pause()
    while os.read(0, 256):
        pass
    """

    struct Fixture {
        let folder: URL
        let socket: String
        let script: String

        init() throws {
            folder = try makeScratchDirectory("sup")
            socket = folder.appendingPathComponent("h.sock").path
            script = folder.appendingPathComponent("host.py").path
            try HostSupervisorIntegrationTests.standIn.write(toFile: script, atomically: true, encoding: .utf8)
        }

        func configuration(_ mode: String, grace: Duration = .seconds(5)) -> HostSupervisor.Configuration {
            HostSupervisor.Configuration(executable: URL(fileURLWithPath: "/usr/bin/python3"),
                                         arguments: [script, mode, socket, folder.path], socket: socket,
                                         lock: folder.appendingPathComponent("server.lock").path,
                                         ownerPoll: .milliseconds(100), grace: grace)
        }
    }

    static func start(_ supervisor: HostSupervisor) async throws {
        try await Task.detached { try supervisor.start() }.value
    }

    static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func aKilledHostStartsAgainAndOneWhoseStdinClosesStops() async throws {
        let fixture = try Fixture()
        let supervisor = HostSupervisor(fixture.configuration("serve"))
        defer { supervisor.stop() }
        try await Self.start(supervisor)
        #expect(RemoteHostClient.localSocketAnswers(fixture.socket), "start returns once the host answers")
        let first = try #require(supervisor.childPID)
        #expect(supervisor.ownsAgents)

        kill(first, SIGKILL)
        try await eventually("a new host after the kill") {
            supervisor.childPID.map { $0 != first } == true && supervisor.ownsAgents
        }

        // The app's end of stdin closing (its crash) stops the host by itself.
        let second = try #require(supervisor.childPID)
        supervisor.closeChildStdin()
        try await eventually("the host stopped at its stdin's end of file") { !Self.alive(second) }
    }

    @Test func stopSendsSIGTERMThenSIGKILLAfterTheGrace() async throws {
        let fixture = try Fixture()
        let supervisor = HostSupervisor(fixture.configuration("stubborn", grace: .milliseconds(300)))
        try await Self.start(supervisor)
        let pid = try #require(supervisor.childPID)
        let clock = ContinuousClock()
        let took = clock.measure { supervisor.stop() }
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent("term").path), "SIGTERM came first")
        #expect(took >= .milliseconds(300), "the host had its grace")
        try await eventually("the host killed") { !Self.alive(pid) }
        #expect(supervisor.childPID == nil, "nothing started after stop")
    }

    @Test func threeFailedStartsAreTheLaunchsFailure() async throws {
        let fixture = try Fixture()
        var configuration = fixture.configuration("crash")
        configuration.sleep = { _ in }
        let supervisor = HostSupervisor(configuration)
        defer { supervisor.stop() }
        await #expect(throws: HostSupervisor.StartFailed.self) { try await Self.start(supervisor) }
    }

    @Test func anOwnerIsFollowedAndAChildStartsOnlyOnceItGoes() async throws {
        let fixture = try Fixture()
        let owner = Process()
        owner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        owner.arguments = [fixture.script, "owner", fixture.socket, fixture.folder.path]
        try owner.run()
        defer { if owner.isRunning { kill(owner.processIdentifier, SIGKILL) } }
        try await eventually("the owner answers") { RemoteHostClient.localSocketAnswers(fixture.socket) }

        let supervisor = HostSupervisor(fixture.configuration("serve"))
        defer { supervisor.stop() }
        try await Self.start(supervisor)
        #expect(supervisor.childPID == nil, "an owner's workspace is followed, not contested")
        #expect(!supervisor.ownsAgents, "Quit leaves the owner's agents running")

        kill(owner.processIdentifier, SIGKILL)
        try await eventually("the app's own host once the owner went") {
            supervisor.ownsAgents && RemoteHostClient.localSocketAnswers(fixture.socket)
        }
    }
}
