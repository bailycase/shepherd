import Foundation

public enum NativeThreadRequest: Codable, Hashable, Sendable {
    case snapshot(expectedSessionID: String? = nil, beforeEntryID: String? = nil, afterRevision: UInt64? = nil)
    /// `images` is v2 (RPC agents, `sendImages` in `supportedActions`); absent on the wire when nil.
    case send(expectedSessionID: String, generation: String, operationID: UUID, text: String, delivery: NativeThreadDelivery, images: [NativeImage]? = nil)
    case abort(expectedSessionID: String, generation: String, operationID: UUID)
    case answer(expectedSessionID: String, generation: String, operationID: UUID, dialogID: String, answer: NativeDialogAnswer)
    /// v2: `model` is "provider/id". Gated by `setModel` in `supportedActions`.
    case setModel(expectedSessionID: String, generation: String, operationID: UUID, model: String)
    /// v2: off/low/medium/high. Gated by `setThinking` in `supportedActions`.
    case setThinking(expectedSessionID: String, generation: String, operationID: UUID, level: String)
    /// v2 (RPC agents with native children): drive one subagent run. Routed to the children
    /// extension, never to the parent model. `text` is the reply/steer for `.message`.
    case subagentCommand(expectedSessionID: String, generation: String, operationID: UUID, runID: String, action: NativeSubagentAction, text: String? = nil, mode: NativeThreadDelivery? = nil)
    /// v2: one page (50) of a subagent's transcript, newest first, from its session file.
    case subagentTranscript(expectedSessionID: String, runID: String, beforeEntryID: String? = nil)

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

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
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

    public var isRPC: Bool { runtime == "rpc" }

    public init(
        piSessionID: String, generation: String, revision: UInt64, running: Bool, model: String? = nil,
        thinking: String? = nil, supportedActions: [String], dialogsSupported: Bool, dialogs: [NativeThreadDialog],
        widgets: [NativeThreadWidget]? = nil, messages: [NativeThreadMessage], olderCursor: String? = nil,
        provisional: [NativeThreadMessage], clipped: Bool, runtime: String? = nil, stats: NativeThreadStats? = nil,
        commands: [NativeCommand]? = nil, subagents: [NativeSubagent]? = nil
    ) {
        self.piSessionID = piSessionID
        self.generation = generation
        self.revision = revision
        self.running = running
        self.model = model
        self.thinking = thinking
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

    public init(
        entryID: String, role: String, blocks: [NativeThreadBlock], toolName: String? = nil, toolCallID: String? = nil,
        argumentsText: String? = nil, status: String? = nil, isError: Bool? = nil, truncated: Bool = false, timestamp: Double? = nil,
        startedAt: Double? = nil, thinkingSeconds: Double? = nil
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
