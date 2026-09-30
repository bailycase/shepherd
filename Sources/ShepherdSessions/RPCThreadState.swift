import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The native-thread view of one `RPCSession`, fed by pi's event stream: projection rules,
/// limits, error codes, and operation idempotency behind `SessionServer.nativeThread`, served
/// alike to the desktop, remote, and iOS clients. Confined to the session queue (which targets
/// the server queue). The queue of messages sent while pi works lives here too
/// (`RPCThreadState+Queue.swift`).
final class RPCThreadState {
    static let textLimit = 16 * 1024
    static let snapshotLimit = 240 * 1024
    static let activeLimit = 120 * 1024
    static let pageSize = 50
    static let dialogLimit = 8
    static let dialogBytes = 48 * 1024
    /// UI_LIMITS in the extension.
    static let widgetItems = 16
    static let widgetTextBytes = 4096
    static let widgetTitleBytes = 256
    static let widgetAggregateBytes = 32 * 1024
    static let operationTableSize = 256
    static let supportedActions = ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents", "queue", "compact", "designContext",
                                   "designReferences", "browserElements", "retry", "interrupt", "setServiceTier"]
    /// pi answers `compact` only once the summary is written, which takes as long as a reply.
    static let compactTimeout: TimeInterval = 600
    /// Bytes of a child session file the transcript reader will scan (tail); older is unreachable.
    static let transcriptReadLimit = 8 * 1024 * 1024
    /// Beside a native child's session: one `{"text","at"}` line per message the user sent it
    /// (the children extension's `messageChild`), so its transcript tells them from the parent's.
    static let userMessagesFile = "user-messages.jsonl"
    static let userMessagesReadLimit = 1024 * 1024
    /// pi answers a prompt only once its preflight is done: input handlers, a compaction after
    /// an aborted run, image processing, or an extension command running to its end.
    static let promptTimeout: TimeInterval = 30

    /// One row of the run pi is streaming, in the order pi produced it: its assistant messages,
    /// tool calls, the user messages it read, and prompts it has not read yet (pending).
    struct LiveItem {
        enum Kind: Equatable {
            case assistant(Int)
            case tool(String)
            case user
            case pending(UUID)
            /// A compaction pi is running, or one that stopped or failed (`NativeCompaction`).
            case compaction(String)
            /// A question pi asked, once it ended (`NativeQuestionRecord`), by its dialog id.
            case question(String)
        }
        var kind: Kind
        /// Assigning it forgets its hash and size, so a commit rehashes only the rows that changed.
        var value: NativeThreadMessage {
            didSet {
                hash = nil
                bytes = nil
            }
        }
        var raw: RPCMessage?
        var ended: Bool
        /// `value`'s hash, taken by the first commit after it was assigned.
        var hash: Int? = nil
        /// `value`'s encoded size, taken by the first snapshot that shows it.
        var bytes: Int? = nil
    }

    private struct Operation {
        let fingerprint: NativeThreadRequest
        var result: NativeThreadResult?
        var waiters: [(NativeThreadResult) -> Void] = []
    }

    let session: RPCSession
    let queue: DispatchQueue
    private(set) var piSessionID: String?
    /// How many times the bootstrap has asked pi for its state (more than once: a slow start).
    private(set) var bootstrapAttempts = 0
    /// The bootstrap's `get_messages` has not answered. pi answers it after `get_state`, and a
    /// long history takes a moment to arrive: served meanwhile, a resumed thread would show
    /// as a new, empty one.
    private var historyPending = true
    /// Installed by SessionServer: called once, on the session queue, when the thread first
    /// serves (pi has answered `get_state` and `get_messages`).
    var onServable: (() -> Void)?
    private var announcedServable = false
    /// A new agent's opening prompt, held until the thread serves (`sendOpeningPrompt`).
    typealias OpeningPrompt = (text: String, images: [NativeImage], id: UUID)
    private var openingPrompt: OpeningPrompt?
    /// The opening prompt pi never read (it stopped before the thread served).
    var unreadOpeningPrompt: OpeningPrompt? { openingPrompt }
    /// Requests get a snapshot rather than `native_starting`.
    var isServable: Bool { piSessionID != nil && !historyPending }
    private(set) var generation = UUID().uuidString
    private(set) var revision: UInt64 = 0
    /// Called on the session queue each time `revision` moves.
    var onRevision: (() -> Void)?
    /// Called on the session queue when pi finishes a tool call, with the tool's name.
    var onToolFinished: ((String) -> Void)?
    private var signature = 0
    /// From `agent_start` until `agent_settled`: pi's own `isStreaming`. A run's `agent_end` is not
    /// its end: pi may retry, compact, or continue before it settles, and until then a prompt
    /// needs a streaming behavior.
    private(set) var running = false
    private(set) var model: String?
    private(set) var thinking: String?
    /// The levels pi offers `model` (`get_available_thinking_levels`); nil until pi answers, or
    /// from a pi without the command.
    private(set) var thinkingLevels: [String]?
    /// The agent's service tier as the host keeps it (`Agent.serviceTier`): the server sets it
    /// whenever its state changes, and the snapshot shows it beside `serviceTiers`.
    var serviceTier: ServiceTier = .standard {
        didSet { if serviceTier != oldValue { commit() } }
    }
    /// The tiers `model` offers (`ServiceTierSupport`), Standard first, none when it takes no tier:
    /// worked out from what pi's `get_state` says the model is, so it follows every model change.
    private(set) var serviceTiers: [ServiceTier] = []
    /// Installed by SessionServer: the tiers a model offers, which also knows a CLIProxyAPI model's
    /// owner (from a cached read of its connection file).
    var serviceTierOffer: (ServiceTierModel) -> [ServiceTier] = { ServiceTierSupport.tiers(for: $0) }
    /// Installed by SessionServer: changes the agent's tier (persisted, its file written, every
    /// client told), answering nil or why it couldn't.
    var applyServiceTier: ((ServiceTier, @escaping (String?) -> Void) -> Void)?
    private(set) var stats: NativeThreadStats?
    /// pi's `autoCompactionEnabled` (get_state).
    private(set) var autoCompaction: Bool?
    /// The host's estimate of pi's context, from its messages; refreshed with history.
    var estimate: ContextEstimate?
    /// A compaction pi is running (`compaction_start` until `compaction_end`).
    var compactingRun: NativeCompactionRun?
    /// Compactions this host saw finish, by the summary pi wrote: why, and pi's estimate after.
    var compactionNotes: [CompactionNote] = []
    /// Installed by SessionServer: pi's compaction settings for a model ("provider/id"), read
    /// from pi's settings files (never written).
    var compactionSettings: (String?) -> PiCompactionSettings = { _ in PiCompactionSettings() }
    /// The settings for `settingsModel`, read once per model.
    var settingsFor: (model: String?, value: PiCompactionSettings)?
    /// What the snapshot's `context` shows, rebuilt whenever a part of it changes.
    var context: NativeThreadContext?
    // A commit combines hashes taken when each part was assigned (the lists here, each
    // provisional and tool entry), so a streamed delta rehashes only the message it grew.
    private(set) var commands: [NativeCommand]? { didSet { commandsHash = commands.hashValue } }
    /// Native child runs as last published by the children extension over the socket.
    private(set) var subagents: [NativeSubagent] = [] { didSet { subagentsHash = subagents.hashValue } }
    private var commandsHash = Optional<[NativeCommand]>.none.hashValue
    private var subagentsHash = [NativeSubagent]().hashValue
    private var dialogsHash = [NativeThreadDialog]().hashValue
    private var widgetsHash = [NativeThreadWidget]().hashValue
    /// The queue as the last commit hashed it, and that hash. The queue is derived state (items,
    /// mode, pause), so a commit compares it, which is cheap while its texts are the ones it
    /// hashed, and rehashes it only when it changed.
    private var hashedQueue: NativeQueue?
    private var queueHashValue = 0
    /// The queue as the last snapshot sized it, and its encoded size: a snapshot re-encodes the
    /// queue only when it changed.
    private var sizedQueue: NativeQueue?
    private var queueBytesValue = 0
    #if DEBUG
    /// Tests: text bytes of the entries rehashed since the last commit, and by the last commit.
    private var bytesHashedSinceCommit = 0
    private(set) var bytesHashedByLastCommit = 0
    /// Tests: JSON encodes the last snapshot made, and its size by arithmetic.
    private var encodesSinceSnapshot = 0
    private(set) var encodesByLastSnapshot = 0
    /// Tests: JSON bytes those encodes produced.
    private var bytesEncodedSinceSnapshot = 0
    private(set) var bytesEncodedByLastSnapshot = 0
    private(set) var bytesOfLastSnapshot = 0
    #endif
    /// Installed by SessionServer: writes a childCommand to the children extension and answers
    /// with its error text (nil on success). Runs on the server queue.
    var dispatchSubagentCommand: ((String, NativeSubagentAction, String?, NativeThreadDelivery?, @escaping (String?) -> Void) -> Void)?
    private(set) var history: [NativeThreadMessage] = [] { didSet { historyBytes = Array(repeating: -1, count: history.count) } }
    /// Each history row's encoded size, taken by the first snapshot that shows it (-1 until then).
    private var historyBytes: [Int] = []
    /// Bumped whenever a refresh changes history, so a same-length change (a compaction) is a
    /// new revision.
    private var historyVersion = 0
    var live: [LiveItem] = []
    private var sequence = 0
    private var currentAssistant: Int?
    /// When each tool call was first seen (ms): named by the model, else running. Its clock, for
    /// live calls and for the duration history keeps.
    private var toolStarts: [String: Double] = [:]
    /// The calls the model is writing now, by call id: their arguments as far as they streamed.
    private var streamingCalls: [String: StreamingToolArguments] = [:]
    /// Live thinking spans per provisional assistant message (ms), and the finished ones keyed
    /// by the message's pi timestamp so history projected later keeps "Thought for Ns".
    private var thinkingSpans: [Int: (start: Double, end: Double?)] = [:]
    private var thinkingByTimestamp: [Double: Double] = [:]
    private(set) var dialogs: [NativeThreadDialog] = [] {
        didSet {
            dialogsHash = dialogs.hashValue
            dialogBytes = nil
            if dialogReasons.count > dialogs.count {
                let open = Set(dialogs.map(\.id))
                dialogReasons = dialogReasons.filter { open.contains($0.key) }
            }
            let question = Self.question(in: dialogs, reasons: dialogReasons)
            if question != askedQuestion {
                askedQuestion = question
                onQuestionChanged?(question)
            }
        }
    }
    /// Called on the session queue when the question the thread asks first changes (nil once
    /// none is open): the sidebar's Needs you says why without reading the thread.
    var onQuestionChanged: ((AgentQuestion?) -> Void)?
    private var askedQuestion: AgentQuestion?
    /// The short reason of each open dialog an asking tool opened, by dialog id.
    private var dialogReasons: [String: String] = [:]
    /// Asking tools running now and the short reason each gave (nil for none), oldest first.
    private var askingCalls: [(id: String, reason: String?)] = []

    /// What the thread asks first: a question's title, and the agent's word or two for it
    /// ("retention?") when its asking tool gave one.
    struct AgentQuestion: Equatable {
        var title: String
        var reason: String?
    }

    /// The first open question with a title, trimmed; nil when none has one.
    static func question(in dialogs: [NativeThreadDialog], reasons: [String: String] = [:]) -> AgentQuestion? {
        for dialog in dialogs {
            let title = dialog.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return AgentQuestion(title: title, reason: reasons[dialog.id]) }
        }
        return nil
    }

    /// Whether a tool waits on the user, by name: the status extension's rule (`ask_user`,
    /// `question`), which also gives such tools the `short` parameter.
    static func asksUser(_ toolName: String) -> Bool {
        toolName.contains(#/(?i)(?:^|[^a-z0-9])(?:ask|question)(?:[^a-z0-9]|$)/#)
    }

    /// Longest short reason kept; the sidebar shows far less.
    static let shortReasonLimit = 120

    /// An asking call's `short` argument as one trimmed line, or nil when it gave none.
    static func shortReason(in args: JSONValue?) -> String? {
        guard case .object(let fields) = args, case .string(let text) = fields["short"] else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(shortReasonLimit))
    }
    private var dialogBytes: [Int]?
    private var widgets: [(id: String, value: NativeThreadWidget)] = [] { didSet { widgetsHash = widgets.map(\.value).hashValue } }
    private var operations: [(id: String, operation: Operation)] = []
    var projectionClipped = false
    /// The last assistant message of the current run ended in a provider error.
    var runFailed = false
    /// That error's message, when pi gave one.
    private var runError: String?
    /// The user stopped this run: pi ends a run stopped mid-tool-call with an error reply,
    /// which is not a turn that failed.
    var stopRequested = false
    /// What a Stop ended, which projects as `aborted` rather than as a failure: tool calls that
    /// failed as it aborted them, and the error replies pi ended those runs with (by pi's
    /// timestamp).
    private var stoppedCalls: Set<String> = []
    private var stoppedReplies: Set<Double> = []

    // Queue state (RPCThreadState+Queue.swift).
    var items: [QueueItem] = []
    var dispatches: [Dispatch] = []
    /// A Retry on its way (`RPCThreadState+Retry.swift`): its dispatch, until the run it starts
    /// does (or pi says it started none).
    var retryDispatch: UUID?
    /// What waits for the settled turn's capture to end (a Retry sent just as pi settled).
    var afterSettleCapture: [() -> Void] = []
    var paused = false
    var queueNotice: String?
    var modeOverride: NativeQueueMode?
    /// The host's default for agents with no choice of their own (Settings).
    var defaultQueueMode: NativeQueueMode = .all {
        didSet { if defaultQueueMode != oldValue { commit() } }
    }
    /// Steering items sent to pi whose queued text pi has not reported yet (`queue_update`).
    var unboundSteers: [UUID] = []
    /// Steering prompts pi has not answered; a settle waits for them (`settled()`).
    var steersInFlight = 0
    var settleAwaitingSteers = false
    /// pi's own queue as its last `queue_update` had it.
    var piSteering: [String] = []
    var piFollowUp: [String] = []
    /// What a delete or a clear removed, for an undo.
    var deleted: [(item: QueueItem, index: Int)] = []
    /// Copies a send is granting that have not reached this thread yet: the server marks them in
    /// the queue turn that grants them, and `send` clears them once the message is pi's or waits
    /// in the queue (`withheldDesignPayloads`).
    var sendingDesignPayloads: Set<UUID> = []

    /// Copies the thread was granted but pi has not read: a send still on its way here, or a
    /// message waiting in the queue (steering ones included) that the user may still take back.
    /// design_get and design_note answer from none of them.
    var withheldDesignPayloads: Set<UUID> {
        sendingDesignPayloads.union(items.flatMap(\.designPayloads))
    }

    /// Installed by SessionServer: the queue was expected to go when pi settled, and did not.
    var onIdleAfterQueue: (() -> Void)?
    /// Installed by SessionServer: queued messages carrying design references were deleted
    /// before pi read them, and these copies go with them. Called on the session queue.
    var onDesignPayloadsWithdrawn: (([UUID]) -> Void)?
    /// Installed by SessionServer: where a turn starts and ends, for the Changes engine's
    /// snapshots of the working tree (`ChangesService`). Called on the session queue.
    var onTurnEvent: ((TurnEvent) -> Void)?
    /// Asynchronous filesystem boundaries; completions return to this thread's queue.
    var beforePrompt: ((@escaping () -> Void) -> Void)?
    var captureSettledTurn: ((@escaping () -> Void) -> Void)?
    var discardPreparedTurn: (() -> Void)?
    var settleCapture: UUID?
    var preparingPrompts: [UUID: (NativeThreadResult) -> Void] = [:]
    var sendAfterCapture: [UUID]?
    /// Messages an interrupt (`NativeThreadDelivery.interrupt`) is stopping pi for, first in the
    /// queue and sent the moment pi is idle (`RPCThreadState+Interrupt.swift`).
    var interrupting: [UUID]?
    /// The interrupt's `abort` is on its way to pi: pi answers it only once the run has settled,
    /// and the messages wait for that answer (a prompt written before pi finished aborting could
    /// be queued behind the run it ends and never run).
    var interruptAbortPending = false
    /// The agent's recorded turns, as the server last set them (`setTurnChanges`).
    private(set) var turnChanges: [ChangesTurn]? { didSet { turnChangesHash = turnChanges.hashValue } }
    private var turnChangesHash = Optional<[ChangesTurn]>.none.hashValue
    /// Whether the server has set them since the thread started.
    private(set) var turnChangesSet = false
    /// The server held back a "done" report because the queue was about to go.
    var doneHeld = false
    /// pi is retrying a failed request (`auto_retry_start` until `auto_retry_end`).
    private(set) var retry: NativeThreadRetry?

    /// Where messages Shepherd delivered came from, by entry id (persisted per pi session).
    let originStore: ThreadOriginStore?
    var origins: [String: ThreadOriginStore.Record] = [:]
    /// Entry ids in `origins`, oldest first.
    var originOrder: [String] = []
    /// The send behind each user message this host delivered, by entry id (this run only).
    var operationsByEntry: [String: UUID] = [:]
    /// When each open dialog arrived (ms), by its id.
    var askedAt: [String: Double] = [:]
    /// The questions pi asked in this session and how they ended, oldest first (persisted with
    /// the origins, `RPCThreadState+Questions.swift`).
    var questions: [ThreadOriginStore.Question] = []

    private static let encoder = JSONEncoder()
    private static let queueFieldBytes = #","queue":"#.utf8.count
    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])"
    )

    init(session: RPCSession, queue: DispatchQueue, originStore: ThreadOriginStore? = nil) {
        self.session = session
        self.queue = queue
        self.originStore = originStore
    }

    /// Populate from a freshly spawned (or resumed) pi. Until `get_state` and `get_messages`
    /// answer, requests are answered `native_starting`. pi reads its stdin only once it has
    /// started, so a pi slower than `timeout` answers requests that already timed out (and are
    /// dropped): ask again.
    func bootstrap(timeout: TimeInterval = 10) {
        bootstrapAttempts += 1
        let attempt = bootstrapAttempts
        let generation = generation
        refreshState(timeout: timeout) { [weak self] result in
            guard let self, self.piSessionID == nil, case .failure(.timeout) = result, self.session.isAlive else { return }
            ShepherdLog.info("rpc session \(self.session.id) has not started within \(timeout)s; asking again")
            self.bootstrap(timeout: timeout)
        }
        refreshMessages(timeout: timeout) { [weak self] _ in
            // Loaded or not (a history over the record cap never arrives), the thread serves now;
            // an attempt the bootstrap has since repeated waits for the repeat.
            guard let self, attempt == self.bootstrapAttempts, generation == self.generation else { return }
            self.historyPending = false
            self.announceIfServable()
        }
        refreshStats(timeout: timeout)
        session.request(.getCommands, timeout: timeout) { [weak self] result in
            guard let self, case .success(let response) = result, response.success else { return }
            let listed = response.data?["commands"]
            self.commands = Self.projectCommands(listed)
            self.commit()
            self.readArgumentHints(Self.promptTemplateFiles(listed))
        }
    }

    // MARK: - Events (session queue)

    func handle(_ event: RPCEvent) {
        switch event {
        case .agentStart:
            retryStarted()
            // A compaction that stopped or failed says so until the next run.
            live.removeAll { if case .compaction = $0.kind { $0.value.compaction?.phase != .running } else { false } }
            // A retry's second start is the same turn; the engine tells them apart.
            onTurnEvent?(.started)
            running = true
            runFailed = false
            runError = nil
            stopRequested = false
            settleAwaitingSteers = false
            doneHeld = false
            if !items.isEmpty { onUserInputWhileRunning?() }
        case .agentEnd:
            dropStreamingCalls()
            refreshMessages()
            refreshState()
            refreshStats()
        case .agentSettled:
            running = false
            retry = nil
            dropStreamingCalls()
            askingCalls.removeAll()
            let token = UUID()
            settleCapture = token
            if let captureSettledTurn {
                captureSettledTurn { [weak self] in
                    guard let self, self.settleCapture == token else { return }
                    self.settleCapture = nil
                    self.runAfterSettleCapture()
                    self.drainIfReady()
                    self.idleAfterQueue()
                }
            } else {
                onTurnEvent?(.settled)
                settleCapture = nil
            }
            settled()
        case .messageStart(let message) where message.role == "user":
            onTurnEvent?(.message(timestamp: message.timestamp, text: DesignViewRecord.strippingFence(from: message.content.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined())))
            userMessageStarted(message)
        case .messageEnd(let message) where message.role == "user":
            userMessageEnded(message)
        case .messageStart(let message):
            guard message.role == "assistant" else { break }
            sequence += 1
            currentAssistant = sequence
            upsertAssistant(message, ended: false)
        case .messageUpdate(let delta):
            guard let key = currentAssistant, let index = live.firstIndex(where: { $0.kind == .assistant(key) }), let current = live[index].raw else {
                // message_start was missed (spawned mid-turn); start accumulating now.
                sequence += 1
                currentAssistant = sequence
                var raw = RPCMessage(role: "assistant", content: [])
                Self.apply(delta, to: &raw)
                upsertAssistant(raw, ended: false)
                streamToolCall(delta, in: raw)
                break
            }
            // A call's argument fragments change nothing the reply shows, only the call's row.
            if delta.type == "toolcall_delta" {
                streamToolCall(delta, in: current)
                break
            }
            var raw = current
            Self.apply(delta, to: &raw)
            upsertAssistant(raw, ended: false)
            streamToolCall(delta, in: raw)
        case .messageEnd(let message):
            guard message.role == "assistant" else { break }
            if currentAssistant == nil {
                sequence += 1
                currentAssistant = sequence
            }
            runFailed = message.stopReason == "error"
            runError = runFailed ? message.errorMessage : nil
            var ended = message
            if runFailed, stopRequested {
                ended.stopReason = "aborted"
                if let time = message.timestamp { stoppedReplies.insert(time) }
            }
            upsertAssistant(ended, ended: true)
            currentAssistant = nil
            // A reply pi stopped, or that failed, runs none of its calls: those still being
            // written leave the thread. Any other hands them to pi, and each execution continues
            // its row.
            let runs = ended.stopReason != "error" && ended.stopReason != "aborted"
            dropStreamingCalls(keeping: runs ? Set(ended.content.compactMap { block -> String? in
                if case .toolCall(let id, _, _) = block { return id }
                return nil
            }) : [])
            // The ring moves once per reply, never per token.
            refreshStats()
        case .toolExecutionStart(let id, let name, let args):
            if Self.asksUser(name) {
                askingCalls.removeAll { $0.id == id }
                askingCalls.append((id, Self.shortReason(in: args)))
            }
            streamingCalls[id] = nil
            upsertTool(id: id, name: name, args: args, content: [], isError: nil, status: "running")
        case .toolExecutionUpdate(let id, let name, let args, let partial):
            upsertTool(id: id, name: name, args: args, content: partial?.content ?? [], isError: nil, status: "running")
        case .toolExecutionEnd(let id, let name, let result, let isError):
            let stopped = isError && stopRequested
            if stopped { stoppedCalls.insert(id) }
            askingCalls.removeAll { $0.id == id }
            upsertTool(id: id, name: name, args: nil, content: result?.content ?? [], isError: isError, status: stopped ? "aborted" : "complete")
            onToolFinished?(name)
        case .queueUpdate(let steering, let followUp):
            piQueueChanged(steering: steering, followUp: followUp)
        case .extensionUIRequest(let request):
            handleUIRequest(request)
        case .extensionError(let path, let event, let error):
            ShepherdLog.warning("rpc session \(session.id) extension error in \(path ?? "?") (\(event ?? "?")): \(error)")
        case .compactionStart(let reason):
            compactionStarted(reason: NativeCompactionReason(pi: reason))
        case .compactionEnd(let reason, let result, let aborted, let willRetry, let error):
            compactionEnded(reason: NativeCompactionReason(pi: reason), result: result, aborted: aborted, willRetry: willRetry, error: error)
        case .autoRetryStart(let attempt, let maxAttempts, let delayMs, _):
            retry = NativeThreadRetry(attempt: attempt, maxAttempts: maxAttempts,
                                      retryAt: (Date().timeIntervalSince1970 * 1000 + max(0, delayMs)).rounded())
        case .autoRetryEnd:
            retry = nil
        case .turnStart, .turnEnd, .unknown:
            break
        }
        commit()
    }

    /// The run ended in a provider error the user did not cause by stopping it.
    var turnFailure: TurnFailure? {
        runFailed && !stopRequested ? TurnFailure(message: runError) : nil
    }

    /// Server queue: full replacement from a setAgentChildren publish.
    func setSubagents(_ rows: [ChildRun]) {
        subagents = rows
        commit()
    }

    /// Server queue: the agent's turns as the Changes engine recorded them.
    func setTurnChanges(_ turns: [ChangesTurn]?) {
        turnChangesSet = true
        let turns = turns?.isEmpty == true ? nil : turns
        guard turns != turnChanges else { return }
        turnChanges = turns
        commit()
    }

    // MARK: - Requests (server queue)

    /// `olderClient`: the request came from a remote client that does not read the host's queue
    /// (its `hello` listed no `native.queue.v1`); its queued sends go to pi alone.
    func handle(_ request: NativeThreadRequest, olderClient: Bool = false, completion: @escaping (NativeThreadResult) -> Void) {
        guard let piSessionID, !historyPending else {
            completion(.failure(code: NativeThreadCode.starting, message: "The agent is starting."))
            return
        }
        commit()
        switch request {
        case .snapshot(let expectedSessionID, let beforeEntryID, let afterRevision):
            if let expectedSessionID, expectedSessionID != piSessionID {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            if beforeEntryID == nil, afterRevision == revision {
                completion(.unchanged(piSessionID: piSessionID, generation: generation, revision: revision))
                return
            }
            completion(snapshot(beforeEntryID: beforeEntryID))
        case .subagentTranscript(let expectedSessionID, let runID, let beforeEntryID):
            guard expectedSessionID == piSessionID else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            guard let run = subagents.first(where: { $0.runID == runID }), let file = run.sessionFile else {
                completion(.failure(code: "unknown_run", message: "That subagent is no longer listed."))
                return
            }
            completion(Self.transcript(runID: runID, file: file, beforeEntryID: beforeEntryID))
        case .send(let expectedSessionID, let generation, let operationID, _, _, _, _, _, _),
             .abort(let expectedSessionID, let generation, let operationID),
             .answer(let expectedSessionID, let generation, let operationID, _, _),
             .setModel(let expectedSessionID, let generation, let operationID, _),
             .setThinking(let expectedSessionID, let generation, let operationID, _),
             .subagentCommand(let expectedSessionID, let generation, let operationID, _, _, _, _),
             .queue(let expectedSessionID, let generation, let operationID, _),
             .compact(let expectedSessionID, let generation, let operationID, _),
             .retry(let expectedSessionID, let generation, let operationID, _),
             .setServiceTier(let expectedSessionID, let generation, let operationID, _):
            guard expectedSessionID == piSessionID, generation == self.generation else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            let key = operationID.uuidString.uppercased()
            if let index = operations.firstIndex(where: { $0.id == key }) {
                guard operations[index].operation.fingerprint == request else {
                    completion(.failure(code: "operation_conflict", message: "Operation ID was reused with a different payload."))
                    return
                }
                if let result = operations[index].operation.result {
                    completion(result)
                } else {
                    operations[index].operation.waiters.append(completion)
                }
                return
            }
            operations.append((key, Operation(fingerprint: request)))
            if operations.count > Self.operationTableSize { operations.removeFirst() }
            perform(request, operationID: operationID, olderClient: olderClient) { [weak self] result in
                guard let self else { completion(result); return }
                guard let index = self.operations.firstIndex(where: { $0.id == key }) else {
                    // Evicted while in flight; still answer this caller.
                    completion(result)
                    return
                }
                self.operations[index].operation.result = result
                let waiters = self.operations[index].operation.waiters
                self.operations[index].operation.waiters = []
                // One revision: the change the action made, or the answer alone.
                let revision = self.revision
                self.commit()
                if self.revision == revision { self.bumpRevision() }
                completion(result)
                waiters.forEach { $0(result) }
            }
        }
    }

    static func dispatchFailure(_ result: Result<RPCResponse, RPCError>) -> NativeThreadResult? {
        switch result {
        case .success(let response) where response.success:
            return nil
        case .success(let response):
            return .failure(code: "dispatch_failed", message: response.error.map { "The agent refused it: \($0)" } ?? "The agent refused it.")
        case .failure(.timeout):
            return .failure(code: "outcome_unknown", message: "The agent did not answer in time. Check the thread before trying again; nothing will be resent automatically.")
        case .failure(let error):
            return .failure(code: "dispatch_failed", message: error.description)
        }
    }

    /// The fence a send puts ahead of its words: its references', else its design view record's.
    /// References go only to an ordinary thread and a view record only to a design's chat, so one
    /// send never carries both; if one did, the view record is dropped, since every display
    /// surface takes off only the one fence a message starts with.
    /// A browser elements fence follows the design one, so a message's words come last.
    static func sendContext(_ designContext: NativeDesignContext?, references: [DesignReferenceRecord]?,
                            elements: [BrowserElement]? = nil) -> String? {
        let design = references.flatMap { DesignReferenceFence.fenced($0) } ?? designContext?.valid?.fenced()
        let browser = elements.flatMap { BrowserElementFence.fenced($0) }
        guard design != nil || browser != nil else { return nil }
        return (design ?? "") + (browser ?? "")
    }

    /// An accepted new user send during a running turn. Idempotent operation replay never fires it.
    var onUserInputWhileRunning: (() -> Void)?

    private func perform(_ request: NativeThreadRequest, operationID: UUID, olderClient: Bool, completion: @escaping (NativeThreadResult) -> Void) {
        let accepted = NativeThreadResult.accepted(operationID: operationID)
        let settle: (Result<RPCResponse, RPCError>) -> Void = { result in
            completion(Self.dispatchFailure(result) ?? accepted)
        }
        switch request {
        case .send(_, _, _, let text, let delivery, let images, let designContext, let designReferences, let browserElements):
            let images = images ?? []
            let elements = Array((browserElements ?? []).prefix(BrowserElement.maxPerMessage)).map(\.clamped)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty,
                  text.utf8.count <= Self.textLimit else {
                completion(.failure(code: "invalid", message: "Send requires text or images, with text up to 16 KiB."))
                return
            }
            guard NativeImage.fitOneSend(images) else {
                completion(.failure(code: "invalid", message: "Send accepts up to \(NativeImage.maxPerSend) images of \(NativeImage.maxBytes / 1024 / 1024) MiB each."))
                return
            }
            // A record that breaks the grammar is dropped whole; the message still goes. Design
            // references reach here only as the server read them (`SessionServer.nativeThread`).
            let context = Self.sendContext(designContext, references: designReferences, elements: elements)
            let interruptsBackgroundWait = running && delivery == .followUp
            send(id: operationID, text: text, delivery: delivery, images: images,
                 // A message with references or elements goes to pi on its own: joined, its fence
                 // would give way.
                 alone: olderClient || !(designReferences ?? []).isEmpty || !elements.isEmpty, context: context,
                 designPayloads: (designReferences ?? []).compactMap(\.payloadID),
                 elements: elements.map(\.withoutHTML)) { [weak self] result in
                if interruptsBackgroundWait, case .accepted = result { self?.onUserInputWhileRunning?() }
                completion(result)
            }
        case .abort:
            // Stopping refuses what pi is waiting on: a question has no Dismiss, and a turn
            // waiting on an answer would not stop.
            refuseDialogs()
            stop { settle($0) }
        case .queue(_, _, _, let action):
            perform(action, operationID: operationID, completion: completion)
        case .setModel(_, _, _, let model):
            // "provider/id"; ids may themselves contain "/" so split on the first one only.
            guard let slash = model.firstIndex(of: "/"), slash > model.startIndex, model.index(after: slash) < model.endIndex else {
                completion(.failure(code: "invalid", message: "Model must be provider/id."))
                return
            }
            let provider = String(model[..<slash])
            let id = String(model[model.index(after: slash)...])
            session.request(.setModel(provider: provider, modelId: id)) { [weak self] result in
                settle(result)
                self?.refreshState()
            }
        case .setThinking(_, _, _, let level):
            // pi clamps a level the model lacks to the nearest one it takes.
            guard ThinkingLevel(rawValue: level) != nil else {
                completion(.failure(code: "invalid", message: "Thinking level must be one of "
                    + ThinkingLevel.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                return
            }
            session.request(.setThinkingLevel(level: level)) { [weak self] result in
                settle(result)
                self?.refreshState()
            }
        case .setServiceTier(_, _, _, let raw):
            guard let tier = ServiceTier(rawValue: raw) else {
                completion(.failure(code: "invalid", message: "Speed must be one of "
                    + ServiceTier.allCases.map(\.rawValue).joined(separator: ", ") + "."))
                return
            }
            // The model decides what is offered: a tier it lacks would change nothing, and saying so
            // beats a Speed control that lies.
            guard serviceTiers.contains(tier) else {
                completion(.failure(code: "unsupported", message: "This model has no \(tier.title) speed."))
                return
            }
            guard let applyServiceTier else {
                completion(.failure(code: "dispatch_failed", message: "The host can't change this agent's speed."))
                return
            }
            applyServiceTier(tier) { error in
                completion(error.map { .failure(code: "dispatch_failed", message: $0) } ?? accepted)
            }
        case .answer(_, _, _, let dialogID, let answer):
            guard let index = dialogs.firstIndex(where: { $0.id == dialogID }), dialogs[index].unavailable == nil else {
                completion(.failure(code: "dialog_unavailable", message: "Dialog answer not accepted. Refresh the thread."))
                return
            }
            let command: RPCCommand
            switch answer {
            case .select(let value), .input(let value), .editor(let value):
                command = .extensionUIResponse(id: dialogID, value: value)
            case .confirm(let value):
                command = .extensionUIResponse(id: dialogID, confirmed: value)
            case .cancel:
                command = .extensionUIResponse(id: dialogID, cancelled: true)
            }
            // pi never answers extension_ui_response; the write is the dispatch.
            guard session.send(command) else {
                completion(.failure(code: "dispatch_failed", message: "The agent's input is closed or full. Try again."))
                return
            }
            let dialog = dialogs.remove(at: index)
            recordQuestion(dialog, answer: answer)
            completion(accepted)
        case .subagentCommand(_, _, _, let runID, let action, let text, let mode):
            // Unknown runs and empty replies never reach the socket; the dispatch itself is the
            // server's (it owns the children extension's connection).
            guard subagents.contains(where: { $0.runID == runID }) else {
                completion(.failure(code: "unknown_run", message: "That subagent is no longer listed."))
                return
            }
            if action == .message, (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (text ?? "").utf8.count > Self.textLimit {
                completion(.failure(code: "invalid", message: "A subagent message needs text up to 16 KiB."))
                return
            }
            guard let dispatchSubagentCommand else {
                completion(.failure(code: "dispatch_failed", message: "The subagent runtime is not connected."))
                return
            }
            dispatchSubagentCommand(runID, action, text, mode) { error in
                completion(error.map { .failure(code: "child_command_failed", message: $0) } ?? accepted)
            }
        case .compact(_, _, _, let instructions):
            compact(instructions: instructions, operationID: operationID, completion: completion)
        case .retry(_, _, _, let entryID):
            retryTurn(entryID: entryID, operationID: operationID, completion: completion)
        case .snapshot, .subagentTranscript:
            completion(.failure(code: "invalid", message: "Not an action."))
        }
    }

    // MARK: - Subagent transcript

    /// One page of a child's pi session JSONL, projected with the same rules as history.
    /// Entry ids are the session entry ids ("c:<id>"); a stale cursor fails like history paging.
    static func transcript(runID: String, file: String, beforeEntryID: String?) -> NativeThreadResult {
        guard let handle = FileHandle(forReadingAtPath: file) else {
            return .failure(code: "transcript_unavailable", message: "The subagent's session file is not readable.")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let start = max(0, size - transcriptReadLimit)
        try? handle.seek(toOffset: UInt64(start))
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[data.index(after: newline)...] }
        struct Entry: Decodable { let type: String; let id: String?; let message: RPCMessage? }
        let decoder = JSONDecoder()
        var entries: [(id: String, message: RPCMessage)] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(Entry.self, from: line), entry.type == "message", let id = entry.id, let message = entry.message else { continue }
            if message.role == "custom" && message.display != true { continue }
            entries.append((id, message))
        }
        let fromUser = userMessageIDs(entries, sent: userMessages(beside: file))
        var arguments: [String: JSONValue] = [:]
        var callTimes: [String: Double] = [:]
        for entry in entries where entry.message.role == "assistant" {
            for case .toolCall(let id, _, let args) in entry.message.content {
                if let args { arguments[id] = args }
                if let time = entry.message.timestamp { callTimes[id] = time }
            }
        }
        var end = entries.count
        if let beforeEntryID {
            guard let index = entries.firstIndex(where: { "c:\($0.id)" == beforeEntryID }) else {
                return .failure(code: "stale_cursor", message: "History changed. Refresh the recent page.")
            }
            end = index
        }
        var pageStart = end
        var page: [NativeThreadMessage] = []
        // Reserve the envelope and cursor before admitting rows, like the parent history page.
        var pageBytes = bytes(NativeSubagentTranscript(runID: runID, messages: [], olderCursor: nil, earlierCount: end)) + 1024
        while pageStart > 0, page.count < pageSize {
            let entry = entries[pageStart - 1]
            let args = entry.message.role == "toolResult" ? entry.message.toolCallId.flatMap { arguments[$0] } : nil
            var value = project(entryID: "c:\(entry.id)", message: entry.message, args: args)
            if entry.message.role == "toolResult" { value.startedAt = entry.message.toolCallId.flatMap { callTimes[$0] } }
            if fromUser.contains(entry.id) { value.origin = .user }
            let nextBytes = bytes(value) + 1 + jsonStringBytes(value.entryID)
            guard pageBytes + nextBytes <= snapshotLimit else {
                if page.isEmpty {
                    return .failure(code: "transcript_unavailable", message: "A transcript entry exceeds the page limit.")
                }
                break
            }
            pageBytes += nextBytes
            page.insert(value, at: 0)
            pageStart -= 1
        }
        return .transcript(value: NativeSubagentTranscript(
            runID: runID, messages: page, olderCursor: pageStart > 0 ? page.first?.entryID : nil, earlierCount: pageStart))
    }

    /// What the user sent the child whose session is `file`, oldest first; none for a run
    /// without the file (a pi-subagents run, or one from an older extension).
    static func userMessages(beside file: String) -> [(text: String, at: Double)] {
        let path = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent(userMessagesFile).path
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let start = max(0, size - userMessagesReadLimit)
        try? handle.seek(toOffset: UInt64(start))
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[data.index(after: newline)...] }
        struct Line: Decodable { let text: String; let at: Double }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            (try? decoder.decode(Line.self, from: line)).map { ($0.text, $0.at) }
        }
    }

    /// The user messages among `entries` that the user sent: each record claims the first
    /// message with its text written no earlier than it was sent.
    static func userMessageIDs(_ entries: [(id: String, message: RPCMessage)], sent: [(text: String, at: Double)]) -> Set<String> {
        guard !sent.isEmpty else { return [] }
        var unclaimed = sent
        var ids: Set<String> = []
        for entry in entries where entry.message.role == "user" {
            let text = entry.message.content.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined()
            // pi stamps the message after the extension records it; a second of slack covers rounding.
            let written = entry.message.timestamp ?? .infinity
            guard let index = unclaimed.firstIndex(where: { $0.text == text && written >= $0.at - 1000 }) else { continue }
            unclaimed.remove(at: index)
            ids.insert(entry.id)
            if unclaimed.isEmpty { break }
        }
        return ids
    }

    // MARK: - Refresh

    func refreshState(timeout: TimeInterval = 10, done: ((Result<RPCResponse, RPCError>) -> Void)? = nil) {
        // The levels follow the model, so they are asked with the state. pi answers stdin in
        // order, so they land just before it and ride its commit: no revision of their own.
        session.request(.getAvailableThinkingLevels, timeout: timeout) { [weak self] result in
            guard let self, case .success(let response) = result, let levels = response.thinkingLevels,
                  levels != self.thinkingLevels else { return }
            self.thinkingLevels = levels
        }
        session.request(.getState, timeout: timeout) { [weak self] result in
            defer { done?(result) }
            guard let self, case .success(let response) = result, response.success, let data = response.data else { return }
            if let id = data["sessionId"]?.stringValue, id != self.piSessionID {
                let switched = self.piSessionID != nil
                if switched { self.resetForNewSession() }
                self.piSessionID = id
                self.loadOrigins(sessionID: id)
                if switched { self.refreshMessages(timeout: timeout) }
            }
            if let m = data["model"], let provider = m["provider"]?.stringValue, let id = m["id"]?.stringValue {
                self.model = "\(provider)/\(id)"
                self.serviceTiers = self.serviceTierOffer(ServiceTierModel(provider: provider, id: id, api: m["api"]?.stringValue))
            } else {
                self.model = nil
                self.serviceTiers = []
            }
            self.thinking = data["thinkingLevel"]?.stringValue
            self.autoCompaction = data["autoCompactionEnabled"]?.boolValue
            self.updateContext()
            if let streaming = data["isStreaming"]?.boolValue, streaming != self.running {
                self.running = streaming
                // A settle this thread did not see (it came before the bootstrap) still lets the
                // queue go.
                if !streaming {
                    self.drainIfReady()
                    self.idleAfterQueue()
                }
            }
            self.commit()
            self.announceIfServable()
        }
    }

    private func announceIfServable() {
        guard isServable, !announcedServable else { return }
        announcedServable = true
        if let opening = openingPrompt {
            openingPrompt = nil
            deliverOpeningPrompt(opening.text, images: opening.images, id: opening.id)
        }
        onServable?()
    }

    /// A new agent's opening prompt (`OpeningPrompt`), sent the moment the thread serves: in the
    /// same queue turn, before any request is answered, so the first snapshot a client gets shows
    /// it (pending until pi starts it) and none shows the thread without it.
    func sendOpeningPrompt(_ text: String, images: [NativeImage] = [], id: UUID) {
        guard isServable else {
            openingPrompt = (text, images, id)
            return
        }
        deliverOpeningPrompt(text, images: images, id: id)
    }

    private func deliverOpeningPrompt(_ text: String, images: [NativeImage], id: UUID) {
        let sessionID = session.id
        guard text.utf8.count <= Self.textLimit else {
            ShepherdLog.warning("rpc session \(sessionID) refused its opening prompt: over \(Self.textLimit) bytes")
            return
        }
        guard NativeImage.fitOneSend(images) else {
            ShepherdLog.warning("rpc session \(sessionID) refused its opening prompt: its images are over the limits")
            return
        }
        send(id: id, text: text, delivery: .followUp, images: images) { result in
            guard case .failure(let code, let message) = result else { return }
            ShepherdLog.warning("rpc session \(sessionID) refused its opening prompt: \(code) \(message)")
        }
    }

    func refreshMessages(timeout: TimeInterval = 10, done: ((Result<RPCResponse, RPCError>) -> Void)? = nil) {
        let generation = generation
        session.request(.getMessages, timeout: timeout) { [weak self] result in
            defer { done?(result) }
            guard let self, generation == self.generation else { return }
            // A failed history fetch must not lock out snapshots, Send, or Stop forever.
            // Reset already discarded the old session; serve the new one as incomplete, as
            // bootstrap does, and let a later refresh recover its history.
            defer {
                self.historyPending = false
                self.commit()
                self.announceIfServable()
                self.drainIfReady()
            }
            guard case .success(let response) = result, response.success,
                  let messages = response.messages else {
                self.projectionClipped = true
                return
            }
            let history = Self.projectHistory(self.markingStopped(messages),
                                              sentReferences: self.origins.compactMapValues(\.references)) { value, message in
                if message.role == "compactionSummary", let summary = message.summary,
                   let note = self.compactionNotes.last(where: { $0.summary == summary }) {
                    value.compaction?.reason = note.reason
                    value.compaction?.tokensAfter = note.after
                }
                if let id = message.toolCallId, message.role == "toolResult", let started = self.toolStarts[id] {
                    value.startedAt = started
                }
                if let id = message.toolCallId, message.role == "toolResult", self.stoppedCalls.contains(id) {
                    value.status = "aborted"
                }
                if message.role == "assistant", let time = message.timestamp { value.thinkingSeconds = self.thinkingByTimestamp[time] }
                if message.role == "user" {
                    let text = message.content.compactMap { block -> String? in
                        if case .text(let text) = block { return text }
                        return nil
                    }.joined()
                    // A design comment's origin is its fence (`project`), which pi keeps.
                    if value.origin == nil {
                        value.origin = self.origins[value.entryID]?.origin(text: DesignViewRecord.strippingFence(from: text))
                    }
                    value.operationID = self.operationsByEntry[value.entryID]
                }
            }
            let kept = Self.keepingSummarized(previous: self.history, next: Self.interleave(self.questions, into: history))
            if kept != self.history {
                self.history = kept
                self.historyVersion += 1
            }
            let estimate = Self.estimate(messages)
            if estimate != self.estimate { self.estimate = estimate }
            // message_end precedes persistence; a refresh means everything ended is now history.
            self.live.removeAll { item in
                switch item.kind {
                case .assistant, .user: item.ended
                case .tool: item.value.status == "complete" || item.value.status == "aborted"
                case .pending: false
                case .compaction: item.ended
                // History places it now.
                case .question: true
                }
            }
            self.updateContext()
        }
    }

    /// pi's error replies to a Stop, as the stops they were.
    private func markingStopped(_ messages: [RPCMessage]) -> [RPCMessage] {
        guard !stoppedReplies.isEmpty else { return messages }
        return messages.map { message in
            guard message.role == "assistant", message.stopReason == "error", let time = message.timestamp,
                  stoppedReplies.contains(time) else { return message }
            var stopped = message
            stopped.stopReason = "aborted"
            return stopped
        }
    }

    func refreshStats(timeout: TimeInterval = 10) {
        session.request(.getSessionStats, timeout: timeout) { [weak self] result in
            guard let self, case .success(let response) = result, response.success, let data = response.data else { return }
            self.stats = Self.projectStats(data)
            self.updateContext()
            self.commit()
        }
    }

    /// get_session_stats → stats. pi estimates the context from the thread's messages, so a
    /// session with none yet (a first turn before pi's first reply) reports 0: unknown, not a
    /// figure to show.
    static func projectStats(_ data: JSONValue) -> NativeThreadStats {
        let usage = data["contextUsage"]
        let tokens = usage?["tokens"]?.countValue.flatMap { $0 > 0 ? $0 : nil }
        return NativeThreadStats(
            contextTokens: tokens,
            contextWindow: usage?["contextWindow"]?.countValue,
            contextPercent: tokens == nil ? nil : usage?["percent"]?.doubleValue,
            totalTokens: data["tokens"]?["total"]?.countValue,
            cost: data["cost"]?.doubleValue
        )
    }

    /// get_commands → capped, byte-limited list. Over-long names are dropped, descriptions clipped.
    /// An `argumentHint` pi sends is kept (pi 0.87.1 sends none; `readArgumentHints` reads a
    /// prompt template's from its file).
    static func projectCommands(_ value: JSONValue?) -> [NativeCommand] {
        guard let items = value?.arrayValue else { return [] }
        var result: [NativeCommand] = []
        for item in items {
            guard let name = item["name"]?.stringValue, !name.isEmpty, name.utf8.count <= NativeCommand.maxNameBytes,
                  name != retryCommand else { continue }
            var description = item["description"]?.stringValue
            if let text = description, text.utf8.count > NativeCommand.maxDescriptionBytes {
                description = String(decoding: Array(text.utf8.prefix(NativeCommand.maxDescriptionBytes)), as: UTF8.self)
            }
            result.append(NativeCommand(name: name, description: description, source: item["source"]?.stringValue,
                                        arguments: argumentHint(item["argumentHint"]?.stringValue)))
            if result.count == NativeCommand.maxCount { break }
        }
        return result
    }

    /// A hint worth showing: trimmed, one line, within `NativeCommand.maxArgumentsBytes`.
    static func argumentHint(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.contains("\n"),
              text.utf8.count <= NativeCommand.maxArgumentsBytes else { return nil }
        return text
    }

    /// The prompt templates get_commands listed, by name, with the file pi read each from.
    static func promptTemplateFiles(_ value: JSONValue?) -> [String: String] {
        var files: [String: String] = [:]
        for item in value?.arrayValue ?? [] where item["source"]?.stringValue == "prompt" && item["argumentHint"] == nil {
            guard let name = item["name"]?.stringValue, let path = item["sourceInfo"]?["path"]?.stringValue,
                  path.hasSuffix(".md") else { continue }
            files[name] = path
            if files.count == NativeCommand.maxCount { break }
        }
        return files
    }

    /// How much of a template file is read for its frontmatter.
    static let frontmatterBytes = 4096

    /// A prompt template's `argument-hint` from its YAML frontmatter, as pi reads it for its own
    /// autocomplete ("argument-hint: \"[tag]\""); nil when the file has none.
    static func argumentHint(frontmatter text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).makeIterator()
        guard lines.next()?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        while let line = lines.next() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil }
            guard trimmed.hasPrefix("argument-hint:") else { continue }
            var value = trimmed.dropFirst("argument-hint:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return argumentHint(value)
        }
        return nil
    }

    /// Reads each prompt template's argument hint off the queue (small files, but file work all
    /// the same), then adds them to the commands still listed, and commits once if any changed.
    private func readArgumentHints(_ files: [String: String]) {
        guard !files.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var hints: [String: String] = [:]
            for (name, path) in files {
                guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? handle.close() }
                let head = (try? handle.read(upToCount: Self.frontmatterBytes)) ?? Data()
                if let hint = Self.argumentHint(frontmatter: String(decoding: head, as: UTF8.self)) { hints[name] = hint }
            }
            guard !hints.isEmpty, let self else { return }
            self.queue.async { [weak self] in
                guard let self, var commands = self.commands else { return }
                var changed = false
                for index in commands.indices where commands[index].arguments == nil {
                    if let hint = hints[commands[index].name] {
                        commands[index].arguments = hint
                        changed = true
                    }
                }
                if changed {
                    self.commands = commands
                    self.commit()
                }
            }
        }
    }

    /// pi switched sessions (new_session / switch): nothing from the previous
    /// session may be acted on with the old generation.
    private func resetForNewSession() {
        historyPending = true
        generation = UUID().uuidString
        operations.removeAll()
        live.removeAll()
        toolStarts.removeAll()
        streamingCalls.removeAll()
        thinkingSpans.removeAll()
        thinkingByTimestamp.removeAll()
        stoppedCalls.removeAll()
        stoppedReplies.removeAll()
        widgets.removeAll()
        history.removeAll()
        historyVersion += 1
        currentAssistant = nil
        projectionClipped = false
        operationsByEntry.removeAll()
        questions.removeAll()
        // A question still open from the last session is not this one's to record.
        askedAt.removeAll()
        estimate = nil
        compactingRun = nil
        compactionNotes.removeAll()
        context = nil
        retryDispatch = nil
        resetQueueForNewSession()
        signature = 0
        bumpRevision()
        // A Retry waiting on the old session's capture finds its turn gone.
        runAfterSettleCapture()
    }

    /// Takes history from `index` on out of what the thread shows, until the next refresh
    /// brings pi's own (Retry: the turn it retries leaves at once).
    func dropHistory(from index: Int) {
        guard history.indices.contains(index) else { return }
        history.removeSubrange(index...)
        historyVersion += 1
    }

    // MARK: - Live rows

    /// The session's record of where delivered messages came from.
    private func loadOrigins(sessionID: String) {
        guard let originStore else { return }
        let loaded = originStore.load(sessionID: sessionID)
        origins = Dictionary(loaded.map { ($0.id, $0.record) }, uniquingKeysWith: { $1 })
        originOrder = loaded.map(\.id)
        questions = originStore.loadQuestions(sessionID: sessionID)
    }

    func recordOrigin(_ origin: NativeMessageOrigin, entryID: String) {
        guard var record = ThreadOriginStore.Record(origin) else { return }
        record.references = origins[entryID]?.references
        keepOrigin(record, entryID: entryID)
    }

    /// Records that the user sent the message `entryID` in this thread with these design
    /// references' copies, so the thread draws its fence as chips (and after a relaunch).
    func recordReferences(_ payloads: [String], entryID: String) {
        var record = origins[entryID] ?? ThreadOriginStore.Record(references: payloads)
        record.references = payloads
        keepOrigin(record, entryID: entryID)
    }

    private func keepOrigin(_ record: ThreadOriginStore.Record, entryID: String) {
        origins[entryID] = record
        originOrder.removeAll { $0 == entryID }
        originOrder.append(entryID)
        if originOrder.count > ThreadOriginStore.limit {
            for id in originOrder.prefix(originOrder.count - ThreadOriginStore.limit) { origins[id] = nil }
            originOrder.removeFirst(originOrder.count - ThreadOriginStore.limit)
        }
        saveOrigins()
    }

    /// Writes the session's origins and questions.
    func saveOrigins() {
        guard let piSessionID, let originStore else { return }
        originStore.save(sessionID: piSessionID, records: originOrder.compactMap { id in origins[id].map { (id, $0) } },
                         questions: questions)
    }

    /// The id history will give a live user message, so the row keeps it when it settles: a
    /// repeat of the same key (two messages pi stamped in one millisecond) counts the earlier
    /// ones in history and the run so far.
    func liveEntryID(for message: RPCMessage) -> String {
        guard let time = message.timestamp.flatMap(Self.millisecondKey) else {
            sequence += 1
            return "provisional:user:\(sequence)"
        }
        let key = "user:\(time)"
        func matches(_ id: String) -> Bool { id == key || id.hasPrefix(key + "#") }
        let repeats = history.count { matches($0.entryID) } + live.count { $0.kind == .user && matches($0.value.entryID) }
        return repeats == 0 ? key : "\(key)#\(repeats)"
    }

    /// pi finished writing a user message it read (persisted at message_end).
    private func userMessageEnded(_ message: RPCMessage) {
        guard let index = live.lastIndex(where: { $0.kind == .user && !$0.ended && $0.value.timestamp == message.timestamp }) else { return }
        live[index].ended = true
    }

    /// Everything in the run, in pi's order, then the prompts pi has not read yet.
    var liveRows: [NativeThreadMessage] {
        live.filter { if case .pending = $0.kind { return false } else { return true } }.map(\.value)
            + live.filter { if case .pending = $0.kind { return true } else { return false } }.map(\.value)
    }

    /// At most a page of assistant messages and a page of tool calls stay live (oldest go
    /// first); user rows always stay, since they open the turns the rest belong to.
    func trimLive() {
        func trim(_ matches: (LiveItem.Kind) -> Bool) {
            guard live.count(where: { matches($0.kind) }) > Self.pageSize, let first = live.firstIndex(where: { matches($0.kind) }) else { return }
            live.remove(at: first)
            projectionClipped = true
        }
        trim { if case .assistant = $0 { true } else { false } }
        trim { if case .tool = $0 { true } else { false } }
    }

    private func upsertAssistant(_ raw: RPCMessage, ended: Bool) {
        guard let key = currentAssistant else { return }
        var value = Self.project(entryID: "provisional:assistant:\(key)", message: raw)
        value.status = ended ? (raw.stopReason ?? "complete") : "streaming"
        let now = Date().timeIntervalSince1970 * 1000
        var hasThinking = false, answered = false
        for block in raw.content {
            switch block {
            case .thinking: hasThinking = true
            case .text(let text) where !text.isEmpty: answered = true
            case .toolCall: answered = true
            default: break
            }
        }
        if hasThinking, thinkingSpans[key] == nil { thinkingSpans[key] = (now, nil) }
        if var span = thinkingSpans[key], span.end == nil, answered || ended {
            span.end = now
            thinkingSpans[key] = span
        }
        if let span = thinkingSpans[key] {
            let seconds = ((span.end ?? now) - span.start) / 1000
            value.thinkingSeconds = seconds
            if ended, let time = raw.timestamp { thinkingByTimestamp[time] = seconds }
        }
        let item = LiveItem(kind: .assistant(key), value: value, raw: raw, ended: ended)
        if let index = live.firstIndex(where: { $0.kind == .assistant(key) }) {
            live[index] = item
        } else {
            live.append(item)
            trimLive()
        }
    }

    private func upsertTool(id: String, name: String, args: JSONValue?, content: [RPCContentBlock], isError: Bool?, status: String) {
        let index = live.firstIndex { $0.kind == .tool(id) }
        let previous = index.map { live[$0].value }
        var value = Self.project(
            entryID: "provisional:tool:\(id)",
            message: RPCMessage(role: "toolResult", content: content, toolName: name, toolCallId: id, isError: isError),
            args: args
        )
        if value.argumentsText == nil { value.argumentsText = previous?.argumentsText }
        value.status = status
        // One clock for the call: from when the host first saw it, which is when the model named
        // it, through its run into history.
        if toolStarts[id] == nil { toolStarts[id] = Date().timeIntervalSince1970 * 1000 }
        value.startedAt = toolStarts[id]
        if status == "complete", value.timestamp == nil { value.timestamp = Date().timeIntervalSince1970 * 1000 }
        if let index {
            // Unchanged rows stay as they are: a commit rehashes only what was assigned.
            if live[index].value != value { live[index].value = value }
        } else {
            live.append(LiveItem(kind: .tool(id), value: value, raw: nil, ended: false))
            trimLive()
        }
    }

    // MARK: - Tool calls being written

    /// A tool call is a row from the moment the model names it, so the thread shows it ("Writing
    /// src/big.txt") while its arguments stream instead of a finished paragraph and nothing
    /// moving. The row carries only the fields an activity line names; `tool_execution_start`
    /// makes the same row the running call, with its complete arguments. pi 0.87.1's events:
    /// `toolcall_start` names the call (`id`, `toolName`), each `toolcall_delta` carries the next
    /// fragment of the arguments' JSON text (not the text so far), and `toolcall_end` the finished
    /// call. A provider that sends its calls whole ends up here too, in one step.
    private func streamToolCall(_ delta: RPCAssistantDelta, in message: RPCMessage) {
        switch delta.type {
        case "toolcall_start":
            guard let id = delta.id, !id.isEmpty, let name = delta.toolName, !name.isEmpty else { return }
            streamingCalls[id] = StreamingToolArguments()
            upsertTool(id: id, name: name, args: nil, content: [], isError: nil, status: "streaming")
        case "toolcall_delta":
            guard let index = delta.contentIndex, message.content.indices.contains(index),
                  case .toolCall(let id, let name, _) = message.content[index],
                  streamingCalls[id]?.append(delta.delta ?? "") == true, let args = streamingCalls[id]?.arguments else { return }
            upsertTool(id: id, name: name, args: args, content: [], isError: nil, status: "streaming")
        case "toolcall_end":
            guard case .toolCall(let id, let name, let arguments?)? = delta.toolCall, streamingCalls[id] != nil,
                  let args = StreamingToolArguments.named(in: arguments) else { return }
            upsertTool(id: id, name: name, args: args, content: [], isError: nil, status: "streaming")
        default:
            break
        }
    }

    /// Takes the calls still being written out of the thread, except `keeping`: the ones a
    /// finished reply hands to pi, which run next and continue their rows. Nothing else ever
    /// runs a call that was still streaming (a stopped or failed request, the end of the run).
    private func dropStreamingCalls(keeping: Set<String> = []) {
        var dropped: [String] = []
        live.removeAll { item in
            guard case .tool(let id) = item.kind, item.value.status == "streaming", !keeping.contains(id) else { return false }
            dropped.append(id)
            return true
        }
        for id in dropped { toolStarts[id] = nil }
        if !streamingCalls.isEmpty { streamingCalls = streamingCalls.filter { keeping.contains($0.key) } }
    }

    static func apply(_ delta: RPCAssistantDelta, to message: inout RPCMessage) {
        guard let index = delta.contentIndex, index >= 0 else { return }
        while message.content.count <= index { message.content.append(.text("")) }
        switch delta.type {
        case "text_start":
            message.content[index] = .text("")
        case "text_delta":
            if case .text(let text) = message.content[index] {
                message.content[index] = .text(text + (delta.delta ?? ""))
            } else {
                message.content[index] = .text(delta.delta ?? "")
            }
        case "text_end":
            if let content = delta.content { message.content[index] = .text(content) }
        case "thinking_start":
            message.content[index] = .thinking("")
        case "thinking_delta":
            if case .thinking(let text) = message.content[index] {
                message.content[index] = .thinking(text + (delta.delta ?? ""))
            } else {
                message.content[index] = .thinking(delta.delta ?? "")
            }
        case "thinking_end":
            // Streamed without its `redacted` flag; message_end brings the block itself.
            if let content = delta.content {
                message.content[index] = .thinking(content == RPCContentBlock.redactedThinkingPlaceholder ? "" : content)
            }
        case "toolcall_start":
            message.content[index] = .toolCall(id: delta.id ?? "", name: delta.toolName ?? "", arguments: nil)
        case "toolcall_end":
            if let call = delta.toolCall { message.content[index] = call }
        default:
            break
        }
    }

    // MARK: - Dialogs and widgets

    /// Cancels every question pi waits on that can be answered here (its asker gets pi's
    /// cancelled answer); the next commit drops them from the thread, which records each as
    /// not answered.
    func refuseDialogs() {
        let open = dialogs.filter { $0.unavailable == nil }
        guard !open.isEmpty else { return }
        for dialog in open { session.send(.extensionUIResponse(id: dialog.id, cancelled: true)) }
        dialogs.removeAll { $0.unavailable == nil }
        if session.isAlive { for dialog in open { recordQuestion(dialog, answer: .cancel) } }
    }

    private func handleUIRequest(_ request: RPCExtensionUIRequest) {
        switch request.method {
        case "select", "confirm", "input", "editor":
            guard let kind = NativeThreadDialog.Kind(rawValue: request.method) else { return }
            var dialog = NativeThreadDialog(
                id: request.id, kind: kind, title: request.title ?? "", options: request.options,
                message: request.message, placeholder: request.placeholder, prefill: request.prefill, timeout: request.timeout
            )
            if Self.bytes(dialog) > Self.dialogBytes {
                dialog = NativeThreadDialog(id: request.id, kind: kind, title: "Dialog too large for native thread", unavailable: "payload-limit")
            }
            // A dialog an asking tool opens carries that call's reason (the newest, should two run).
            // One assignment, so the question changes once and its reason is not pruned first.
            var next = dialogs.filter { $0.id != request.id }
            next.append(dialog)
            dialogReasons[request.id] = askingCalls.last?.reason ?? nil
            askedAt[request.id] = Date().timeIntervalSince1970 * 1000
            dialogs = next
            if let delay = Self.dialogTimeout(request.timeout) {
                // pi auto-resolves on its side; we only stop showing it, and the thread says it
                // went unanswered.
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, let index = self.dialogs.firstIndex(where: { $0.id == request.id }) else { return }
                    self.recordQuestion(self.dialogs.remove(at: index), answer: nil)
                    self.commit()
                    // pi may already have settled and its history refresh beaten this timer.
                    // Place the record in history even when no later turn will refresh it.
                    self.refreshMessages()
                }
            }
        case "setWidget":
            guard let key = request.widgetKey else { return }
            let text = request.widgetLines.map { $0.map(Self.stripANSI).joined(separator: "\n") }
            // Some extensions publish machine payloads for their own TUI component
            // (pi-subagents: "PI_SUBAGENT_ASYNC_JSON:{…}"). Those are not for people.
            if let text, Self.isMachineWidget(text) { setWidget(nil, key: key); return }
            setWidget(text.map { NativeThreadWidget(namespace: "pi", key: key, kind: .text, text: $0) }, key: key)
        case "notify":
            // A TUI toast ("Ponytail loaded: full", "Task queued"). The native thread has no
            // toast surface and the message rarely matters after the moment; dropping it beats
            // parking it above the composer.
            break
        default:
            // setStatus is the TUI footer slot (ponytail, goal, codex-fast park persistent
            // chrome there), not conversation content; setTitle / set_editor_text likewise.
            break
        }
    }

    /// nil clears. Over-limit items are dropped with a log line, never fatal.
    /// `UPPER_SNAKE:` marker prefixes and bare JSON objects/arrays are machine widgets.
    static func isMachineWidget(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let marker = trimmed[..<colon]
        return marker.count >= 4 && marker.allSatisfy { $0.isUppercase || $0 == "_" || $0.isNumber }
    }

    private func setWidget(_ item: NativeThreadWidget?, key: String) {
        let id = "pi\u{0}\(key)"
        guard let item else {
            widgets.removeAll { $0.id == id }
            return
        }
        guard !key.isEmpty, key.utf8.count <= 128 else {
            ShepherdLog.warning("rpc session \(session.id) widget key rejected (1–128 bytes)")
            return
        }
        guard item.text.utf8.count <= Self.widgetTextBytes, (item.title ?? "").utf8.count <= Self.widgetTitleBytes else {
            ShepherdLog.warning("rpc session \(session.id) widget '\(key)' dropped: text exceeds \(Self.widgetTextBytes) bytes or title exceeds \(Self.widgetTitleBytes)")
            return
        }
        let existing = widgets.firstIndex { $0.id == id }
        guard existing != nil || widgets.count < Self.widgetItems else {
            ShepherdLog.warning("rpc session \(session.id) widget '\(key)' dropped: at most \(Self.widgetItems) items")
            return
        }
        var next = widgets.filter { $0.id != id }
        next.append((id, item))
        guard Self.bytes(next.map(\.value)) <= Self.widgetAggregateBytes else {
            ShepherdLog.warning("rpc session \(session.id) widget '\(key)' dropped: items exceed the \(Self.widgetAggregateBytes)-byte budget")
            return
        }
        widgets = next
    }

    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansi.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Snapshot

    /// Everything a snapshot shows, as one signature: a change anywhere moves the revision, and
    /// nothing else does. Each part's hash is taken once per change: the lists here when they are
    /// assigned, a live row by the first commit after its value changed.
    func commit() {
        var hasher = Hasher()
        hasher.combine(history.count)
        hasher.combine(historyVersion)
        hasher.combine(live.count)
        for index in live.indices where live[index].hash == nil {
            live[index].hash = entryHash(live[index].value)
        }
        for item in live { hasher.combine(item.hash) }
        hasher.combine(dialogsHash)
        hasher.combine(widgetsHash)
        hasher.combine(running)
        hasher.combine(model)
        hasher.combine(thinking)
        hasher.combine(thinkingLevels)
        hasher.combine(serviceTier)
        hasher.combine(serviceTiers)
        hasher.combine(piSessionID)
        hasher.combine(stats)
        hasher.combine(context)
        hasher.combine(commandsHash)
        hasher.combine(subagentsHash)
        hasher.combine(turnChangesHash)
        hasher.combine(retry)
        hasher.combine(queueHash())
        #if DEBUG
        bytesHashedByLastCommit = bytesHashedSinceCommit
        bytesHashedSinceCommit = 0
        #endif
        let next = hasher.finalize()
        if next != signature {
            signature = next
            bumpRevision()
        }
    }

    private func bumpRevision() {
        revision += 1
        onRevision?()
    }

    private func entryHash(_ value: NativeThreadMessage) -> Int {
        #if DEBUG
        bytesHashedSinceCommit += value.blocks.reduce(0) { $0 + $1.text.utf8.count } + (value.argumentsText?.utf8.count ?? 0)
            + (value.origin?.parts?.reduce(0) { $0 + $1.text.utf8.count } ?? 0)
        #endif
        return value.hashValue
    }

    private func queueHash() -> Int {
        let queue = queueValue
        if queue == hashedQueue { return queueHashValue }
        hashedQueue = queue
        #if DEBUG
        bytesHashedSinceCommit += queue.items.reduce(0) { $0 + $1.text.utf8.count } + (queue.notice?.utf8.count ?? 0)
        #endif
        queueHashValue = queue.hashValue
        return queueHashValue
    }

    private func queueBytes(_ queue: NativeQueue) -> Int {
        if queue == sizedQueue { return queueBytesValue }
        sizedQueue = queue
        queueBytesValue = measured(queue)
        return queueBytesValue
    }

    private func snapshot(beforeEntryID: String?) -> NativeThreadResult {
        var end = history.count
        if let beforeEntryID {
            // Entry ids name messages (`historyEntryID`), so resolve the cursor by id.
            guard let index = history.firstIndex(where: { $0.entryID == beforeEntryID }) else {
                return .failure(code: "stale_cursor", message: "History changed. Refresh the recent page.")
            }
            end = index
        }
        #if DEBUG
        encodesSinceSnapshot = 0
        bytesEncodedSinceSnapshot = 0
        #endif
        let dialogs = Array(self.dialogs.prefix(Self.dialogLimit))
        var base = NativeThreadSnapshot(
            piSessionID: piSessionID ?? "", generation: generation, revision: revision, running: running,
            model: model, thinking: thinking, thinkingLevels: thinkingLevels, supportedActions: Self.supportedActions, dialogsSupported: true,
            dialogs: [], widgets: widgets.map(\.value), messages: [], provisional: [],
            clipped: projectionClipped || dialogs.contains { $0.unavailable == "payload-limit" },
            runtime: "rpc", stats: stats, commands: commands, subagents: subagents, context: context,
            turnChanges: turnChanges, retry: retry,
            serviceTier: serviceTier.rawValue, serviceTiers: serviceTiers.map(\.rawValue)
        )
        // The rest encodes without the queue, which adds `,"queue":` and its cached size.
        let queue = queueValue
        let baseBytes = measured(base) + Self.queueFieldBytes + queueBytes(queue)
        base.queue = queue
        let sizedDialogs = zip(dialogs, dialogSizes()).map { Sized(value: $0, bytes: $1) }
        let budgeted = Self.budget(
            base, baseBytes: baseBytes, active: activeEntries(), dialogs: sizedDialogs,
            historyEnd: end, history: { self.historyEntry($0) }
        )
        #if DEBUG
        encodesByLastSnapshot = encodesSinceSnapshot
        bytesEncodedByLastSnapshot = bytesEncodedSinceSnapshot
        bytesOfLastSnapshot = budgeted.bytes
        #endif
        return .snapshot(value: budgeted.snapshot)
    }

    /// Fills `value` with the page of `history` that ends before `end`: up to 50 entries, newest
    /// last, within what is left of the snapshot budget. `olderCursor` marks older history, in
    /// `history` or, with `moreBefore`, before it.
    static func fillPage(_ value: inout NativeThreadSnapshot, from history: [NativeThreadMessage], end: Int, moreBefore: Bool = false) {
        var size = bytes(value)
        var index = end - 1
        while index >= 0 {
            let message = history[index]
            size += bytes(message) + 1
            if size > snapshotLimit {
                value.clipped = true
                break
            }
            value.messages.insert(message, at: 0)
            index -= 1
            if value.messages.count == pageSize { break }
        }
        if index >= 0 || moreBefore, let first = value.messages.first { value.olderCursor = first.entryID }
    }

    /// An element of a snapshot list and its encoded size.
    struct Sized<Value> {
        let value: Value
        let bytes: Int
    }

    /// Applies the snapshot budgets to `base`, whose dialogs, messages and provisional lists are
    /// empty and which encodes to `baseBytes`, by arithmetic over each element's encoded size: a
    /// list adds its elements and the commas between them, and `clipped` turning true saves a
    /// byte. Active output is trimmed to `activeLimit` first (the oldest provisional rows that are
    /// not user rows, which open the turns the rest belong to; then the newest dialogs), then
    /// history fills the rest of `snapshotLimit` from `historyEnd` back, a
    /// page at most. The decisions are the ones encoding the growing snapshot made; returns the
    /// snapshot and its exact encoded size.
    static func budget(
        _ base: NativeThreadSnapshot,
        baseBytes: Int,
        active: [Sized<NativeThreadMessage>],
        dialogs: [Sized<NativeThreadDialog>],
        historyEnd: Int,
        history: (Int) -> Sized<NativeThreadMessage>
    ) -> (snapshot: NativeThreadSnapshot, bytes: Int) {
        func list(_ count: Int, _ sum: Int) -> Int { count == 0 ? 0 : sum + count - 1 }
        var clipped = base.clipped
        func flag() -> Int { clipped == base.clipped ? 0 : clipped ? -1 : 1 }
        var dropped = Set<Int>()
        var activeSum = active.reduce(0) { $0 + $1.bytes }
        var dialogCount = dialogs.count
        var dialogSum = dialogs.reduce(0) { $0 + $1.bytes }
        func size() -> Int {
            baseBytes + flag() + list(active.count - dropped.count, activeSum) + list(dialogCount, dialogSum)
        }
        var next = 0
        while size() > activeLimit {
            while next < active.count, active[next].value.role == "user" { next += 1 }
            guard next < active.count else { break }
            activeSum -= active[next].bytes
            dropped.insert(next)
            next += 1
            clipped = true
        }
        while size() > activeLimit, dialogCount > 0 {
            dialogCount -= 1
            dialogSum -= dialogs[dialogCount].bytes
            clipped = true
        }
        // Each message is counted with a comma, as when the growing snapshot was encoded.
        var budgeted = size()
        var page: [Sized<NativeThreadMessage>] = []
        var index = historyEnd - 1
        while index >= 0 {
            let entry = history(index)
            budgeted += entry.bytes + 1
            if budgeted > snapshotLimit {
                clipped = true
                break
            }
            page.append(entry)
            index -= 1
            if page.count == pageSize { break }
        }
        page.reverse()
        var value = base
        value.provisional = active.indices.filter { !dropped.contains($0) }.map { active[$0].value }
        value.dialogs = dialogs[..<dialogCount].map(\.value)
        value.messages = page.map(\.value)
        value.clipped = clipped
        var bytes = size() + list(page.count, page.reduce(0) { $0 + $1.bytes })
        if index >= 0, let first = page.first {
            value.olderCursor = first.value.entryID
            // ,"olderCursor":"…"
            bytes += 15 + jsonStringBytes(first.value.entryID)
        }
        return (value, bytes)
    }

    /// The length of `text` as JSONEncoder writes it: quoted, with `"`, `\`, `/` and control
    /// characters escaped.
    static func jsonStringBytes(_ text: String) -> Int {
        var bytes = 2
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), 0x08, 0x09, 0x0A, 0x0C, 0x0D: bytes += 2
            case ..<0x20: bytes += 6
            default: bytes += 1
            }
        }
        return bytes
    }

    /// `liveRows`, each sized once for as long as it stays unchanged.
    private func activeEntries() -> [Sized<NativeThreadMessage>] {
        var entries: [Sized<NativeThreadMessage>] = []
        var pending: [Sized<NativeThreadMessage>] = []
        entries.reserveCapacity(live.count)
        for index in live.indices {
            let bytes = live[index].bytes ?? measured(live[index].value)
            live[index].bytes = bytes
            let entry = Sized(value: live[index].value, bytes: bytes)
            if case .pending = live[index].kind { pending.append(entry) } else { entries.append(entry) }
        }
        return entries + pending
    }

    /// The sizes of the dialogs a snapshot can carry (the first `dialogLimit`).
    private func dialogSizes() -> [Int] {
        if let dialogBytes { return dialogBytes }
        let sizes = dialogs.prefix(Self.dialogLimit).map { measured($0) }
        dialogBytes = sizes
        return sizes
    }

    /// History rows are immutable until the next refresh replaces them, so each is sized once.
    private func historyEntry(_ index: Int) -> Sized<NativeThreadMessage> {
        if historyBytes[index] < 0 { historyBytes[index] = measured(history[index]) }
        return Sized(value: history[index], bytes: historyBytes[index])
    }

    private func measured<T: Encodable>(_ value: T) -> Int {
        let bytes = Self.bytes(value)
        #if DEBUG
        encodesSinceSnapshot += 1
        bytesEncodedSinceSnapshot += bytes
        #endif
        return bytes
    }

    /// A value that cannot be encoded counts as over every budget, without overflowing a sum.
    static func bytes<T: Encodable>(_ value: T) -> Int {
        (try? encoder.encode(value).count) ?? Int(Int32.max)
    }

    // MARK: - Projection

    /// pi's message list as thread history, with the same rules wherever it comes from (pi's
    /// `get_messages`, or its session file read from disk): custom messages are model-only
    /// unless their extension marked them display (pi-subagents' task-completed JSON is the
    /// usual case), and child reports ("Child native-… (worker): complete … Session: …") restate
    /// the card and ledger, which own that information here (the TUI still shows them). pi keeps
    /// a call's arguments and start on the assistant's toolCall block; the toolResult row is
    /// what the thread shows, so both are handed across by call id. `adjust` sees each row with
    /// its message last.
    ///
    /// `sentReferences` names, by entry id, the design references' copies of each message the
    /// user sent in this thread (`ThreadOriginStore`): only those messages show their references
    /// as chips; any other fence shows as text.
    static func projectHistory(
        _ messages: [RPCMessage],
        sentReferences: [String: [String]] = [:],
        adjust: (inout NativeThreadMessage, RPCMessage) -> Void = { _, _ in }
    ) -> [NativeThreadMessage] {
        var arguments: [String: JSONValue] = [:]
        var callTimes: [String: Double] = [:]
        for message in messages where message.role == "assistant" {
            for case .toolCall(let id, _, let args) in message.content {
                if let args { arguments[id] = args }
                if let time = message.timestamp { callTimes[id] = time }
            }
        }
        var seen: [String: Int] = [:]
        return chronological(messages).enumerated().compactMap { index, message in
            // pi's structured system prompt rides in the message list; the thread never shows it.
            if message.role == "system" { return nil }
            if message.role == "custom" && message.display != true { return nil }
            if message.role == "custom" && message.customType == "shepherd-child" { return nil }
            let args = message.role == "toolResult" ? message.toolCallId.flatMap { arguments[$0] } : nil
            let entryID = historyEntryID(message, index: index, seen: &seen)
            var value = project(entryID: entryID, message: message, args: args, sentReferences: sentReferences[entryID])
            if let id = message.toolCallId, message.role == "toolResult" { value.startedAt = callTimes[id] }
            adjust(&value, message)
            if let origin = value.origin { value.origin = clipped(origin) }
            return value
        }
    }

    /// When a dialog pi opened with `timeout` (ms) stops showing; nil for none. An extension
    /// passes any number, and one past `Int.max` milliseconds waits as long as Dispatch can.
    static func dialogTimeout(_ timeout: Double?) -> DispatchTimeInterval? {
        guard let timeout, timeout > 0, let milliseconds = Int(reportedCount: timeout) else { return nil }
        return .milliseconds(milliseconds)
    }

    /// pi's millisecond timestamp as an entry id writes it; nil for one no `Int64` holds.
    static func millisecondKey(_ time: Double) -> Int64? {
        Int64(exactly: time.rounded(.towardZero))
    }

    /// A history entry's id names the message, never its place in pi's list, so a message keeps
    /// its id across refreshes and when it is read from pi's session file before pi answers
    /// (history pages start at different places). A tool result is its call ("t:<call id>");
    /// anything else with pi's millisecond timestamp is "<role>:<ms>", a repeat of that within
    /// the list becoming "#<n>"; a message without a timestamp (never from pi itself) keeps its
    /// position ("m:<index>").
    static func historyEntryID(_ message: RPCMessage, index: Int, seen: inout [String: Int]) -> String {
        let key: String
        if message.role == "toolResult", let call = message.toolCallId, !call.isEmpty {
            key = "t:\(call)"
        } else if let time = message.timestamp.flatMap(millisecondKey) {
            key = "\(message.role.isEmpty ? "custom" : message.role):\(time)"
        } else {
            return "m:\(index)"
        }
        let repeats = seen[key, default: 0]
        seen[key] = repeats + 1
        return repeats == 0 ? key : "\(key)#\(repeats)"
    }

    /// A queue origin's parts restate the message's text: they share one text budget.
    static func clipped(_ origin: NativeMessageOrigin) -> NativeMessageOrigin {
        guard case .queue(var parts) = origin else { return origin }
        var remaining = textLimit
        for index in parts.indices {
            let bytes = parts[index].text.utf8.count
            if bytes <= remaining {
                remaining -= bytes
                continue
            }
            parts[index].text = clippedText(parts[index].text, limit: remaining)
            remaining = 0
        }
        return .queue(parts: parts)
    }

    ///
    /// A user message's design references fence comes off (its records become the message's
    /// `designReferences`) only when `sentReferences` names every copy it carries: a message the
    /// user sent in this thread. Otherwise it stays, as text.
    static func project(entryID: String, message: RPCMessage, args: JSONValue? = nil, sentReferences: [String]? = nil) -> NativeThreadMessage {
        var remaining = textLimit
        var truncated = false
        func clip(_ value: String) -> String {
            let bytes = value.utf8.count
            if bytes <= remaining {
                remaining -= bytes
                return value
            }
            truncated = true
            let text = clippedText(value, limit: remaining)
            remaining = 0
            return text
        }
        var result = NativeThreadMessage(entryID: entryID, role: message.role.isEmpty ? "custom" : message.role, blocks: [])
        if let toolName = message.toolName { result.toolName = clip(toolName) }
        if let toolCallID = message.toolCallId { result.toolCallID = clip(toolCallID) }
        if let args { result.argumentsText = clip(json(args)) }
        // A design view record the viewer's message carried is pi's to read, not the thread's.
        var fenced = message.role == "user"
        for block in message.content {
            if result.blocks.count >= 128 || remaining == 0 {
                truncated = true
                break
            }
            switch block {
            case .text(let text):
                if fenced, let comment = DesignCommentFence.parse(text), comment.fence.reply != true {
                    // A design comment: the chat draws its card.
                    result.origin = .designComment(id: comment.fence.comment)
                }
                if fenced, let markup = DesignMarkupFence.parse(text) {
                    // Pencil markup: the chat draws what the agent read.
                    result.origin = .designMarkup(strokes: markup.markup.strokes.count, notes: markup.markup.noteCount)
                }
                var shown = fenced ? DesignViewRecord.strippingFence(from: text, references: false, elements: false) : text
                if fenced, let sentReferences, let parsed = DesignReferenceFence.parse(text),
                   let ids = DesignReferenceFence.payloadIDs(parsed.records), Set(ids).isSubset(of: sentReferences) {
                    shown = String(parsed.text)
                    result.designReferences = parsed.records.map(\.withoutFiles)
                }
                // Elements picked in the Browser: the composer and the queue draw them as chips,
                // but no board draws one on a sent bubble, so the human line stays as the words.
                if fenced, let parsed = BrowserElementFence.parse(shown) {
                    shown = String(parsed.text)
                    result.browserElements = parsed.elements.map(\.withoutHTML)
                }
                fenced = false
                result.blocks.append(NativeThreadBlock(kind: .text, text: clip(shown)))
            case .thinking(let text):
                // Streamed thinking arrives raw (pi-ai ends each summary part with a blank line);
                // what a reader sees is normalized, the growing text as much as the settled one.
                result.blocks.append(NativeThreadBlock(kind: .thinking, text: clip(RPCContentBlock.normalizedThinking(text))))
            case .image:
                result.blocks.append(NativeThreadBlock(kind: .unsupportedImage, text: clip("[Image unavailable in native thread]")))
            case .toolCall:
                // The tool row (name, arguments, result) is the call's surface; dumping the
                // call JSON as prose duplicated it.
                break
            case .unknown:
                break
            }
        }
        // A stopped run's "Request was aborted" says nothing its `aborted` status does not.
        if let error = message.errorMessage, !error.isEmpty, message.stopReason != "aborted" {
            result.blocks.append(NativeThreadBlock(kind: .text, text: clip(error)))
        }
        if message.stopReason == "error" {
            result.provider = message.provider.map(clip)
            result.model = message.model.map(clip)
        }
        if message.role == "compactionSummary" {
            result.compaction = NativeCompaction(phase: .done, tokensBefore: message.tokensBefore.flatMap(Int.init(reportedCount:)),
                                                 summary: message.summary.map(clip))
        }
        if let isError = message.isError { result.isError = isError }
        if let stop = message.stopReason, !stop.isEmpty { result.status = clip(stop) }
        result.timestamp = message.timestamp
        result.truncated = truncated
        return result
    }

    private static let argumentEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static func json(_ value: JSONValue) -> String {
        (try? argumentEncoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

/// A turn's edges, as the Changes engine hears them.
enum TurnEvent: Equatable {
    /// pi started a run.
    case started
    /// A user message joined the thread (the first one names the turn).
    case message(timestamp: Double?, text: String)
    /// pi's run settled.
    case settled
}
