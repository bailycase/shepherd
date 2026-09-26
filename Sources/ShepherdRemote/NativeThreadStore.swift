import Foundation
import Observation
import ShepherdProtocol

/// Which pi session a thread shows: a new session or a new generation of it is a different
/// thread (history, echoes, and questions belong to one).
public struct NativeThreadSession: Hashable, Sendable {
    public var piSessionID: String
    public var generation: String

    public init(piSessionID: String, generation: String) {
        self.piSessionID = piSessionID
        self.generation = generation
    }

    public var key: String { piSessionID + ":" + generation }
}

/// One turn as the thread lists it: the turn, and for a reply its presentation and the
/// prompt that opened it. Equatable, so a row that did not change is not redrawn.
public struct NativeThreadRow: Equatable, Identifiable, Sendable {
    public var turn: NativeTurn
    /// Replies only.
    public var presentation: NativeTurnPresentation?
    /// True while this reply is the one streaming.
    public var live: Bool
    /// The opening prompt's text (a reply's Retry) and time (its footer).
    public var promptText: String?
    public var startedAt: Double?
    /// The turn the host recorded for this reply (`NativeThreadSnapshot.turnChanges`): its
    /// changes card, with Undo and Redo.
    public var recordedTurn: ChangesTurn? = nil
    /// A finished reply's "Edited N files" card for the touch thread: the host's record of its
    /// turn (`recordedTurn`), else its edit calls.
    public var changes: NativeChangesCard? = nil

    public var id: String { turn.id }
    public var isUser: Bool { turn.isUser }
}

/// A native thread for one agent: polls the host's snapshots, keeps the optimistic echoes of
/// sends, and derives what the thread draws (rows, subagent placements) once per change, so
/// views read stored values and typing in the composer invalidates only the composer.
@MainActor
@Observable
public final class NativeThreadStore {
    public typealias Request = @MainActor (NativeThreadRequest) async throws -> NativeThreadResult
    /// History from disk to show until pi answers (`preview(_:)`); nil when there is none.
    public typealias Preview = @Sendable () async -> NativeThreadSnapshot?
    /// Waits out one poll interval; throws once the run loop's task is cancelled.
    public typealias Pause = @Sendable (Duration) async throws -> Void

    public private(set) var snapshot: NativeThreadSnapshot?
    public private(set) var messages: [NativeThreadMessage] = []
    public private(set) var olderCursor: String? { didSet { threadVersion &+= 1 } }
    public private(set) var loadingOlder = false { didSet { threadVersion &+= 1 } }
    public private(set) var ready = false { didSet { bothVersions() } }
    /// The agent's pi is starting (`native_starting`): not ready, and not an error. The thread
    /// polls quickly, a send waits for it (see `acceptsSend`), and a slow start is said in the
    /// composer (`awaitingPi`). A pi that has not started within `startingLimit` becomes a
    /// `loadError`.
    public private(set) var starting = false { didSet { bothVersions() } }
    /// The thread shows history read from pi's session file while pi starts (`preview(_:)`),
    /// not a snapshot pi served: nothing can be done with it yet, and pi's first snapshot
    /// replaces it in place (its entries carry the ids pi's will).
    public private(set) var previewing = false { didSet { bothVersions() } }
    public private(set) var busy = false { didSet { bothVersions() } }
    public private(set) var loadError: String? { didSet { bothVersions() } }
    public private(set) var notice: String? { didSet { chromeVersion &+= 1 } }
    public private(set) var sentCount = 0
    /// Whether the last accepted send waits in Up next (a follow-up sent while pi works) rather
    /// than going into the thread now. Set with `sentCount`, and read when it changes: only a
    /// send that goes in now brings the reader to the tail.
    @ObservationIgnored public private(set) var lastSendQueued = false
    /// Optimistic echoes of accepted sends (entryID "pending:<operationID>", status "pending").
    /// A host that holds the queue (`NativeQueue`) shows its own pending row under the same id,
    /// so an echo lasts only until the host's next snapshot. From an older host, an echo is
    /// "queued" when it was sent as a follow-up while a turn ran, and leaves once pi persists a
    /// user message with the same text, or when the session changes.
    public private(set) var pending: [NativeThreadMessage] = []
    /// The host's queue as this client shows it: the last snapshot's, with this client's own
    /// changes applied at once until the host's next snapshot confirms them. Empty from a host
    /// without a queue (`supportsQueue`). The composer draws it, so it counts as chrome
    /// (`chromeVersion`): what changed while the thread was away lands without motion.
    public private(set) var queue: [NativeQueuedMessage] = [] { didSet { chromeVersion &+= 1 } }
    /// How the queue goes when pi settles, as the host reports it (or as this client just set).
    public private(set) var queueMode: NativeQueueMode? { didSet { chromeVersion &+= 1 } }
    /// The queue waits for the user (pi was stopped, or a turn or delivery failed).
    public private(set) var queuePaused = false { didSet { chromeVersion &+= 1 } }
    /// Why the host paused the queue on its own.
    public private(set) var queueNotice: String? { didSet { chromeVersion &+= 1 } }
    /// `snapshot.running` held true for 400 ms after it drops, so tool boundaries never flicker
    /// the tail indicator or the Stop button.
    public private(set) var settledRunning = false
    public var draft = ""
    public var delivery: NativeThreadDelivery = .followUp

    /// History, then the optimistic user echo, then the live (provisional) reply to it. The echo
    /// must precede provisional rows: the reply to a sent message streams below it, and the
    /// order must not flip once pi persists the message (that flip re-laid the whole tail). A
    /// queued follow-up waits below the reply still streaming, which is not its answer.
    public private(set) var displayedMessages: [NativeThreadMessage] = []
    public private(set) var turns: [NativeTurn] = []
    public private(set) var rows: [NativeThreadRow] = [] { didSet { threadVersion &+= 1 } }
    /// Each reply's subagents, where their spawn calls were (keyed by turn id).
    public private(set) var placements: [String: NativeSubagentPlacement] = [:] { didSet { threadVersion &+= 1 } }
    public private(set) var subagents: [NativeSubagent] = [] { didSet { chromeVersion &+= 1 } }
    /// The subagent tray above the composer, while it shows (`nativeTrayRuns`).
    public private(set) var tray: NativeSubagentTray? { didSet { chromeVersion &+= 1 } }
    /// When the prompt that opened the current turn was sent (ms). A queued follow-up has not
    /// opened a turn yet; nil while the newest prompt is an echo.
    public private(set) var lastPromptAt: Double?

