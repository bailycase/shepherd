import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// `RemoteAgentQuery.terminals`: what each terminal pane of an agent's layout runs, answered by
/// the server itself (the terminal panel's tab states on a client).
@Suite("Remote terminal activity", .integrationTimeLimit)
struct RemoteTerminalActivityTests {
    /// An agent whose layout holds its thread and two shells: one at rest, one running a command
    /// in its own process group, as a shell with job control runs one.
    private func seedAgent(_ r: RemoteHost, idleScript: String = "echo IDLE_READY; cat") async throws
        -> (agent: AgentID, idle: SessionInfo, busy: SessionInfo, panes: [PaneID]) {
        let idle = try await r.host.shell(idleScript)
        let busy = try await r.host.shell("set -m; sleep 30; true")
        try await r.host.waitForScreen(idle.id, toContain: "IDLE_READY")
        let space = Space(name: "demo", path: r.host.dir.path)
        let thread = LeafPane(cwd: space.path)
        let idlePane = LeafPane(sessionID: idle.id, cwd: space.path)
        let busyPane = LeafPane(sessionID: busy.id, cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .horizontal, ratio: 0.5, first: .leaf(thread),
                                                                    second: .split(axis: .vertical, ratio: 0.5, first: .leaf(idlePane), second: .leaf(busyPane))))
        let agent = Agent(name: "agent", spaceID: space.id, tabID: tab.id, paneID: thread.id)
        var threadWithAgent = thread
        threadWithAgent.agentID = agent.id
        var seeded = tab
        seeded.layout = seeded.layout.updatingLeaf(thread.id) { $0 = threadWithAgent }
        try await r.host.seed(ShepherdState(spaces: [space], tabs: [seeded], agents: [agent]))
        return (agent.id, idle, busy, [idlePane.id, busyPane.id])
    }

    @Test func theHostListsAnAgentsTerminalsWithWhatRunsInEach() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let seeded = try await seedAgent(r)
        let client = try await r.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.terminalActivityCapability))

        var terminals: [RemoteTerminalActivity] = []
        try await eventually("the busy shell to report its command") {
            guard case .terminals(let rows) = try await client.agentQuery(agentID: seeded.agent, query: .terminals) else { return false }
            terminals = rows
            return rows.count == 2 && rows[1].command?.contains("sleep 30") == true
        }
        // The thread's pane is never a terminal; the rest come in layout order.
        #expect(terminals.map(\.paneID) == seeded.panes)
        #expect(terminals.map(\.sessionID) == [seeded.idle.id, seeded.busy.id])
        #expect(terminals[0].command == nil && !terminals[0].isRunning)
        #expect(terminals[1].isRunning && terminals[1].process == "sleep")
        #expect(terminals[0].outputSequence > 0)
    }

    @Test func outputAdvancesATerminalsSequence() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let seeded = try await seedAgent(r)
        let before = await r.server.terminalActivity(agentID: seeded.agent)
        let start = try #require(before.first { $0.sessionID == seeded.idle.id }).outputSequence
        r.server.write(sessionID: seeded.idle.id, data: Data("more-output\n".utf8))
        try await r.host.waitForScreen(seeded.idle.id, toContain: "more-output")
        try await eventually("the sequence to move") {
            await r.server.terminalActivity(agentID: seeded.agent).first { $0.sessionID == seeded.idle.id }!.outputSequence > start
        }
    }

    /// A shell answers a new size by drawing its prompt again: that output moves the output
    /// sequence (the attach watermark) but is not news, so no tab gets a dot for a resize. A
    /// command printing afterwards is news.
    @Test func aResizeRedrawIsNotNewsButACommandsOutputIs() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        // Redraws on SIGWINCH as zsh's prompt does; prints ticks once `go` exists, as a command would.
        let seeded = try await seedAgent(r, idleScript: "trap 'echo REDRAW' WINCH; echo IDLE_READY; "
            + "while :; do if [ -f go ]; then echo tick; fi; sleep 0.05; done")
        func idle() async throws -> RemoteTerminalActivity {
            try #require(await r.server.terminalActivity(agentID: seeded.agent).first { $0.sessionID == seeded.idle.id })
        }
        let before = try await idle()
        r.server.resize(sessionID: seeded.idle.id, cols: 100, rows: 30)
        try await r.host.waitForScreen(seeded.idle.id, toContain: "REDRAW")
        let redrawn = try await idle()
        #expect(redrawn.outputSequence > before.outputSequence)
        #expect(redrawn.newsSequence == before.newsSequence)

        FileManager.default.createFile(atPath: r.host.dir.appendingPathComponent("go").path, contents: nil)
        try await eventually("a command's output to be news") {
            try await idle().news > redrawn.news
        }
    }

    @Test func anUnknownAgentIsRefused() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let client = try await r.typed()
        defer { client.disconnect() }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.agentQuery(agentID: AgentID(), query: .terminals)
        }
        #expect(await r.server.terminalActivity(agentID: AgentID()).isEmpty)
    }
}
