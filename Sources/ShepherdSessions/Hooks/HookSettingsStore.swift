import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Reads and writes `settings.json`. Every change reads the file, applies itself and writes the
/// whole file by temp file and rename. Only a missing file reads as the defaults (everything on).
/// A file that can't be read is damaged: reads and changes throw `Damaged`, the file is left as it
/// is, and callers treat every hook as off, because the file holds the switches the person turned
/// off and defaulting would run them again.
public final class HookSettingsStore: @unchecked Sendable {
    public struct Damaged: Error, LocalizedError, Equatable, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let url: URL
    private let lock = NSLock()
    private var loggedDamage = false

    /// `support` is Shepherd's Application Support folder; the file is `<support>/hooks/settings.json`.
    public init(support: URL) {
        url = support.appendingPathComponent("hooks", isDirectory: true).appendingPathComponent("settings.json")
    }

    /// The file as it is now, or the defaults when it is missing. Throws when it is damaged.
    public func read() throws -> HookSettings {
        try lock.withLock { try load() }
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

    /// The app and host can both write. Lock a separate inode because settings is replaced by rename.
    func withMutation<T>(_ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("settings.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return try body()
    }

    /// Applies `body` to the current file and writes the result whole; nothing when it changes nothing.
    public func change(_ body: (inout HookSettings) throws -> Void) throws {
        try withMutation { try changeLocked(body) }
    }

    /// Call inside `withMutation`, including when the settings write must precede a hook publish.
    func changeLocked(_ body: (inout HookSettings) throws -> Void) throws {
        try lock.withLock {
            var settings = try load()
            let before = settings
            try body(&settings)
            guard settings != before else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(settings)
            data.append(UInt8(ascii: "\n"))
            try PiHome.write(data, to: url, mode: 0o600)
        }
    }

    /// Call with the lock held. The damage is logged once until the file reads again.
    private func load() throws -> HookSettings {
        switch PersistedFile<HookSettings>.load(from: url) {
        case .loaded(let settings):
            loggedDamage = false
            return settings
        case .missing:
            loggedDamage = false
            return HookSettings()
        case .damaged(_, let error):
            let message = "Couldn't read \(url.path): \(error). Every hook is treated as off until it is fixed. "
                + "Restore the file from a backup or fix its JSON."
            if !loggedDamage {
                ShepherdLog.error(message)
                loggedDamage = true
            }
            throw Damaged(message: message)
        }
    }
}
