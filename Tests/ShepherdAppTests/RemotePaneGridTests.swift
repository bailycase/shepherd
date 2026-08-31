import Foundation
import Testing
import ShepherdCore
import ShepherdRemote
import ShepherdSessions
@testable import ShepherdApp

@Suite("Remote pane grid", .serialized)
@MainActor
struct RemotePaneGridTests {
    @Test func initialAttachWaitsForSettledGrid() async throws {
        let dir = URL(
            fileURLWithPath: "/tmp/shepherd-remote-grid-\(UInt32.random(in: 0..<1_000_000))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { server.stop() }

        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "sleep 30"],
            cols: 80,
            rows: 24
        ))
        let tokenURL = dir.appendingPathComponent("remote-token")
        let port = try server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "test")
        defer { client.disconnect() }

        let pane = RemotePaneSession(sessionID: info.id, client: client)
        pane.start()
        pane.noteGrid(cols: 97, rows: 34)
        pane.noteGrid(cols: 139, rows: 34)

        #expect(await waitUntil { pane.phase == RemotePaneSession.Phase.live })
        let attached = try #require(await server.sessionInfo(sessionID: info.id))
        #expect((attached.cols, attached.rows) == (139, 34))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