    // What the chrome draws, each its own property (derived in `deriveChrome`). A snapshot is
    // one value, so a view that reads any part of it redraws on every streamed chunk; these
    // change only when they do, so a chunk redraws the thread and its live row, and a poll
    // that moves only the context count redraws only the toolbar's counters.

    /// The snapshot's pi session, nil before the first one.
    public private(set) var session: NativeThreadSession? { didSet { bothVersions() } }
    public private(set) var dialogs: [NativeThreadDialog] = [] { didSet { chromeVersion &+= 1 } }
    public private(set) var dialogsSupported = true { didSet { threadVersion &+= 1 } }
    /// Extension widgets of the kinds this client draws.
    public private(set) var widgets: [NativeThreadWidget] = [] { didSet { chromeVersion &+= 1 } }
    public private(set) var commands: [NativeCommand] = [] { didSet { chromeVersion &+= 1 } }
    public private(set) var model: String? { didSet { chromeVersion &+= 1 } }
    public private(set) var thinking: String? { didSet { chromeVersion &+= 1 } }
    /// The levels the thinking menu offers: pi's for the current model, or
    /// `NativeThinkingLevel.fallback` from a host that does not say.
    public private(set) var thinkingLevels: [NativeThinkingLevel] = NativeThinkingLevel.fallback { didSet { chromeVersion &+= 1 } }
    public private(set) var stats: NativeThreadStats?
    /// The ring beside Send; nil from a host that reports no context (no ring). It changes
    /// only when the usage does, so the ring redraws alone and never with a streamed chunk.
    public private(set) var contextMeter: NativeContextMeter? { didSet { chromeVersion &+= 1 } }
    /// What the ring's details show, derived with it.
    public private(set) var contextDetails: NativeContextDetails?
    @ObservationIgnored private var contextInputs: (context: NativeThreadContext?, model: String?, replying: Bool, unset: Bool) = (nil, nil, false, true)
    /// Which compactions in the thread show what the agent kept (Show summary).
    public let compactions = NativeCompactionExpansion()
    /// Which errors in the thread show their Details, and which folded ones were opened.
    public let errors = NativeTurnErrorExpansion()
    public private(set) var supportedActions: Set<String> = [] { didSet { bothVersions() } }
    public private(set) var clipped = false { didSet { threadVersion &+= 1 } }
    /// The thread's own running state: `settledRunning` unless the connection is lost (a
    /// cached running snapshot is not running). The live "Thinking…" and Stop read it.
    public private(set) var running = false { didSet { bothVersions() } }
    /// What the host last reported, without the settling `running` adds.
    public private(set) var hostRunning = false
    /// The thread's last reply ended in an error and nothing has started since: the agent
    /// reads failed (Status language) until its next turn.
    public private(set) var lastTurnFailed = false { didSet { chromeVersion &+= 1 } }
    /// pi works with nothing moving in the thread, so the thread ends in the live "Thinking…"
    /// line (LiveText): between tools (the live turn's `betweenTools`), or before pi's reply has
    /// a row. False while a question waits (the composer shows it). A running call is its own
    /// live line, and a reply being written is its own indicator; a pi starting again says so in
    /// the composer (`awaitingPi`), never here.
    public private(set) var showsThinking = false { didSet { threadVersion &+= 1 } }
    /// User turns in the thread (the toolbar counts them once the whole history is loaded).
    public private(set) var userTurnCount = 0
    public private(set) var hasSubagents = false

    /// "piSessionID:generation", nil before the first snapshot.
    public var sessionKey: String? { session?.key }

    // MARK: Catching up

    /// Where the thread stood once it caught up after coming on screen: the versions of what
    /// its rows and its chrome showed then.
    public struct CatchUp: Equatable, Sendable {
        public let thread: Int
        public let chrome: Int
    }

    /// Set, in the same update, by the first pull that lands after `run` starts; nil from
    /// `suspend` (the thread went off screen) until then. Everything up to these versions
    /// arrived while the thread was away or loading and lands without motion; what changes
    /// after moves as usual (`CatchUpGate`). Not observed: it changes no pixel itself, so
    /// catching up costs no pass of its own.
    @ObservationIgnored public private(set) var catchUp: CatchUp?
    /// Bumped whenever what the thread's rows show changes (rows, the live "Thinking…", the
    /// notices, readiness), and what the composer and the toolbar show (`chromeVersion`). Not
    /// observed: views read them as they render.
    @ObservationIgnored public private(set) var threadVersion = 0
    @ObservationIgnored public private(set) var chromeVersion = 0

    private func bothVersions() {
        threadVersion &+= 1
        chromeVersion &+= 1
    }

    /// The first pull since `run` started has landed.
    private func caughtUp() {
        if catchUp == nil { catchUp = CatchUp(thread: threadVersion, chrome: chromeVersion) }
    }

    /// How long `starting` may last before it is reported as an error. Polling continues, so
    /// a pi that answers later still clears it.
    public let startingLimit: Duration

    /// How `run` waits between polls. Tests pass one that never ends, to drive every refresh
    /// themselves.
    private let pause: Pause

    /// A pushed revision (`revisionAvailable`) ends the poll loop's pause early, but the loop
    /// pulls at most this often, so a streaming turn lands at about 30 Hz.
    nonisolated public static let pushedPullSpacing: Duration = .milliseconds(33)
    @ObservationIgnored private let pollWake = PollWake()
    @ObservationIgnored private var lastPull: ContinuousClock.Instant?

    public init(startingLimit: Duration = .seconds(60), pause: @escaping Pause = { try await Task.sleep(for: $0) }) {
        self.startingLimit = startingLimit
        self.pause = pause
    }

