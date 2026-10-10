import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol

public enum RemoteHostClientError: Error, CustomStringConvertible, Sendable {
    case resolveFailed(host: String)
    case system(call: String, errno: Int32)
    case rejected(code: String, message: String)
    case outcomeUnknown(message: String)
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
        case .outcomeUnknown(let message): return message
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
/// making a fresh client. A connection that fails during `connect` is reported
/// only by what `connect` throws: a host refusing the token replies and then
/// closes, and the close must not stand in for the refusal.
public final class RemoteHostClient: @unchecked Sendable {
    /// Remote host state pushed after every host-side mutation. Main queue.
    public var onStateChanged: ((ShepherdState) -> Void)?
    /// PTY output (replay or live) for an attached session. Main queue.
    public var onOutput: ((SessionID, Data) -> Void)?
    /// An attached session's process exited. Main queue.
    public var onSessionExited: ((SessionID, Int32?) -> Void)?
    /// A connection `connect` returned died (readable EOF, write failure, or
    /// `disconnect`). Fired at most once, on the main queue.
    public var onDisconnected: ((String) -> Void)?
    /// A design this client watches changed on the host (`RemoteDesignRequest.watch`): its files'
    /// new revision, its comments', or both. A hint to pull. Main queue.
    public var onDesignChanged: ((DesignID, UInt64?, UInt64?) -> Void)?
    public var onProjectExecutionChanged: ((ProjectExecutionKey, UInt64) -> Void)?
    /// What the host offers changed while connected (its Design tool turned on or off);
    /// `capabilities` already holds the new list. Main queue.
    public var onCapabilitiesChanged: ((Set<String>) -> Void)?
    /// What the host says about an agent's browser (`BrowserDrivePush`): a request to run on this
    /// client's page, the agent's queue given up, this client's claim ended, the user's message
    /// that hands the page back, or a page the agent opened on the host. Main queue, in order.
    public var onBrowserDrive: ((BrowserDrivePush) -> Void)?
    /// What the host offers. Written on the client's queue (at hello, and when the host pushes a
    /// change) and read from any thread, so it sits behind a lock.
    public private(set) var capabilities: Set<String> {
        get { capabilityLock.lock(); defer { capabilityLock.unlock() }; return storedCapabilities }
        set { capabilityLock.lock(); storedCapabilities = newValue; capabilityLock.unlock() }
    }
    private let capabilityLock = NSLock()
    private var storedCapabilities: Set<String> = []

    private let queue = DispatchQueue(label: "shepherd.remote.client")
    private var connectionGeneration = UUID()
    private let socketOpen: (@Sendable (String, UInt16) throws -> Int32)?
    private var pendingOpen: RemoteSocketOpen?
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var lineBuffer = LineBuffer()
    private var pendingWrites: [Data] = []
    private var pendingWriteOffset = 0
    /// Bytes not yet written: what `pendingWrites` holds, less the offset into the first.
    private var pendingWriteBytes = 0
    private var nextRequestID = 1
    private var pendingReplies: [Int: CheckedContinuation<RemoteReply, Error>] = [:]
    private var disconnectNotified = false
    /// `connect` returned this connection; until then its failures are thrown, not notified.
    private var established = false
    private var uploading = false // Client queue owns the one active transfer.

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
        case designChanged(DesignID, UInt64?, UInt64?)
        case projectExecutionChanged(ProjectExecutionKey, UInt64)
        case capabilities(Set<String>)
        case browserDrive(BrowserDrivePush)
    }
    private var pendingEvents: [PushedEvent] = []
    private var deliveryInFlight = false

    private static let requestTimeout: TimeInterval = 10
    private static let maxQueuedWriteBytes = 8 * 1024 * 1024

    /// This connection's Browser tunnels (`RemoteProtocol.browserTunnelCapability`): opened on
    /// demand for a viewer's web view, ended with the connection. Runs on this client's queue.
    public let tunnels: BrowserTunnelHub

    public init() {
        socketOpen = nil
        tunnels = BrowserTunnelHub(queue: queue)
        tunnels.link = self
    }

    // Allows the pending-open lifecycle to be checked without relying on DNS timing.
    init(socketOpen: @escaping @Sendable (String, UInt16) throws -> Int32) {
        self.socketOpen = socketOpen
        tunnels = BrowserTunnelHub(queue: queue)
        tunnels.link = self
    }

