import Foundation

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
public enum HookScope: Hashable, Sendable {
    case mac
    case space(root: String)
    public var root: String? { if case .space(let root) = self { return root }; return nil }
}

/// What reading one hooks file came to (Settings › Hooks › Sources).
public enum HookFileState: Equatable, Sendable {
    /// Read; `count` handlers.
    case loaded(count: Int)
    case notFound
    /// Not read: its reader (Claude Code or Codex) is off.
    case readerOff
    /// Not read: pi's `trust.json` doesn't trust the space.
    case spaceNotTrusted
    /// Couldn't read: a 1-based line when the text didn't parse, and why.
    case unreadable(line: Int?, message: String)

    /// The Sources row's status ("2 hooks", "Couldn't read: line 4, …").
    public var label: String {
        switch self {
        case .loaded(let count): count == 1 ? "1 hook" : "\(count) hooks"
        case .notFound: "Not found"
        case .readerOff: "Not read"
        case .spaceNotTrusted: "Skipped: space not trusted"
        case .unreadable(let line?, let message): "Couldn't read: line \(line), \(message)"
        case .unreadable(nil, let message): "Couldn't read: \(message)"
        }
    }
}

/// One hooks file the catalog looked for.
public struct HookSource: Equatable, Sendable, Identifiable {
    /// Absolute path; also the file part of each of its hooks' slots and hashes.
    public var path: String
    public var scope: HookScope
    public var format: HookFormat
    /// Codex's `config.toml`: read, never written.
    public var isTOML: Bool
    public var state: HookFileState
    public var id: String { path }
}

/// One handler object, as the file holds it, with typed views of the keys Shepherd knows.
public struct HookHandler: Equatable, Hashable, Sendable {
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

/// Where a hook stands with the person (docs/hooks.md › Identity and trust).
public enum HookReview: Equatable, Sendable {
    /// Trusted and on: it runs.
    case on
    /// Trusted, switched off.
    case off
    /// No trusted entry has its slot.
    case new
    /// A trusted entry has its slot with another hash; `previous` is it, for the diff.
    case changed(previous: HookTrust.Record)

    public var needsReview: Bool {
        switch self {
        case .new, .changed: true
        case .on, .off: false
        }
    }
}

/// One hook: one handler in one file.
public struct HookEntry: Equatable, Sendable, Identifiable {
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
    public var review: HookReview

    public var hookEvent: HookEvent? { HookEvent(rawValue: event) }
    /// Whether it runs: trusted, on, and a type that runs.
    public var runs: Bool { review == .on && handler.canRun }
    /// The name a thread row shows: `statusMessage`, else the command's first word, else the tool.
    public var name: String {
        if let message = handler.statusMessage, !message.isEmpty { return message }
        if let word = handler.command?.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first { return String(word) }
        return handler.tool ?? handler.type
    }
}

/// The hooks that apply to one thread, for the composer glyph.
public struct HookSummary: Equatable, Sendable {
    /// Hooks that would run (trusted, on, a type that runs).
    public var running: Int
    /// Hooks that are new or changed.
    public var needingReview: Int
    /// Whether the composer shows the hook glyph; the dot is `needingReview > 0`.
    public var showsGlyph: Bool { running > 0 || needingReview > 0 }
}

/// Everything the catalog found at one moment.
public struct HookCatalogSnapshot: Equatable, Sendable {
    /// Every file looked for: This Mac's first, then each space's, in docs/hooks.md's table order.
    public var sources: [HookSource]
    /// Every hook in every loaded file, in source and file order.
    public var entries: [HookEntry]
    public var trust: HookTrust

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
        let entries = entries(forSpaceRoot: spaceRoot)
        return HookSummary(running: entries.filter(\.runs).count, needingReview: entries.filter(\.review.needsReview).count)
    }
}

