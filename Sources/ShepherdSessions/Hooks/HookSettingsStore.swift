import Foundation
import ShepherdProtocol

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