    @ObservationIgnored private var request: Request? {
        didSet { if (request != nil) != (oldValue != nil) { onLiveChange?(request != nil) } }
    }
    /// Told when the poll loop starts (true: the thread is on screen) and when it ends, so the
    /// host pushes revisions only for threads on screen (`revisionAvailable`).
    @ObservationIgnored public var onLiveChange: ((Bool) -> Void)?
    /// A design agent's chat: what the design screen shows as a message leaves
    /// (`DesignViewRecord`), sent with it where the host takes one (`designContext`).
    @ObservationIgnored public var designContext: (() -> DesignViewRecord?)?
    /// The poll loop runs: the thread is on screen, and a pushed revision pulls it.
    public var isLive: Bool { request != nil }
    /// When the current stretch of `native_starting` answers began.
    @ObservationIgnored private var startingSince: ContinuousClock.Instant?
    /// Sends waiting for pi to start: resumed with true once the thread is ready, false when it
    /// stops or fails first. Nothing has been dispatched for them yet.
    @ObservationIgnored private var startWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var settleTask: Task<Void, Never>?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var recentRequest = UUID()
    @ObservationIgnored private var historyEpoch = UUID()
    /// Saved user entries → the echo they replaced, so the turn keeps its identity.
    @ObservationIgnored private var aliases: [String: String] = [:]
    /// Snapshot requests started so far. A change of this client's (a queue edit, an echo)
    /// stands until a snapshot requested after the host accepted it arrives.
    @ObservationIgnored private var pulls = 0
    @ObservationIgnored private var overlays: [QueueOverlay] = []
    /// Queued messages this client holds (an editor open on them). A thread off screen cannot
    /// renew them, so they are renewed as it comes back.
    @ObservationIgnored private var holding: Set<UUID> = []
    /// Echo id → the pull count when its send was accepted (hosts with a queue).
    @ObservationIgnored private var echoAccepted: [String: Int] = [:]
    /// Images this client queued, by queued message id: the host keeps only their names.
    @ObservationIgnored private var sentImages: [UUID: [NativeImage]] = [:]
    @ObservationIgnored private var presentationCache: [String: (key: PresentationKey, value: NativeTurnPresentation)] = [:]
    /// The machine the agent runs on ("build-01"), named in its errors' Details. Set by the
    /// thread's owner.
    @ObservationIgnored public var hostName: String? {
        didSet { if hostName != oldValue { derive() } }
    }
    /// Calls parse their JSON and output once; a finished call never changes.
    @ObservationIgnored private var callCache: [CallKey: NativeActivityCall] = [:]
    /// Finished thinking is parsed once: a reply streaming under it rebuilds its turn, not it.
    @ObservationIgnored private var thinkingCache: [String: [NativeMarkdownBlock]] = [:]
    /// How many times thinking was parsed (tests).
    @ObservationIgnored private(set) var thinkingParses = 0

    private struct QueueOverlay {
        let id: UUID
        /// The pull count when the host answered; nil while the request is on its way.
        var accepted: Int?
        var mode: NativeQueueMode?
        let apply: (inout [NativeQueuedMessage]) -> Void
    }

    private struct PresentationKey: Equatable {
        var messages: [NativeThreadMessage]
        var live: Bool
        var cards: NativeCardLayout
        var errors: NativeTurnErrorContext
    }

    private struct CallKey: Hashable {
        var entryID: String
        var status: String?
        var isError: Bool?
        var outputSize: Int
        /// A running call's output can change at the same length (the host clips a long tail,
        /// a progress line rewrites itself), so its key carries the end of the output too.
        var liveTail: String?
    }

    /// Reconcile echoes against a snapshot: gone when the real message landed or the session moved on.
    private func settlePending(_ value: NativeThreadSnapshot, sameSession: Bool, pull: Int) {
        guard sameSession else {
            if !pending.isEmpty { pending = [] }
            aliases = [:]
            echoAccepted = [:]
            overlays = []
            holding = []
            return
        }
        // Everything this client changed before the host answered the pull that brought this
        // snapshot is in it.
        overlays.removeAll { $0.accepted.map { $0 < pull } ?? false }
        guard !pending.isEmpty else { return }
        if value.queue != nil {
            // The host shows its own row for the send (same id), or has it in its queue.
            let settled = echoAccepted.filter { $0.value < pull }.map(\.key)
            guard !settled.isEmpty else { return }
            pending.removeAll { settled.contains($0.entryID) }
            for id in settled { echoAccepted[id] = nil }
            return
        }
        let persisted = (messages + value.messages + value.provisional).filter { $0.role == "user" }
        let texts = Set(persisted.map(Self.userText))
        let landed = pending.filter { texts.contains(Self.userText($0)) }
        guard !landed.isEmpty else { return }
        for echo in landed {
            let text = Self.userText(echo)
            // The newest saved message with the echo's text is the one it became.
            if let saved = persisted.last(where: { Self.userText($0) == text && aliases[$0.entryID] == nil }) {
                aliases[saved.entryID] = echo.entryID
            }
        }
        pending.removeAll { texts.contains(Self.userText($0)) }
    }