/// Finds and reads the hooks files on this host (docs/hooks.md › Files). A value: every call reads
/// the files afresh, so call it off the main thread and off the server queue.
public struct HookCatalog: Sendable {
    /// The user's home folder (`HOME`), where This Mac's files live. Never a space.
    public var home: String
    /// pi's `trust.json`, which decides whether a space's files are read.
    public var piTrust: URL
    /// Shepherd's own `trust.json` for hooks.
    public var trustStore: HookTrustStore

    /// Files larger than this are reported, not read.
    public static let fileLimit = 1 << 20

    /// `support` is Shepherd's Application Support folder; pi's trust file defaults to the one in
    /// Shepherd's pi home, `<support>/pi/trust.json`.
    public init(home: String = PiHome.environmentHome, support: URL, piTrust: URL? = nil) {
        // Kept as given (never standardized, which drops /private): file paths in hashes start with it.
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.home = home
        self.piTrust = piTrust ?? support.appendingPathComponent("pi", isDirectory: true).appendingPathComponent("trust.json")
        trustStore = HookTrustStore(support: support)
    }

    /// The space a thread in `cwd` belongs to: the git top level (the nearest folder with a
    /// `.git` entry, below `home`), else `cwd`, canonical. Nil when that is `home` or above it.
    public static func spaceRoot(forCwd cwd: String, home: String) -> String? {
        let canonicalHome = PiHome.canonical(home)
        let start = PiHome.canonical(cwd)
        guard !PiHome.isInside(canonicalHome, start) else { return nil }
        var folder = start
        while folder != "/" && folder != canonicalHome {
            if FileManager.default.fileExists(atPath: folder + "/.git") { return folder }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return start
    }

    public func spaceRoot(forCwd cwd: String) -> String? { Self.spaceRoot(forCwd: cwd, home: home) }

    /// The files of `scope`, in the contract's order: path relative to the scope's folder, format.
    static let layout: [(String, HookFormat)] = [
        (".shepherd/hooks.json", .shepherd),
        (".claude/settings.json", .claude), (".claude/settings.local.json", .claude),
        (".codex/hooks.json", .codex), (".codex/config.toml", .codex),
    ]

    /// Reads This Mac's files and those of each space in `spaceRoots` (canonical roots, as
    /// `spaceRoot(forCwd:)` gives them; the home folder and repeats are dropped).
    public func load(spaceRoots: [String] = []) -> HookCatalogSnapshot {
        let trust = trustStore.read()
        let piDecisions = readPiTrust()
        let canonicalHome = PiHome.canonical(home)
        var sources: [HookSource] = [], entries: [HookEntry] = []
        var scopes: [(HookScope, String, Bool)] = [(.mac, home, true)]
        var seen = Set<String>()
        for root in spaceRoots {
            let root = PiHome.canonical(root)
            guard !PiHome.isInside(canonicalHome, root), seen.insert(root).inserted else { continue }
            scopes.append((.space(root: root), root, Self.trusts(piDecisions, root)))
        }
        for (scope, folder, spaceTrusted) in scopes {
            for (relative, format) in Self.layout {
                // The home's Claude Code local settings aren't in the contract's table.
                if scope == .mac && relative == ".claude/settings.local.json" { continue }
                let path = folder + "/" + relative
                let isTOML = relative.hasSuffix(".toml")
                var source = HookSource(path: path, scope: scope, format: format, isTOML: isTOML, state: .notFound)
                if !FileManager.default.fileExists(atPath: path) {
                    source.state = .notFound
                } else if !trust.readers.reads(format) {
                    source.state = .readerOff
                } else if !spaceTrusted {
                    source.state = .spaceNotTrusted
                } else {
                    do {
                        let found = try Self.entries(in: path, scope: scope, format: format, isTOML: isTOML, trust: trust)
                        source.state = .loaded(count: found.count)
                        entries += found
                    } catch let error as HookJSON.ParseError {
                        source.state = .unreadable(line: error.line, message: error.message)
                    } catch {
                        source.state = .unreadable(line: nil, message: String(describing: error))
                    }
                }
                sources.append(source)
            }
        }
        return HookCatalogSnapshot(sources: sources, entries: entries, trust: trust)
    }

    /// The composer glyph's counts for a thread in `cwd`: reads This Mac's files and that space's.
    public func summary(forCwd cwd: String) -> HookSummary {
        let root = spaceRoot(forCwd: cwd)
        return load(spaceRoots: root.map { [$0] } ?? []).summary(forSpaceRoot: root)
    }

    // MARK: Reading

    struct ReadFailure: Error, CustomStringConvertible { let description: String }

    /// The hooks in one file. Throws `HookJSON.ParseError` or `ReadFailure`.
    static func entries(in path: String, scope: HookScope, format: HookFormat, isTOML: Bool, trust: HookTrust) throws -> [HookEntry] {
        let root = try document(at: path, isTOML: isTOML)
        return try entries(of: root, file: path, scope: scope, format: format, editable: !isTOML, trust: trust)
    }

    /// The file parsed, `{}` when it is empty.
    static func document(at path: String, isTOML: Bool) throws -> HookJSON {
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch { throw ReadFailure(description: "the file can't be opened") }
        guard data.count <= fileLimit else { throw ReadFailure(description: "the file is larger than 1 MiB") }
        guard var text = String(data: data, encoding: .utf8) else { throw ReadFailure(description: "the file isn't UTF-8 text") }
        // A leading BOM is dropped for JSON and TOML alike, as the runtime does.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.allSatisfy(\.isWhitespace) { return .object([HookJSON.Member]()) }
        return isTOML ? try HookTOML.parse(text) : try HookJSON.parse(text)
    }

    /// The hooks in a parsed file's `hooks` object, which must have the contract's shape.
    static func entries(of root: HookJSON, file: String, scope: HookScope, format: HookFormat, editable: Bool, trust: HookTrust) throws -> [HookEntry] {
        guard root.objectValue != nil else { throw ReadFailure(description: "the file isn't a JSON object") }
        guard let hooks = root["hooks"] else { return [] }
        guard let events = hooks.objectValue else { throw ReadFailure(description: "“hooks” isn't an object") }
        var entries: [HookEntry] = []
        for member in events {
            guard let groups = member.value.arrayValue else { throw ReadFailure(description: "“hooks.\(member.key)” isn't a list") }
            for (g, group) in groups.enumerated() {
                guard group.objectValue != nil, let handlers = (group["hooks"] ?? .array([])).arrayValue else {
                    throw ReadFailure(description: "a group in “\(member.key)” isn't an object with a “hooks” list")
                }
                let matcher = group["matcher"]?.stringValue ?? ""
                for (h, raw) in handlers.enumerated() {
                    guard raw.objectValue != nil else { throw ReadFailure(description: "a handler in “\(member.key)” isn't an object") }
                    let canonical = raw.canonical
                    let hash = HookCanonical.hash(file: file, event: member.key, matcher: matcher, canonical: canonical)
                    let slot = HookCanonical.slot(file: file, event: member.key, group: g, handler: h)
                    entries.append(HookEntry(slot: slot, scope: scope, file: file, format: format, event: member.key, matcher: matcher,
                                             groupIndex: g, handlerIndex: h, handler: HookHandler(raw: raw), hash: hash,
                                             canonical: canonical, editable: editable, review: trust.review(hash: hash, slot: slot)))
                }
            }
        }
        return entries
    }

    // MARK: Space trust

    /// pi's decisions, `path: true|false`; empty when the file is missing or invalid.
    func readPiTrust() -> [String: Bool] {
        guard let data = try? Data(contentsOf: piTrust),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { value in
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
    }

    /// pi's rule: the nearest decision at or above `root` wins.
    static func trusts(_ decisions: [String: Bool], _ root: String) -> Bool {
        var folder = root
        while true {
            if let decision = decisions[folder] { return decision }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return false }
            folder = parent
        }
    }
}
