import Foundation
import ShepherdProtocol

/// A failed request to the model as the thread draws it (TurnErrors, ThreadError): a plain
/// title from the status and type, the provider's own words cleaned (keys cut to their ends,
/// links, no JSON or escaped quotes), a few facts, and everything the provider sent back for
/// Details and Copy. Read once per change from pi's `errorMessage`, never in a view.
public struct NativeTurnError: Equatable, Hashable, Sendable {
    /// What went wrong, which picks the title and the glyph.
    public enum Kind: String, Hashable, Sendable {
        case auth, timeout, overloaded, server, rateLimit, network, contextTooLong, other
    }

    /// A run of the message.
    public enum Span: Hashable, Sendable {
        case text(String)
        /// A key cut to its ends, a host, or a name the provider quoted: mono, in the body color.
        case code(String)
        /// A link: `display` is the address without its scheme.
        case link(display: String, url: String)
    }

    /// A run of the raw body, pretty-printed: JSON keys and strings take the syntax colors.
    public enum BodyToken: Hashable, Sendable {
        case plain(String)
        case key(String)
        case string(String)
        /// A key cut to its ends, inside a string.
        case redacted(String)
        /// An address inside a string.
        case link(String)
    }

    /// A row of Details ("Status", "401").
    public struct Fact: Hashable, Sendable {
        public var label: String
        public var value: String
        public var mono: Bool

        public init(_ label: String, _ value: String, mono: Bool = true) {
            self.label = label
            self.value = value
            self.mono = mono
        }
    }

    /// The failed message's entry (the last try's): what keeps its Details open.
    public var id: String
    public var kind: Kind
    /// "OpenAI rejected the API key".
    public var title: String
    /// The provider's words, cleaned.
    public var message: [Span]
    /// Status and type as small chips ("401", "authentication_error").
    public var chips: [String]
    /// "gpt-5 · OpenAI".
    public var source: String?
    /// "Tried 3 times over 31m", after pi's automatic retries.
    public var tries: String?
    /// When it failed: "5:54 PM".
    public var time: String?
    /// The folded line's meta: "401 · 5:52 PM".
    public var foldedMeta: String
    /// Details' rows: provider, model, host, status, type, code, request, time.
    public var facts: [Fact]
    /// Everything the provider sent back, pretty-printed and redacted.
    public var body: [BodyToken]
    /// The whole error as text, redacted the same way (Copy).
    public var copyText: String
    /// Two errors with one signature failed the same way (the earlier one folds).
    public var signature: String

    /// The message as plain text.
    public var messageText: String {
        message.map { span in
            switch span {
            case .text(let text), .code(let text): text
            case .link(_, let url): url
            }
        }.joined()
    }

    /// The glyph beside the title (SF Symbols): an hourglass for a timeout, a crossed-out wave
    /// for the network, arrows in for a thread too long, a warning otherwise.
    public var glyph: String { Self.glyph(kind) }

    public static func glyph(_ kind: Kind) -> String {
        switch kind {
        case .timeout: "hourglass"
        case .network: "wifi.slash"
        case .contextTooLong: "arrow.down.right.and.arrow.up.left"
        default: "exclamationmark.triangle"
        }
    }

