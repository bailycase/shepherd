import CryptoKit
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
    /// What the snapshot's other lists may weigh (`fitting`), so a long thread's cards and recorded
    /// turns never squeeze its history out, and the room history and the live run always keep
    /// whatever the rest weighs (`budget`).
    static let subagentsLimit = 64 * 1024
    static let turnChangesLimit = 48 * 1024
    static let widgetsLimit = 64 * 1024
    static let historyReserve = 96 * 1024
    static let activeReserve = 48 * 1024
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
                                   "designReferences", "browserElements", "retry", "interrupt", "setServiceTier", "images", "queueSubagent", "artifacts"]
    /// pi answers `compact` only once the summary is written, which takes as long as a reply.
    static let compactTimeout: TimeInterval = 600
    /// Bytes of a child session file the transcript reader will scan (tail); older is unreachable.
    static let transcriptReadLimit = 8 * 1024 * 1024
    /// Beside a native child's session: one `{"text","at"}` line per message the user sent it
    /// (the children extension's `messageChild`), so its transcript tells them from the parent's.
    static let userMessagesFile = "user-messages.jsonl"
    static let userMessagesReadLimit = 1024 * 1024
    /// pi answers a prompt only once its preflight is done: input handlers, a compaction after
    /// an aborted run, image processing, or an extension command running to its end. Allow the
    /// same bounded time for a preflight compaction as for Compact now.
    static let promptTimeout: TimeInterval = compactTimeout

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
            /// What an extension command the user ran said back (`CommandNotice`).
            case notice(UUID)
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
        let fingerprint: SHA256.Digest
        var result: NativeThreadResult?
        var waiters: [(NativeThreadResult) -> Void] = []
    }

    let session: RPCSession
    let queue: DispatchQueue
    private(set) var piSessionID: String?
    /// A readiness failure, independent of whether any client is watching this thread.
    private var bootstrapFailure: String?
    private var bootstrapTimeout: TimeInterval?
    private var bootstrapWaitingForHuman: Bool?
    private var bootstrapDeadline = UUID()
    /// The bootstrap's `get_messages` has not answered. pi answers it after `get_state`, and a
    /// long history takes a moment to arrive: served meanwhile, a resumed thread would show
    /// as a new, empty one.
    private var historyPending = true
    // Only a successfully installed history supersedes an older request still hydrating images.
    private var historyRequestSequence: UInt64 = 0
    private var appliedHistorySequence: UInt64 = 0
    /// Installed by SessionServer: called once, on the session queue, when the thread first
    /// serves (pi has answered `get_state` and `get_messages`).
    var onServable: (() -> Void)?
    var onDiagnosticDuration: ((String, Double) -> Void)?
    var onDiagnosticActivity: ((String) -> Void)?
    private var diagnosticTimings: [String: (String, ContinuousClock.Instant)] = [:]
    private var announcedServable = false
    /// A new agent's opening prompt, held until the thread serves (`sendOpeningPrompt`).
    typealias OpeningPrompt = (text: String, images: [NativeImage], id: UUID, at: Double)
    private var openingPrompt: OpeningPrompt?
    /// The opening prompt pi never read (it stopped before the thread served).
    var unreadOpeningPrompt: OpeningPrompt? { openingPrompt }
    /// Requests get a snapshot rather than `native_starting`.
    var isServable: Bool { piSessionID != nil && !historyPending }
    private(set) var generation = UUID().uuidString
    private(set) var revision: UInt64 = 0
    /// Called on the session queue each time `revision` moves.
    var onRevision: (() -> Void)?
    /// Recovery observes intent even when a change does not alter the rendered snapshot.
    var onRecoveryChanged: (() -> Bool)?
    var recoveryAttempts = 0
    var restoringRecovery = true
    var recoveryAtLaunch: AgentRecoveryStore.Checkpoint?
    var recoveryDispatchID: UUID?
    var recoveryWaiting: Bool { !dialogs.isEmpty || !askingCalls.isEmpty }
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
    /// What the snapshot lists for the `/` menu: `allCommands` less the names the user turned off in
    /// Settings ▸ Pi ▸ Slash commands (`hiddenCommands`). Every client reads this one list.
    private(set) var commands: [NativeCommand]? { didSet { commandsHash = commands.hashValue } }
    /// Everything pi's `get_commands` listed, after the projection (`projectCommands`) and before
    /// the user's switches. The Settings page lists from it so a disabled command can come back.
    private(set) var allCommands: [NativeCommand]? { didSet { rebuildCommands() } }
    /// Names left out of `commands` and refused when sent: this host's own switches, set by the
    /// server and applied live.
    var hiddenCommands: Set<String> = [] {
        didSet {
            guard hiddenCommands != oldValue else { return }
            rebuildCommands()
            commit()
        }
    }
    /// Told each time pi lists its commands, so the server can keep the host's catalog.
    var onCommandsListed: (([NativeCommand]) -> Void)?
    /// Native child runs as last published by the children extension over the socket.
    private(set) var subagents: [NativeSubagent] = [] {
        didSet {
            guard subagents != oldValue else { return }
            subagentsHash = subagents.hashValue
            snapshotSubagents = Self.fitting(subagents, limit: Self.subagentsLimit)
        }
    }
    /// What a snapshot carries of `subagents`: the runs within their budget (`fitting`).
    private(set) var snapshotSubagents: [NativeSubagent] = []
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
    /// Queue admission is serialized with edits and draining; uncertain launches require reconciliation.
    var startingQueueChild: UUID?
    var unknownQueueChildren: Set<UUID> = []
    var dispatchQueueChild: ((UUID, String, [NativeImage], @escaping (String?) -> Void) -> Void)?
    /// Installed by SessionServer: writes a childCommand to the children extension and answers
    /// with its error text (nil on success). Runs on the server queue.
    var dispatchSubagentCommand: ((String, NativeSubagentAction, String?, NativeThreadDelivery?, @escaping (String?) -> Void) -> Void)?
    var stopProjectChildren: ((@escaping (String?) -> Void) -> Void)?
    private(set) var history: [NativeThreadMessage] = [] { didSet { historyBytes = Array(repeating: -1, count: history.count) } }
    /// Each history row's encoded size, taken by the first snapshot that shows it (-1 until then).
    private var historyBytes: [Int] = []
    /// Bumped whenever a refresh changes history, so a same-length change (a compaction) is a
    /// new revision.
    private var historyVersion = 0
    var live: [LiveItem] = []
    /// Tests only: runs off the queue before a history's images are read (`refreshMessages`).
    var beforeHistoryImages: (() -> Void)?
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
    /// The model request in flight (ResponseTiming): what pi's provider hooks reported of it
    /// (`recordResponseMark`) and what its stream showed. `requestSeq` is the hooks' number for it,
    /// `requestKey` the live assistant message it became once pi started that. nil between requests.
    private var request: NativeResponseTiming?
    private var requestSeq: Int?
    private var requestKey: Int?
    private struct ResponseMarks {
        var timing = NativeResponseTiming()
        var timestamp: Double?
    }
    /// Bounded correlation records for the independently delivered hook and RPC channels.
    private var responseMarks: [Int: ResponseMarks] = [:]
    /// Finished requests' timing, by the assistant message's pi timestamp, so history projected
    /// later keeps it. In memory only, and bounded (`timingLimit`): a thread reopened after a
    /// restart has none, and says so by offering none.
    private var timingByTimestamp: [Double: NativeResponseTiming] = [:]
    static let timingLimit = 512
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
            updateBootstrapDeadline()
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
    private var widgets: [(id: String, value: NativeThreadWidget)] = [] {
        didSet {
            widgetsHash = widgets.map(\.value).hashValue
            snapshotWidgets = Self.fitting(widgets.map(\.value), limit: Self.widgetsLimit)
        }
    }
    /// What a snapshot carries of `widgets`, within their budget.
    private var snapshotWidgets: [NativeThreadWidget] = []
    private(set) var goal: NativeGoal?
    private var goalsAvailable = false
    /// SessionServer supplies the host experiment policy before the thread starts.
    private(set) var goalsEnabled = true
    private var pendingGoalPolicy: Bool?
    /// Off must reach pi even if On supersedes it before stdin has room.
    private var pendingGoalDisable = false
    var goalYieldGeneration: String?
    private var goalCommand: UUID?
    private var goalCommandFailure: String?
    var onGoalChanged: ((NativeGoal?) -> Void)?

    func setGoalsEnabled(_ enabled: Bool, notifyController: Bool = true) {
        let changed = goalsEnabled != enabled
        goalsEnabled = enabled
        if !enabled {
            goalYieldGeneration = nil
            goalsAvailable = false
            if goal != nil { goal = nil; onGoalChanged?(nil) }
        }
        if changed { rebuildCommands(); commit() }
        if notifyController, session.hasGoalController {
            pendingGoalPolicy = enabled
            pendingGoalDisable = pendingGoalDisable || !enabled
            flushGoalPolicy()
        }
    }

    private func flushGoalPolicy() {
        // At most two tiny records: a disable barrier, then the latest policy.
        while let enabled = pendingGoalPolicy {
            let next = pendingGoalDisable ? false : enabled
            guard session.send(.prompt(message: "/shepherd-goal {\"action\":\"configure\",\"enabled\":\(next)}", streamingBehavior: .steer)) else {
                if session.pendingInputBytes > 0, session.onInputDrained == nil {
                    session.onInputDrained = { [weak self] in self?.flushGoalPolicy() }
                }
                return
            }
            pendingGoalDisable = false
            if next == enabled { pendingGoalPolicy = nil }
        }
        session.onInputDrained = nil
    }

    private var operations: [(id: String, operation: Operation)] = []
    /// The host could not read pi's history the last time it asked (`refreshMessages`), so the thread
    /// may be missing messages: the snapshot says so (`clips.history`) until a fetch lands whole.
    var historyUnread = false
    /// Rows of the running turn's output `trimLive` dropped since history was last read: the snapshot
    /// says so (`clips.live`), and the finished turn's history brings them back.
    private(set) var liveLeftOut = 0
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
    var recoveryPending: (id: UUID, completion: (NativeThreadResult) -> Void)?
    var checkpointRecovery: NativeCheckpointRecovery?
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
    private(set) var lastTurnAssistant: NativeThreadMessage?
    var projectResultDeliveryID: UUID?
    private(set) var lastTurnResult: ProjectVisibleResult?
    private(set) var lastTurnResultDeliveryID: UUID?
    private func captureResult(_ message: RPCMessage, final: Bool = false) {
        let user = live.last(where: { $0.value.role == "user" })?.value.entryID ?? history.last(where: { $0.role == "user" })?.entryID
        guard let expected = projectResultDeliveryID, user.flatMap({ operationsByEntry[$0] }) == expected else { return }
        var captured = Self.visibleProjectResult(message)
        // A dropped agent_end cannot promote an earlier message_end slice to the complete final reply.
        captured.complete = captured.complete && final
        lastTurnResult = captured
        lastTurnResultDeliveryID = expected
    }

    func discardProjectResult(deliveryID: UUID) {
        guard lastTurnResultDeliveryID == deliveryID else { return }
        lastTurnResult = nil; lastTurnResultDeliveryID = nil
    }
    static func visibleProjectResult(_ message: RPCMessage) -> ProjectVisibleResult {
        let text = message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }; return nil
        }.joined(separator: "\n")
        let supported = message.content.allSatisfy { block in
            switch block { case .text, .thinking: true; default: false }
        }
        var bytes = Data(text.utf8.prefix(ProjectVisibleResult.maximumBytes))
        for _ in 0..<3 where String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return .init(text: String(decoding: bytes, as: UTF8.self), complete: supported && text.utf8.count <= ProjectVisibleResult.maximumBytes && message.stopReason == "stop", stopReason: message.stopReason)
    }
    /// A native human question is a safe pause point only when no other tool/assistant runs.
    var waitingOnlyForDialog: Bool {
        dialogs.contains(where: { $0.unavailable == nil }) && currentAssistant == nil && liveRows.filter { $0.role == "toolResult" && $0.status == "running" }
            .allSatisfy { Self.asksUser($0.toolName ?? "") }
    }
    /// Asynchronous filesystem boundaries; completions return to this thread's queue.
    var beforePrompt: ((@escaping () -> Void) -> Void)?
    var captureSettledTurn: ((@escaping () -> Void) -> Void)?
    var onUserMessageConsumed: ((UUID?, String) -> Void)?
    var onActualTurnSettled: (() -> Void)?
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
    private(set) var turnChanges: [ChangesTurn]? {
        didSet {
            turnChangesHash = turnChanges.hashValue
            snapshotTurnChanges = turnChanges.map { Self.fitting($0, limit: Self.turnChangesLimit) }
        }
    }
    /// What a snapshot carries of `turnChanges`, within its budget.
    private var snapshotTurnChanges: [ChangesTurn]?
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
    /// What extension commands the user ran said back, newest last, and the commands in flight
    /// (`RPCThreadState+CommandNotices.swift`). Not persisted: they answer a command, and a
    /// command leaves nothing in pi's session.
    var commandNotices: [CommandNotice] = []
    var commandWindows: Set<UUID> = []
    var inputActive = false
    var inputOutcomeUnknown = false
    var waitingInputs: [(Bool) -> Void] = []
    /// How long a command's toasts count as its own after pi answers it.
    var commandNoticeGrace: TimeInterval = 1.5

    /// File invalidations coalesce while busy; no timers, model calls or persistent work.
    private var skillsNeedRefresh = false
    private(set) var skillRefreshFailures = 0
    private var skillCommandsPending = false
    private var skillRefreshInFlight = false

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

    /// pi may not read stdin until startup finishes. Bound readiness, not its lifetime: keep
    /// late answers so a slow pi can still serve and take its opening prompt, without retries.
    func bootstrap(timeout: TimeInterval = 60) {
        if session.hasGoalController { setGoalsEnabled(goalsEnabled) }
        refreshState(timeout: timeout, acceptLateResponse: true)
        refreshMessages(timeout: timeout, bootstrap: true)
        refreshStats(timeout: timeout, acceptLateResponse: true)
        refreshCommands(timeout: timeout, acceptLateResponse: true)
        bootstrapTimeout = timeout
        bootstrapWaitingForHuman = nil
        updateBootstrapDeadline()
    }

    /// Human response time is not startup work. Bound the machine's wait again after an answer.
    private func updateBootstrapDeadline() {
        guard let timeout = bootstrapTimeout, !isServable else { return }
        let waitingForHuman = dialogs.contains(where: { $0.unavailable == nil })
        guard bootstrapWaitingForHuman != waitingForHuman else { return }
        bootstrapWaitingForHuman = waitingForHuman
        bootstrapDeadline = UUID()
        bootstrapFailure = nil
        guard !waitingForHuman else { return }
        let deadline = bootstrapDeadline
        let generation = generation
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.bootstrapDeadline == deadline, self.generation == generation,
                  !self.isServable, self.session.isAlive else { return }
            let waiting = [self.piSessionID == nil ? "get_state" : nil, self.historyPending ? "get_messages" : nil].compactMap { $0 }.joined(separator: ", ")
            self.bootstrapFailure = "The agent is running but was not ready within \(timeout.formatted()) seconds (waiting for \(waiting)). Your first message is kept. Check Settings > Pi; Reconnect checks readiness again."
            ShepherdLog.warning("rpc session \(self.session.id) readiness deadline: waiting for \(waiting)")
            self.onRevision?()
        }
    }

    func canRecoverCheckpoint(operationID: UUID) -> Bool {
        isServable && !running && !inputActive && compactingRun == nil && openingPrompt == nil
            && dialogs.isEmpty && items.isEmpty && dispatches.isEmpty
            && (retryDispatch == nil || retryDispatch == operationID)
            && preparingPrompts.isEmpty && settleCapture == nil && sendAfterCapture == nil
            && interrupting == nil && !interruptAbortPending && unboundSteers.isEmpty
            && steersInFlight == 0 && !settleAwaitingSteers && piSteering.isEmpty && piFollowUp.isEmpty
            && sendingDesignPayloads.isEmpty
    }

    /// Moving changes the working directory and reloads instructions, so no pending work may survive it.
    var canMoveSpace: Bool {
        isServable && !running && !inputActive && compactingRun == nil && openingPrompt == nil
            && dialogs.isEmpty && items.isEmpty && dispatches.isEmpty && retryDispatch == nil
            && preparingPrompts.isEmpty && settleCapture == nil
            && sendAfterCapture == nil && interrupting == nil && !interruptAbortPending
            && unboundSteers.isEmpty && steersInFlight == 0 && !settleAwaitingSteers
            && piSteering.isEmpty && piFollowUp.isEmpty && sendingDesignPayloads.isEmpty
            && subagents.allSatisfy { $0.isTerminal && $0.state != "paused" && !$0.needsAttention }
            && (goal == nil || goal?.state == .paused || goal?.state == .met) && goalCommand == nil
    }

    func refreshSkillsIfIdle() {
        guard skillsNeedRefresh, session.isAlive, skillRefreshFailures < 3, !skillRefreshInFlight,
              piSessionID != nil, !running, !inputActive, compactingRun == nil else { return }
        skillsNeedRefresh = false
        skillRefreshInFlight = true
        session.request(.refreshSkills) { [weak self] result in
            guard let self else { return }
            self.skillRefreshInFlight = false
            if case .success(let response) = result, response.success {
                self.skillRefreshFailures = 0
                self.skillCommandsPending = self.skillCommandsPending || response.data?["changed"]?.boolValue == true
                if self.skillCommandsPending { self.refreshCommands() }
            } else if case .success(let response) = result, response.error == "skills_busy" {
                // Engine-side fence also covers prompt preflight and queued continuations.
                self.skillsNeedRefresh = true
                return
            } else {
                // A timeout can lose the reply after pi already replaced its catalog. The next
                // successful refresh may say unchanged; still reconcile the host's command list.
                self.skillCommandsPending = true
                self.skillsNeedRefresh = true
                self.skillRefreshFailures += 1
                if self.skillRefreshFailures == 3 {
                    ShepherdLog.warning("Skill refresh stopped after three failures for session \(self.session.id)")
                }
            }
            self.refreshSkillsIfIdle()
        }
    }

    private func refreshCommands(timeout: TimeInterval = 10, attempt: Int = 0, acceptLateResponse: Bool = false) {
        let generation = generation
        let receive: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            guard let self, !acceptLateResponse || self.generation == generation else { return }
            guard case .success(let response) = result, response.success else {
                if self.skillCommandsPending, self.session.isAlive, attempt < 2 {
                    self.refreshCommands(timeout: timeout, attempt: attempt + 1, acceptLateResponse: acceptLateResponse)
                }
                return
            }
            let listed = response.data?["commands"]
            self.skillCommandsPending = false
            let commands = Self.projectCommands(listed)
            guard self.allCommands != commands else { return }
            self.allCommands = commands
            self.commit()
            self.onCommandsListed?(commands)
            self.readArgumentHints(Self.promptTemplateFiles(listed))
        }
        session.request(.getCommands, timeout: timeout,
                        onLateResponse: acceptLateResponse ? { receive(.success($0)) } : nil, completion: receive)
    }

    // MARK: - Events (session queue)

    func handle(_ event: RPCEvent) {
        switch event {
        case .skillsChanged:
            skillsNeedRefresh = true
            skillRefreshFailures = 0
            refreshSkillsIfIdle()
        case .skillsWatchError(let error):
            ShepherdLog.warning("Skill file observation failed for session \(session.id): \(error)")
        case .agentStart:
            diagnosticTimings.removeAll(keepingCapacity: true)
            beginDiagnostic("agent.turn", operation: "agent.turn")
            lastTurnAssistant = nil
            lastTurnResult = nil
            lastTurnResultDeliveryID = nil
            // A compaction that stopped or failed says so until the next run.
            live.removeAll { if case .compaction = $0.kind { $0.value.compaction?.phase != .running } else { false } }
            // A retry's second start is the same turn; the engine tells them apart.
            onTurnEvent?(.started)
            running = true
            runFailed = false
            runError = nil
            // A buffered start can arrive after Stop. Only newly authorized input clears it.
            settleAwaitingSteers = false
            doneHeld = false
            if !items.isEmpty {
                yieldGoalToQueue()
                onUserInputWhileRunning?()
            }
        case .agentEnd(let messages, _):
            if let message = messages.last(where: { $0.role == "assistant" }) {
                if lastTurnAssistant == nil { lastTurnAssistant = Self.project(entryID: liveEntryID(for: message), message: message) }
                captureResult(message, final: true)
            }
            dropStreamingCalls()
            refreshMessages()
            refreshState()
            refreshStats()
        case .agentSettled:
            if !runFailed, !stopRequested { recoveryAttempts = 0 }
            endDiagnostic("agent.turn")
            diagnosticTimings.removeAll(keepingCapacity: true)
            running = false
            request = nil
            requestKey = nil
            requestSeq = nil
            // Socket marks can arrive after stdout settles or starts the next run. Keep the
            // bounded correlation records until session reset (a new process owns a new state).
            retry = nil
            refreshState()
            dropStreamingCalls()
            askingCalls.removeAll()
            let token = UUID()
            settleCapture = token
            if let captureSettledTurn {
                captureSettledTurn { [weak self] in
                    guard let self, self.settleCapture == token else { return }
                    self.settleCapture = nil
                    self.onActualTurnSettled?()
                    self.drainIfReady()
                    self.idleAfterQueue()
                }
            } else {
                onTurnEvent?(.settled)
                settleCapture = nil
                onActualTurnSettled?()
            }
            settled()
            refreshSkillsIfIdle()
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
            beginDiagnostic("model.response", operation: "model.response")
            sequence += 1
            currentAssistant = sequence
            requestStarted(key: sequence, timestamp: message.timestamp)
            upsertAssistant(message, ended: false)
        case .messageUpdate(let delta):
            guard let key = currentAssistant, let index = live.firstIndex(where: { $0.kind == .assistant(key) }), let current = live[index].raw else {
                // message_start was missed (spawned mid-turn); start accumulating now.
                sequence += 1
                currentAssistant = sequence
                requestStarted(key: sequence)
                var raw = RPCMessage(role: "assistant", content: [])
                Self.apply(delta, to: &raw)
                upsertAssistant(raw, ended: false)
                observeStream(delta)
                streamToolCall(delta, in: raw)
                break
            }
            observeStream(delta)
            // A call's argument fragments change nothing the reply shows, only the call's row.
            if delta.type == "toolcall_delta" {
                streamToolCall(delta, in: current)
                break
            }
            var raw = current
            Self.apply(delta, to: &raw)
            upsertAssistant(raw, ended: false)
            streamToolCall(delta, in: raw)
        case .messageEnd(let message) where message.role == "custom" && message.display == true && message.customType != "shepherd-child":
            // A message an extension displays (a command's report) is in pi's history already, and
            // an idle pi has no turn whose end would refresh it.
            if !running { refreshMessages() }
        case .messageEnd(let message):
            guard message.role == "assistant" else { break }
            endDiagnostic("model.response")
            if currentAssistant == nil {
                sequence += 1
                currentAssistant = sequence
                requestStarted(key: sequence, timestamp: message.timestamp)
                upsertAssistant(message, ended: false)
            }
            requestEnded(message)
            runFailed = message.stopReason == "error"
            runError = runFailed ? message.errorMessage : nil
            if runFailed, !stopRequested { onDiagnosticActivity?("model.failed") }
            var ended = message
            if runFailed, stopRequested {
                ended.stopReason = "aborted"
                if let time = message.timestamp { stoppedReplies.insert(time) }
            }
            upsertAssistant(ended, ended: true)
            requestDone()
            lastTurnAssistant = live.last(where: { $0.value.role == "assistant" })?.value
            captureResult(ended)
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
        case .toolExecutionStart(let id, let name, let args, _):
            let operation = name.hasPrefix("mcp__") ? "tool.mcp" : (["read", "bash", "write", "edit"].contains(name) ? "tool." + name : "tool.other")
            beginDiagnostic("tool:" + id, operation: operation)
            if Self.asksUser(name) {
                askingCalls.removeAll { $0.id == id }
                askingCalls.append((id, Self.shortReason(in: args)))
            }
            streamingCalls[id] = nil
            upsertTool(id: id, name: name, args: args, content: [], isError: nil, status: "running")
        case .toolExecutionUpdate(let id, let name, let args, let partial, _):
            upsertTool(id: id, name: name, args: args, content: partial?.content ?? [], isError: nil, status: "running")
        case .toolExecutionEnd(let id, let name, let result, let isError, _):
            endDiagnostic("tool:" + id)
            let stopped = isError && stopRequested
            if isError, !stopRequested { onDiagnosticActivity?("tool.failed") }
            askingCalls.removeAll { $0.id == id }
            if stopped { stoppedCalls.insert(id) }
            upsertTool(id: id, name: name, args: nil, content: result?.content ?? [], isError: isError, status: stopped ? "aborted" : "complete", projectAction: result?.projectAction)
            onToolFinished?(name)
        case .queueUpdate(let steering, let followUp):
            piQueueChanged(steering: steering, followUp: followUp)
        case .extensionUIRequest(let request):
            handleUIRequest(request)
        case .extensionError(let path, let event, let error):
            onDiagnosticActivity?("extension.failed")
            ShepherdLog.warning("rpc session \(session.id) extension error in \(path ?? "?") (\(event ?? "?")): \(error)")
            recordCommandFailure(path: path, event: event, error: error)
            if goalCommand != nil, event == "command", path == "command:shepherd-goal" { goalCommandFailure = error }
        case .compactionStart(let reason):
            beginDiagnostic("context.compact", operation: "context.compact")
            compactionStarted(reason: NativeCompactionReason(pi: reason))
        case .compactionEnd(let reason, let result, let aborted, let willRetry, let error):
            endDiagnostic("context.compact")
            if error != nil, !aborted { onDiagnosticActivity?("context.compact_failed") }
            compactionEnded(reason: NativeCompactionReason(pi: reason), result: result, aborted: aborted, willRetry: willRetry, error: error)
        case .autoRetryStart(let attempt, let maxAttempts, let delayMs, _):
            onDiagnosticActivity?("model.retry")
            retry = NativeThreadRetry(attempt: attempt, maxAttempts: maxAttempts,
                                      retryAt: (Date().timeIntervalSince1970 * 1000 + max(0, delayMs)).rounded())
        case .autoRetryEnd:
            retry = nil
        case .turnStart:
            beginDiagnostic("model.response", operation: "model.response")
        case .turnEnd, .unknown:
            break
        }
        commit()
    }

    private func beginDiagnostic(_ key: String, operation: String) {
        guard onDiagnosticDuration != nil, diagnosticTimings[key] == nil, diagnosticTimings.count < 128 else { return }
        diagnosticTimings[key] = (operation, .now)
    }

    private func endDiagnostic(_ key: String) {
        guard let (operation, started) = diagnosticTimings.removeValue(forKey: key) else { return }
        let elapsed = started.duration(to: .now).components
        onDiagnosticDuration?(operation, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
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
    /// `isolateSend`: host-managed operation identity must survive even an all-at-once queue.
    func handle(_ request: NativeThreadRequest, olderClient: Bool = false, isolateSend: Bool = false, startupDialogs: Bool = true,
                recoveryBinding: CheckpointRecoveryBinding? = nil, recoveryAuthorization: @escaping () -> Bool = { true },
                completion: @escaping (NativeThreadResult) -> Void) {
        if !isServable {
            if !startupDialogs, dialogs.contains(where: { $0.unavailable == nil }) {
                completion(.failure(code: NativeThreadCode.unavailable,
                                    message: "Update Shepherd on this device to answer the agent's startup question."))
                return
            }
            switch request {
            case .snapshot(_, nil, _) where startupDialogs && bootstrapFailure == nil && (!dialogs.isEmpty || !questions.isEmpty), .answer:
                break
            default:
                completion(.failure(code: bootstrapFailure == nil ? NativeThreadCode.starting : NativeThreadCode.unavailable,
                                    message: bootstrapFailure ?? "The agent is starting."))
                return
            }
        }
        let piSessionID = isServable ? (self.piSessionID ?? "") : ""
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
        case .image(let expectedSessionID, let imageID, let offset):
            guard expectedSessionID == piSessionID else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            serveImage(imageID, offset: offset, completion: completion)
        case .artifact(let expectedSessionID, let path, let offset):
            guard expectedSessionID == piSessionID else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            serveArtifact(path, offset: offset, completion: completion)
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
             .retry(let expectedSessionID, let generation, let operationID, _, _),
             .setServiceTier(let expectedSessionID, let generation, let operationID, _),
             .goal(let expectedSessionID, let generation, let operationID, _, _, _, _):
            guard expectedSessionID == piSessionID, generation == self.generation else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            let fingerprint: SHA256.Digest
            do { fingerprint = try Self.operationFingerprint(request) }
            catch {
                completion(.failure(code: "invalid", message: "The request could not be encoded."))
                return
            }
            let key = operationID.uuidString.uppercased()
            if let index = operations.firstIndex(where: { $0.id == key }) {
                guard operations[index].operation.fingerprint == fingerprint else {
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
            operations.append((key, Operation(fingerprint: fingerprint)))
            if operations.count > Self.operationTableSize { operations.removeFirst() }
            perform(request, operationID: operationID, alone: olderClient || isolateSend,
                    recoveryBinding: recoveryBinding, recoveryAuthorization: recoveryAuthorization) { [weak self] result in
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

    /// Retain only 32 bytes per operation, not its text and image payloads. Request strings use
    /// Swift's canonical Unicode equality; the only floating-point request fields also equate ±0.
    static func operationFingerprint(_ request: NativeThreadRequest) throws -> SHA256.Digest {
        var normalized = request.withDesignReferences(request.designReferences?.map { reference in
            var reference = reference
            if reference.width == 0 { reference.width = 0 }
            if reference.height == 0 { reference.height = 0 }
            return reference
        })
        if case .send(let session, let generation, let operation, let text, let delivery, let images, let context, let references, let elements) = normalized {
            normalized = .send(expectedSessionID: session, generation: generation, operationID: operation, text: text, delivery: delivery,
                               images: images?.map { NativeImage(mimeType: $0.mimeType, data: Data(SHA256.hash(data: $0.data)), name: $0.name) },
                               designContext: context, designReferences: references, browserElements: elements)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(normalized)
        let text = String(decoding: data, as: UTF8.self).precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(text.utf8))
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

    private func perform(_ request: NativeThreadRequest, operationID: UUID, alone: Bool,
                         recoveryBinding: CheckpointRecoveryBinding?, recoveryAuthorization: @escaping () -> Bool, completion: @escaping (NativeThreadResult) -> Void) {
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
                 alone: alone || !(designReferences ?? []).isEmpty || !elements.isEmpty, context: context,
                 designPayloads: (designReferences ?? []).compactMap(\.payloadID),
                 elements: elements.map(\.withoutHTML)) { [weak self] result in
                if interruptsBackgroundWait, case .accepted = result { self?.onUserInputWhileRunning?() }
                completion(result)
            }
        case .abort:
            // Stopping refuses what pi is waiting on: a question has no Dismiss, and a turn
            // waiting on an answer would not stop.
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
        case .goal(_, _, _, let action, let expectedID, let expectedRevision, let expectedState):
            guard goalsEnabled && goalsAvailable else { completion(.failure(code: "unsupported", message: "Enable Goals in Settings > Experiments.")); return }
            guard action.isValid else { completion(.failure(code: "invalid", message: "A goal needs text up to 32768 characters.")); return }
            if action == .pause || action == .resume || action == .confirm {
                guard let goal, expectedID == goal.id, expectedRevision == goal.revision, expectedState == goal.state else {
                    completion(.failure(code: "stale_goal", message: "Use the displayed goal state and revision.")); return
                }
            }
            guard expectedID == nil || expectedID == goal?.id,
                  expectedRevision == nil || expectedRevision == goal?.revision,
                  expectedState == nil || expectedState == goal?.state else {
                completion(.failure(code: "stale_goal", message: "The goal changed. Refresh it before acting.")); return
            }
            var command = action.command
            if expectedID != nil || expectedRevision != nil || expectedState != nil,
               var object = try? JSONSerialization.jsonObject(with: Data(command.dropFirst("/shepherd-goal ".count).utf8)) as? [String: Any] {
                if let expectedID { object["expectedGoalID"] = expectedID }
                if let expectedRevision { object["expectedGoalRevision"] = expectedRevision }
                if let expectedState { object["expectedGoalState"] = expectedState.rawValue }
                if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                    command = "/shepherd-goal " + String(decoding: data, as: UTF8.self)
                }
            }
            guard goalCommand == nil else { completion(.failure(code: "busy", message: "Another goal command is pending.")); return }
            goalCommand = operationID
            goalCommandFailure = nil
            let generation = generation
            session.request(.prompt(message: command, streamingBehavior: .steer), timeout: Self.promptTimeout) { [weak self] result in
                guard let self, self.generation == generation else {
                    completion(.failure(code: "stale_session", message: "The session changed while the goal command was pending.")); return
                }
                let error = self.goalCommandFailure
                self.goalCommand = nil
                self.goalCommandFailure = nil
                if let error { completion(.failure(code: "goal_rejected", message: error)) }
                else { settle(result) }
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
        case .retry(_, _, _, let entryID, let checkpoint):
            retryTurn(entryID: entryID, checkpoint: checkpoint, operationID: operationID, binding: recoveryBinding,
                      authorized: recoveryAuthorization, completion: completion)
        case .snapshot, .subagentTranscript, .image, .artifact:
            completion(.failure(code: "invalid", message: "Not an action."))
        }
    }

    // MARK: - Images

    /// One piece of an image pi saved in this thread, read from pi's own history for this agent. Nothing a client sends names a
    /// file: the id must match an image in the history as it is now. Server queue in, server queue out: the scan, the hash, the
    /// base64 and the header read of a megabytes-long history run on a utility queue, and the answer is given only if the session
    /// is still the one asked about.
    private func serveImage(_ imageID: String, offset: Int, completion: @escaping (NativeThreadResult) -> Void) {
        guard ThreadImages.parse(imageID) != nil, offset >= 0 else {
            completion(.failure(code: NativeImageCode.unknown, message: "That image is not in this thread."))
            return
        }
        let generation = generation
        let sessionID = piSessionID
        let stale = NativeThreadResult.failure(code: "stale_session", message: "Refresh the thread before acting.")
        session.request(.getMessages, timeout: 30) { [weak self] result in
            guard let self, generation == self.generation else { completion(stale); return }
            guard case .success(let response) = result, response.success, let messages = response.messages else {
                completion(.failure(code: NativeImageCode.unknown, message: "The thread's history could not be read."))
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let found = ThreadImages.find(imageID, in: messages)
                let chunk = found.flatMap { ThreadImages.chunk(imageID, mimeType: $0.mimeType, data: $0.data, offset: offset) }
                guard let self else { completion(stale); return }
                self.queue.async { [weak self] in
                    guard let self, generation == self.generation, sessionID == self.piSessionID else { completion(stale); return }
                    if let chunk { completion(.imageChunk(value: chunk)); return }
                    completion(.failure(code: NativeImageCode.unknown,
                                        message: found == nil ? "That image is not in this thread." : "That part of the image is past its end."))
                }
            }
        }
    }

    // MARK: - Artifacts

    /// One piece of a file this thread's `write` calls made (`ThreadArtifacts`). The written paths are read from pi's own history for this
    /// agent as it is now, and the file from disk, off the server queue; the answer is given only if the session is still the one asked about.
    private func serveArtifact(_ path: String, offset: Int, completion: @escaping (NativeThreadResult) -> Void) {
        guard !path.isEmpty, offset >= 0 else {
            completion(.failure(code: NativeArtifactCode.unknown, message: "That file is not one this thread made."))
            return
        }
        let generation = generation
        let sessionID = piSessionID
        let cwd = session.cwd
        let stale = NativeThreadResult.failure(code: "stale_session", message: "Refresh the thread before acting.")
        session.request(.getMessages, timeout: 30) { [weak self] result in
            guard let self, generation == self.generation else { completion(stale); return }
            guard case .success(let response) = result, response.success, let messages = response.messages else {
                completion(.failure(code: NativeArtifactCode.unknown, message: "The thread's history could not be read."))
                return
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let read = ThreadArtifacts.read(path, offset: offset, written: ThreadArtifacts.writtenPaths(in: messages), cwd: cwd)
                guard let self else { completion(stale); return }
                self.queue.async { [weak self] in
                    guard let self, generation == self.generation, sessionID == self.piSessionID else { completion(stale); return }
                    switch read {
                    case .chunk(let chunk): completion(.artifactChunk(value: chunk))
                    case .outOfRange: completion(.failure(code: NativeArtifactCode.unknown, message: "That file is not one this thread made."))
                    case .unavailable: completion(.failure(code: NativeArtifactCode.unavailable, message: "That file can't be opened now."))
                    }
                }
            }
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
        let projected = entries.flatMap { entry -> [NativeThreadMessage] in
            let args = entry.message.role == "toolResult" ? entry.message.toolCallId.flatMap { arguments[$0] } : nil
            var value = project(entryID: "c:\(entry.id)", message: entry.message, args: args)
            if entry.message.role == "toolResult" { value.startedAt = entry.message.toolCallId.flatMap { callTimes[$0] } }
            if fromUser.contains(entry.id) { value.origin = .user }
            return [value] + nestedRows(entry.message, parentEntryID: value.entryID)
        }
        var end = projected.count
        if let beforeEntryID {
            guard let index = projected.firstIndex(where: { $0.entryID == beforeEntryID }) else {
                return .failure(code: "stale_cursor", message: "History changed. Refresh the recent page.")
            }
            end = index
        }
        var pageStart = end
        var page: [NativeThreadMessage] = []
        // Reserve the envelope and cursor before admitting rows, like the parent history page.
        var pageBytes = bytes(NativeSubagentTranscript(runID: runID, messages: [], olderCursor: nil, earlierCount: end)) + 1024
        while pageStart > 0, page.count < pageSize {
            let value = projected[pageStart - 1]
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
    /// without the file, such as a run from an older extension.
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

    func refreshState(timeout: TimeInterval = 10, acceptLateResponse: Bool = false,
                      done: ((Result<RPCResponse, RPCError>) -> Void)? = nil) {
        // The levels follow the model, so they are asked with the state. pi answers stdin in
        // order, so they land just before it and ride its commit: no revision of their own.
        let generation = generation
        let receiveLevels: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            guard let self, (!acceptLateResponse || self.generation == generation),
                  case .success(let response) = result, let levels = response.thinkingLevels,
                  levels != self.thinkingLevels else { return }
            self.thinkingLevels = levels
        }
        session.request(.getAvailableThinkingLevels, timeout: timeout,
                        onLateResponse: acceptLateResponse ? { receiveLevels(.success($0)) } : nil, completion: receiveLevels)
        let receive: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            defer { done?(result); self?.refreshSkillsIfIdle() }
            guard let self, (!acceptLateResponse || self.generation == generation),
                  case .success(let response) = result, response.success, let data = response.data else { return }
            if let id = data["sessionId"]?.stringValue, id != self.piSessionID {
                let switched = self.piSessionID != nil
                let goalController = self.goalsAvailable
                if switched { self.resetForNewSession() }
                self.piSessionID = id
                self.loadOrigins(sessionID: id)
                if switched {
                    self.refreshMessages(timeout: timeout)
                    // session_start's restored widget can precede this get_state response.
                    if goalController {
                        self.session.request(.prompt(message: "/shepherd-goal {\"action\":\"status\"}", streamingBehavior: .steer)) { _ in }
                    }
                }
            }
            if let m = data["model"], let provider = m["provider"]?.stringValue, let id = m["id"]?.stringValue {
                self.model = "\(provider)/\(id)"
                self.serviceTiers = ServiceTierSupport.tiers(for: ServiceTierModel(provider: provider, id: id, api: m["api"]?.stringValue))
            } else {
                self.model = nil
                self.serviceTiers = []
            }
            self.checkpointRecovery = data["checkpointRecovery"].flatMap { value in
                (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(NativeCheckpointRecovery.self, from: $0) }
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
        session.request(.getState, timeout: timeout,
                        onLateResponse: acceptLateResponse ? { receive(.success($0)) } : nil, completion: receive)
    }

    private func announceIfServable() {
        guard isServable, !announcedServable else { return }
        announcedServable = true
        bootstrapFailure = nil
        bootstrapTimeout = nil
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
            openingPrompt = (text, images, id, Date().timeIntervalSince1970 * 1000)
            commit()
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

    /// Bootstrap keeps late history answers and never serves a timed-out fetch as empty history.
    func refreshMessages(timeout: TimeInterval = 10, bootstrap: Bool = false,
                         done: ((Result<RPCResponse, RPCError>) -> Void)? = nil) {
        let generation = generation
        historyRequestSequence += 1
        let sequence = historyRequestSequence
        let started = ContinuousClock.now
        let measured: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            let elapsed = started.duration(to: .now).components
            self?.onDiagnosticDuration?("history.refresh", Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
            done?(result)
        }
        let receive: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            guard let self else { return }
            // The live rows that had ended when pi answered are the ones this history holds. One that ends while the images
            // below are read (the next message pi starts, a Steer now's above all) is not in it, and stays live.
            let persisted = Set(self.live.filter(Self.persisted).map(\.value.entryID))
            // A history with images costs a header read and a SHA-256 each. That work is done here, off the thread's queue, into a
            // table built from exactly these messages; the projection on the thread's queue only looks entries up. A history with
            // no images goes straight on.
            if case .success(let response) = result, response.success, let messages = response.messages,
               ThreadImages.hasImages(messages) {
                let hook = self.beforeHistoryImages
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    hook?()
                    let table = ThreadImages.table(for: messages)
                    self?.queue.async { [weak self] in
                        self?.finishRefresh(result, generation: generation, sequence: sequence, bootstrap: bootstrap, images: table, persisted: persisted,
                                            done: measured)
                    }
                }
                return
            }
            self.finishRefresh(result, generation: generation, sequence: sequence, bootstrap: bootstrap, images: [:], persisted: persisted, done: measured)
        }
        session.request(.getMessages, timeout: timeout,
                        onLateResponse: bootstrap ? { receive(.success($0)) } : nil, completion: receive)
    }

    /// A live row pi has persisted: a fetch of its history from then on holds it.
    private static func persisted(_ item: LiveItem) -> Bool {
        switch item.kind {
        case .assistant, .user, .compaction: item.ended
        case .tool: item.value.status == "complete" || item.value.status == "aborted"
        case .pending, .question, .notice: false
        }
    }

    private func finishRefresh(_ result: Result<RPCResponse, RPCError>, generation: String, sequence: UInt64, bootstrap: Bool,
                               images: [String: ThreadImages.Meta], persisted: Set<String>,
                               done: ((Result<RPCResponse, RPCError>) -> Void)?) {
        do {
            defer { done?(result) }
            guard generation == self.generation, sequence > appliedHistorySequence else { return }
            // During bootstrap a timeout is not an empty history. The readiness deadline
            // surfaces the failure; a late answer can still recover the full conversation.
            if bootstrap, case .failure(.timeout) = result { return }
            // Other failed history fetches serve as incomplete until a later refresh succeeds.
            defer {
                self.historyPending = false
                self.commit()
                self.announceIfServable()
                self.drainIfReady()
            }
            guard case .success(let response) = result, response.success,
                  let messages = response.messages else {
                self.historyUnread = true
                return
            }
            // The whole history is here again: what it could not read, and the live rows `trimLive`
            // dropped, are in it.
            self.appliedHistorySequence = sequence
            self.historyUnread = false
            self.liveLeftOut = 0
            let history = Self.projectHistory(self.markingStopped(messages),
                                              sentReferences: self.origins.compactMapValues(\.references), images: images) { value, message in
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
                if message.role == "assistant", let time = message.timestamp {
                    value.thinkingSeconds = self.thinkingByTimestamp[time]
                    value.timing = self.timingByTimestamp[time]
                }
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
            let kept = Self.keepingSummarized(previous: self.history, next: Self.interleave(self.placedRecords, into: history))
            if kept != self.history {
                self.history = kept
                self.historyVersion += 1
            }
            let estimate = Self.estimate(messages)
            if estimate != self.estimate { self.estimate = estimate }
            // message_end precedes persistence: what had ended when pi answered is now history.
            self.live.removeAll { item in
                switch item.kind {
                // History places it now.
                case .question, .notice: true
                default: persisted.contains(item.value.entryID) && Self.persisted(item)
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

    func refreshStats(timeout: TimeInterval = 10, acceptLateResponse: Bool = false) {
        let generation = generation
        let receive: (Result<RPCResponse, RPCError>) -> Void = { [weak self] result in
            guard let self, (!acceptLateResponse || self.generation == generation),
                  case .success(let response) = result, response.success, let data = response.data else { return }
            self.stats = Self.projectStats(data)
            self.updateContext()
            self.commit()
        }
        session.request(.getSessionStats, timeout: timeout,
                        onLateResponse: acceptLateResponse ? { receive(.success($0)) } : nil, completion: receive)
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

    /// Commands of pi's own built-in extensions that only work in its terminal UI: in RPC mode
    /// pi's handler answers "available in interactive mode" and does nothing else (llama.cpp's
    /// `/llama`). pi lists a built-in extension's file as `builtin:<name>` (`<inline:<name>>`
    /// before pi 0.99, which a host still on an older engine reports), so a user's own command of
    /// the same name is kept.
    static let terminalOnlyBuiltIns: Set<String> = ["llama"]

    /// Whether `path`, the `sourceInfo.path` pi lists a command under, is one of pi's own
    /// built-in extensions rather than a file.
    static func isBuiltInExtension(path: String?) -> Bool {
        guard let path else { return false }
        return path.hasPrefix("builtin:") || path.hasPrefix("<inline:")
    }

    /// `commands` from `allCommands`: nothing hidden lists everything, else the rest in pi's order.
    private func rebuildCommands() {
        let visible = allCommands?.filter { !hiddenCommands.contains($0.name) && (goalsEnabled || $0.name != "goal") }
        if visible != commands { commands = visible }
    }

    /// get_commands → capped, byte-limited list. Over-long names are dropped, descriptions clipped.
    /// A command no thread can run is left out: the host's own `/shepherd-retry`, and pi's
    /// terminal-only built-ins. An `argumentHint` pi sends is kept (pi 1.0 sends none;
    /// `readArgumentHints` reads a prompt template's from its file).
    static func projectCommands(_ value: JSONValue?) -> [NativeCommand] {
        guard let items = value?.arrayValue else { return [] }
        var result: [NativeCommand] = []
        for item in items {
            guard let name = item["name"]?.stringValue, !name.isEmpty, name.utf8.count <= NativeCommand.maxNameBytes,
                  name != retryCommand, name != "shepherd-goal" else { continue }
            if terminalOnlyBuiltIns.contains(name), isBuiltInExtension(path: item["sourceInfo"]?["path"]?.stringValue) { continue }
            var description = item["description"]?.stringValue
            if let text = description, text.utf8.count > NativeCommand.maxDescriptionBytes {
                description = String(decoding: Array(text.utf8.prefix(NativeCommand.maxDescriptionBytes)), as: UTF8.self)
            }
            result.append(NativeCommand(name: name, description: description, source: item["source"]?.stringValue,
                                        arguments: argumentHint(item["argumentHint"]?.stringValue) ?? (name == "goal" ? "<condition>" : nil)))
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
                guard let self, var commands = self.allCommands else { return }
                var changed = false
                for index in commands.indices where commands[index].arguments == nil {
                    if let hint = hints[commands[index].name] {
                        commands[index].arguments = hint
                        changed = true
                    }
                }
                if changed {
                    self.allCommands = commands
                    self.commit()
                    self.onCommandsListed?(commands)
                }
            }
        }
    }

    /// pi switched sessions (new_session / switch): nothing from the previous
    /// session may be acted on with the old generation.
    private func resetForNewSession() {
        cancelRecovery()
        historyPending = true
        generation = UUID().uuidString
        diagnosticTimings.removeAll(keepingCapacity: true)
        operations.removeAll()
        live.removeAll()
        toolStarts.removeAll()
        streamingCalls.removeAll()
        thinkingSpans.removeAll()
        thinkingByTimestamp.removeAll()
        timingByTimestamp.removeAll()
        request = nil
        requestKey = nil
        requestSeq = nil
        responseMarks.removeAll()
        stoppedCalls.removeAll()
        stoppedReplies.removeAll()
        widgets.removeAll()
        goal = nil
        goalsAvailable = false
        goalCommand = nil
        goalCommandFailure = nil
        onGoalChanged?(nil)
        history.removeAll()
        historyVersion += 1
        currentAssistant = nil
        historyUnread = false
        liveLeftOut = 0
        operationsByEntry.removeAll()
        questions.removeAll()
        commandNotices.removeAll()
        cancelWaitingInputs()
        // A question still open from the last session is not this one's to record.
        askedAt.removeAll()
        estimate = nil
        compactingRun = nil
        compactionNotes.removeAll()
        context = nil
        retryDispatch = nil
        checkpointRecovery = nil
        resetQueueForNewSession()
        signature = 0
        bumpRevision()
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
        let startupQuestions = questions
        let loadedQuestions = originStore.loadQuestions(sessionID: sessionID)
        let startupIDs = Set(startupQuestions.map(\.id))
        questions = Array((loadedQuestions.filter { !startupIDs.contains($0.id) } + startupQuestions).suffix(ThreadOriginStore.questionLimit))
        if !startupQuestions.isEmpty { saveOrigins() }
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
            liveLeftOut += 1
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
        let existing = live.firstIndex(where: { $0.kind == .assistant(key) })
        value.timing = existing.flatMap { live[$0].value.timing } ?? raw.timestamp.flatMap { timingByTimestamp[$0] } ?? (key == requestKey ? request : nil)
        let item = LiveItem(kind: .assistant(key), value: value, raw: raw, ended: ended)
        if let index = existing {
            live[index] = item
        } else {
            live.append(item)
            trimLive()
        }
    }

    private func upsertTool(id: String, name: String, args: JSONValue?, content: [RPCContentBlock], isError: Bool?, status: String,
                            projectAction: NativeProjectAction? = nil, argumentBytes: Int? = nil) {
        let index = live.firstIndex { $0.kind == .tool(id) }
        let previous = index.map { live[$0].value }
        var value = Self.project(
            entryID: "provisional:tool:\(id)",
            message: RPCMessage(role: "toolResult", content: content, toolName: name, toolCallId: id, isError: isError, projectAction: projectAction),
            args: args
        )
        if value.argumentsText == nil { value.argumentsText = previous?.argumentsText }
        value.status = status
        // Only while the model writes the call: once it runs, its arguments are whole.
        value.argumentBytes = status == "streaming" ? argumentBytes ?? previous?.argumentBytes : nil
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

    // MARK: - Response timing

    /// Server queue: a moment of a model request as the agent's pi reported it (the status
    /// extension's provider hooks). The extension socket and pi's stdout are two channels, so a
    /// mark may land after the stream it describes has started; `seq` keeps it on its request.
    /// `at` is pi's clock, which is this host's.
    func recordResponseMark(_ mark: ResponseTimingMark, seq: Int, at: Double) {
        guard at.isFinite, at > 0, seq > 0 else { return }
        if responseMarks[seq] == nil, responseMarks.count >= Self.timingLimit,
           let oldest = responseMarks.keys.min() { responseMarks[oldest] = nil }
        var marks = responseMarks[seq] ?? ResponseMarks()
        switch mark {
        case .sent:
            guard marks.timing.sentAt == nil else { return }
            marks.timing.sentAt = at
            if seq >= (requestSeq ?? 0) {
                requestSeq = seq
                // Only an unbound live message may provisionally take a send. The message
                // correlation below corrects it even if stdout is a whole request ahead.
                if var current = request, current.sentAt == nil, requestKey != nil {
                    current.sentAt = at
                    request = current
                } else {
                    request = marks.timing
                    requestKey = nil
                }
            }
        case .headers, .firstEvent:
            Self.apply(mark, at: at, to: &marks.timing)
            if seq == requestSeq, var current = request {
                Self.apply(mark, at: at, to: &current)
                request = current
            }
        case .message:
            marks.timestamp = at
        }
        responseMarks[seq] = marks
        if let time = marks.timestamp {
            let index = live.firstIndex { $0.value.role == "assistant" && $0.raw?.timestamp == time }
            let historyIndex = history.firstIndex { $0.role == "assistant" && $0.timestamp == time }
            var timing = index.flatMap { live[$0].value.timing } ?? historyIndex.flatMap { history[$0].timing }
                ?? timingByTimestamp[time] ?? NativeResponseTiming()
            // An evicted/incomplete correlation record must not erase already measured marks.
            timing.sentAt = marks.timing.sentAt ?? timing.sentAt
            timing.headersAt = marks.timing.headersAt ?? timing.headersAt
            if let first = marks.timing.firstEventAt { Self.apply(.firstEvent, at: first, to: &timing) }
            if let index {
                live[index].value.timing = timing
                if !live[index].ended, seq == requestSeq, case .assistant(let key) = live[index].kind {
                    request = timing
                    requestKey = key
                }
            }
            if let historyIndex, history[historyIndex].timing != timing {
                // History may have replaced the provisional row before the socket was read.
                // Its observer invalidates encoded row sizes; the version notifies clients.
                history[historyIndex].timing = timing
                historyVersion += 1
            }
            if timingByTimestamp[time] == nil, timingByTimestamp.count >= Self.timingLimit,
               let oldest = timingByTimestamp.keys.min() { timingByTimestamp[oldest] = nil }
            timingByTimestamp[time] = timing
            if timing.endedAt != nil, seq == requestSeq { request = nil; requestKey = nil }
        } else {
            applyRequestToLive()
        }
        commit()
    }

    /// A headers or first-event mark: the first headers stand, and the earlier first event (pi's
    /// stream, as this host read it, may have shown one first).
    static func apply(_ mark: ResponseTimingMark, at: Double, to timing: inout NativeResponseTiming) {
        switch mark {
        case .sent, .message: break
        case .headers: if timing.headersAt == nil { timing.headersAt = at }
        case .firstEvent: timing.firstEventAt = min(timing.firstEventAt ?? at, at)
        }
    }

    /// pi started an assistant message: the request in flight made it. One that started before
    /// its send was reported (or with no hooks at all) is timed from here on without a send.
    private func requestStarted(key: Int, timestamp: Double? = nil) {
        if let timestamp, let linked = responseMarks.first(where: { $0.value.timestamp == timestamp }) {
            // The socket may be ahead by several requests. Never consume a newer send for
            // the older assistant whose stdout is only now being read.
            if linked.key == requestSeq { requestKey = key; request = linked.value.timing }
            return
        }
        if request == nil || requestKey != nil {
            request = NativeResponseTiming()
            requestSeq = nil
        }
        requestKey = key
    }

    /// The first event, thinking and visible text of the response, as pi's stream showed them.
    /// Once each is set this is a few comparisons per delta: no clock is read.
    private func observeStream(_ delta: RPCAssistantDelta) {
        guard let key = currentAssistant, let index = live.firstIndex(where: { $0.kind == .assistant(key) }),
              var timing = live[index].value.timing else { return }
        let thinking = delta.type == "thinking_start" || delta.type == "thinking_delta"
        let text = delta.type == "text_delta" && timing.firstTextAt == nil && (delta.delta ?? "").contains { !$0.isWhitespace }
        let mixed = timing.mixedPhases != true && (delta.type == "toolcall_start" || (thinking && timing.firstTextAt != nil))
        guard timing.firstEventAt == nil || (thinking && timing.firstThinkingAt == nil) || text || mixed else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if timing.firstEventAt == nil { timing.firstEventAt = now }
        if thinking, timing.firstThinkingAt == nil { timing.firstThinkingAt = now }
        if text { timing.firstTextAt = now }
        if mixed { timing.mixedPhases = true }
        live[index].value.timing = timing
        if requestKey == key { request = timing }
    }

    /// The response ended: its timing joins the message for good, with the usage and ids the
    /// provider reported.
    private func requestEnded(_ message: RPCMessage) {
        guard let key = currentAssistant, let index = live.firstIndex(where: { $0.kind == .assistant(key) }),
              var timing = live[index].value.timing else { return }
        timing.endedAt = Date().timeIntervalSince1970 * 1000
        timing.inputTokens = message.usage?.prompt
        timing.outputTokens = message.usage?.output.flatMap { Int(reportedCount: $0) }.flatMap { $0 > 0 ? $0 : nil }
        timing.provider = message.provider.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
        timing.model = message.model.flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        live[index].value.timing = timing
        if requestKey == key { request = timing }
        if let time = message.timestamp {
            if timingByTimestamp.count >= Self.timingLimit, let oldest = timingByTimestamp.keys.min() { timingByTimestamp[oldest] = nil }
            timingByTimestamp[time] = timing
        }
    }

    /// After `upsertAssistant` used it for the ended message: nothing is in flight.
    private func requestDone() {
        if requestKey == currentAssistant {
            request = nil
            requestKey = nil
        }
    }

    /// The live message the request made shows its timing as it changes.
    private func applyRequestToLive() {
        guard let key = requestKey, let index = live.firstIndex(where: { $0.kind == .assistant(key) }),
              live[index].value.timing != request else { return }
        live[index].value.timing = request
    }

    /// The request in flight, for the thread's live line; nil when none is, or the agent is idle.
    var liveRequest: NativeResponseTiming? {
        running && request?.endedAt == nil ? request : nil
    }

    // MARK: - Tool calls being written

    /// A tool call is a row from the moment the model names it, so the thread shows it ("Writing
    /// src/big.txt") while its arguments stream instead of a finished paragraph and nothing
    /// moving. The row carries only the fields an activity line names; `tool_execution_start`
    /// makes the same row the running call, with its complete arguments. pi 1.0.0's events:
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
                  case .toolCall(let id, let name, _) = message.content[index], streamingCalls[id] != nil else { return }
            let before = streamingCalls[id]?.shownBytes
            let grew = streamingCalls[id]?.append(delta.delta ?? "") == true
            let shown = streamingCalls[id]?.shownBytes
            // The row changes when a field it names grew or its count reached the next step; most
            // fragments do neither, and cost only their own length.
            guard grew || shown != before else { return }
            upsertTool(id: id, name: name, args: streamingCalls[id]?.arguments, content: [], isError: nil, status: "streaming", argumentBytes: shown)
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
            if kind == .input, Self.bytes(dialog) <= Self.dialogBytes, dialog.placeholder == "Say anything",
                      let suffix = dialog.title.range(of: "\n\nOptions:\n", options: .backwards),
                      let choices = try? JSONDecoder().decode([String].self, from: Data(dialog.title[suffix.upperBound...].utf8)),
                      !choices.isEmpty, choices.count <= 16, Set(choices).count == choices.count,
                      choices.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 }),
                      dialog.title[..<suffix.lowerBound].utf8.count <= 2000 {
                // project_question uses a supported input, not a select accepting unoffered values.
                // Normalize its human-readable fallback hints before persisting or presenting it.
                dialog.options = choices
                dialog.title = String(dialog.title[..<suffix.lowerBound])
                // Older clients still draw the offered hints above their ordinary input field.
                dialog.message = choices.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            }
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
            if key == "shepherd.goal" {
                guard goalsEnabled else { return }
                guard let text else {
                    goalsAvailable = false
                    if goal != nil { goal = nil; onGoalChanged?(nil) }
                    return
                }
                guard text.hasPrefix("SHEPHERD_GOAL:") else { return }
                let next = NativeGoal.readWidget(text)
                guard next != nil || text == "SHEPHERD_GOAL:null" else { return }
                goalsAvailable = true
                if next != goal {
                    let prior = goal
                    goal = next
                    // Fleet/sidebar state does not carry a live clock or token counter.
                    if prior?.id != next?.id || prior?.state != next?.state || prior?.reason != next?.reason {
                        onGoalChanged?(next)
                    }
                }
                return
            }
            // Some extensions publish machine payloads for their own TUI component
            // rather than human-readable text. Those are not for people.
            if let text, Self.isMachineWidget(text) { setWidget(nil, key: key); return }
            setWidget(text.map { NativeThreadWidget(namespace: "pi", key: key, kind: .text, text: $0) }, key: key)
        case "notify":
            // A TUI toast ("Ponytail loaded: full", "Task queued"). The native thread has no
            // toast surface and the message rarely matters after the moment; dropping it beats
            // parking it above the composer. One the user's own command is answering is what that
            // command said back, and the thread keeps it.
            recordNotify(request)
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
        _ = onRecoveryChanged?()
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
        hasher.combine(goal)
        hasher.combine(goalsAvailable)
        hasher.combine(historyUnread)
        hasher.combine(liveLeftOut)
        hasher.combine(running || retryDispatch != nil)
        hasher.combine(checkpointRecovery)
        hasher.combine(model)
        hasher.combine(thinking)
        hasher.combine(thinkingLevels)
        hasher.combine(serviceTier)
        hasher.combine(serviceTiers)
        hasher.combine(piSessionID)
        hasher.combine(openingPrompt?.id)
        hasher.combine(stats)
        hasher.combine(context)
        hasher.combine(commandsHash)
        hasher.combine(subagentsHash)
        hasher.combine(turnChangesHash)
        hasher.combine(retry)
        hasher.combine(liveRequest)
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
        // What this snapshot shortens or could not read: older history is not one of them (it is
        // `olderCursor`'s), and a too large question says so itself in the dock.
        let clips = NativeThreadClips(history: historyUnread, live: liveLeftOut)
        let initializing = !isServable
        var base = NativeThreadSnapshot(
            piSessionID: initializing ? "" : (piSessionID ?? ""), generation: generation, revision: revision, running: running || retryDispatch != nil,
            model: model, thinking: thinking, thinkingLevels: thinkingLevels,
            supportedActions: initializing ? ["answer"] : Self.supportedActions + (goalsAvailable ? ["goal"] : []) + (checkpointRecovery?.version == 1 ? ["checkpointRecovery"] : []), dialogsSupported: true,
            dialogs: [], widgets: snapshotWidgets, messages: [], provisional: [],
            clipped: !clips.isEmpty,
            runtime: "rpc", stats: stats, commands: commands, subagents: snapshotSubagents, context: context,
            turnChanges: snapshotTurnChanges, retry: retry,
            serviceTier: serviceTier.rawValue, serviceTiers: serviceTiers.map(\.rawValue), goal: goal,
            clips: clips.isEmpty ? nil : clips, liveRequest: liveRequest,
            initializing: initializing ? true : nil, checkpointRecovery: initializing ? nil : checkpointRecovery
        )
        // The rest encodes without the queue, which adds `,"queue":` and its cached size.
        let queue = queueValue
        let baseBytes = measured(base) + Self.queueFieldBytes + queueBytes(queue)
        base.queue = queue
        let sizedDialogs = zip(dialogs, dialogSizes()).map { Sized(value: $0, bytes: $1) }
        var active = activeEntries()
        if initializing, let opening = openingPrompt {
            let row = NativeThreadMessage.pendingSend(operationID: opening.id, text: opening.text, images: opening.images.count, timestamp: opening.at)
            active.insert(Sized(value: row, bytes: Self.bytes(row)), at: 0)
        }
        let budgeted = Self.budget(
            base, baseBytes: baseBytes, active: active, dialogs: sizedDialogs,
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
            let messageBytes = bytes(message)
            size += messageBytes + 1
            // What does not fit is an older page (`olderCursor`), not clipped.
            if size > snapshotLimit, !value.messages.isEmpty || messageBytes + bytes(message.entryID) > textLimit * 8 { break }
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
    /// page at most. A base that weighs more than the snapshot may never leaves the live rows
    /// less than `activeReserve` nor history less than `historyReserve`. The decisions are the
    /// ones encoding the growing snapshot made; returns the snapshot and its exact encoded size.
    static func budget(
        _ base: NativeThreadSnapshot,
        baseBytes: Int,
        active: [Sized<NativeThreadMessage>],
        dialogs: [Sized<NativeThreadDialog>],
        historyEnd: Int,
        history: (Int) -> Sized<NativeThreadMessage>
    ) -> (snapshot: NativeThreadSnapshot, bytes: Int) {
        func list(_ count: Int, _ sum: Int) -> Int { count == 0 ? 0 : sum + count - 1 }
        // What this snapshot leaves out of the live run or the questions joins `clips`; `clipped`
        // and `clips` turn on together, and what they add to the encoded size is counted in `clipDelta`.
        var clips = base.clips ?? NativeThreadClips()
        let clipsField = ",\"clips\":".utf8.count
        let baseClips = base.clips.map { Self.bytes($0) + clipsField } ?? 0
        var clipDelta = 0
        func clipped() {
            let flag = (base.clipped || !clips.isEmpty) == base.clipped ? 0 : -1
            clipDelta = (clips.isEmpty ? 0 : Self.bytes(clips) + clipsField) - baseClips + flag
        }
        var dropped = Set<Int>()
        var activeSum = active.reduce(0) { $0 + $1.bytes }
        var dialogCount = dialogs.count
        var dialogSum = dialogs.reduce(0) { $0 + $1.bytes }
        func size() -> Int {
            baseBytes + clipDelta + list(active.count - dropped.count, activeSum) + list(dialogCount, dialogSum)
        }
        // Live content may use up to `activeLimit` of the snapshot, but a heavy base never leaves it
        // less than `activeReserve`, or a long thread's run would draw nothing while it streams.
        let activeCap = max(activeLimit, baseBytes + activeReserve)
        var next = 0
        while size() > activeCap {
            while next < active.count, active[next].value.role == "user" { next += 1 }
            guard next < active.count else { break }
            activeSum -= active[next].bytes
            dropped.insert(next)
            next += 1
            clips.live += 1
            clipped()
        }
        while size() > activeCap, dialogCount > 0 {
            dialogCount -= 1
            dialogSum -= dialogs[dialogCount].bytes
            clips.questions += 1
            clipped()
        }
        // Each message is counted with a comma, as when the growing snapshot was encoded. History
        // always has `historyReserve` to fill. Keep at least one bounded message even if JSON
        // escaping makes it exceed that reserve, otherwise there is no row or paging cursor.
        // Unbounded producer IDs are not admitted this way: leave room for the cursor and frame.
        var budgeted = size()
        let limit = max(snapshotLimit, budgeted + historyReserve)
        var page: [Sized<NativeThreadMessage>] = []
        var index = historyEnd - 1
        while index >= 0 {
            let entry = history(index)
            budgeted += entry.bytes + 1
            // Older history that does not fit is a page away (`olderCursor`), not clipped.
            if budgeted > limit, !page.isEmpty || entry.bytes + bytes(entry.value.entryID) > textLimit * 8 { break }
            page.append(entry)
            index -= 1
            if page.count == pageSize { break }
        }
        page.reverse()
        var value = base
        value.provisional = active.indices.filter { !dropped.contains($0) }.map { active[$0].value }
        value.dialogs = dialogs[..<dialogCount].map(\.value)
        value.messages = page.map(\.value)
        value.clips = clips.isEmpty ? nil : clips
        value.clipped = base.clipped || !clips.isEmpty
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
    /// unless their extension marked them display. A model-only completion report is the
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
        images: [String: ThreadImages.Meta] = [:],
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
        return shownHistory(messages).flatMap { entryID, message -> [NativeThreadMessage] in
            let args = message.role == "toolResult" ? message.toolCallId.flatMap { arguments[$0] } : nil
            var value = project(entryID: entryID, message: message, args: args, sentReferences: sentReferences[entryID], images: images)
            if let id = message.toolCallId, message.role == "toolResult" { value.startedAt = callTimes[id] }
            adjust(&value, message)
            if let origin = value.origin { value.origin = clipped(origin) }
            return [value] + nestedRows(message, parentEntryID: entryID, adjust: adjust)
        }
    }

    /// The messages history shows, in order, each with the entry id history gives it. The one place that decides which messages
    /// are hidden and how the rest are numbered: `projectHistory` and `ThreadImages.find` both read it, so an image id the
    /// snapshot offered always finds its message again (a hidden message with a repeated timestamp cannot shift the numbers).
    static func shownHistory(_ messages: [RPCMessage]) -> [(entryID: String, message: RPCMessage)] {
        var seen: [String: Int] = [:]
        return chronological(messages).enumerated().compactMap { index, message in
            // pi's structured system prompt rides in the message list; the thread never shows it.
            if message.role == "system" { return nil }
            if message.role == "custom" && message.display != true { return nil }
            if message.role == "custom" && message.customType == "shepherd-child" { return nil }
            return (historyEntryID(message, index: index, seen: &seen), message)
        }
    }

    /// Native metadata keeps invocation order and arguments; our display-only details keep
    /// bounded output. Missing output in an older session is not an empty successful result.
    private static func nestedRows(_ message: RPCMessage, parentEntryID: String,
                                   adjust: (inout NativeThreadMessage, RPCMessage) -> Void = { _, _ in }) -> [NativeThreadMessage] {
        guard message.role == "toolResult", let nested = message.nestedCalls else { return [] }
        let details = message.details?["calls"]?.arrayValue ?? []
        let saved = Dictionary(details.prefix(256).compactMap { value -> (String, JSONValue)? in
            value["id"]?.stringValue.map { ($0, value) }
        }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        return nested.calls.compactMap { call in
            guard !call.id.isEmpty, !call.name.isEmpty, call.id != message.toolCallId, seen.insert(call.id).inserted else { return nil }
            let detail = saved[call.id]
            let stopped = call.status == "unfinished" || detail?["status"]?.stringValue == "cancelled"
            var text = detail?["output"]?.stringValue ?? call.error ?? "Pi did not save this nested call's output."
            if detail?["outputTruncated"]?.boolValue == true {
                text += "\nOutput excerpt limited to 8,192 characters per call and 32,768 per script. Remaining output was not saved."
            }
            if call.argumentsBytes != nil { text += "\nPi omitted this call's arguments because they exceeded its metadata limit." }
            let raw = RPCMessage(role: "toolResult", content: text.isEmpty ? [] : [.text(text)], toolName: call.name,
                                 toolCallId: call.id, isError: call.status == "error", stopReason: stopped ? "aborted" : "complete",
                                 timestamp: detail?["timestamp"]?.doubleValue)
            var row = project(entryID: "\(parentEntryID):nested:\(call.id)", message: raw, args: call.arguments)
            row.startedAt = detail?["startedAt"]?.doubleValue
            adjust(&row, raw)
            return row
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
    /// `images` is what `ThreadImages.table(for:)` read of the history this message is in, keyed by entry and position. The projection only
    /// looks an image up: it never decodes or hashes one (it runs on the thread's queue), and an image with no entry, as in a live row, whose
    /// id history does not yet number, is named by nothing and stays the "Image" chip until the history is read again.
    static func project(entryID: String, message: RPCMessage, args: JSONValue? = nil, sentReferences: [String]? = nil,
                        images: [String: ThreadImages.Meta] = [:]) -> NativeThreadMessage {
        // A bounded 20 × 500 worker plan plus its arguments can exceed the ordinary 16 KiB
        // row (JSON escapes use six bytes). Keep the full report within the existing frame budget.
        var remaining = message.role == "toolResult" && message.toolName == "project_plan" ? 128 * 1024 : textLimit
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
        var result = NativeThreadMessage(entryID: entryID, role: message.role.isEmpty ? "custom" : message.role, blocks: [], customType: message.customType)
        result.projectAction = message.projectAction
        if let toolName = message.toolName { result.toolName = clip(toolName) }
        if let toolCallID = message.toolCallId { result.toolCallID = clip(toolCallID) }
        if let args { result.argumentsText = clip(json(Self.fitting(args, within: remaining))) }
        // A design view record the viewer's message carried is pi's to read, not the thread's.
        var fenced = message.role == "user"
        var goalDetailsAdded = false
        var imageIndex = 0
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
                if !goalDetailsAdded, message.role == "custom", message.customType == "shepherd.goal.check", let details = message.details {
                    goalDetailsAdded = true
                    if let model = details["checkedBy"]?.stringValue {
                        let label = "Checked by " + String(model.prefix(256)).replacingOccurrences(of: #"[\p{Cc}\p{Zl}\p{Zp}]"#, with: " ", options: .regularExpression)
                        if let marker = shown.range(of: "\n\nDetails:\n") { shown.insert(contentsOf: "\n" + label, at: marker.lowerBound) }
                        else { shown += "\n" + label }
                    }
                    var diagnostic: [String] = []
                    if let feedback = details["verdict"]?["reason"]?.stringValue { diagnostic.append("Evaluator feedback:\n" + feedback) }
                    if let error = details["error"]?.stringValue { diagnostic.append(error) }
                    let missing = details["missingEvidence"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if !missing.isEmpty { diagnostic.append("Missing evidence:\n" + missing.joined(separator: "\n")) }
                    let proof = details["verdict"]?["evidence"]?.arrayValue?.compactMap { row -> String? in
                        guard let quote = row["quote"]?.stringValue else { return nil }
                        return (row["entryId"]?.stringValue.map { $0 + ": " } ?? "") + quote
                    } ?? []
                    if !proof.isEmpty { diagnostic.append("Tool evidence:\n" + proof.joined(separator: "\n")) }
                    if !diagnostic.isEmpty {
                        shown += (shown.contains("\n\nDetails:\n") ? "\n\n" : "\n\nDetails:\n") + diagnostic.joined(separator: "\n\n")
                    }
                }
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
                // Metadata only, never the bytes: the client fetches them (`NativeThreadRequest.image`).
                var block = NativeThreadBlock(kind: .unsupportedImage, text: clip("[Image unavailable in native thread]"))
                if let meta = images[ThreadImages.key(entryID: entryID, index: imageIndex)] {
                    block.imageID = ThreadImages.id(entryID: entryID, index: imageIndex, meta: meta)
                    block.mimeType = meta.mimeType
                    block.width = meta.width
                    block.height = meta.height
                    block.byteCount = meta.byteCount
                }
                imageIndex += 1
                result.blocks.append(block)
            case .toolCall:
                // The tool row (name, arguments, result) is the call's surface; dumping the
                // call JSON as prose duplicated it.
                break
            case .unknown:
                break
            }
        }
        if message.nestedCalls?.complete == false {
            result.blocks.append(NativeThreadBlock(kind: .text, text: clip("Pi's nested call log is incomplete; some calls or arguments were not saved.")))
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

    /// `args` that fit `limit` bytes of JSON: when they do not, each long string of the call (a `write`'s `content`) is cut to
    /// `argumentStringBytes`, so the call stays valid JSON and its short fields (the `path`, which sorts after `content`) survive; the
    /// cut `content` leaves its true line count in `contentLines`. Clipping the encoded text instead would end it mid-string and lose
    /// the path of exactly the big files an activity line, the Changes card and the Artifacts tab name.
    static func fitting(_ args: JSONValue, within limit: Int) -> JSONValue {
        guard case .object(var fields) = args, json(args).utf8.count > limit else { return args }
        for (key, value) in fields {
            guard case .string(let text) = value, text.utf8.count > argumentStringBytes else { continue }
            fields[key] = .string(clippedText(text, limit: argumentStringBytes))
            if key == "content" {
                fields["contentLines"] = .number(Double(text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)))
            }
        }
        return .object(fields)
    }

    /// The most a long string argument keeps in a row that has to be clipped.
    static let argumentStringBytes = 1024

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
