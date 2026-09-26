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
    /// A terminal-only operation (attach, screen, resize) on an RPC session.
    case noTerminal(SessionID)
    case noSuchSpace(SpaceID)
    case noSuchTab(TabID)
    case noSuchPane(PaneID)
    case tabInUse(TabID)
    case noSuchAgent(AgentID)
    case noSuchAutomation(AutomationID)
    case noSuchDesign(DesignID)
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
        case .noTerminal(let id):
            return "session \(id) is an RPC session and has no terminal"
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
        case .noSuchDesign(let id):
            return "unknown design \(id)"
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

    /// Design extension requests in flight, by token: their connection waits here (server queue)
    /// while the design store reads or writes.
    private var designRequestClients: [Int: ExtensionConnection] = [:]
    private var nextDesignRequest = 0

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
        /// Set by helloChildren: the children extension's control channel for that agent.
        var childrenAgentID: AgentID?
        /// What a remote client said it understands in its `hello`.
        var clientCapabilities: Set<String> = []
        /// A client from before minimal, xhigh and max: it decodes only `ThinkingLevel.legacy`.
        var knowsLegacyThinkingOnly: Bool { !clientCapabilities.contains(RemoteProtocol.thinkingLevelsCapability) }
        var lineBuffer = LineBuffer()
        var readSource: DispatchSourceRead?
        var writeSource: DispatchSourceWrite?
        var pendingReplies: [Data] = []
        var pendingReplyOffset = 0
        var queuedReplyBytes = 0
        var upload: RemoteFileUpload?

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
        /// The output that is news to a viewer who looked away: not a redraw after a resize.
        var news = TerminalNews()
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
    /// The pi status extension reported a status. A `done` that ends a turn pi failed carries
    /// the failure; every other report carries nil. Delivered on the main actor.
    public var onAgentStatus: ((AgentID, AgentStatus, TurnFailure?) -> Void)?
    /// The subagents extension published an agent's live child-run projection
    /// (full replace). Display-only — never persisted, never validated against
    /// state; the GUI owns row lifecycle. Delivered on the main actor.
    public var onAgentChildren: ((AgentID, [ChildRun]) -> Void)?
    /// The notify extension's tool asked for a system notification.
    /// Fire-and-forget, delivered on the main actor.
    public var onNotify: ((AgentID, String, String) -> Void)?
    /// An agent's pi began serving its native thread: a snapshot request now gets its history
    /// instead of `native_starting`. Once per pi, when it serves and its agent's pane is bound
    /// to it (whichever comes last), after the state broadcast of that binding. Delivered on
    /// the main actor, so a local thread need not wait for its next poll.
    public var onNativeThreadServable: ((AgentID) -> Void)?
    /// A watched agent's native thread (`watchThreadRevisions`) moved to a new revision, or its
    /// pane was bound to a pi. Delivered on the main actor, at most once per display frame
    /// (`revisionPushSpacing`): every agent revised while one delivery waits rides it, so a
    /// streaming turn costs a main hop per frame, and an agent no one watches costs none. A hint
    /// to pull, not state: it may land after callbacks the server queued later.
    public var onThreadRevision: ((AgentID) -> Void)?
    /// A watched design's files (`watchDesignRevisions`) moved to a new revision. Paced like
    /// `onThreadRevision`: on the main actor, at most once per display frame, every design revised
    /// while one delivery waits riding it. A hint to pull the design's snapshot, not state.
    public var onDesignRevision: ((DesignID) -> Void)?
    /// An agent's pi finished a tool call (its name). The app reads the agent's checkout again
    /// after calls that may have changed files. Delivered on the main actor.
    public var onAgentToolFinished: ((AgentID, String) -> Void)?
    /// The shortest time between two `onThreadRevision` deliveries: one display frame.
    public static let revisionPushSpacing: DispatchTimeInterval = .microseconds(16_667)
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
    /// An agent asked to open a native diff-review pane. The GUI owns the
    /// review layout and user interaction; the completion carries the result.
    public var onReviewRequest: ((ReviewRequest, @escaping (ReviewOutcome) -> Void) -> Void)?
    public var onRemotePaneRequest: ((PaneRequest, @escaping (PaneOutcome) -> Void) -> Void)?
    /// A remote client asked to create an agent. Spawning pi (extension
    /// flags, session-file seeding, pane binding) is the GUI's flow, so the
    /// request is handed to it like a pane request. Delivered on the main
    /// actor; the completion may be called from any thread. `nil` handler
    /// (headless server, tests) rejects the request.
    public var onRemoteCreateAgent: ((RemoteCreateAgentRequest, @escaping (Result<AgentID, RemoteCreateAgentError>) -> Void) -> Void)?

    public var onRemoteCreationOptions: ((SpaceID, String?, Bool?, @escaping (Result<RemoteCreationOptions, RemoteCreateAgentError>) -> Void) -> Void)?
    public var onRemoteAgentQuery: ((AgentID, RemoteAgentQuery, @escaping (Result<RemoteAgentResult, RemoteCreateAgentError>) -> Void) -> Void)?
    public var onRemoteAgentAction: ((AgentID, RemoteAgentAction, @escaping (Result<Void, RemoteCreateAgentError>) -> Void) -> Void)?
    /// A remote client reads or changes this host's settings (`RemoteRequest.hostSettings`): the
    /// GUI owns them, so a server without it (headless, tests) rejects the request. Called on the
    /// main actor.
    public var onRemoteHostSettings: ((RemoteHostSettingsRequest, @escaping (Result<HostSettings, RemoteCreateAgentError>) -> Void) -> Void)?
    /// A remote client saved or restored this host's root instructions: the GUI's Settings page
    /// follows. Delivered on the main actor.
    public var onInstructionsChanged: ((InstructionsSnapshot) -> Void)?

    /// Shepherd's root instructions for pi on this host (the support directory's
    /// `instructions/`): remote clients read and save them through the server, and the Mac's
    /// Settings page through this store directly.
    public let instructions: InstructionsStore
    /// Settings ▸ Experiments ▸ Suggested instructions on this host (`instructions/suggestions.json`):
    /// agents suggest through the extension socket, remote clients act through the server, and
    /// the Mac's Settings page through this store directly.
    public let suggestions: SuggestionsStore
    /// An agent suggested a line, or a remote client acted on the suggestions: the GUI's
    /// Experiments page follows. Delivered on the main actor.
    public var onSuggestionsChanged: ((SuggestionsSnapshot) -> Void)?
    /// The agent skills on this host (Settings ▸ Skills): ~/.agents/skills, which pi reads, and
    /// what Shepherd keeps beside it in the support directory's `skills/`. Remote clients change
    /// them through the server, the Mac's Settings page through this store directly.
    public let skills: SkillsStore
    /// A remote client changed this host's skills: the GUI's Skills page follows. Delivered on
    /// the main actor.
    public var onSkillsChanged: ((SkillsSnapshot) -> Void)?
    /// The files of every design (the Design tool), in the support directory's `designs/`. Reads
    /// go to it directly; writes go through the server's design mutations, which commit and
    /// broadcast what they changed.
    public let designs: DesignStore
    /// Skills requests fetch from git, so they run here, one at a time, never on the server's
    /// queue.
    private let skillsQueue = DispatchQueue(label: "shepherd.skills", qos: .userInitiated)

    private let queue = DispatchQueue(label: "shepherd.sessions")
    private let socketPath: String
    private let store: StateStore
    private let modelCatalog: ModelCatalog
    /// Where each delivered message came from, per pi session (support directory).
    private let originStore: ThreadOriginStore
    /// How each automation's runs went (support directory), for remote clients.
    private let runLog: AutomationRunLog
    /// The Changes pane's engine: scopes, diffs, the base picker, and each agent's turns with
    /// their Undo (docs/changes.md). The app calls it directly; remote clients through
    /// `RemoteAgentQuery.changes*`.
    public let changes: ChangesService
    /// How queues go for agents with no choice of their own (Settings ▸ Agents).
    private var defaultQueueMode: NativeQueueMode = .all
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
    private struct PendingAgentRequest {
        let caller: ExtensionConnection
        let target: ExtensionConnection?
        let targetAgentID: AgentID
        let id: Int
        let timer: DispatchWorkItem
        var deletionConfirmed = false
    }
    private var agentRequests: [String: PendingAgentRequest] = [:]
    public var onAgentPeerCancellation: ((String) -> Void)?

    private var nextChildCommandID = 0
    /// RPC sessions retired this run, with their exit codes (nil: a signal). A pane still bound
    /// to one ran a pi that is gone, unlike a binding left from the previous run, which the app
    /// is respawning.
    private var retiredRPCSessions: [SessionID: Int32?] = [:]
    /// RPC sessions whose thread serves but that no agent's pane is bound to yet
    /// (`onNativeThreadServable` waits for the binding).
    private var unannouncedServable: Set<SessionID> = []
    private enum NativeOutcome {
        case result(NativeThreadResult)
        case failure(code: String, message: String)
    }

    /// childCommand frames awaiting their childCommandResult, by correlation id.
    private var childCommandPending: [Int: (client: ExtensionConnection, completion: (String?) -> Void)] = [:]

    /// One child process per session, on a PTY (terminal panes) or on
    /// pipes (`pi --mode rpc`). Terminal-only paths take `pty` and treat nil as
    /// "no terminal"; liveness, exit, and kill are shared.
    private enum ServerSession {
        case pty(PTYSession)
        case rpc(RPCSession, RPCThreadState)

        var pty: PTYSession? {
            if case .pty(let session) = self { return session }
            return nil
        }

        var thread: RPCThreadState? {
            if case .rpc(_, let state) = self { return state }
            return nil
        }

        var isAlive: Bool {
            switch self {
            case .pty(let s): return s.isAlive
            case .rpc(let s, _): return s.isAlive
            }
        }

        /// nil while alive or after a signal.
        var exitCode: Int32? {
            switch self {
            case .pty(let s): return s.exitCode
            case .rpc(let s, _): return s.exitCode
            }
        }

        var info: SessionInfo {
            switch self {
            case .pty(let s): return s.info
            case .rpc(let s, _): return s.info
            }
        }

        func signalProcessGroup(_ sig: Int32) {
            switch self {
            case .pty(let s): s.signalProcessGroup(sig)
            case .rpc(let s, _): s.signalProcessGroup(sig)
            }
        }

        func shutdown() {
            switch self {
            case .pty(let s): s.shutdown()
            case .rpc(let s, _): s.shutdown()
            }
        }
    }

    /// Watched keys (agents' threads, designs) that revised since the last main-queue delivery:
    /// filled on the server queue, drained on the main queue, which also sets what is watched.
    final class RevisionPacer<Key: Hashable>: @unchecked Sendable {
        private let lock = NSLock()
        private var order: [Key] = []
        private var members: Set<Key> = []
        private var watched: Set<Key> = []
        private var lastDelivery: DispatchTime?

        func watch(_ keys: Set<Key>) {
            lock.lock()
            defer { lock.unlock() }
            watched = keys
        }

        /// When to deliver, for the first watched key since the last drain: a frame after the
        /// last delivery, or now. Nil when the key is not watched or a delivery is scheduled.
        func insert(_ key: Key) -> DispatchTime? {
            lock.lock()
            defer { lock.unlock() }
            guard watched.contains(key), members.insert(key).inserted else { return nil }
            order.append(key)
            guard order.count == 1 else { return nil }
            let now = DispatchTime.now()
            guard let lastDelivery else { return now }
            return max(now, lastDelivery + SessionServer.revisionPushSpacing)
        }

        /// The keys to tell the app about now, those still watched.
        func drain() -> [Key] {
            lock.lock()
            defer { lock.unlock() }
            lastDelivery = .now()
            let drained = order.filter(watched.contains)
            order.removeAll()
            members.removeAll()
            return drained
        }
    }

    private let revisedThreads = RevisionPacer<AgentID>()
    private let revisedDesigns = RevisionPacer<DesignID>()
    /// Tests only: handed to every RPC session this server creates afterwards, to run on the
    /// decode queue before each record it decodes off the server queue.
    var beforeOffQueueDecode: (() -> Void)?
    /// Tests only: what this host tells a remote client it can do, to stand in for an older host.
    /// Set before a client connects.
    var advertisedCapabilities = RemoteProtocol.capabilities
    /// Which agent's own pane runs each session, for the store version it was built from.
    private var sessionAgents: (version: UInt64, agents: [SessionID: AgentID])?

    private var sessions: [SessionID: ServerSession] = [:]
    private var attachedSessions: Set<SessionID> = []
    /// Output waiting for the GUI, plus the one delivery currently executing
    /// on the main queue, tracked independently for each session.
    private var outputStates: [SessionID: SessionOutputState] = [:]

    /// The models a remote client's `listModels` gets, and the default among them. It blocks
    /// (asking pi shells out), so the server calls it off its queue.
    public typealias ModelCatalog = @Sendable () -> ModelListing

    /// pi's own catalog (`pi --list-models`, else models.json) and settings.json's default, all
    /// as "provider/id".
    public static let piModelCatalog: ModelCatalog = {
        ModelListing(entries: PiModelCatalog.entriesOrConfigured(), defaultModel: PiConfig.defaultModel(),
                     levelMaps: PiConfig.thinkingLevelMaps())
    }

    /// This Mac's models as a remote client's `listModels` gets them, for the local New Agent
    /// sheet. Blocking (asking pi shells out): call it off the main thread and the server queue.
    public func modelListing() -> ModelListing { modelCatalog() }

    /// `modelCatalog` answers remote model listings; tests pass a stand-in so nothing runs pi.
    /// `skillsDirectory` is where this host's skills live, ~/.agents/skills unless a test passes
    /// its own. `trash` is where an Undo moves the files a turn created; tests pass their own.
    public init(socketPath: String, stateURL: URL, modelCatalog: @escaping ModelCatalog = SessionServer.piModelCatalog,
                skillsDirectory: URL? = nil, trash: @escaping ChangesService.Trash = ChangesService.systemTrash) {
        self.socketPath = socketPath
        self.store = StateStore(url: stateURL)
        self.modelCatalog = modelCatalog
        self.originStore = ThreadOriginStore(directory: stateURL.deletingLastPathComponent().appendingPathComponent("thread-origins", isDirectory: true))
        self.runLog = AutomationRunLog(url: stateURL.deletingLastPathComponent().appendingPathComponent("automation-runs.json"))
        let instructions = InstructionsStore(directory: stateURL.deletingLastPathComponent().appendingPathComponent("instructions", isDirectory: true))
        self.instructions = instructions
        self.suggestions = SuggestionsStore(url: instructions.directory.appendingPathComponent("suggestions.json"), instructions: instructions)
        self.skills = SkillsStore(directory: skillsDirectory ?? ShepherdPaths.agentSkillsDirectory(),
                                  stateDirectory: stateURL.deletingLastPathComponent().appendingPathComponent("skills", isDirectory: true))
        self.changes = ChangesService(directory: stateURL.deletingLastPathComponent().appendingPathComponent("changes", isDirectory: true),
                                      trash: trash)
        self.designs = DesignStore(directory: stateURL.deletingLastPathComponent().appendingPathComponent("designs", isDirectory: true))
        installChanges()
    }

    /// The queue mode of every agent that has not chosen its own (`NativeQueueAction.setMode`).
    public func setDefaultQueueMode(_ mode: NativeQueueMode) {
        queue.async {
            self.defaultQueueMode = mode
            for session in self.sessions.values { session.thread?.defaultQueueMode = mode }
        }
    }

    /// The last committed state, from any thread and without waiting for the server queue: a
    /// mutation still running (or queued) is not in it, and one that has returned always is.
    public var state: ShepherdState {
        store.committed
    }

    /// Bind the extension socket and clear stale persisted state from the
    /// previous run (sessions died with the app; agent statuses no longer
    /// mean anything until pi reports fresh ones).
    public func start() throws {
        // Which designs lost their folders is read on the store's queue, not the server's.
        let missingDesigns = designs.missingDesigns(among: store.committed.designs.map(\.id))
        try queue.sync { try startOnQueue(missingDesigns: missingDesigns) }
        countDesignBoards()
    }

    /// Kill every session and close the extension socket. Called when the app
    /// terminates: sessions must not outlive the app.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    // MARK: - Lifecycle (server queue)

    /// Tabs from before shells were removed: global shells (no space) and space shell
    /// workspaces (a space's layout no agent owns). Utility terminals are purged separately.
    static func shellTabIDs(in state: ShepherdState) -> Set<TabID> {
        let agentTabs = Set(state.agents.map(\.tabID))
        return Set(state.tabs.filter { $0.inspectorFor == nil && ($0.spaceID == nil || !agentTabs.contains($0.id)) }.map(\.id))
    }

    /// Automation run agents from the previous app run: every agent in the reserved hidden
    /// space (runs only ever live there) plus any agent an automation still points at. Runs are
    /// ephemeral; enabled automations start fresh ones after adoption. Keeping the old agents
    /// relaunched their pi on every start and piled up one per launch.
    static func automationRunAgentIDs(in state: ShepherdState) -> Set<AgentID> {
        let hiddenSpaces = Set(state.spaces.filter(\.hidden).map(\.id))
        return Set(state.agents.filter { hiddenSpaces.contains($0.spaceID) }.map(\.id))
            .union(state.automations.compactMap(\.agentID))
    }

    /// Whether startup must forget designs whose folders are gone, or clear references between
    /// designs and agents that no longer exist (`removedAgents`: those startup drops anyway).
    static func designsNeedReconciling(in state: ShepherdState, missing: Set<DesignID>, removedAgents: Set<AgentID>) -> Bool {
        let designs = Set(state.designs.map(\.id)).subtracting(missing)
        let agents = Set(state.agents.map(\.id)).subtracting(removedAgents)
        return !missing.isEmpty
            || state.agents.contains { $0.designID.map { !designs.contains($0) } == true }
            || state.designs.contains { $0.agentID.map { !agents.contains($0) } == true }
    }

    /// Forgets designs whose folders are gone, and clears an agent's design or a design's agent
    /// that no longer exists: opening such a design starts a fresh agent.
    static func reconcileDesigns(_ state: inout ShepherdState, missing: Set<DesignID>) {
        state.designs.removeAll { missing.contains($0.id) }
        let designs = Set(state.designs.map(\.id))
        for i in state.agents.indices where state.agents[i].designID.map({ !designs.contains($0) }) == true {
            state.agents[i].designID = nil
        }
        let agents = Set(state.agents.map(\.id))
        for i in state.designs.indices where state.designs[i].agentID.map({ !agents.contains($0) }) == true {
            state.designs[i].agentID = nil
        }
    }

    private func startOnQueue(missingDesigns: Set<DesignID> = []) throws {
        let stale = store.state.agents.filter { $0.status != .idle }.map(\.id)
        let deadInspectors = store.state.tabs.contains { $0.inspectorFor != nil }
        let deadReviews = store.state.tabs.contains { tab in
            tab.layout.leaves.contains { $0.isReview == true }
        }
        let staleRuns = store.state.automations.contains { $0.agentID != nil }
        let shellTabs = Self.shellTabIDs(in: store.state)
        let runAgents = Self.automationRunAgentIDs(in: store.state)
        let staleDesigns = Self.designsNeedReconciling(in: store.state, missing: missingDesigns, removedAgents: runAgents)
        if !stale.isEmpty || deadInspectors || deadReviews || staleRuns || !shellTabs.isEmpty || !runAgents.isEmpty
            || staleDesigns {
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
                    // Global shells and space shell workspaces were removed from Shepherd;
                    // their layouts (and the sessions they would respawn) go.
                    state.tabs.removeAll { shellTabs.contains($0.id) }
                    // Review panes are session-scoped UI: their native viewer
                    // died with the previous run, so remove them from each
                    // layout. A lone review leaf keeps the tab usable.
                    for i in state.tabs.indices {
                        var layout = state.tabs[i].layout
                        let reviewIDs = layout.leaves.filter { $0.isReview == true }.map(\.id)
                        for paneID in reviewIDs {
                            if let closed = layout.closing(pane: paneID) {
                                layout = closed
                            } else {
                                layout = layout.updatingLeaf(paneID) { $0.isReview = nil }
                            }
                        }
                        state.tabs[i].layout = layout
                    }
                    // Automation runs died with the previous app run; enabled
                    // ones restart through the GUI after adoption. Their agents and layouts go.
                    let runTabs = Set(state.agents.filter { runAgents.contains($0.id) }.map(\.tabID))
                    state.agents.removeAll { runAgents.contains($0.id) }
                    state.tabs.removeAll { runTabs.contains($0.id) || $0.inspectorFor.map(runAgents.contains) == true }
                    for i in state.automations.indices {
                        state.automations[i].agentID = nil
                    }
                    Self.reconcileDesigns(&state, missing: missingDesigns)
                }
            } catch {
                throw SessionServerError.persistFailed(String(describing: error))
            }
        }
        // Runs still open died with the previous launch, their agents with them.
        runLog.closeOpenRuns()
        changes.pruneTurns(keeping: Set(store.state.agents.map(\.id)))

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
        // At launch every pi's extensions dial in while the queue may be busy decoding
        // histories; a short backlog refused them. The kernel caps SOMAXCONN.
        guard listen(fd, SOMAXCONN) == 0 else {
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
        unannouncedServable.removeAll()
        attachedSessions.removeAll()
        outputStates.removeAll()
        for client in Array(clients.values) {
            disconnect(client)
        }
        for token in Array(agentRequests.keys) {
            finishAgentRequest(token, result: .init(text: "server stopped", code: "disconnected"))
        }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            unlink(socketPath)
            listenFD = -1
        }
        stopRemoteListenerOnQueue()
        // Where delivered messages came from is written off the queue; a relaunch reads it.
        originStore.flush()
        runLog.flush()
    }

    // MARK: - Native thread

    /// Answered from the agent's `RPCThreadState`, without TCP or authentication.
    /// Transport failures match RemoteHostClient.nativeThread: rejected or outcomeUnknown.
    /// Pi-level failures remain NativeThreadResult.failure. Cancellation does not undo
    /// dispatch; as with TCP, callers must ignore stale responses and never auto-retry.
    public func nativeThread(agentID: AgentID, request: NativeThreadRequest) async throws -> NativeThreadResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // Include the same envelope budget as TCP, excluding NDJSON's newline. A snapshot
                // request carries no user payload, and streaming clients poll it often.
                let bytes: Int
                if case .snapshot = request {
                    bytes = 0
                } else {
                    bytes = (try? NDJSON.encode(RemoteRequest.nativeThread(id: 0, agentID: agentID, request: request)).count - 1) ?? Int.max
                }
                self.dispatchNativeThread(agentID: agentID, request: request, requestBytes: bytes) { outcome in
                    self.hopToMain {
                        switch outcome {
                        case .result(let result): continuation.resume(returning: result)
                        case .failure("outcome_unknown", let message):
                            continuation.resume(throwing: RemoteHostClientError.outcomeUnknown(message: message))
                        case .failure(let code, let message):
                            continuation.resume(throwing: RemoteHostClientError.rejected(code: code, message: message))
                        }
                    }
                }
            }
        }
    }

    /// Queue-owned dispatch shared by local and authenticated TCP callers. The thread state
    /// checks pi's current session/generation; persisted agent session IDs may lag /resume.
    ///
    /// An agent whose pane has no pi yet is starting, not gone: the app binds a freshly spawned
    /// pi only after the agent is in state (and respawns a restored agent's pi when its pane
    /// mounts), and clients poll from the moment the agent appears.
    ///
    /// `olderClient`: a remote client whose `hello` did not say it reads the host's queue.
    private func dispatchNativeThread(
        agentID: AgentID,
        request: NativeThreadRequest,
        requestBytes: Int,
        olderClient: Bool = false,
        completion: @escaping (NativeOutcome) -> Void
    ) {
        let unavailable = { (message: String) in completion(.failure(code: NativeThreadCode.unavailable, message: message)) }
        guard let agent = store.state.agents.first(where: { $0.id == agentID }) else {
            unavailable("The agent no longer exists.")
            return
        }
        guard let tab = store.state.tabs.first(where: { $0.id == agent.tabID }),
              let paneID = agent.paneID, let leaf = tab.layout.leaf(withID: paneID) else {
            unavailable("The agent has no thread pane.")
            return
        }
        guard let sessionID = leaf.sessionID, let session = sessions[sessionID] else {
            if let sessionID = leaf.sessionID, let code = retiredRPCSessions[sessionID] {
                unavailable(Self.exitMessage(code))
            } else {
                completion(.failure(code: NativeThreadCode.starting, message: "The agent is starting."))
            }
            return
        }
        guard let thread = session.thread else {
            unavailable("The agent is not running in its pane.")
            return
        }
        if !thread.turnChangesSet { thread.setTurnChanges(changes.turns(agentID: agentID)) }
        guard session.isAlive else {
            unavailable(Self.exitMessage(session.exitCode))
            return
        }
        // Image sends (v2) carry base64 payloads; text requests keep the tight bound.
        let requestLimit = request.images.isEmpty ? 64 * 1024 : 12 * 1024 * 1024
        guard requestBytes < requestLimit else {
            completion(.failure(code: "native_limit", message: "Native request limit exceeded."))
            return
        }
        if case .send = request { noteAgentSend(agentID) }
        thread.handle(request, olderClient: olderClient) { completion(.result($0)) }
    }

    private static func exitMessage(_ code: Int32?) -> String {
        "The agent exited (\(code.map { "code \($0)" } ?? "signal"))."
    }

    /// Server queue. Writes a childCommand to the agent's children-extension connection and
    /// answers with the extension's error text (nil on success). A resume can take a few
    /// seconds while pi boots, hence the 15s ceiling.
    private func sendChildCommand(
        agentID: AgentID, runID: String, action: NativeSubagentAction, text: String?, mode: NativeThreadDelivery?,
        completion: @escaping (String?) -> Void
    ) {
        guard let client = clients.values.first(where: { $0.childrenAgentID == agentID }) else {
            completion("Native subagents are unavailable for this agent (children extension not connected).")
            return
        }
        nextChildCommandID += 1
        let correlation = nextChildCommandID
        childCommandPending[correlation] = (client, completion)
        let childAction: ChildCommandAction = switch action {
        case .message: .message
        case .cancel: .cancel
        case .resume: .resume
        case .pause: .pause
        case .continue: .continue
        }
        reply(.childCommand(id: correlation, runID: runID, action: childAction, text: text, mode: mode), to: client)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.childCommandPending.removeValue(forKey: correlation)?.completion("Subagent command timed out. Refresh before acting; do not automatically retry.")
        }
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
        guard listen(fd, SOMAXCONN) == 0 else {
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
            guard case .hello(let id, let token, let clientName, let protocolVersion, let capabilities) = request else {
                ShepherdLog.warning("remote request before hello on fd \(client.fd)")
                sendFinal(.error(id: 0, code: "unauthenticated", message: "hello required"), to: client)
                return
            }
            guard protocolVersion == RemoteProtocol.version else {
                sendFinal(.error(
                    id: id,
                    code: RemoteProtocol.versionMismatchCode,
                    message: "host speaks protocol \(RemoteProtocol.version)"
                ), to: client)
                return
            }
            guard let expected = remoteToken, RemoteToken.matches(token, expected: expected) else {
                ShepherdLog.warning("remote client '\(clientName)' rejected: bad token (fd \(client.fd))")
                sendFinal(.error(id: id, code: RemoteProtocol.unauthorizedCode, message: "bad token"), to: client)
                return
            }
            client.authenticated = true
            client.clientCapabilities = Set(capabilities ?? [])
            send(.helloOk(
                id: id,
                protocolVersion: RemoteProtocol.version,
                capabilities: advertisedCapabilities
            ), to: client)
            ShepherdLog.info("remote client '\(clientName)' authenticated (fd \(client.fd))")
            return
        }

        switch request {
        case .nativeThread(let id, let agentID, let request):
            guard !line.contains(13) else { disconnect(client); return }
            let olderClient = !client.clientCapabilities.contains(RemoteProtocol.nativeQueueCapability)
            dispatchNativeThread(agentID: agentID, request: request, requestBytes: line.count, olderClient: olderClient) { [weak self, weak client] outcome in
                guard let self, let client else { return }
                switch outcome {
                case .result(let result): self.send(.nativeThread(id: id, result: result), to: client)
                case .failure(let code, let message): self.send(.error(id: id, code: code, message: message), to: client)
                }
            }
        case .hello(let id, _, _, _, _):
            send(.error(id: id, code: "protocol", message: "already authenticated"), to: client)
        case .upload(let id, let action):
            do {
                switch action {
                case .begin(let sessionID, let name, let size):
                    guard sessions[sessionID]?.isAlive == true else { throw RemoteCreateAgentError("Session is not running") }
                    guard client.upload == nil else { throw RemoteCreateAgentError("An upload is already in progress") }
                    let upload = try RemoteFileUpload(directory: store.url.deletingLastPathComponent().appendingPathComponent("remote-drops"), sessionID: sessionID, name: name, size: size)
                    client.upload = upload
                    send(.uploadResult(id: id, result: .ready(uploadID: upload.id)), to: client)
                case .chunk(let uploadID, let data):
                    guard let upload = client.upload, upload.id == uploadID else { throw RemoteCreateAgentError("Unknown upload") }
                    try upload.append(data)
                    send(.ok(id: id), to: client)
                case .finish(let uploadID):
                    guard let upload = client.upload, upload.id == uploadID else { throw RemoteCreateAgentError("Unknown upload") }
                    guard sessions[upload.sessionID]?.isAlive == true else { throw RemoteCreateAgentError("Session stopped before upload completed") }
                    let path = try upload.finish()
                    client.upload = nil
                    send(.uploadResult(id: id, result: .complete(path: path)), to: client)
                case .cancel(let uploadID):
                    if client.upload?.id == uploadID { client.upload = nil }
                    send(.ok(id: id), to: client)
                }
            } catch {
                switch action {
                case .chunk(let uploadID, _), .finish(let uploadID):
                    if client.upload?.id == uploadID { client.upload = nil }
                case .begin, .cancel: break
                }
                send(.error(id: id, code: "upload_failed", message: String(describing: error)), to: client)
            }
        case .creationOptions(let id, let spaceID, let cwd, let fetchFirst):
            guard store.state.spaces.contains(where: { $0.id == spaceID }), let handler = onRemoteCreationOptions else {
                send(.error(id: id, code: "unavailable", message: "Host creation options unavailable"), to: client)
                return
            }
            hopToMain { [weak self] in
                handler(spaceID, cwd, fetchFirst) { result in
                    guard let self else { return }
                    self.queue.async {
                        guard self.clients[client.fd] === client else { return }
                        switch result {
                        case .success(var options):
                            if client.knowsLegacyThinkingOnly { options.thinking = options.thinking.clamped(to: ThinkingLevel.legacy) }
                            self.send(.creationOptions(id: id, options: options), to: client)
                        case .failure(let error): self.send(.error(id: id, code: "options_failed", message: error.message), to: client)
                        }
                    }
                }
            }
        case .agentQuery(let id, let agentID, .terminals):
            // The server owns the sessions: answered here, without the GUI.
            guard let terminals = terminalActivity(of: agentID) else {
                send(.error(id: id, code: "no_such_agent", message: "Agent no longer exists on the host."), to: client)
                return
            }
            send(.agentResult(id: id, result: .terminals(terminals)), to: client)
        case .agentQuery(let id, let agentID, let query) where query.isChanges:
            // The server owns the engine: answered here, without the GUI, off the queue.
            guard store.state.agents.contains(where: { $0.id == agentID }) else {
                send(.error(id: id, code: "no_such_agent", message: "Agent no longer exists on the host."), to: client)
                return
            }
            let changes = changes
            // The connection is only touched back on the server queue.
            let connection = ChangesUnchecked(value: client)
            Task.detached { [weak self] in
                let result: Result<RemoteAgentResult, ChangesError>
                do { result = .success(try await changes.answer(query, agentID: agentID)) } catch let error as ChangesError {
                    result = .failure(error)
                } catch { result = .failure(ChangesError(ChangesError.gitFailed, String(describing: error))) }
                self?.queue.async {
                    let client = connection.value
                    guard let self, self.clients[client.fd] === client else { return }
                    switch result {
                    case .success(let value): self.send(.agentResult(id: id, result: value), to: client)
                    case .failure(let error): self.send(.error(id: id, code: error.code, message: error.message), to: client)
                    }
                }
            }
        case .agentQuery(let id, let agentID, let query):
            guard let handler = onRemoteAgentQuery else {
                send(.error(id: id, code: "unavailable", message: "Agent inspection is unavailable on the host."), to: client)
                return
            }
            hopToMain { [weak self] in
                handler(agentID, query) { result in
                    guard let self else { return }
                    self.queue.async {
                        guard self.clients[client.fd] === client else { return }
                        switch result {
                        case .success(let value):
                            let reply = RemoteReply.agentResult(id: id, result: value)
                            guard let encoded = try? NDJSON.encode(reply), encoded.count < 1024 * 1024 else {
                                self.send(.error(id: id, code: "too_large", message: "Agent result exceeds the remote payload limit."), to: client)
                                return
                            }
                            self.send(reply, to: client)
                        case .failure(let error): self.send(.error(id: id, code: "query_failed", message: error.message), to: client)
                        }
                    }
                }
            }
        case .agentAction(let id, let agentID, let action):
            guard store.state.agents.contains(where: { $0.id == agentID }) else {
                send(.error(id: id, code: "no_such_agent", message: "Agent no longer exists on the host."), to: client)
                return
            }
            guard let handler = onRemoteAgentAction else {
                send(.error(id: id, code: "unsupported", message: "Host cannot perform agent actions without a GUI."), to: client)
                return
            }
            hopToMain { [weak self] in
                handler(agentID, action) { result in
                    guard let self else { return }
                    self.queue.async {
                        guard self.clients[client.fd] === client else { return }
                        switch result {
                        case .success: self.send(.ok(id: id), to: client)
                        case .failure(let error):
                            self.send(.error(id: id, code: "action_failed", message: error.message), to: client)
                        }
                    }
                }
            }
        case .automation(let id, let automationID, let request):
            remoteAutomation(id: id, automationID: automationID, request: request, client: client)
        case .instructions(let id, let request):
            remoteInstructions(id: id, request: request, client: client)
        case .suggestions(let id, let request):
            remoteSuggestions(id: id, request: request, client: client)
        case .skills(let id, let request):
            remoteSkills(id: id, request: request, client: client)
        case .hostSettings(let id, let request):
            guard let handler = onRemoteHostSettings else {
                send(.error(id: id, code: "unavailable", message: "This host has no settings to share."), to: client)
                return
            }
            hopToMain { [weak self] in
                handler(request) { result in
                    guard let self else { return }
                    self.queue.async {
                        guard self.clients[client.fd] === client else { return }
                        switch result {
                        case .success(let settings): self.send(.hostSettings(id: id, settings: settings), to: client)
                        case .failure(let error): self.send(.error(id: id, code: "settings_failed", message: error.message), to: client)
                        }
                    }
                }
            }
        case .stateFetch(let id):
            let state = store.state
            send(.state(id: id, state: client.knowsLegacyThinkingOnly ? state.legacyThinkingLevels() : state), to: client)
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
            if let session = sessions[sessionID]?.pty, session.isAlive {
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
            let catalog = modelCatalog
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let listing = catalog()
                self?.queue.async {
                    guard let self, self.clients[client.fd] === client else { return }
                    self.send(.models(id: id, models: listing.models, defaultModel: listing.defaultModel,
                                     withoutThinking: listing.withoutThinking, thinkingLevels: listing.thinkingLevels), to: client)
                }
            }
        case .addSpace(let id, let path):
            remoteAddSpace(id: id, path: path, client: client)
        case .createAgent(let id, let spaceID, let cwd, let model, let thinking, let initialPrompt, let worktreeBranch, let worktreeBase, let worktreeFetchFirst, let initialImages):
            let images = initialImages ?? []
            // Refused before anything is made: pi would refuse them once the agent exists.
            guard images.isEmpty || initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  NativeImage.fitOneSend(images) else {
                send(.error(id: id, code: "invalid", message: "A new thread takes up to \(NativeImage.maxPerSend) images of \(NativeImage.maxBytes / 1024 / 1024) MiB each, with a prompt."), to: client)
                return
            }
            remoteCreateAgent(
                id: id,
                request: RemoteCreateAgentRequest(
                    spaceID: spaceID,
                    cwd: cwd,
                    model: model,
                    thinking: thinking,
                    initialPrompt: initialPrompt,
                    worktreeBranch: worktreeBranch,
                    worktreeBase: worktreeBase,
                    worktreeFetchFirst: worktreeFetchFirst,
                    initialImages: images
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
        hopToMain { [weak self] in
            handler(request) { outcome in
                guard let self else { return }
                self.queue.async {
                    guard self.clients[client.fd] === client else { return }
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

    /// A remote client managing an automation. Everything but reading its runs goes through
    /// `onAutomationRequest`, the handler an agent's `automation_*` tools reach, so a remote
    /// change follows the same rules as a local one.
    private func remoteAutomation(id: Int, automationID: AutomationID, request: RemoteAutomationRequest, client: ExtensionConnection) {
        let exists = store.state.automations.contains { $0.id == automationID }
        func fail(_ code: String, _ message: String) {
            send(.error(id: id, code: code, message: message), to: client)
        }
        if case .create = request {
            guard !exists else { return fail("conflict", "automation \(automationID) already exists") }
        } else if !exists {
            return fail("no_such_automation", "The automation no longer exists on the host.")
        }
        let routed: AutomationRequest
        switch request {
        case .runs:
            send(.automationResult(id: id, result: .runs(runLog.runs(for: automationID, in: store.state))), to: client)
            return
        case .setEnabled(let enabled):
            routed = .update(automationID: automationID, name: nil, prompt: nil, cwd: nil, enabled: enabled)
        case .run:
            routed = .start(automationID: automationID)
        case .stop:
            routed = .stop(automationID: automationID)
        case .delete:
            routed = .delete(automationID: automationID)
        case .create(let draft), .update(let draft):
            let fields: (name: String, prompt: String, cwd: String)
            switch Self.validatedAutomation(draft) {
            case .success(let valid): fields = valid
            case .failure(let error): return fail(error.code, error.message)
            }
            if case .create = request {
                let automation = Automation(id: automationID, name: fields.name, prompt: fields.prompt, cwd: fields.cwd,
                                            enabled: draft.enabled)
                routed = .create(automation: automation, start: false)
            } else {
                routed = .update(automationID: automationID, name: fields.name, prompt: fields.prompt, cwd: fields.cwd,
                                 enabled: draft.enabled)
            }
        }
        guard let handler = onAutomationRequest else {
            return fail("unsupported", "Host cannot manage automations without a GUI.")
        }
        hopToMain { [weak self] in
            handler(routed) { outcome in
                guard let self else { return }
                self.queue.async {
                    guard self.clients[client.fd] === client else { return }
                    switch outcome {
                    case .failed(let code, let message): self.send(.error(id: id, code: code, message: message), to: client)
                    case .ok, .automations: self.send(.automationResult(id: id, result: .ok), to: client)
                    }
                }
            }
        }
    }

    struct AutomationDraftError: Error, Equatable {
        let code: String
        let message: String
    }

    /// A remote client reading or saving this host's root instructions. They are two small
    /// files behind the store's lock, so the server answers here, with or without a GUI; a save
    /// or a restore tells the GUI, whose Settings page follows.
    private func remoteInstructions(id: Int, request: RemoteInstructionsRequest, client: ExtensionConnection) {
        do {
            let snapshot: InstructionsSnapshot
            switch request {
            case .fetch:
                snapshot = instructions.snapshot()
            case .save(let file, let content, let origin, let sync):
                snapshot = try instructions.save(file, content: content, origin: origin, sync: sync)
                announceInstructions(snapshot)
            case .restore(let revisionID, let origin):
                snapshot = try instructions.restore(revisionID: revisionID, origin: origin)
                announceInstructions(snapshot)
            }
            send(.instructions(id: id, snapshot: snapshot), to: client)
        } catch InstructionsStore.StoreError.noSuchRevision {
            send(.error(id: id, code: "no_such_revision", message: InstructionsStore.StoreError.noSuchRevision.description), to: client)
        } catch {
            send(.error(id: id, code: "write_failed", message: String(describing: error)), to: client)
        }
    }

    private func announceInstructions(_ snapshot: InstructionsSnapshot) {
        guard let handler = onInstructionsChanged else { return }
        hopToMain { handler(snapshot) }
    }

    private func remoteSuggestions(id: Int, request: RemoteSuggestionsRequest, client: ExtensionConnection) {
        do {
            let snapshot: SuggestionsSnapshot
            switch request {
            case .fetch:
                snapshot = suggestions.snapshot()
            case .configure(let settings):
                snapshot = try suggestions.configure(settings)
            case .add(let suggestionID, let line, let file):
                if let line, let problem = InstructionsText.suggestionProblem(line) {
                    send(.error(id: id, code: "invalid", message: problem), to: client)
                    return
                }
                snapshot = try suggestions.add(suggestionID, line: line, file: file)
                announceInstructions(instructions.snapshot())
            case .addAll:
                snapshot = try suggestions.addAll()
                announceInstructions(instructions.snapshot())
            case .dismiss(let suggestionID):
                snapshot = try suggestions.dismiss(suggestionID)
            case .undo(let addedID):
                snapshot = try suggestions.undo(addedID)
                announceInstructions(instructions.snapshot())
            }
            if request != .fetch { announceSuggestions(snapshot) }
            send(.suggestions(id: id, snapshot: snapshot), to: client)
        } catch SuggestionsStore.StoreError.noSuchSuggestion {
            send(.error(id: id, code: "no_such_suggestion", message: SuggestionsStore.StoreError.noSuchSuggestion.description), to: client)
        } catch {
            send(.error(id: id, code: "write_failed", message: String(describing: error)), to: client)
        }
    }

    /// An agent's `suggest_instruction`: taken only while the experiment is on for its kind of
    /// agent and the file, and answered with what became of the line.
    private func suggestInstruction(id: Int, agentID: AgentID, line: String, reason: String, file: InstructionFile?,
                                    client: ExtensionConnection) {
        guard let agent = store.state.agents.first(where: { $0.id == agentID }) else {
            reply(.error(id: id, code: "no_such_agent", message: "no such agent"), to: client)
            return
        }
        let kind: SuggestionSource.Kind = Self.automationRunAgentIDs(in: store.state).contains(agentID) ? .automation : .thread
        let file = file ?? .agents
        guard suggestions.snapshot().settings.files(for: kind).contains(file) else {
            reply(.error(id: id, code: "suggestions_off",
                         message: "The user hasn't turned on suggestions for \(file.fileName) from this agent."), to: client)
            return
        }
        if let problem = InstructionsText.suggestionProblem(line) {
            reply(.error(id: id, code: "invalid", message: problem), to: client)
            return
        }
        do {
            let result = try suggestions.suggest(line: line, reason: String(reason.prefix(600)), file: file,
                                                 source: SuggestionSource(kind: kind, name: agent.name))
            if result.outcome == .waiting { announceSuggestions(result.snapshot) }
            reply(.suggestion(id: id, outcome: result.outcome), to: client)
        } catch {
            reply(.error(id: id, code: "write_failed", message: String(describing: error)), to: client)
        }
    }

    private func announceSuggestions(_ snapshot: SuggestionsSnapshot) {
        guard let handler = onSuggestionsChanged else { return }
        hopToMain { handler(snapshot) }
    }

    /// A remote client reading or changing this host's skills. Looking up, installing and
    /// checking for updates fetch from git, so every request runs on the skills queue and its
    /// answer comes back here; a change tells the GUI, whose Skills page follows.
    private func remoteSkills(id: Int, request: RemoteSkillsRequest, client: ExtensionConnection) {
        let skillsStore = self.skills
        skillsQueue.async { [weak self] in
            let result: Result<RemoteSkillsResult, SkillsStore.StoreError>
            do {
                result = .success(try skillsStore.perform(request))
            } catch let error as SkillsStore.StoreError {
                result = .failure(error)
            } catch {
                result = .failure(.writeFailed(error.localizedDescription))
            }
            guard let self else { return }
            self.queue.async {
                if request.changesSkills, case .success(.skills(let snapshot)) = result, let handler = self.onSkillsChanged {
                    self.hopToMain { handler(snapshot) }
                }
                guard self.clients[client.fd] === client else { return }
                switch result {
                case .success(let answer): self.send(.skills(id: id, result: answer), to: client)
                case .failure(let error): self.send(.error(id: id, code: error.code, message: error.description), to: client)
                }
            }
        }
    }

    /// A remote draft as the host would save it: a name and a prompt that are not blank, and a
    /// directory that exists on the host.
    static func validatedAutomation(_ draft: RemoteAutomationDraft) -> Result<(name: String, prompt: String, cwd: String), AutomationDraftError> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.init(code: "invalid_automation", message: "An automation needs a name.")) }
        guard !prompt.isEmpty else { return .failure(.init(code: "invalid_automation", message: "An automation needs a prompt.")) }
        let cwd = (draft.cwd as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure(.init(code: "no_such_directory", message: "\(cwd) is not a directory on the host"))
        }
        return .success((name, prompt, cwd))
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
        do {
            try mutateState { $0.spaces.append(space) }
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
        hopToMain { [weak self] in
            handler(request) { result in
                guard let self else { return }
                self.queue.async {
                    guard self.clients[client.fd] === client else { return }
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
        guard let session = sessions[sessionID]?.pty, session.isAlive else {
            send(.error(id: id, code: "no_such_session", message: "session is not running or has no terminal"), to: client)
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
        guard let session = sessions[sessionID]?.pty else { return }
        let remote = Array((remoteViewports[sessionID] ?? [:]).values)
        let grids = remote.isEmpty ? localViewports[sessionID].map { [$0] } ?? [] : remote
        guard let minCols = grids.map(\.cols).min(),
              let minRows = grids.map(\.rows).min() else { return }
        // Viewport reports arrive on every surface layout, attach, and detach.
        // A same-size resize would SIGWINCH the child into a full repaint for
        // nothing; attach paths get their redraw from the snapshot instead.
        guard session.cols != minCols || session.rows != minRows else { return }
        resizePTY(session, sessionID: sessionID, cols: minCols, rows: minRows)
    }

    /// Server queue. Every PTY resize goes through here: what the child prints next redraws
    /// its screen, which is not news (`TerminalNews`).
    private func resizePTY(_ session: PTYSession, sessionID: SessionID, cols: Int, rows: Int) {
        outputStates[sessionID]?.news.resized(at: .now)
        session.resize(cols: cols, rows: rows)
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
        guard let entry = sessions[sessionID] else {
            send(.error(id: id, code: "no_such_session", message: "unknown session \(sessionID)"), to: client)
            return
        }
        guard let session = entry.pty else {
            send(.error(id: id, code: "no_terminal", message: "session \(sessionID) is an RPC session and has no terminal"), to: client)
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
        guard let payload = Self.stateChangedPayload(state) else { return }
        // Encoded a second time only while an older client is connected and an agent has a level
        // it cannot decode.
        let legacyOnly = state.usesOnlyLegacyThinkingLevels
        var legacyPayload: Data??
        for client in remotes {
            guard client.knowsLegacyThinkingOnly, !legacyOnly else {
                enqueuePayload(payload, to: client)
                continue
            }
            if legacyPayload == nil { legacyPayload = .some(Self.stateChangedPayload(state.legacyThinkingLevels())) }
            if let data = legacyPayload ?? nil { enqueuePayload(data, to: client) }
        }
    }

    private static func stateChangedPayload(_ state: ShepherdState) -> Data? {
        guard let payload = try? NDJSON.encode(RemoteReply.stateChanged(state: state)),
              payload.count - 1 <= NDJSON.maxPayloadBytes else {
            ShepherdLog.error("state broadcast exceeds the payload limit; skipped")
            return nil
        }
        return payload
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
        for (token, request) in agentRequests where !request.deletionConfirmed && (request.caller === client || request.target === client) {
            finishAgentRequest(token, result: .init(text: "agent connection closed", code: "disconnected"))
        }
        client.upload = nil
        for (id, pending) in childCommandPending where pending.client === client {
            childCommandPending.removeValue(forKey: id)?.completion("Children extension disconnected. Refresh before acting.")
        }
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
            // Rows feed both the thread snapshot (cards) and the sidebar (onAgentChildren).
            rpcThread(forAgent: agentID)?.setSubagents(children)
            hopToMain { [weak self] in self?.onAgentChildren?(agentID, children) }
        case .helloChildren(let agentID):
            guard store.state.agents.contains(where: { $0.id == agentID }), client.agentID == nil else { return }
            for previous in Array(clients.values) where previous !== client && previous.childrenAgentID == agentID {
                disconnect(previous)
            }
            client.childrenAgentID = agentID
        case .childCommandResult(let id, let error):
            guard let pending = childCommandPending[id], pending.client === client else { return }
            childCommandPending.removeValue(forKey: id)?.completion(error)
        case .notify(let agentID, let title, let body):
            hopToMain { [weak self] in self?.onNotify?(agentID, title, body) }
        case .helloAgent(let agentID):
            client.agentID = agentID
        case .coordinateAgent(let id, let agentID, let targetAgentID, let request):
            coordinateAgent(id: id, agentID: agentID, targetAgentID: targetAgentID, request: request, client: client)
        case .agentResponse(let agentID, let token, let result):
            guard let pending = agentRequests[token], pending.target === client,
                  pending.targetAgentID == agentID, client.agentID == agentID else { return }
            guard result.text.utf8.count <= 64 * 1024 else {
                finishAgentRequest(token, result: .init(text: "agent response exceeds 64 KiB", code: "reply_too_large"))
                return
            }
            finishAgentRequest(token, result: result)
        case .cancelAgentRequest(let id, let agentID):
            guard client.agentID == agentID else { return }
            for (token, pending) in agentRequests where pending.caller === client && pending.id == id && !pending.deletionConfirmed {
                finishAgentRequest(token, result: .init(text: "request cancelled", code: "cancelled"))
            }
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
        case .requestReview(let id, let agentID, let cwd, let reference):
            routeReviewRequest(.start(agentID: agentID, cwd: cwd, reference: reference), requestID: id, client: client)
        case .suggestInstruction(let id, let agentID, let line, let reason, let file):
            suggestInstruction(id: id, agentID: agentID, line: line, reason: reason, file: file, client: client)
        case .designRead(let id, let agentID, let designID, let path):
            designRequest(id: id, agentID: agentID, designID: designID, path: path, client: client) { server, path in
                if let path { return .designBoard(id: id, board: try await server.designBoard(designID, path: path)) }
                return .design(id: id, snapshot: try await server.designSnapshot(designID))
            }
        case .designWriteBoard(let id, let agentID, let designID, let path, let source, let baseRevision):
            designRequest(id: id, agentID: agentID, designID: designID, path: path, client: client) { server, path in
                guard let path else { throw DesignStoreError.invalidPath("", .empty) }
                let result = try await server.writeDesignBoard(designID, path: path, source: source, baseRevision: baseRevision)
                return .designWritten(id: id, result: result)
            }
        case .designUpdateIndex(let id, let agentID, let designID, let changes, let baseRevision):
            designRequest(id: id, agentID: agentID, designID: designID, path: nil, client: client) { server, _ in
                let result = try await server.updateDesignIndex(designID, patch: changes, baseRevision: baseRevision)
                return .designWritten(id: id, result: result)
            }
        case .designComments(let id, let agentID, let designID):
            designRequest(id: id, agentID: agentID, designID: designID, path: nil, client: client) { server, _ in
                .designComments(id: id, comments: try await server.designComments(designID))
            }
        case .designCommentReply(let id, let agentID, let designID, let commentID, let text):
            designRequest(id: id, agentID: agentID, designID: designID, path: nil, client: client) { server, _ in
                guard let comment = UUID(uuidString: commentID) else { throw DesignStoreError.noSuchComment(commentID) }
                let outcome = try await server.replyToDesignComment(designID, commentID: comment, text: text, author: .agent)
                return .designComment(id: id, comment: outcome.comment)
            }
        }
    }

    /// Server queue: one design extension request. Only the agent drawing the design may read or
    /// write it, and a board path is checked against the grammar before anything is read. The
    /// files are read and written on the design store's queue; the reply comes back here.
    private func designRequest(id: Int, agentID: AgentID, designID: DesignID, path: String?, client: ExtensionConnection,
                               _ body: @escaping @Sendable (SessionServer, DesignPath?) async throws -> ExtensionReply) {
        guard let agent = store.state.agents.first(where: { $0.id == agentID }) else {
            reply(.error(id: id, code: "no_such_agent", message: "no such agent"), to: client)
            return
        }
        guard agent.designID == designID, store.state.designs.contains(where: { $0.id == designID }) else {
            reply(.error(id: id, code: "not_your_design", message: "this agent does not draw design \(designID)"), to: client)
            return
        }
        var boardPath: DesignPath?
        if let path {
            do { boardPath = try DesignPath.validate(path) } catch {
                reply(.error(id: id, code: DesignStoreError.invalidPath(path, error).code,
                             message: DesignStoreError.invalidPath(path, error).description), to: client)
                return
            }
        }
        // The connection stays on this queue; the task carries only a token for it.
        nextDesignRequest += 1
        let token = nextDesignRequest
        designRequestClients[token] = client
        Task { [weak self] in
            guard let self else { return }
            let answer: ExtensionReply
            do {
                answer = try await body(self, boardPath)
            } catch let error as DesignStoreError {
                answer = .error(id: id, code: error.code, message: error.description)
            } catch let error as SessionServerError {
                answer = .error(id: id, code: "design_refused", message: error.description)
            } catch {
                answer = .error(id: id, code: "design_failed", message: String(describing: error))
            }
            self.queue.async {
                guard let client = self.designRequestClients.removeValue(forKey: token) else { return }
                self.reply(answer, to: client)
            }
        }
    }

    private func coordinateAgent(id: Int, agentID: AgentID, targetAgentID: AgentID,
                                 request: AgentCoordinationRequest, client: ExtensionConnection) {
        guard client.agentID == agentID,
              let sender = store.state.agents.first(where: { $0.id == agentID }),
              store.state.agents.contains(where: { $0.id == targetAgentID }) else {
            reply(.error(id: id, code: "no_such_agent", message: "registered sender and existing target required"), to: client)
            return
        }
        guard agentID != targetAgentID || request.operation == .read else {
            reply(.error(id: id, code: "self_control", message: "an agent cannot control, wait for, or delete itself"), to: client)
            return
        }
        guard agentRequests.values.filter({ $0.caller === client }).count < 16,
              !agentRequests.values.contains(where: { $0.caller === client && $0.id == id }) else {
            reply(.error(id: id, code: "busy", message: "too many pending agent requests or duplicate id"), to: client)
            return
        }
        var forwarded = request
        if request.operation == .steer {
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 32 * 1024 else {
                reply(.error(id: id, code: "invalid", message: "steering text must contain 1 to 32768 bytes"), to: client)
                return
            }
            forwarded.text = "[from: \(sender.name)] \(text)"
        }
        let target = clients.values.first { !$0.isRemote && $0.agentID == targetAgentID }
        guard request.operation == .delete || target != nil else {
            reply(.error(id: id, code: "not_running", message: "target has no live panes extension"), to: client)
            return
        }
        let token = UUID().uuidString
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.agentRequests[token]?.deletionConfirmed == false else { return }
            self.finishAgentRequest(token, result: .init(text: "agent request timed out", code: "timeout"))
        }
        agentRequests[token] = PendingAgentRequest(caller: client, target: request.operation == .delete ? nil : target,
                                                  targetAgentID: targetAgentID, id: id, timer: timer)
        queue.asyncAfter(deadline: .now() + (request.operation == .delete ? 120 : 5), execute: timer)
        if request.operation == .delete {
            guard let handler = onAgentPeerRequest else {
                finishAgentRequest(token, result: .init(text: "native confirmation unavailable", code: "unsupported"))
                return
            }
            hopToMain { [weak self] in
                handler(.delete(agentID: agentID, targetAgentID: targetAgentID, requestID: token)) { outcome in
                    guard let self else { return }
                    self.queue.async {
                        let result: AgentCoordinationResult
                        switch outcome {
                        case .ok: result = .init(text: "deleted agent \(targetAgentID); process termination requested; worktree and branch kept")
                        case .failed(let code, let message): result = .init(text: message, code: code)
                        case .agents: result = .init(text: "invalid deletion response", code: "invalid")
                        }
                        self.finishAgentRequest(token, result: result)
                    }
                }
            }
        } else if let target {
            reply(.agentRequest(id: 0, requestID: token, targetAgentID: targetAgentID, request: forwarded), to: target)
        }
    }

    private func finishAgentRequest(_ token: String, result: AgentCoordinationResult) {
        guard let pending = agentRequests.removeValue(forKey: token) else { return }
        pending.timer.cancel()
        reply(.agentResult(id: pending.id, result: result), to: pending.caller)
        if pending.target == nil {
            hopToMain { [weak self] in self?.onAgentPeerCancellation?(token) }
        }
    }

    /// Claim only after a native button click. A timed-out or cancelled dialog cannot delete.
    public func claimAgentDeletion(_ token: String) async -> Bool {
        await enqueueValue {
            guard var pending = self.agentRequests[token], pending.target == nil,
                  !pending.deletionConfirmed else { return false }
            pending.deletionConfirmed = true
            pending.timer.cancel()
            self.agentRequests[token] = pending
            return true
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

    /// Hand a review request to the GUI and write its reply back to the client.
    private func routeReviewRequest(_ request: ReviewRequest, requestID: Int, client: ExtensionConnection) {
        guard let handler = onReviewRequest else {
            reply(.error(id: requestID, code: "unsupported", message: "no review handler"), to: client)
            return
        }
        hopToMain { [weak self, weak client] in
            handler(request) { outcome in
                guard let self, let client else { return }
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
        case .childCommand(let id, _, _, _, _), .ok(let id),
             .error(let id, _, _),
             .panes(let id, _),
             .paneOpened(let id, _),
             .paneContent(let id, _, _),
             .reviewResult(let id, _),
             .automations(let id, _),
             .agents(let id, _),
             .message(let id, _),
             .agentRequest(let id, _, _, _),
             .agentResult(let id, _),
             .suggestion(let id, _),
             .design(let id, _),
             .designBoard(let id, _),
             .designWritten(let id, _),
             .designComments(let id, _),
             .designComment(let id, _):
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
        var failure: TurnFailure?
        if status == .done, let thread = rpcThread(forAgent: agentID) {
            // Between queued turns pi settles for a moment; the agent is not done (and must not
            // post "Agent finished") while its queue goes next. And the extension's report can
            // arrive before pi's own settle on stdout, which says how the turn ended: wait for it.
            if thread.continuesAfterSettle || thread.running {
                thread.doneHeld = true
                return
            }
            failure = thread.turnFailure
        }
        if let index = store.state.agents.firstIndex(where: { $0.id == agentID }) {
            let current = store.state.agents[index].status
            if current == status {
                // Nothing to persist or broadcast (extension reconnects re-send
                // the current status); the callback still fires so launch UI
                // learns pi is up.
                hopToMain { [weak self] in self?.onAgentStatus?(agentID, status, failure) }
                return
            }
            if !current.canTransition(to: status) {
                ShepherdLog.warning("agent \(agentID): invalid status transition \(current.rawValue) -> \(status.rawValue); applying anyway")
            }
            // Two reports a turn: kept in memory, never validated or written on their own. A turn
            // starting or ending moves the agent up Recents; nothing else a turn reports does.
            let before = store.state
            let moved = AgentStatus.movesRecents(from: current, to: status)
            let now = Self.nowMilliseconds()
            store.updateLive {
                $0.agents[index].status = status
                if moved { $0.agents[index].lastActiveAt = now }
            }
            runLog.record(from: before, to: store.state)
        } else {
            ShepherdLog.warning("setAgentStatus for unknown agent \(agentID); dropped")
            return
        }
        let committedState = store.state
        broadcastRemoteState(committedState)
        hopToMain { [weak self] in
            self?.onAgentStatus?(agentID, status, failure)
            self?.onStateChanged?(committedState)
        }
    }

    /// Server queue: the question an agent's thread asks first changed (its title and the
    /// agent's short reason for it). Live state, like a status: broadcast at once and never
    /// written on its own (nor ever to state.json).
    func applyAgentQuestion(agentID: AgentID, question: String?, reason: String? = nil) {
        guard let index = store.state.agents.firstIndex(where: { $0.id == agentID }) else { return }
        let reason = question == nil ? nil : reason
        let agent = store.state.agents[index]
        guard agent.waitingOn != question || agent.waitingReason != reason else { return }
        store.updateLive {
            $0.agents[index].waitingOn = question
            $0.agents[index].waitingReason = reason
        }
        let committedState = store.state
        broadcastRemoteState(committedState)
        hopToMain { [weak self] in self?.onStateChanged?(committedState) }
    }

    /// Server queue: a message was sent to the agent, which moves it up Recents.
    private func noteAgentSend(_ agentID: AgentID) {
        guard let index = store.state.agents.firstIndex(where: { $0.id == agentID }) else { return }
        let now = Self.nowMilliseconds()
        store.updateLive { $0.agents[index].lastActiveAt = now }
        let committedState = store.state
        broadcastRemoteState(committedState)
        hopToMain { [weak self] in self?.onStateChanged?(committedState) }
    }

    /// Now, as `Agent.lastActiveAt` keeps it.
    public static func nowMilliseconds() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

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
        let before = store.state
        do {
            try store.update(mutate)
        } catch {
            throw SessionServerError.persistFailed(String(describing: error))
        }
        let state = store.state
        runLog.record(from: before, to: state)
        broadcastRemoteState(state)
        hopToMain { [weak self] in self?.onStateChanged?(state) }
        announceServableThreads()
    }

    /// Server queue: tell the app about every serving thread whose agent is now bound to it.
    private func announceServableThreads() {
        guard !unannouncedServable.isEmpty else { return }
        for sessionID in unannouncedServable {
            guard let agentID = agentID(forSession: sessionID) else { continue }
            unannouncedServable.remove(sessionID)
            hopToMain { [weak self] in self?.onNativeThreadServable?(agentID) }
        }
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
            // Revisions pi reached before its pane was bound had no agent to reach.
            if let sessionID, self.sessions[sessionID]?.thread != nil {
                self.threadRevised(sessionID: sessionID)
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

    /// Remove a space with everything that lives in it: its agents, their
    /// layouts and utility tabs, and every session
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
                // Designs outlive their agents (and their space): opening one starts a fresh agent.
                for i in $0.designs.indices where $0.designs[i].agentID.map(doomedAgents.contains) == true {
                    $0.designs[i].agentID = nil
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
            guard let spaceID = tab.spaceID else {
                throw SessionServerError.conflict("tab \(tab.id) belongs to no space")
            }
            guard self.store.state.spaces.contains(where: { $0.id == spaceID }) else {
                throw SessionServerError.noSuchSpace(spaceID)
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

    /// Record the branch and changed-file count the app read from an agent's checkout. Live
    /// state, like a status: broadcast at once (remote clients draw it in their headers), never
    /// validated or written on its own, and a no-op when nothing changed.
    public func setAgentCheckout(_ agentID: AgentID, _ checkout: AgentCheckout?) async {
        await enqueueValue {
            guard let index = self.store.state.agents.firstIndex(where: { $0.id == agentID }),
                  self.store.state.agents[index].checkout != checkout else { return }
            self.store.updateLive { $0.agents[index].checkout = checkout }
            let committedState = self.store.state
            self.broadcastRemoteState(committedState)
            self.hopToMain { [weak self] in self?.onStateChanged?(committedState) }
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

    public func reorderAgent(_ agentID: AgentID, onto target: AgentID) async throws {
        try await enqueue {
            let agents = self.store.state.agents
            guard let from = agents.firstIndex(where: { $0.id == agentID }),
                  let to = agents.firstIndex(where: { $0.id == target }),
                  agents[from].spaceID == agents[to].spaceID else {
                throw SessionServerError.conflict("Agents must belong to the same space")
            }
            guard from != to, let moved = agents.moving(agentID, before: target) else { return }
            try self.mutateState { $0.agents = moved }
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
                for i in $0.designs.indices where $0.designs[i].agentID == agentID {
                    $0.designs[i].agentID = nil
                }
            }
        }
    }

    // MARK: - Automations (server queue)

    /// Each automation's run whose agent still exists, from any thread without waiting for the
    /// server queue: a state broadcast or awaited mutation is always reflected in it. The local
    /// GUI reads whether a run is live (`AutomationRun.isLive`) from it.
    public var openAutomationRuns: [AutomationID: AutomationRun] {
        runLog.openRuns
    }

    /// The runs the host kept for an automation, oldest first; a run's agent only while it exists.
    public func automationRuns(_ automationID: AutomationID) async -> [AutomationRun] {
        await enqueueValue { self.runLog.runs(for: automationID, in: self.store.state) }
    }

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
                // The design stays; opening it starts a fresh agent.
                for i in $0.designs.indices where $0.designs[i].agentID == agentID {
                    $0.designs[i].agentID = nil
                }
            }

            for sessionID in layoutSessions {
                self.killSessionOnQueue(sessionID)
            }
        }
    }

    // MARK: - Designs

    /// Makes a design: its folder with a new canvas.json titled with its name, then its record.
    /// Its space must exist, and its agent when it names one.
    public func createDesign(_ design: Design) async throws -> DesignSnapshot {
        var design = design
        design.name = design.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !design.name.isEmpty else { throw SessionServerError.conflict("a design needs a name") }
        try await enqueue { try self.checkNewDesign(design) }
        let created = Date(timeIntervalSince1970: design.createdAt / 1000)
        let snapshot = try await designs.create(design.id, title: design.name, at: created)
        design.boardCount = snapshot.index.boards.count
        do {
            try await enqueue {
                try self.checkNewDesign(design)
                try self.mutateState { $0.designs.append(design) }
            }
        } catch {
            try? await designs.delete(design.id)
            throw error
        }
        return snapshot
    }

    private func checkNewDesign(_ design: Design) throws {
        guard !store.state.designs.contains(where: { $0.id == design.id }) else {
            throw SessionServerError.conflict("design \(design.id) already exists")
        }
        guard store.state.spaces.contains(where: { $0.id == design.spaceID }) else {
            throw SessionServerError.noSuchSpace(design.spaceID)
        }
        if let agentID = design.agentID, !store.state.agents.contains(where: { $0.id == agentID }) {
            throw SessionServerError.noSuchAgent(agentID)
        }
    }

    /// Renames a design: its record and its canvas's `title`.
    public func renameDesign(_ designID: DesignID, to name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SessionServerError.conflict("a design needs a name") }
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let result = try await designs.updateIndex(designID, patch: .object(["title": .string(trimmed)]), baseRevision: nil)
        try await enqueue { try self.commitDesignWrite(designID, result) }
    }

    /// Forgets a design and removes its folder. Its agent stays an ordinary agent.
    public func deleteDesign(_ designID: DesignID) async throws {
        try await enqueue {
            guard self.store.state.designs.contains(where: { $0.id == designID }) else {
                throw SessionServerError.noSuchDesign(designID)
            }
            try self.mutateState {
                $0.designs.removeAll { $0.id == designID }
                for i in $0.agents.indices where $0.agents[i].designID == designID {
                    $0.agents[i].designID = nil
                }
            }
        }
        try await designs.delete(designID)
    }

    /// Records which agent draws a design (nil: none; opening it starts one).
    public func setDesignAgent(_ designID: DesignID, agentID: AgentID?) async throws {
        try await enqueue {
            guard let index = self.store.state.designs.firstIndex(where: { $0.id == designID }) else {
                throw SessionServerError.noSuchDesign(designID)
            }
            if let agentID, !self.store.state.agents.contains(where: { $0.id == agentID }) {
                throw SessionServerError.noSuchAgent(agentID)
            }
            guard self.store.state.designs[index].agentID != agentID else { return }
            try self.mutateState { $0.designs[index].agentID = agentID }
        }
    }

    /// A design's index, revision and board hashes.
    public func designSnapshot(_ designID: DesignID) async throws -> DesignSnapshot {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        return try await designs.snapshot(designID)
    }

    /// One board's source.
    public func designBoard(_ designID: DesignID, path: DesignPath) async throws -> DesignBoardSource {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        return try await designs.board(designID, path: path)
    }

    /// Writes a board's whole source (`DesignBoardCheck` first), when the design is still at
    /// `baseRevision` (nil: whatever it is at). A write that changes the files moves the design
    /// up Recents and broadcasts.
    public func writeDesignBoard(_ designID: DesignID, path: DesignPath, source: String,
                                 baseRevision: UInt64? = nil) async throws -> DesignWriteResult {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let result = try await designs.writeBoard(designID, path: path, source: source, baseRevision: baseRevision)
        try await enqueue { try self.commitDesignWrite(designID, result) }
        return result
    }

    /// Writes several boards' whole sources as one change: one revision, one broadcast (a tweak
    /// applied to every element of a name). Each board's replaced content is kept as a version.
    public func writeDesignBoards(_ designID: DesignID, sources: [DesignPath: String],
                                  baseRevision: UInt64? = nil) async throws -> DesignBoardsWrite {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let written = try await designs.writeBoards(designID, sources: sources, baseRevision: baseRevision)
        try await enqueue { try self.commitDesignWrite(designID, written.result) }
        return written
    }

    /// A board's kept versions, oldest first (the last `DesignBoardVersion.kept`).
    public func designVersions(_ designID: DesignID, path: DesignPath) async throws -> [DesignBoardVersion] {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        return try await designs.versions(designID, path: path)
    }

    /// Puts boards back to kept versions as one change. With `ifCurrent`, only while each board
    /// still has the hash it names (an undo never takes back a later write); what each held is
    /// kept as its next version, so a restore can itself be undone.
    public func restoreDesignVersions(_ designID: DesignID, _ versions: [DesignPath: Int], ifCurrent: [DesignPath: String]? = nil,
                                      baseRevision: UInt64? = nil) async throws -> DesignBoardsWrite {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let written = try await designs.restore(designID, versions: versions, ifCurrent: ifCurrent, baseRevision: baseRevision)
        try await enqueue { try self.commitDesignWrite(designID, written.result) }
        return written
    }

    /// Applies a canvas_update to the design's index (`DesignIndex.merging`: a JSON merge patch
    /// that keeps every key it doesn't name), when the design is still at `baseRevision`. A new
    /// `title` renames the design.
    public func updateDesignIndex(_ designID: DesignID, patch: JSONValue,
                                  baseRevision: UInt64? = nil) async throws -> DesignWriteResult {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let result = try await designs.updateIndex(designID, patch: patch, baseRevision: baseRevision)
        try await enqueue { try self.commitDesignWrite(designID, result) }
        return result
    }

    /// Copies a board beside itself as a new board (Duplicate): its file and its canvas entry
    /// as one write, when the design is still at `baseRevision`. Answers the copy's path.
    public func duplicateDesignBoard(_ designID: DesignID, path: DesignPath,
                                     baseRevision: UInt64? = nil) async throws -> DesignDuplicate {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let duplicate = try await designs.duplicateBoard(designID, path: path, baseRevision: baseRevision)
        try await enqueue { try self.commitDesignWrite(designID, duplicate.result) }
        return duplicate
    }

    // MARK: - Design comments

    /// What a comment or reply made on the canvas left behind: the comment as kept, and why it
    /// didn't reach the design agent (nil: it went to pi, or waits in its queue).
    public struct DesignCommentOutcome: Sendable {
        public var comment: DesignComment
        public var undelivered: String?
    }

    /// A design's comments, open and resolved.
    public func designComments(_ designID: DesignID) async throws -> DesignComments {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        return try await designs.comments(designID)
    }

    /// Pins a comment to a board's element (checked against the board's source), when the
    /// comments are still at `baseRevision`, and hands it to the design's agent as a turn of its
    /// own through the host queue: at once while pi is idle, else after the turn it is working
    /// on, never into it.
    public func addDesignComment(_ designID: DesignID, draft: DesignCommentDraft,
                                 baseRevision: UInt64? = nil) async throws -> DesignCommentOutcome {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let comment = try await designs.addComment(designID, draft: draft, baseRevision: baseRevision, at: Self.nowMilliseconds())
        await enqueueValue { self.designRevised(designID) }
        let undelivered = await deliverDesignComment(designID, id: comment.id, text: comment.text,
                                                     fence: DesignCommentFence(comment).fenced())
        return DesignCommentOutcome(comment: comment, undelivered: undelivered)
    }

    /// Adds a reply under a comment. The viewer's reply goes to the design's agent like a comment
    /// (fenced, marked a reply); the agent's (`comment_reply`) goes nowhere else.
    public func replyToDesignComment(_ designID: DesignID, commentID: UUID, text: String, author: DesignCommentAuthor = .user,
                                     baseRevision: UInt64? = nil) async throws -> DesignCommentOutcome {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let comment = try await designs.replyToComment(designID, commentID: commentID, author: author, text: text,
                                                       baseRevision: baseRevision, at: Self.nowMilliseconds())
        await enqueueValue { self.designRevised(designID) }
        guard author == .user, let reply = comment.replies.last else { return DesignCommentOutcome(comment: comment) }
        let undelivered = await deliverDesignComment(designID, id: reply.id, text: reply.text,
                                                     fence: DesignCommentFence(comment, reply: true).fenced())
        return DesignCommentOutcome(comment: comment, undelivered: undelivered)
    }

    /// Resolves a comment, or opens it again. Only the viewer resolves: no extension message
    /// reaches this.
    @discardableResult
    public func resolveDesignComment(_ designID: DesignID, commentID: UUID, resolved: Bool = true,
                                     baseRevision: UInt64? = nil) async throws -> DesignComment {
        guard state.designs.contains(where: { $0.id == designID }) else { throw SessionServerError.noSuchDesign(designID) }
        let comment = try await designs.setCommentResolved(designID, commentID: commentID, resolved: resolved,
                                                           baseRevision: baseRevision, at: Self.nowMilliseconds())
        await enqueueValue { self.designRevised(designID) }
        return comment
    }

    /// Hands a comment (or a reply under one) to the design's agent as its own queued turn: the
    /// fence, then the viewer's words, going to pi alone. Why it couldn't, or nil.
    private func deliverDesignComment(_ designID: DesignID, id: UUID, text: String, fence: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            queue.async {
                let design = self.store.state.designs.first { $0.id == designID }
                guard let agent = self.store.state.agents.first(where: { $0.id == design?.agentID })
                        ?? self.store.state.agents.first(where: { $0.designID == designID }) else {
                    continuation.resume(returning: "The design has no agent.")
                    return
                }
                guard let tab = self.store.state.tabs.first(where: { $0.id == agent.tabID }),
                      let paneID = agent.paneID, let sessionID = tab.layout.leaf(withID: paneID)?.sessionID,
                      let session = self.sessions[sessionID], let thread = session.thread, session.isAlive else {
                    continuation.resume(returning: "The design agent isn't running.")
                    return
                }
                guard thread.isServable else {
                    continuation.resume(returning: "The design agent is starting.")
                    return
                }
                self.noteAgentSend(agent.id)
                thread.send(id: id, text: text, delivery: .followUp, images: [], alone: true, context: fence) { result in
                    if case .failure(_, let message) = result {
                        continuation.resume(returning: message)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    /// Server queue: what a write to a design's files changes in its record. A new title is
    /// persisted; the board count and `lastActiveAt` are live, like an agent's status.
    private func commitDesignWrite(_ designID: DesignID, _ result: DesignWriteResult) throws {
        guard result.changed, let index = store.state.designs.firstIndex(where: { $0.id == designID }) else { return }
        designRevised(designID)
        let now = Self.nowMilliseconds()
        let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, store.state.designs[index].name != title {
            try mutateState {
                $0.designs[index].name = title
                $0.designs[index].boardCount = result.boardCount
                $0.designs[index].lastActiveAt = now
            }
            return
        }
        store.updateLive {
            $0.designs[index].boardCount = result.boardCount
            $0.designs[index].lastActiveAt = now
        }
        let committedState = store.state
        broadcastRemoteState(committedState)
        hopToMain { [weak self] in self?.onStateChanged?(committedState) }
    }

    /// Reads each design's board count off the server's queue after startup, then publishes the
    /// counts that changed as live state.
    private func countDesignBoards() {
        let ids = store.committed.designs.map(\.id)
        guard !ids.isEmpty else { return }
        Task {
            let counts = await designs.boardCounts(ids)
            queue.async {
                let changed = self.store.state.designs.indices.filter {
                    let design = self.store.state.designs[$0]
                    return counts[design.id].map { $0 != design.boardCount } == true
                }
                guard !changed.isEmpty else { return }
                self.store.updateLive { state in
                    for i in changed { state.designs[i].boardCount = counts[state.designs[i].id] }
                }
                let committedState = self.store.state
                self.broadcastRemoteState(committedState)
                self.hopToMain { [weak self] in self?.onStateChanged?(committedState) }
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

    /// Hands a new agent's pi (an RPC session) its opening prompt: held until the thread serves,
    /// then sent before the thread answers any request, so every client's first snapshot shows
    /// it. Its pending row is `OpeningPrompt`'s, which a client can draw while pi starts.
    public func sendOpeningPrompt(_ prompt: OpeningPrompt, sessionID: SessionID) async {
        await enqueueValue { self.sessions[sessionID]?.thread?.sendOpeningPrompt(prompt.text, images: prompt.images, id: prompt.operationID) }
    }

    /// Whether an RPC session's thread serves yet, bound to an agent or not (for tests).
    func threadServes(sessionID: SessionID) async -> Bool {
        await enqueueValue { self.sessions[sessionID]?.thread?.isServable == true }
    }

    public func createSession(params: CreateSessionParams) async throws -> SessionInfo {
        try await enqueue {
            try self.makeSessionOnQueue(params: params)
        }
    }

    private func makeSessionOnQueue(params: CreateSessionParams) throws -> SessionInfo {
        let server = self
        weak let serverWeak = server
        if params.runtime == .rpc {
            let sessionQueue = DispatchQueue(label: "shepherd.rpc", target: queue)
            let session: RPCSession
            do {
                session = try RPCSession(params: params, queue: sessionQueue)
            } catch {
                throw PTYSession.SpawnError(message: String(describing: error))
            }
            let sid = session.id
            session.beforeOffQueueDecode = beforeOffQueueDecode
            let thread = RPCThreadState(session: session, queue: sessionQueue, originStore: originStore)
            thread.defaultQueueMode = defaultQueueMode
            // pi's compaction settings, as this pi reads them: its agent directory (the app's
            // environment, or the session's) and the project's own. Read, never written.
            let piDirectory = PiConfig.agentDirectory(environment: ProcessInfo.processInfo.environment.merging(params.env ?? [:]) { $1 })
            let cwd = params.cwd
            thread.compactionSettings = { model in PiConfig.compactionSettings(model: model, cwd: cwd, in: piDirectory) }
            // The queue did not go after all (pi refused it, or it paused): pi is idle, so the
            // agent is done even though its status report was held for the queue.
            thread.onIdleAfterQueue = { [weak serverWeak] in
                guard let server = serverWeak, let agentID = server.agentID(forSession: sid),
                      server.store.state.agents.first(where: { $0.id == agentID })?.status == .working else { return }
                server.applyAgentStatus(agentID: agentID, status: .done)
            }
            // Card actions go to the children extension's control channel, never the parent model.
            thread.dispatchSubagentCommand = { [weak serverWeak] runID, action, text, mode, done in
                guard let server = serverWeak, let agentID = server.agentID(forSession: sid) else { done("Agent is gone."); return }
                server.sendChildCommand(agentID: agentID, runID: runID, action: action, text: text, mode: mode, completion: done)
            }
            thread.onRevision = { [weak serverWeak] in serverWeak?.threadRevised(sessionID: sid) }
            thread.onQuestionChanged = { [weak serverWeak] question in
                guard let server = serverWeak, let agentID = server.agentID(forSession: sid) else { return }
                server.applyAgentQuestion(agentID: agentID, question: question?.title, reason: question?.reason)
            }
            thread.onToolFinished = { [weak serverWeak] name in
                guard let server = serverWeak, let agentID = server.agentID(forSession: sid) else { return }
                server.hopToMain { [weak server] in server?.onAgentToolFinished?(agentID, name) }
            }
            session.onEvent = { [weak thread] event in thread?.handle(event) }
            thread.onServable = { [weak serverWeak] in
                guard let server = serverWeak, server.sessions[sid] != nil else { return }
                server.unannouncedServable.insert(sid)
                server.announceServableThreads()
            }
            session.onStderr = { line in ShepherdLog.info("rpc session \(sid) stderr: \(line)") }
            session.onExit = { [weak serverWeak] code in
                serverWeak?.sessionDidExit(sid, code: code)
            }
            thread.onTurnEvent = { [weak serverWeak] event in
                guard let server = serverWeak, let agentID = server.agentID(forSession: sid) else { return }
                switch event {
                case .started: server.changes.turnStarted(agentID: agentID)
                case .message(let timestamp, let text): server.changes.turnMessage(agentID: agentID, timestamp: timestamp, text: text)
                case .settled: server.changes.turnSettled(agentID: agentID)
                }
            }
            sessions[sid] = .rpc(session, thread)
            session.start()
            sessionQueue.async { thread.bootstrap() }
            ShepherdLog.info("rpc session \(sid) created: \(session.command.joined(separator: " "))")
            return session.info
        }
        let sessionQueue = DispatchQueue(label: "shepherd.pty", target: queue)
        let session = try PTYSession(params: params, queue: sessionQueue)
        let sid = session.id
        session.onOutput = { [weak serverWeak] data in
            serverWeak?.deliverOutput(sessionID: sid, data: data)
        }
        session.onExit = { [weak serverWeak] code in
            serverWeak?.sessionDidExit(sid, code: code)
        }
        sessions[sid] = .pty(session)
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
        try await withCheckedThrowingContinuation { continuation in
            attachSnapshot(sessionID: sessionID, replay: replay) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Submit before returning, so a later detach cannot overtake this attach.
    /// Completion runs on the main queue, in order with output callbacks.
    public func attachSnapshot(
        sessionID: SessionID,
        replay: Bool,
        completion: @escaping @MainActor (Result<AttachmentSnapshot, Error>) -> Void
    ) {
        queue.async {
            let result = Result {
                guard let entry = self.sessions[sessionID] else {
                    throw SessionServerError.noSuchSession(sessionID)
                }
                guard let session = entry.pty else {
                    throw SessionServerError.noTerminal(sessionID)
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
            DispatchQueue.main.async { completion(result) }
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
                    self.sessions[sessionID]?.pty?.resumeOutputReading()
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
            guard let session = self.sessions[sessionID]?.pty, session.isAlive else { return }
            session.writeInput(data)
        }
    }

    /// Types `command` and Return into a fresh shell once its line editor reads, so the command
    /// shows once, at the prompt. Written sooner, the terminal echoes it as typeahead before the
    /// shell draws its prompt, and the line editor then shows it again. A shell with no line
    /// editor gets it after `timeout`. `submit` false leaves it typed at the prompt, not run (Run
    /// in terminal).
    public func typeCommand(_ command: String, sessionID: SessionID, submit: Bool = true, timeout: TimeInterval = 5) {
        let data = Data((submit ? command + "\n" : command).utf8)
        let deadline = DispatchTime.now() + timeout
        queue.async { self.typeWhenLineEditorReads(data, sessionID: sessionID, deadline: deadline) }
    }

    /// Server queue. Checks the terminal's mode every `lineEditorPoll` until the deadline.
    private func typeWhenLineEditorReads(_ data: Data, sessionID: SessionID, deadline: DispatchTime) {
        guard let session = sessions[sessionID]?.pty, session.isAlive else { return }
        guard session.lineEditorReading || DispatchTime.now() >= deadline else {
            queue.asyncAfter(deadline: .now() + Self.lineEditorPoll) { [weak self] in
                self?.typeWhenLineEditorReads(data, sessionID: sessionID, deadline: deadline)
            }
            return
        }
        session.writeInput(data)
    }

    private static let lineEditorPoll: DispatchTimeInterval = .milliseconds(20)

    /// Visible rows of a session's screen, trailing blank lines trimmed. Lets
    /// an agent read what a pane it opened has printed.
    /// Foreground process name of a session's PTY ("zsh", "pi", "htop"),
    /// for display. Nil for unknown sessions or dead children.
    public func foregroundProcessName(sessionID: SessionID) async -> String? {
        await enqueueValue { self.sessions[sessionID]?.pty?.foregroundProcessName }
    }

    /// Current working directory of the foreground process in a session's PTY.
    public func foregroundWorkingDirectory(sessionID: SessionID) async -> String? {
        await enqueueValue { self.sessions[sessionID]?.pty?.foregroundWorkingDirectory }
    }

    /// Foreground command line of a session's PTY ("pi --model x"), for
    /// shell restore. Nil at a bare prompt.
    public func foregroundCommandLine(sessionID: SessionID) async -> String? {
        await enqueueValue { self.sessions[sessionID]?.pty?.foregroundCommandLine }
    }

    /// What each terminal pane of an agent's layout runs now, and how far its output has got
    /// (the terminal panel's tab states, locally and over `RemoteAgentQuery.terminals`). The
    /// agent's own pi pane is never among them. Empty for an unknown agent.
    public func terminalActivity(agentID: AgentID) async -> [RemoteTerminalActivity] {
        await enqueueValue { self.terminalActivity(of: agentID) ?? [] }
    }

    /// Server queue. Nil when the agent or its layout is gone.
    private func terminalActivity(of agentID: AgentID) -> [RemoteTerminalActivity]? {
        guard let agent = store.state.agents.first(where: { $0.id == agentID }),
              let tab = store.state.tabs.first(where: { $0.id == agent.tabID }) else { return nil }
        return tab.layout.leaves.compactMap { leaf in
            guard leaf.id != agent.paneID, leaf.agentID == nil, let sessionID = leaf.sessionID,
                  let pty = sessions[sessionID]?.pty else { return nil }
            // A login shell's argv[0] is "-zsh": the program is "zsh".
            let process = pty.foregroundProcessName.map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
            return RemoteTerminalActivity(paneID: leaf.id, sessionID: sessionID, process: process,
                                          command: pty.runningCommandLine,
                                          outputSequence: outputStates[sessionID]?.outputSequence ?? 0,
                                          newsSequence: outputStates[sessionID]?.news.sequence ?? 0)
        }
    }

    public func screenText(sessionID: SessionID) async -> [String]? {
        await enqueueValue {
            guard let session = self.sessions[sessionID]?.pty else { return nil }
            var lines = session.screen.visibleText()
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            return lines
        }
    }

    public func resize(sessionID: SessionID, cols: Int, rows: Int) {
        queue.async {
            guard let session = self.sessions[sessionID]?.pty else { return }
            self.resizePTY(session, sessionID: sessionID, cols: cols, rows: rows)
        }
    }

    /// Kills the command running in a session's terminal (Kill process), leaving its shell.
    /// False when nothing but the shell has the terminal, or the session is gone.
    @discardableResult
    public func killForegroundCommand(sessionID: SessionID) async -> Bool {
        await enqueueValue { self.sessions[sessionID]?.pty?.killForegroundCommand() ?? false }
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
            if session.thread != nil { self.retiredRPCSessions.updateValue(session.exitCode, forKey: sessionID) }
            self.unannouncedServable.remove(sessionID)
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
        output.news.output(at: .now)
        // Remote streaming happens on the server queue in delivery order and
        // is independent of the GUI's attach state — a headless host has no
        // GUI viewer, and the remote client must still receive output.
        streamToRemoteClients(sessionID: sessionID, data: data)
        guard attachedSessions.contains(sessionID),
              let session = sessions[sessionID]?.pty else { return }

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
            sessions[sessionID]?.pty?.resumeOutputReading()
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

    /// Tests only: parks a block on the server queue until `release` is signalled, and returns
    /// once the queue is held. Never call it from the server queue.
    func holdQueue(until release: DispatchSemaphore) async {
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            queue.async {
                held.resume()
                release.wait()
            }
        }
    }

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

    /// Server queue: the agent whose own pane runs this session. Streaming asks on every
    /// revision, so the lookup is rebuilt once per committed state rather than scanned.
    private func agentID(forSession sessionID: SessionID) -> AgentID? {
        if sessionAgents?.version != store.version {
            let tabs = Dictionary(store.state.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var agents: [SessionID: AgentID] = [:]
            for agent in store.state.agents {
                guard let paneID = agent.paneID,
                      let bound = tabs[agent.tabID]?.layout.leaf(withID: paneID)?.sessionID,
                      agents[bound] == nil else { continue }
                agents[bound] = agent.id
            }
            sessionAgents = (store.version, agents)
        }
        return sessionAgents?.agents[sessionID]
    }

    /// Server queue: tell the app a watched agent's thread revised, coalescing everything up to a
    /// frame after the last delivery into one hop. The delivery is a hint to pull, so unlike
    /// `hopToMain` it need not keep its place among the other callbacks.
    private func threadRevised(sessionID: SessionID) {
        guard let agentID = agentID(forSession: sessionID), let deadline = revisedThreads.insert(agentID) else { return }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            for agentID in self.revisedThreads.drain() {
                self.onThreadRevision?(agentID)
            }
        }
    }

    /// The agents whose revisions `onThreadRevision` reports: the app's threads on screen (their
    /// stores' poll loops run). Replaces the last set; none are watched until the app says.
    public func watchThreadRevisions(of agentIDs: Set<AgentID>) {
        revisedThreads.watch(agentIDs)
    }

    /// The designs whose revisions `onDesignRevision` reports: the app's designs on screen.
    /// Replaces the last set; none are watched until the app says.
    public func watchDesignRevisions(of designIDs: Set<DesignID>) {
        revisedDesigns.watch(designIDs)
    }

    /// Server queue: tell the app a watched design's files changed, paced like a thread's
    /// revisions.
    private func designRevised(_ designID: DesignID) {
        guard let deadline = revisedDesigns.insert(designID) else { return }
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            for designID in self.revisedDesigns.drain() {
                self.onDesignRevision?(designID)
            }
        }
    }

    /// Server queue: the RPC thread state behind an agent's pane, if it is an RPC agent.
    private func rpcThread(forAgent agentID: AgentID) -> RPCThreadState? {
        guard let agent = store.state.agents.first(where: { $0.id == agentID }),
              let tab = store.state.tabs.first(where: { $0.id == agent.tabID }),
              let paneID = agent.paneID, let sessionID = tab.layout.leaf(withID: paneID)?.sessionID else { return nil }
        return sessions[sessionID]?.thread
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

    /// The `sockaddr_un` for `path`, rejecting paths longer than `sun_path` allows. Public for
    /// clients of the extension socket (and the test support module).
    public static func socketAddress(for path: String) throws -> sockaddr_un {
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

// MARK: - Changes

/// A value handed across a `@Sendable` boundary and used only back on the queue that owns it.
private struct ChangesUnchecked<Value>: @unchecked Sendable {
    let value: Value
}

extension SessionServer {
    /// Server queue, from the committed state: the agent's thread pane directory and branch base.
    fileprivate static func changesContext(_ state: ShepherdState, _ agentID: AgentID) -> ChangesService.AgentContext? {
        guard let agent = state.agents.first(where: { $0.id == agentID }),
              let tab = state.tabs.first(where: { $0.id == agent.tabID }) else { return nil }
        let cwd = agent.paneID.flatMap { tab.layout.leaf(withID: $0)?.cwd } ?? tab.layout.firstLeaf.cwd
        return ChangesService.AgentContext(cwd: cwd, worktreeBase: agent.worktreeBase,
                                           isWorktree: agent.worktreePath != nil || agent.worktreeBranch != nil)
    }

    fileprivate func installChanges() {
        changes.agentContext = { [weak self] agentID in
            guard let self else { return nil }
            return Self.changesContext(self.state, agentID)
        }
        changes.onTurnsChanged = { [weak self] agentID, turns in
            self?.queue.async { self?.setTurnChanges(turns, for: agentID) }
        }
    }

    /// Server queue: hands an agent's turns to its thread, whose next snapshot carries them.
    fileprivate func setTurnChanges(_ turns: [ChangesTurn], for agentID: AgentID) {
        guard let agent = store.state.agents.first(where: { $0.id == agentID }),
              let tab = store.state.tabs.first(where: { $0.id == agent.tabID }),
              let paneID = agent.paneID, let sessionID = tab.layout.leaf(withID: paneID)?.sessionID,
              let thread = sessions[sessionID]?.thread else { return }
        thread.setTurnChanges(turns)
    }
}
