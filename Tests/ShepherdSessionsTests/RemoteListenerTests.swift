import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

/// Raw POSIX TCP NDJSON client mirroring what a remote Shepherd will do:
/// connect to the host's listener, hello with a token, issue id-correlated
/// requests, and read replies plus pushed state broadcasts.
private final class RemoteClient {
    private let fd: Int32
    private var closed = false
    private var readBuffer = Data()

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSocketError(message: "socket failed: errno \(errno)") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard r == 0 else {
            let err = errno
            close(fd)
            throw TestSocketError(message: "connect failed: errno \(err)")
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    deinit { closeConnection() }

    func closeConnection() {
        if !closed {
            closed = true
            close(fd)
        }
    }

    func send(_ request: RemoteRequest) throws {
        let data = try NDJSON.encode(request)
        let deadline = ContinuousClock.now + .seconds(10)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                guard ContinuousClock.now < deadline else {
                    throw TestSocketError(message: "timed out writing to socket")
                }
                let n = write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(2000)
                    continue
                }
                throw TestSocketError(message: "write failed: errno \(errno)")
            }
        }
    }

    func readReply(timeout: Duration = .seconds(10)) throws -> RemoteReply {
        let deadline = ContinuousClock.now + timeout
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while ContinuousClock.now < deadline {
            if let nl = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = readBuffer[readBuffer.startIndex..<nl]
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return try NDJSON.decode(RemoteReply.self, from: Data(line))
            }
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                readBuffer.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                throw TestSocketError(message: "socket closed while awaiting reply")
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(5000)
            } else {
                throw TestSocketError(message: "read failed: errno \(errno)")
            }
        }
        throw TestSocketError(message: "timed out awaiting reply")
    }

    /// True when the host closes the connection (an auth rejection).
    func waitForDisconnect(timeout: Duration = .seconds(10)) throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while ContinuousClock.now < deadline {
            let n = read(fd, &buf, buf.count)
            if n == 0 { return true }
            if n > 0 {
                readBuffer.append(contentsOf: buf[0..<n])
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(5000)
                continue
            }
            // ECONNRESET after the host closes also counts as disconnected.
            return true
        }
        return false
    }
}

@Suite("Remote listener", .serialized)
struct RemoteListenerTests {
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

