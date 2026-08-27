import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
@testable import ShepherdApp

@Suite("Terminal session lifecycle")
@MainActor
struct TerminalSessionStoreTests {
    @Test func closingPaneDuringGridWaitDoesNotSpawnOrResurrectSession() async throws {
        let dir = URL(fileURLWithPath: "/tmp/shepherd-store-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { server.stop() }

        let space = Space(name: "s", path: "/tmp")
        let pane = LeafPane(cwd: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab]))

        let store = TerminalSessionStore(server: server)
        _ = store.session(for: pane, in: tab)
        await Task.yield()

        store.detachPane(pane.id)
        try await server.removeTab(tab.id)
        try await Task.sleep(for: .milliseconds(700))

        #expect(await server.listSessions().isEmpty)
        #expect(await store.awaitSession(forPane: pane.id, timeout: .milliseconds(50)) == nil)
    }

    @Test func attachWatermarkKeepsOnlyPostSnapshotOutput() {
        let buffered = [
            TerminalSessionStore.PaneSession.BufferedOutput(data: Data("before".utf8), sequence: 10),
            TerminalSessionStore.PaneSession.BufferedOutput(data: Data("included".utf8), sequence: 11),
            TerminalSessionStore.PaneSession.BufferedOutput(data: Data("after".utf8), sequence: 12),
        ]

        let fresh = TerminalSessionStore.PaneSession.output(after: 11, from: buffered)

        #expect(fresh.map(\.sequence) == [12])
        #expect(fresh.map { String(decoding: $0.data, as: UTF8.self) } == ["after"])
    }

    @Test func exitDuringSurfaceRebuildIsRetiredBeforeReattachment() async throws {
        let dir = URL(fileURLWithPath: "/tmp/shepherd-store-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { server.stop() }

        let store = TerminalSessionStore(server: server)
        let pane = LeafPane(cwd: "/")
        let paneSession = TerminalSessionStore.PaneSession(paneID: pane.id)
        var exitedPaneID: PaneID?
        store.onPaneSessionExited = { exitedPaneID = $0 }

        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "sleep 0.2"]
        ))
        try await store.adopt(paneSession, sessionID: info.id)
        store.rebuildAllSurfaces()

        let exitDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < exitDeadline, exitedPaneID != pane.id {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(exitedPaneID == pane.id)

        let retiredDeadline = ContinuousClock.now + .seconds(5)
        var retired = false
        while ContinuousClock.now < retiredDeadline {
            if await server.listSessions().isEmpty {
                retired = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(retired)
    }

    @Test func earlyExitIsHandledWhenAdoptionArrivesLate() async throws {
        let dir = URL(fileURLWithPath: "/tmp/shepherd-store-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { server.stop() }

        let store = TerminalSessionStore(server: server)
        let pane = LeafPane(cwd: "/")
        let paneSession = TerminalSessionStore.PaneSession(paneID: pane.id)
        var exitedPaneID: PaneID?
        store.onPaneSessionExited = { exitedPaneID = $0 }

        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "printf early-exit"]
        ))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await server.listSessions().first?.isAlive == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        try await store.adopt(paneSession, sessionID: info.id)
        let handledDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < handledDeadline, exitedPaneID == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(exitedPaneID == pane.id)
        #expect(paneSession.phase == .exited(0))

        let retiredDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < retiredDeadline {
            if await server.listSessions().isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await server.listSessions().isEmpty)
    }
}
