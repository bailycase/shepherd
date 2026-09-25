import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A terminal pane a remote client keeps on screen while its host relaunches: the link it
/// attaches with (`RemoteTerminalLink`) against a real listener, as the iOS app drives it.
@Suite("Remote terminal across a host restart", .integrationTimeLimit)
struct RemoteTerminalRestartTests {
    /// The iOS app's view of one host session (`MobileTerminalSession`): attached while held, a
    /// refused attach asked again after the link's backoff, and dropped when the pane's session
    /// changes (the app keys the pane's view by its session).
    actor HeldTerminal {
        let session: SessionID
        private var link = RemoteTerminalLink()
        private var client: RemoteHostClient?
        private var retry: Task<Void, Never>?
        private(set) var refusals: [String] = []
        var phase: RemoteTerminalLink.Phase { link.phase }

        init(_ session: SessionID) { self.session = session }

        func hold(_ client: RemoteHostClient) {
            if self.client !== client { link.disconnected() }
            self.client = client
            perform(link.want(true))
            perform(link.noteGrid(cols: 80, rows: 24))
        }

        func release() {
            retry?.cancel()
            perform(link.want(false))
        }

        func send(_ text: String) {
            client?.write(sessionID: session, data: Data(text.utf8))
        }

        private func perform(_ commands: [RemoteTerminalLink.Command]) {
            guard let client else { return }
            for command in commands {
                switch command {
                case .attach(let cols, let rows):
                    let attempt = link.attempt
                    Task {
                        do {
                            _ = try await client.attach(sessionID: session, cols: cols, rows: rows)
                            attached(attempt)
                        } catch {
                            refused(error, attempt)
                        }
                    }
                case .resize(let cols, let rows): client.resize(sessionID: session, cols: cols, rows: rows)
                case .detach: client.detach(sessionID: session)
                }
            }
        }

        private func attached(_ attempt: Int) { link.attached(attempt: attempt) }

        private func refused(_ error: Error, _ attempt: Int) {
            let code = if case RemoteHostClientError.rejected(let code, _) = error { code } else { "\(error)" }
            refusals.append(code)
            guard let delay = link.attachFailed(code, attempt: attempt) else { return }
            retry?.cancel()
            retry = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                perform(link.retry(attempt: attempt))
            }
        }
    }

    private struct Seeded {
        let tab: TabID
        let pane: PaneID
    }

    /// An agent whose layout holds its thread and one terminal running `session`.
    private func seed(_ host: ScratchServer, session: SessionID) async throws -> Seeded {
        let space = Space(name: "demo", path: host.dir.path)
        var thread = LeafPane(cwd: space.path)
        let terminal = LeafPane(sessionID: session, cwd: space.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .split(axis: .horizontal, ratio: 0.5, first: .leaf(thread), second: .leaf(terminal)))
        let agent = Agent(name: "agent", spaceID: space.id, tabID: tab.id, paneID: thread.id)
        thread.agentID = agent.id
        var seeded = tab
        seeded.layout = seeded.layout.updatingLeaf(thread.id) { $0 = thread }
        try await host.seed(ShepherdState(spaces: [space], tabs: [seeded], agents: [agent]))
        return Seeded(tab: tab.id, pane: terminal.id)
    }

    private static func connect(port: UInt16, token: String, output: Locked<[SessionID: Data]>,
                                states: Locked<[ShepherdState]>) async throws -> RemoteHostClient {
        let client = RemoteHostClient()
        client.onOutput = { id, data in output.withValue { $0[id, default: Data()].append(data) } }
        client.onStateChanged = { state in states.withValue { $0.append(state) } }
        let state = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "held")
        states.withValue { $0.append(state) }
        return client
    }

    @Test func aHeldPaneReattachesToItsNewShellAfterTheHostRestarts() async throws {
        let first = try RemoteHost()
        var firstRunning = true
        defer { if firstRunning { first.stop() } }
        let dir = first.host.dir
        let tokenURL = dir.appendingPathComponent("remote-token")
        let before = try await first.host.shell("echo BEFORE_READY; cat")
        try await first.host.waitForScreen(before.id, toContain: "BEFORE_READY")
        let seeded = try await seed(first.host, session: before.id)

        let output = Locked<[SessionID: Data]>([:])
        let states = Locked<[ShepherdState]>([])
        let firstClient = try await Self.connect(port: first.port, token: first.token, output: output, states: states)
        let disconnected = Locked(false)
        firstClient.onDisconnected = { _ in disconnected.withValue { $0 = true } }
        let old = HeldTerminal(before.id)
        await old.hold(firstClient)
        try await eventually("the pane to attach") { await old.phase == .live }
        await old.send("typed-before\n")
        try await first.host.waitForScreen(before.id, toContain: "typed-before")

        // The host relaunches over its own state and listens on the same port with the same token.
        first.host.stop(keepFiles: true)
        firstRunning = false
        try await eventually("the client to see the host go") { disconnected.current }
        let second = try ScratchServer(dir: dir)
        defer { second.stop() }
        _ = try second.server.startRemoteListener(port: first.port, tokenURL: tokenURL)

        // Reconnected, the pane still names the old shell until the host respawns it: the attach
        // is refused, and asked again while the pane stays on screen.
        let client = try await Self.connect(port: first.port, token: first.token, output: output, states: states)
        defer { client.disconnect() }
        await old.hold(client)
        try await eventually("the refused attach to be asked again") {
            await old.refusals.filter { $0 == "no_such_session" }.count >= 2
        }

        // The host respawns the pane's shell under a new session; the client hears it pushed.
        let after = try await second.shell("echo AFTER_READY; cat")
        try await second.server.updatePaneSession(tabID: seeded.tab, paneID: seeded.pane, sessionID: after.id)
        try await eventually("the new session to reach the client") {
            states.current.last?.tabs.first { $0.id == seeded.tab }?.layout.leaf(withID: seeded.pane)?.sessionID == after.id
        }

        // A pane with a new session is a new view: the old one lets go, the new one attaches.
        await old.release()
        let new = HeldTerminal(after.id)
        await new.hold(client)
        try await eventually("the new shell to attach") { await new.phase == .live }
        #expect(await new.refusals.isEmpty)
        try await eventually("the new shell's replay") {
            String(decoding: output.current[after.id] ?? Data(), as: UTF8.self).contains("AFTER_READY")
        }
        await new.send("typed-after\n")
        try await second.waitForScreen(after.id, toContain: "typed-after")
        try await eventually("the echo to stream back") {
            String(decoding: output.current[after.id] ?? Data(), as: UTF8.self).contains("typed-after")
        }
    }

    @Test func aHeldPaneReattachesToTheSameShellWhenOnlyTheListenerRestarts() async throws {
        let r = try RemoteHost()
        defer { r.stop() }
        let shell = try await r.host.shell("echo READY; cat")
        try await r.host.waitForScreen(shell.id, toContain: "READY")
        let output = Locked<[SessionID: Data]>([:])
        let states = Locked<[ShepherdState]>([])
        let firstClient = try await Self.connect(port: r.port, token: r.token, output: output, states: states)
        let disconnected = Locked(false)
        firstClient.onDisconnected = { _ in disconnected.withValue { $0 = true } }
        let held = HeldTerminal(shell.id)
        await held.hold(firstClient)
        try await eventually("the pane to attach") { await held.phase == .live }

        r.server.stopRemoteListener()
        try await eventually("the client to see the listener go") { disconnected.current }
        _ = try r.server.startRemoteListener(port: r.port, tokenURL: r.host.dir.appendingPathComponent("remote-token"))

        let client = try await Self.connect(port: r.port, token: r.token, output: output, states: states)
        defer { client.disconnect() }
        await held.hold(client)
        try await eventually("the pane to attach again") { await held.phase == .live }
        #expect(await held.refusals.isEmpty)
        await held.send("typed-again\n")
        try await r.host.waitForScreen(shell.id, toContain: "typed-again")
    }
}
