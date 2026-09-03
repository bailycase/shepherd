import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol

public enum RemoteHostClientError: Error, CustomStringConvertible, Sendable {
    case resolveFailed(host: String)
    case system(call: String, errno: Int32)
    case rejected(code: String, message: String)
    case disconnected
    case timeout

    public var description: String {
        switch self {
        case .resolveFailed(let host):
            return "could not resolve \(host)"
        case .system(let call, let err):
            return "\(call) failed: \(String(cString: strerror(err))) (errno \(err))"
        case .rejected(let code, let message):
            return "\(code): \(message)"
        case .disconnected:
            return "connection closed"
        case .timeout:
            return "request timed out"
        }
    }
}

/// TCP NDJSON client for a remote Shepherd host's listener. The mirror image
/// of the host side: id-correlated requests with async replies, plus pushed
/// events (state changes, session output, exits) delivered on the main queue
/// in arrival order — the same contract SessionServer's callbacks have.
///
/// One client per host connection. `connect` performs the full handshake
/// (hello + initial state fetch); after that the owner reads pushed state and
/// drives sessions with attach/write/resize. Any socket failure tears the
/// connection down and fires `onDisconnected` once; the owner reconnects by
/// making a fresh client.
public final class RemoteHostClient: @unchecked Sendable {
    /// Remote host state pushed after every host-side mutation. Main queue.
    public var onStateChanged: ((ShepherdState) -> Void)?
    /// PTY output (replay or live) for an attached session. Main queue.
    public var onOutput: ((SessionID, Data) -> Void)?
    /// An attached session's process exited. Main queue.
    public var onSessionExited: ((SessionID, Int32?) -> Void)?
    /// The connection died (readable EOF, write failure, or `disconnect`).
    /// Fired at most once, on the main queue.
    public var onDisconnected: ((String) -> Void)?
    public private(set) var capabilities: Set<String> = []

    private let queue = DispatchQueue(label: "shepherd.remote.client")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var lineBuffer = LineBuffer()
    private var pendingWrites: [Data] = []
    private var pendingWriteOffset = 0
    private var nextRequestID = 1
    private var pendingReplies: [Int: CheckedContinuation<RemoteReply, Error>] = [:]
    private var disconnectNotified = false

    /// Pushed events wait here for the main queue. One hop is in flight at a
    /// time and consecutive output for one session merges into one callback,
    /// so a flooding host cannot queue a closure per frame behind UI work
    /// (the host side has the same one-delivery rule). Kept as one FIFO for
    /// every event kind so `sessionExited` still follows that session's
    /// last bytes. Client queue only.
    private enum PushedEvent {
        case state(ShepherdState)
        case output(SessionID, Data)
        case exited(SessionID, Int32?)
    }
    private var pendingEvents: [PushedEvent] = []
    private var deliveryInFlight = false

    private static let requestTimeout: TimeInterval = 10
    private static let maxQueuedWriteBytes = 8 * 1024 * 1024

    public init() {}

    deinit {
        // The read source's cancel handler owns closing the fd. Cancel is
        // thread-safe; a source must never be released while still active.
        if let readSource {
            readSource.cancel()
        } else if fd >= 0 {
            close(fd)
        }
        writeSource?.cancel()
        for continuation in pendingReplies.values {
            continuation.resume(throwing: RemoteHostClientError.disconnected)
        }
    }

    /// Resolve, connect, authenticate, and fetch the host's current state.
    public func connect(
        host: String,
        port: UInt16,
        token: String,
        clientName: String
    ) async throws -> ShepherdState {
        let fd = try await Task.detached(priority: .userInitiated) {
            try Self.openSocket(host: host, port: port)
        }.value

        try queue.sync {
            guard self.fd < 0 else {
                close(fd)
                throw RemoteHostClientError.system(call: "connect", errno: EISCONN)
            }
            self.fd = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.handleReadable() }
            source.setCancelHandler { close(fd) }
            self.readSource = source
            source.activate()
        }

