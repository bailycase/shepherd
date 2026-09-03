import Foundation

/// Pi's on-disk session files, from Shepherd's side.
///
/// Shepherd launches every agent with `--session-id <agent id>` so the agent
/// resumes the same conversation across respawns. Pi only *writes* a session
/// file once the agent has actually done something, so an agent that is never
/// prompted has no file — and pi greets every relaunch with
/// "Warning: No project session found with id '…'; creating a new session with
/// that id." on the first two rows of the pane, forever.
///
/// Seeding the session header ourselves removes the warning at the source:
/// `SessionManager.list` then finds the id and pi opens it instead of warning.
/// Best-effort by design — if anything here fails the agent still launches,
/// it just prints the warning as before.
enum PiSessionFile {
    /// Pi's session-file schema version. Kept in step with the `{"type":"session"}`
    /// header pi itself writes; a mismatch only risks the warning coming back,
    /// never a broken session.
    private static let version = 3

    /// Pi's default `~/.pi/agent/sessions` root. Tests pass a scratch root
    /// instead so they never write into the user's home directory.
    static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    /// `sessionsRoot/<mangled cwd>/` — pi derives the directory name from the
    /// absolute cwd, replacing each path separator with `-` and wrapping the
    /// result in `--`.
    static func projectDirectory(forCwd cwd: String, sessionsRoot: URL = defaultSessionsRoot) -> URL {
        sessionsRoot.appendingPathComponent("--\(mangled(cwd))--", isDirectory: true)
    }

    /// Pi resolves the real path first (so /tmp and /private/tmp agree), then
    /// mangles it.
    static func mangled(_ cwd: String) -> String {
        let resolved = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .path
        return resolved
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
    }

    /// True when pi can already resolve `sessionID` in `cwd` (any file whose
    /// name ends in `_<id>.jsonl`, which is how pi names them).
    static func exists(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL = defaultSessionsRoot
    ) -> Bool {
        let directory = projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return names.contains { $0.hasSuffix("_\(sessionID).jsonl") }
    }

    /// True when pi has actually written events into the session (model and
    /// thinking changes land as the first entries). A file we merely seeded
    /// has one header line and no pi state. Launch flags like `--thinking`
    /// must only be passed while this is false: once pi owns the session, the
    /// file is the source of truth and flags would clobber in-session changes.
    static func hasRuntimeState(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL = defaultSessionsRoot
    ) -> Bool {
        let directory = projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let name = names.first(where: { $0.hasSuffix("_\(sessionID).jsonl") }),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name))
        else { return false }
        // More than one newline-terminated line means pi appended events.
        let newlines = data.filter { $0 == UInt8(ascii: "\n") }.count
        if newlines > 1 { return true }
        // A trailing partial second line counts too.
        if let last = data.lastIndex(of: UInt8(ascii: "\n")), last < data.count - 1 { return true }
        return false
    }

    /// Write the one-line session header pi needs to adopt `sessionID` without
    /// warning. No-op when a session already exists. Returns false when
    /// anything went wrong (the caller carries on regardless).
    @discardableResult
    static func seedIfMissing(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL = defaultSessionsRoot
    ) -> Bool {
        guard !exists(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot) else { return true }

        let resolvedCwd = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .path
        let directory = projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
        let now = Date()

        let header: [String: Any] = [
            "type": "session",
            "version": version,
            "id": sessionID,
            "timestamp": isoTimestamp.string(from: now),
            "cwd": resolvedCwd,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) else {
            return false
        }

        let url = directory.appendingPathComponent("\(fileTimestamp.string(from: now))_\(sessionID).jsonl")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `2026-08-22T01:34:01.750Z`
    private static let isoTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    /// `2026-08-22T01-34-01-750Z` (pi's filename-safe rendition).
    private static let fileTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
        return formatter
    }()
}
