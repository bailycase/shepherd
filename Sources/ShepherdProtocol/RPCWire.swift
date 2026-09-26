import Foundation

// Wire types for `pi --mode rpc` (pi's docs/rpc.md). Decoding is lenient by
// design: unknown fields are ignored, unknown event types become
// `.unknown(type:)`, and free-form payloads (`data`, `args`) are kept as
// `JSONValue` so callers decode what they need; `get_messages` alone decodes
// its history typed, falling back to JSON when it does not fit. pi's formats
// are not a contract we control.

/// An arbitrary JSON document.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Most values are strings and objects: try those first, since every failed attempt
        // builds a DecodingError. Bool stays ahead of Double so true and false are never numbers.
        if c.decodeNil() {
            self = .null
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Re-decode this value as a concrete type.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

// MARK: - Commands (stdin)

public struct RPCImage: Codable, Hashable, Sendable {
    public var data: String
    public var mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    enum CodingKeys: String, CodingKey { case type, data, mimeType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(String.self, forKey: .data)
        mimeType = try c.decode(String.self, forKey: .mimeType)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("image", forKey: .type)
        try c.encode(data, forKey: .data)
        try c.encode(mimeType, forKey: .mimeType)
    }
}

public enum RPCStreamingBehavior: String, Codable, Hashable, Sendable { case steer, followUp }

public enum RPCCommand: Encodable, Hashable, Sendable {
    case prompt(message: String, images: [RPCImage] = [], streamingBehavior: RPCStreamingBehavior? = nil)
    case abort
    /// Empties pi's steering and follow-up queues and answers with their text.
    case clearQueue
    case getState
    case getMessages
    case getSessionStats
    case getCommands
    case setModel(provider: String, modelId: String)
    case setThinkingLevel(level: String)
    /// The levels the session's current model takes (`{"levels": [...]}`).
    case getAvailableThinkingLevels
    case newSession
    case extensionUIResponse(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil)
    /// Summarize the conversation now, keeping what `customInstructions` asks for. pi answers
    /// once the summary is written, with its result. (Never `set_auto_compaction`: pi writes
    /// that to the user's settings.json.)
    case compact(customInstructions: String? = nil)

    /// The wire `type` field.
    public var type: String {
        switch self {
        case .prompt: return "prompt"
        case .abort: return "abort"
        case .clearQueue: return "clear_queue"
        case .getState: return "get_state"
        case .getMessages: return "get_messages"
        case .getSessionStats: return "get_session_stats"
        case .getCommands: return "get_commands"
        case .setModel: return "set_model"
        case .setThinkingLevel: return "set_thinking_level"
        case .getAvailableThinkingLevels: return "get_available_thinking_levels"
        case .newSession: return "new_session"
        case .extensionUIResponse: return "extension_ui_response"
        case .compact: return "compact"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, message, images, streamingBehavior, provider, modelId, level, id, value, confirmed, cancelled, customInstructions
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        switch self {
        case .prompt(let message, let images, let streamingBehavior):
            try c.encode(message, forKey: .message)
            if !images.isEmpty { try c.encode(images, forKey: .images) }
            try c.encodeIfPresent(streamingBehavior, forKey: .streamingBehavior)
        case .setModel(let provider, let modelId):
            try c.encode(provider, forKey: .provider)
            try c.encode(modelId, forKey: .modelId)
        case .setThinkingLevel(let level):
            try c.encode(level, forKey: .level)
        case .extensionUIResponse(let id, let value, let confirmed, let cancelled):
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(value, forKey: .value)
            try c.encodeIfPresent(confirmed, forKey: .confirmed)
            try c.encodeIfPresent(cancelled, forKey: .cancelled)
        case .compact(let customInstructions):
            try c.encodeIfPresent(customInstructions, forKey: .customInstructions)
        case .abort, .clearQueue, .getState, .getMessages, .getSessionStats, .getCommands, .getAvailableThinkingLevels, .newSession:
            break
        }
    }
}

/// One stdin record: a command plus its optional correlation id.
public struct RPCCommandFrame: Encodable, Sendable {
    public var id: String?
    public var command: RPCCommand

    public init(id: String?, command: RPCCommand) {
        self.id = id
        self.command = command
    }

    enum CodingKeys: String, CodingKey { case id }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try command.encode(to: encoder)
    }
}

// MARK: - Responses (stdout)

public struct RPCResponse: Decodable, Hashable, Sendable {
    /// `data`, kept as JSON except where a large payload has a type of its own.
    public enum Payload: Hashable, Sendable {
        case json(JSONValue)
        /// `get_messages`' `data.messages`, decoded in the record's own decode: a long session's
        /// history is one multi-megabyte record, and a JSONValue tree re-encoded to decode it
        /// again cost several times the typed decode.
        case messages([RPCMessage])
    }

    public var id: String?
    public var command: String
    public var success: Bool
    public var payload: Payload?
    public var error: String?

    public init(id: String? = nil, command: String, success: Bool, data: JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.command = command
        self.success = success
        self.payload = data.map(Payload.json)
        self.error = error
    }

    /// `data` as JSON; nil when it decoded as a typed payload.
    public var data: JSONValue? {
        if case .json(let value) = payload { return value }
        return nil
    }

    /// `get_messages`' messages, from the typed payload or else leniently from the JSON.
    public var messages: [RPCMessage]? {
        switch payload {
        case .messages(let messages): messages
        case .json(let value): try? value["messages"]?.decode([RPCMessage].self)
        case nil: nil
        }
    }

    /// `get_available_thinking_levels`' levels, in pi's order; nil when it failed (a pi without
    /// the command) or named none.
    public var thinkingLevels: [String]? {
        guard success, let levels = data?["levels"]?.arrayValue?.compactMap(\.stringValue), !levels.isEmpty else { return nil }
        return levels
    }

    enum CodingKeys: String, CodingKey { case id, command, success, data, error }

    private struct MessagesData: Decodable {
        let messages: [RPCMessage]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? false
        if command == "get_messages", let typed = try? c.decode(MessagesData.self, forKey: .data) {
            payload = .messages(typed.messages)
        } else {
            // Anything the typed payload does not fit keeps the lenient path.
            payload = try c.decodeIfPresent(JSONValue.self, forKey: .data).map(Payload.json)
        }
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Messages

public enum RPCContentBlock: Codable, Hashable, Sendable {
    case text(String)
    /// The reasoning a reader can read, or "" when the provider kept it back (see
    /// `readableThinking`).
    case thinking(String)
    case toolCall(id: String, name: String, arguments: JSONValue?)
    case image(mimeType: String, data: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey { case type, text, thinking, thinkingSignature, redacted, id, name, arguments, mimeType, data }

    /// What pi-ai writes as the text of Anthropic's `redacted_thinking` (flagged `redacted`);
    /// a streamed `thinking_end` carries it without the flag.
    public static let redactedThinkingPlaceholder = "[Reasoning redacted]"

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(Self.readableThinking(
                try c.decodeIfPresent(String.self, forKey: .thinking) ?? "",
                signature: try? c.decodeIfPresent(String.self, forKey: .thinkingSignature),
                redacted: (try? c.decodeIfPresent(Bool.self, forKey: .redacted)) ?? false))
        case "toolCall":
            self = .toolCall(
                id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                arguments: try c.decodeIfPresent(JSONValue.self, forKey: .arguments)
            )
        case "image":
            self = .image(
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "",
                data: try c.decodeIfPresent(String.self, forKey: .data) ?? ""
            )
        default:
            self = .unknown(type: type)
        }
    }

    /// pi-ai keeps reasoning it cannot show as a thinking block: Anthropic's `redacted_thinking`
    /// (`redacted`, the placeholder as its text), and encrypted or omitted reasoning (OpenAI's
    /// `encrypted_content`, Anthropic's omitted display, a proxy that streams none) with empty
    /// text and the opaque payload in `thinkingSignature`. Those read as "". A summary pi left
    /// only in the signature (OpenRouter's `reasoning_details` without `reasoning` deltas, an
    /// OpenAI Responses reasoning item) is read from there.
    static func readableThinking(_ text: String, signature: String?, redacted: Bool) -> String {
        if redacted { return "" }
        if text.contains(where: { !$0.isWhitespace }) { return normalizedThinking(text) }
        guard let signature, let first = signature.first(where: { !$0.isWhitespace }), first == "[" || first == "{",
              let json = try? JSONSerialization.jsonObject(with: Data(signature.utf8)) else { return "" }
        let parts: [String]
        if let details = json as? [[String: Any]] {
            // openai-completions: reasoning.summary / reasoning.text details (reasoning.encrypted is opaque).
            parts = details.compactMap { detail in
                switch detail["type"] as? String {
                case "reasoning.summary": detail["summary"] as? String
                case "reasoning.text": detail["text"] as? String
                default: nil
                }
            }
        } else if let item = json as? [String: Any], item["type"] as? String == "reasoning" {
            // openai-responses: the reasoning item, its summary first.
            let texts = { (key: String) in ((item[key] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String } }
            let summary = texts("summary")
            parts = summary.isEmpty ? texts("content") : summary
        } else {
            parts = []
        }
        return normalizedThinking(parts.joined(separator: "\n\n"))
    }

    /// Thinking text as a reader sees it: no whitespace before or after it, and no more than one
    /// blank line anywhere in it (a whitespace-only line counts as blank), so empty summary parts
    /// leave no gap. pi-ai closes every OpenAI Responses summary part with a blank line as it
    /// streams, and joins a finished item's parts with one, empty parts included.
    ///
    /// Growing text only grows its normalized form (it is a prefix-preserving map): a trailing
    /// space it drops mid-stream comes back once the next word follows it.
    public static func normalizedThinking(_ text: String) -> String {
        var result = ""
        var blank = false
        // Split on the UTF-16 newline: it splits "\r\n" too, which is one Character.
        for line in text.components(separatedBy: "\n") {
            if line.allSatisfy(\.isWhitespace) {
                blank = true
                continue
            }
            if !result.isEmpty { result += blank ? "\n\n" : "\n" }
            result += line
            blank = false
        }
        guard let first = result.firstIndex(where: { !$0.isWhitespace }),
              let last = result.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return first == result.startIndex && result.index(after: last) == result.endIndex ? result : String(result[first...last])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .thinking(let thinking):
            try c.encode("thinking", forKey: .type)
            try c.encode(thinking, forKey: .thinking)
        case .toolCall(let id, let name, let arguments):
            try c.encode("toolCall", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encodeIfPresent(arguments, forKey: .arguments)
        case .image(let mimeType, let data):
            try c.encode("image", forKey: .type)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encode(data, forKey: .data)
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

/// Lenient `AgentMessage`: user, assistant, toolResult, bashExecution, or
/// anything pi adds later. A string `content` (user messages) decodes as one
/// text block.
public struct RPCMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: [RPCContentBlock]
    public var toolName: String?
    public var toolCallId: String?
    public var isError: Bool?
    public var stopReason: String?
    /// Assistant messages with `stopReason: "error"` carry the provider error here.
    public var errorMessage: String?
    public var timestamp: Double?
    /// `custom` messages: extensions mark model-only payloads `display: false`.
    public var customType: String?
    public var display: Bool?
    /// `compactionSummary` and `branchSummary` messages: what pi summarized, and (compaction)
    /// the context it replaced.
    public var summary: String?
    public var tokensBefore: Double?
    /// `system` messages (pi 0.87's structured prompt): named prompt sections, a null deleting an
    /// earlier one, and the tools added or removed. Decoded only for that role.
    public var sections: [String: String?]?
    public var toolsAdded: [JSONValue]?
    public var toolsRemoved: [JSONValue]?
    /// Assistant messages that failed (`stopReason: "error"`): the provider and model the
    /// request went to. Decoded only for those, so a long history's decode stays as it was.
    public var provider: String?
    public var model: String?

    public init(
        role: String, content: [RPCContentBlock], toolName: String? = nil, toolCallId: String? = nil,
        isError: Bool? = nil, stopReason: String? = nil, errorMessage: String? = nil, timestamp: Double? = nil,
        customType: String? = nil, display: Bool? = nil, summary: String? = nil, tokensBefore: Double? = nil,
        sections: [String: String?]? = nil, toolsAdded: [JSONValue]? = nil, toolsRemoved: [JSONValue]? = nil,
        provider: String? = nil, model: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.isError = isError
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
        self.customType = customType
        self.display = display
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.sections = sections
        self.toolsAdded = toolsAdded
        self.toolsRemoved = toolsRemoved
        self.provider = provider
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case role, content, toolName, toolCallId, isError, stopReason, errorMessage, timestamp, customType, display
        case summary, tokensBefore, sections, toolsAdded, toolsRemoved, provider, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        if let blocks = try? c.decode([RPCContentBlock].self, forKey: .content) {
            content = blocks
        } else if let text = try? c.decode(String.self, forKey: .content) {
            content = [.text(text)]
        } else {
            content = []
        }
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        customType = try c.decodeIfPresent(String.self, forKey: .customType)
        display = try c.decodeIfPresent(Bool.self, forKey: .display)
        // Only the roles that carry them: a long history's decode stays as it was.
        switch role {
        case "compactionSummary", "branchSummary":
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
            tokensBefore = try? c.decodeIfPresent(Double.self, forKey: .tokensBefore)
        case "system":
            sections = try? c.decodeIfPresent([String: String?].self, forKey: .sections)
            toolsAdded = try? c.decodeIfPresent([JSONValue].self, forKey: .toolsAdded)
            toolsRemoved = try? c.decodeIfPresent([JSONValue].self, forKey: .toolsRemoved)
        case "assistant" where stopReason == "error":
            provider = try? c.decodeIfPresent(String.self, forKey: .provider)
            model = try? c.decodeIfPresent(String.self, forKey: .model)
        default:
            break
        }
    }
}

/// `compaction_end.result`, and the `compact` command's answer.
public struct RPCCompactionResult: Decodable, Hashable, Sendable {
    public var summary: String?
    public var tokensBefore: Double?
    public var estimatedTokensAfter: Double?
    public var firstKeptEntryId: String?

    public init(summary: String? = nil, tokensBefore: Double? = nil, estimatedTokensAfter: Double? = nil, firstKeptEntryId: String? = nil) {
        self.summary = summary
        self.tokensBefore = tokensBefore
        self.estimatedTokensAfter = estimatedTokensAfter
        self.firstKeptEntryId = firstKeptEntryId
    }
}

/// `message_update.assistantMessageEvent`: `type` is one of text_start,
/// text_delta, text_end, thinking_start, thinking_delta, thinking_end,
/// toolcall_start, toolcall_delta, toolcall_end.
public struct RPCAssistantDelta: Decodable, Hashable, Sendable {
    public var type: String
    public var contentIndex: Int?
    /// text_delta / thinking_delta / toolcall_delta chunk.
    public var delta: String?
    /// text_end / thinking_end full block content.
    public var content: String?
    /// toolcall_start call id.
    public var id: String?
    /// toolcall_start tool name.
    public var toolName: String?
    /// toolcall_end completed call.
    public var toolCall: RPCContentBlock?

    enum CodingKeys: String, CodingKey { case type, contentIndex, delta, content, id, toolName, toolCall }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        contentIndex = try c.decodeIfPresent(Int.self, forKey: .contentIndex)
        delta = try c.decodeIfPresent(String.self, forKey: .delta)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolCall = try c.decodeIfPresent(RPCContentBlock.self, forKey: .toolCall)
    }
}

/// `tool_execution_update.partialResult` / `tool_execution_end.result`.
public struct RPCToolResult: Decodable, Hashable, Sendable {
    public var content: [RPCContentBlock]
    public var details: JSONValue?

    enum CodingKeys: String, CodingKey { case content, details }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent([RPCContentBlock].self, forKey: .content) ?? []
        details = try c.decodeIfPresent(JSONValue.self, forKey: .details)
    }
}

/// `extension_ui_request`. Dialog methods (select/confirm/input/editor)
/// expect an `extension_ui_response`; notify/setStatus/setWidget/setTitle/
/// set_editor_text are fire-and-forget.
public struct RPCExtensionUIRequest: Decodable, Hashable, Sendable {
    public var id: String
    public var method: String
    public var title: String?
    public var message: String?
    public var options: [String]?
    public var placeholder: String?
    public var prefill: String?
    /// Milliseconds; pi auto-resolves the dialog when it elapses.
    public var timeout: Double?
    public var notifyType: String?
    public var statusKey: String?
    public var statusText: String?
    public var widgetKey: String?
    public var widgetLines: [String]?
    public var widgetPlacement: String?
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case id, method, title, message, options, placeholder, prefill, timeout, notifyType
        case statusKey, statusText, widgetKey, widgetLines, widgetPlacement, text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        options = try c.decodeIfPresent([String].self, forKey: .options)
        placeholder = try c.decodeIfPresent(String.self, forKey: .placeholder)
        prefill = try c.decodeIfPresent(String.self, forKey: .prefill)
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
        notifyType = try c.decodeIfPresent(String.self, forKey: .notifyType)
        statusKey = try c.decodeIfPresent(String.self, forKey: .statusKey)
        statusText = try c.decodeIfPresent(String.self, forKey: .statusText)
        widgetKey = try c.decodeIfPresent(String.self, forKey: .widgetKey)
        widgetLines = try c.decodeIfPresent([String].self, forKey: .widgetLines)
        widgetPlacement = try c.decodeIfPresent(String.self, forKey: .widgetPlacement)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }
}

// MARK: - Events (stdout)

public enum RPCEvent: Decodable, Hashable, Sendable {
    case agentStart
    case agentEnd(messages: [RPCMessage], willRetry: Bool)
    case agentSettled
    case turnStart
    case turnEnd(message: RPCMessage?, toolResults: [RPCMessage])
    case messageStart(message: RPCMessage)
    /// pi's `usage` rides every delta; nothing reads it, and decoding it cost most of a delta's
    /// decode, so it is left in the record.
    case messageUpdate(delta: RPCAssistantDelta)
    case messageEnd(message: RPCMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue?)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue?, partialResult: RPCToolResult?)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: RPCToolResult?, isError: Bool)
    case queueUpdate(steering: [String], followUp: [String])
    case extensionUIRequest(RPCExtensionUIRequest)
    case extensionError(extensionPath: String?, event: String?, error: String)
    /// `reason`: manual, threshold, or overflow.
    case compactionStart(reason: String?)
    /// `result` when it succeeded; `aborted` when it was stopped; otherwise `errorMessage` says
    /// why it failed. `willRetry`: an overflow compaction pi retries the prompt after.
    case compactionEnd(reason: String?, result: RPCCompactionResult?, aborted: Bool, willRetry: Bool, errorMessage: String?)
    /// pi retries a request that failed in a way worth retrying: `attempt` of `maxAttempts`,
    /// after `delayMs`.
    case autoRetryStart(attempt: Int, maxAttempts: Int, delayMs: Double, errorMessage: String?)
    /// The retries are over: one worked, or they ran out (or were stopped).
    case autoRetryEnd(success: Bool)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, messages, willRetry, message, toolResults, assistantMessageEvent
        case toolCallId, toolName, args, partialResult, result, isError, steering, followUp
        case extensionPath, event, error, reason, aborted, errorMessage
        case attempt, maxAttempts, delayMs, success
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "agent_start":
            self = .agentStart
        case "agent_end":
            self = .agentEnd(
                messages: try c.decodeIfPresent([RPCMessage].self, forKey: .messages) ?? [],
                willRetry: try c.decodeIfPresent(Bool.self, forKey: .willRetry) ?? false
            )
        case "agent_settled":
            self = .agentSettled
        case "turn_start":
            self = .turnStart
        case "turn_end":
            self = .turnEnd(
                message: try c.decodeIfPresent(RPCMessage.self, forKey: .message),
                toolResults: try c.decodeIfPresent([RPCMessage].self, forKey: .toolResults) ?? []
            )
        case "message_start":
            self = .messageStart(message: try c.decode(RPCMessage.self, forKey: .message))
        case "message_update":
            self = .messageUpdate(delta: try c.decode(RPCAssistantDelta.self, forKey: .assistantMessageEvent))
        case "message_end":
            self = .messageEnd(message: try c.decode(RPCMessage.self, forKey: .message))
        case "tool_execution_start":
            self = .toolExecutionStart(
                toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "",
                toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                args: try c.decodeIfPresent(JSONValue.self, forKey: .args)
            )
        case "tool_execution_update":
            self = .toolExecutionUpdate(
                toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "",
                toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                args: try c.decodeIfPresent(JSONValue.self, forKey: .args),
                partialResult: try c.decodeIfPresent(RPCToolResult.self, forKey: .partialResult)
            )
        case "tool_execution_end":
            self = .toolExecutionEnd(
                toolCallId: try c.decodeIfPresent(String.self, forKey: .toolCallId) ?? "",
                toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                result: try c.decodeIfPresent(RPCToolResult.self, forKey: .result),
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            )
        case "queue_update":
            self = .queueUpdate(
                steering: try c.decodeIfPresent([String].self, forKey: .steering) ?? [],
                followUp: try c.decodeIfPresent([String].self, forKey: .followUp) ?? []
            )
        case "extension_ui_request":
            self = .extensionUIRequest(try RPCExtensionUIRequest(from: decoder))
        case "extension_error":
            self = .extensionError(
                extensionPath: try c.decodeIfPresent(String.self, forKey: .extensionPath),
                event: try c.decodeIfPresent(String.self, forKey: .event),
                error: try c.decodeIfPresent(String.self, forKey: .error) ?? ""
            )
        case "compaction_start":
            self = .compactionStart(reason: try? c.decodeIfPresent(String.self, forKey: .reason))
        case "compaction_end":
            self = .compactionEnd(
                reason: try? c.decodeIfPresent(String.self, forKey: .reason),
                result: try? c.decodeIfPresent(RPCCompactionResult.self, forKey: .result),
                aborted: (try? c.decodeIfPresent(Bool.self, forKey: .aborted)) ?? false,
                willRetry: (try? c.decodeIfPresent(Bool.self, forKey: .willRetry)) ?? false,
                errorMessage: try? c.decodeIfPresent(String.self, forKey: .errorMessage)
            )
        case "auto_retry_start":
            self = .autoRetryStart(
                attempt: (try? c.decodeIfPresent(Int.self, forKey: .attempt)) ?? 1,
                maxAttempts: (try? c.decodeIfPresent(Int.self, forKey: .maxAttempts)) ?? 0,
                delayMs: (try? c.decodeIfPresent(Double.self, forKey: .delayMs)) ?? 0,
                errorMessage: try? c.decodeIfPresent(String.self, forKey: .errorMessage)
            )
        case "auto_retry_end":
            self = .autoRetryEnd(success: (try? c.decodeIfPresent(Bool.self, forKey: .success)) ?? false)
        default:
            self = .unknown(type: type)
        }
    }
}

/// One stdout record: a response to one of our commands, or an event.
public enum RPCIncoming: Decodable, Sendable {
    case response(RPCResponse)
    case event(RPCEvent)

    enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decodeIfPresent(String.self, forKey: .type) == "response" {
            self = .response(try RPCResponse(from: decoder))
        } else {
            self = .event(try RPCEvent(from: decoder))
        }
    }
}