        let helloReply = try await request { id in
            .hello(id: id, token: token, clientName: clientName, protocolVersion: RemoteProtocol.version)
        }
        guard case .helloOk(_, _, let capabilities) = helloReply else {
            if case .error(_, let code, let message) = helloReply {
                disconnect()
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            disconnect()
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected hello reply")
        }
        self.capabilities = Set(capabilities)

        let stateReply = try await request { id in .stateFetch(id: id) }
        guard case .state(_, let state) = stateReply else {
            disconnect()
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected state reply")
        }
        return state
    }

    /// Attach to a session at the client surface's grid. The host replies
    /// `attached`, then streams the screen replay and live output through
    /// `onOutput` in order.
    public func attach(
        sessionID: SessionID,
        cols: Int,
        rows: Int,
        viewportGeneration: UInt64 = 0
    ) async throws -> RemoteAttachment {
        let reply = try await request { id in
            .attach(
                id: id,
                sessionID: sessionID,
                cols: cols,
                rows: rows,
                viewportGeneration: viewportGeneration
            )
        }
        guard case .attached(_, let attachment) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected attach reply")
        }
        return attachment
    }

    /// A host directory listing: the resolved path, its parent (nil at the
    /// filesystem root), and visible subdirectory names.
    public struct DirListing: Sendable {
        public let path: String
        public let parent: String?
        public let dirs: [String]

        public init(path: String, parent: String?, dirs: [String]) {
            self.path = path
            self.parent = parent
            self.dirs = dirs
        }
    }

    /// List a host directory's subdirectories. Empty path = the host's home.
    public func listDir(path: String) async throws -> DirListing {
        let reply = try await request { id in .listDir(id: id, path: path) }
        guard case .dirListing(_, let path, let parent, let dirs) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected listDir reply")
        }
        return DirListing(path: path, parent: parent, dirs: dirs)
    }

    /// The host's pi model ids and configured default model.
    public func listModels() async throws -> (models: [String], defaultModel: String?) {
        let reply = try await request { id in .listModels(id: id) }
        guard case .models(_, let models, let defaultModel) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected listModels reply")
        }
        return (models, defaultModel)
    }

    /// Create a space from a directory on the host.
    @discardableResult
    public func addSpace(path: String) async throws -> SpaceID {
        let reply = try await request { id in .addSpace(id: id, path: path) }
        guard case .spaceAdded(_, let spaceID) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected addSpace reply")
        }
        return spaceID
    }

    /// Create an agent on the host. The host spawns pi; the agent arrives in
    /// pushed state. Uses a longer timeout — spawning waits on the host GUI.
    @discardableResult
    public func createAgent(
        spaceID: SpaceID,
        cwd: String?,
        model: String?,
        thinking: ThinkingLevel?,
        initialPrompt: String?
    ) async throws -> AgentID {
        let reply = try await request(timeout: 30) { id in
            .createAgent(
                id: id,
                spaceID: spaceID,
                cwd: cwd,
                model: model,
                thinking: thinking,
                initialPrompt: initialPrompt
            )
        }
        guard case .agentCreated(_, let agentID) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected createAgent reply")
        }
        return agentID
    }

    public func detach(sessionID: SessionID) {
        queue.async { self.sendRequest(.detach(sessionID: sessionID)) }
    }

    public func write(sessionID: SessionID, data: Data) {
        queue.async { self.sendRequest(.input(sessionID: sessionID, data: data)) }
    }

    public func resize(sessionID: SessionID, cols: Int, rows: Int, viewportGeneration: UInt64 = 0) {
        queue.async {
            self.sendRequest(.resize(
                sessionID: sessionID,
                cols: cols,
                rows: rows,
                viewportGeneration: viewportGeneration
            ))
        }
    }

    @discardableResult
    public func openPane(agentID: AgentID, relativeTo paneID: PaneID, axis: SplitAxis) async throws -> PaneID {
        guard capabilities.contains(RemoteProtocol.paneControlCapability) else {
            throw RemoteHostClientError.rejected(code: "unsupported", message: "host needs a newer Shepherd build for remote panes")
        }
        let reply = try await request { id in
            .openPane(id: id, agentID: agentID, axis: axis, relativeTo: paneID)
        }
        guard case .paneOpened(_, let opened) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected openPane reply")
        }
        return opened
    }

    public func closePane(agentID: AgentID, paneID: PaneID) async throws {
        guard capabilities.contains(RemoteProtocol.paneControlCapability) else {
            throw RemoteHostClientError.rejected(code: "unsupported", message: "host needs a newer Shepherd build for remote panes")
        }
        let reply = try await request { id in .closePane(id: id, agentID: agentID, paneID: paneID) }
        try expectOk(reply)
    }

    public func resizePaneSplit(agentID: AgentID, split: PaneNode, ratio: Double) async throws {
        guard capabilities.contains(RemoteProtocol.paneControlCapability) else {
            throw RemoteHostClientError.rejected(code: "unsupported", message: "host needs a newer Shepherd build for remote panes")
        }
        let reply = try await request { id in
            .resizePaneSplit(id: id, agentID: agentID, split: split, ratio: ratio)
        }
        try expectOk(reply)
    }

    /// Send a composed block as one bracketed paste (+ optional Return).
    /// Current hosts acknowledge it. Legacy protocol-v1 hosts did not advertise
    /// capabilities, so use their existing raw-input path instead of sending an
    /// unknown request that would make them drop the connection.
    public func paste(sessionID: SessionID, text: String, submit: Bool) async throws {
        if !capabilities.contains(RemoteProtocol.pasteCapability) {
            let payload = RemoteProtocol.composedInput(text: text, submit: submit)
            try queue.sync {
                guard fd >= 0 else { throw RemoteHostClientError.disconnected }
                sendRequest(.input(sessionID: sessionID, data: payload))
            }
            return
        }

        let reply = try await request { id in
            .paste(id: id, sessionID: sessionID, text: text, submit: submit)
        }
        try expectOk(reply)
    }

    private func expectOk(_ reply: RemoteReply) throws {
        guard case .ok = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected reply")
        }
    }

    public func disconnect() {
        queue.sync { teardown(reason: "closed") }
    }

    // MARK: - Connection plumbing (client queue)

    private static func openSocket(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            throw RemoteHostClientError.resolveFailed(host: host)
        }
        defer { freeaddrinfo(info) }

        var lastErrno: Int32 = ECONNREFUSED
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let ai = candidate {
            let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    var one: Int32 = 1
                    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                    _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                    let flags = fcntl(fd, F_GETFL, 0)
                    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                    return fd
                }
                lastErrno = errno
                close(fd)
            } else {
                lastErrno = errno
            }
            candidate = ai.pointee.ai_next
        }
        throw RemoteHostClientError.system(call: "connect", errno: lastErrno)
    }

    /// Issue an id-correlated request and await its reply.
    private func request(
        timeout: TimeInterval = RemoteHostClient.requestTimeout,
        _ make: @escaping (Int) -> RemoteRequest
    ) async throws -> RemoteReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.fd >= 0 else {
                    continuation.resume(throwing: RemoteHostClientError.disconnected)
                    return
                }
                let id = self.nextRequestID
                self.nextRequestID += 1
                self.pendingReplies[id] = continuation
                self.sendRequest(make(id))
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let pending = self.pendingReplies.removeValue(forKey: id) else { return }
                    pending.resume(throwing: RemoteHostClientError.timeout)
                    self.teardown(reason: "request timed out")
                }
            }
        }
    }

    private func sendRequest(_ req: RemoteRequest) {
        guard fd >= 0 else { return }
        let payload: Data
        do {
            payload = try NDJSON.encode(req)
        } catch {
            ShepherdLog.error("could not encode remote request: \(error)")
            return
        }
        guard pendingWrites.reduce(0, { $0 + $1.count }) + payload.count <= Self.maxQueuedWriteBytes else {
            teardown(reason: "write queue overflow")
            return
        }
        pendingWrites.append(payload)
        drainWrites()
    }

    private func drainWrites() {
        guard fd >= 0 else { return }
        while !pendingWrites.isEmpty {
            let payload = pendingWrites[0]
            let offset = pendingWriteOffset
            guard offset < payload.count else {
                pendingWrites.removeFirst()
                pendingWriteOffset = 0
                continue
            }
            let result = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), payload.count - offset)
            }
            if result > 0 {
                pendingWriteOffset += result
                if pendingWriteOffset == payload.count {
                    pendingWrites.removeFirst()
                    pendingWriteOffset = 0
                }
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armWriter()
                return
            }
            teardown(reason: "write failed: errno \(errno)")
            return
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func armWriter() {
        guard writeSource == nil, fd >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainWrites() }
        source.setCancelHandler {}
        writeSource = source
        source.activate()
    }

    private func handleReadable() {
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                let lines: [Data]
                do {
                    lines = try lineBuffer.append(Data(bytes: buf, count: n))
                } catch {
                    teardown(reason: "framing violation: \(error)")
                    return
                }
                for line in lines {
                    guard fd >= 0 else { return }
                    handleLine(line)
                }
                continue
            }
            if n == 0 {
                teardown(reason: "host closed the connection")
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            teardown(reason: "read failed: errno \(errno)")
            return
        }
    }

    private func handleLine(_ line: Data) {
        let reply: RemoteReply
        do {
            reply = try NDJSON.decode(RemoteReply.self, from: line)
        } catch {
            ShepherdLog.warning("undecodable remote reply: \(error)")
            return
        }
        switch reply {
        case .helloOk(let id, _, _), .ok(let id), .paneOpened(let id, _),
             .state(let id, _), .attached(let id, _),
             .dirListing(let id, _, _, _), .models(let id, _, _),
             .spaceAdded(let id, _), .agentCreated(let id, _):
            resumePending(id: id, with: reply)
        case .error(let id, _, _):
            resumePending(id: id, with: reply)
        case .stateChanged(let state):
            push(.state(state))
        case .output(let sessionID, let data):
            if case .output(let last, var merged)? = pendingEvents.last, last == sessionID {
                merged.append(data)
                pendingEvents[pendingEvents.count - 1] = .output(sessionID, merged)
            } else {
                push(.output(sessionID, data))
            }
        case .sessionExited(let sessionID, let code):
            push(.exited(sessionID, code))
        }
    }

    private func push(_ event: PushedEvent) {
        pendingEvents.append(event)
        scheduleDelivery()
    }

    /// Client queue. Hands the whole backlog to the main queue in one hop;
    /// events that arrive meanwhile wait for the next hop.
    private func scheduleDelivery() {
        guard !deliveryInFlight, !pendingEvents.isEmpty else { return }
        deliveryInFlight = true
        let batch = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        hopToMain { [weak self] in
            guard let self else { return }
            for event in batch {
                switch event {
                case .state(let state): self.onStateChanged?(state)
                case .output(let sessionID, let data): self.onOutput?(sessionID, data)
                case .exited(let sessionID, let code): self.onSessionExited?(sessionID, code)
                }
            }
            self.queue.async { [weak self] in
                self?.deliveryInFlight = false
                self?.scheduleDelivery()
            }
        }
    }

    private func resumePending(id: Int, with reply: RemoteReply) {
        guard let continuation = pendingReplies.removeValue(forKey: id) else {
            ShepherdLog.warning("remote reply for unknown request \(id); dropped")
            return
        }
        continuation.resume(returning: reply)
    }

    private func teardown(reason: String) {
        guard fd >= 0 else { return }
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        // Cancel handlers own the close; without a read source, close here.
        fd = -1
        pendingWrites.removeAll()
        pendingWriteOffset = 0
        // Undelivered pushes die with the connection; the owner drops its
        // view state on disconnect and re-snapshots on reconnect.
        pendingEvents.removeAll()
        for continuation in pendingReplies.values {
            continuation.resume(throwing: RemoteHostClientError.disconnected)
        }
        pendingReplies.removeAll()
        if !disconnectNotified {
            disconnectNotified = true
            hopToMain { [weak self] in self?.onDisconnected?(reason) }
        }
    }

    private func hopToMain(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}
