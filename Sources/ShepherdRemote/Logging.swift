import Darwin
import Foundation
import os

/// Timestamped stderr logging for the session server (and, historically,
/// a separate executable).
public enum ShepherdLog {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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

    /// Each phone push decision and each relay answer, in the unified log as well (category "Push"),
    /// since the background host's stderr goes nowhere. Kinds, counts and statuses only, never a
    /// token, registration id or the alert's text.
    public static func push(_ message: String) {
        pushLog.notice("\(message, privacy: .public)")
        emit("INFO", message)
    }

    private static func emit(_ level: String, _ message: String) {
        // fputs serializes via stdio's internal file lock.
        fputs("\(formatter.string(from: Date())) [\(level)] \(message)\n", stderr)
    }
}
