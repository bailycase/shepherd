import Foundation

/// What an agent's browser tools ask of its thread's Browser page (`Extensions/shepherd-browser.ts`,
/// docs/browser.md). The agent is never named here: the server serves a request only on the
/// connection that registered as that agent (`ExtensionMessage.helloBrowser`), so a tool can act
/// only on its own thread's page.
///
/// On the wire a request is an object with an `action` and that action's parameters, all optional
/// but the ones the action needs (`{"action":"click","ref":"e12","double":true}`). Free-text
/// parameters stay strings (`direction`, `key`) so a bad one is answered `invalid` rather than
/// dropped as undecodable.
public enum BrowserRequest: Codable, Hashable, Sendable {
    /// Load a page (http, https or about:blank) and wait for it to finish.
    case open(url: String, note: String?)
    /// A text snapshot of the page (or of `selector`'s element) with a ref for every element the
    /// agent may act on. `maxChars` caps the snapshot (default 30 000, at most 60 000).
    case read(selector: String?, maxChars: Int?)
    case click(ref: String, double: Bool, note: String?)
    /// Type into a field. `clear` replaces what is there; `submit` presses Enter afterwards.
    case type(ref: String, text: String, clear: Bool, submit: Bool, note: String?)
    case press(key: String, note: String?)
    /// `direction` is up, down, left, right, top or bottom; with a `ref` and no direction the
    /// element is scrolled into view, with a direction it is the container that scrolls.
    case scroll(direction: String?, amount: Int?, ref: String?, note: String?)
    /// Wait for `text` (or, with `gone`, for it to disappear), for `ref` to show (or go), or
    /// `ms` milliseconds; at most `timeout` seconds (default 10, at most 30).
    case wait(text: String?, ref: String?, gone: Bool, ms: Int?, timeout: Double?)
    /// The visible viewport, or with a `ref` that element.
    case screenshot(ref: String?)
    /// The page's console lines and network count; `clear` empties them afterwards.
    case console(clear: Bool)
    /// Run an expression (or statements that `return` a value) in the page and answer its value
    /// as JSON.
    case eval(expression: String, note: String?)
    case back(note: String?)
    case forward(note: String?)
    case reload(note: String?)

    /// Caps on what a request may carry.
    public static let maxTextLength = 20_000
    public static let maxExpressionLength = 20_000
    public static let maxSnapshotChars = 60_000
    public static let defaultSnapshotChars = 30_000
    public static let maxWaitSeconds = 30.0
    public static let defaultWaitSeconds = 10.0

    private enum CodingKeys: String, CodingKey {
        case action, url, note, selector, maxChars, ref, double, text, clear, submit
        case key, direction, amount, gone, ms, timeout, expression
    }

    /// The wire name of the action.
    public enum Action: String, Codable, CaseIterable, Sendable {
        case open, read, click, type, press, scroll, wait, screenshot, console, eval, back, forward, reload
    }

    public var action: Action {
        switch self {
        case .open: .open
        case .read: .read
        case .click: .click
        case .type: .type
        case .press: .press
        case .scroll: .scroll
        case .wait: .wait
        case .screenshot: .screenshot
        case .console: .console
        case .eval: .eval
        case .back: .back
        case .forward: .forward
        case .reload: .reload
        }
    }

    /// The agent's own words for what it is doing, if it gave any.
    public var note: String? {
        switch self {
        case .open(_, let note), .click(_, _, let note), .type(_, _, _, _, let note), .press(_, let note),
             .scroll(_, _, _, let note), .eval(_, let note), .back(let note), .forward(let note), .reload(let note):
            note
        case .read, .wait, .screenshot, .console:
            nil
        }
    }

