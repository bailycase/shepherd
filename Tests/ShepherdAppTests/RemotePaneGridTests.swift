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

    @Test func closingInspectorStreamReleasesHostViewportWithoutKillingSession() async throws {
        let dir = URL(fileURLWithPath: "/tmp/shepherd-detach-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = SessionServer(socketPath: dir.appendingPathComponent("d.sock").path, stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer { server.stop() }
        let info = try await server.createSession(params: .init(cwd: dir.path, command: ["/bin/cat"], cols: 120, rows: 40))
        server.reportLocalViewport(sessionID: info.id, cols: 120, rows: 40)
        let space = Space(name: "host", path: dir.path)
        let primary = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: dir.path)))
        let agent = Agent(name: "agent", spaceID: space.id, tabID: primary.id)
        let inspector = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(sessionID: info.id, cwd: dir.path)), inspectorFor: agent.id)
        try await server.putState(.init(spaces: [space], tabs: [primary, inspector], agents: [agent]))
        let tokenURL = dir.appendingPathComponent("remote-token")
        let port = try server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let suite = "shepherd.detach.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let remotes = RemoteHostStore(defaults: defaults)
        remotes.addHost(name: "host", host: "127.0.0.1", port: port, token: token)
        let connection = try #require(remotes.connections.first)
        defer { remotes.removeHost(id: connection.id) }
        #expect(await waitUntil { connection.phase == .connected })
        let pane = try #require(remotes.paneSession(connection: connection, sessionID: info.id))
        pane.noteGrid(cols: 80, rows: 24)
        #expect(await waitUntil { pane.phase == .live })
        #expect(await server.sessionInfo(sessionID: info.id)?.cols == 80)
        remotes.closePane(connection: connection, sessionID: info.id)
        #expect(connection.pane(for: info.id) == nil)
        var restored = false
        for _ in 0..<100 {
            if let state = await server.sessionInfo(sessionID: info.id), state.cols == 120, state.rows == 40 {
                restored = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(restored)
        #expect(server.state.tabs.contains { $0.id == inspector.id })
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
