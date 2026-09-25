import Foundation

public enum NativeThreadRequest: Codable, Hashable, Sendable {
    case snapshot(expectedSessionID: String? = nil, beforeEntryID: String? = nil, afterRevision: UInt64? = nil)
    /// `images` is v2 (RPC agents, `sendImages` in `supportedActions`); absent on the wire when nil.
    case send(expectedSessionID: String, generation: String, operationID: UUID, text: String, delivery: NativeThreadDelivery, images: [NativeImage]? = nil)
    case abort(expectedSessionID: String, generation: String, operationID: UUID)
    case answer(expectedSessionID: String, generation: String, operationID: UUID, dialogID: String, answer: NativeDialogAnswer)
    /// v2: `model` is "provider/id". Gated by `setModel` in `supportedActions`.
    case setModel(expectedSessionID: String, generation: String, operationID: UUID, model: String)
    /// v2: a level the snapshot's `thinkingLevels` lists (off/low/medium/high from a host that
    /// sends none). Gated by `setThinking` in `supportedActions`.
    case setThinking(expectedSessionID: String, generation: String, operationID: UUID, level: String)
    /// v2 (RPC agents with native children): drive one subagent run. Routed to the children
    /// extension, never to the parent model. `text` is the reply/steer for `.message`.
    case subagentCommand(expectedSessionID: String, generation: String, operationID: UUID, runID: String, action: NativeSubagentAction, text: String? = nil, mode: NativeThreadDelivery? = nil)
    /// v2: one page (50) of a subagent's transcript, newest first, from its session file.
    case subagentTranscript(expectedSessionID: String, runID: String, beforeEntryID: String? = nil)
    /// v3: change the messages the host holds while pi works (`NativeQueue`). Gated by `queue`
    /// in `supportedActions` and, remotely, `native.queue.v1`.
    case queue(expectedSessionID: String, generation: String, operationID: UUID, action: NativeQueueAction)
    /// v4: summarize the conversation now (pi's `compact`), keeping what `instructions` asks
    /// for. Gated by `compact` in `supportedActions` and, remotely, `native.context.v1`.
    case compact(expectedSessionID: String, generation: String, operationID: UUID, instructions: String? = nil)

    public var images: [NativeImage] {
        if case .send(_, _, _, _, _, let images) = self { return images ?? [] }
        return []
    }
}

/// An image attached to a `send`. `data` travels base64 (Codable's default for `Data`).
public struct NativeImage: Codable, Hashable, Sendable {
    public static let maxBytes = 2 * 1024 * 1024
    public static let maxPerSend = 4
    public var mimeType: String
    public var data: Data
    /// The file it came from, for the queue's attachment chips. Absent from older clients.
    public var name: String?

    public init(mimeType: String, data: Data, name: String? = nil) {
        self.mimeType = mimeType
        self.data = data
        self.name = name
    }
}

// MARK: - Queue (v3)

/// What the host holds for pi while it works: messages sent during a run, delivered when pi
/// settles (`mode`), or steered in. Nothing in `items` has reached pi except a `.steering` item,
/// which pi has queued and reads once its current tool calls finish. Held by the host, so every
/// client sees and edits the same queue.
public struct NativeQueue: Codable, Hashable, Sendable {
    /// Steering items first, in the order they were steered, then the queue in delivery order.
    public var items: [NativeQueuedMessage]
    /// How the queue goes when pi settles: this agent's choice, else the host's default. nil
    /// when this client does not know the host's mode.
    public var mode: NativeQueueMode?
    /// The queue waits instead of going when pi settles: the user stopped pi, or a turn or a
    /// delivery failed. A new message, Send now, or Steer resumes it.
    public var paused: Bool
    /// Why the queue paused on its own (a delivery pi refused), for the stack to say.
    public var notice: String?

    public init(items: [NativeQueuedMessage] = [], mode: NativeQueueMode? = nil, paused: Bool = false, notice: String? = nil) {
        self.items = items
        self.mode = mode
        self.paused = paused
        self.notice = notice
    }

