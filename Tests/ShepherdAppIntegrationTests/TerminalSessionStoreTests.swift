import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import TerminalSurfaceKit

/// Pane → session binding in `TerminalSessionStore` against a real server: shells keep
/// running without a view and replay exactly once when one mounts; RPC agent panes bind
/// without any surface; exits retire their sessions however they race the binding.
@Suite("Terminal session store", .mainActorExclusive)
@MainActor
struct TerminalSessionStoreTests {
    /// An echo loop that also prints `banner` once at start.
    private static func echo(banner: String = "") -> [String] {
        ["/bin/sh", "-c", "stty -echo; \(banner.isEmpty ? "" : "printf '\(banner)\\n'; ")while IFS= read -r line; do printf '%s\\n' \"$line\"; done"]
    }

    private struct ShellPane {
        let store: TerminalSessionStore
        let session: TerminalSessionStore.PaneSession
        let pane: LeafPane
        let info: SessionInfo
    }

    /// A store over one layout whose single leaf is bound to a running echo shell.
    private func shellPane(_ server: ScratchServer, banner: String = "") async throws -> ShellPane {
        let info = try await server.server.createSession(params: CreateSessionParams(cwd: server.dir.path, command: Self.echo(banner: banner)))
        let space = Fixture.space(path: server.dir.path)
        let pane = LeafPane(sessionID: info.id, cwd: server.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await server.server.putState(ShepherdState(spaces: [space], tabs: [tab]))
        let store = TerminalSessionStore(server: server.server)
        return ShellPane(store: store, session: store.session(for: pane, in: tab), pane: pane, info: info)
    }

    private func screenContains(_ server: SessionServer, _ id: SessionID, _ text: String) async -> Bool {
        await server.screenText(sessionID: id)?.contains { $0.contains(text) } == true
    }

    /// Output produced while no view is mounted is never streamed to the app; mounting a view
    /// later recovers it from the server's screen, and a mounted-but-hidden view still streams.
    @Test(arguments: [false, true])
    func aShellKeepsRunningWithoutAViewAndItsScreenReturnsWhenOneMounts(mountedFirst: Bool) async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let server = scratch.server
        let shell = try await shellPane(scratch)
        let delivered = Locked(0)
        let forward = server.onSequencedOutput
        server.onSequencedOutput = { id, data, sequence in
            delivered.withValue { $0 += data.count }
            forward?(id, data, sequence)
        }
        let window = OffscreenWindow()
        defer { window.close() }
        if mountedFirst {
            window.show(AppTerminalView(model: shell.session.terminal, isFocused: false))
            try await eventuallyOnMain("the surface to go live") { shell.session.phase == .live }
            window.show(EmptyView())
        }
        // A resize report from a view that is gone must not resubscribe to output.
        shell.session.terminal.onResize?(100, 30)
        let before = delivered.current

        server.write(sessionID: shell.info.id, data: Data((String(repeating: "background-output\n", count: 200) + "marker\n").utf8))
        try await eventuallyAsync("the shell to print while unwatched") { await screenContains(server, shell.info.id, "marker") }

        #expect(delivered.current == before, "no view, no stream")
        #expect(await server.sessionInfo(sessionID: shell.info.id)?.isAlive == true)
        #expect(shell.store.liveSession(forPane: shell.pane.id) == shell.info.id)
        window.show(AppTerminalView(model: shell.session.terminal, isFocused: false, isRendering: false))
        try await eventuallyOnMain("the remounted view to replay the screen") {
            shell.session.terminal.model.session.readViewportText()?.contains("marker") == true
        }
        server.write(sessionID: shell.info.id, data: Data("hidden-live\n".utf8))
        try await eventuallyOnMain("a hidden view to keep streaming") {
            shell.session.terminal.model.session.readViewportText()?.contains("hidden-live") == true
        }
        #expect(await server.listSessions().count == 1)
    }

    /// The attach reply for a surface can arrive after that surface already went away (or was
    /// replaced). It must be dropped: no output reaches an absent view, and the view that
    /// finally attaches sees the snapshot plus later output exactly once.
    @Test(arguments: [false, true])
    func aStaleAttachReplyIsDroppedAndTheNextViewSeesOutputExactlyOnce(replaced: Bool) async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let server = scratch.server
        let shell = try await shellPane(scratch, banner: "snapshot-once")
        let session = shell.session
        try await eventuallyAsync("the banner on the server's screen") { await screenContains(server, shell.info.id, "snapshot-once") }
        let delivered = Locked(Data())
        let forward = server.onSequencedOutput
        server.onSequencedOutput = { id, data, sequence in
            delivered.withValue { $0.append(data) }
            forward?(id, data, sequence)
        }
        let replacement = UUID()
        var invalidated = false
        let attachmentChanged = session.terminal.onSurfaceAttachmentChanged
        session.terminal.onSurfaceAttachmentChanged = { generation in
            attachmentChanged?(generation)
            guard generation != nil, !invalidated else { return }
            invalidated = true
            // Synchronously, while the attach reply is still in flight: another view appears
            // and disappears, and optionally a replacement view takes over.
            let absent = UUID()
            session.terminal.model.surfaceViewAppeared(absent)
            session.terminal.model.surfaceViewDisappeared(absent)
            if replaced { session.terminal.model.surfaceViewAppeared(replacement) }
        }
        let window = OffscreenWindow()
        defer { window.close() }

