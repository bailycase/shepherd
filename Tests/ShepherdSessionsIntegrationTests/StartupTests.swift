import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Every session died with the previous app run, so `start()` clears what state.json still
/// claims about them before anything is served — and it owns the socket safely.
@Suite("Server startup", .integrationTimeLimit)
struct StartupTests {
    /// Persists `state` through one server, stops it, and starts a fresh server on the same files.
    private func relaunch(with state: ShepherdState) async throws -> ScratchServer {
        let first = try ScratchServer.fresh()
        try await first.server.putState(state)
        first.stop(keepFiles: true)
        return try ScratchServer(dir: first.dir)
    }

    @Test func staleStatusesResetToIdle() async throws {
        let space = Fixture.space()
        let working = Fixture.agent(in: space, status: .working)
        let blocked = Fixture.agent(in: space, status: .blocked)
        let h = try await relaunch(with: Fixture.workspace([working, blocked], space: space))
        defer { h.stop() }

        #expect(h.server.state.agents.map(\.status) == [.idle, .idle])
        #expect(try h.persisted().agents.map(\.status) == [.idle, .idle])
    }

    /// A status only ever written along with another change still comes back idle.
    @Test func aStatusWrittenAlongAnotherChangeResetsToIdle() async throws {
        let first = try ScratchServer.fresh()
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        try await first.seed(Fixture.workspace([worker], space: space))
        let client = try ExtensionClient(path: first.socketPath)
        try client.send(.setAgentStatus(agentID: worker.agent.id, status: .working))
        try await eventually("the status to apply") { first.server.state.agents.first?.status == .working }
        try await first.server.addSpace(Fixture.space("added"))
        #expect(try first.persisted().agents.first?.status == .working)
        client.closeConnection()
        first.stop(keepFiles: true)

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        #expect(h.server.state.agents.first?.status == .idle)
        #expect(try h.persisted().agents.first?.status == .idle)
    }

