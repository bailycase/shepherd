import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
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

    @Test func aHostRefusesAWorkspaceTheAppOwns() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        await #expect(processExitsWith: .failure) { [socket = h.socketPath as String, state = h.stateURL.path as String] in
            SessionHost.run(SessionServer(socketPath: socket, stateURL: URL(fileURLWithPath: state)), respawn: Self.defaults)
        }
        #expect(FileManager.default.fileExists(atPath: h.socketPath), "the owner keeps serving")
    }

    @Test func onlyTheOwnershipRefusalReadsAsWorkspaceInUse() {
        #expect(SessionServerError.isWorkspaceInUse(SessionServerError.system(call: "bind", errno: EADDRINUSE)))
        #expect(!SessionServerError.isWorkspaceInUse(SessionServerError.system(call: "bind", errno: EACCES)))
        #expect(!SessionServerError.isWorkspaceInUse(SessionServerError.socketPathTooLong(path: "/x")))
    }
}
