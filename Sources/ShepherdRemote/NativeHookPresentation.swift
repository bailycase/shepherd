import Foundation
import ShepherdProtocol

/// A hook's row in the thread (HookThreadScene board): a glyph in its kind's color, the verb, the
/// event and what the hook looked at in mono, and, when the hook said something, a box with its
/// lines and the command's meta, then Open hook. Built from the message's `NativeHookRecord`, or
/// from the message's text when an older host sent none.
public struct NativeHookRow: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable, CaseIterable {
        case ran, denied, sentBack, added, failed, context, asked, systemMessage
    }

    public enum Link: Equatable, Hashable, Sendable {
        /// Settings › Hooks with the hook's editor open.
        case openHook(hash: String)
    }

    public var kind: Kind
    public var verb: String
    /// "PreToolUse · Edit|Write · edit .env".
    public var detail: String
    public var lines: [String]
    public var meta: String?
    public var link: Link?

    /// Whether the row has a box to disclose.
    public var hasBox: Bool { !lines.isEmpty || (meta != nil && kind != .ran) }

    /// What the row says to VoiceOver and Copy.
    public var spoken: String { [verb, detail].filter { !$0.isEmpty }.joined(separator: ", ") }

    public init(kind: Kind, verb: String, detail: String, lines: [String] = [], meta: String? = nil, link: Link? = nil) {
        self.kind = kind; self.verb = verb; self.detail = detail; self.lines = lines; self.meta = meta; self.link = link
    }

    /// The row a record draws.
    public init(_ record: NativeHookRecord) {
        let kind = Kind(rawValue: record.kind) ?? .ran
        let parts = [record.event, record.detail ?? record.name].compactMap { $0 }.filter { !$0.isEmpty }
        let link: Link? = switch kind {
        case .denied, .failed, .added, .sentBack, .context: record.hash.map { .openHook(hash: $0) }
        case .ran, .asked, .systemMessage: nil
        }
        self.init(kind: kind, verb: Self.verb(kind, event: record.event, meta: record.meta), detail: parts.joined(separator: " · "),
                  lines: record.lines, meta: record.meta, link: link)
    }

    /// The row a message with no record draws: its text as the verb, as a remote client shows it.
    public init(text: String) {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let rest = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init)
        self.init(kind: .ran, verb: first, detail: "", lines: Array(rest.prefix(NativeHookRecord.maxLines)))
    }

    /// The board's words for each kind ("A hook denied a tool call").
    static func verb(_ kind: Kind, event: String, meta: String?) -> String {
        switch kind {
        case .ran: "Ran a hook"
        case .denied:
            switch event {
            case "UserPromptSubmit": "A hook blocked your message"
            case "PreToolUse": "A hook denied a tool call"
            default: "A hook blocked this"
            }
        case .sentBack: event == "PostToolUse" ? "A hook sent feedback to the agent" : "A hook sent the agent back"
        case .added: "Added a hook"
        case .failed: (meta ?? "").contains("timed out") ? "A hook timed out; the agent went ahead" : "A hook failed"
        case .context: "A hook added context"
        case .asked: "A hook asked you first"
        case .systemMessage: "A hook says"
        }
    }
}

/// A hook the agent proposes (`hook_propose`, docs/hooks.md › Proposals): the select request whose
/// title is the marker line and the card's JSON. The app draws it as the proposal card.
public struct NativeHookProposal: Equatable, Sendable {
    public static let marker = "shepherd.hook.proposal"
    /// The options the runtime offers, answered verbatim.
    public static let addToSpace = "Add to this space"
    public static let addToMac = "Add to this Mac"
    public static let notNow = "Not now"

    public struct Test: Equatable, Sendable, Decodable {
        public var ok: Bool
        public var summary: String
        public var exit: Int?
        public var ms: Int?
    }
    public struct Scopes: Equatable, Sendable, Decodable {
        public var space: String?
        public var mac: String
    }

    public var dialogID: String
    public var name: String
    public var event: String
    public var matcher: String
    public var command: String
    public var statusMessage: String?
    public var timeout: Double?
    public var scopes: Scopes
    /// "space" or "mac": the one the agent picked.
    public var scope: String
    public var test: Test?
    /// The options the request offers (a space-less thread has no "Add to this space").
    public var options: [String]

    private struct Card: Decodable {
        var name: String
        var event: String
        var matcher: String?
        var command: String
        var statusMessage: String?
        var timeout: Double?
        var scopes: Scopes
        var scope: String?
        var test: Test?
    }

    /// The proposal a dialog carries; nil for every other dialog.
    public init?(dialog: NativeThreadDialog) {
        guard dialog.kind == .select, dialog.title.hasPrefix(Self.marker + "\n"),
              let card = try? JSONDecoder().decode(Card.self, from: Data(dialog.title.dropFirst(Self.marker.count + 1).utf8)) else { return nil }
        dialogID = dialog.id
        name = card.name; event = card.event; matcher = card.matcher ?? ""; command = card.command
        statusMessage = card.statusMessage; timeout = card.timeout; scopes = card.scopes
        scope = card.scope == "space" && card.scopes.space != nil ? "space" : "mac"
        test = card.test
        options = dialog.options ?? []
    }

    /// The option that adds the hook in `scope`.
    public func addOption(scope: String) -> String { scope == "space" ? Self.addToSpace : Self.addToMac }
    /// The file the hook is saved in for `scope`.
    public func path(scope: String) -> String { scope == "space" ? (scopes.space ?? scopes.mac) : scopes.mac }
    /// The test's meta ("exit 0 · 0.4 s").
    public var testMeta: String? {
        guard let test else { return nil }
        let parts = [test.exit.map { "exit \($0)" }, test.ms.map { $0 < 1000 ? "\($0) ms" : String(format: "%.1f s", Double($0) / 1000) }]
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }
}

/// A `PreToolUse` hook's `ask` (docs/hooks.md › In the thread): the select request whose title is
/// "A hook asks before this runs", the call, the reason and the hook's file, with Deny and Allow once.
public struct NativeHookAsk: Equatable, Sendable {
    public static let title = "A hook asks before this runs"
    public static let deny = "Deny"
    public static let allow = "Allow once"

    public var dialogID: String
    public var call: String
    public var reason: String
    public var file: String

    public init?(dialog: NativeThreadDialog) {
        guard dialog.kind == .select, dialog.title.hasPrefix(Self.title),
              Set(dialog.options ?? []) == [Self.deny, Self.allow] else { return nil }
        let parts = dialog.title.components(separatedBy: "\n\n")
        dialogID = dialog.id
        call = parts.count > 1 ? parts[1] : ""
        reason = parts.count > 2 ? parts[2] : ""
        file = parts.count > 3 ? parts[3...].joined(separator: "\n\n") : ""
    }
}

/// A dialog the thread draws as a hook's own piece instead of the question dock.
public enum NativeHookPrompt: Equatable, Sendable {
    case proposal(NativeHookProposal)
    case ask(NativeHookAsk)

    public init?(_ dialog: NativeThreadDialog?) {
        guard let dialog else { return nil }
        if let proposal = NativeHookProposal(dialog: dialog) { self = .proposal(proposal) }
        else if let ask = NativeHookAsk(dialog: dialog) { self = .ask(ask) }
        else { return nil }
    }

    public var dialogID: String {
        switch self {
        case .proposal(let proposal): proposal.dialogID
        case .ask(let ask): ask.dialogID
        }
    }
}