    private static func userText(_ message: NativeThreadMessage) -> String {
        message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live subagents keep the fast cadence too: their cards tick counters and activity. A
    /// starting pi is polled faster still, so the thread comes up as soon as pi answers.
    public var pollInterval: Duration {
        if starting { return .milliseconds(200) }
        return snapshot?.running == true || snapshot?.dialogs.isEmpty == false || hasLiveSubagents ? .milliseconds(500) : .seconds(2)
    }

    public var hasLiveSubagents: Bool { subagents.contains { !$0.isTerminal } }

    /// The host holds messages sent while pi works (`NativeQueue`): sends during a run join
    /// `queue`, and the queue actions below apply.
    public var supportsQueue: Bool {
        ready && snapshot?.queue != nil && snapshot?.supportedActions.contains("queue") == true
    }

    public func supports(_ action: String) -> Bool {
        ready && !busy && supportedActions.contains(action)
    }

    /// The thread is waiting for its pi: starting, shown from disk, or its first pull still on
    /// its way. Not an error, and not a thread kept from before that is refreshing.
    public var awaitingPi: Bool {
        !ready && loadError == nil && (starting || previewing || session == nil)
    }

    /// Send is offered: the thread supports it now, or it is not ready yet (pi starting, the
    /// first pull still on its way, a thread shown from disk) and the send will wait for it
    /// (every pi thread takes sends).
    public var acceptsSend: Bool {
        supports("send") || (!ready && !busy && loadError == nil)
    }

    // MARK: Derived state

    /// Recomputes what the thread draws. Values are assigned only when they changed, so an
    /// unchanged poll invalidates nothing.
    private func derive() {
        let ids = Set(messages.map(\.entryID))
        let toolIDs = Set(messages.compactMap(\.toolCallID))
        let provisional = (snapshot?.provisional ?? []).filter {
            !ids.contains($0.entryID) && ($0.toolCallID == nil || !toolIDs.contains($0.toolCallID!))
        }
        let displayed: [NativeThreadMessage]
        if snapshot?.queue != nil {
            // The host orders the run (user messages where pi read them) and shows its own
            // pending row for a send; an echo stands in only until the host's next snapshot.
            let live = Set(provisional.map(\.entryID))
            displayed = messages + provisional + pending.filter { !live.contains($0.entryID) }
        } else {
            displayed = messages + pending.filter { $0.status != "queued" } + provisional + pending.filter { $0.status == "queued" }
        }
        if displayed != displayedMessages { displayedMessages = displayed }
        // A steer lands inside the running turn; it does not restart its clock.
        let promptAt = displayed.last { $0.role == "user" && $0.status != "queued" && $0.origin != .steered }?.timestamp
        if promptAt != lastPromptAt { lastPromptAt = promptAt }
        var aliases = self.aliases
        for message in displayed where message.role == "user" {
            if let operation = message.operationID, aliases[message.entryID] == nil { aliases[message.entryID] = "pending:\(operation.uuidString)" }
        }
        let turns = nativeTurns(displayed, aliases: aliases)
        if turns != self.turns { self.turns = turns }
        let runs = snapshot?.subagents ?? []
        if runs != subagents { subagents = runs }
        let placements = nativeSubagentPlacements(runs, turns: turns)
        if placements != self.placements { self.placements = placements }
        let trayRuns = nativeTrayRuns(runs, placements: placements, turnOrder: turns.map(\.id), lastUserMessageAt: promptAt)
        let tray = trayRuns.map(NativeSubagentTray.init)
        if tray != self.tray { self.tray = tray }

        // The streaming reply is the last one, with only queued follow-ups below it.
        let running = loadError == nil && settledRunning
        let lastReply = turns.lastIndex { !$0.isUser }
        let liveReply = running ? lastReply.flatMap { index in
            turns[(index + 1)...].allSatisfy { $0.messages.allSatisfy { $0.status == "queued" } } ? index : nil
        } : nil
        var rows: [NativeThreadRow] = []
        rows.reserveCapacity(turns.count)
        var kept: Set<String> = []
        for (index, turn) in turns.enumerated() {
            if turn.isUser {
                rows.append(NativeThreadRow(turn: turn, presentation: nil, live: false, promptText: nil, startedAt: nil))
                continue
            }
            let isLive = index == liveReply
            let opener = index > 0 && turns[index - 1].isUser ? turns[index - 1] : nil
            let errors = NativeTurnErrorContext(host: hostName, retry: isLive ? snapshot?.retry : nil)
            let key = PresentationKey(messages: turn.messages, live: isLive, cards: NativeCardLayout(placements[turn.id]), errors: errors)
            let presentation: NativeTurnPresentation
            if let cached = presentationCache[turn.id], cached.key == key {
                presentation = cached.value
            } else {
                presentation = nativeTurnPresentation(turn.messages, live: isLive, cards: key.cards, errors: errors, call: call,
                                                      thinking: thinkingBlocks)
                presentationCache[turn.id] = (key, presentation)
            }
            kept.insert(turn.id)
            let prompt = opener.map { $0.messages.flatMap(\.blocks).filter { $0.kind == .text }.map(\.text).joined(separator: "\n") }
            let startedAt = opener?.messages.first?.timestamp
            let recordedTurn = changesTurn(forMessageAt: startedAt, in: snapshot?.turnChanges)
            let card = isLive ? nil : nativeChangesCard(turn: recordedTurn, changes: presentation.changes)
            rows.append(NativeThreadRow(turn: turn, presentation: presentation, live: isLive, promptText: prompt,
                                        startedAt: startedAt, recordedTurn: recordedTurn, changes: card))
        }
        if presentationCache.count > kept.count { presentationCache = presentationCache.filter { kept.contains($0.key) } }
        Self.foldRepeatedErrors(&rows)
        if rows != self.rows { self.rows = rows }
        deriveChrome()
    }

    /// A reply that ended in an error the next reply failed with again folds to a line
    /// (ThreadError: "the earlier one folds to a line").
    static func foldRepeatedErrors(_ rows: inout [NativeThreadRow]) {
        var next: String?
        for index in rows.indices.reversed() where !rows[index].isUser {
            guard var presentation = rows[index].presentation,
                  case .error(let id, let error, true, let folded)? = presentation.items.last else {
                next = nil
                continue
            }
            if !folded, next == error.signature {
                presentation.items[presentation.items.count - 1] = .error(id: id, error: error, final: true, folded: true)
                rows[index].presentation = presentation
            }
            next = error.signature
        }
    }

    /// Recomputes what the chrome draws (see `session`), each assigned only when it changed.
    private func deriveChrome() {
        let value = snapshot
        let session = value.map { NativeThreadSession(piSessionID: $0.piSessionID, generation: $0.generation) }
        if session != self.session { self.session = session }
        let dialogs = value?.dialogs ?? []
        if dialogs != self.dialogs { self.dialogs = dialogs }
        let dialogsSupported = value?.dialogsSupported ?? true
        if dialogsSupported != self.dialogsSupported { self.dialogsSupported = dialogsSupported }
        let widgets = (value?.widgets ?? []).filter { $0.kind != .unknown }
        if widgets != self.widgets { self.widgets = widgets }
        let commands = value?.commands ?? []
        if commands != self.commands { self.commands = commands }
        if value?.model != model { model = value?.model }
        if value?.thinking != thinking { thinking = value?.thinking }
        let levels = NativeThinkingLevel.levels(value?.thinkingLevels)
        if levels != thinkingLevels { thinkingLevels = levels }
        if value?.stats != stats { stats = value?.stats }
        let actions = Set(value?.supportedActions ?? [])
        if actions != supportedActions { supportedActions = actions }
        let clipped = value?.clipped ?? false
        if clipped != self.clipped { self.clipped = clipped }
        let hostRunning = value?.running ?? false
        if hostRunning != self.hostRunning { self.hostRunning = hostRunning }
        let running = loadError == nil && settledRunning
        if running != self.running { self.running = running }
        var failed = false
        if !running, case .error(_, _, true, _)? = rows.last?.presentation?.items.last { failed = true }
        if failed != lastTurnFailed { lastTurnFailed = failed }
        // The meter and its details derive from the context, the model and whether the agent is
        // replying alone, so a streamed chunk (same context) formats nothing.
        if contextInputs.unset || contextInputs.context != value?.context || contextInputs.model != value?.model
            || contextInputs.replying != running {
            contextInputs = (value?.context, value?.model, running, false)
            let meter = NativeContextMeter(value?.context, replying: running)
            if meter != contextMeter { contextMeter = meter }
            let details = value?.context.map { NativeContextDetails(context: $0, model: value?.model) }
            if details != contextDetails { contextDetails = details }
        }
        let thinking = showsThinking(running: running, dialogs: dialogs)
        if thinking != showsThinking { showsThinking = thinking }
        let userTurns = turns.count(where: \.isUser)
        if userTurns != userTurnCount { userTurnCount = userTurns }
        if subagents.isEmpty == hasSubagents { hasSubagents = !subagents.isEmpty }
    }

    private func showsThinking(running: Bool, dialogs: [NativeThreadDialog]) -> Bool {
        guard running, dialogs.isEmpty else { return false }
        guard let live = rows.last(where: \.live) else { return true }
        return live.presentation?.betweenTools ?? false
    }

    /// The queue as the host last reported it, with this client's unconfirmed changes on top.
    private func deriveQueue() {
        var items = snapshot?.queue?.items ?? []
        var mode = snapshot?.queue?.mode
        for overlay in overlays {
            overlay.apply(&items)
            if let chosen = overlay.mode { mode = chosen }
        }
        if items != queue { queue = items }
        if mode != queueMode { queueMode = mode }
        let paused = snapshot?.queue?.paused == true && !items.isEmpty
        if paused != queuePaused { queuePaused = paused }
        let notice = items.isEmpty ? nil : snapshot?.queue?.notice
        if notice != queueNotice { queueNotice = notice }
        if sentImages.count > 64 {
            let kept = Set(items.map(\.id))
            sentImages = sentImages.filter { kept.contains($0.key) }
        }
    }

    private func call(_ message: NativeThreadMessage) -> NativeActivityCall {
        let running = message.status == "running" || message.status == "streaming"
        let key = CallKey(entryID: message.entryID, status: message.status, isError: message.isError,
                          outputSize: message.blocks.reduce(0) { $0 + $1.text.utf8.count },
                          liveTail: running ? message.blocks.last.map { String(decoding: $0.text.utf8.suffix(1024), as: UTF8.self) } : nil)
        if let cached = callCache[key] { return cached }
        let value = NativeActivityCall(message)
        if callCache.count > 4096 { callCache.removeAll(keepingCapacity: true) }
        callCache[key] = value
        return value
    }

    private func thinkingBlocks(_ text: String) -> [NativeMarkdownBlock] {
        if let cached = thinkingCache[text] { return cached }
        thinkingParses += 1
        let value = nativeThinkingBlocks(text)
        if thinkingCache.count > 1024 { thinkingCache.removeAll(keepingCapacity: true) }
        thinkingCache[text] = value
        return value
    }

    // MARK: Polling

    // The view's foreground task owns this loop, while the thread is on screen. Reconnection
    // always starts without a revision.
    /// `preview` is read alongside the first pull while the thread has nothing to show yet.
    public func run(request: @escaping Request, preview: Preview? = nil) async {
        guard !Task.isCancelled else { return }
        suspend()
        let run = epoch
        self.request = request
        if let preview, snapshot == nil {
            Task { [weak self] in
                guard let value = await preview(), let self, self.epoch == run else { return }
                self.preview(value)
            }
        }
        await withTaskCancellationHandler {
            // The newest page merges onto the history already loaded, as a poll's does: a thread
            // shown again keeps the older pages read in it. Another session or generation, or no
            // overlap, starts over from that page.
            await pull(fresh: true)
            await renewHolds(run)
            while !Task.isCancelled && epoch == run {
                do { try await pauseUntilNextPull() } catch { break }
                guard epoch == run else { break }
                await pull()
            }
            if epoch == run { suspend() }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.epoch == run else { return }
                self.suspend()
            }
        }
    }

