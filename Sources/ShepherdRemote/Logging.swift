import Darwin
import Foundation
import os

/// Timestamped stderr logging for the session server (and, historically,
/// a separate executable).
public enum ShepherdLog {
    private static let formatter = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static let hostLog = OSAllocatedUnfairLock<URL?>(initialState: nil)
    private static let hostLogLimit = 256 * 1024

    /// A signed LaunchAgent plist cannot name a user's Application Support folder at build time.
    /// The background host calls this once it owns the workspace; keep stderr for local debugging.
    public static func persistHostLog(in support: URL) {
        hostLog.withLock { $0 = support.appendingPathComponent("host.log") }
    }

    public static func info(_ message: String) { emit("INFO", message) }
    public static func warning(_ message: String) { emit("WARN", message) }
    public static func error(_ message: String) { emit("ERROR", message) }

    private static let connectionLog = Logger(subsystem: "com.shepherd.app", category: "Connection")

    /// A connection to or from a host opening, failing or closing, and why. Goes to the unified log
    /// as well (`log show --predicate 'subsystem == "com.shepherd.app" AND category == "Connection"'`),
    /// public, so callers put only reasons, sizes and descriptors in it, never a payload or a token.
    public static func connection(_ message: String) {
        connectionLog.notice("\(message, privacy: .public)")
        emit("INFO", message)
    }

    private static let pushLog = Logger(subsystem: "com.shepherd.app", category: "Push")

    /// Each phone push decision and each relay answer, in the unified log as well (category "Push").
    /// Kinds, counts and statuses only, never a token, registration id or the alert's text.
    public static func push(_ message: String) {
        pushLog.notice("\(message, privacy: .public)")
        emit("INFO", message)
    }

    private static func emit(_ level: String, _ message: String) {
        // fputs serializes via stdio's internal file lock.
        let line = "\(formatter.format(Date())) [\(level)] \(message)\n"
        fputs(line, stderr)
        hostLog.withLock { url in
            guard let url else { return }
            var bytes = Data(line.utf8.prefix(hostLogLimit - 1))
            if bytes.count < line.utf8.count { bytes.append(10) }
            appendHostLog(bytes, to: url)
        }
    }

    private static func appendHostLog(_ bytes: Data, to url: URL) {
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var fd = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { if fd >= 0 { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        if info.st_size > hostLogLimit - bytes.count {
            close(fd)
            fd = -1
            guard rename(url.path, url.appendingPathExtension("1").path) == 0 else { return }
            fd = open(url.path, flags, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
        }
        bytes.withUnsafeBytes { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
    }
}
