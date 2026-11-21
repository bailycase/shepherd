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
            appendHostLog(line, url: url, limit: hostLogLimit)
        }
    }

    static func appendHostLog(_ line: String, url: URL, limit: Int) {
        guard limit > 0 else { return }
        let utf8 = line.utf8
        var bytes: Data
        if utf8.count <= limit {
            bytes = Data(utf8)
        } else {
            var end = utf8.index(utf8.startIndex, offsetBy: limit - 1)
            // Don't split a UTF-8 scalar. Leave room for the line terminator.
            while utf8[end] & 0xC0 == 0x80 { utf8.formIndex(before: &end) }
            bytes = Data(utf8[..<end])
            bytes.append(10)
        }
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        var fd = open(url.path, flags, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { if fd >= 0 { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        if info.st_size > limit - bytes.count {
            close(fd)
            fd = -1
            guard rename(url.path, url.appendingPathExtension("1").path) == 0 else { return }
            fd = open(url.path, flags, S_IRUSR | S_IWUSR)
            guard fd >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
        }
        bytes.withUnsafeBytes { buffer in
            _ = write(fd, buffer.baseAddress, buffer.count)
        }
    }
}