        func tearDown() {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test func uploadsAreChunkedPrivateAndConnectionOwned() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let session = try await h.server.createSession(params: .init(cwd: h.dir.path, command: ["/bin/cat"], cols: 80, rows: 24))
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: h.port, token: h.token, clientName: "upload")
        defer { client.disconnect() }
        let source = h.dir.appendingPathComponent("source.bin")
        let bytes = Data(repeating: 42, count: RemoteProtocol.uploadChunkBytes + 31)
        try bytes.write(to: source)
        let drops = h.dir.appendingPathComponent("remote-drops")
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
        let expired = drops.appendingPathComponent("expired")
        try Data([1]).write(to: expired)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: expired.path)
        let path = try await client.upload(file: source, sessionID: session.id)
        #expect(!FileManager.default.fileExists(atPath: expired.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(path.hasPrefix(h.dir.appendingPathComponent("remote-drops").path + "/"))
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(try Data(contentsOf: source) == bytes)
        let raw = try RemoteClient(port: h.port)
        try raw.send(.hello(id: 1, token: h.token, clientName: "partial", protocolVersion: RemoteProtocol.version))
        _ = try raw.readReply()
        try raw.send(.upload(id: 2, action: .begin(sessionID: session.id, name: "../escape", size: 1)))
        guard case .error = try raw.readReply() else { Issue.record("Traversal accepted"); return }
        try raw.send(.upload(id: 3, action: .begin(sessionID: session.id, name: "too-large", size: RemoteProtocol.uploadMaxBytes + 1)))
        guard case .error = try raw.readReply() else { Issue.record("Oversize accepted"); return }
        try raw.send(.upload(id: 4, action: .begin(sessionID: session.id, name: "partial", size: 3)))
        guard case .uploadResult(_, .ready(let id)) = try raw.readReply() else { Issue.record("Missing upload id"); return }
        try raw.send(.upload(id: 40, action: .begin(sessionID: session.id, name: "second", size: 1)))
        guard case .error = try raw.readReply() else { Issue.record("Overlapping upload accepted"); return }
        try raw.send(.upload(id: 41, action: .chunk(uploadID: UUID(), data: Data([9]))))
        guard case .error = try raw.readReply() else { Issue.record("Unknown chunk accepted"); return }
        try raw.send(.upload(id: 42, action: .finish(uploadID: UUID())))
        guard case .error = try raw.readReply() else { Issue.record("Unknown finish accepted"); return }
        try raw.send(.upload(id: 43, action: .chunk(uploadID: id, data: Data([1, 2, 3]))))
        guard case .ok = try raw.readReply() else { Issue.record("Original upload was lost"); return }
        try raw.send(.upload(id: 44, action: .finish(uploadID: id)))
        guard case .uploadResult(_, .complete(let preservedPath)) = try raw.readReply() else { Issue.record("Original upload could not finish"); return }
        #expect(try Data(contentsOf: URL(fileURLWithPath: preservedPath)) == Data([1, 2, 3]))
        try raw.send(.upload(id: 45, action: .begin(sessionID: session.id, name: "partial", size: 3)))
        guard case .uploadResult(_, .ready(let id)) = try raw.readReply() else { Issue.record("Missing second upload id"); return }
        let intruder = try RemoteClient(port: h.port)
        try intruder.send(.hello(id: 1, token: h.token, clientName: "other", protocolVersion: RemoteProtocol.version))
        _ = try intruder.readReply()
        try intruder.send(.upload(id: 2, action: .chunk(uploadID: id, data: Data([1]))))
        guard case .error = try intruder.readReply() else { Issue.record("Cross-connection chunk accepted"); return }
        try raw.send(.upload(id: 5, action: .chunk(uploadID: id, data: Data([1]))))
        _ = try raw.readReply()
        raw.closeConnection()
        let partial = h.dir.appendingPathComponent("remote-drops/\(id.uuidString)-partial")
        try await waitUntil { !FileManager.default.fileExists(atPath: partial.path) }
        #expect(FileManager.default.fileExists(atPath: path))
        try intruder.send(.upload(id: 3, action: .begin(sessionID: session.id, name: "incomplete", size: 2)))
        guard case .uploadResult(_, .ready(let incomplete)) = try intruder.readReply() else { Issue.record("Missing id"); return }
        try intruder.send(.upload(id: 4, action: .finish(uploadID: incomplete)))
        guard case .error = try intruder.readReply() else { Issue.record("Incomplete upload accepted"); return }
        #expect(!FileManager.default.fileExists(atPath: drops.appendingPathComponent("\(incomplete.uuidString)-incomplete").path))
        try intruder.send(.upload(id: 5, action: .begin(sessionID: session.id, name: "overflow", size: 1)))
        guard case .uploadResult(_, .ready(let overflow)) = try intruder.readReply() else { Issue.record("Missing id"); return }
        try intruder.send(.upload(id: 6, action: .chunk(uploadID: overflow, data: Data([1, 2]))))
        guard case .error = try intruder.readReply() else { Issue.record("Declared size overrun accepted"); return }
    }

    @Test func creationChoicesReachHostUnchanged() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let space = Space(name: "host", path: "/host/repo")
        try await h.server.addSpace(space)
        h.server.onRemoteCreationOptions = { spaceID, cwd, fetch, completion in
            #expect(spaceID == space.id)
            #expect(cwd == "/host/checkout")
            #expect(fetch == false)
            completion(.success(.init(base: "origin/release", note: "cached", fetchFirst: false, model: "host/model", thinking: .high)))
        }
        let created = AgentID()
        h.server.onRemoteCreateAgent = { request, completion in
            #expect(request.worktreeBase == "origin/release")
            #expect(request.worktreeFetchFirst == false)
            #expect(request.worktreeBranch == "worktree/test")
            completion(.success(created))
        }
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: h.port, token: h.token, clientName: "create")
        defer { client.disconnect() }
        let options = try await client.creationOptions(spaceID: space.id, cwd: "/host/checkout", fetchFirst: false)
        #expect(options.base == "origin/release")
        #expect(options.thinking == .high)
        #expect(try await client.createAgent(spaceID: space.id, cwd: "/host/checkout", model: nil, thinking: nil, initialPrompt: nil, worktreeBranch: "worktree/test", worktreeBase: options.base, worktreeFetchFirst: options.fetchFirst) == created)
    }

    @Test func delayedAgentResultDoesNotReachAReplacementConnection() async throws {
        let h = try Harness()
        defer { h.tearDown() }
        let space = Space(name: "test", path: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: "/tmp")))
        let agent = Agent(name: "agent", spaceID: space.id, tabID: tab.id)
        try await h.server.putState(ShepherdState(spaces: [space], tabs: [tab], agents: [agent]))
        let callbacks = Locked<[(Result<Void, RemoteCreateAgentError>) -> Void]>([])
        h.server.onRemoteAgentAction = { _, _, completion in callbacks.withValue { $0.append(completion) } }
        let first = try RemoteClient(port: h.port)
        try first.send(.hello(id: 1, token: h.token, clientName: "first", protocolVersion: RemoteProtocol.version))
        _ = try first.readReply()
        try first.send(.agentAction(id: 77, agentID: agent.id, action: .rename(name: "private result")))
        try await waitUntil { callbacks.current.count == 1 }
        first.closeConnection()
        try await Task.sleep(for: .milliseconds(100))
        let second = try RemoteClient(port: h.port)
        try second.send(.hello(id: 1, token: h.token, clientName: "replacement", protocolVersion: RemoteProtocol.version))
        _ = try second.readReply()
        callbacks.current[0](.failure(RemoteCreateAgentError("first client's result")))
        #expect(throws: (any Error).self) { _ = try second.readReply(timeout: .milliseconds(300)) }
        try second.send(.stateFetch(id: 2))
        guard case .state(let id, _) = try second.readReply() else { Issue.record("Expected replacement state reply"); return }
        #expect(id == 2)
    }

    @Test func tokenIsGeneratedOnceWithOwnerOnlyPermissions() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("remote-token")

        let first = try SessionServer.loadOrCreateRemoteToken(at: url)
        #expect(first.count == 64)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        // A second load returns the same token, not a fresh one.
        #expect(try SessionServer.loadOrCreateRemoteToken(at: url) == first)
    }

    @Test func helloWithGoodTokenServesState() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let space = Space(name: "demo", path: "/tmp/demo")
        try await h.server.addSpace(space)

        let client = try RemoteClient(port: h.port)
        try client.send(.hello(id: 1, token: h.token, clientName: "test", protocolVersion: RemoteProtocol.version))
        guard case .helloOk(let id, let version, let capabilities) = try client.readReply() else {
            throw TestSocketError(message: "expected helloOk")
        }
        #expect(id == 1)
        #expect(version == RemoteProtocol.version)
        #expect(capabilities.contains(RemoteProtocol.pasteCapability))
        #expect(capabilities.contains(RemoteProtocol.paneControlCapability))

        try client.send(.stateFetch(id: 2))
        guard case .state(let stateID, let state) = try client.readReply() else {
            throw TestSocketError(message: "expected state")
        }
        #expect(stateID == 2)
        #expect(state.spaces.map(\.id) == [space.id])
    }

    @Test func badTokenIsRejectedAndDisconnected() throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try RemoteClient(port: h.port)
        try client.send(.hello(id: 1, token: "wrong", clientName: "test", protocolVersion: RemoteProtocol.version))
        guard case .error(_, let code, _) = try client.readReply() else {
            throw TestSocketError(message: "expected error reply")
        }
        #expect(code == "unauthorized")
        #expect(try client.waitForDisconnect())
    }

    @Test func wrongProtocolVersionIsRejected() throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try RemoteClient(port: h.port)
        try client.send(.hello(id: 1, token: h.token, clientName: "test", protocolVersion: 999))
        guard case .error(_, let code, _) = try client.readReply() else {
            throw TestSocketError(message: "expected error reply")
        }
        #expect(code == "protocol_version")
        #expect(try client.waitForDisconnect())
    }

    @Test func requestBeforeHelloIsRejected() throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try RemoteClient(port: h.port)
        try client.send(.stateFetch(id: 1))
        guard case .error(_, let code, _) = try client.readReply() else {
            throw TestSocketError(message: "expected error reply")
        }
        #expect(code == "unauthenticated")
        #expect(try client.waitForDisconnect())
    }

    @Test func mutationsBroadcastToAuthenticatedClients() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try RemoteClient(port: h.port)
        try client.send(.hello(id: 1, token: h.token, clientName: "test", protocolVersion: RemoteProtocol.version))
        guard case .helloOk = try client.readReply() else {
            throw TestSocketError(message: "expected helloOk")
        }

        let space = Space(name: "demo", path: "/tmp/demo")
        try await h.server.addSpace(space)

        guard case .stateChanged(let state) = try client.readReply() else {
            throw TestSocketError(message: "expected stateChanged broadcast")
        }
        #expect(state.spaces.map(\.id) == [space.id])
    }

    @Test func unauthenticatedClientsReceiveNoBroadcasts() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        // Connected but never sent hello.
        let lurker = try RemoteClient(port: h.port)

        // An authenticated client proves the broadcast happened.
        let client = try RemoteClient(port: h.port)
        try client.send(.hello(id: 1, token: h.token, clientName: "test", protocolVersion: RemoteProtocol.version))
        guard case .helloOk = try client.readReply() else {
            throw TestSocketError(message: "expected helloOk")
        }

        try await h.server.addSpace(Space(name: "demo", path: "/tmp/demo"))
        guard case .stateChanged = try client.readReply() else {
            throw TestSocketError(message: "expected stateChanged broadcast")
        }

        // The lurker's socket has nothing to read (a broadcast would have
        // arrived by now — the authenticated client already got it).
        #expect(throws: (any Error).self) {
            _ = try lurker.readReply(timeout: .milliseconds(300))
        }
    }

    @Test func stopRemoteListenerDisconnectsClientsButKeepsExtensions() async throws {
        let h = try Harness()
        defer { h.tearDown() }

        let client = try RemoteClient(port: h.port)
        try client.send(.hello(id: 1, token: h.token, clientName: "test", protocolVersion: RemoteProtocol.version))
        guard case .helloOk = try client.readReply() else {
            throw TestSocketError(message: "expected helloOk")
        }

        h.server.stopRemoteListener()
        #expect(try client.waitForDisconnect())

        // The extension socket still works after the remote listener is gone.
        let agentID = AgentID()
        let space = Space(name: "demo", path: "/tmp/demo")
        let pane = LeafPane(cwd: "/tmp/demo")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "pi-1", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await h.server.addSpace(space)
        try await h.server.addTab(tab)
        try await h.server.addAgent(agent)

        let ext = try ExtensionClient(path: h.dir.appendingPathComponent("d.sock").path)
        defer { ext.closeConnection() }
        try ext.send(.setAgentStatus(agentID: agentID, status: .working))
        try await waitUntil {
            h.server.state.agents.first?.status == .working
        }
        #expect(h.server.state.agents.first?.status == .working)
    }
}