    @Test func utilityTerminalsArePurged() async throws {
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        let utility = Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: space.path)), inspectorFor: worker.agent.id)
        let h = try await relaunch(with: ShepherdState(spaces: [space], tabs: [worker.tab, utility], agents: [worker.agent]))
        defer { h.stop() }

        #expect(h.server.state.tabs == [worker.tab])
    }

    /// A review pane is session-scoped UI; a lone review leaf becomes a plain pane so its layout stays usable.
    @Test func reviewLeavesArePurgedAndALoneReviewRootIsKept() async throws {
        let space = Fixture.space()
        let review = LeafPane(cwd: space.path, isReview: true)
        let kept = LeafPane(cwd: space.path)
        let split = Tab(spaceID: space.id, order: 0, layout: .split(axis: .vertical, ratio: 0.5, first: .leaf(review), second: .leaf(kept)))
        let loneReview = LeafPane(cwd: space.path, isReview: true)
        let lone = Tab(spaceID: space.id, order: 1, layout: .leaf(loneReview))
        let agents = [Agent(name: "a", spaceID: space.id, tabID: split.id), Agent(name: "b", spaceID: space.id, tabID: lone.id)]
        let h = try await relaunch(with: ShepherdState(spaces: [space], tabs: [split, lone], agents: agents))
        defer { h.stop() }

        let tabs = h.server.state.tabs
        #expect(tabs.first?.layout == .leaf(kept))
        #expect(tabs.last?.layout == .leaf(LeafPane(id: loneReview.id, cwd: space.path)))
    }

    /// Terminals are tabs only: a layout an older build split beside the thread (Split right, Split
    /// down, nested) loads as one tab per terminal, oldest first, each keeping its folder and
    /// title, with the thread first; the flattened layout is written back.
    @Test func splitTerminalLayoutsFlattenIntoOneTabEach() async throws {
        let space = Fixture.space()
        let built = LeafPane(cwd: "/tmp/demo/api", title: "build")
        let logs = LeafPane(cwd: "/tmp/demo/logs")
        let tests = LeafPane(cwd: "/tmp/demo/tests")
        let watch = LeafPane(cwd: "/tmp/demo/web")
        let worker = Fixture.agent(in: space)
        let thread = try #require(worker.tab.layout.leaves.first)
        // Tab one splits into a column of three (a pane split right, one of those split down);
        // tab two is a lone terminal opened later.
        let firstTab = PaneNode.split(axis: .vertical, ratio: 0.5, first: .leaf(built),
                                      second: .split(axis: .horizontal, ratio: 0.4, first: .leaf(logs), second: .leaf(tests)))
        let layout = PaneNode.split(axis: .horizontal, ratio: 0.5,
                                    first: .split(axis: .horizontal, ratio: 0.5, first: .leaf(thread), second: .leaf(watch)),
                                    second: firstTab)
        var tab = worker.tab
        tab.layout = layout
        let h = try await relaunch(with: ShepherdState(spaces: [space], tabs: [tab], agents: [worker.agent]))
        defer { h.stop() }

        let flat = try #require(h.server.state.tabs.first?.layout)
        #expect(flat.terminals(besideThread: thread.id).map(\.id) == [built.id, logs.id, tests.id, watch.id])
        #expect(!flat.hasSplitTerminals(besideThread: thread.id))
        #expect(flat.leaf(withID: built.id)?.title == "build")
        #expect(flat.leaf(withID: logs.id)?.cwd == "/tmp/demo/logs")
        #expect(flat.firstLeaf.id == thread.id)
        #expect(h.server.state.agents == [worker.agent])
        #expect(try h.persisted().tabs.first?.layout == flat, "the flat layout is written back")
    }

    /// An agent that remote clients drive is migrated the same way, so a client of the relaunched
    /// host is sent a layout of tabs and never a split.
    @Test func aRemoteClientOfAMigratedHostIsSentFlatTabs() async throws {
        let space = Fixture.space()
        let first = LeafPane(cwd: "/tmp/demo")
        let second = LeafPane(cwd: "/tmp/demo")
        let worker = Fixture.agent(in: space)
        let thread = try #require(worker.tab.layout.leaves.first)
        var tab = worker.tab
        // The thread on the far side of the root: a column of two terminals beside it.
        tab.layout = .split(axis: .vertical, ratio: 0.7,
                            first: .split(axis: .vertical, ratio: 0.5, first: .leaf(first), second: .leaf(second)),
                            second: .leaf(thread))
        let h = try await relaunch(with: ShepherdState(spaces: [space], tabs: [tab], agents: [worker.agent]))
        defer { h.stop() }
        let tokenURL = h.dir.appendingPathComponent("remote-token")
        let port = try h.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        let sent = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "typed")
        defer { client.disconnect() }

        let layout = try #require(sent.tabs.first?.layout)
        #expect(layout.terminals(besideThread: thread.id).map(\.id) == [first.id, second.id])
        #expect(!layout.hasSplitTerminals(besideThread: thread.id))
        #expect(TerminalPanel.tabs(in: layout, thread: thread.id).map(\.id) == [first.id, second.id])
    }

    /// Layouts of single-terminal tabs, and a thread with no terminals, are left exactly alone.
    @Test func layoutsOfSingleTerminalTabsAreNotRewritten() async throws {
        let space = Fixture.space()
        let worker = Fixture.agent(in: space)
        let thread = try #require(worker.tab.layout.leaves.first)
        let terminal = LeafPane(cwd: "/tmp/demo")
        var tab = worker.tab
        tab.layout = .split(axis: .horizontal, ratio: 0.7, first: .leaf(thread), second: .leaf(terminal))
        let first = try ScratchServer.fresh()
        try await first.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [worker.agent]))
        first.stop(keepFiles: true)
        let before = try FileManager.default.attributesOfItem(atPath: first.stateURL.path)[.systemFileNumber] as? NSNumber

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let after = try FileManager.default.attributesOfItem(atPath: h.stateURL.path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
        #expect(h.server.state.tabs.first?.layout == tab.layout, "ratio and axis stay as they were")
    }

    /// Shells were removed: older files' global shells and space shell workspaces are dropped.
    @Test func globalShellsAndSpaceShellWorkspacesAreDropped() async throws {
        let space = Fixture.space()
        let spaceShell = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        let worker = Fixture.agent(in: space)
        // A global shell as older builds wrote it, shell-only keys included.
        let global = try JSONDecoder().decode(Tab.self, from: Data("""
        {"id":"\(TabID().rawValue)","order":0,"name":"~","nameIsFinal":true,"restoreCommand":"htop",
         "layout":{"type":"leaf","pane":{"id":"\(PaneID().rawValue)","cwd":"/tmp"}}}
        """.utf8))
        let h = try await relaunch(with: ShepherdState(spaces: [space], tabs: [spaceShell, worker.tab, global], agents: [worker.agent]))
        defer { h.stop() }

        #expect(h.server.state.tabs == [worker.tab])
        #expect(h.server.state.agents == [worker.agent])
    }

    @Test func aCleanStateFileIsNotRewritten() async throws {
        let space = Fixture.space()
        let first = try ScratchServer.fresh()
        try await first.server.putState(Fixture.workspace([Fixture.agent(in: space)], space: space))
        first.stop(keepFiles: true)
        let before = try FileManager.default.attributesOfItem(atPath: first.stateURL.path)[.systemFileNumber] as? NSNumber

        let h = try ScratchServer(dir: first.dir)
        defer { h.stop() }
        let after = try FileManager.default.attributesOfItem(atPath: h.stateURL.path)[.systemFileNumber] as? NSNumber
        #expect(before == after)
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty)
    }

    // MARK: - The socket

    @Test func theSupportDirectoryAndSocketAreOwnerOnly() throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let mode = { (path: String) in
            ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        }
        #expect(mode(h.dir.path) == 0o700)
        #expect(mode(h.socketPath) == 0o600)
    }

    @Test func aSecondServerRefusesWithoutChangingTheLiveWorkspace() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let space = Fixture.space()
        let worker = Fixture.agent(in: space, status: .working)
        var state = Fixture.workspace([worker], space: space)
        state.automations = [Automation(name: "Live run", prompt: "work", cwd: space.path, agentID: worker.agent.id)]
        try await h.server.putState(state)
        let logURL = h.dir.appendingPathComponent("automation-runs.json")
        try await eventually("the live run to be saved") { FileManager.default.fileExists(atPath: logURL.path) }
        let stateBytes = try Data(contentsOf: h.stateURL)
        let logBytes = try Data(contentsOf: logURL)
        let pendingImport = h.dir.appendingPathComponent("designs/.import-live/marker")
        try FileManager.default.createDirectory(at: pendingImport.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("in progress".utf8).write(to: pendingImport)
        let second = SessionServer(socketPath: h.socketPath, stateURL: h.stateURL)
        defer { second.stop() }
        let error = #expect(throws: SessionServerError.self) { try second.start() }
        guard case .system("bind", EADDRINUSE)? = error else { Issue.record("expected EADDRINUSE, got \(String(describing: error))"); return }
        await #expect(throws: SessionServerError.self) { try await second.addSpace(Fixture.space("refused")) }
        for runtime in [SessionRuntime.pty, .rpc] {
            await #expect(throws: SessionServerError.self) {
                _ = try await second.createSession(params: CreateSessionParams(
                    cwd: h.dir.path, command: ["/bin/sh", "-c", "touch should-not-run"], runtime: runtime))
            }
        }
        #expect(throws: SessionServerError.self) {
            _ = try second.startRemoteListener(port: 0, tokenURL: h.dir.appendingPathComponent("rejected-token"))
        }
        second.stop() // Flushes any accidental deferred writes too.
        #expect(try Data(contentsOf: h.stateURL) == stateBytes)
        #expect(try Data(contentsOf: logURL) == logBytes)
        #expect(try Data(contentsOf: pendingImport) == Data("in progress".utf8))
        #expect(h.server.state == state)
        #expect(await second.listSessions().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: h.dir.appendingPathComponent("should-not-run").path))
        #expect(throws: Never.self) { _ = try ExtensionClient(path: h.socketPath) }
    }

    @Test func ownershipAlsoProtectsTheStateWithADifferentSocketAndBeforeQuarantine() throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let invalid = Data("invalid state".utf8)
        try invalid.write(to: h.stateURL)
        let second = SessionServer(socketPath: h.dir.appendingPathComponent("other.sock").path, stateURL: h.stateURL)
        defer { second.stop() }
        #expect(try Data(contentsOf: h.stateURL) == invalid)
        #expect(throws: SessionServerError.self) { try second.start() }
        second.stop()
        #expect(try Data(contentsOf: h.stateURL) == invalid)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: h.dir.path)).contains { $0.contains(".corrupt-") })
    }

    @Test func retryingStartupReloadsStateAfterTheOwnerStops() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let second = SessionServer(socketPath: h.socketPath, stateURL: h.stateURL)
        defer { second.stop() }
        #expect(throws: SessionServerError.self) { try second.start() }
        let space = Fixture.space("saved after refusal")
        try await h.server.addSpace(space)
        h.server.stop()
        try second.start()
        #expect(second.state.spaces == [space])
        try second.start() // An idempotent start cannot reconcile a live server again.
        #expect(second.state.spaces == [space])
    }

    @Test func aLiveSocketStillRefusesAnOwnerUsingAnotherStateDirectory() throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let other = try makeScratchDirectory("owner")
        defer { try? FileManager.default.removeItem(at: other) }
        let second = SessionServer(socketPath: h.socketPath, stateURL: other.appendingPathComponent("state.json"))
        defer { second.stop() }
        #expect(throws: SessionServerError.self) { try second.start() }
        second.stop()
        #expect(throws: Never.self) { _ = try ExtensionClient(path: h.socketPath) }
        // Bind failure releases the lock, so another server can use the second directory.
        let retry = SessionServer(socketPath: other.appendingPathComponent("s.sock").path,
                                  stateURL: other.appendingPathComponent("state.json"))
        defer { retry.stop() }
        try retry.start()
    }

    @Test func aStaleSocketFileIsReplaced() throws {
        let dir = try makeScratchDirectory("stale")
        let path = dir.appendingPathComponent("s.sock").path
        // A bound-then-abandoned socket: the file exists, nobody listens.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try SessionServer.socketAddress(for: path)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))

        let h = try ScratchServer(dir: dir)
        defer { h.stop() }
        #expect(throws: Never.self) { _ = try ExtensionClient(path: path) }
    }

    @Test func stopRemovesTheSocket() throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.stop()
        #expect(!FileManager.default.fileExists(atPath: h.socketPath))
    }
}