        window.show(AppTerminalView(model: session.terminal, isFocused: false))
        try await eventuallyOnMain("the first attach to be invalidated") { invalidated }
        if replaced { try await eventuallyOnMain("the replacement view to go live") { session.phase == .live } }
        server.write(sessionID: shell.info.id, data: Data("after-invalidation\n".utf8))
        // The screen query is answered after every earlier reply on the main queue, including
        // a stale attach reply, so nothing that was going to be delivered is still pending.
        try await eventuallyAsync("the shell to print") { await screenContains(server, shell.info.id, "after-invalidation") }
        if !replaced {
            #expect(delivered.current.isEmpty, "nothing streams to a view that disappeared")
            #expect(session.phase != .live)
            session.terminal.model.surfaceViewAppeared(replacement)
        }
        try await eventuallyOnMain("the attached view to show the screen") {
            session.terminal.model.session.readViewportText()?.contains("after-invalidation") == true
        }
        server.write(sessionID: shell.info.id, data: Data("live-once\n".utf8))
        try await eventuallyOnMain("live output to arrive") {
            session.terminal.model.session.readViewportText()?.contains("live-once") == true
        }

        let lines = try #require(session.terminal.model.session.readViewportText())
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        #expect(lines == ["snapshot-once", "after-invalidation", "live-once"])
        #expect(await server.sessionInfo(sessionID: shell.info.id)?.isAlive == true)
    }

    /// A shell pane whose layout disappears while it waits for its first grid never spawns.
    @Test func aPaneRemovedBeforeItsShellStartsNeverSpawnsOne() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let server = scratch.server
        let space = Fixture.space(path: scratch.dir.path)
        let pane = LeafPane(cwd: scratch.dir.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        try await server.putState(ShepherdState(spaces: [space], tabs: [tab]))
        let store = TerminalSessionStore(server: server)
        let session = store.session(for: pane, in: tab)

        try await server.removeTab(tab.id)

        try await eventuallyOnMain("the pane's start to give up") {
            if case .failed = session.phase { return true }
            return false
        }
        #expect(await server.listSessions().isEmpty)
        #expect(store.liveSession(forPane: pane.id) == nil)
    }

    /// An RPC agent's pane binds its pi without a Ghostty surface, grid wait, or attach; the
    /// binding survives surface rebuilds and cold parking; pi exiting still closes the pane.
    @Test func anRPCAgentPaneBindsWithoutASurfaceAndClosesWhenPiExits() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space)
        try await app.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let store = TerminalSessionStore(server: app.server)
        var exited: PaneID?
        store.onPaneSessionExited = { exited = $0 }

        let session = store.session(for: agent.piPane, in: agent.tab)

        #expect(session.isRPC)
        try await eventuallyOnMain("the pane to bind pi") { session.phase == .live }
        #expect(!session.hasTerminalModel)
        let sessionID = try #require(store.liveSession(forPane: agent.piPane.id))
        let info = try #require(await app.server.sessionInfo(sessionID: sessionID))
        #expect(info.cols == 0 && info.rows == 0)
        store.rebuildAllSurfaces()
        store.parkPane(agent.piPane.id)
        #expect(store.session(for: agent.piPane, in: agent.tab) === session)
        #expect(store.liveSession(forPane: agent.piPane.id) == sessionID && !session.hasTerminalModel)

        let snapshot = try await app.readyThread(agent.agent.id)
        _ = try? await app.server.nativeThread(agentID: agent.agent.id, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), text: "die", delivery: .followUp))

        try await eventuallyOnMain("pi's exit to close the pane") { exited == agent.piPane.id }
        #expect(session.phase == .exited(3))
    }

    @Test func aProcessThatExitsDuringASurfaceRebuildIsRetired() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let server = scratch.server
        let store = TerminalSessionStore(server: server)
        let pane = LeafPane(cwd: "/")
        let session = TerminalSessionStore.PaneSession(paneID: pane.id)
        var exited: PaneID?
        store.onPaneSessionExited = { exited = $0 }
        let gate = scratch.dir.appendingPathComponent("exit-now")
        let info = try await server.createSession(params: CreateSessionParams(
            cwd: "/", command: ["/bin/sh", "-c", "while [ ! -e '\(gate.path)' ]; do sleep 0.01; done"]))
        try await store.adopt(session, sessionID: info.id)

        store.rebuildAllSurfaces()
        FileManager.default.createFile(atPath: gate.path, contents: nil)

        try await eventuallyOnMain("the exit to close the pane") { exited == pane.id }
        try await eventuallyAsync("the dead session to be retired") { await server.listSessions().isEmpty }
    }

    @Test func aProcessThatExitsBeforeItsPaneAdoptsItIsStillHandled() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let server = scratch.server
        let store = TerminalSessionStore(server: server)
        let pane = LeafPane(cwd: "/")
        let session = TerminalSessionStore.PaneSession(paneID: pane.id)
        var exited: PaneID?
        store.onPaneSessionExited = { exited = $0 }
        let info = try await server.createSession(params: CreateSessionParams(cwd: "/", command: ["/bin/sh", "-c", "exit 0"]))
        try await eventuallyAsync("the process to exit") { await server.sessionInfo(sessionID: info.id)?.isAlive == false }

        try await store.adopt(session, sessionID: info.id)

        try await eventuallyOnMain("the late adoption to see the exit") { exited == pane.id }
        #expect(session.phase == .exited(0))
        try await eventuallyAsync("the dead session to be retired") { await server.listSessions().isEmpty }
    }
}