    private enum CodingKeys: String, CodingKey { case items, mode, paused, notice }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        items = try values.decodeIfPresent([NativeQueuedMessage].self, forKey: .items) ?? []
        // A mode a newer host added is unknown here, not a broken snapshot.
        mode = try? values.decodeIfPresent(NativeQueueMode.self, forKey: .mode)
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        notice = try values.decodeIfPresent(String.self, forKey: .notice)
    }

    /// The items still waiting for their turn (not steering), in delivery order.
    public var queued: [NativeQueuedMessage] { items.filter { $0.state == .queued } }
}

/// One message in the host's queue. Its id is the operation id of the `send` that queued it.
public struct NativeQueuedMessage: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Hashable, Sendable {
        /// Waiting on the host for pi to settle.
        case queued
        /// Handed to pi to read after its current tool calls; not in the thread until pi does.
        case steering

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .queued
        }
    }

    public var id: UUID
    public var text: String
    /// The images it carries; their bytes stay on the host.
    public var images: [NativeQueuedImage]
    /// When the user sent it (ms since epoch).
    public var sentAt: Double
    public var state: State
    /// An editor is open on it somewhere: the queue waits rather than send it mid-edit.
    public var held: Bool

    public init(id: UUID, text: String, images: [NativeQueuedImage] = [], sentAt: Double, state: State = .queued, held: Bool = false) {
        self.id = id
        self.text = text
        self.images = images
        self.sentAt = sentAt
        self.state = state
        self.held = held
    }

    private enum CodingKeys: String, CodingKey { case id, text, images, sentAt, state, held }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        images = try values.decodeIfPresent([NativeQueuedImage].self, forKey: .images) ?? []
        sentAt = try values.decodeIfPresent(Double.self, forKey: .sentAt) ?? 0
        state = try values.decodeIfPresent(State.self, forKey: .state) ?? .queued
        held = try values.decodeIfPresent(Bool.self, forKey: .held) ?? false
    }
}

public struct NativeQueuedImage: Codable, Hashable, Sendable {
    public var mimeType: String
    public var name: String?

    public init(mimeType: String, name: String? = nil) {
        self.mimeType = mimeType
        self.name = name
    }
}

public enum NativeQueueMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// The head of the queue opens the next turn; the rest wait for the one after.
    case oneAtATime
    /// Everything queued arrives as one turn, in order.
    case all
}

/// A change to the host's queue. Indexes count queued items only (steering items are not
/// placed): 0 goes first.
public enum NativeQueueAction: Codable, Hashable, Sendable {
    case edit(id: UUID, text: String)
    case delete(id: UUID)
    /// Undo a delete or a clear: the host keeps what it removed for a while.
    case restore(ids: [UUID], index: Int)
    case move(id: UUID, index: Int)
    /// Hand these to pi now, in order, to read after its current tool calls. While pi is idle
    /// this is `sendNow`.
    case steer(ids: [UUID])
    /// Take a steering item back before pi reads it; it returns to the head of the queue.
    case unsteer(id: UUID)
    /// Delete every queued item (steering items stay).
    case clear
    /// An editor opened (true) or closed on the item. A hold lapses on its own after a while.
    case hold(id: UUID, held: Bool)
    /// This agent's delivery mode; nil follows the host's default.
    case setMode(mode: NativeQueueMode?)
    /// While pi is idle (a paused queue): send these now as the next turn.
    case sendNow(ids: [UUID])
}

/// How a user message reached pi, when Shepherd delivered it: steered into a running turn, or
/// from the queue (several queued messages arrive as one message, one part each).
public enum NativeMessageOrigin: Codable, Hashable, Sendable {
    case steered
    case queue(parts: [NativeQueuePart])
    /// In a subagent's transcript: the user wrote it (a steer or an answer from its card or
    /// inspector), not the parent agent. Older hosts mark nothing, and clients read every later
    /// message as the parent's.
    case user
    /// From a newer host.
    case unknown

