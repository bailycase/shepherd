import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// A terminal tab restored from state.json after a relaunch (2026-10 audit, L22): the shown
/// tab's shell respawns and binds to the tab; a hidden one waits, dormant, until its tab shows.
@Suite("Terminal restore", .mainActorExclusive)
@MainActor
struct TerminalRestoreTests {
    @Test func aRestoredTerminalTabRespawnsItsShellWhenShown() async throws {
        try StubPi.installAsEngine()
        let directory = try makeScratchDirectory("l22")
        let space = Fixture.space(path: directory.path)
        var shown = Fixture.agent("shown", in: space, order: 0, auxiliary: 1, piSession: SessionID())
        var hidden = Fixture.agent("hidden", in: space, order: 1, auxiliary: 1, piSession: SessionID())
        shown.agent.lastActiveAt = 20
        hidden.agent.lastActiveAt = 10
        // The previous run's shells died with it; their bindings are what state.json still holds.
        let stale = (shown: SessionID(), hidden: SessionID())
        shown.tab.layout = shown.tab.layout.updatingLeaf(shown.auxiliary[0].id) { $0.sessionID = stale.shown }
        hidden.tab.layout = hidden.tab.layout.updatingLeaf(hidden.auxiliary[0].id) { $0.sessionID = stale.hidden }
        try JSONEncoder().encode(Fixture.state(spaces: [space], agents: [shown, hidden]))
            .write(to: directory.appendingPathComponent("state.json"))

        let app = try AppHarness(directory: directory)
        defer { app.stop() }
        let vm = try await app.start(restoringAgents: true)
        #expect(vm.selectedAgentID == shown.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: false, WorkspaceView(vm: vm))
        defer { window.close() }
        vm.terminalPanels.update(.init(host: nil, tab: shown.tab.id)) { $0.shown = true }

        /// The live PTY bound to `pane` in both the store and the persisted layout, once it is.
        func bound(_ pane: LeafPane, in tab: ShepherdCore.Tab) async -> SessionID? {
            guard let id = vm.sessions.liveSession(forPane: pane.id),
                  vm.state.tabs.first(where: { $0.id == tab.id })?.layout.leaf(withID: pane.id)?.sessionID == id,
                  vm.sessions.session(for: pane, in: tab).phase == .live,
                  let info = await app.server.sessionInfo(sessionID: id), info.isAlive, !info.command.contains("--mode") else { return nil }
            return id
        }
        try await eventuallyAsync("the shown tab's shell to respawn and bind") { await bound(shown.auxiliary[0], in: shown.tab) != nil }
        #expect(await bound(shown.auxiliary[0], in: shown.tab) != stale.shown, "a session that died with the last run is no binding")

        let dormant = vm.sessions.session(for: hidden.auxiliary[0], in: hidden.tab)
        #expect(dormant.isDormant && vm.sessions.liveSession(forPane: hidden.auxiliary[0].id) == nil, "a hidden tab spawns nothing")

        vm.selectAgent(hidden.agent.id)
        vm.terminalPanels.update(.init(host: nil, tab: hidden.tab.id)) { $0.shown = true }
        try await eventuallyAsync("the newly shown tab's shell to spawn and bind") { await bound(hidden.auxiliary[0], in: hidden.tab) != nil }
        #expect(!dormant.isDormant && dormant.hasTerminalModel)
        #expect(await bound(hidden.auxiliary[0], in: hidden.tab) != stale.hidden)
    }
}
