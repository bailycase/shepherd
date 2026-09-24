import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

// MARK: - Fixtures

/// Small builders for workspace records. An "agent" here is always a top-level agent with its
/// own single-pane layout, the shape the app creates.
enum Fixture {
    static func space(_ name: String = "demo", path: String? = nil) -> Space {
        Space(name: name, path: path ?? "/tmp/\(name)")
    }

    static func agent(
        in space: Space,
        name: String = "worker",
        status: AgentStatus = .idle,
        nameIsFinal: Bool = false,
        sessionID: SessionID? = nil
    ) -> (agent: Agent, tab: ShepherdCore.Tab) {
        let agentID = AgentID()
        let pane = LeafPane(sessionID: sessionID, cwd: space.path, agentID: agentID)
        let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: name, spaceID: space.id, tabID: tab.id, paneID: pane.id,
                          status: status, nameIsFinal: nameIsFinal)
        return (agent, tab)
    }

    /// One space holding the given agents, each with its own layout.
    static func workspace(_ agents: [(agent: Agent, tab: ShepherdCore.Tab)], space: Space) -> ShepherdState {
        ShepherdState(spaces: [space], tabs: agents.map(\.tab), agents: agents.map(\.agent))
    }
}

extension ScratchServer {
    /// A server on a directory no other test can be using (`makeScratchDirectory` is `mkdtemp`).
    static func fresh() throws -> ScratchServer {
        try ScratchServer()
    }

    /// Replace the state and wait for its broadcast, then forget every broadcast so a test
    /// observes only what it causes.
    func seed(_ state: ShepherdState) async throws {
        try await server.putState(state)
        try await eventually("the seeded state to broadcast") { broadcasts.current.last == state }
        broadcasts.withValue { $0.removeAll() }
    }

    /// state.json as it is on disk right now.
    func persisted() throws -> ShepherdState {
        try JSONDecoder().decode(ShepherdState.self, from: Data(contentsOf: stateURL))
    }

    /// Spawn a PTY session running `script` under /bin/sh.
    func shell(_ script: String, cols: Int = 80, rows: Int = 24, env: [String: String]? = nil) async throws -> SessionInfo {
        try await server.createSession(params: CreateSessionParams(
            cwd: dir.path, command: ["/bin/sh", "-c", script], cols: cols, rows: rows, env: env))
    }

    func screen(_ sessionID: SessionID) async -> String {
        await server.screenText(sessionID: sessionID)?.joined(separator: "\n") ?? ""
    }

    /// Wait until the session's headless screen shows `text`.
    func waitForScreen(_ sessionID: SessionID, toContain text: String, timeout: Duration = defaultWaitTimeout) async throws {
        do {
            try await eventually("the screen to show \(text.debugDescription)", timeout: timeout) {
                await screen(sessionID).contains(text)
            }
        } catch let timeout as WaitTimeout {
            let info = await server.sessionInfo(sessionID: sessionID)
            let foreground = await server.foregroundCommandLine(sessionID: sessionID)
            throw WireError("\(timeout) [session \(sessionID), alive: \(String(describing: info?.isAlive)), foreground: \(foreground ?? "-"), screen: \(await screen(sessionID).debugDescription)]")
        }
    }

    /// The child is reaped. Its last bytes may still be draining; wait on the screen for those.
    func waitForExit(_ sessionID: SessionID, timeout: Duration = defaultWaitTimeout) async throws {
        try await eventually("session \(sessionID) to exit", timeout: timeout) {
            await server.sessionInfo(sessionID: sessionID)?.isAlive == false
        }
    }
}

/// Everything a server hands the GUI through its main-queue callbacks.
final class Callbacks: @unchecked Sendable {
    let output = Locked<[SessionID: Data]>([:])
    let deliveries = Locked<[SessionID: Int]>([:])
    let exits = Locked<[SessionID: Int32?]>([:])
    let statuses = Locked<[(AgentID, AgentStatus)]>([])

    init(_ server: SessionServer) {
        server.onOutput = { [output, deliveries] id, data in
            output.withValue { $0[id, default: Data()].append(data) }
            deliveries.withValue { $0[id, default: 0] += 1 }
        }
        server.onSessionExited = { [exits] id, code in exits.withValue { $0[id] = code } }
        server.onAgentStatus = { [statuses] id, status in statuses.withValue { $0.append((id, status)) } }
    }

    func text(_ id: SessionID) -> String { String(decoding: output.current[id] ?? Data(), as: UTF8.self) }
    func exited(_ id: SessionID) -> Bool { exits.current.keys.contains(id) }
    func exitCode(_ id: SessionID) -> Int32?? { exits.current[id] }
}

/// Every delivery the main queue already accepted has run once this returns; used as a barrier
/// after server-side evidence that output was (or was not) scheduled.
@MainActor func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

// MARK: - Blocking helpers

