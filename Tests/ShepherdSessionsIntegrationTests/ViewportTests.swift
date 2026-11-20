import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// PTY sizing with several viewers (tmux semantics): attached remote viewers share the smallest
/// grid among them; with none attached, the host's own surface rules. Reports that would not
/// change the grid never reach the child — every SIGWINCH is a full TUI repaint.
@Suite("Viewport sizing", .integrationTimeLimit)
struct ViewportTests {
    private func size(_ r: RemoteHost, _ id: SessionID) async -> [Int]? {
        await r.server.sessionInfo(sessionID: id).map { [$0.cols, $0.rows] }
    }

    private func waitForSize(_ r: RemoteHost, _ id: SessionID, _ expected: [Int]) async throws {
        try await eventually("the PTY to be \(expected[0])x\(expected[1])") { await size(r, id) == expected }
    }

    @Test func theSmallestAttachedViewerWins() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        r.server.reportLocalViewport(sessionID: info.id, cols: 200, rows: 60)
        try await waitForSize(r, info.id, [200, 60])

        let phone = try await r.raw()
        try phone.send(.attach(id: 2, sessionID: info.id, cols: 46, rows: 30, viewportGeneration: 0))
        try await waitForSize(r, info.id, [46, 30])

        let laptop = try await r.raw()
        try laptop.send(.attach(id: 2, sessionID: info.id, cols: 150, rows: 25, viewportGeneration: 0))
        try await waitForSize(r, info.id, [46, 25])

        try phone.send(.resize(sessionID: info.id, cols: 120, rows: 40, viewportGeneration: 1))
        try await waitForSize(r, info.id, [120, 25])

        try phone.send(.detach(sessionID: info.id))
        try await waitForSize(r, info.id, [150, 25])

        laptop.closeConnection()
        try await waitForSize(r, info.id, [200, 60])
    }

    /// Remote viewers are sized among themselves; a small host window does not clamp them.
    @Test func theHostSurfaceOnlyRulesWithoutRemoteViewers() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        r.server.reportLocalViewport(sessionID: info.id, cols: 80, rows: 24)
        let client = try await r.raw()
        try client.send(.attach(id: 2, sessionID: info.id, cols: 160, rows: 50, viewportGeneration: 0))
        try await waitForSize(r, info.id, [160, 50])

        try client.send(.detach(sessionID: info.id))
        try await waitForSize(r, info.id, [80, 24])
    }

    @Test func resizeReportsFromUnattachedOrEmptyViewportsAreIgnored() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        let bystander = try await r.raw()
        try bystander.send(.resize(sessionID: info.id, cols: 20, rows: 10, viewportGeneration: 0))
        r.server.reportLocalViewport(sessionID: info.id, cols: 0, rows: 5)
        // A round trip on the same connection orders the ignored report before this check.
        try bystander.send(.stateFetch(id: 9))
        _ = try await bystander.frames(until: { if case .state = $0 { true } else { false } })
        #expect(await size(r, info.id) == [80, 24])
    }

    @Test func oversizedViewportsCannotReplaceAValidGrid() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let info = try await r.host.shell("cat")
        let client = try await r.raw()
        try client.send(.attach(id: 2, sessionID: info.id, cols: 100, rows: 30, viewportGeneration: 0))
        try await waitForSize(r, info.id, [100, 30])

        for (cols, rows) in [(65_536, 1), (1, Int.max), (1024, 1024)] {
            try client.send(.resize(sessionID: info.id, cols: cols, rows: rows, viewportGeneration: 1))
            r.server.reportLocalViewport(sessionID: info.id, cols: cols, rows: rows)
            r.server.resize(sessionID: info.id, cols: cols, rows: rows)
            try client.send(.stateFetch(id: 9))
            _ = try await client.frames(until: { if case .state = $0 { true } else { false } })
            #expect(await size(r, info.id) == [100, 30])
        }
        try client.send(.attach(id: 10, sessionID: info.id, cols: 65_536, rows: 1, viewportGeneration: 2))
        let refused = try await client.frames(until: { if case .error(id: 10, code: _, message: _) = $0 { true } else { false } })
        #expect(refused.contains { if case .error(id: 10, code: "invalid_viewport", message: _) = $0 { true } else { false } })
        #expect(await size(r, info.id) == [100, 30])
        try client.send(.resize(sessionID: info.id, cols: 120, rows: 40, viewportGeneration: 3))
        try await waitForSize(r, info.id, [120, 40])
        // The invalid local report was not stored for later use when the remote detaches.
        r.server.reportLocalViewport(sessionID: info.id, cols: 90, rows: 25)
        r.server.reportLocalViewport(sessionID: info.id, cols: Int.max, rows: Int.max)
        try client.send(.detach(sessionID: info.id))
        try await waitForSize(r, info.id, [90, 25])
    }

    @Test func invalidInitialGridsStartNoChild() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        for (cols, rows) in [(0, 24), (-1, 24), (65_536, 1), (1024, 1024), (Int.max, Int.max)] {
            await #expect(throws: PTYSession.SpawnError.self) {
                _ = try await h.server.createSession(params: CreateSessionParams(
                    cwd: h.dir.path, command: ["/bin/sh", "-c", "touch should-not-run"], cols: cols, rows: rows))
            }
        }
        #expect(await h.server.listSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("should-not-run").path))
    }

    @Test func unchangedReportsDoNotSignalTheChild() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let counter = """
        import signal, sys
        n = 0
        def winch(*_):
            global n
            n += 1
        signal.signal(signal.SIGWINCH, winch)
        print("READY", flush=True)
        while True:
            line = sys.stdin.readline()
            if not line: break
            print("probe %s winch=%d" % (line.strip(), n), flush=True)
        """
        let info = try await r.server.createSession(params: CreateSessionParams(cwd: r.host.dir.path, command: ["python3", "-c", counter]))
        try await r.host.waitForScreen(info.id, toContain: "READY")
        let client = try await r.raw()

        try client.send(.attach(id: 2, sessionID: info.id, cols: 100, rows: 30, viewportGeneration: 0))
        try client.send(.input(sessionID: info.id, data: Data("a\n".utf8)))
        try await r.host.waitForScreen(info.id, toContain: "probe a winch=1")

        try client.send(.resize(sessionID: info.id, cols: 100, rows: 30, viewportGeneration: 1))
        r.server.reportLocalViewport(sessionID: info.id, cols: 100, rows: 30)
        try client.send(.input(sessionID: info.id, data: Data("b\n".utf8)))
        try await r.host.waitForScreen(info.id, toContain: "probe b winch=")
        #expect(await r.host.screen(info.id).contains("probe b winch=1"))
    }
}
