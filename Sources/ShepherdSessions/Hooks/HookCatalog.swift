import Foundation
import ShepherdProtocol

/// Finds and reads the hooks files on this host. A value: every call reads
/// the files afresh, so call it off the main thread and off the server queue.
public struct HookCatalog: Sendable {
    /// The user's home folder (`HOME`), where This Mac's files live. Never a space.
    public var home: String
    /// `<support>/hooks/settings.json`: the off switches and readers.
    public var settingsStore: HookSettingsStore

    /// Files larger than this are reported, not read.
    public static let fileLimit = 1 << 20

    /// Debug builds only: the home folder whose This Mac files the app's catalog reads. The test
    /// isolation sets it, so no test reads or writes the person's `~/.shepherd`, `~/.claude` or `~/.codex`.
    public static let homeOverrideEnvKey = "SHEPHERD_HOOKS_HOME"

    /// The app's hooks home: the override where honoured, else `fallback` (pi's user home).
    public static func home(fallback: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            honoursOverride: Bool = PiEngine.honoursOverride) -> String {
        guard honoursOverride, let value = environment[homeOverrideEnvKey], !value.isEmpty else { return fallback }
        return value
    }

    /// `support` is Shepherd's Application Support folder.
    public init(home: String = PiHome.environmentHome, support: URL) {
        // Kept as given (never standardized, which drops /private): file paths in hashes start with it.
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        self.home = home
        settingsStore = HookSettingsStore(support: support)
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
        let settings = settingsStore.read()
        let canonicalHome = PiHome.canonical(home)
        var sources: [HookSource] = [], entries: [HookEntry] = []
        var scopes: [(HookScope, String)] = [(.mac, home)]
        var seen = Set<String>()
        for root in spaceRoots {
            let root = PiHome.canonical(root)
            guard !PiHome.isInside(canonicalHome, root), seen.insert(root).inserted else { continue }
            scopes.append((.space(root: root), root))
        }
        for (scope, folder) in scopes {
            for (relative, format) in Self.layout {
                // The home's Claude Code local settings aren't in the contract's table.
                if scope == .mac && relative == ".claude/settings.local.json" { continue }
                let path = folder + "/" + relative
                let isTOML = relative.hasSuffix(".toml")
                var source = HookSource(path: path, scope: scope, format: format, isTOML: isTOML, state: .notFound)
                if !FileManager.default.fileExists(atPath: path) {
                    source.state = .notFound
                } else if !settings.readers.reads(format) {
                    source.state = .readerOff
                } else {
                    do {
                        let found = try Self.entries(in: path, scope: scope, format: format, isTOML: isTOML, settings: settings)
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
        return HookCatalogSnapshot(sources: sources, entries: entries, settings: settings, home: home)
    }

    /// The composer glyph's counts for a thread in `cwd`: reads This Mac's files and that space's.
    public func summary(forCwd cwd: String) -> HookSummary {
        let root = spaceRoot(forCwd: cwd)
        return load(spaceRoots: root.map { [$0] } ?? []).summary(forSpaceRoot: root)
    }

    // MARK: Reading

    struct ReadFailure: Error, CustomStringConvertible { let description: String }

    /// The hooks in one file. Throws `HookJSON.ParseError` or `ReadFailure`.
    static func entries(in path: String, scope: HookScope, format: HookFormat, isTOML: Bool, settings: HookSettings) throws -> [HookEntry] {
        let root = try document(at: path, isTOML: isTOML)
        return try entries(of: root, file: path, scope: scope, format: format, editable: !isTOML, settings: settings)
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
    static func entries(of root: HookJSON, file: String, scope: HookScope, format: HookFormat, editable: Bool, settings: HookSettings = HookSettings()) throws -> [HookEntry] {
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
                                             canonical: canonical, editable: editable, on: settings.isOn(hash)))
                }
            }
        }
        return entries
    }
}