/// Opts a non-Sendable value into crossing to a helper thread for one blocking call.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Run a blocking socket read on its own thread. Not the cooperative pool (tests would stall
/// each other) and not a GCD global queue: with a few hundred tests waiting at once, blocked
/// reads exhaust GCD's worker limit and starve the very server queues that must answer them.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let thread = Thread { continuation.resume(with: Result(catching: body)) }
        thread.stackSize = 256 * 1024
        thread.start()
    }
}

extension ExtensionClient {
    /// The next reply, read off the cooperative pool.
    func reply(timeout: Duration = .seconds(10)) async throws -> ExtensionReply {
        let client = Unchecked(value: self)
        return try await blocking { try client.value.readReply(timeout: timeout) }
    }

    func disconnected(timeout: Duration = .seconds(10)) async throws -> Bool {
        let client = Unchecked(value: self)
        return try await blocking { try client.value.waitForDisconnect(timeout: timeout) }
    }
}

// MARK: - Raw remote wire client

/// A raw TCP NDJSON client for the remote listener: frame-level control for the auth,
/// ordering, and chunking assertions the typed `RemoteHostClient` hides.
final class RawRemote: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError("socket: errno \(errno)") }
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
            // A throwing init of a fully initialised class still runs deinit; closing the
            // descriptor there too would close whatever another test opened with that number.
            closed = true
            throw WireError("connect: errno \(err)")
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Adopts a socket that is already connected to the listener, in blocking mode.
    init(connected fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) & ~O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { closeConnection() }

    func closeConnection() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(fd)
    }

    func send(_ request: RemoteRequest) throws {
        try sendRaw(NDJSON.encode(request))
    }

    func sendRaw(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let n = write(fd, raw.baseAddress! + offset, data.count - offset)
                if n > 0 { offset += n; continue }
                if errno == EINTR { continue }
                throw WireError("write: errno \(errno)")
            }
        }
    }

    /// Authenticate and return the host's capabilities.
    @discardableResult
    func hello(token: String, id: Int = 1) async throws -> [String] {
        try send(.hello(id: id, token: token, clientName: "raw", protocolVersion: RemoteProtocol.version))
        let reply = try await next()
        guard case .helloOk(_, _, let capabilities) = reply else {
            throw WireError("expected helloOk, got \(reply)")
        }
        return capabilities
    }

    /// The next frame, or a timeout error.
    func next(timeout: Duration = .seconds(10)) async throws -> RemoteReply {
        let line = try await blocking { [self] in try self.readLine(timeout: timeout) }
        return try NDJSON.decode(RemoteReply.self, from: line)
    }

    /// Frames up to and including the first that satisfies `last`.
    func frames(until last: (RemoteReply) -> Bool, timeout: Duration = .seconds(10)) async throws -> [RemoteReply] {
        var frames: [RemoteReply] = []
        while true {
            let frame = try await next(timeout: timeout)
            frames.append(frame)
            if last(frame) { return frames }
        }
    }

    /// True once the host closes the connection.
    func disconnected(timeout: Duration = .seconds(10)) async throws -> Bool {
        try await blocking { [self] in
            do {
                while true { _ = try self.readLine(timeout: timeout) }
            } catch let error as WireError where error.reason == "closed" {
                return true
            } catch let error as WireError where error.reason == "timeout" {
                return false
            }
        }
    }

    private func readLine(timeout: Duration) throws -> Data {
        let deadline = ContinuousClock.now + timeout
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw WireError("timeout") }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let millis = Int32(max(1, remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
            let ready = poll(&pfd, 1, min(millis, 100))
            if ready < 0, errno != EINTR { throw WireError("poll: errno \(errno)") }
            guard ready > 0 else { continue }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 || (errno != EINTR && errno != EAGAIN) {
                throw WireError("closed")
            }
        }
    }
}

extension RemoteReply {
    var outputData: Data? {
        if case .output(_, let data) = self { return data }
        return nil
    }
}

// MARK: - A listening host

/// A scratch server with its remote listener on an ephemeral port.
struct RemoteHost {
    let host: ScratchServer
    let port: UInt16
    let token: String

    var server: SessionServer { host.server }

    init(modelCatalog: @escaping SessionServer.ModelCatalog = { ScratchServer.standInModels }) throws {
        host = try ScratchServer(modelCatalog: modelCatalog)
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() { host.stop() }

    func raw(authenticated: Bool = true) async throws -> RawRemote {
        let client = try RawRemote(port: port)
        if authenticated { try await client.hello(token: token) }
        return client
    }

    func typed() async throws -> RemoteHostClient {
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "typed")
        return client
    }
}

// MARK: - Results

extension NativeThreadResult {
    var failureCode: String? {
        if case .failure(let code, _) = self { return code }
        return nil
    }

    var snapshotValue: NativeThreadSnapshot? {
        if case .snapshot(let value) = self { return value }
        return nil
    }
}

struct WireError: Error, CustomStringConvertible {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var description: String { reason }
}