    /// `text` is pi's `errorMessage`; `provider` and `model` pi's ids; `host` the machine the
    /// agent runs on. `attempts` counts the failed tries (pi's automatic retries), the first
    /// made at `firstAt` and the last at `at` (ms).
    public init(id: String = "", text: String, provider: String? = nil, model: String? = nil, host: String? = nil, attempts: Int = 1,
                firstAt: Double? = nil, at: Double? = nil, timeZone: TimeZone = .current) {
        self.id = id
        let parsed = NativeProviderError(text)
        let providerName = provider.flatMap { $0.isEmpty ? nil : Self.providerName($0) }
        let host = host.flatMap { $0.isEmpty ? nil : $0 }
        let model = model.flatMap { $0.isEmpty ? nil : $0 }
        let kind = parsed.kind
        self.kind = kind
        title = Self.title(kind, provider: providerName, model: model)

        var chips: [String] = []
        var message: [Span]
        switch kind {
        case .network:
            if let errno = parsed.errno { chips.append(errno) }
            if let host { chips.append(host) }
            let target: Span = parsed.apiHost.map { .code($0) } ?? .text(providerName ?? "The provider")
            let reason = parsed.networkReason
            message = [target, .text(" didn’t answer" + (host.map { " from \($0)" } ?? "") + ": " + reason + ".")]
        case .timeout:
            chips.append("timeout")
            if let status = parsed.status { chips.append(String(status)) }
            message = Self.spans(parsed.message)
        default:
            if let status = parsed.status { chips.append(String(status)) }
            if let label = parsed.label { chips.append(label) }
            message = Self.spans(parsed.message)
        }
        if message.isEmpty { message = [.text("The request failed.")] }
        self.message = message
        self.chips = chips
        let sourceParts = [model, providerName].compactMap { $0 }
        source = sourceParts.isEmpty ? nil : sourceParts.joined(separator: " · ")
        if attempts > 1 {
            var tries = "Tried \(attempts) times"
            if let firstAt, let at, at - firstAt >= 1000 { tries += " over " + Self.spanText((at - firstAt) / 1000) }
            self.tries = tries
        } else {
            tries = nil
        }
        time = at.map { nativeClockText($0, timeZone: timeZone) }
        foldedMeta = ([chips.first, time].compactMap { $0 }).joined(separator: " · ")

        var facts: [Fact] = []
        if let providerName { facts.append(Fact("Provider", providerName, mono: false)) }
        if let model { facts.append(Fact("Model", model)) }
        if let host { facts.append(Fact("Host", host)) }
        if let status = parsed.status { facts.append(Fact("Status", String(status))) }
        if let type = parsed.type { facts.append(Fact("Type", type)) }
        if let code = parsed.code { facts.append(Fact("Code", code)) }
        if let errno = parsed.errno, parsed.code != errno { facts.append(Fact("Error", errno)) }
        if let request = parsed.requestID { facts.append(Fact("Request", request)) }
        if let at { facts.append(Fact("At", Self.secondsClock(at, timeZone: timeZone))) }
        self.facts = facts
        body = parsed.body

        let messageText = message.map { span -> String in
            switch span {
            case .text(let text), .code(let text): text
            case .link(_, let url): url
            }
        }.joined()
        var copy = [title, messageText]
        let line = (chips + [source, tries].compactMap { $0 }).joined(separator: " · ")
        if !line.isEmpty { copy.append(line) }
        if !facts.isEmpty { copy.append("\n" + facts.map { "\($0.label): \($0.value)" }.joined(separator: "\n")) }
        let bodyText = parsed.body.map(\.text).joined()
        if !bodyText.isEmpty { copy.append("\n" + bodyText) }
        copyText = copy.joined(separator: "\n")
        signature = ([kind.rawValue, title] + chips).joined(separator: "|")
    }

    // MARK: Words

    static func title(_ kind: Kind, provider: String?, model: String?) -> String {
        let who = provider ?? "The provider"
        switch kind {
        case .auth: return "\(who) rejected the API key"
        case .timeout: return "\(who) didn’t respond in time"
        case .overloaded: return "\(who) is overloaded"
        case .server: return "\(who) had a server error"
        case .rateLimit: return "Rate limited by \(provider ?? "the provider")"
        case .network: return "Couldn’t reach \(provider ?? "the provider")"
        case .contextTooLong: return "The thread is too long for \(model ?? "the model")"
        case .other: return provider.map { "The request to \($0) failed" } ?? "The model request failed"
        }
    }

    /// pi's provider ids as people write them; an id Shepherd doesn't know shows as it is.
    public static func providerName(_ id: String) -> String {
        let names: [String: String] = [
            "anthropic": "Anthropic", "openai": "OpenAI", "openai-codex": "OpenAI", "azure-openai-responses": "Azure OpenAI",
            "google": "Google", "google-vertex": "Vertex AI", "amazon-bedrock": "Amazon Bedrock", "deepseek": "DeepSeek",
            "openrouter": "OpenRouter", "mistral": "Mistral", "xai": "xAI", "groq": "Groq", "cerebras": "Cerebras",
            "github-copilot": "GitHub Copilot", "fireworks": "Fireworks", "together": "Together", "huggingface": "Hugging Face",
            "moonshotai": "Moonshot AI", "moonshotai-cn": "Moonshot AI", "kimi-coding": "Kimi", "minimax": "MiniMax",
            "minimax-cn": "MiniMax", "zai": "Z.ai", "zai-coding-cn": "Z.ai", "nvidia": "NVIDIA", "meta": "Meta",
            "vercel-ai-gateway": "Vercel AI Gateway", "cloudflare-ai-gateway": "Cloudflare AI Gateway",
            "cloudflare-workers-ai": "Cloudflare Workers AI", "baseten": "Baseten", "opencode": "OpenCode",
            "opencode-go": "OpenCode", "qwen-token-plan": "Qwen", "qwen-token-plan-cn": "Qwen",
            "qwen-token-plan-individual": "Qwen", "xiaomi": "Xiaomi", "ant-ling": "Ant Ling",
        ]
        return names[id.lowercased()] ?? id
    }

