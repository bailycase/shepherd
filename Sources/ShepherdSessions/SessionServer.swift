import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

public enum SessionServerError: Error, CustomStringConvertible {
    case socketPathTooLong(path: String)
    case system(call: String, errno: Int32)
    case noSuchSession(SessionID)
    case noSuchSpace(SpaceID)
    case noSuchTab(TabID)
    case noSuchPane(PaneID)
    case tabInUse(TabID)
    case noSuchAgent(AgentID)
    case noSuchAutomation(AutomationID)
    case conflict(String)
    case persistFailed(String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path):
            return "socket path exceeds sun_path capacity: \(path)"
        case .system(let call, let err):
            return "\(call) failed: \(String(cString: strerror(err))) (errno \(err))"
        case .noSuchSession(let id):
            return "unknown session \(id)"
        case .noSuchSpace(let id):
            return "unknown space \(id)"
        case .noSuchTab(let id):
            return "unknown tab \(id)"
        case .noSuchPane(let id):
            return "unknown pane \(id)"
        case .tabInUse(let id):
            return "tab \(id) is referenced by an agent"
        case .noSuchAgent(let id):
            return "unknown agent \(id)"
        case .noSuchAutomation(let id):
            return "unknown automation \(id)"
        case .conflict(let message):
            return message
        case .persistFailed(let message):
            return "persist failed: \(message)"
        }
    }
}

/// The screen replay and output sequence captured by one atomic attach turn.
public struct AttachmentSnapshot: Sendable {
    public let replay: Data
    public let outputSequence: UInt64

    public var watermark: UInt64 { outputSequence }

    public init(replay: Data, outputSequence: UInt64) {
        self.replay = replay
        self.outputSequence = outputSequence
    }
}

/// In-process owner of every PTY session and the persisted ShepherdState.
/// There is no daemon process anymore: the app spawns sessions directly and
/// they live and die with it (closing the app kills every agent, like any
/// terminal app). State.json is still the source of truth across relaunches —
/// the app loads it at launch and respawns each pane's session fresh.
///
/// All state lives on one serial queue. Each PTY session's internal queue
/// targets it, so session callbacks and server handlers are mutually
/// exclusive; this is what makes attach-time screen snapshots exact.
///
/// The one remaining socket: the pi status extension connects to a Unix
/// domain socket we host (SHEPHERD_SOCKET) and reports agent lifecycle status
/// fire-and-forget. It is same-user, filesystem-confined IPC with no
/// authentication, not a security boundary against another process running as
/// the same macOS user. There is no GUI wire protocol. The GUI calls this class
/// directly.
public final class SessionServer: @unchecked Sendable {
    private static let maxQueuedReplyBytes = 2 * 1024 * 1024
    /// Bounds bytes retained between the PTY and the renderer. The in-flight
    /// delivery is counted with the pending bytes, so the renderer cannot keep
    /// an unbounded backlog alive by stalling the main queue.
    static let outputHighWaterMark = 4 * 1024 * 1024
    static let outputLowWaterMark = 1 * 1024 * 1024
    static let maxOutputDeliveryBytes = 256 * 1024

    private final class ExtensionConnection {
        let fd: Int32
        /// True for a remote Shepherd client on the TCP listener; false for a
        /// pi extension on the Unix socket.
        let isRemote: Bool
        /// Remote connections must pass the token handshake before any other
        /// request is served. Extension connections never authenticate.
        var authenticated = false
        /// Set when a final reply (an auth error) should end the connection
        /// once the write queue drains.
        var closeAfterFlush = false
        /// Set by helloAgent: this connection belongs to that agent's panes
        /// extension and accepts unsolicited message pushes.
        var agentID: AgentID?
        var lineBuffer = LineBuffer()
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var pendingReplies: [Data] = []
        var pendingReplyOffset = 0
        var queuedReplyBytes = 0

        init(fd: Int32, isRemote: Bool = false) {
            self.fd = fd
            self.isRemote = isRemote
        }
    }

    private final class OutputDelivery {
        let data: Data
        let endSequence: UInt64
        private let lock = NSLock()
        private var cancelled = false

        init(data: Data, endSequence: UInt64) {
            self.data = data
            self.endSequence = endSequence
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    private final class SessionOutputState {
        struct PendingChunk {
            var data: Data
            let sequence: UInt64
        }

        var pending: [PendingChunk] = []
        var pendingBytes = 0
        /// Every PTY read gets one sequence on the server queue, including
        /// output read while detached. The attach watermark samples this
        /// counter after the screen has consumed the same bytes.
        var outputSequence: UInt64 = 0
        /// A delivery stays in flight until its main-queue callback returns.
        /// A cancelled delivery still occupies this slot until its callback
        /// runs, keeping the renderer from receiving overlapping output.
        var delivery: OutputDelivery?
        var readSuspended = false
        var exitPending = false
        var exitCode: Int32?

        var outstandingBytes: Int {
            pendingBytes + (delivery?.data.count ?? 0)
        }
    }

    /// Shared instance the app uses; tests construct their own with scratch
    /// paths.
    public static let shared = SessionServer(
        socketPath: ShepherdPaths.socketURL().path,
        stateURL: ShepherdPaths.stateURL()
    )

    /// PTY output for an attached session. Delivered on the main actor.
    public var onOutput: ((SessionID, Data) -> Void)?
    /// PTY output with the server-queue sequence of the delivery's final
    /// source chunk. Coalesced deliveries retain that end sequence.
    public var onSequencedOutput: ((SessionID, Data, UInt64) -> Void)?
    /// A session's child process exited. Delivered on the main actor.
    public var onSessionExited: ((SessionID, Int32?) -> Void)?
    /// State was persisted. Every mutation broadcasts, including mutations
    /// initiated by the GUI. Delivered on the main actor.
    public var onStateChanged: ((ShepherdState) -> Void)?
    /// The pi status extension reported a status. Delivered on the main actor.
    public var onAgentStatus: ((AgentID, AgentStatus) -> Void)?
    /// The subagents extension published an agent's live child-run projection
    /// (full replace). Display-only — never persisted, never validated against
    /// state; the GUI owns row lifecycle. Delivered on the main actor.
    public var onAgentChildren: ((AgentID, [ChildRun]) -> Void)?
    /// The notify extension's tool asked for a system notification.
    /// Fire-and-forget, delivered on the main actor.
    public var onNotify: ((AgentID, String, String) -> Void)?
    /// A Shepherd agent asked to see, message, or spawn peer threads.
    /// Forwarded to the GUI like pane requests. Delivered on the main actor;
    /// the completion may be called from any thread.
    public var onAgentPeerRequest: ((AgentPeerRequest, @escaping (AgentPeerOutcome) -> Void) -> Void)?
    /// A pi session (the automation skill) asked to manage automations. The
    /// GUI owns the run lifecycle (space resolution, agent spawn/kill), so
    /// requests forward there like pane requests. Delivered on the main
    /// actor; the completion may be called from any thread.
    public var onAutomationRequest: ((AutomationRequest, @escaping (AutomationOutcome) -> Void) -> Void)?
    /// An agent asked to drive its own panes (the panes extension). Layout and
    /// pane→session binding live in the GUI, so the request is handed to it and
    /// the reply comes back through the completion. Delivered on the main
    /// actor; the completion may be called from any thread.
    public var onPaneRequest: ((PaneRequest, @escaping (PaneOutcome) -> Void) -> Void)?
    public var onRemotePaneRequest: ((PaneRequest, @escaping (PaneOutcome) -> Void) -> Void)?
    /// A remote client asked to create an agent. Spawning pi (extension
    /// flags, session-file seeding, pane binding) is the GUI's flow, so the
    /// request is handed to it like a pane request. Delivered on the main
    /// actor; the completion may be called from any thread. `nil` handler
    /// (headless server, tests) rejects the request.
    public var onRemoteCreateAgent: ((RemoteCreateAgentRequest, @escaping (Result<AgentID, RemoteCreateAgentError>) -> Void) -> Void)?

    private let queue = DispatchQueue(label: "shepherd.sessions")
    private let socketPath: String
    private let store: StateStore
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var remoteListenFD: Int32 = -1
    private var remoteAcceptSource: DispatchSourceRead?
    private var remoteToken: String?
    /// Which remote clients (by fd) stream each session's output. Registered
    /// in the same queue turn as the attach snapshot, so replay + live output
    /// are exact — the same guarantee the GUI attach path has.
    private var remoteAttachments: [SessionID: Set<Int32>] = [:]
    /// Each remote viewer's reported grid per session (tmux semantics:
    /// the smallest attached viewport wins). The host GUI's own surface size
    /// participates via `reportLocalViewport`. Cleared on detach/disconnect;
    /// with no reports left the PTY keeps its last-known size.
    private var remoteViewports: [SessionID: [Int32: (cols: Int, rows: Int)]] = [:]
    /// The host GUI's own surface grid per session (fd -1 in the min).
    private var localViewports: [SessionID: (cols: Int, rows: Int)] = [:]
    private var clients: [Int32: ExtensionConnection] = [:]
    private var sessions: [SessionID: PTYSession] = [:]
    private var attachedSessions: Set<SessionID> = []
    /// Output waiting for the GUI, plus the one delivery currently executing
    /// on the main queue, tracked independently for each session.
    private var outputStates: [SessionID: SessionOutputState] = [:]

    public init(socketPath: String, stateURL: URL) {
        self.socketPath = socketPath
        self.store = StateStore(url: stateURL)
    }

    /// Current persisted state (safe to read from any thread).
    public var state: ShepherdState {
        queue.sync { store.state }
    }

    /// Bind the extension socket and clear stale persisted state from the
    /// previous run (sessions died with the app; agent statuses no longer
    /// mean anything until pi reports fresh ones).
    public func start() throws {
        try queue.sync { try startOnQueue() }
    }

    /// Kill every session and close the extension socket. Called when the app
    /// terminates: sessions must not outlive the app.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    // MARK: - Lifecycle (server queue)

    private func startOnQueue() throws {
        let stale = store.state.agents.filter { $0.status != .idle }.map(\.id)
        let deadInspectors = store.state.tabs.contains { $0.inspectorFor != nil }
        let staleRuns = store.state.automations.contains { $0.agentID != nil }
        if !stale.isEmpty || deadInspectors || staleRuns {
            do {
                try store.update { state in
                    for id in stale {
                        if let i = state.agents.firstIndex(where: { $0.id == id }) {
                            state.agents[i].status = .idle
                        }
                    }
                    // Inspector tabs are session-scoped UI: their viewer
                    // processes died with the previous run, so restoring
                    // them would show empty shells.
                    state.tabs.removeAll { $0.inspectorFor != nil }
                    // Automation runs died with the previous app run; enabled
                    // ones restart through the GUI after adoption.
                    for i in state.automations.indices {
                        state.automations[i].agentID = nil
                    }
                }
            } catch {
                throw SessionServerError.persistFailed(String(describing: error))
            }
        }

        let fm = FileManager.default
        let supportDirectory = (socketPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
        guard chmod(supportDirectory, 0o700) == 0 else {
            throw SessionServerError.system(call: "chmod", errno: errno)
        }

        if fm.fileExists(atPath: socketPath) {
            if probeLiveSocket() {
                throw SessionServerError.system(call: "bind", errno: EADDRINUSE)
            }
            ShepherdLog.info("removing stale socket at \(socketPath)")
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SessionServerError.system(call: "socket", errno: errno) }

        var addr = try Self.socketAddress(for: socketPath)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw SessionServerError.system(call: "bind", errno: err)
        }
        guard chmod(socketPath, 0o600) == 0 else {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw SessionServerError.system(call: "chmod", errno: err)
        }
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            unlink(socketPath)
            throw SessionServerError.system(call: "listen", errno: err)
        }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.activate()
        ShepherdLog.info("extension socket listening on \(socketPath)")
    }

