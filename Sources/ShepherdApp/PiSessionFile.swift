import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

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

    /// The path as pi sees it: `realpath(3)`, like Node's `fs.realpathSync`. Foundation's
    /// `resolvingSymlinksInPath` is not a substitute: it maps /private/tmp back to /tmp.
    static func realPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else { return (expanded as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `sessionsRoot/<mangled cwd>/` — pi derives the directory name from the
    /// absolute cwd, replacing each path separator with `-` and wrapping the
    /// result in `--`.
    static func projectDirectory(forCwd cwd: String, sessionsRoot: URL) -> URL {
        sessionsRoot.appendingPathComponent("--\(mangled(cwd))--", isDirectory: true)
    }

    /// Pi resolves the real path first (so /tmp and /private/tmp agree), then
    /// mangles it.
    static func mangled(_ cwd: String) -> String {
        realPath(cwd)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
    }

    /// True when pi can already resolve `sessionID` in `cwd` (any file whose
    /// name ends in `_<id>.jsonl`, which is how pi names them).
    static func exists(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL
    ) -> Bool {
        file(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot) != nil
    }

    /// The session file pi resolves for `sessionID` in `cwd`, if there is one.
    static func file(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL
    ) -> URL? {
        let directory = projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let name = names.first(where: { $0.hasSuffix("_\(sessionID).jsonl") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// How much of a session file `hasRuntimeState` reads at a time: the header line and the
    /// start of whatever follows it, unless the header is longer. Long sessions run to tens of
    /// megabytes, and reading one whole on every launch held the app's launch up for seconds.
    static let runtimeStateProbeBytes = 64 * 1024

    /// True when pi has actually written events into the session (model and
    /// thinking changes land as the first entries). A file we merely seeded
    /// has one header line and no pi state. Launch flags like `--thinking`
    /// must only be passed while this is false: once pi owns the session, the
    /// file is the source of truth and flags would clobber in-session changes.
    static func hasRuntimeState(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL
    ) -> Bool {
        guard let url = file(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // Any byte after the header's newline is pi's (a trailing partial line included). A
        // restored agent's session can run to many megabytes; only its first line matters, and
        // reading goes on past the first chunk only while no newline has been seen.
        var headerEnded = false
        while let chunk = try? handle.read(upToCount: runtimeStateProbeBytes), !chunk.isEmpty {
            if headerEnded { return true }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                if chunk.index(after: newline) < chunk.endIndex { return true }
                headerEnded = true
            }
        }
        return false
    }

    /// The agent's thread as its session file holds it, to show while pi starts
    /// (`PiSessionPreview`); nil when pi has no file for the session yet. File work: call it off
    /// the main actor.
    static func preview(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL
    ) -> NativeThreadSnapshot? {
        guard let url = file(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot) else { return nil }
        return PiSessionPreview.snapshot(file: url, sessionID: sessionID)
    }

    /// `preview(sessionID:cwd:)` for a thread's store, read off the main actor, from the cwd pi
    /// is launched in.
    static func previewLoader(sessionID: String, cwd: String, sessionsRoot: URL) -> NativeThreadStore.Preview {
        {
            await Task.detached(priority: .userInitiated) {
                preview(sessionID: sessionID, cwd: TerminalSessionStore.resolvedCwd(cwd), sessionsRoot: sessionsRoot)
            }.value
        }
    }

    /// Before an agent's pi launches: whether its session is still fresh (so launch flags
    /// apply), after seeding the header pi needs to find it. File work, kept off the main actor
    /// by its callers.
    static func prepareForLaunch(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL
    ) -> Bool {
        let fresh = !hasRuntimeState(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot)
        seedIfMissing(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot)
        return fresh
    }

    /// Write the one-line session header pi needs to adopt `sessionID` without
    /// warning. No-op when a session already exists. Returns false when
    /// anything went wrong (the caller carries on regardless).
    @discardableResult
    static func seedIfMissing(
        sessionID: String,
        cwd: String,
        sessionsRoot: URL
    ) -> Bool {
        guard !exists(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot) else { return true }

        let resolvedCwd = realPath(cwd)
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

    struct ForkFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Copy a session file (a native child's transcript, or an agent's own session) into `cwd`'s
    /// project directory under a fresh session id so `pi --session-id` resumes it as a
    /// first-class agent. Every whole entry is kept (a line pi is still writing is left out);
    /// only the header's id, cwd, and timestamp change. Returns the new id.
    static func fork(
        sessionFile: String,
        cwd: String,
        sessionsRoot: URL
    ) throws -> String {
        guard var data = FileManager.default.contents(atPath: sessionFile), !data.isEmpty else {
            throw ForkFailure(message: "The session file is missing or unreadable.")
        }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              var header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              header["type"] as? String == "session" else {
            throw ForkFailure(message: "The session file has no session header.")
        }
        if let last = data.lastIndex(of: UInt8(ascii: "\n")) { data = data[...last] }
        let sessionID = UUID().uuidString.lowercased()
        let now = Date()
        header["id"] = sessionID
        header["cwd"] = realPath(cwd)
        header["timestamp"] = isoTimestamp.string(from: now)
        header.removeValue(forKey: "parentSession")
        let directory = projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
        let url = directory.appendingPathComponent("\(fileTimestamp.string(from: now))_\(sessionID).jsonl")
        do {
            let headerData = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try (headerData + data[newline...]).write(to: url, options: .atomic)
        } catch {
            throw ForkFailure(message: "Could not copy the transcript: \(error.localizedDescription)")
        }
        return sessionID
    }

    /// What was said in a session, oldest first, as "user: …" and "assistant: …" paragraphs: the
    /// user's and the assistant's text along the branch pi is on (walked back from its last
    /// entry by `parentId`), never thinking, tool calls or their results. Nil when the file
    /// is missing or holds nothing said. File work: call it off the main actor.
    static func transcript(file: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file.path) else { return nil }
        var entries: [String: [String: Any]] = [:]
        var order: [String] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  entry["type"] as? String != "session" else { continue }
            let id = entry["id"] as? String ?? "#\(order.count)"
            entries[id] = entry
            order.append(id)
        }
        // pi's entries form a tree once the conversation has branched; older files carry no
        // parent links, and then every entry is on the one branch.
        var branch: [String] = []
        var cursor = order.last
        var seen: Set<String> = []
        while let id = cursor, let entry = entries[id], seen.insert(id).inserted {
            branch.append(id)
            cursor = entry["parentId"] as? String
        }
        if branch.count < order.count, !order.contains(where: { entries[$0]?["parentId"] is String }) { branch = order.reversed() }
        let paragraphs = branch.reversed().compactMap { id -> String? in
            guard let entry = entries[id], entry["type"] as? String == "message",
                  let message = entry["message"] as? [String: Any],
                  let role = message["role"] as? String, role == "user" || role == "assistant" else { return nil }
            let text: String
            if let plain = message["content"] as? String {
                text = plain
            } else {
                let blocks = message["content"] as? [[String: Any]] ?? []
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : "\(role): \(trimmed)"
        }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
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
