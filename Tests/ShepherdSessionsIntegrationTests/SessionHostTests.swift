import Darwin
import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions
import ShepherdTestSupport

/// `Shepherd --host`: the session server with no UI. Each host runs in its own process (an exit
/// test), since it owns signal handling and ends with `exit`.
@Suite("Headless host", .integrationTimeLimit)
struct SessionHostTests {
    @MainActor static func defaults(_ agent: Agent) -> AgentSpawn { AgentSpawn(agent: agent, cwd: "", settings: AgentLaunchSettings()) }

    @Test func theHostServesUntilSIGTERMThenStopsAndFreesTheWorkspace() async throws {
        let dir = try makeScratchDirectory("host")
        let socket = dir.appendingPathComponent("s.sock").path
        let state = dir.appendingPathComponent("state.json").path
        await #expect(processExitsWith: .success) { [socket = socket as String, state = state as String] in
            let server = SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state))
            SessionHost.run(server, respawn: Self.defaults, ready: { kill(getpid(), SIGTERM) })
        }
        #expect(!FileManager.default.fileExists(atPath: socket), "the host stopped its server")
        let next = SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state))
        defer { next.stop() }
        try next.start()
    }

    /// While the server queue is busy (here, parked), start-up leaves the main actor free: the remote and local listeners bind
    /// once the queue turns, and nothing on main waits for it. A main actor that waited would be stuck until the safety release.
    @Test func startUpKeepsTheMainActorFreeWhileTheServerQueueIsBusy() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let release = DispatchSemaphore(value: 0)
        await h.server.holdQueue(until: release)
        defer { release.signal() }
        let safetyReleased = Locked(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { safetyReleased.withValue { $0 = true }; release.signal() }
        let configured = Locked(false)
        let remote = Locked<UInt16??>(nil)
        let local = h.dir.appendingPathComponent("h.sock").path
        let serving = Task { @MainActor in
            await SessionHost.serve(h.server, socket: local, recovering: false, respawn: Self.defaults, configure: { server in
                server.setRemoteListener(port: 0) { result in remote.withValue { $0 = .some((try? result.get()) ?? nil) } }
                configured.withValue { $0 = true }
            })
        }
        try await eventually("start-up to configure the remote listener") { configured.current }
        await MainActor.run {}
        #expect(!safetyReleased.current, "the main actor answered only after the parked queue was released: start-up waits on it")

        release.signal()
        _ = await serving.value
        try await eventually("the remote listener to bind") { remote.current != nil }
        #expect((remote.current ?? nil) != nil)
        #expect(FileManager.default.fileExists(atPath: local), "the local socket is bound")
    }

    /// A newer app's `drain` reaches a host that serves a remote listener: it exits once quiet, as an idle host must, and
    /// does not wait on the listener. Build 724 hung here after the app asked it to drain, so it never moved to a new build.
    @Test func aDrainWhileTheRemoteListenerIsOpenEndsTheHost() async throws {
        let dir = try makeScratchDirectory("host")
        let socket = dir.appendingPathComponent("s.sock").path
        let state = dir.appendingPathComponent("state.json").path
        await #expect(processExitsWith: .success) { [socket = socket as String, state = state as String] in
            let server = SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state))
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { _exit(EXIT_FAILURE) }
            SessionHost.run(server, respawn: Self.defaults, configure: { server in
                server.setRemoteListener(port: 0) { result in
                    guard case .success(.some) = result, let drain = server.onDrainRequest else { _exit(EXIT_FAILURE) }
                    drain()
                }
            })
        }
        #expect(!FileManager.default.fileExists(atPath: socket), "the drained host stopped its server")
    }

    /// Once an idle host drains, shutdown must keep main free even if the server queue is busy.
    /// Only main can release the parked queue, and only after shutdown has begun.
    @Test func drainedHostKeepsTheMainQueueAnsweringWhileShutdownWaitsOnTheServerQueue() async throws {
        let dir = try makeScratchDirectory("host")
        let socket = dir.appendingPathComponent("s.sock").path
        let state = dir.appendingPathComponent("state.json").path
        await #expect(processExitsWith: .success) { [socket = socket as String, state = state as String] in
            let server = SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state))
            let release = DispatchSemaphore(value: 0)
            SessionHost.run(server, respawn: Self.defaults, configure: { server in
                // Let startup dispatch the listener bind before parking the queue.
                DispatchQueue.main.async {
                    server.queue.async { release.wait() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) { _exit(EXIT_FAILURE) }
                    Task.detached {
                        do {
                            try await eventually("shutdown to enter stop", timeout: .seconds(5)) {
                                do { _ = try BoundedCommand.run(["/usr/bin/true"], timeout: 5); return false }
                                catch BoundedCommand.Failure.terminating { return true }
                            }
                        } catch {
                            _exit(EXIT_FAILURE)
                        }
                        DispatchQueue.main.async { release.signal() }
                    }
                    guard let drain = server.onDrainRequest else { _exit(EXIT_FAILURE) }
                    drain()
                }
            })
        }
    }

    @Test func aHostRefusesAWorkspaceTheAppOwns() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        // A distinct status, so the app's supervisor follows the owner instead of restarting.
        await #expect(processExitsWith: .exitCode(SessionHost.ownedExitStatus)) { [socket = h.socketPath as String, state = h.stateURL.path as String] in
            SessionHost.run(SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state)), respawn: Self.defaults)
        }
        #expect(FileManager.default.fileExists(atPath: h.socketPath), "the owner keeps serving")
    }

    @Test func theAppsChildStopsWhenItsStdinCloses() async throws {
        let dir = try makeScratchDirectory("host")
        let socket = dir.appendingPathComponent("s.sock").path
        let state = dir.appendingPathComponent("state.json").path
        await #expect(processExitsWith: .success) { [socket = socket as String, state = state as String] in
            // The app's pipe as stdin; closing its write end is the app quitting or crashing.
            var fds: [Int32] = [0, 0]
            precondition(pipe(&fds) == 0)
            dup2(fds[0], STDIN_FILENO)
            close(fds[0])
            let server = SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state))
            SessionHost.run(server, supervised: true, respawn: Self.defaults, ready: { close(fds[1]) })
        }
        #expect(!FileManager.default.fileExists(atPath: socket), "the host stopped its server")
    }

    @Test func onlyTheOwnershipRefusalReadsAsWorkspaceInUse() {
        #expect(SessionServerError.isWorkspaceInUse(SessionServerError.system(call: "bind", errno: EADDRINUSE)))
        #expect(!SessionServerError.isWorkspaceInUse(SessionServerError.system(call: "bind", errno: EACCES)))
        #expect(!SessionServerError.isWorkspaceInUse(SessionServerError.socketPathTooLong(path: "/x")))
    }
}