    private func renewHolds(_ run: UUID) async {
        holding.formIntersection(queue.filter { $0.state == .queued }.map(\.id))
        for id in holding {
            guard epoch == run else { return }
            await holdQueued(id, true)
        }
    }

    /// Shows `value`, history read from pi's session file (or a new agent's empty thread), until
    /// pi answers. Ignored once pi has served this thread anything: disk never overwrites pi.
    public func preview(_ value: NativeThreadSnapshot) {
        guard !ready, snapshot == nil || previewing else { return }
        if value != snapshot { snapshot = value }
        if value.messages != messages { messages = value.messages }
        if olderCursor != value.olderCursor { olderCursor = value.olderCursor }
        if !previewing { previewing = true }
        derive()
    }

    /// The host has a newer revision to pull (the local server pushes each one a local agent's
    /// pi reaches): the poll loop pulls now instead of when its pause ends, or once more right
    /// after the pull in flight however many arrive meanwhile, and at most every
    /// `pushedPullSpacing`. A thread off screen has no loop and ignores it; its first pull when
    /// shown again catches it up. The interval's poll stays as the fallback.
    public func revisionAvailable() {
        guard request != nil else { return }
        pollWake.signal()
    }

    /// One pull of the run loop. It takes every push that arrived before it; one that arrives
    /// while it is in flight ends the next pause at once.
    private func pull(fresh: Bool = false) async {
        pollWake.pending = false
        lastPull = .now
        await refresh(fresh: fresh)
    }