    /// Reading, waiting, screenshots and the console still work after the user takes over; every
    /// other action is refused (`taken_over`).
    public var isObservation: Bool {
        switch self {
        case .read, .wait, .screenshot, .console: true
        case .open, .click, .type, .press, .scroll, .eval, .back, .forward, .reload: false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let note = try c.decodeIfPresent(String.self, forKey: .note)
        switch try c.decode(Action.self, forKey: .action) {
        case .open:
            self = .open(url: try c.decode(String.self, forKey: .url), note: note)
        case .read:
            self = .read(selector: try c.decodeIfPresent(String.self, forKey: .selector),
                         maxChars: try c.decodeIfPresent(Int.self, forKey: .maxChars))
        case .click:
            self = .click(ref: try c.decode(String.self, forKey: .ref),
                          double: try c.decodeIfPresent(Bool.self, forKey: .double) ?? false, note: note)
        case .type:
            self = .type(ref: try c.decode(String.self, forKey: .ref), text: try c.decode(String.self, forKey: .text),
                         clear: try c.decodeIfPresent(Bool.self, forKey: .clear) ?? false,
                         submit: try c.decodeIfPresent(Bool.self, forKey: .submit) ?? false, note: note)
        case .press:
            self = .press(key: try c.decode(String.self, forKey: .key), note: note)
        case .scroll:
            self = .scroll(direction: try c.decodeIfPresent(String.self, forKey: .direction),
                           amount: try c.decodeIfPresent(Int.self, forKey: .amount),
                           ref: try c.decodeIfPresent(String.self, forKey: .ref), note: note)
        case .wait:
            self = .wait(text: try c.decodeIfPresent(String.self, forKey: .text), ref: try c.decodeIfPresent(String.self, forKey: .ref),
                         gone: try c.decodeIfPresent(Bool.self, forKey: .gone) ?? false,
                         ms: try c.decodeIfPresent(Int.self, forKey: .ms), timeout: try c.decodeIfPresent(Double.self, forKey: .timeout))
        case .screenshot:
            self = .screenshot(ref: try c.decodeIfPresent(String.self, forKey: .ref))
        case .console:
            self = .console(clear: try c.decodeIfPresent(Bool.self, forKey: .clear) ?? false)
        case .eval:
            self = .eval(expression: try c.decode(String.self, forKey: .expression), note: note)
        case .back:
            self = .back(note: note)
        case .forward:
            self = .forward(note: note)
        case .reload:
            self = .reload(note: note)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(note, forKey: .note)
        switch self {
        case .open(let url, _):
            try c.encode(url, forKey: .url)
        case .read(let selector, let maxChars):
            try c.encodeIfPresent(selector, forKey: .selector)
            try c.encodeIfPresent(maxChars, forKey: .maxChars)
        case .click(let ref, let double, _):
            try c.encode(ref, forKey: .ref)
            if double { try c.encode(true, forKey: .double) }
        case .type(let ref, let text, let clear, let submit, _):
            try c.encode(ref, forKey: .ref)
            try c.encode(text, forKey: .text)
            if clear { try c.encode(true, forKey: .clear) }
            if submit { try c.encode(true, forKey: .submit) }
        case .press(let key, _):
            try c.encode(key, forKey: .key)
        case .scroll(let direction, let amount, let ref, _):
            try c.encodeIfPresent(direction, forKey: .direction)
            try c.encodeIfPresent(amount, forKey: .amount)
            try c.encodeIfPresent(ref, forKey: .ref)
        case .wait(let text, let ref, let gone, let ms, let timeout):
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(ref, forKey: .ref)
            if gone { try c.encode(true, forKey: .gone) }
            try c.encodeIfPresent(ms, forKey: .ms)
            try c.encodeIfPresent(timeout, forKey: .timeout)
        case .screenshot(let ref):
            try c.encodeIfPresent(ref, forKey: .ref)
        case .console(let clear):
            if clear { try c.encode(true, forKey: .clear) }
        case .eval(let expression, _):
            try c.encode(expression, forKey: .expression)
        case .back, .forward, .reload:
            break
        }
    }
}

/// A screenshot on the wire: base64 image bytes and their media type.
public struct BrowserImage: Codable, Hashable, Sendable {
    public var data: String
    public var mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// The page's answer to a `BrowserRequest`, before the server stamps it with the request id: text
/// (and for a screenshot an image), or a failure whose `code` is one of `invalid`, `taken_over`,
/// `no_page`, `no_such_ref`, `stale_ref`, `disabled`, `hidden`, `covered`, `refused_url`,
/// `timeout`, `navigation_failed`, `script_error`, `unavailable`, `not_registered`, `no_such_agent`,
/// `not_a_thread` or (an agent on another Mac, whose viewer left) `viewer_gone`, and whose `message`
/// is written for the agent to read.
public enum BrowserOutcome: Hashable, Sendable {
    case result(text: String, image: BrowserImage?)
    case failure(code: String, message: String)

    /// A reply stays under the frame cap (`NDJSON.maxPayloadBytes`, 1 MiB) whatever the page holds:
    /// text is cut at 64 KB (worst case six bytes of escape per byte) and an image's base64 at 400 KB
    /// (a 300 KB picture).
    public static let maxTextBytes = 64 * 1024
    public static let maxImageBase64Bytes = 400 * 1024
    public static let truncationMark = "\n[truncated]"

    public static func text(_ text: String) -> BrowserOutcome { .result(text: text, image: nil) }

    /// `text` cut to at most `limit` UTF-8 bytes on a character boundary, with the mark where it
    /// was cut.
    public static func truncated(_ text: String, toBytes limit: Int = maxTextBytes) -> String {
        guard text.utf8.count > limit else { return text }
        let mark = truncationMark
        var end = text.startIndex
        var used = 0
        let room = max(0, limit - mark.utf8.count)
        for index in text.indices {
            let size = text[index].utf8.count
            if used + size > room { break }
            used += size
            end = text.index(after: index)
        }
        return String(text[..<end]) + mark
    }

    /// The wire reply for request `id`: a failure is the generic `error` reply.
    public func reply(id: Int) -> ExtensionReply {
        switch self {
        case .result(let text, let image):
            var text = Self.truncated(text)
            var image = image
            if let held = image, held.data.utf8.count > Self.maxImageBase64Bytes {
                image = nil
                text += "\n[the screenshot was too large to send]"
            }
            return .browserResult(id: id, text: text, image: image)
        case .failure(let code, let message):
            return .error(id: id, code: code, message: Self.truncated(message, toBytes: 8 * 1024))
        }
    }
}