    private enum CodingKeys: String, CodingKey { case steered, queue, user }
    private enum QueueKeys: String, CodingKey { case parts }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.steered) {
            self = .steered
        } else if values.contains(.user) {
            self = .user
        } else if values.contains(.queue) {
            let queue = try values.nestedContainer(keyedBy: QueueKeys.self, forKey: .queue)
            self = .queue(parts: try queue.decode([NativeQueuePart].self, forKey: .parts))
        } else {
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .steered:
            _ = values.nestedContainer(keyedBy: QueueKeys.self, forKey: .steered)
        case .user:
            _ = values.nestedContainer(keyedBy: QueueKeys.self, forKey: .user)
        case .queue(let parts):
            var queue = values.nestedContainer(keyedBy: QueueKeys.self, forKey: .queue)
            try queue.encode(parts, forKey: .parts)
        case .unknown:
            break
        }
    }

    public var parts: [NativeQueuePart]? {
        if case .queue(let parts) = self { return parts }
        return nil
    }
}

/// One queued message inside a delivered one: its own text, the time it was sent, and how
/// many of the message's images are its.
public struct NativeQueuePart: Codable, Hashable, Sendable {
    public var id: UUID?
    public var text: String
    public var sentAt: Double
    public var images: Int

    public init(id: UUID? = nil, text: String, sentAt: Double, images: Int = 0) {
        self.id = id
        self.text = text
        self.sentAt = sentAt
        self.images = images
    }

    private enum CodingKeys: String, CodingKey { case id, text, sentAt, images }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        sentAt = try values.decodeIfPresent(Double.self, forKey: .sentAt) ?? 0
        images = try values.decodeIfPresent(Int.self, forKey: .images) ?? 0
    }
}

/// v2 snapshot field from pi's `get_session_stats`. Every member is optional: pi omits
/// `contextUsage` without a model, and cost is absent on some providers.
public struct NativeThreadStats: Codable, Hashable, Sendable {
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var contextPercent: Double?
    public var totalTokens: Int?
    public var cost: Double?

    public init(contextTokens: Int? = nil, contextWindow: Int? = nil, contextPercent: Double? = nil, totalTokens: Int? = nil, cost: Double? = nil) {
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.totalTokens = totalTokens
        self.cost = cost
    }
}

/// v2 snapshot entry from pi's `get_commands`: a slash command the client may send as `/name`.
public struct NativeCommand: Codable, Hashable, Sendable {
    public static let maxCount = 128
    public static let maxNameBytes = 64
    public static let maxDescriptionBytes = 256
    public var name: String
    public var description: String?
    /// extension / prompt / skill.
    public var source: String?

    public init(name: String, description: String? = nil, source: String? = nil) {
        self.name = name
        self.description = description
        self.source = source
    }
}

public enum NativeThreadDelivery: String, Codable, Hashable, Sendable { case followUp, steer }

/// Card and inspector actions on a subagent run. Pause and continue suspend and resume a run
/// that is still in progress.
public enum NativeSubagentAction: String, Codable, Hashable, Sendable { case message, cancel, resume, pause, `continue` }

/// One native child run projected into the RPC thread (v2, additive). Same shape as
/// `ChildRun` so the server can hand the extension's rows straight through.
public typealias NativeSubagent = ChildRun

public enum NativeDialogAnswer: Codable, Hashable, Sendable {
    case select(value: String)
    case confirm(value: Bool)
    case input(value: String)
    case editor(value: String)
    case cancel
}

public enum NativeThreadResult: Codable, Hashable, Sendable {
    case snapshot(value: NativeThreadSnapshot)
    case unchanged(piSessionID: String, generation: String, revision: UInt64)
    /// Acknowledges synchronous API dispatch only, not persistence or completion.
    case accepted(operationID: UUID)
    case failure(code: String, message: String)
    /// v2: one transcript page for `.subagentTranscript`. `olderCursor` is the first entry's id.
    case transcript(value: NativeSubagentTranscript)
}