    /// Waits out one poll interval, or less once a revision is pushed, but never less than
    /// `pushedPullSpacing` since the last pull began. Throws once the loop's task is cancelled.
    private func pauseUntilNextPull() async throws {
        let pause = self.pause
        if !pollWake.pending {
            let interval = pollInterval
            let wake = pollWake
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await pause(interval) }
                group.addTask { await wake.wait() }
                try await group.next()
                group.cancelAll()
            }
        }
        if let lastPull {
            let rest = Self.pushedPullSpacing - (ContinuousClock.now - lastPull)
            if rest > .zero { try await pause(rest) }
        }
    }

    /// The thread went off screen (its agent is hidden): the poll loop ends, and everything the
    /// thread shows stays as it was (ready, running, the rows, the pages of history), so showing
    /// it again is a flip, and the first pull then catches it up. An action still in flight is
    /// reported as unknown.
    public func suspend() {
        // A send still waiting for pi to start was never dispatched: its draft stays as it is.
        if busy, startWaiters.isEmpty {
            notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
        }
        resumeStartWaiters(false)
        epoch = UUID()
        recentRequest = UUID()
        historyEpoch = UUID()
        request = nil
        catchUp = nil
        // The starting limit counts from the next answer.
        startingSince = nil
        if busy { busy = false }
        if loadingOlder { loadingOlder = false }
    }

    /// Detaches the store from its host (an error, a pruned agent, a view that went away): as
    /// `suspend`, and nothing is ready or running until it polls again.
    public func stop() {
        suspend()
        if ready { ready = false }
        // Unknown until the thread polls again.
        endStarting()
        settleTask?.cancel()
        settleTask = nil
        if settledRunning {
            settledRunning = false
            derive()
        }
    }

    /// `catchingUp`: the first pull since the thread came on screen, which lands what happened
    /// while it was away all at once, a finished turn included.
    private func settleRunning(_ running: Bool, catchingUp: Bool) {
        settleTask?.cancel()
        settleTask = nil
        if running {
            if !settledRunning { settledRunning = true }
        } else if catchingUp {
            if settledRunning { settledRunning = false }
        } else if settledRunning {
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.snapshot?.running != true else { return }
                self.settledRunning = false
                self.derive()
            }
        }
    }

    public func refresh(fresh: Bool = false, resetHistory: Bool = false) async {
        guard !Task.isCancelled, let request else { return }
        let run = epoch
        let ticket = UUID()
        recentRequest = ticket
        pulls += 1
        let pull = pulls
        let previous = snapshot
        let fresh = fresh || !ready
        do {
            let result = try await request(.snapshot(
                expectedSessionID: fresh ? nil : previous?.piSessionID,
                afterRevision: fresh ? nil : previous?.revision
            ))
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            switch result {
            case .snapshot(let value):
                let sameSession = previous?.piSessionID == value.piSessionID && previous?.generation == value.generation
                if sameSession, let previous, value.revision < previous.revision { return }
                settlePending(value, sameSession: sameSession, pull: pull)
                settleRunning(value.running, catchingUp: catchUp == nil)
                if !resetHistory, sameSession, value.olderCursor != nil,
                   let first = value.messages.first,
                   let overlap = messages.firstIndex(where: { $0.entryID == first.entryID }) {
                    let merged = Array(messages[..<overlap]) + value.messages
                    if merged != messages { messages = merged }
                } else {
                    if value.messages != messages { messages = value.messages }
                    if olderCursor != value.olderCursor { olderCursor = value.olderCursor }
                    historyEpoch = UUID()
                    if loadingOlder { loadingOlder = false }
                }
                if value != snapshot { snapshot = value }
                if previewing { previewing = false }
                if !ready { ready = true }
                endStarting()
                if loadError != nil { loadError = nil }
                deriveQueue()
                derive()
                caughtUp()
                resumeStartWaiters(true)
            case .unchanged(let session, let generation, _):
                if previous?.piSessionID != session || previous?.generation != generation || fresh {
                    ready = false
                    await refresh(fresh: true)
                } else {
                    if !ready { ready = true }
                    endStarting()
                    // Nothing changed on the host: whatever this client changed before it asked
                    // is in the snapshot it already has, or was refused.
                    let before = overlays.count
                    overlays.removeAll { $0.accepted.map { $0 < pull } ?? false }
                    if overlays.count != before { deriveQueue() }
                    if loadError != nil {
                        loadError = nil
                        derive()
                    }
                    caughtUp()
                    resumeStartWaiters(true)
                }
            case .failure(let code, _) where code == NativeThreadCode.starting:
                noteStarting()
            case .failure(let code, let message):
                ready = false
                setLoadError(message)
                if code == "stale_session", !fresh { await refresh(fresh: true) }
            default:
                ready = false
                setLoadError("Unexpected thread response. Refresh to try again.")
            }
        } catch RemoteHostClientError.rejected(let code, _) where code == NativeThreadCode.starting {
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            noteStarting()
        } catch {
            guard !Task.isCancelled, epoch == run, recentRequest == ticket else { return }
            ready = false
            setLoadError(String(describing: error))
        }
    }

    /// Any failure but `native_starting`: the thread is not starting, it is in trouble.
    private func setLoadError(_ message: String) {
        endStarting()
        resumeStartWaiters(false)
        guard loadError != message else { return }
        loadError = message
        derive()
    }

    /// pi has not answered yet (the host is still binding or booting it): quiet, with no
    /// error, until it has taken longer than `startingLimit`.
    private func noteStarting() {
        if ready { ready = false }
        let now = ContinuousClock.now
        let since = startingSince ?? now
        startingSince = since
        // A thread cached from before (a host that relaunched) is not running while pi restarts.
        if settledRunning {
            settleTask?.cancel()
            settleTask = nil
            settledRunning = false
            derive()
        }
        guard now - since < startingLimit else {
            if starting {
                starting = false
                deriveChrome()
            }
            resumeStartWaiters(false)
            let limit = startingLimit.formatted(.units(allowed: [.minutes, .seconds], width: .wide))
            let message = "The agent has not started after \(limit)."
            if loadError != message {
                loadError = message
                derive()
            }
            return
        }
        if !starting {
            starting = true
            deriveChrome()
        }
        if loadError != nil {
            loadError = nil
            derive()
        }
    }

    private func endStarting() {
        if starting {
            starting = false
            deriveChrome()
        }
        startingSince = nil
    }

    private func resumeStartWaiters(_ started: Bool) {
        guard !startWaiters.isEmpty else { return }
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume(returning: started) }
    }

    /// At once when the thread can act. Until it is ready (pi starting, or the first pull on its
    /// way), holds the caller (the composer shows its "Waiting for pi" spinner): false instead
    /// when the thread stops or fails first, or pi never starts. Nothing is dispatched while it
    /// waits.
    private func readyToAct() async -> Bool {
        if ready { return true }
        guard loadError == nil, !busy, request != nil else { return false }
        let run = epoch
        busy = true
        let started = await withCheckedContinuation { startWaiters.append($0) }
        // stop() already reset everything for a thread that went away meanwhile.
        guard epoch == run else { return false }
        busy = false
        return started && ready
    }

    public func loadOlder() async {
        guard ready, !loadingOlder, let request, let current = snapshot, let cursor = olderCursor else { return }
        let run = epoch
        let history = historyEpoch
        loadingOlder = true
        defer { if epoch == run && historyEpoch == history { loadingOlder = false } }
        do {
            let result = try await request(.snapshot(expectedSessionID: current.piSessionID, beforeEntryID: cursor))
            guard !Task.isCancelled, epoch == run, historyEpoch == history, olderCursor == cursor,
                  snapshot?.piSessionID == current.piSessionID, snapshot?.generation == current.generation else { return }
            switch result {
            case .snapshot(let page) where page.piSessionID == current.piSessionID && page.generation == current.generation:
                let ids = Set(messages.map(\.entryID))
                messages = page.messages.filter { !ids.contains($0.entryID) } + messages
                olderCursor = page.olderCursor
                derive()
            case .failure(let code, let message):
                loadError = message
                derive()
                if code == "stale_cursor" || code == "stale_session" { await refresh(fresh: true, resetHistory: true) }
            default: break
            }
        } catch {
            guard !Task.isCancelled, epoch == run, historyEpoch == history else { return }
            setLoadError(String(describing: error))
        }
    }

    // MARK: Actions

    /// `images` requires `sendImages` support (v2, RPC agents); they are dropped otherwise.
    /// Sent while pi is starting, the draft waits for it (see `acceptsSend`), still in the field,
    /// then goes as the field has it by then: edited, or not at all once cleared.
    public func send(images: [NativeImage] = []) async {
        await send(images: images, delivery: delivery)
    }

    /// While pi works, `delivery` says whether the message waits in the queue (`followUp`) or
    /// is steered in; while pi is idle it goes at once either way.
    public func send(images: [NativeImage] = [], delivery: NativeThreadDelivery) async {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, await readyToAct() else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              supports("send"), let current = snapshot else { return }
        let operation = UUID()
        let attached: [NativeImage]? = images.isEmpty || !supports("sendImages") ? nil : images
        let context = supports("designContext") ? designContext?().map(NativeDesignContext.init) : nil
        await perform(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                            operationID: operation, text: text, delivery: delivery, images: attached, designContext: context),
                      operation: operation, current: current, sentText: text, delivery: delivery, images: attached ?? [])
    }

    /// Send `text` as a new user message without touching the draft (a turn's Retry).
    public func send(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, await readyToAct(),
              supports("send"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.send(expectedSessionID: current.piSessionID, generation: current.generation,
                            operationID: operation, text: text, delivery: delivery),
                      operation: operation, current: current, sentText: text, delivery: delivery)
    }

    // MARK: Queue

    /// The images this client sent with a queued message (the host keeps only their names);
    /// empty for another client's.
    public func queuedImages(_ id: UUID) -> [NativeImage] {
        sentImages[id] ?? []
    }

    /// Saves an edit to a queued message; it keeps its place. Also releases the item's hold.
    public func editQueued(_ id: UUID, text: String) async {
        holding.remove(id)
        await queueAction(.edit(id: id, text: text)) { NativeQueueRules.edit(id, text: text, in: &$0) }
    }

    /// Deletes a queued message, returning it and the place it had, for an Undo
    /// (`restoreQueued`). nil when it is not queued.
    @discardableResult
    public func deleteQueued(_ id: UUID) async -> (message: NativeQueuedMessage, index: Int)? {
        guard let index = NativeQueueRules.queuedIndex(of: id, in: queue), let message = queue.first(where: { $0.id == id }) else { return nil }
        await queueAction(.delete(id: id)) { NativeQueueRules.remove([id], from: &$0) }
        return (message, index)
    }

    /// Deletes every queued message (steering ones stay), returning them for an Undo.
    @discardableResult
    public func clearQueue() async -> [NativeQueuedMessage] {
        let cleared = queue.filter { $0.state == .queued }
        guard !cleared.isEmpty else { return [] }
        await queueAction(.clear) { items in items.removeAll { $0.state == .queued } }
        return cleared
    }

    /// Undoes a delete or a clear: the messages return at queued index `index`, in order.
    public func restoreQueued(_ messages: [NativeQueuedMessage], at index: Int) async {
        guard !messages.isEmpty else { return }
        await queueAction(.restore(ids: messages.map(\.id), index: index)) { NativeQueueRules.insert(messages, atQueuedIndex: index, into: &$0) }
    }

    /// Moves a queued message to queued index `index` (0 goes first).
    public func moveQueued(_ id: UUID, to index: Int) async {
        await queueAction(.move(id: id, index: index)) { NativeQueueRules.move(id, toQueuedIndex: index, in: &$0) }
    }

    /// Steers queued messages in now, in order (Steer now, Steer all now). While pi is idle the
    /// host sends them as the next turn instead.
    public func steerQueued(_ ids: [UUID]) async {
        let running = snapshot?.running == true
        await queueAction(.steer(ids: ids)) { items in
            if running { NativeQueueRules.steer(ids, in: &items) }
        }
    }

    /// Takes a steering message back before pi reads it: it returns to the head of the queue.
    public func unsteer(_ id: UUID) async {
        await queueAction(.unsteer(id: id)) { NativeQueueRules.unsteer(id, in: &$0) }
    }

    /// An editor opened (true) or closed on a queued message: the host waits to send the queue
    /// while it is held. A hold lapses on the host after two minutes unless renewed.
    public func holdQueued(_ id: UUID, _ held: Bool) async {
        if held { holding.insert(id) } else { holding.remove(id) }
        await queueAction(.hold(id: id, held: held)) { NativeQueueRules.hold(id, held, in: &$0) }
    }

    /// This agent's delivery mode; nil follows the host's default.
    public func setQueueMode(_ mode: NativeQueueMode?) async {
        await queueAction(.setMode(mode: mode), mode: mode) { _ in }
    }

    /// While pi is idle (a paused queue): these messages open the next turn now, and the rest of
    /// the queue resumes after it.
    public func sendQueuedNow(_ ids: [UUID]) async {
        await queueAction(.sendNow(ids: ids)) { items in items.removeAll { ids.contains($0.id) } }
    }

    /// Applies `apply` to `queue` at once, then asks the host. Queue actions never make the
    /// composer busy: they are not the draft's.
    @discardableResult
    private func queueAction(_ action: NativeQueueAction, mode: NativeQueueMode? = nil,
                             apply: @escaping (inout [NativeQueuedMessage]) -> Void) async -> Bool {
        guard supportsQueue, let request, let current = snapshot else { return false }
        let run = epoch
        let operation = UUID()
        overlays.append(QueueOverlay(id: operation, accepted: nil, mode: mode, apply: apply))
        deriveQueue()
        var accepted = false
        // The overlay settles even when the thread went off screen meanwhile: left unanswered,
        // no later snapshot would clear it.
        do {
            let result = try await request(.queue(expectedSessionID: current.piSessionID, generation: current.generation,
                                                  operationID: operation, action: action))
            switch result {
            case .accepted(let id) where id == operation:
                accepted = true
                if let index = overlays.firstIndex(where: { $0.id == operation }) { overlays[index].accepted = pulls }
            case .failure(_, let message):
                if epoch == run { notice = message }
            default:
                if epoch == run {
                    notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
                }
            }
        } catch {
            if epoch == run {
                if case RemoteHostClientError.outcomeUnknown = error {
                    notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
                } else { notice = String(describing: error) }
            }
        }
        if !accepted {
            overlays.removeAll { $0.id == operation }
            deriveQueue()
        }
        guard epoch == run else { return false }
        await refresh()
        return accepted
    }

    /// "provider/id"; gated by `setModel` in `supportedActions`.
    public func setModel(_ model: String) async {
        guard supports("setModel"), let current = snapshot, current.model != model else { return }
        let operation = UUID()
        await perform(.setModel(expectedSessionID: current.piSessionID, generation: current.generation,
                                operationID: operation, model: model), operation: operation, current: current)
    }

    /// off/low/medium/high; gated by `setThinking` in `supportedActions`.
    public func setThinking(_ level: String) async {
        guard supports("setThinking"), let current = snapshot, current.thinking != level else { return }
        let operation = UUID()
        await perform(.setThinking(expectedSessionID: current.piSessionID, generation: current.generation,
                                   operationID: operation, level: level), operation: operation, current: current)
    }

    /// Card and inspector actions on one subagent run. Gated by `subagents` in `supportedActions`.
    public func subagentCommand(runID: String, action: NativeSubagentAction, text: String? = nil, mode: NativeThreadDelivery? = nil) async {
        guard supports("subagents"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.subagentCommand(expectedSessionID: current.piSessionID, generation: current.generation, operationID: operation,
                                       runID: runID, action: action, text: text, mode: mode), operation: operation, current: current)
    }

    /// One transcript page for the inspector; nil when the thread is not ready or the host refused.
    public func subagentTranscript(runID: String, beforeEntryID: String? = nil) async -> NativeSubagentTranscript? {
        guard let request, let current = snapshot else { return nil }
        guard case .transcript(let page)? = try? await request(.subagentTranscript(expectedSessionID: current.piSessionID, runID: runID, beforeEntryID: beforeEntryID)) else { return nil }
        return page
    }

    /// pi's `compact`, keeping what `instructions` asks for. pi stops a run to compact, so the
    /// host takes it only while the agent is idle. Gated by `compact` in `supportedActions`.
    public func compact(instructions: String?) async {
        guard supports("compact"), let current = snapshot else { return }
        let text = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = UUID()
        await perform(.compact(expectedSessionID: current.piSessionID, generation: current.generation, operationID: operation,
                               instructions: text?.isEmpty == false ? text : nil), operation: operation, current: current)
    }

    public func abort() async {
        guard supports("abort"), let current = snapshot else { return }
        let operation = UUID()
        await perform(.abort(expectedSessionID: current.piSessionID, generation: current.generation,
                             operationID: operation), operation: operation, current: current)
    }

    /// Stop the parent's turn and every live subagent (the composer's "⌘. stop all").
    public func abortAll() async {
        let live = subagents.filter { !$0.isTerminal }.map(\.runID)
        for runID in live { await subagentCommand(runID: runID, action: .cancel) }
        await abort()
    }

    public func answer(dialogID: String, sessionID: String, generation: String, answer: NativeDialogAnswer) async {
        guard supports("answer"), let current = snapshot,
              current.piSessionID == sessionID, current.generation == generation,
              current.dialogs.contains(where: { $0.id == dialogID && $0.unavailable == nil }) else { return }
        let operation = UUID()
        await perform(.answer(expectedSessionID: sessionID, generation: generation, operationID: operation,
                              dialogID: dialogID, answer: answer), operation: operation, current: current)
    }

    private func perform(_ action: NativeThreadRequest, operation: UUID, current: NativeThreadSnapshot, sentText: String? = nil,
                         delivery: NativeThreadDelivery = .followUp, images: [NativeImage] = []) async {
        guard let request else { return }
        let run = epoch
        // A follow-up sent while a turn runs waits in the queue until the turn ends.
        let queued = current.running && delivery == .followUp
        let hostQueues = current.queue != nil
        busy = true
        notice = nil
        do {
            let result = try await request(action)
            guard epoch == run else { return }
            guard snapshot?.piSessionID == current.piSessionID, snapshot?.generation == current.generation else {
                busy = false
                notice = "The session changed while the action was pending. Check the thread before trying again."
                return
            }
            switch result {
            case .accepted(let accepted) where accepted == operation:
                if let sentText {
                    if draft == sentText { draft = "" }
                    lastSendQueued = queued
                    sentCount += 1
                    if hostQueues && current.running {
                        // The host queued it (or steered it in): it shows in the queue, not the thread.
                        let item = NativeQueuedMessage(id: operation, text: sentText,
                                                       images: images.map { NativeQueuedImage(mimeType: $0.mimeType, name: $0.name) },
                                                       sentAt: Date().timeIntervalSince1970 * 1000,
                                                       state: delivery == .steer ? .steering : .queued)
                        if !images.isEmpty { sentImages[operation] = images }
                        overlays.append(QueueOverlay(id: operation, accepted: pulls, mode: nil) { items in
                            if !items.contains(where: { $0.id == item.id }) { items.append(item); NativeQueueRules.normalize(&items) }
                        })
                        deriveQueue()
                    } else {
                        let id = "pending:\(operation.uuidString)"
                        pending.append(NativeThreadMessage(entryID: id, role: "user",
                                                           blocks: [NativeThreadBlock(kind: .text, text: sentText)],
                                                           status: queued ? "queued" : "pending"))
                        if hostQueues { echoAccepted[id] = pulls }
                    }
                    derive()
                }
                // Success is visible in the thread itself; only failures earn a notice.
                notice = nil
            case .failure(_, let message): notice = message
            default:
                notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
            }
        } catch {
            guard epoch == run else { return }
            if case RemoteHostClientError.outcomeUnknown = error {
                notice = "Action outcome unknown. Refresh and check the thread before trying again. Nothing will be resent automatically."
            } else { notice = String(describing: error) }
        }
        guard epoch == run else { return }
        busy = false
        ready = false
        await refresh(fresh: true)
    }
}