    deinit {
        pendingOpen?.cancel()
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
        let opening = RemoteSocketOpen()
        let attempt = try queue.sync {
            guard self.fd < 0 else {
                throw RemoteHostClientError.system(call: "connect", errno: EISCONN)
            }
            pendingOpen?.cancel()
            pendingOpen = opening
            connectionGeneration = UUID()
            return connectionGeneration
        }
        return try await withTaskCancellationHandler {
            let fd: Int32
            do {
                fd = try await opening.open(host: host, port: port, override: socketOpen)
            } catch {
                queue.sync { if connectionGeneration == attempt { pendingOpen = nil } }
                throw error
            }

            try queue.sync {
                guard !Task.isCancelled, connectionGeneration == attempt else {
                    close(fd)
                    throw CancellationError()
                }
                pendingOpen = nil
                self.fd = fd
                disconnectNotified = false
                established = false
                lineBuffer = LineBuffer()
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.handleReadable() }
                source.setCancelHandler { close(fd) }
                self.readSource = source
                source.activate()
            }

            do {
                let helloReply = try await request(connectionGeneration: attempt) { id in
                    .hello(id: id, token: token, clientName: clientName, protocolVersion: RemoteProtocol.version,
                           capabilities: RemoteProtocol.clientCapabilities)
                }
                guard case .helloOk(_, _, let capabilities) = helloReply else {
                    if case .error(_, let code, let message) = helloReply {
                        throw RemoteHostClientError.rejected(code: code, message: message)
                    }
                    throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected hello reply")
                }
                try queue.sync {
                    guard connectionGeneration == attempt else {
                        throw Task.isCancelled ? CancellationError() : RemoteHostClientError.disconnected
                    }
                    self.capabilities = Set(capabilities)
                }
                let stateReply = try await request(connectionGeneration: attempt) { id in .stateFetch(id: id) }
                guard case .state(_, let state) = stateReply else {
                    throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected state reply")
                }
                try queue.sync {
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard connectionGeneration == attempt else { throw RemoteHostClientError.disconnected }
                    established = true
                }
                return Self.shown(state, capabilities: Set(capabilities))
            } catch {
                queue.sync {
                    if connectionGeneration == attempt { teardown(reason: "connection failed") }
                }
                throw error
            }
        } onCancel: {
            self.queue.sync {
                if self.connectionGeneration == attempt { self.teardown(reason: "cancelled") }
            }
        }
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

