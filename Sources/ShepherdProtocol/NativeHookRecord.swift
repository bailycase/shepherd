import Foundation

/// A hook's row in a thread (docs/hooks.md › In the thread): the `details` of a `shepherd.hook`
/// custom message, bounded. Absent from older hosts and from rows whose details didn't read;
/// clients then draw the message's text.
public struct NativeHookRecord: Codable, Hashable, Sendable {
    /// "ran", "denied", "sentBack", "added", "failed", "context", "asked", "systemMessage"; a kind
    /// this client doesn't know draws as `ran`.
    public var kind: String
    /// The hook event ("PreToolUse").
    public var event: String
    /// The hook's name: its status message, else the command's first word.
    public var name: String
    /// "Edit|Write · edit .env": the matcher and what the hook looked at.
    public var detail: String?
    /// What the hook said (the reason, the context, the test output), for the row's box.
    public var lines: [String]
    /// "<command> · exit 2 · 41 ms".
    public var meta: String?
    /// The hook's hash, for Open hook.
    public var hash: String?
    /// The hooks file it came from.
    public var file: String?

    /// Bounds for what a row carries: a hook's output is the agent's business, the row shows its start.
    public static let maxLines = 24
    public static let maxText = 2048

    public init(kind: String, event: String, name: String, detail: String? = nil, lines: [String] = [], meta: String? = nil,
                hash: String? = nil, file: String? = nil) {
        self.kind = kind; self.event = event; self.name = name; self.detail = detail
        self.lines = lines; self.meta = meta; self.hash = hash; self.file = file
    }

    /// The record a message's `details` carry, clipped; nil when they aren't the contract's shape.
    public init?(details: JSONValue?) {
        guard let details, let kind = details["kind"]?.stringValue, !kind.isEmpty else { return nil }
        func clip(_ text: String?) -> String? {
            guard let text else { return nil }
            return text.count > Self.maxText ? String(text.prefix(Self.maxText)) + "…" : text
        }
        let lines = (details["lines"]?.arrayValue ?? []).compactMap(\.stringValue)
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
        self.init(kind: clip(kind) ?? kind, event: clip(details["event"]?.stringValue) ?? "", name: clip(details["name"]?.stringValue) ?? "",
                  detail: clip(details["detail"]?.stringValue), lines: lines.prefix(Self.maxLines).compactMap { clip($0) },
                  meta: clip(details["meta"]?.stringValue), hash: clip(details["hash"]?.stringValue), file: clip(details["file"]?.stringValue))
    }
}
