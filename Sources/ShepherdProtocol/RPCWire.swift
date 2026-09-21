import Foundation

// Wire types for `pi --mode rpc` (pi's docs/rpc.md). Decoding is lenient by
// design: unknown fields are ignored, unknown event types become
// `.unknown(type:)`, and free-form payloads (`data`, `args`, `usage`) are kept
// as `JSONValue` so callers decode what they need. pi's formats are not a
// contract we control.

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
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
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
    case getState
    case getMessages
    case getSessionStats
    case getCommands
    case setModel(provider: String, modelId: String)
    case setThinkingLevel(level: String)
    case newSession
    case extensionUIResponse(id: String, value: String? = nil, confirmed: Bool? = nil, cancelled: Bool? = nil)

    /// The wire `type` field.
    public var type: String {
        switch self {
        case .prompt: return "prompt"
        case .abort: return "abort"
        case .getState: return "get_state"
        case .getMessages: return "get_messages"
        case .getSessionStats: return "get_session_stats"
        case .getCommands: return "get_commands"
        case .setModel: return "set_model"
        case .setThinkingLevel: return "set_thinking_level"
        case .newSession: return "new_session"
        case .extensionUIResponse: return "extension_ui_response"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, message, images, streamingBehavior, provider, modelId, level, id, value, confirmed, cancelled
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
        case .abort, .getState, .getMessages, .getSessionStats, .getCommands, .newSession:
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
    public var id: String?
    public var command: String
    public var success: Bool
    public var data: JSONValue?
    public var error: String?

    public init(id: String? = nil, command: String, success: Bool, data: JSONValue? = nil, error: String? = nil) {
        self.id = id
        self.command = command
        self.success = success
        self.data = data
        self.error = error
    }

    enum CodingKeys: String, CodingKey { case id, command, success, data, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? false
        data = try c.decodeIfPresent(JSONValue.self, forKey: .data)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Messages

public enum RPCContentBlock: Codable, Hashable, Sendable {
    case text(String)
    case thinking(String)
    case toolCall(id: String, name: String, arguments: JSONValue?)
    case image(mimeType: String, data: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey { case type, text, thinking, id, name, arguments, mimeType, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .thinking) ?? "")
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

    public init(
        role: String, content: [RPCContentBlock], toolName: String? = nil, toolCallId: String? = nil,
        isError: Bool? = nil, stopReason: String? = nil, errorMessage: String? = nil, timestamp: Double? = nil
    ) {
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolCallId = toolCallId
        self.isError = isError
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey { case role, content, toolName, toolCallId, isError, stopReason, errorMessage, timestamp }

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
    case messageUpdate(delta: RPCAssistantDelta, usage: JSONValue?)
    case messageEnd(message: RPCMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, args: JSONValue?)
    case toolExecutionUpdate(toolCallId: String, toolName: String, args: JSONValue?, partialResult: RPCToolResult?)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: RPCToolResult?, isError: Bool)
    case queueUpdate(steering: [String], followUp: [String])
    case extensionUIRequest(RPCExtensionUIRequest)
    case extensionError(extensionPath: String?, event: String?, error: String)
    case unknown(type: String)

    enum CodingKeys: String, CodingKey {
        case type, messages, willRetry, message, toolResults, assistantMessageEvent, usage
        case toolCallId, toolName, args, partialResult, result, isError, steering, followUp
        case extensionPath, event, error
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
            self = .messageUpdate(
                delta: try c.decode(RPCAssistantDelta.self, forKey: .assistantMessageEvent),
                usage: try c.decodeIfPresent(JSONValue.self, forKey: .usage)
            )
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