    /// The host's pi models, its configured default, and which take no thinking level.
    public func listModels() async throws -> ModelListing {
        let reply = try await request { id in .listModels(id: id) }
        guard case .models(_, let models, let defaultModel, let withoutThinking, let thinkingLevels, let serviceTiers, let contexts) = reply else {
            if case .error(_, let code, let message) = reply {
                throw RemoteHostClientError.rejected(code: code, message: message)
            }
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected listModels reply")
        }
        return ModelListing(models: models, defaultModel: defaultModel, withoutThinking: withoutThinking,
                            thinkingLevels: thinkingLevels, serviceTiers: serviceTiers, contexts: contexts)
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
        initialPrompt: String?,
        worktreeBranch: String? = nil,
        worktreeBase: String? = nil,
        worktreeFetchFirst: Bool? = nil,
        initialImages: [NativeImage] = [],
        serviceTier: ServiceTier? = nil
    ) async throws -> AgentID {
        if serviceTier != nil, !capabilities.contains(RemoteProtocol.createAgentServiceTierCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to choose a new thread's speed.")
        }
        // An older host would drop the images and start the thread without them.
        if !initialImages.isEmpty, !capabilities.contains(RemoteProtocol.createAgentImagesCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: Self.createAgentImagesRefusal)
        }
        if worktreeBase != nil || worktreeFetchFirst != nil, !capabilities.contains(RemoteProtocol.creationOptionsCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to choose worktree creation options.")
        }
        if worktreeBranch != nil, !capabilities.contains(RemoteProtocol.worktreeActionsCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to create worktree agents.")
        }
        let images = initialImages.isEmpty ? nil : initialImages
        if images != nil, Self.overFrame(.createAgent(id: 0, spaceID: spaceID, cwd: cwd, model: model, thinking: thinking,
                                                      initialPrompt: initialPrompt, worktreeBranch: worktreeBranch,
                                                      worktreeBase: worktreeBase, worktreeFetchFirst: worktreeFetchFirst,
                                                      initialImages: images, serviceTier: serviceTier)) {
            throw RemoteHostClientError.rejected(code: "too_large", message: Self.imagesTooLarge)
        }
        let reply = try await request(timeout: 120) { id in
            .createAgent(
                id: id,
                spaceID: spaceID,
                cwd: cwd,
                model: model,
                thinking: thinking,
                initialPrompt: initialPrompt,
                worktreeBranch: worktreeBranch,
                worktreeBase: worktreeBase,
                worktreeFetchFirst: worktreeFetchFirst,
                initialImages: images,
                serviceTier: serviceTier
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

    public func creationOptions(spaceID: SpaceID, cwd: String?, fetchFirst: Bool?) async throws -> RemoteCreationOptions {
        guard capabilities.contains(RemoteProtocol.creationOptionsCapability) else {
            guard cwd == nil, fetchFirst == nil else {
                throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to choose worktree creation options.")
            }
            let listing = try await listModels()
            return RemoteCreationOptions(base: "", note: "", fetchFirst: false, model: listing.defaultModel, thinking: .medium)
        }
        let reply = try await request(timeout: 120) { .creationOptions(id: $0, spaceID: spaceID, cwd: cwd, fetchFirst: fetchFirst) }
        if case .creationOptions(_, let options) = reply { return options }
        if case .error(_, let code, let message) = reply { throw RemoteHostClientError.rejected(code: code, message: message) }
        throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected creation options reply")
    }

    public func upload(file: URL, sessionID: SessionID) async throws -> String {
        guard capabilities.contains(RemoteProtocol.uploadCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to drop files or images.")
        }
        try queue.sync {
            guard !uploading else {
                throw RemoteHostClientError.rejected(code: "upload_busy", message: "A file drop is already uploading to this host")
            }
            uploading = true
        }
        defer { queue.sync { uploading = false } }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= RemoteProtocol.uploadMaxBytes else {
            throw RemoteHostClientError.rejected(code: "upload_failed", message: "Drop regular files no larger than 32 MiB. Directories are not supported.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let begin = try await request { .upload(id: $0, action: .begin(sessionID: sessionID, name: file.lastPathComponent, size: size)) }
        if case .error(_, let code, let message) = begin { throw RemoteHostClientError.rejected(code: code, message: message) }
        guard case .uploadResult(_, .ready(let uploadID)) = begin else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected upload reply")
        }
        do {
            while let data = try handle.read(upToCount: RemoteProtocol.uploadChunkBytes), !data.isEmpty {
                try Task.checkCancellation()
                let reply = try await request { .upload(id: $0, action: .chunk(uploadID: uploadID, data: data)) }
                if case .error(_, let code, let message) = reply { throw RemoteHostClientError.rejected(code: code, message: message) }
            }
            let reply = try await request { .upload(id: $0, action: .finish(uploadID: uploadID)) }
            if case .uploadResult(_, .complete(let path)) = reply { return path }
            if case .error(_, let code, let message) = reply { throw RemoteHostClientError.rejected(code: code, message: message) }
            throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected upload completion")
        } catch {
            _ = try? await request { .upload(id: $0, action: .cancel(uploadID: uploadID)) }
            throw error
        }
    }

    /// Why a host without `createAgentImagesCapability` cannot start a thread with images.
    public static let createAgentImagesRefusal = "Update Shepherd on the host to start a thread with images."
    static let imagesTooLarge = "Images exceed the remote payload limit. Send fewer or smaller images."
    /// Design references go only into a thread on the Mac that runs it (docs/designs.md › Design
    /// references), never over the remote listener.
    public static let designReferencesRefusal = "Design references can't go to a thread on another Mac yet: send it from that Mac."


    /// One NDJSON frame per request: the host drops anything over the cap.
    static func overFrame(_ request: RemoteRequest) -> Bool {
        guard let bytes = try? NDJSON.encode(request).count else { return false }
        return bytes - 1 > NDJSON.maxPayloadBytes
    }

    /// Why a host with `capabilities` cannot take `request` (it predates it), or nil.
    static func missingCapability(_ request: NativeThreadRequest, capabilities: Set<String>) -> String? {
        switch request {
        case .setModel, .setThinking:
            capabilities.contains(RemoteProtocol.nativeThreadV2Capability) ? nil : "Update Shepherd on the host to change the model or thinking level."
        case .queue(_, _, _, .interrupt):
            capabilities.contains(RemoteProtocol.nativeInterruptCapability) ? nil : "Update Shepherd on the host to steer now."
        case .send(_, _, _, _, .interrupt, _, _, _, _):
            capabilities.contains(RemoteProtocol.nativeInterruptCapability) ? nil : "Update Shepherd on the host to steer now."
        case .queue:
            capabilities.contains(RemoteProtocol.nativeQueueCapability) ? nil : "Update Shepherd on the host to change its queue."
        case .compact:
            capabilities.contains(RemoteProtocol.nativeContextCapability) ? nil : "Update Shepherd on the host to compact the context."
        case .retry:
            capabilities.contains(RemoteProtocol.nativeRetryCapability) ? nil : "Update Shepherd on the host to retry a turn in place."
        case .goal:
            capabilities.contains(RemoteProtocol.nativeGoalCapability) ? nil : "Update Shepherd on the host to control goals."
        case .setServiceTier:
            capabilities.contains(RemoteProtocol.nativeServiceTierCapability) ? nil : "Update Shepherd on the host to change its speed."
        case .send where !request.images.isEmpty:
            capabilities.contains(RemoteProtocol.nativeThreadV2Capability) ? nil : "Update Shepherd on the host to send images."
        default:
            nil
        }
    }

    /// The request as this host takes it: a send's design context stays only where the host
    /// takes one (an older host would drop it anyway); the message goes either way.
    static func outgoing(_ request: NativeThreadRequest, capabilities: Set<String>) -> NativeThreadRequest {
        capabilities.contains(RemoteProtocol.designContextCapability) ? request : request.droppingDesignContext
    }

    /// The result as this client acts on it: a snapshot lists `retry` only from a host that
    /// retries in place (`native.retry.v1`), so the thread sends the prompt again anywhere else,
    /// and `interrupt` only from one that stops pi for a message (`native.interrupt.v1`), so the
    /// thread steers there; `setServiceTier` only from one that keeps each agent's tier
    /// (`native.serviceTier.v1`), so the composer draws no Speed control anywhere else.
    static func incoming(_ result: NativeThreadResult, capabilities: Set<String>) -> NativeThreadResult {
        guard case .snapshot(var value) = result else { return result }
        let before = value.supportedActions
        for (capability, action) in [(RemoteProtocol.nativeRetryCapability, "retry"), (RemoteProtocol.nativeInterruptCapability, "interrupt"),
                                     (RemoteProtocol.nativeServiceTierCapability, "setServiceTier"), (RemoteProtocol.nativeGoalCapability, "goal")]
        where !capabilities.contains(capability) {
            value.supportedActions.removeAll { $0 == action }
        }
        return value.supportedActions == before ? result : .snapshot(value: value)
    }

    public func nativeThread(agentID: AgentID, request original: NativeThreadRequest) async throws -> NativeThreadResult {
        let command = Self.outgoing(original, capabilities: capabilities)
        guard capabilities.contains(RemoteProtocol.nativeThreadCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to view native threads.")
        }
        if let missing = Self.missingCapability(command, capabilities: capabilities) {
            throw RemoteHostClientError.rejected(code: "update_required", message: missing)
        }
        if let references = command.designReferences, !references.isEmpty {
            throw RemoteHostClientError.rejected(code: "design_references_local", message: Self.designReferencesRefusal)
        }
        switch command {
        case .send where !command.images.isEmpty:
            if Self.overFrame(.nativeThread(id: 0, agentID: agentID, request: command)) {
                throw RemoteHostClientError.rejected(code: "too_large", message: Self.imagesTooLarge)
            }
        default: break
        }
        let reply: RemoteReply
        do {
            reply = try await request(timeout: 15) { .nativeThread(id: $0, agentID: agentID, request: command) }
        } catch RemoteHostClientError.timeout {
            throw RemoteHostClientError.outcomeUnknown(message: "Native request timed out. Refresh before acting; do not automatically retry.")
        } catch RemoteHostClientError.disconnected {
            throw RemoteHostClientError.outcomeUnknown(message: "Connection lost. Refresh before acting; do not automatically retry.")
        }
        let legacy = !capabilities.contains(RemoteProtocol.nativeThreadStartingCapability)
        if case .nativeThread(_, let result) = reply {
            if case .failure(let code, let message) = result {
                return .failure(code: Self.availabilityCode(code, legacyHost: legacy), message: message)
            }
            return Self.incoming(result, capabilities: capabilities)
        }
        if case .error(_, let code, let message) = reply {
            if code == "outcome_unknown" { throw RemoteHostClientError.outcomeUnknown(message: message) }
            throw RemoteHostClientError.rejected(code: Self.availabilityCode(code, legacyHost: legacy), message: message)
        }
        throw RemoteHostClientError.outcomeUnknown(message: "Native action outcome unknown. Refresh before acting; do not automatically retry.")
    }

    /// A host from before `native_starting` answered `native_unavailable` while an agent's pi
    /// started (its pane not bound yet, or pi not answering yet). Such a host retires an agent
    /// whose pi exits, so an agent it still lists is almost always starting: read it as that.
    /// The store's starting limit bounds the rare agent whose launch failed there.
    static func availabilityCode(_ code: String, legacyHost: Bool) -> String {
        legacyHost && code == NativeThreadCode.unavailable ? NativeThreadCode.starting : code
    }

    /// The capability a host must advertise before `query` is sent to it.
    public static func capability(for query: RemoteAgentQuery) -> String {
        switch query {
        case .worktreeSetup, .worktreeCommitCount, .worktreeDescription: RemoteProtocol.worktreeSetupCapability
        case .deleteKeepingWorktree, .worktreeInfo, .deleteWorktree, .finalizeWorktree, .worktreeStatus: RemoteProtocol.worktreeActionsCapability
        case .commitInfo, .commitMessage, .commit: RemoteProtocol.reviewCommitCapability
        case .terminals: RemoteProtocol.terminalActivityCapability
        case .devServers: RemoteProtocol.browserTunnelCapability
        case .changesOverview, .changesList, .changesFile, .changesBranches, .changesPatch, .changesUndoTurn, .changesRedoTurn:
            RemoteProtocol.changesCapability
        default: RemoteProtocol.agentInspectionCapability
        }
    }

    public func agentQuery(agentID: AgentID, query: RemoteAgentQuery) async throws -> RemoteAgentResult {
        let capability = Self.capability(for: query)
        guard capabilities.contains(capability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to inspect remote agents.")
        }
        // The host's setup probes and a drafted commit message run a model or the network.
        let slow: Bool
        switch query {
        case .worktreeSetup, .worktreeCommitCount, .worktreeDescription, .commitMessage, .changesOverview, .changesList: slow = true
        default: slow = false
        }
        let reply = try await request(timeout: slow ? 150 : 30) { .agentQuery(id: $0, agentID: agentID, query: query) }
        if case .agentResult(_, let result) = reply { return result }
        if case .error(_, let code, let message) = reply {
            throw RemoteHostClientError.rejected(code: code, message: message)
        }
        throw RemoteHostClientError.outcomeUnknown(message: "Unexpected agent inspection reply. Check operation status before retrying.")
    }

    /// The dev servers the agent's folder on the host offers (`browserTunnelCapability`).
    public func devServers(agentID: AgentID) async throws -> [DevServer] {
        guard capabilities.contains(RemoteProtocol.browserTunnelCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: Self.tunnelsRefusal)
        }
        guard case .devServers(let servers) = try await agentQuery(agentID: agentID, query: .devServers) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected devServers reply")
        }
        return servers
    }

    /// Runs `command` in a new terminal pane of the agent's layout on the host, in `cwd`
    /// (`browserTunnelCapability`): the Browser's "Start on build-01".
    public func openTerminal(agentID: AgentID, cwd: String, command: String) async throws {
        guard capabilities.contains(RemoteProtocol.browserTunnelCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: Self.tunnelsRefusal)
        }
        try await agentAction(agentID: agentID, action: .openTerminal(cwd: cwd, command: command))
    }

