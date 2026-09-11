import Foundation

public enum NativeThreadRequest: Codable, Hashable, Sendable {
    case snapshot(expectedSessionID: String? = nil, beforeEntryID: String? = nil, afterRevision: UInt64? = nil)
    case send(expectedSessionID: String, generation: String, operationID: UUID, text: String, delivery: NativeThreadDelivery)
    case abort(expectedSessionID: String, generation: String, operationID: UUID)
    case answer(expectedSessionID: String, generation: String, operationID: UUID, dialogID: String, answer: NativeDialogAnswer)
}

public enum NativeThreadDelivery: String, Codable, Hashable, Sendable { case followUp, steer }

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
    public var messages: [NativeThreadMessage]
    public var olderCursor: String?
    public var provisional: [NativeThreadMessage]
    public var clipped: Bool
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
}

public struct NativeThreadBlock: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case text, thinking, unsupportedImage }
    public var kind: Kind
    public var text: String
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
}
