import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
@testable import ShepherdApp

/// A global shell that was running a command when the app quit re-types that
/// command into the fresh shell on relaunch. End-to-end against a real
/// server: seed persisted state carrying `restoreCommand`, render the pane,
/// and watch the spawned PTY actually run it.
@Suite("Shell restore", .serialized)
@MainActor
struct ShellRestoreTests {
    private struct Fixture {
        let dir: URL
        let server: SessionServer

        init() throws {
            dir = URL(fileURLWithPath: "/tmp/shepherd-shellrestore-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(15),
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }

    @Test func restoreCommandRunsInTheRespawnedShell() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }

        // Persisted state as a previous run would leave it: a shell tab whose
        // pane carries a dead sessionID and a recorded restore command.
        let marker = "SHEPHERD_RESTORE_\(UInt32.random(in: 0..<1_000_000))"
        let pane = LeafPane(sessionID: SessionID(), cwd: "/tmp")
        let shell = Tab(
            spaceID: nil,
            order: 0,
            layout: .leaf(pane),
            name: "~",
            restoreCommand: "echo \(marker)"
        )
        try await fixture.server.putState(ShepherdState(spaces: [], tabs: [shell], agents: []))

        let vm = ShepherdViewModel(server: fixture.server)
        #expect(await waitUntil { vm.state.tabs.first?.id == shell.id })

        // Rendering the pane view triggers the spawn; do what PaneLeafView does.
        _ = vm.sessions.session(for: pane, in: shell)

        // The fresh shell must eventually run the restore command: its PTY
        // screen shows the marker (echoed by the command itself).
        let sawMarker = await waitUntil { [weak server = fixture.server] in
            guard let server else { return false }
            guard let session = await server.listSessions().first(where: \.isAlive) else { return false }
            let lines = await server.screenText(sessionID: session.id) ?? []
            return lines.contains { $0.contains(marker) }
        }
        #expect(sawMarker)
    }
}