    /// "45s", "1m 40s", "2m", "31m", "1h 5m".
    static func spanText(_ seconds: Double) -> String {
        let whole = max(1, Int(reportedCount: seconds.rounded()) ?? 0)
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 {
            let rest = whole % 60
            return rest == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(rest)s"
        }
        let minutes = (whole % 3600) / 60
        return minutes == 0 ? "\(whole / 3600)h" : "\(whole / 3600)h \(minutes)m"
    }

    static func secondsClock(_ milliseconds: Double, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    // MARK: Cleaning

    /// The message as spans: keys cut to their ends, links, and names the provider quoted in
    /// backticks, with escaped quotes undone.
    static func spans(_ text: String) -> [Span] {
        var spans: [Span] = []
        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            if case .text(let previous)? = spans.last { spans[spans.count - 1] = .text(previous + value) } else { spans.append(.text(value)) }
        }
        let cleaned = text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
        for piece in NativeRedaction.pieces(cleaned) {
            switch piece {
            case .text(let value):
                // Backticked names read as code.
                let parts = value.components(separatedBy: "`")
                if parts.count >= 3 {
                    for (index, part) in parts.enumerated() {
                        if index % 2 == 1, index < parts.count - 1, !part.isEmpty, !part.contains("\n") { spans.append(.code(part)) }
                        else { appendText(index % 2 == 1 && index == parts.count - 1 ? "`" + part : part) }
                    }
                } else {
                    appendText(value)
                }
            case .key(let value): spans.append(.code(value))
            case .url(let url): spans.append(.link(display: NativeRedaction.display(url), url: url))
            }
        }
        return spans
    }
}

extension NativeTurnError.BodyToken {
    var text: String {
        switch self {
        case .plain(let text), .key(let text), .string(let text), .redacted(let text), .link(let text): text
        }
    }
}

/// pi retrying a failed request on its own (TurnErrors › While it retries): "OpenAI is
/// overloaded · retrying in 8s", "2 of 3".
public struct NativeRetryLine: Equatable, Hashable, Sendable {
    /// "OpenAI is overloaded".
    public var title: String
    public var glyph: String
    public var attempt: Int
    public var maxAttempts: Int
    /// When the next try goes (ms, the host's clock).
    public var retryAt: Double

    public init(title: String, glyph: String, attempt: Int, maxAttempts: Int, retryAt: Double) {
        self.title = title
        self.glyph = glyph
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.retryAt = retryAt
    }

    /// The line's words at `now` (ms): "retrying in 8s" until the try goes, then "retrying".
    public func text(now: Double) -> String {
        let seconds = Int(((retryAt - now) / 1000).rounded(.up))
        return title + (seconds > 0 ? " · retrying in \(seconds)s" : " · retrying")
    }

    /// "2 of 3", or nil when pi didn't say how many.
    public var count: String? {
        maxAttempts > 0 ? "\(attempt) of \(maxAttempts)" : nil
    }
}

// MARK: - Reading a provider's error

/// What pi's `errorMessage` says: the HTTP status, the provider's JSON body and the fields in
/// it, and the provider's own message. pi writes it as "<status>: <body>", "<status> <message>",
/// "<Provider> API error (<status>): <message>", or the SDK's message alone ("Connection error.").
struct NativeProviderError {
    var status: Int?
    var type: String?
    var code: String?
    var requestID: String?
    var message: String
    var errno: String?
    var apiHost: String?
    var kind: NativeTurnError.Kind
    var body: [NativeTurnError.BodyToken]

    /// The chip beside the status: the type, unless it is a generic one and a code says more.
    var label: String? {
        let generic: Set<String> = ["invalid_request_error", "error", "tokens", "requests", "invalid_request"]
        if let type, !generic.contains(type.lowercased()) { return type }
        return code ?? type
    }

