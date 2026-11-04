import Foundation

// Hooks' values (docs/hooks.md): what the host's catalog finds, the off switches, a draft and a
// test's result. ShepherdSessions reads and writes the files; the Mac and the remote clients
// (`hooks.v1`) draw these.

/// Which tool's file format a hooks file is in.
public enum HookFormat: String, CaseIterable, Codable, Sendable {
    case shepherd, claude, codex
    /// "Shepherd", "Claude Code", "Codex".
    public var name: String {
        switch self {
        case .shepherd: "Shepherd"
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Where a hook applies: every thread on this Mac, or threads in one space (its root path).
public enum HookScope: Hashable, Codable, Sendable {
    case mac
    case space(root: String)
    public var root: String? { if case .space(let root) = self { return root }; return nil }
}

/// What reading one hooks file came to (Settings › Hooks › Sources).
public enum HookFileState: Hashable, Codable, Sendable {
    /// Read; `count` handlers.
    case loaded(count: Int)
    case notFound
    /// Not read: its reader (Claude Code or Codex) is off.
    case readerOff
    /// Couldn't read: a 1-based line when the text didn't parse, and why.
    case unreadable(line: Int?, message: String)

    /// The Sources row's status ("2 hooks", "Couldn't read: line 4, …").
    public var label: String {
        switch self {
        case .loaded(let count): count == 1 ? "1 hook" : "\(count) hooks"
        case .notFound: "Not found"
        case .readerOff: "Not read"
        case .unreadable(let line?, let message): "Couldn't read: line \(line), \(message)"
        case .unreadable(nil, let message): "Couldn't read: \(message)"
        }
    }
}

/// One hooks file the catalog looked for.
public struct HookSource: Hashable, Codable, Sendable, Identifiable {
    /// Absolute path; also the file part of each of its hooks' slots and hashes.
    public var path: String
    public var scope: HookScope
    public var format: HookFormat
    /// Codex's `config.toml`: read, never written.
    public var isTOML: Bool
    public var state: HookFileState
    public var id: String { path }

    public init(path: String, scope: HookScope, format: HookFormat, isTOML: Bool, state: HookFileState) {
        self.path = path; self.scope = scope; self.format = format; self.isTOML = isTOML; self.state = state
    }
}

/// One handler object, as the file holds it, with typed views of the keys Shepherd knows.
public struct HookHandler: Hashable, Codable, Sendable {
    /// The whole object, unknown keys included, in file order.
    public var raw: HookJSON
    public init(raw: HookJSON) { self.raw = raw }

    /// A `command` handler with only the keys given.
    public static func command(_ command: String, timeout: Double? = nil, statusMessage: String? = nil, async: Bool? = nil) -> HookHandler {
        var raw = HookJSON.object(["type": .string("command"), "command": .string(command)])
        if let timeout { raw["timeout"] = .number(timeout) }
        if let statusMessage, !statusMessage.isEmpty { raw["statusMessage"] = .string(statusMessage) }
        if let async { raw["async"] = .bool(async) }
        return HookHandler(raw: raw)
    }

    /// `command`, `mcp_tool`, `prompt`, `agent`, or whatever the file says.
    public var type: String { raw["type"]?.stringValue ?? "" }
    public var command: String? { raw["command"]?.stringValue }
    /// Seconds.
    public var timeout: Double? { raw["timeout"]?.numberValue }
    public var statusMessage: String? { raw["statusMessage"]?.stringValue }
    public var isAsync: Bool { raw["async"]?.boolValue ?? false }
    /// `mcp_tool`: the server, the tool, and its input (with `${field.path}` placeholders).
    public var server: String? { raw["server"]?.stringValue }
    public var tool: String? { raw["tool"]?.stringValue }
    public var input: HookJSON? { raw["input"] }
    /// Only `command` and `mcp_tool` handlers run; `prompt` and `agent` are listed, never run.
    public var canRun: Bool { type == "command" || type == "mcp_tool" }
}

/// One hook: one handler in one file.
public struct HookEntry: Hashable, Codable, Sendable, Identifiable {
    /// The slot: `<file>#<Event>/<group>/<handler>`.
    public var id: String { slot }
    public var slot: String
    public var scope: HookScope
    public var file: String
    public var format: HookFormat
    /// The event name as the file spells it; `hookEvent` is nil for one Shepherd doesn't know.
    public var event: String
    public var matcher: String
    public var groupIndex: Int
    public var handlerIndex: Int
    public var handler: HookHandler
    public var hash: String
    /// The handler's canonical JSON.
    public var canonical: String
    /// False for Codex's `config.toml`, which Shepherd reads but never writes.
    public var editable: Bool
    /// Not switched off (docs/hooks.md › Identity and the off switch).
    public var on: Bool

    public init(slot: String, scope: HookScope, file: String, format: HookFormat, event: String, matcher: String,
                groupIndex: Int, handlerIndex: Int, handler: HookHandler, hash: String, canonical: String, editable: Bool, on: Bool) {
        self.slot = slot; self.scope = scope; self.file = file; self.format = format; self.event = event; self.matcher = matcher
        self.groupIndex = groupIndex; self.handlerIndex = handlerIndex; self.handler = handler; self.hash = hash
        self.canonical = canonical; self.editable = editable; self.on = on
    }

    public var hookEvent: HookEvent? { HookEvent(rawValue: event) }
    /// Whether it runs: on, and a type that runs.
    public var runs: Bool { on && handler.canRun }
    /// The name a thread row shows: `statusMessage`, else the command's first word, else the tool.
    public var name: String {
        if let message = handler.statusMessage, !message.isEmpty { return message }
        if let word = handler.command?.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first { return String(word) }
        return handler.tool ?? handler.type
    }
}

/// The hooks that apply to one thread, for the composer glyph.
public struct HookSummary: Equatable, Sendable {
    /// Hooks that would run (on, a type that runs).
    public var running: Int
    public init(running: Int) { self.running = running }
    /// Whether the composer shows the hook glyph.
    public var showsGlyph: Bool { running > 0 }
}

/// Everything the catalog found at one moment.
public struct HookCatalogSnapshot: Hashable, Codable, Sendable {
    /// Every file looked for: This Mac's first, then each space's, in docs/hooks.md's table order.
    public var sources: [HookSource]
    /// Every hook in every loaded file, in source and file order.
    public var entries: [HookEntry]
    public var settings: HookSettings
    /// The host's home folder, where This Mac's files live: for `~` in labels and This Mac's save target.
    public var home: String

    public init(sources: [HookSource], entries: [HookEntry], settings: HookSettings, home: String = "") {
        self.sources = sources; self.entries = entries; self.settings = settings; self.home = home
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([HookSource].self, forKey: .sources) ?? []
        entries = try c.decodeIfPresent([HookEntry].self, forKey: .entries) ?? []
        settings = try c.decodeIfPresent(HookSettings.self, forKey: .settings) ?? HookSettings()
        home = try c.decodeIfPresent(String.self, forKey: .home) ?? ""
    }

    /// This Mac's hooks plus those of `spaceRoot` (none for nil), as a thread there sees them.
    public func entries(forSpaceRoot spaceRoot: String?) -> [HookEntry] {
        entries.filter { $0.scope == .mac || ($0.scope.root != nil && $0.scope.root == spaceRoot) }
    }

    /// The hooks that would run in a thread whose space is `spaceRoot`.
    public func running(forSpaceRoot spaceRoot: String?) -> [HookEntry] {
        entries(forSpaceRoot: spaceRoot).filter(\.runs)
    }

    /// Counts for the composer glyph, without reading anything.
    public func summary(forSpaceRoot spaceRoot: String?) -> HookSummary {
        HookSummary(running: running(forSpaceRoot: spaceRoot).count)
    }
}

/// `<support>/hooks/settings.json` (docs/hooks.md › Identity and the off switch): which hooks the
/// person switched off, by hash, and whether the Claude Code and Codex readers are on. Every
/// configured hook not in `off` runs.
public struct HookSettings: Hashable, Sendable, Codable {
    /// The Sources switches: whether Claude Code's and Codex's files are read. Both default on.
    public struct Readers: Hashable, Sendable, Codable {
        public var claude = true
        public var codex = true
        public init(claude: Bool = true, codex: Bool = true) { self.claude = claude; self.codex = codex }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            claude = (try? c.decode(Bool.self, forKey: .claude)) ?? true
            codex = (try? c.decode(Bool.self, forKey: .codex)) ?? true
        }
        /// Whether files of `format` are read.
        public func reads(_ format: HookFormat) -> Bool {
            switch format {
            case .shepherd: true
            case .claude: claude
            case .codex: codex
            }
        }
    }

    public var version = 1
    /// Hashes switched off.
    public var off: [String] = []
    public var readers = Readers()

    public init(off: [String] = [], readers: Readers = Readers()) {
        self.off = off; self.readers = readers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        off = (try? c.decode([String].self, forKey: .off)) ?? []
        readers = (try? c.decode(Readers.self, forKey: .readers)) ?? Readers()
    }

    /// Whether the hook with this hash is on.
    public func isOn(_ hash: String) -> Bool { !off.contains(hash) }
}

/// What a hook's run means for the agent (docs/hooks.md › What a hook gets and gives back).
public enum HookOutcome: Hashable, Codable, Sendable {
    /// Exit 0 with nothing that changes the step.
    case allowed
    /// Exit 2, `decision: "block"`, a `deny`, or `continue: false`; the reason the agent would read.
    case blocked(reason: String)
    /// `permissionDecision: "ask"`: the person would be asked.
    case ask(reason: String)
    /// Context the agent would read.
    case context(String)
    /// Another exit, a spawn error, or output Shepherd can't take: the agent goes ahead.
    case failed(String)
    case timedOut

    /// One line for the test result ("Would block: …").
    public var summary: String {
        switch self {
        case .allowed: "Allowed"
        case .blocked(let reason): reason.isEmpty ? "Would block" : "Would block: \(reason)"
        case .ask(let reason): reason.isEmpty ? "Would ask you" : "Would ask you: \(reason)"
        case .context(let text): "Adds context: \(text)"
        case .failed(let why): "Failed: \(why)"
        case .timedOut: "Timed out"
        }
    }

    /// Reads one finished run the way the runtime does.
    public static func interpret(event: String, exit: Int32, stdout: String, stderr: String) -> HookOutcome {
        let errors = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if exit == 2 { return .blocked(reason: errors) }
        if exit != 0 { return .failed("exit \(exit)" + (errors.isEmpty ? "" : ": " + (errors.split(separator: "\n").first.map(String.init) ?? ""))) }
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? HookJSON.parse(text), json.objectValue != nil {
            let specific = json["hookSpecificOutput"]
            if json["decision"]?.stringValue == "block" { return .blocked(reason: json["reason"]?.stringValue ?? "") }
            let reason = specific?["permissionDecisionReason"]?.stringValue ?? ""
            switch specific?["permissionDecision"]?.stringValue {
            case "deny": return .blocked(reason: reason)
            case "ask": return .ask(reason: reason)
            default: break
            }
            if json["continue"]?.boolValue == false { return .blocked(reason: json["stopReason"]?.stringValue ?? "") }
            if let context = specific?["additionalContext"]?.stringValue ?? json["additionalContext"]?.stringValue, !context.isEmpty {
                return .context(context)
            }
            return .allowed
        }
        if !text.isEmpty, event == HookEvent.sessionStart.rawValue || event == HookEvent.userPromptSubmit.rawValue { return .context(text) }
        return .allowed
    }
}

/// One test run of a command handler.
public struct HookTestResult: Hashable, Codable, Sendable {
    /// Nil when it never finished (timeout, spawn error).
    public var exit: Int32?
    /// Each capped at 64 KiB.
    public var stdout: String
    public var stderr: String
    public var milliseconds: Int
    public var outcome: HookOutcome
    /// The stream was longer than the cap and is cut there.
    public var stdoutCut: Bool
    public var stderrCut: Bool

    public init(exit: Int32?, stdout: String, stderr: String, milliseconds: Int, outcome: HookOutcome,
                stdoutCut: Bool = false, stderrCut: Bool = false) {
        self.exit = exit; self.stdout = stdout; self.stderr = stderr; self.milliseconds = milliseconds; self.outcome = outcome
        self.stdoutCut = stdoutCut; self.stderrCut = stderrCut
    }

    private enum CodingKeys: String, CodingKey { case exit, stdout, stderr, milliseconds, outcome, stdoutCut, stderrCut }

    /// The output and its cut marks decode as empty and uncut when a reply leaves them out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exit = try c.decodeIfPresent(Int32.self, forKey: .exit)
        stdout = try c.decodeIfPresent(String.self, forKey: .stdout) ?? ""
        stderr = try c.decodeIfPresent(String.self, forKey: .stderr) ?? ""
        milliseconds = try c.decode(Int.self, forKey: .milliseconds)
        outcome = try c.decode(HookOutcome.self, forKey: .outcome)
        stdoutCut = try c.decodeIfPresent(Bool.self, forKey: .stdoutCut) ?? false
        stderrCut = try c.decodeIfPresent(Bool.self, forKey: .stderrCut) ?? false
    }
}

/// A hook as Settings' editor holds it before it is written.
public struct HookDraft: Hashable, Codable, Sendable {
    public var event: String
    /// Empty for none.
    public var matcher: String
    public var handler: HookHandler
    public init(event: String, matcher: String = "", handler: HookHandler) {
        self.event = event; self.matcher = matcher; self.handler = handler
    }
}


// MARK: Remote (`hooks.v1`)

/// A hook as a client read it: its slot, and its hash then, which a change must still find in the
/// file (else `hook_changed`).
public struct HookRef: Hashable, Codable, Sendable {
    public var slot: String
    public var hash: String
    public init(slot: String, hash: String) { self.slot = slot; self.hash = hash }
    public init(_ entry: HookEntry) { self.init(slot: entry.slot, hash: entry.hash) }
}

/// Settings › Hooks on a host (`RemoteRequest.hooks`), answered with the host's catalog as it is
/// afterwards, or a test's result.
public enum RemoteHooksRequest: Codable, Hashable, Sendable {
    case fetch
    /// The off switch of the hook with this hash.
    case setOn(hash: String, on: Bool)
    /// The Claude Code or Codex reader (Sources).
    case setReader(format: HookFormat, on: Bool)
    /// The editor's Save: writes `drafts` into `file` (one of the catalog's JSON files). With
    /// `replacing`, the hook it edits: when `file` is its file, the draft at `kept` takes its place;
    /// else every draft is added and it is removed.
    case save(drafts: [HookDraft], file: String, replacing: HookRef?, kept: Int?)
    case delete(HookRef)
    /// Runs `command` once on the host against a sample `event`, in `root` (one of the catalog's
    /// spaces; nil: the home folder), for at most `timeout` or the event's limit.
    case test(command: String, event: HookEvent, matcher: String, timeout: Double?, root: String?)
}

extension RemoteHooksRequest {
    /// Whether it can change the host's hooks (a read or a test can't).
    public var changesHooks: Bool {
        switch self {
        case .fetch, .test: false
        default: true
        }
    }
}

public enum RemoteHooksResult: Codable, Hashable, Sendable {
    case hooks(HookCatalogSnapshot)
    case tested(HookTestResult)
}