/// Failure codes a thread's availability is reported with, as `NativeThreadResult.failure` or
/// a rejected request. Both travel between hosts and clients, so they never change.
public enum NativeThreadCode {
    /// The agent exists but its pi is not serving yet: the app has not bound the process to
    /// the agent's pane, or pi has not answered its first `get_state` and `get_messages`.
    /// Clients wait and poll; it is never an error. Hosts advertise it with
    /// `RemoteProtocol.nativeThreadStartingCapability`.
    public static let starting = "native_starting"
    /// The agent's pi is gone: it exited, the agent was removed, or its pane runs no pi.
    public static let unavailable = "native_unavailable"
}

public struct NativeSubagentTranscript: Codable, Hashable, Sendable {
    public var runID: String
    public var messages: [NativeThreadMessage]
    public var olderCursor: String?
    /// Entries before the returned page (the "72 earlier turns" caption).
    public var earlierCount: Int
    public init(runID: String, messages: [NativeThreadMessage], olderCursor: String? = nil, earlierCount: Int = 0) {
        self.runID = runID
        self.messages = messages
        self.olderCursor = olderCursor
        self.earlierCount = earlierCount
    }
}

public struct NativeThreadSnapshot: Codable, Hashable, Sendable {
    public var piSessionID: String
    public var generation: String
    public var revision: UInt64
    public var running: Bool
    public var model: String?
    public var thinking: String?
    /// The levels pi offers the current model (`get_available_thinking_levels`), in pi's order.
    /// nil from an older host, or before pi has answered: clients then offer off/low/medium/high.
    public var thinkingLevels: [String]?
    public var supportedActions: [String]
    public var dialogsSupported: Bool
    public var dialogs: [NativeThreadDialog]
    /// Absent on older bridges. Unknown future item kinds are ignored by renderers.
    public var widgets: [NativeThreadWidget]?
    public var messages: [NativeThreadMessage]
    public var olderCursor: String?
    public var provisional: [NativeThreadMessage]
    public var clipped: Bool
    /// v2: "rpc" for every agent. "terminal" or nil came from the removed terminal-agent bridge;
    /// kept on the wire for older hosts.
    public var runtime: String?
    /// v2: RPC agents only.
    public var stats: NativeThreadStats?
    /// v2: RPC agents only.
    public var commands: [NativeCommand]?
    /// v2: native child runs (RPC agents with the children extension). nil from older hosts.
    public var subagents: [NativeSubagent]?
    /// v3: the messages the host holds for pi. nil from older hosts (they send straight to pi).
    public var queue: NativeQueue?
    /// v4: what fills the model's context window (`native.context.v1`). nil from older hosts,
    /// which get no context meter.
    public var context: NativeThreadContext?

    public var isRPC: Bool { runtime == "rpc" }

    public init(
        piSessionID: String, generation: String, revision: UInt64, running: Bool, model: String? = nil,
        thinking: String? = nil, thinkingLevels: [String]? = nil, supportedActions: [String], dialogsSupported: Bool, dialogs: [NativeThreadDialog],
        widgets: [NativeThreadWidget]? = nil, messages: [NativeThreadMessage], olderCursor: String? = nil,
        provisional: [NativeThreadMessage], clipped: Bool, runtime: String? = nil, stats: NativeThreadStats? = nil,
        commands: [NativeCommand]? = nil, subagents: [NativeSubagent]? = nil, queue: NativeQueue? = nil,
        context: NativeThreadContext? = nil
    ) {
        self.piSessionID = piSessionID
        self.generation = generation
        self.revision = revision
        self.running = running
        self.model = model
        self.thinking = thinking
        self.thinkingLevels = thinkingLevels
        self.supportedActions = supportedActions
        self.dialogsSupported = dialogsSupported
        self.dialogs = dialogs
        self.widgets = widgets
        self.messages = messages
        self.olderCursor = olderCursor
        self.provisional = provisional
        self.clipped = clipped
        self.runtime = runtime
        self.stats = stats
        self.commands = commands
        self.subagents = subagents
        self.queue = queue
        self.context = context
    }
}