    private func stopOnQueue() {
        for session in sessions.values {
            session.shutdown()
        }
        for output in outputStates.values {
            output.delivery?.cancel()
        }
        sessions.removeAll()
        attachedSessions.removeAll()
        outputStates.removeAll()
        for client in Array(clients.values) {
            disconnect(client)
        }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            unlink(socketPath)
            listenFD = -1
        }
        stopRemoteListenerOnQueue()
    }

    // MARK: - Remote listener (server queue)

    /// Bind the TCP listener for remote Shepherd clients. Pass port 0 to bind
    /// an ephemeral port; the bound port is returned either way. The token is
    /// loaded from `tokenURL`, generated (0600) on first use. The listener
    /// binds all interfaces — the user's VPN is the reachability and security
    /// boundary; the token keeps other devices on that network honest.
    public func startRemoteListener(port: UInt16, tokenURL: URL) throws -> UInt16 {
        try queue.sync { try startRemoteListenerOnQueue(port: port, tokenURL: tokenURL) }
    }

    /// Close the TCP listener and every remote client connection. Extension
    /// connections and sessions are unaffected.
    public func stopRemoteListener() {
        queue.sync { stopRemoteListenerOnQueue() }
    }

    private func startRemoteListenerOnQueue(port: UInt16, tokenURL: URL) throws -> UInt16 {
        guard remoteListenFD < 0 else {
            throw SessionServerError.conflict("remote listener already running")
        }
        remoteToken = try Self.loadOrCreateRemoteToken(at: tokenURL)

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SessionServerError.system(call: "socket", errno: errno) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw SessionServerError.system(call: "bind", errno: err)
        }
        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw SessionServerError.system(call: "listen", errno: err)
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLen)
            }
        }
        guard named == 0 else {
            let err = errno
            close(fd)
            throw SessionServerError.system(call: "getsockname", errno: err)
        }
        let boundPort = UInt16(bigEndian: boundAddr.sin_port)

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        remoteListenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptRemotePending(on: fd) }
        source.setCancelHandler { close(fd) }
        remoteAcceptSource = source
        source.activate()
        ShepherdLog.info("remote listener on port \(boundPort)")
        return boundPort
    }

    private func stopRemoteListenerOnQueue() {
        for client in Array(clients.values) where client.isRemote {
            disconnect(client)
        }
        remoteAcceptSource?.cancel()
        remoteAcceptSource = nil
        remoteListenFD = -1
        remoteToken = nil
    }

    /// Load the shared remote token, generating one (32 random bytes as hex,
    /// mode 0600) on first use.
    static func loadOrCreateRemoteToken(at url: URL) throws -> String {
        if let data = try? Data(contentsOf: url) {
            let token = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else {
            throw SessionServerError.system(call: "chmod", errno: errno)
        }
        return token
    }

    private func acceptRemotePending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                ShepherdLog.error("remote accept failed: errno \(errno)")
                return
            }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let client = ExtensionConnection(fd: fd, isRemote: true)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.handleReadable(fd: fd) }
            source.setCancelHandler { close(fd) }
            client.readSource = source
            clients[fd] = client
            source.activate()
            ShepherdLog.info("remote client connected (fd \(fd))")
        }
    }

    private func handleRemoteLine(_ line: Data, from client: ExtensionConnection) {
        let request: RemoteRequest
        do {
            request = try NDJSON.decode(RemoteRequest.self, from: line)
        } catch {
            ShepherdLog.warning("undecodable remote request on fd \(client.fd): \(error)")
            disconnect(client)
            return
        }

        guard client.authenticated else {
            guard case .hello(let id, let token, let clientName, let protocolVersion) = request else {
                ShepherdLog.warning("remote request before hello on fd \(client.fd)")
                sendFinal(.error(id: 0, code: "unauthenticated", message: "hello required"), to: client)
                return
            }
            guard protocolVersion == RemoteProtocol.version else {
                sendFinal(.error(
                    id: id,
                    code: "protocol_version",
                    message: "host speaks protocol \(RemoteProtocol.version)"
                ), to: client)
                return
            }
            guard let expected = remoteToken, token == expected else {
                ShepherdLog.warning("remote client '\(clientName)' rejected: bad token (fd \(client.fd))")
                sendFinal(.error(id: id, code: "unauthorized", message: "bad token"), to: client)
                return
            }
            client.authenticated = true
            send(.helloOk(
                id: id,
                protocolVersion: RemoteProtocol.version,
                capabilities: RemoteProtocol.capabilities
            ), to: client)
            ShepherdLog.info("remote client '\(clientName)' authenticated (fd \(client.fd))")
            return
        }

        switch request {
        case .hello(let id, _, _, _):
            send(.error(id: id, code: "protocol", message: "already authenticated"), to: client)
        case .stateFetch(let id):
            send(.state(id: id, state: store.state), to: client)
        case .attach(let id, let sessionID, let cols, let rows, let viewportGeneration):
            remoteAttach(
                id: id,
                sessionID: sessionID,
                cols: cols,
                rows: rows,
                viewportGeneration: viewportGeneration,
                client: client
            )
        case .detach(let sessionID):
            remoteAttachments[sessionID]?.remove(client.fd)
            remoteViewports[sessionID]?.removeValue(forKey: client.fd)
            // Remaining viewers get their space back immediately.
            applyMinViewport(sessionID: sessionID)
        case .input(let sessionID, let data):
            if let session = sessions[sessionID], session.isAlive {
                session.writeInput(data)
            }
        case .resize(let sessionID, let cols, let rows, _):
            guard remoteAttachments[sessionID]?.contains(client.fd) == true else { return }
            recordRemoteViewport(sessionID: sessionID, fd: client.fd, cols: cols, rows: rows)
        case .paste(let id, let sessionID, let text, let submit):
            remotePaste(id: id, sessionID: sessionID, text: text, submit: submit, client: client)
        case .openPane(let id, let agentID, let axis, let relativeTo):
            remotePaneRequest(
                id: id,
                request: .open(agentID: agentID, axis: axis, cwd: nil, relativeTo: relativeTo, command: nil),
                client: client
            )
        case .closePane(let id, let agentID, let paneID):
            remotePaneRequest(id: id, request: .close(agentID: agentID, paneID: paneID), client: client)
        case .resizePaneSplit(let id, let agentID, let split, let ratio):
            remotePaneRequest(
                id: id,
                request: .resizeSplit(agentID: agentID, split: split, ratio: ratio),
                client: client
            )
        case .listDir(let id, let path):
            remoteListDir(id: id, path: path, client: client)
        case .listModels(let id):
            // Asking pi shells out (~0.5s cold); never block the server
            // queue. Reply from the queue once the catalog returns.
            let fd = client.fd
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let models = PiModelCatalog.modelIDs()
                let fallback = models.isEmpty ? PiConfig.modelIDs() : models
                let defaultModel = PiConfig.defaultModel()
                self?.queue.async {
                    guard let self, let client = self.clients[fd] else { return }
                    self.send(.models(id: id, models: fallback, defaultModel: defaultModel), to: client)
                }
            }
        case .addSpace(let id, let path):
            remoteAddSpace(id: id, path: path, client: client)
        case .createAgent(let id, let spaceID, let cwd, let model, let thinking, let initialPrompt):
            remoteCreateAgent(
                id: id,
                request: RemoteCreateAgentRequest(
                    spaceID: spaceID,
                    cwd: cwd,
                    model: model,
                    thinking: thinking,
                    initialPrompt: initialPrompt
                ),
                client: client
            )
        }
    }

    private func remotePaneRequest(id: Int, request: PaneRequest, client: ExtensionConnection) {
        guard let handler = onRemotePaneRequest else {
            send(.error(id: id, code: "unsupported", message: "host cannot mutate panes"), to: client)
            return
        }
        let fd = client.fd
        hopToMain { [weak self] in
            handler(request) { outcome in
                guard let self else { return }
                self.queue.async {
                    guard let client = self.clients[fd] else { return }
                    switch outcome {
                    case .ok:
                        self.send(.ok(id: id), to: client)
                    case .opened(let pane):
                        self.send(.paneOpened(id: id, paneID: pane.id), to: client)
                    case .failed(let code, let message):
                        self.send(.error(id: id, code: code, message: message), to: client)
                    case .panes, .content:
                        self.send(.error(id: id, code: "protocol", message: "unexpected pane reply"), to: client)
                    }
                }
            }
        }
    }

    /// List a directory's subdirectories for the remote pickers. Hidden
    /// directories are skipped. Empty path starts at the host user's home.
    private func remoteListDir(id: Int, path: String, client: ExtensionConnection) {
        let fm = FileManager.default
        let resolved = path.isEmpty
            ? fm.homeDirectoryForCurrentUser.path
            : (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            send(.error(id: id, code: "no_such_directory", message: "\(resolved) is not a directory on the host"), to: client)
            return
        }
        // Hidden directories are included — ~/.pi is a legitimate space; the
        // client picker decides whether to show them (off by default).
        let names = ((try? fm.contentsOfDirectory(atPath: resolved)) ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .filter { name in
                var sub: ObjCBool = false
                let full = (resolved as NSString).appendingPathComponent(name)
                return fm.fileExists(atPath: full, isDirectory: &sub) && sub.boolValue
            }
        let parent = resolved == "/" ? nil : (resolved as NSString).deletingLastPathComponent
        send(.dirListing(id: id, path: resolved, parent: parent, dirs: names), to: client)
    }

    /// Create a space from a host-side directory. Pure state — no GUI
    /// involvement — so the server handles it directly, mirroring the GUI's
    /// own addSpace (space + shell tab in one snapshot).
    private func remoteAddSpace(id: Int, path: String, client: ExtensionConnection) {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            send(.error(id: id, code: "no_such_directory", message: "\(expanded) is not a directory on the host"), to: client)
            return
        }
        guard !store.state.spaces.contains(where: { $0.path == expanded }) else {
            send(.error(id: id, code: "conflict", message: "a space for \(expanded) already exists"), to: client)
            return
        }
        let space = Space(name: (expanded as NSString).lastPathComponent, path: expanded)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: expanded)))
        do {
            try mutateState {
                $0.spaces.append(space)
                $0.tabs.append(tab)
            }
        } catch {
            send(.error(id: id, code: "persist_failed", message: String(describing: error)), to: client)
            return
        }
        send(.spaceAdded(id: id, spaceID: space.id), to: client)
    }

    private func remoteCreateAgent(id: Int, request: RemoteCreateAgentRequest, client: ExtensionConnection) {
        guard let handler = onRemoteCreateAgent else {
            send(.error(id: id, code: "unsupported", message: "host cannot create agents (no GUI)"), to: client)
            return
        }
        guard store.state.spaces.contains(where: { $0.id == request.spaceID }) else {
            send(.error(id: id, code: "no_such_space", message: "unknown space \(request.spaceID)"), to: client)
            return
        }
        let fd = client.fd
        hopToMain { [weak self] in
            handler(request) { result in
                guard let self else { return }
                self.queue.async {
                    guard let client = self.clients[fd] else { return }
                    switch result {
                    case .success(let agentID):
                        self.send(.agentCreated(id: id, agentID: agentID), to: client)
                    case .failure(let error):
                        self.send(.error(id: id, code: "create_failed", message: error.message), to: client)
                    }
                }
            }
        }
    }

    /// Raw bytes per remote output frame. Base64 expands 4/3× and the JSON
    /// envelope adds ≈100 bytes, so 256 KiB raw stays well under the 1 MiB
    /// NDJSON payload limit.
    static let remoteOutputChunkBytes = 256 * 1024
    static let remoteRenderPatchBytes = 700 * 1024

    /// Bracketed paste + optional Return — the composer's transport. One
    /// literal block regardless of newlines (raw input would submit each
    /// line), then the submit key, acked.
    private func remotePaste(id: Int, sessionID: SessionID, text: String, submit: Bool, client: ExtensionConnection) {
        guard let session = sessions[sessionID], session.isAlive else {
            send(.error(id: id, code: "no_such_session", message: "session is not running"), to: client)
            return
        }
        session.writeInput(RemoteProtocol.composedInput(text: text, submit: submit))
        send(.ok(id: id), to: client)
    }

    /// Record one viewer's grid and apply the min across viewers —
    /// smallest-screen-wins. No generation fences needed: our transport
    /// delivers reports in order per client.
    private func recordRemoteViewport(sessionID: SessionID, fd: Int32, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        remoteViewports[sessionID, default: [:]][fd] = (cols, rows)
        applyMinViewport(sessionID: sessionID)
    }

    private func applyMinViewport(sessionID: SessionID) {
        guard let session = sessions[sessionID] else { return }
        let remote = Array((remoteViewports[sessionID] ?? [:]).values)
        let grids = remote.isEmpty ? localViewports[sessionID].map { [$0] } ?? [] : remote
        guard let minCols = grids.map(\.cols).min(),
              let minRows = grids.map(\.rows).min() else { return }
        session.resize(cols: minCols, rows: minRows)
    }

    /// The host GUI's own surface size. It controls the PTY only while no
    /// remote viewers are attached; remote viewers share their own min-grid.
    public func reportLocalViewport(sessionID: SessionID, cols: Int, rows: Int) {
        queue.async {
            guard cols > 0, rows > 0 else { return }
            self.localViewports[sessionID] = (cols, rows)
            self.applyMinViewport(sessionID: sessionID)
        }
    }

    /// Attach a remote client: record its grid, apply the min, snapshot, and
    /// queue the replay — all in this queue turn, so output delivered after
    /// it can never be missing from between snapshot and stream.
    private func remoteAttach(
        id: Int,
        sessionID: SessionID,
        cols: Int,
        rows: Int,
        viewportGeneration: UInt64,
        client: ExtensionConnection
    ) {
        guard let session = sessions[sessionID] else {
            send(.error(id: id, code: "no_such_session", message: "unknown session \(sessionID)"), to: client)
            return
        }
        if cols > 0, rows > 0 {
            remoteViewports[sessionID, default: [:]][client.fd] = (cols, rows)
            applyMinViewport(sessionID: sessionID)
        }
        remoteAttachments[sessionID, default: []].insert(client.fd)
        send(.attached(
            id: id,
            attachment: RemoteAttachment(
                sessionID: sessionID,
                cols: session.screen.cols,
                rows: session.screen.rows,
                viewportGeneration: viewportGeneration
            )
        ), to: client)
        let replay = session.screen.snapshot()
        var offset = replay.startIndex
        while offset < replay.endIndex {
            let end = replay.index(offset, offsetBy: Self.remoteOutputChunkBytes, limitedBy: replay.endIndex) ?? replay.endIndex
            send(.output(sessionID: sessionID, data: replay.subdata(in: offset..<end)), to: client)
            offset = end
        }
        if !session.isAlive {
            send(.sessionExited(sessionID: sessionID, code: nil), to: client)
        }
    }

    private func streamToRemoteClients(sessionID: SessionID, data: Data) {
        guard let fds = remoteAttachments[sessionID], !fds.isEmpty else { return }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.remoteOutputChunkBytes, limitedBy: data.endIndex) ?? data.endIndex
            let chunk = data.subdata(in: offset..<end)
            for fd in fds {
                if let client = clients[fd] {
                    send(.output(sessionID: sessionID, data: chunk), to: client)
                }
            }
            offset = end
        }
    }

    private func send(_ reply: RemoteReply, to client: ExtensionConnection) {
        guard clients[client.fd] === client else { return }
        let payload: Data
        do {
            payload = try NDJSON.encode(reply)
        } catch {
            ShepherdLog.error("could not encode remote reply: \(error)")
            disconnect(client)
            return
        }
        guard payload.count - 1 <= NDJSON.maxPayloadBytes else {
            ShepherdLog.error("remote reply exceeds the payload limit on fd \(client.fd)")
            disconnect(client)
            return
        }
        enqueuePayload(payload, to: client)
    }

    /// Send a terminal reply (an auth failure) and close once it flushes.
    private func sendFinal(_ reply: RemoteReply, to client: ExtensionConnection) {
        client.closeAfterFlush = true
        send(reply, to: client)
    }

    /// Push a fresh state snapshot to every authenticated remote client.
    /// Runs on the server queue alongside the mutation that produced it.
    private func broadcastRemoteState(_ state: ShepherdState) {
        let remotes = clients.values.filter { $0.isRemote && $0.authenticated }
        guard !remotes.isEmpty else { return }
        guard let payload = try? NDJSON.encode(RemoteReply.stateChanged(state: state)),
              payload.count - 1 <= NDJSON.maxPayloadBytes else {
            ShepherdLog.error("state broadcast exceeds the payload limit; skipped")
            return
        }
        for client in remotes {
            enqueuePayload(payload, to: client)
        }
    }

    // MARK: - Extension socket (server queue)

    private func acceptPending(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                ShepherdLog.error("accept failed: errno \(errno)")
                return
            }
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            let client = ExtensionConnection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.handleReadable(fd: fd) }
            source.setCancelHandler { close(fd) }
            client.readSource = source
            clients[fd] = client
            source.activate()
            ShepherdLog.info("status extension connected (fd \(fd))")
        }
    }

    private func handleReadable(fd: Int32) {
        guard let client = clients[fd] else { return }
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                let lines: [Data]
                do {
                    lines = try client.lineBuffer.append(Data(bytes: buf, count: n))
                } catch {
                    ShepherdLog.warning("extension framing violation on fd \(fd): \(error)")
                    disconnect(client)
                    return
                }
                for line in lines {
                    guard clients[fd] === client else { return }
                    if client.isRemote {
                        handleRemoteLine(line, from: client)
                    } else {
                        handleLine(line, from: client)
                    }
                }
                continue
            }
            if n == 0 {
                disconnect(client)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            disconnect(client)
            return
        }
    }

    private func disconnect(_ client: ExtensionConnection) {
        guard clients[client.fd] === client else { return }
        clients.removeValue(forKey: client.fd)
        if client.isRemote {
            for sessionID in remoteAttachments.keys {
                remoteAttachments[sessionID]?.remove(client.fd)
            }
            for sessionID in remoteViewports.keys where remoteViewports[sessionID]?[client.fd] != nil {
                remoteViewports[sessionID]?.removeValue(forKey: client.fd)
                applyMinViewport(sessionID: sessionID)
            }
        }
        client.readSource?.cancel()
        client.readSource = nil
        client.writeSource?.cancel()
        client.writeSource = nil
        client.pendingReplies.removeAll(keepingCapacity: false)
        client.pendingReplyOffset = 0
        client.queuedReplyBytes = 0
        ShepherdLog.info("\(client.isRemote ? "remote client" : "status extension") disconnected (fd \(client.fd))")
    }

    private func handleLine(_ line: Data, from client: ExtensionConnection) {
        let message: ExtensionMessage
        do {
            message = try NDJSON.decode(ExtensionMessage.self, from: line)
        } catch {
            ShepherdLog.error("undecodable extension message: \(error)")
            return
        }
        switch message {
        case .setAgentStatus(let agentID, let status):
            applyAgentStatus(agentID: agentID, status: status)
        case .setAgentName(let agentID, let name):
            applyAgentName(agentID: agentID, name: name)
        case .setAgentSession(let agentID, let piSessionID):
            applyAgentSession(agentID: agentID, piSessionID: piSessionID)
        case .setAgentChildren(let agentID, let children):
            hopToMain { [weak self] in self?.onAgentChildren?(agentID, children) }
        case .notify(let agentID, let title, let body):
            hopToMain { [weak self] in self?.onNotify?(agentID, title, body) }
        case .helloAgent(let agentID):
            client.agentID = agentID
        case .listAgents(let id, let agentID):
            routeAgentPeerRequest(.list(agentID: agentID), requestID: id, client: client)
        case .sendToAgent(let id, let agentID, let targetAgentID, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply(.error(id: id, code: "invalid", message: "text is required"), to: client)
                return
            }
            routeAgentPeerRequest(
                .send(agentID: agentID, targetAgentID: targetAgentID, text: text),
                requestID: id,
                client: client
            )
        case .spawnAgent(let id, let agentID, let cwd, let prompt):
            guard !cwd.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                reply(.error(id: id, code: "invalid", message: "cwd and prompt are required"), to: client)
                return
            }
            routeAgentPeerRequest(
                .spawn(agentID: agentID, cwd: cwd, prompt: prompt),
                requestID: id,
                client: client
            )
        case .createAutomation(let id, let name, let prompt, let cwd, let enabled, let start):
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty, !trimmedPrompt.isEmpty, !cwd.isEmpty else {
                reply(.error(id: id, code: "invalid", message: "name, prompt, and cwd are required"), to: client)
                return
            }
            let automation = Automation(name: trimmedName, prompt: trimmedPrompt, cwd: cwd, enabled: enabled)
            routeAutomationRequest(.create(automation: automation, start: start), requestID: id, client: client)
        case .listAutomations(let id):
            routeAutomationRequest(.list, requestID: id, client: client)
        case .updateAutomation(let id, let automationID, let name, let prompt, let cwd, let enabled):
            routeAutomationRequest(
                .update(automationID: automationID, name: name, prompt: prompt, cwd: cwd, enabled: enabled),
                requestID: id,
                client: client
            )
        case .deleteAutomation(let id, let automationID):
            routeAutomationRequest(.delete(automationID: automationID), requestID: id, client: client)
        case .startAutomation(let id, let automationID):
            routeAutomationRequest(.start(automationID: automationID), requestID: id, client: client)
        case .stopAutomation(let id, let automationID):
            routeAutomationRequest(.stop(automationID: automationID), requestID: id, client: client)
        case .listPanes(let id, let agentID):
            routePaneRequest(.list(agentID: agentID), requestID: id, client: client)
        case .openPane(let id, let agentID, let axis, let cwd, let relativeTo, let command):
            routePaneRequest(
                .open(agentID: agentID, axis: axis, cwd: cwd, relativeTo: relativeTo, command: command),
                requestID: id,
                client: client
            )
        case .closePane(let id, let agentID, let paneID):
            routePaneRequest(.close(agentID: agentID, paneID: paneID), requestID: id, client: client)
        case .focusPane(let id, let agentID, let paneID):
            routePaneRequest(.focus(agentID: agentID, paneID: paneID), requestID: id, client: client)
        case .sendPaneInput(let id, let agentID, let paneID, let text, let submit):
            routePaneRequest(
                .sendInput(agentID: agentID, paneID: paneID, text: text, submit: submit),
                requestID: id,
                client: client
            )
        case .readPane(let id, let agentID, let paneID):
            routePaneRequest(.read(agentID: agentID, paneID: paneID), requestID: id, client: client)
        }
    }

    /// Push a peer-thread message to an agent's registered extension
    /// connection. Returns false when the agent has no live registered
    /// connection (extension not loaded or not yet connected).
    public func pushMessage(toAgent agentID: AgentID, text: String) -> Bool {
        queue.sync {
            guard let client = clients.values.first(where: { $0.agentID == agentID }) else {
                return false
            }
            reply(.message(id: 0, text: text), to: client)
            return true
        }
    }

    /// Hand a peer-thread request to the GUI and write its reply back, the
    /// same shape as pane routing.
    private func routeAgentPeerRequest(_ request: AgentPeerRequest, requestID: Int, client: ExtensionConnection) {
        guard let handler = onAgentPeerRequest else {
            reply(.error(id: requestID, code: "unsupported", message: "agent peers unavailable"), to: client)
            return
        }
        hopToMain { [weak self, weak client] in
            handler(request) { outcome in
                guard let self, let client else { return }
                self.queue.async { self.reply(outcome.withID(requestID), to: client) }
            }
        }
    }

    /// Hand an automation request to the GUI and write its reply back, the
    /// same shape as pane routing.
    private func routeAutomationRequest(_ request: AutomationRequest, requestID: Int, client: ExtensionConnection) {
        guard let handler = onAutomationRequest else {
            reply(.error(id: requestID, code: "unsupported", message: "automations unavailable"), to: client)
            return
        }
        hopToMain { [weak self, weak client] in
            handler(request) { outcome in
                guard let self, let client else { return }
                self.queue.async { self.reply(outcome.withID(requestID), to: client) }
            }
        }
    }

    /// Hand a pane request to the GUI and write its reply back to the client.
    /// The GUI owns layouts, so the server only correlates the request id.
    private func routePaneRequest(_ request: PaneRequest, requestID: Int, client: ExtensionConnection) {
        guard let handler = onPaneRequest else {
            reply(.error(id: requestID, code: "unsupported", message: "pane control unavailable"), to: client)
            return
        }
        hopToMain { [weak self, weak client] in
            handler(request) { outcome in
                guard let self, let client else { return }
                // Replies are written on the server queue, like every other
                // socket write, so they cannot interleave with a read.
                self.queue.async { self.reply(outcome.withID(requestID), to: client) }
            }
        }
    }

    private func reply(_ message: ExtensionReply, to client: ExtensionConnection) {
        guard clients[client.fd] === client else { return }

        let payload: Data
        do {
            let encoded = try NDJSON.encode(message)
            if encoded.count - 1 <= NDJSON.maxPayloadBytes {
                payload = encoded
            } else {
                ShepherdLog.warning(
                    "extension reply for request \(replyID(message)) exceeds the \(NDJSON.maxPayloadBytes)-byte payload limit"
                )
                payload = try NDJSON.encode(ExtensionReply.error(
                    id: replyID(message),
                    code: "reply_too_large",
                    message: "reply exceeds the maximum payload size"
                ))
            }
        } catch {
            ShepherdLog.error("could not encode extension reply: \(error)")
            disconnect(client)
            return
        }

        guard payload.count - 1 <= NDJSON.maxPayloadBytes else {
            ShepherdLog.error("reply_too_large fallback exceeded the payload limit")
            disconnect(client)
            return
        }
        enqueuePayload(payload, to: client)
    }

    /// Queue an encoded NDJSON payload on a connection's write queue, bounded
    /// by `maxQueuedReplyBytes`. Shared by extension replies and remote
    /// replies/broadcasts.
    private func enqueuePayload(_ payload: Data, to client: ExtensionConnection) {
        guard clients[client.fd] === client else { return }
        guard client.queuedReplyBytes + payload.count <= Self.maxQueuedReplyBytes else {
            ShepherdLog.warning("reply queue overflow on fd \(client.fd)")
            disconnect(client)
            return
        }
        client.pendingReplies.append(payload)
        client.queuedReplyBytes += payload.count
        drainReplies(for: client)
    }

    private func replyID(_ message: ExtensionReply) -> Int {
        switch message {
        case .ok(let id),
             .error(let id, _, _),
             .panes(let id, _),
             .paneOpened(let id, _),
             .paneContent(let id, _, _),
             .automations(let id, _),
             .agents(let id, _),
             .message(let id, _):
            return id
        }
    }

    /// Drain queued replies on the server queue. A nonblocking socket that
    /// cannot accept more bytes waits for a write-source event instead of
    /// blocking the server queue or dropping an otherwise valid reply.
    private func drainReplies(for client: ExtensionConnection) {
        guard clients[client.fd] === client else { return }

        while !client.pendingReplies.isEmpty {
            let payload = client.pendingReplies[0]
            let offset = client.pendingReplyOffset
            guard offset < payload.count else {
                client.pendingReplies.removeFirst()
                client.pendingReplyOffset = 0
                continue
            }

            let result = payload.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(client.fd, base.advanced(by: offset), payload.count - offset)
            }
            if result > 0 {
                client.pendingReplyOffset += result
                client.queuedReplyBytes -= result
                if client.pendingReplyOffset == payload.count {
                    client.pendingReplies.removeFirst()
                    client.pendingReplyOffset = 0
                }
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armReplyWriter(for: client)
                return
            }

            ShepherdLog.warning("extension reply write failed on fd \(client.fd): errno \(errno)")
            disconnect(client)
            return
        }

        client.writeSource?.cancel()
        client.writeSource = nil
        if client.closeAfterFlush {
            disconnect(client)
        }
    }

    private func armReplyWriter(for client: ExtensionConnection) {
        guard clients[client.fd] === client, client.writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
        source.setEventHandler { [weak self, weak client] in
            guard let self, let client else { return }
            self.drainReplies(for: client)
        }
        source.setCancelHandler {}
        client.writeSource = source
        source.activate()
    }

    private func applyAgentStatus(agentID: AgentID, status: AgentStatus) {
        if let index = store.state.agents.firstIndex(where: { $0.id == agentID }) {
            let current = store.state.agents[index].status
            if !current.canTransition(to: status) {
                ShepherdLog.warning("agent \(agentID): invalid status transition \(current.rawValue) -> \(status.rawValue); applying anyway")
            }
            do {
                try store.update { $0.agents[index].status = status }
            } catch {
                let persistenceError = SessionServerError.persistFailed(String(describing: error))
                ShepherdLog.error("failed to persist status for agent \(agentID): \(persistenceError)")
                return
            }
        } else {
            ShepherdLog.warning("setAgentStatus for unknown agent \(agentID); dropped")
            return
        }
        let committedState = store.state
        broadcastRemoteState(committedState)
        hopToMain { [weak self] in
            self?.onAgentStatus?(agentID, status)
            self?.onStateChanged?(committedState)
        }
    }

    /// Record which pi session an agent is in, so relaunching reopens the
    /// conversation the user was last working in rather than the original one.
    private func applyAgentSession(agentID: AgentID, piSessionID: String) {
        let trimmed = piSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = store.state.agents.firstIndex(where: { $0.id == agentID }) else {
            ShepherdLog.warning("setAgentSession for unknown agent \(agentID); dropped")
            return
        }
        guard store.state.agents[index].effectivePiSessionID != trimmed else { return }
        do {
            // A different session is a different conversation: whatever name
            // the agent wore described the old one, so naming reopens and the
            // namer extension may retitle (pi's own session name for free, or
            // one cheap call on the resumed conversation's opening prompt).
            try mutateState {
                $0.agents[index].piSessionID = trimmed
                $0.agents[index].nameIsFinal = false
            }
            ShepherdLog.info("agent \(agentID) moved to pi session \(trimmed)")
        } catch {
            ShepherdLog.error("failed to persist session for agent \(agentID): \(error)")
        }
    }

    /// Apply a namer-proposed title. Provisional names only: a user rename (or
    /// a title that already landed) marks the agent final and wins forever.
    private func applyAgentName(agentID: AgentID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = store.state.agents.firstIndex(where: { $0.id == agentID }) else {
            ShepherdLog.warning("setAgentName for unknown agent \(agentID); dropped")
            return
        }
        guard !store.state.agents[index].nameIsFinal else {
            ShepherdLog.info("setAgentName for agent \(agentID) ignored; name is final")
            return
        }
        do {
            try mutateState {
                $0.agents[index].name = trimmed
                $0.agents[index].nameIsFinal = true
            }
            ShepherdLog.info("agent \(agentID) named '\(trimmed)'")
        } catch {
            ShepherdLog.error("failed to persist name for agent \(agentID): \(error)")
        }
    }

    // MARK: - State mutations (server queue)

    /// Apply a state mutation, persist it, and notify the GUI.
    private func mutateState(_ mutate: (inout ShepherdState) -> Void) throws {
        do {
            try store.update(mutate)
        } catch {
            throw SessionServerError.persistFailed(String(describing: error))
        }
        let state = store.state
        broadcastRemoteState(state)
        hopToMain { [weak self] in self?.onStateChanged?(state) }
    }

    public func putState(_ newState: ShepherdState) async throws {
        try await enqueue {
            try self.mutateState { $0 = newState }
        }
    }

    /// Replace a tab's pane tree without allowing a stale structural snapshot
    /// to erase live pane-to-session bindings. A pane keeps its binding when
    /// the same PaneID remains in the new tree; new panes start unbound.
    public func updateLayoutStructure(tabID: TabID, layout: PaneNode) async throws {
        try await enqueue {
            guard let index = self.store.state.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw SessionServerError.noSuchTab(tabID)
            }
            let current = self.store.state.tabs[index].layout
            let merged = Self.preservingSessionBindings(from: current, in: layout)
            try self.mutateState { $0.tabs[index].layout = merged }
        }
    }

    /// Update one pane's binding without replacing the surrounding tree. This
    /// keeps a binding write safe when a structural layout write is queued
    /// before or after it.
    public func updatePaneSession(
        tabID: TabID,
        paneID: PaneID,
        sessionID: SessionID?
    ) async throws {
        try await enqueue {
            guard let index = self.store.state.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw SessionServerError.noSuchTab(tabID)
            }
            guard self.store.state.tabs[index].layout.contains(paneID) else {
                throw SessionServerError.noSuchPane(paneID)
            }
            try self.mutateState {
                $0.tabs[index].layout = $0.tabs[index].layout.updatingLeaf(paneID) {
                    $0.sessionID = sessionID
                }
            }
        }
    }

    public func addSpace(_ space: Space) async throws {
        try await enqueue {
            guard !self.store.state.spaces.contains(where: { $0.id == space.id }) else {
                throw SessionServerError.conflict("space \(space.id) already exists")
            }
            try self.mutateState { $0.spaces.append(space) }
        }
    }

    /// Add a space and its main layout in one persisted snapshot. The UI never
    /// observes a space without the shell workspace that makes it usable.
    public func addSpace(_ space: Space, withTab tab: ShepherdCore.Tab) async throws {
        try await enqueue {
            guard !self.store.state.spaces.contains(where: { $0.id == space.id }) else {
                throw SessionServerError.conflict("space \(space.id) already exists")
            }
            guard !self.store.state.tabs.contains(where: { $0.id == tab.id }) else {
                throw SessionServerError.conflict("tab \(tab.id) already exists")
            }
            guard tab.spaceID == space.id else {
                throw SessionServerError.conflict("space and tab do not match")
            }
            try self.mutateState {
                $0.spaces.append(space)
                $0.tabs.append(tab)
            }
        }
    }

    /// Remove a space with everything that lives in it: its agents, their
    /// layouts and inspector tabs, its shell workspace, and every session
    /// running in any of them. Spaces nested by path are separate entities
    /// and are untouched — they simply stop rendering as children.
    public func deleteSpace(_ spaceID: SpaceID) async throws {
        try await enqueue {
            guard self.store.state.spaces.contains(where: { $0.id == spaceID }) else {
                throw SessionServerError.noSuchSpace(spaceID)
            }
            let doomedAgents = Set(self.store.state.agents.filter { $0.spaceID == spaceID }.map(\.id))
            let doomedTabs = self.store.state.tabs.filter { tab in
                tab.spaceID == spaceID
                    || tab.inspectorFor.map(doomedAgents.contains) == true
            }
            let sessions = Set(doomedTabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) })

            // Persist the final state before terminating anything, matching
            // deleteAgent: a failed write must not leave orphaned kills.
            let doomedTabIDs = Set(doomedTabs.map(\.id))
            try self.mutateState {
                $0.spaces.removeAll { $0.id == spaceID }
                $0.agents.removeAll { doomedAgents.contains($0.id) }
                $0.tabs.removeAll { doomedTabIDs.contains($0.id) }
                for i in $0.automations.indices where $0.automations[i].agentID.map(doomedAgents.contains) == true {
                    $0.automations[i].agentID = nil
                }
            }
            for sessionID in sessions {
                self.killSessionOnQueue(sessionID)
            }
        }
    }

    public func updateSpace(_ space: Space) async throws {
        try await enqueue {
            guard let index = self.store.state.spaces.firstIndex(where: { $0.id == space.id }) else {
                throw SessionServerError.noSuchSpace(space.id)
            }
            try self.mutateState { $0.spaces[index] = space }
        }
    }

    public func addTab(_ tab: ShepherdCore.Tab) async throws {
        try await enqueue {
            guard !self.store.state.tabs.contains(where: { $0.id == tab.id }) else {
                throw SessionServerError.conflict("tab \(tab.id) already exists")
            }
            // Global shells (spaceID == nil) belong to no space.
            if let spaceID = tab.spaceID {
                guard self.store.state.spaces.contains(where: { $0.id == spaceID }) else {
                    throw SessionServerError.noSuchSpace(spaceID)
                }
            }
            try self.mutateState { $0.tabs.append(tab) }
        }
    }

    public func updateTab(_ tab: ShepherdCore.Tab) async throws {
        try await enqueue {
            guard let index = self.store.state.tabs.firstIndex(where: { $0.id == tab.id }) else {
                throw SessionServerError.noSuchTab(tab.id)
            }
            try self.mutateState { $0.tabs[index] = tab }
        }
    }

    public func removeTab(_ tabID: TabID) async throws {
        try await enqueue {
            guard self.store.state.tabs.contains(where: { $0.id == tabID }) else {
                throw SessionServerError.noSuchTab(tabID)
            }
            guard !self.store.state.agents.contains(where: { $0.tabID == tabID }) else {
                throw SessionServerError.tabInUse(tabID)
            }
            try self.mutateState {
                $0.tabs.removeAll { $0.id == tabID }
            }
        }
    }

    public func addAgent(_ agent: Agent) async throws {
        try await enqueue {
            guard !self.store.state.agents.contains(where: { $0.id == agent.id }) else {
                throw SessionServerError.conflict("agent \(agent.id) already exists")
            }
            guard self.store.state.spaces.contains(where: { $0.id == agent.spaceID }) else {
                throw SessionServerError.noSuchSpace(agent.spaceID)
            }
            guard self.store.state.tabs.contains(where: { $0.id == agent.tabID }) else {
                throw SessionServerError.noSuchTab(agent.tabID)
            }
            try self.mutateState { $0.agents.append(agent) }
        }
    }

    /// Add a top-level agent and its private layout atomically. This prevents
    /// observers from seeing an orphan tab and gives the GUI one canonical
    /// snapshot to adopt instead of racing two mutation broadcasts.
    public func addAgent(_ agent: Agent, withTab tab: ShepherdCore.Tab) async throws {
        try await enqueue {
            guard !self.store.state.agents.contains(where: { $0.id == agent.id }) else {
                throw SessionServerError.conflict("agent \(agent.id) already exists")
            }
            guard !self.store.state.tabs.contains(where: { $0.id == tab.id }) else {
                throw SessionServerError.conflict("tab \(tab.id) already exists")
            }
            guard self.store.state.spaces.contains(where: { $0.id == agent.spaceID }) else {
                throw SessionServerError.noSuchSpace(agent.spaceID)
            }
            guard agent.tabID == tab.id else {
                throw SessionServerError.conflict("agent \(agent.id) does not reference tab \(tab.id)")
            }
            guard agent.spaceID == tab.spaceID else {
                throw SessionServerError.conflict("agent and tab belong to different spaces")
            }
            try self.mutateState {
                $0.tabs.append(tab)
                $0.agents.append(agent)
            }
        }
    }

    public func updateAgent(_ agent: Agent) async throws {
        try await enqueue {
            guard let index = self.store.state.agents.firstIndex(where: { $0.id == agent.id }) else {
                throw SessionServerError.noSuchAgent(agent.id)
            }
            try self.mutateState { $0.agents[index] = agent }
        }
    }

    /// Persist a hand-entered agent title without replacing the rest of the
    /// agent snapshot that may have changed since the UI rendered it.
    public func renameAgent(_ agentID: AgentID, to name: String) async throws {
        try await enqueue {
            guard let index = self.store.state.agents.firstIndex(where: { $0.id == agentID }) else {
                throw SessionServerError.noSuchAgent(agentID)
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, self.store.state.agents[index].name != trimmed else { return }
            try self.mutateState {
                $0.agents[index].name = trimmed
                $0.agents[index].nameIsFinal = true
            }
        }
    }

    public func removeAgent(_ agentID: AgentID) async throws {
        try await enqueue {
            guard self.store.state.agents.contains(where: { $0.id == agentID }) else {
                throw SessionServerError.noSuchAgent(agentID)
            }
            try self.mutateState {
                $0.agents.removeAll { $0.id == agentID }
                for i in $0.automations.indices where $0.automations[i].agentID == agentID {
                    $0.automations[i].agentID = nil
                }
            }
        }
    }

    // MARK: - Automations (server queue)

    public func addAutomation(_ automation: Automation) async throws {
        try await enqueue {
            guard !self.store.state.automations.contains(where: { $0.id == automation.id }) else {
                throw SessionServerError.conflict("automation \(automation.id) already exists")
            }
            try self.mutateState { $0.automations.append(automation) }
        }
    }

    public func updateAutomation(_ automation: Automation) async throws {
        try await enqueue {
            guard let index = self.store.state.automations.firstIndex(where: { $0.id == automation.id }) else {
                throw SessionServerError.noSuchAutomation(automation.id)
            }
            try self.mutateState { $0.automations[index] = automation }
        }
    }

    /// Remove the saved automation only; a running agent keeps running and
    /// stays in the sidebar as an ordinary agent.
    public func removeAutomation(_ automationID: AutomationID) async throws {
        try await enqueue {
            guard self.store.state.automations.contains(where: { $0.id == automationID }) else {
                throw SessionServerError.noSuchAutomation(automationID)
            }
            try self.mutateState { $0.automations.removeAll { $0.id == automationID } }
        }
    }

    /// Delete a top-level agent in one server queue turn: remove the agent and
    /// its private layout together, then terminate every process in its
    /// layout. The GUI never observes the invalid intermediate state where
    /// only one side of that relationship exists.
    public func deleteAgent(_ agentID: AgentID) async throws {
        try await enqueue {
            guard let agent = self.store.state.agents.first(where: { $0.id == agentID }) else {
                throw SessionServerError.noSuchAgent(agentID)
            }
            guard let tab = self.store.state.tabs.first(where: { $0.id == agent.tabID }) else {
                throw SessionServerError.noSuchTab(agent.tabID)
            }

            // The agent's own layout plus its inspector tab (if any) die
            // together — an inspector without its agent is meaningless.
            let doomedTabs = self.store.state.tabs.filter {
                $0.id == agent.tabID || $0.inspectorFor == agentID
            }
            let layoutSessions = Set(doomedTabs.flatMap { $0.layout.leaves.compactMap(\.sessionID) })

            // Persist the valid final state before terminating anything. If
            // persistence fails, the user's processes and workspace remain
            // untouched rather than becoming an unrecorded partial deletion.
            let doomedTabIDs = Set(doomedTabs.map(\.id))
            try self.mutateState {
                $0.agents.removeAll { $0.id == agentID }
                $0.tabs.removeAll { doomedTabIDs.contains($0.id) }
                // The automation outlives its run; it just stops running.
                for i in $0.automations.indices where $0.automations[i].agentID == agentID {
                    $0.automations[i].agentID = nil
                }
            }

            for sessionID in layoutSessions {
                self.killSessionOnQueue(sessionID)
            }
        }
    }

    // MARK: - Sessions (server queue)

    public func listSessions() async -> [SessionInfo] {
        await enqueueValue {
            self.sessions.values.map(\.info).sorted { $0.id.rawValue < $1.id.rawValue }
        }
    }

    /// Read one runtime's current liveness without exposing the session
    /// object. Dead sessions remain queryable until explicit retirement.
    public func sessionInfo(sessionID: SessionID) async -> SessionInfo? {
        await enqueueValue { self.sessions[sessionID]?.info }
    }

    public func createSession(params: CreateSessionParams) async throws -> SessionInfo {
        try await enqueue {
            try self.makeSessionOnQueue(params: params)
        }
    }

    private func makeSessionOnQueue(params: CreateSessionParams) throws -> SessionInfo {
        let server = self
        weak let serverWeak = server
        let sessionQueue = DispatchQueue(label: "shepherd.pty", target: queue)
        let session = try PTYSession(params: params, queue: sessionQueue)
        let sid = session.id
        session.onOutput = { [weak serverWeak] data in
            serverWeak?.deliverOutput(sessionID: sid, data: data)
        }
        session.onExit = { [weak serverWeak] code in
            serverWeak?.sessionDidExit(sid, code: code)
        }
        sessions[sid] = session
        outputStates[sid] = SessionOutputState()
        session.start()
        ShepherdLog.info(
            "session \(sid) created \(params.cols)x\(params.rows): \(session.command.joined(separator: " "))"
        )
        return session.info
    }

    /// Attach atomically and return the screen replay plus the output
    /// watermark represented by that replay.
    public func attachSnapshot(sessionID: SessionID, replay: Bool) async throws -> AttachmentSnapshot {
        try await enqueue {
            guard let session = self.sessions[sessionID] else {
                throw SessionServerError.noSuchSession(sessionID)
            }
            // Same queue turn as registration: no output can slip between the
            // snapshot and the caller seeing `attached`.
            self.attachedSessions.insert(sessionID)
            // Anything still buffered was already fed into `screen`, so the
            // snapshot represents it. Delivering it as well would replay that
            // output on top of the snapshot — which showed up as pi's splash
            // screen drawn twice, with two prompt boxes.
            if let output = self.outputStates[sessionID] {
                output.pending.removeAll(keepingCapacity: true)
                output.pendingBytes = 0
                output.delivery?.cancel()
                if output.readSuspended {
                    session.resumeOutputReading()
                    output.readSuspended = false
                }
                self.deliverPendingExitIfReady(sessionID: sessionID)
                return AttachmentSnapshot(
                    replay: replay ? session.screen.snapshot() : Data(),
                    outputSequence: output.outputSequence
                )
            }
            self.deliverPendingExitIfReady(sessionID: sessionID)
            return AttachmentSnapshot(
                replay: replay ? session.screen.snapshot() : Data(),
                outputSequence: 0
            )
        }
    }

    /// Compatibility wrapper for callers that only need the replay bytes.
    public func attach(sessionID: SessionID, replay: Bool) async throws -> Data {
        try await attachSnapshot(sessionID: sessionID, replay: replay).replay
    }

    public func detach(sessionID: SessionID) {
        queue.async {
            self.attachedSessions.remove(sessionID)
            // A detached pane has nowhere to deliver; drop what was buffered.
            if let output = self.outputStates[sessionID] {
                output.pending.removeAll(keepingCapacity: true)
                output.pendingBytes = 0
                output.delivery?.cancel()
                if output.readSuspended {
                    self.sessions[sessionID]?.resumeOutputReading()
                    output.readSuspended = false
                }
            }
            self.deliverPendingExitIfReady(sessionID: sessionID)
        }
    }

    /// Fire-and-forget input write (dead sessions ignore input). Calls are
    /// ordered: each is enqueued on the server queue in submission order.
    public func write(sessionID: SessionID, data: Data) {
        queue.async {
            guard let session = self.sessions[sessionID], session.isAlive else { return }
            session.writeInput(data)
        }
    }

    /// Visible rows of a session's screen, trailing blank lines trimmed. Lets
    /// an agent read what a pane it opened has printed.
    /// Foreground process name of a session's PTY ("zsh", "pi", "htop"),
    /// for display. Nil for unknown sessions or dead children.
    public func foregroundProcessName(sessionID: SessionID) async -> String? {
        await enqueueValue { self.sessions[sessionID]?.foregroundProcessName }
    }

    /// Current working directory of the foreground process in a session's PTY.
    public func foregroundWorkingDirectory(sessionID: SessionID) async -> String? {
        await enqueueValue { self.sessions[sessionID]?.foregroundWorkingDirectory }
    }

    /// Foreground command line of a session's PTY ("pi --model x"), for
    /// shell restore. Nil at a bare prompt.
    public func foregroundCommandLine(sessionID: SessionID) async -> String? {
        await enqueueValue { self.sessions[sessionID]?.foregroundCommandLine }
    }

    public func screenText(sessionID: SessionID) async -> [String]? {
        await enqueueValue {
            guard let session = self.sessions[sessionID] else { return nil }
            var lines = session.screen.visibleText()
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            return lines
        }
    }

    public func resize(sessionID: SessionID, cols: Int, rows: Int) {
        queue.async {
            guard let session = self.sessions[sessionID] else { return }
            session.resize(cols: cols, rows: rows)
        }
    }

    public func killSession(_ sessionID: SessionID) {
        queue.async { self.killSessionOnQueue(sessionID) }
    }

    private func killSessionOnQueue(_ sessionID: SessionID) {
        guard let session = sessions[sessionID] else { return }
        if session.isAlive {
            ShepherdLog.info("session \(sessionID) kill requested; sending SIGTERM to its process group")
            session.signalProcessGroup(SIGTERM)
        } else {
            // reap() already killed the remaining process group members.
            return
        }
        queue.asyncAfter(deadline: .now() + .seconds(3)) { [weak self] in
            guard let self, let session = self.sessions[sessionID], session.isAlive else { return }
            ShepherdLog.warning("session \(sessionID) survived SIGTERM; sending SIGKILL to its process group")
            session.signalProcessGroup(SIGKILL)
        }
    }

    /// Release a dead session after its consumer has handled the final exit
    /// callback. Late attach remains possible until this method runs.
    public func retireSession(sessionID: SessionID) async {
        await enqueueValue {
            guard let session = self.sessions[sessionID] else { return }
            guard !session.isAlive else {
                ShepherdLog.warning("session \(sessionID) retirement ignored while it is still alive")
                return
            }
            self.sessions.removeValue(forKey: sessionID)
            self.attachedSessions.remove(sessionID)
            self.outputStates[sessionID]?.delivery?.cancel()
            self.outputStates.removeValue(forKey: sessionID)
            self.remoteViewports.removeValue(forKey: sessionID)
            self.localViewports.removeValue(forKey: sessionID)
            ShepherdLog.info("session \(sessionID) retired")
        }
    }

    /// Queue PTY output for the GUI without letting a stalled renderer grow
    /// the queue forever. The PTY has already fed these bytes into its screen,
    /// so dropping them is only valid after detach or when attach snapshots
    /// replace the pending live delivery.
    private func deliverOutput(sessionID: SessionID, data: Data) {
        guard let output = outputStates[sessionID] else { return }
        output.outputSequence &+= 1
        // Remote streaming happens on the server queue in delivery order and
        // is independent of the GUI's attach state — a headless host has no
        // GUI viewer, and the remote client must still receive output.
        streamToRemoteClients(sessionID: sessionID, data: data)
        guard attachedSessions.contains(sessionID),
              let session = sessions[sessionID] else { return }

        output.pending.append(.init(data: data, sequence: output.outputSequence))
        output.pendingBytes += data.count
        if output.outstandingBytes >= Self.outputHighWaterMark, !output.readSuspended {
            session.suspendOutputReading()
            output.readSuspended = true
        }
        scheduleOutputDelivery(sessionID: sessionID)
    }

    /// Run on the server queue. Exactly one callback may be in flight on the
    /// main queue for a session. A bounded slice keeps each renderer call
    /// short even when the PTY delivered a large burst before the queue turn.
    private func scheduleOutputDelivery(sessionID: SessionID) {
        guard attachedSessions.contains(sessionID),
              let output = outputStates[sessionID],
              output.delivery == nil,
              !output.pending.isEmpty else { return }

        var data = Data()
        data.reserveCapacity(min(output.pendingBytes, Self.maxOutputDeliveryBytes))
        var endSequence: UInt64 = 0
        while data.count < Self.maxOutputDeliveryBytes, !output.pending.isEmpty {
            let remaining = Self.maxOutputDeliveryBytes - data.count
            if output.pending[0].data.count <= remaining {
                let chunk = output.pending.removeFirst()
                data.append(chunk.data)
                output.pendingBytes -= chunk.data.count
                endSequence = chunk.sequence
            } else {
                let prefix = output.pending[0].data.prefix(remaining)
                data.append(contentsOf: prefix)
                output.pending[0].data.removeFirst(remaining)
                output.pendingBytes -= remaining
                endSequence = output.pending[0].sequence
            }
        }
        output.delivery = OutputDelivery(data: data, endSequence: endSequence)

        let delivery = output.delivery!
        hopToMain { [weak self] in
            guard let self else { return }
            if !delivery.isCancelled {
                self.onOutput?(sessionID, delivery.data)
                self.onSequencedOutput?(sessionID, delivery.data, delivery.endSequence)
            }
            self.queue.async { [weak self] in
                self?.finishOutputDelivery(sessionID: sessionID, delivery: delivery)
            }
        }
    }

    /// Run on the server queue after the main callback returns.
    private func finishOutputDelivery(sessionID: SessionID, delivery: OutputDelivery) {
        guard let output = outputStates[sessionID],
              output.delivery === delivery else { return }
        output.delivery = nil

        if output.readSuspended,
           output.outstandingBytes <= Self.outputLowWaterMark {
            sessions[sessionID]?.resumeOutputReading()
            output.readSuspended = false
        }
        scheduleOutputDelivery(sessionID: sessionID)
        deliverPendingExitIfReady(sessionID: sessionID)
    }

    private func sessionDidExit(_ sessionID: SessionID, code: Int32?) {
        ShepherdLog.info("session \(sessionID) exited (code \(code.map(String.init) ?? "signal"))")
        if let fds = remoteAttachments[sessionID] {
            for fd in fds {
                if let client = clients[fd] {
                    send(.sessionExited(sessionID: sessionID, code: code), to: client)
                }
            }
            remoteAttachments.removeValue(forKey: sessionID)
        }
        guard let output = outputStates[sessionID],
              output.delivery != nil || !output.pending.isEmpty else {
            notifySessionExit(sessionID: sessionID, code: code)
            return
        }
        output.exitPending = true
        output.exitCode = code
    }

    /// Keep the exit callback behind all output that was read before the
    /// process died. The app retires a session from that callback, so sending
    /// it first would discard the tail of a large command.
    private func deliverPendingExitIfReady(sessionID: SessionID) {
        guard let output = outputStates[sessionID],
              output.exitPending,
              output.delivery == nil,
              output.pending.isEmpty else { return }
        let code = output.exitCode
        output.exitPending = false
        notifySessionExit(sessionID: sessionID, code: code)
    }

    private func notifySessionExit(sessionID: SessionID, code: Int32?) {
        hopToMain { [weak self] in self?.onSessionExited?(sessionID, code) }
    }

    // MARK: - Queue plumbing

    /// Merge only the bindings belonging to PaneIDs that survive a structural
    /// replacement. Layout callers do not own session IDs, so the current
    /// server snapshot wins even when the incoming leaf carries a stale value.
    private static func preservingSessionBindings(from current: PaneNode, in requested: PaneNode) -> PaneNode {
        switch requested {
        case .leaf(var pane):
            pane.sessionID = current.leaf(withID: pane.id)?.sessionID
            return .leaf(pane)
        case .split(let axis, let ratio, let first, let second):
            return .split(
                axis: axis,
                ratio: ratio,
                first: preservingSessionBindings(from: current, in: first),
                second: preservingSessionBindings(from: current, in: second)
            )
        }
    }

    /// Run on the server queue and resume the caller with the result.
    private func enqueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enqueueValue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    /// Callbacks are delivered on the main actor, FIFO with respect to server
    /// queue order (the main queue preserves submission order).
    private func hopToMain(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }

    // MARK: - Socket helpers

    private func probeLiveSocket() -> Bool {
        guard var addr = try? Self.socketAddress(for: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0
    }

    static func socketAddress(for path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = path.utf8CString
        guard bytes.count <= capacity else {
            throw SessionServerError.socketPathTooLong(path: path)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
            }
        }
        return addr
    }
}
