import Foundation

/// `<support>/hooks/settings.json` (docs/hooks.md › Identity and the off switch): which hooks the
/// person switched off, by hash, and whether the Claude Code and Codex readers are on. Every
/// configured hook not in `off` runs.
public struct HookSettings: Equatable, Sendable, Codable {
    /// The Sources switches: whether Claude Code's and Codex's files are read. Both default on.
    public struct Readers: Equatable, Sendable, Codable {
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

/// Reads and writes `settings.json`. Every change reads the file, applies itself and writes the
/// whole file by temp file and rename; a missing or invalid file reads as everything on.
public final class HookSettingsStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    /// `support` is Shepherd's Application Support folder; the file is `<support>/hooks/settings.json`.
    public init(support: URL) {
        url = support.appendingPathComponent("hooks", isDirectory: true).appendingPathComponent("settings.json")
    }

    /// The file as it is now, or the defaults when it is missing or invalid.
    public func read() -> HookSettings {
        lock.withLock { load() }
    }

    /// Switches a hook on or off.
    public func setOn(_ hash: String, _ on: Bool) throws {
        try change { settings in
            settings.off.removeAll { $0 == hash }
            if !on { settings.off.append(hash) }
        }
    }

    /// Turns the Claude Code or Codex reader on or off. Shepherd's own files are always read.
    public func setReader(_ format: HookFormat, _ on: Bool) throws {
        try change { settings in
            switch format {
            case .shepherd: break
            case .claude: settings.readers.claude = on
            case .codex: settings.readers.codex = on
            }
        }
    }

    /// Applies `body` to the current file and writes the result whole; nothing when it changes nothing.
    public func change(_ body: (inout HookSettings) throws -> Void) throws {
        try lock.withLock {
            var settings = load()
            let before = settings
            try body(&settings)
            guard settings != before else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(settings)
            data.append(UInt8(ascii: "\n"))
            try PiHome.write(data, to: url, mode: 0o600)
        }
    }

    private func load() -> HookSettings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(HookSettings.self, from: data) else { return HookSettings() }
        return settings
    }
}
