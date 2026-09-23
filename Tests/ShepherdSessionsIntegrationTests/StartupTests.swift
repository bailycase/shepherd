import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Every session died with the previous app run, so `start()` clears what state.json still
/// claims about them before anything is served — and it owns the socket safely.
@Suite("Server startup")
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

    @Test func aSecondServerRefusesToBindOverALiveSocket() throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let second = SessionServer(socketPath: h.socketPath, stateURL: h.dir.appendingPathComponent("other.json"))
        let error = #expect(throws: SessionServerError.self) { try second.start() }
        guard case .system("bind", EADDRINUSE)? = error else { Issue.record("expected EADDRINUSE, got \(String(describing: error))"); return }
        // The live server is undisturbed.
        #expect(throws: Never.self) { _ = try ExtensionClient(path: h.socketPath) }
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