public struct NativeThreadMessage: Codable, Hashable, Sendable {
    public var entryID: String
    public var role: String
    public var blocks: [NativeThreadBlock]
    public var toolName: String?
    public var toolCallID: String?
    public var argumentsText: String?
    public var status: String?
    public var isError: Bool?
    public var truncated: Bool
    /// Milliseconds since epoch, when pi stamped the message (turn footers, from-parent captions).
    public var timestamp: Double?
    /// Tool results: milliseconds since epoch when the call began (the issuing assistant
    /// message, or when the host first saw the execution). Absent from older hosts.
    public var startedAt: Double?
    /// Assistant messages: how long the model thought before answering, when the host
    /// observed it streaming. Absent from older hosts and for history it never saw live.
    public var thinkingSeconds: Double?
    /// v3, user messages Shepherd delivered: steered in, or from the queue.
    public var origin: NativeMessageOrigin?
    /// v3, user messages: the `send` that became this message. A host's pending row
    /// ("pending:<id>") and pi's message share it, so the turn keeps its identity.
    public var operationID: UUID?
    /// v4, role "compactionSummary" (a compaction and what the agent kept) and role "compaction"
    /// (one running, or stopped, as a live row). Older clients ignore both.
    public var compaction: NativeCompaction?

    public init(
        entryID: String, role: String, blocks: [NativeThreadBlock], toolName: String? = nil, toolCallID: String? = nil,
        argumentsText: String? = nil, status: String? = nil, isError: Bool? = nil, truncated: Bool = false, timestamp: Double? = nil,
        startedAt: Double? = nil, thinkingSeconds: Double? = nil, origin: NativeMessageOrigin? = nil, operationID: UUID? = nil,
        compaction: NativeCompaction? = nil
    ) {
        self.entryID = entryID
        self.role = role
        self.blocks = blocks
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.argumentsText = argumentsText
        self.status = status
        self.isError = isError
        self.truncated = truncated
        self.timestamp = timestamp
        self.startedAt = startedAt
        self.thinkingSeconds = thinkingSeconds
        self.origin = origin
        self.operationID = operationID
        self.compaction = compaction
    }
}

public struct NativeThreadBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case text, thinking, unsupportedImage }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct NativeThreadDialog: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case select, confirm, input, editor }
    public var id: String
    public var kind: Kind
    public var title: String
    public var options: [String]?
    public var message: String?
    public var placeholder: String?
    public var prefill: String?
    public var timeout: Double?
    public var unavailable: String?

    public init(
        id: String, kind: Kind, title: String, options: [String]? = nil, message: String? = nil,
        placeholder: String? = nil, prefill: String? = nil, timeout: Double? = nil, unavailable: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.options = options
        self.message = message
        self.placeholder = placeholder
        self.prefill = prefill
        self.timeout = timeout
        self.unavailable = unavailable
    }
}

public struct NativeThreadWidget: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable { case status, text, unknown }
    public var namespace: String
    public var key: String
    public var kind: Kind
    public var title: String?
    public var text: String
    // Preserve JS's byte-distinct keys despite Swift's canonical Unicode equality.
    public var id: String { Data(namespace.utf8).base64EncodedString() + ":" + Data(key.utf8).base64EncodedString() }

    private enum CodingKeys: String, CodingKey { case namespace, key, kind, title, text }

    public init(namespace: String, key: String, kind: Kind, title: String? = nil, text: String) {
        self.namespace = namespace
        self.key = key
        self.kind = kind
        self.title = title
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: try values.decode(String.self, forKey: .kind)) ?? .unknown
        // A future kind need not have this version's fields. Keep the thread readable.
        if kind == .unknown {
            namespace = ""; key = ""; title = nil; text = ""
            return
        }
        namespace = try values.decode(String.self, forKey: .namespace)
        key = try values.decode(String.self, forKey: .key)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        text = try values.decode(String.self, forKey: .text)
    }
}
