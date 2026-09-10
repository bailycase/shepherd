import AppKit
import SwiftUI
import Foundation
import Testing
import ShepherdCore
import ShepherdSessions
@testable import ShepherdApp
@testable import TerminalSurfaceKit

@Suite("Terminal session lifecycle", .serialized)
@MainActor
struct TerminalSessionStoreTests {
    @Test(arguments: [false, true])
    func absentSurfaceKeepsProcessAliveAndRecoversSnapshot(initiallyMounted: Bool) async throws {
        let dir = URL(fileURLWithPath: "/tmp/shepherd-store-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { server.stop() }
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/tmp", command: ["/bin/sh", "-c", "stty -echo; while IFS= read -r line; do printf '%s\\n' \"$line\"; done"]
        ))
        let space = Space(name: "s", path: "/tmp")
        let pane = LeafPane(sessionID: info.id, cwd: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab]))
        let store = TerminalSessionStore(server: server)
        let session = store.session(for: pane, in: tab)
        let receive = server.onSequencedOutput
        var deliveredBytes = 0
        server.onSequencedOutput = { id, data, sequence in
            deliveredBytes += data.count
            receive?(id, data, sequence)
        }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        window.contentView = host
        defer { window.contentView = nil }
        if initiallyMounted {
            host.rootView = AnyView(AppTerminalView(model: session.terminal, isFocused: false))
            window.layoutIfNeeded()
            try await waitFor { session.phase == .live }
            host.rootView = AnyView(EmptyView())
            window.layoutIfNeeded()
        }
        // Past the old 700ms fallback, neither an absent view nor a resize
        // callback from an old view may subscribe to output.
        session.terminal.onResize?(100, 30)
        try await Task.sleep(for: .seconds(1))
        let before = deliveredBytes
        let marker = initiallyMounted ? "after-disappearance" : "never-mounted"
        server.write(sessionID: info.id, data: Data((String(repeating: "background-output\n", count: 500) + marker + "\n").utf8))
        try await Task.sleep(for: .milliseconds(500))
        #expect(deliveredBytes == before)
        #expect(await server.sessionInfo(sessionID: info.id)?.isAlive == true)
        #expect(store.liveSession(forPane: pane.id) == info.id)

        host.rootView = AnyView(AppTerminalView(model: session.terminal, isFocused: false, isRendering: false))
        window.layoutIfNeeded()
        try await waitFor { session.terminal.model.session.readViewportText()?.contains(marker) == true }
        #expect(session.phase == .live)
        // A valid mounted-but-hidden surface must still receive live output.
        server.write(sessionID: info.id, data: Data("hidden-live\n".utf8))
        try await waitFor { session.terminal.model.session.readViewportText()?.contains("hidden-live") == true }
        #expect(deliveredBytes > before)
        #expect(await server.listSessions().count == 1)
    }

    @Test(arguments: [false, true])
    func pendingAttachSurvivesDisappearanceOrReplacement(replace: Bool) async throws {
        let dir = URL(fileURLWithPath: "/tmp/shepherd-store-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = SessionServer(
            socketPath: dir.appendingPathComponent("d.sock").path,
            stateURL: dir.appendingPathComponent("state.json")
        )
        try server.start()
        defer { server.stop() }
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/tmp", command: ["/bin/sh", "-c", "stty -echo; printf 'snapshot-once\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done"]
        ))
        let space = Space(name: "s", path: "/tmp")
        let pane = LeafPane(sessionID: info.id, cwd: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab]))
        let store = TerminalSessionStore(server: server)
        let session = store.session(for: pane, in: tab)
        try await waitFor { session.sessionID == info.id }
        let deadline = ContinuousClock.now + .seconds(5)
        while await server.screenText(sessionID: info.id)?.contains("snapshot-once") != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await server.screenText(sessionID: info.id)?.contains("snapshot-once") == true)

        let receive = server.onSequencedOutput
        var delivered = Data()
        server.onSequencedOutput = { id, data, sequence in
            delivered.append(data)
            receive?(id, data, sequence)
        }
        let attachmentChanged = session.terminal.onSurfaceAttachmentChanged
        var invalidated = false
        let replacementID = UUID()
        session.terminal.onSurfaceAttachmentChanged = { generation in
            attachmentChanged?(generation)
            guard generation != nil, !invalidated else { return }
            invalidated = true
            // No main-actor yield: the attach reply is still pending when these
            // lifecycle events invalidate it and optionally start a new generation.
            let absentID = UUID()
            session.terminal.model.surfaceViewAppeared(absentID)
            session.terminal.model.surfaceViewDisappeared(absentID)
            if replace { session.terminal.model.surfaceViewAppeared(replacementID) }
        }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: AppTerminalView(model: session.terminal, isFocused: false))
        defer { window.contentView = nil }
        window.layoutIfNeeded()
        try await waitFor { invalidated }
        if replace {
            try await waitFor { session.phase == .live }
        }
        server.write(sessionID: info.id, data: Data("after-invalidation\n".utf8))
        let outputDeadline = ContinuousClock.now + .seconds(5)
        while await server.screenText(sessionID: info.id)?.contains("after-invalidation") != true,
              ContinuousClock.now < outputDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await server.screenText(sessionID: info.id)?.contains("after-invalidation") == true)
        if !replace {
            try await Task.sleep(for: .milliseconds(100))
            #expect(delivered.isEmpty)
            #expect(session.phase != .live)
            session.terminal.model.surfaceViewAppeared(replacementID)
        }
        try await waitFor {
            session.terminal.model.session.readViewportText()?.contains("after-invalidation") == true
        }
        server.write(sessionID: info.id, data: Data("live-once\n".utf8))
        try await waitFor { session.terminal.model.session.readViewportText()?.contains("live-once") == true }
        let text = try #require(session.terminal.model.session.readViewportText())
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(lines == ["snapshot-once", "after-invalidation", "live-once"])
        #expect(await server.sessionInfo(sessionID: info.id)?.isAlive == true)
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

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
