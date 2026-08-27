import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

/// End-to-end: a real RemoteHostClient against a real SessionServer over
/// loopback TCP, driving real PTY sessions. This is the remote pane loop the
/// MacBook-side GUI will sit on.
@Suite("Remote session streaming", .serialized)
struct RemoteSessionStreamTests {
    private struct Harness {
        let dir: URL
        let server: SessionServer
        let port: UInt16
        let token: String

        init() throws {
            dir = try makeScratchDirectory()
            server = SessionServer(
                socketPath: dir.appendingPathComponent("d.sock").path,
                stateURL: dir.appendingPathComponent("state.json")
            )
            try server.start()
            let tokenURL = dir.appendingPathComponent("remote-token")
            port = try server.startRemoteListener(port: 0, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func connect() async throws -> (RemoteHostClient, ShepherdState) {
            let client = RemoteHostClient()
            let state = try await client.connect(
                host: "127.0.0.1", port: port, token: token, clientName: "test"
            )
            return (client, state)
        }

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func attachStreamsReplayAndLiveOutput() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        // A session that prints a marker, then echoes stdin.
        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "echo REPLAY_MARKER; cat"],
            cols: 80,
            rows: 24
        ))

        // Let the marker land in the server-side screen before attaching, so
        // it arrives as replay (not live output).
        var sawMarkerOnScreen = false
        for _ in 0..<100 {
            if let lines = await h.server.screenText(sessionID: info.id),
               lines.contains(where: { $0.contains("REPLAY_MARKER") }) {
                sawMarkerOnScreen = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(sawMarkerOnScreen)

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        let received = Locked(Data())
        client.onOutput = { [received] sessionID, data in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
        }

        try await client.attach(sessionID: info.id, cols: 100, rows: 30)

        // Replay contains the marker.
        try await waitUntil { [received] in
            String(decoding: received.current, as: UTF8.self).contains("REPLAY_MARKER")
        }
        #expect(String(decoding: received.current, as: UTF8.self).contains("REPLAY_MARKER"))

        // Live loop: bytes written from the client come back via cat.
        client.write(sessionID: info.id, data: Data("hello-from-macbook\n".utf8))
        try await waitUntil { [received] in
            String(decoding: received.current, as: UTF8.self).contains("hello-from-macbook")
        }
        #expect(String(decoding: received.current, as: UTF8.self).contains("hello-from-macbook"))

        h.server.killSession(info.id)
    }

    @Test func resizeAppliesToThePty() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        // stty size prints "rows cols" for the PTY it runs on. Sleep first so
        // the resize (applied at attach) lands before stty samples it.
        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "sleep 1; stty size; cat"],
            cols: 80,
            rows: 24
        ))

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        let received = Locked(Data())
        client.onOutput = { [received] sessionID, data in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
        }
        try await client.attach(sessionID: info.id, cols: 123, rows: 41)

        try await waitUntil(timeout: .seconds(15)) { [received] in
            String(decoding: received.current, as: UTF8.self).contains("41 123")
        }
        #expect(String(decoding: received.current, as: UTF8.self).contains("41 123"))

        h.server.killSession(info.id)
    }

    @Test func exitIsDeliveredToAttachedClients() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "sleep 30"],
            cols: 80,
            rows: 24
        ))

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        let exited = Locked<(SessionID, Int32?)?>(nil)
        client.onSessionExited = { [exited] sessionID, code in
            exited.withValue { $0 = (sessionID, code) }
        }
        try await client.attach(sessionID: info.id, cols: 80, rows: 24)

        h.server.killSession(info.id)
        try await waitUntil { [exited] in exited.current != nil }
        #expect(exited.current?.0 == info.id)
    }

    @Test func detachStopsStreaming() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "cat"],
            cols: 80,
            rows: 24
        ))

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        let received = Locked(Data())
        client.onOutput = { [received] sessionID, data in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
        }
        try await client.attach(sessionID: info.id, cols: 80, rows: 24)

        client.write(sessionID: info.id, data: Data("before-detach\n".utf8))
        try await waitUntil { [received] in
            String(decoding: received.current, as: UTF8.self).contains("before-detach")
        }

        client.detach(sessionID: info.id)
        // Detach is fire-and-forget; give the server queue a beat to apply it
        // before writing more input (which still works — input is
        // attach-independent, like the local path).
        try await Task.sleep(for: .milliseconds(300))
        let baseline = received.current.count
        client.write(sessionID: info.id, data: Data("after-detach\n".utf8))
        try await Task.sleep(for: .seconds(1))
        #expect(received.current.count == baseline)

        h.server.killSession(info.id)
    }

    @Test func pasteDeliversBracketedBlockAndSubmit() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        // `cat -v` echoes control bytes visibly, so the bracketed-paste
        // markers are assertable as text.
        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "stty -echo; cat -v"],
            cols: 80,
            rows: 24
        ))

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        let received = Locked(Data())
        client.onOutput = { [received] sessionID, data in
            guard sessionID == info.id else { return }
            received.withValue { $0.append(data) }
        }
        try await client.attach(sessionID: info.id, cols: 80, rows: 24)

        try await client.paste(sessionID: info.id, text: "line one\nline two", submit: true)
        try await waitUntil { [received] in
            String(decoding: received.current, as: UTF8.self).contains("^[[201~")
        }
        let text = String(decoding: received.current, as: UTF8.self)
        // One bracketed block: open marker, both lines, close marker, then CR.
        #expect(text.contains("^[[200~"))
        #expect(text.contains("line one"))
        #expect(text.contains("line two"))
        #expect(text.contains("^[[201~"))

        // Paste to a dead session is a typed error (the ack contract).
        let exited = Locked(false)
        client.onSessionExited = { [exited] id, _ in
            if id == info.id { exited.withValue { $0 = true } }
        }
        h.server.killSession(info.id)
        try await waitUntil { [exited] in exited.current }
        await #expect(throws: RemoteHostClientError.self) {
            try await client.paste(sessionID: info.id, text: "late", submit: true)
        }
    }

    @Test func smallestViewportWinsAcrossViewers() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "cat"],
            cols: 80,
            rows: 24
        ))

        func ptySize() async -> String? {
            await h.server.sessionInfo(sessionID: info.id).map { "\($0.cols)x\($0.rows)" }
        }

        // Host GUI viewer at 200x60.
        h.server.reportLocalViewport(sessionID: info.id, cols: 200, rows: 60)

        // Phone attaches at 46x30: min wins → 46x30.
        let (phone, _) = try await h.connect()
        defer { phone.disconnect() }
        try await phone.attach(sessionID: info.id, cols: 46, rows: 30)
        var size: String?
        for _ in 0..<50 {
            size = await ptySize()
            if size == "46x30" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(size == "46x30")

        // Phone grows its report — still capped by nothing else below 200x60,
        // so min becomes 100x40.
        phone.resize(sessionID: info.id, cols: 100, rows: 40)
        for _ in 0..<50 {
            size = await ptySize()
            if size == "100x40" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(size == "100x40")

        // Phone detaches: the host viewer's full size comes back.
        phone.detach(sessionID: info.id)
        for _ in 0..<50 {
            size = await ptySize()
            if size == "200x60" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(size == "200x60")

        h.server.killSession(info.id)
    }

    @Test func hostPaneDoesNotClampRemoteViewer() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let info = try await h.server.createSession(params: CreateSessionParams(
            cwd: "/tmp",
            command: ["/bin/sh", "-c", "cat"],
            cols: 80,
            rows: 24
        ))
        h.server.reportLocalViewport(sessionID: info.id, cols: 80, rows: 24)

        let (client, _) = try await h.connect()
        defer { client.disconnect() }
        try await client.attach(sessionID: info.id, cols: 160, rows: 50)
        var size: (Int, Int)?
        for _ in 0..<50 {
            size = await h.server.sessionInfo(sessionID: info.id).map { ($0.cols, $0.rows) }
            if size?.0 == 160, size?.1 == 50 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(size?.0 == 160 && size?.1 == 50)

        client.detach(sessionID: info.id)
        client.resize(sessionID: info.id, cols: 200, rows: 70)
        for _ in 0..<50 {
            size = await h.server.sessionInfo(sessionID: info.id).map { ($0.cols, $0.rows) }
            if size?.0 == 80, size?.1 == 24 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(size?.0 == 80 && size?.1 == 24)
    }

    @Test func remotePaneMutationsRouteThroughHostHandler() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let agentID = AgentID()
        let anchor = PaneID()
        let opened = PaneID()
        let split = PaneNode.split(
            axis: .vertical,
            ratio: 0.5,
            first: .leaf(LeafPane(id: anchor, cwd: "/tmp")),
            second: .leaf(LeafPane(id: opened, cwd: "/tmp"))
        )
        let received = Locked<[PaneRequest]>([])
        h.server.onRemotePaneRequest = { request, respond in
            received.withValue { $0.append(request) }
            if case .open = request {
                respond(.opened(PaneInfo(id: opened, cwd: "/tmp", isAgentPane: false, isFocused: false, isAlive: true)))
            } else {
                respond(.ok)
            }
        }

        let (client, _) = try await h.connect()
        defer { client.disconnect() }
        #expect(try await client.openPane(agentID: agentID, relativeTo: anchor, axis: .vertical) == opened)
        try await client.resizePaneSplit(agentID: agentID, split: split, ratio: 0.7)
        try await client.closePane(agentID: agentID, paneID: opened)

        #expect(received.current == [
            .open(agentID: agentID, axis: .vertical, cwd: nil, relativeTo: anchor, command: nil),
            .resizeSplit(agentID: agentID, split: split, ratio: 0.7),
            .close(agentID: agentID, paneID: opened),
        ])
    }

    @Test func attachToUnknownSessionFails() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        await #expect(throws: RemoteHostClientError.self) {
            try await client.attach(sessionID: SessionID(), cols: 80, rows: 24)
        }
    }

    @Test func hostStopTearsDownTheClient() async throws {
        let h = try Harness()

        let (client, _) = try await h.connect()
        let dropped = Locked(false)
        client.onDisconnected = { [dropped] _ in dropped.withValue { $0 = true } }

        h.tearDown()
        try await waitUntil { [dropped] in dropped.current }
        #expect(dropped.current)
    }

    @Test func listDirBrowsesHostDirectories() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("beta"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("file.txt").path, contents: Data())

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        // Directories only (files excluded), sorted; hidden dirs included —
        // the client picker decides whether to show them (~/.pi is a valid
        // space).
        let listing = try await client.listDir(path: dir.path)
        #expect(listing.dirs == [".hidden", "alpha", "beta"])
        #expect(listing.parent == dir.deletingLastPathComponent().path)

        // Empty path resolves to the host home.
        let home = try await client.listDir(path: "")
        #expect(home.path == fm.homeDirectoryForCurrentUser.path)

        // Navigating down works off the returned path.
        let sub = try await client.listDir(path: listing.path + "/alpha")
        #expect(sub.dirs.isEmpty)
        #expect(sub.parent == listing.path)

        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.listDir(path: "/definitely/not/a/dir")
        }
    }

    @Test func remoteAddSpaceCreatesSpaceWithShellTab() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let (client, _) = try await h.connect()
        defer { client.disconnect() }

        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spaceID = try await client.addSpace(path: dir.path)
        let state = h.server.state
        #expect(state.spaces.map(\.id) == [spaceID])
        #expect(state.tabs.count { $0.spaceID == spaceID } == 1)

        // Duplicate and bogus paths are rejected with typed errors.
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.addSpace(path: dir.path)
        }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.addSpace(path: "/definitely/not/a/dir")
        }
    }

    @Test func remoteCreateAgentRoutesThroughHostHandler() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // The GUI's spawn flow, stubbed: record the request, mint an agent.
        let received = Locked<RemoteCreateAgentRequest?>(nil)
        let minted = AgentID()
        h.server.onRemoteCreateAgent = { [received] request, completion in
            received.withValue { $0 = request }
            completion(.success(minted))
        }

        let (client, _) = try await h.connect()
        defer { client.disconnect() }
        let spaceID = try await client.addSpace(path: dir.path)

        let agentID = try await client.createAgent(
            spaceID: spaceID,
            cwd: dir.path,
            model: "some/model",
            thinking: .high,
            initialPrompt: "hello"
        )
        #expect(agentID == minted)
        #expect(received.current?.spaceID == spaceID)
        #expect(received.current?.model == "some/model")
        #expect(received.current?.thinking == .high)
        #expect(received.current?.initialPrompt == "hello")

        // Unknown space is rejected before reaching the handler.
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.createAgent(
                spaceID: SpaceID(), cwd: nil, model: nil, thinking: nil, initialPrompt: nil
            )
        }
    }

    @Test func remoteCreateAgentWithoutHandlerIsRejected() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let (client, _) = try await h.connect()
        defer { client.disconnect() }
        let spaceID = try await client.addSpace(path: dir.path)

        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.createAgent(
                spaceID: spaceID, cwd: nil, model: nil, thinking: nil, initialPrompt: nil
            )
        }
    }

    @Test func clientSeesStatePushesFromHostMutations() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let (client, initial) = try await h.connect()
        defer { client.disconnect() }
        #expect(initial.spaces.isEmpty)

        let pushed = Locked<[ShepherdState]>([])
        client.onStateChanged = { [pushed] state in
            pushed.withValue { $0.append(state) }
        }

        let space = Space(name: "demo", path: "/tmp/demo")
        try await h.server.addSpace(space)

        try await waitUntil { [pushed] in
            pushed.current.last?.spaces.map(\.id) == [space.id]
        }
        #expect(pushed.current.last?.spaces.map(\.id) == [space.id])
    }
}