/// Ends the poll loop's pause when the host pushes a revision.
@MainActor
private final class PollWake {
    /// A revision was pushed since the last pull began.
    var pending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        pending = true
        let resumed = waiters
        waiters = [:]
        for waiter in resumed.values { waiter.resume() }
    }

    /// Returns once a revision is pushed, or when the waiting task is cancelled.
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if pending || Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
    }
}

/// Which errors in a thread show their Details, and which folded ones were opened, by the
/// failed message's entry (`NativeTurnError.id`). Kept by the store, so a row the list rebuilds
/// keeps them; its own object, so a toggle redraws only the error.
@MainActor
@Observable
public final class NativeTurnErrorExpansion {
    public private(set) var detailsOpen: Set<String> = []
    public private(set) var unfolded: Set<String> = []

    public init() {}

    public func setDetails(_ id: String, open: Bool) {
        if open { detailsOpen.insert(id) } else { detailsOpen.remove(id) }
    }

    public func unfold(_ id: String) {
        if !unfolded.contains(id) { unfolded.insert(id) }
    }
}

/// Which compactions in a thread show what the agent kept: toggled by their Show summary, and
/// opened by the ring's details. Its own object, so a toggle redraws only the compaction lines.
@MainActor
@Observable
public final class NativeCompactionExpansion {
    public private(set) var expanded: Set<String> = []

    public init() {}

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    public func expand(_ id: String) {
        if !expanded.contains(id) { expanded.insert(id) }
    }
}
