import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// #554 H6: a dropped link to This Mac's host used to fail and drop every attached terminal
/// (`connection.panes.removeAll()`), so the app's terminals reset. Now each keeps its surface and
/// attaches again in place once the store reconnects.
@Suite("This Mac's terminals across a reconnect", .mainActorExclusive)
@MainActor
struct ThisMacTerminalReconnectTests {
    @Test func aDroppedLinkReattachesTheSamePane() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let info = try await host.server.createSession(params: CreateSessionParams(cwd: host.dir.path, command: ["/bin/cat"], cols: 80, rows: 24))
        let space = Fixture.space("acme-web", path: host.dir.path)
        var agent = Fixture.agent("web", in: space, auxiliary: 1)
        agent.auxiliary[0].sessionID = info.id
        agent.tab.layout = .split(axis: .vertical, ratio: 0.5, first: .leaf(agent.piPane), second: .leaf(agent.auxiliary[0]))
        try await host.server.putState(Fixture.state(spaces: [space], agents: [agent]))
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        let hosts = RemoteHostStore(defaults: ScratchDefaults(), childRefreshInterval: .milliseconds(200))
        let connection = hosts.addLocalHost(name: "This Mac", socket: socket, token: token)
        defer { hosts.removeHost(id: connection.id) }
        try await eventuallyOnMain("the app to connect") { connection.phase == .connected && !connection.state.tabs.isEmpty }
        let pane = try #require(hosts.paneSession(connection: connection, sessionID: info.id))
        pane.noteGrid(cols: 100, rows: 30)
        try await eventuallyOnMain("the terminal to attach") { pane.phase == .live }
        let first = connection.transportID

        host.server.dropLocalClients()
        try await eventuallyOnMain("the store to reconnect") { connection.phase == .connected && connection.transportID != first }
        try await eventuallyOnMain("the same pane to attach again") { pane.phase == .live }
        #expect(connection.pane(for: info.id) === pane, "kept in place, not dropped and recreated")
    }
}