    /// Why a host without `browserTunnelCapability` has no Browser for a remote viewer.
    public static let tunnelsRefusal = "Update Shepherd on the host to use its Browser from here."

    /// The host runs an agent's browser tools on this client's page when it claims them
    /// (`browserDriveCapability`, which goes with the tunnel the page loads through).
    public var drivesBrowser: Bool {
        let offered = capabilities
        return offered.contains(RemoteProtocol.browserDriveCapability) && offered.contains(RemoteProtocol.browserTunnelCapability)
    }

    /// Claims `agentID`'s browser: the host runs the agent's browser tools on this client's page
    /// from now on (most recent claim wins), until `browserRelease`, a newer claim elsewhere, or the
    /// connection ends. Answers the address the host's own page for the agent holds, `http` or
    /// `https`, for this client to open through its tunnel (nil when it has none). Throws
    /// `update_required` on a host that does not offer it, and the host's own refusal otherwise
    /// (`no_such_agent`, `too_many`, `superseded`).
    public func browserClaim(agentID: AgentID) async throws -> String? {
        guard drivesBrowser else {
            throw RemoteHostClientError.rejected(code: "update_required", message: Self.driveRefusal)
        }
        let reply = try await request(timeout: 30) { .browserClaim(id: $0, agentID: agentID) }
        switch reply {
        case .browserClaimed(_, let url): return url
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected claim reply")
        }
    }