    /// "connection reset", from the network error.
    var networkReason: String {
        switch errno?.uppercased() {
        case "ECONNRESET": return "connection reset"
        case "ECONNREFUSED": return "connection refused"
        case "ENOTFOUND", "EAI_AGAIN": return "its address didn’t resolve"
        case "ETIMEDOUT": return "timed out"
        case "EPIPE": return "connection closed"
        case "EHOSTUNREACH", "ENETUNREACH": return "no route to it"
        default:
            let lower = message.lowercased()
            if lower.contains("socket hang up") || lower.contains("other side closed") { return "connection closed" }
            if lower.contains("getaddrinfo") { return "its address didn’t resolve" }
            var words = message.trimmingCharacters(in: .whitespacesAndNewlines)
            while words.hasSuffix(".") { words.removeLast() }
            return words.isEmpty ? "no answer" : words.prefix(1).lowercased() + words.dropFirst()
        }
    }

    init(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = text
        if let match = Self.firstMatch(Self.prefixed, in: text) {
            status = Int(match[2])
            rest = match[3]
        } else if let match = Self.firstMatch(Self.leadingStatus, in: text) {
            status = Int(match[1])
            rest = match[2]
        } else if let match = Self.firstMatch(Self.namedStatus, in: text) {
            status = Int(match[1])
        }

        var message = rest
        var bodyTokens: [NativeTurnError.BodyToken] = []
        if let json = Self.json(in: rest) {
            bodyTokens = NativeJSONPrinter.tokens(json.text)
            let root = json.value
            var error = root["error"] as? [String: Any] ?? root
            if let nested = root["error"] as? String { message = nested }
            if let text = error["message"] as? String ?? root["message"] as? String ?? root["detail"] as? String { message = text }
            // OpenRouter wraps the upstream provider's answer in metadata.raw.
            if let metadata = error["metadata"] as? [String: Any], let raw = metadata["raw"] as? String,
               let inner = Self.json(in: raw)?.value {
                let innerError = inner["error"] as? [String: Any] ?? inner
                if let text = innerError["message"] as? String { message = text; error = innerError.merging(error) { first, _ in first } }
            }
            if let type = error["type"] as? String, type != "error" { self.type = type }
            else if let type = root["type"] as? String, type != "error" { self.type = type }
            if let status = error["status"] as? String, type == nil { self.type = status }
            if let code = error["code"] as? String { self.code = code }
            else if let code = error["code"] as? Int {
                if (100...599).contains(code) { if status == nil { status = code } } else { self.code = String(code) }
            }
            if let status = error["status"] as? Int, self.status == nil { self.status = status }
            requestID = root["request_id"] as? String ?? error["request_id"] as? String ?? root["requestId"] as? String
        } else if !rest.isEmpty {
            bodyTokens = [.plain(NativeRedaction.redact(text))]
        } else {
            bodyTokens = [.plain(NativeRedaction.redact(text))]
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { message = text }
        self.message = message
        body = bodyTokens

        let haystack = [message, type ?? "", code ?? "", text].joined(separator: " ").lowercased()
        errno = Self.firstMatch(Self.errnoPattern, in: text).map { $0[1].uppercased() }
        apiHost = Self.firstMatch(Self.hostPattern, in: text).map { $0[1] }

        let labels = [type ?? "", code ?? ""].map { $0.lowercased() }
        func has(_ pattern: NSRegularExpression) -> Bool { Self.firstMatch(pattern, in: haystack) != nil }
        if labels.contains(where: { $0.contains("context_length") }) || has(Self.contextPattern) {
            kind = .contextTooLong
        } else if status == 401 || labels.contains(where: { ["authentication_error", "invalid_api_key", "unauthorized", "authentication"].contains($0) })
                    || has(Self.authPattern) {
            kind = .auth
        } else if status == 429 || labels.contains(where: { $0.contains("rate_limit") || $0 == "resource_exhausted" }) || has(Self.ratePattern) {
            kind = .rateLimit
        } else if status == 529 || labels.contains("overloaded_error") || has(Self.overloadedPattern) {
            kind = .overloaded
        } else if status == 408 || status == 504 || (status == nil && has(Self.timeoutPattern)) {
            kind = .timeout
        } else if status == nil, errno != nil || has(Self.networkPattern) {
            kind = .network
        } else if status == 500 || labels.contains(where: { ["server_error", "api_error", "internal_server_error", "internal_error"].contains($0) })
                    || has(Self.serverPattern) {
            kind = .server
        } else {
            kind = .other
        }
    }

    // MARK: Patterns

    /// "OpenAI API error (401): …"
    static let prefixed = try! NSRegularExpression(pattern: #"^(.{1,80}?) \((\d{3})\):\s*(.*)$"#, options: [.dotMatchesLineSeparators])
    /// "401: {…}", "401 Incorrect API key…", "529 overloaded".
    static let leadingStatus = try! NSRegularExpression(pattern: #"^(\d{3})(?::\s*|\s+|$)(.*)$"#, options: [.dotMatchesLineSeparators])
    /// "status code 429", "HTTP 503".
    static let namedStatus = try! NSRegularExpression(pattern: #"\b(?:status(?: code)?|http)[ :=]*(\d{3})\b"#, options: [.caseInsensitive])
    static let errnoPattern = try! NSRegularExpression(
        pattern: #"\b(ECONNRESET|ECONNREFUSED|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EPIPE|EHOSTUNREACH|ENETUNREACH|ECONNABORTED)\b"#,
        options: [.caseInsensitive])
    /// A host named by a failed lookup or connection ("getaddrinfo ENOTFOUND api.openai.com",
    /// "connect ECONNREFUSED api.deepseek.com:443"), or in an address.
    static let hostPattern = try! NSRegularExpression(
        pattern: #"(?:https?://|\b(?:ENOTFOUND|EAI_AGAIN|ECONNREFUSED|ECONNRESET|ETIMEDOUT)\s+)((?:[a-z0-9-]+\.)+[a-z]{2,})"#,
        options: [.caseInsensitive])
    static let contextPattern = try! NSRegularExpression(
        pattern: #"maximum context length|context length|context window|prompt is too long|input is too long|too many tokens|exceeds the (?:model'?s )?(?:maximum )?context"#)
    static let authPattern = try! NSRegularExpression(
        pattern: #"incorrect api key|invalid api key|invalid x-api-key|api key not valid|invalid authentication|missing api key|no api key"#)
    static let ratePattern = try! NSRegularExpression(pattern: #"rate.?limit|too many requests|resource_exhausted"#)
    static let overloadedPattern = try! NSRegularExpression(pattern: #"overloaded|high demand"#)
    static let timeoutPattern = try! NSRegularExpression(pattern: #"timed? ?out|timeout|deadline exceeded"#)
    static let networkPattern = try! NSRegularExpression(
        pattern: #"fetch failed|connection error|network error|socket hang up|other side closed|getaddrinfo|upstream connect|connection (?:refused|reset|lost|closed)|could not connect|unable to connect"#)
    static let serverPattern = try! NSRegularExpression(pattern: #"internal server error|server error|internal error"#)

    /// The capture groups of the first match (group 0 is the whole match).
    static func firstMatch(_ pattern: NSRegularExpression, in text: String) -> [String]? {
        let ns = text as NSString
        guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    /// The JSON object in `text`, from its first `{` to its last `}`, and that text; a JSON
    /// string holding one is read through.
    static func json(in text: String) -> (value: [String: Any], text: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), let inner = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed) as? String {
            return json(in: inner)
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
        let candidate = String(trimmed[start...end])
        guard let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] else { return nil }
        return (value, candidate)
    }
}

// MARK: - Redaction and links

/// Keys cut to their first eight and last four characters ("sk-svcac…fvMA"), a provider's own
/// mask ("sk-proj-****fvMA") the same way, and addresses found.
enum NativeRedaction {
    enum Piece: Equatable {
        case text(String)
        case key(String)
        case url(String)
    }

    /// A provider's mask: some of the key, a run of stars, its end.
    static let masked = try! NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9_\-]{1,}\*{3,}[A-Za-z0-9_\-]{2,}"#)
    /// A key in the clear.
    static let key = try! NSRegularExpression(
        pattern: #"\b(?:sk-ant-[A-Za-z0-9_\-]{12,}|(?:sk|pk|rk|gsk|xai|key|sess)[-_][A-Za-z0-9_\-]{16,}|AIza[0-9A-Za-z_\-]{30,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#)
    static let url = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`\)\]\}]+"#)
    static let bearer = try! NSRegularExpression(pattern: #"(?<=Bearer )[A-Za-z0-9._\-]{16,}"#)

    /// `text` split into plain text, keys (already cut) and addresses.
    static func pieces(_ text: String) -> [Piece] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var found: [(NSRange, Piece)] = []
        for match in url.matches(in: text, range: whole) {
            var range = match.range
            // Sentence punctuation after an address is not part of it.
            while range.length > 0, ".,;:!?".contains(ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                range.length -= 1
            }
            found.append((range, .url(ns.substring(with: range))))
        }
        for pattern in [masked, key, bearer] {
            for match in pattern.matches(in: text, range: whole)
            where !found.contains(where: { NSIntersectionRange($0.0, match.range).length > 0 }) {
                found.append((match.range, .key(cut(ns.substring(with: match.range)))))
            }
        }
        found.sort { $0.0.location < $1.0.location }
        var pieces: [Piece] = []
        var cursor = 0
        for (range, piece) in found {
            if range.location > cursor { pieces.append(.text(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))) }
            pieces.append(piece)
            cursor = range.location + range.length
        }
        if cursor < ns.length { pieces.append(.text(ns.substring(from: cursor))) }
        return pieces
    }

    /// "sk-svcac…fvMA": a mask's stars, or a key's middle, become one ellipsis.
    static func cut(_ key: String) -> String {
        if let stars = key.range(of: #"\*{3,}"#, options: .regularExpression) {
            let head = key[..<stars.lowerBound]
            return String(head.prefix(8)) + "…" + String(key[stars.upperBound...].suffix(4))
        }
        guard key.count > 12 else { return key }
        return String(key.prefix(8)) + "…" + String(key.suffix(4))
    }

    /// `text` with every key cut.
    static func redact(_ text: String) -> String {
        pieces(text).map { piece in
            switch piece {
            case .text(let value), .key(let value), .url(let value): value
            }
        }.joined()
    }

    /// An address without its scheme or a trailing slash: "platform.openai.com/account/api-keys".
    static func display(_ url: String) -> String {
        var text = url
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

// MARK: - Pretty-printing a body

/// Re-indents a JSON text two spaces a level, keeping its keys in the provider's order (a
/// dictionary would sort them), and splits it into tokens: keys, strings (keys cut and
/// addresses marked inside them), and the rest.
enum NativeJSONPrinter {
    static let limit = 8000

    static func tokens(_ json: String) -> [NativeTurnError.BodyToken] {
        var out: [NativeTurnError.BodyToken] = []
        func plain(_ text: String) {
            if case .plain(let previous)? = out.last { out[out.count - 1] = .plain(previous + text) } else { out.append(.plain(text)) }
        }
        let characters = Array(json.prefix(limit))
        var index = 0
        var depth = 0
        var afterOpen = false
        func newline() { plain("\n" + String(repeating: "  ", count: depth)) }
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\"":
                var end = index + 1
                while end < characters.count, characters[end] != "\"" {
                    end += characters[end] == "\\" ? 2 : 1
                }
                let literal = String(characters[index...min(end, characters.count - 1)])
                index = end + 1
                if afterOpen { newline(); afterOpen = false }
                var lookahead = index
                while lookahead < characters.count, characters[lookahead].isWhitespace { lookahead += 1 }
                if lookahead < characters.count, characters[lookahead] == ":" {
                    out.append(.key(literal))
                } else {
                    let unescaped = literal.replacingOccurrences(of: "\\/", with: "/")
                    for piece in NativeRedaction.pieces(unescaped) {
                        switch piece {
                        case .text(let text): out.append(.string(text))
                        case .key(let key): out.append(.redacted(key))
                        case .url(let url): out.append(.link(url))
                        }
                    }
                }
                continue
            case "{", "[":
                if afterOpen { newline() }
                plain(String(character))
                depth += 1
                afterOpen = true
            case "}", "]":
                depth = max(0, depth - 1)
                if afterOpen { afterOpen = false } else { newline() }
                plain(String(character))
            case ",":
                plain(",")
                newline()
            case ":":
                plain(": ")
            default:
                if character.isWhitespace { break }
                if afterOpen { newline(); afterOpen = false }
                plain(String(character))
            }
            index += 1
        }
        if json.count > limit { plain("\n…") }
        return out
    }
}