    /// Gives `agentID`'s browser back to the host. Nothing answers it.
    public func browserRelease(agentID: AgentID) {
        guard capabilities.contains(RemoteProtocol.browserDriveCapability) else { return }
        queue.async { self.sendRequest(.browserRelease(agentID: agentID)) }
    }

    /// Answers a `BrowserDrivePush.request`. Nothing answers it.
    public func browserAnswer(token: Int, outcome: BrowserOutcome) {
        guard capabilities.contains(RemoteProtocol.browserDriveCapability) else { return }
        queue.async { self.sendRequest(.browserAnswer(requestToken: token, outcome: outcome)) }
    }

    /// Why a host without `browserDriveCapability` leaves its agent on its own page.
    public static let driveRefusal = "Update Shepherd on the host so its agent can use the page shown here."

    public func agentAction(agentID: AgentID, action: RemoteAgentAction) async throws {
        guard capabilities.contains(RemoteProtocol.agentActionsCapability), capabilities.contains(action.capability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to use remote agent actions."
            )
        }
        let reply = try await request { .agentAction(id: $0, agentID: agentID, action: action) }
        try expectOk(reply)
    }

    /// Manages one of the host's automations. A host without `automationsCapability` shows its
    /// automations read-only: this throws `update_required` before sending anything.
    @discardableResult
    public func automation(_ automationID: AutomationID, request: RemoteAutomationRequest) async throws -> RemoteAutomationResult {
        guard capabilities.contains(RemoteProtocol.automationsCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to manage its automations from here."
            )
        }
        // Run now spawns the run's agent on the host, which waits on its GUI, as creating one does.
        let timeout: TimeInterval = request == .run ? 120 : RemoteHostClient.requestTimeout
        let reply = try await self.request(timeout: timeout) { .automation(id: $0, automationID: automationID, request: request) }
        switch reply {
        case .automationResult(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected automation reply")
        }
    }

    /// The runs the host kept for an automation, oldest first.
    public func automationRuns(_ automationID: AutomationID) async throws -> [AutomationRun] {
        guard case .runs(let runs) = try await automation(automationID, request: .runs) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected automation reply")
        }
        return runs
    }

    /// Reads or saves the host's root instructions for pi, and answers with its files as they
    /// are afterwards. A host without `instructionsCapability` has none: this throws
    /// `update_required` before sending anything.
    @discardableResult
    public func instructions(_ request: RemoteInstructionsRequest = .fetch) async throws -> InstructionsSnapshot {
        guard capabilities.contains(RemoteProtocol.instructionsCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to edit its instructions from here."
            )
        }
        let reply = try await self.request { .instructions(id: $0, request: request) }
        switch reply {
        case .instructions(_, let snapshot): return snapshot
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected instructions reply")
        }
    }

    /// Reads or acts on the host's suggested instructions (Settings ▸ Experiments), and answers
    /// with its suggestions as they are afterwards. A host without `suggestionsCapability` has no
    /// experiments: this throws `update_required` before sending anything.
    @discardableResult
    public func suggestions(_ request: RemoteSuggestionsRequest = .fetch) async throws -> SuggestionsSnapshot {
        guard capabilities.contains(RemoteProtocol.suggestionsCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to use its experiments from here."
            )
        }
        let reply = try await self.request { .suggestions(id: $0, request: request) }
        switch reply {
        case .suggestions(_, let snapshot): return snapshot
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected suggestions reply")
        }
    }

    /// Reads or changes one of the host's settings (Settings on the iPhone and the iPad), and
    /// answers with its settings as they are afterwards. A host without `hostSettingsCapability`
    /// shares none: this throws `update_required` before sending anything.
    @discardableResult
    public func hostSettings(_ request: RemoteHostSettingsRequest = .fetch) async throws -> HostSettings {
        guard capabilities.contains(RemoteProtocol.hostSettingsCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to see its settings from here."
            )
        }
        if case .change(.goalsEnabled) = request, !capabilities.contains(RemoteProtocol.goalExperimentCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to toggle the Goals experiment.")
        }
        if case .change(.projectsEnabled) = request, !capabilities.contains(RemoteProtocol.projectsExperimentCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to toggle the Projects experiment.")
        }
        let reply = try await self.request { .hostSettings(id: $0, request: request) }
        switch reply {
        case .hostSettings(_, let settings): return settings
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected settings reply")
        }
    }

    /// Reads or changes the host's agent skills (Settings ▸ Skills), and answers with its skills
    /// as they are afterwards, or with a repository's skills for `lookUp`. Looking up, installing
    /// and checking for updates fetch from git on the host, so they wait longer. A host without
    /// `skillsCapability` has none: this throws `update_required` before sending anything.
    @discardableResult
    public func skills(_ request: RemoteSkillsRequest = .fetch) async throws -> RemoteSkillsResult {
        guard capabilities.contains(RemoteProtocol.skillsCapability) else {
            throw RemoteHostClientError.rejected(
                code: "update_required", message: "Update Shepherd on the host to manage its skills from here."
            )
        }
        let timeout: TimeInterval = switch request {
        case .lookUp, .install, .checkUpdates: 180
        default: RemoteHostClient.requestTimeout
        }
        let reply = try await self.request(timeout: timeout) { .skills(id: $0, request: request) }
        switch reply {
        case .skills(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected skills reply")
        }
    }

    public func projectRuntime(_ request: ProjectRuntimeTransport) async throws -> ProjectRuntimeResult {
        if case .worker = request, !capabilities.contains(RemoteProtocol.projectWorkerCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update the Project owner before opening its worker threads.")
        }
        if let native = request.nativeRequest {
            if let references = native.designReferences, !references.isEmpty {
                throw RemoteHostClientError.rejected(code: "design_references_local", message: Self.designReferencesRefusal)
            }
            if Self.overFrame(.logicalProjectRuntime(id: 0, request: request)) {
                throw RemoteHostClientError.rejected(code: "too_large", message: native.images.isEmpty
                    ? "The thread request is too large for the remote connection. Nothing was sent." : Self.imagesTooLarge)
            }
        }
        if case .action(_, _, .assign(_, _, _, _, let host)) = request, let host, host != .local,
           !capabilities.contains(RemoteProtocol.projectPlacementCapability) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update the Project owner before selecting a remote executor.")
        }
        guard capabilities.contains(RemoteProtocol.logicalProjectRuntimeCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the Project owner to coordinate work.")
        }
        if !request.messageImages.isEmpty {
            guard capabilities.contains(RemoteProtocol.projectMessageImagesCapability) else {
                throw RemoteHostClientError.rejected(code: "update_required", message: "Update the Project owner before sending images.")
            }
            if Self.overFrame(.logicalProjectRuntime(id: 0, request: request)) {
                throw RemoteHostClientError.rejected(code: "too_large", message: Self.imagesTooLarge)
            }
        }
        let reply: RemoteReply
        do { reply = try await self.request({ .logicalProjectRuntime(id: $0, request: request) }) }
        catch RemoteHostClientError.timeout {
            throw RemoteHostClientError.outcomeUnknown(message: "Project request timed out. Refresh before acting; do not automatically retry.")
        } catch RemoteHostClientError.disconnected {
            throw RemoteHostClientError.outcomeUnknown(message: "Connection lost. Refresh before acting; do not automatically retry.")
        }
        switch reply {
        case .logicalProjectRuntime(_, let result): return result
        case .error(_, "outcome_unknown", let message): throw RemoteHostClientError.outcomeUnknown(message: message)
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected Project runtime reply.")
        }
    }

    /// Logical projects on this owning host, shared by Mac and iOS clients. No dispatch implied.
    public func projectExecution(_ command: ProjectExecutionRequest) async throws -> ProjectExecutionResult {
        guard !command.requiresPublications || capabilities.contains(RemoteProtocol.projectPublicationsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update the executor before publishing Project artifacts.")
        }
        guard !command.requiresPlacement || capabilities.contains(RemoteProtocol.projectPlacementCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update the executor before using Project question controls.")
        }
        guard capabilities.contains(RemoteProtocol.projectExecutionCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "This host does not offer Project execution.")
        }
        guard !Self.overFrame(.projectExecution(id: 0, request: command)) else {
            throw RemoteHostClientError.rejected(code: "invalid_execution", message: "Execution request exceeds the frame limit.")
        }
        let reply = try await request { .projectExecution(id: $0, request: command) }
        switch reply {
        case .projectExecution(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.disconnected
        }
    }

    public func logicalProjects(_ request: LogicalProjectsRequest) async throws -> LogicalProjectsResult {
        switch request {
        case .linkSpace(_, _, _, let host), .unlinkSpace(_, _, _, let host):
            if let host, host != .local, !capabilities.contains(RemoteProtocol.projectPlacementCapability) {
                throw RemoteHostClientError.rejected(code: "update_required", message: "Update the Project owner before linking remote Spaces.")
            }
        default: break
        }
        guard capabilities.contains(RemoteProtocol.logicalProjectsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to manage logical projects.")
        }
        guard !request.requiresProjectAutomations || capabilities.contains(RemoteProtocol.logicalProjectAutomationsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to manage Project automations.")
        }
        guard !request.requiresProjectFiles || capabilities.contains(RemoteProtocol.logicalProjectFilesCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to preview Project artifacts.")
        }
        let reply = try await self.request { .logicalProjects(id: $0, request: request) }
        switch reply {
        case .logicalProjects(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected logical projects reply.")
        }
    }

    /// Project-only configuration. Capability check happens before anything is sent to an old host.
    public func projects(_ request: RemoteProjectsRequest) async throws -> RemoteProjectsResult {
        guard !request.requiresProjectTrust || capabilities.contains(RemoteProtocol.projectTrustCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to approve space configuration.")
        }
        guard !request.requiresMCP || capabilities.contains(RemoteProtocol.projectMCPCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to sign in to space MCP servers.")
        }
        guard capabilities.contains(RemoteProtocol.projectsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to edit its spaces from here.")
        }
        guard !request.requiresDetails || capabilities.contains(RemoteProtocol.projectDetailsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to read space context and open its editor.")
        }
        let reply = try await self.request { .projects(id: $0, request: request) }
        switch reply {
        case .projects(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "Unexpected space settings reply.")
        }
    }

    /// Reads or changes the host's designs (`designsCapability`, served while the host's Design
    /// tool is on). A host without it throws `update_required` before anything is sent: an older
    /// Shepherd, or the experiment off there.
    public func design(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        guard capabilities.contains(RemoteProtocol.designsCapability) else {
            throw RemoteHostClientError.rejected(code: "update_required", message: Self.designsRefusal)
        }
        if let needed = request.capability, !capabilities.contains(needed) {
            throw RemoteHostClientError.rejected(code: "update_required", message: "Update Shepherd on the host to send it Pencil markup.")
        }
        if Self.overFrame(.design(id: 0, request: request)) {
            throw RemoteHostClientError.rejected(code: "too_large", message: "The change exceeds the remote payload limit.")
        }
        // A listing reads every design's files on the host; a comment waits for the agent's queue.
        let reply = try await self.request(timeout: 30) { .design(id: $0, request: request) }
        switch reply {
        case .design(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
        }
    }

    /// Why a host without `designsCapability` shows no designs.
    public static let designsRefusal = "Turn on Settings ▸ Experiments ▸ Design tool on the host, or update Shepherd there, to see its designs."

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
            throw RemoteHostClientError.rejected(code: "unsupported", message: "host needs a newer Shepherd build for remote terminals")
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
            throw RemoteHostClientError.rejected(code: "unsupported", message: "host needs a newer Shepherd build for remote terminals")
        }
        let reply = try await request { id in .closePane(id: id, agentID: agentID, paneID: paneID) }
        try expectOk(reply)
    }

    public func resizePaneSplit(agentID: AgentID, split: PaneNode, ratio: Double) async throws {
        guard capabilities.contains(RemoteProtocol.paneControlCapability) else {
            throw RemoteHostClientError.rejected(code: "unsupported", message: "host needs a newer Shepherd build for remote terminals")
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

    /// Issue an id-correlated request and await its reply.
    private func request(
        timeout: TimeInterval = RemoteHostClient.requestTimeout,
        connectionGeneration: UUID? = nil,
        _ make: @escaping (Int) -> RemoteRequest
    ) async throws -> RemoteReply {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.fd >= 0, connectionGeneration == nil || self.connectionGeneration == connectionGeneration else {
                    continuation.resume(throwing: RemoteHostClientError.rejected(code: "not_sent", message: "Connection closed before the request was sent"))
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
        guard pendingWriteBytes + payload.count <= Self.maxQueuedWriteBytes else {
            teardown(reason: "write queue overflow")
            return
        }
        pendingWrites.append(payload)
        pendingWriteBytes += payload.count
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
                pendingWriteBytes -= result
                if pendingWriteOffset == payload.count {
                    pendingWrites.removeFirst()
                    pendingWriteOffset = 0
                }
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armWriter()
                // Tunnel sockets held for this queue are read again once it is low.
                if pendingWriteBytes <= BrowserTunnelLimits.resumeBacklogBytes { tunnels.backlogDidDrain() }
                return
            }
            teardown(reason: "write failed: errno \(errno)")
            return
        }
        writeSource?.cancel()
        writeSource = nil
        tunnels.backlogDidDrain()
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

    /// A host's workspace as this client shows it. Designs and the agents that draw them stay
    /// only while the host serves designs (`designs.v1`), where a design's screen shows them.
    /// Elsewhere a design's agent would show as a thread, so a host that sends designs without
    /// serving them (one from before the rule) loses them here (docs/designs.md › Design agents
    /// and ordinary threads).
    static func shown(_ state: ShepherdState, capabilities: Set<String>) -> ShepherdState {
        capabilities.contains(RemoteProtocol.designsCapability) ? state : state.withoutDesigns
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
        case .nativeThread(let id, _), .uploadResult(let id, _), .creationOptions(let id, _), .agentResult(let id, _), .helloOk(let id, _, _), .ok(let id), .paneOpened(let id, _),
             .state(let id, _), .attached(let id, _),
             .dirListing(let id, _, _, _), .models(let id, _, _, _, _, _, _),
             .spaceAdded(let id, _), .agentCreated(let id, _), .automationResult(let id, _), .instructions(let id, _),
             .suggestions(let id, _), .hostSettings(let id, _), .skills(let id, _), .projects(let id, _), .logicalProjects(let id, _), .logicalProjectRuntime(let id, _), .projectExecution(let id, _), .design(let id, _),
             .browserClaimed(let id, _):
            resumePending(id: id, with: reply)
        case .error(let id, _, _):
            resumePending(id: id, with: reply)
        case .stateChanged(let state):
            push(.state(Self.shown(state, capabilities: capabilities)))
        case .output(let sessionID, let data):
            if case .output(let last, var merged)? = pendingEvents.last, last == sessionID {
                merged.append(data)
                pendingEvents[pendingEvents.count - 1] = .output(sessionID, merged)
            } else {
                push(.output(sessionID, data))
            }
        case .sessionExited(let sessionID, let code):
            push(.exited(sessionID, code))
        case .projectExecutionChanged(let key, let revision):
            push(.projectExecutionChanged(key, revision))
        case .designChanged(let designID, let revision, let commentsRevision):
            push(.designChanged(designID, revision, commentsRevision))
        case .tunnel(let frame):
            tunnels.receive(frame)
        case .browserDrive(let push):
            self.push(.browserDrive(push))
        case .capabilitiesChanged(let list):
            capabilities = Set(list)
            push(.capabilities(Set(list)))
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
                case .projectExecutionChanged(let key, let revision): self.onProjectExecutionChanged?(key, revision)
                case .designChanged(let designID, let revision, let comments): self.onDesignChanged?(designID, revision, comments)
                case .capabilities(let capabilities): self.onCapabilitiesChanged?(capabilities)
                case .browserDrive(let push): self.onBrowserDrive?(push)
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
        connectionGeneration = UUID()
        pendingOpen?.cancel()
        pendingOpen = nil
        guard fd >= 0 else { return }
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        // Cancel handlers own the close; without a read source, close here.
        fd = -1
        pendingWrites.removeAll()
        pendingWriteOffset = 0
        pendingWriteBytes = 0
        // Every tunnel of the connection ends with it: the pages see a reset, and the next
        // connection to a forwarded port opens a new tunnel on the next connection.
        tunnels.connectionLost()
        // Undelivered pushes die with the connection; the owner drops its
        // view state on disconnect and re-snapshots on reconnect.
        pendingEvents.removeAll()
        for continuation in pendingReplies.values {
            continuation.resume(throwing: RemoteHostClientError.disconnected)
        }
        pendingReplies.removeAll()
        if established, !disconnectNotified {
            disconnectNotified = true
            hopToMain { [weak self] in self?.onDisconnected?(reason) }
        }
        established = false
    }

    private func hopToMain(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}

// MARK: - Browser tunnels

extension RemoteHostClient: BrowserTunnelLink {
    public func sendTunnel(_ frame: BrowserTunnelFrame) {
        sendRequest(.tunnel(frame))
    }

    public var tunnelBacklogBytes: Int { pendingWriteBytes }

    public var tunnelsAvailable: Bool { fd >= 0 && capabilities.contains(RemoteProtocol.browserTunnelCapability) }
}
