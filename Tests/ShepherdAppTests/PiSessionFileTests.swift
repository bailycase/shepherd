import Foundation
import Testing
@testable import ShepherdApp

/// Shepherd seeds pi's session file so `--session-id` finds a session instead
/// of printing "No project session found with id …" into the top of the pane
/// on every launch of an agent that was never prompted.
@Suite("Pi session files")
struct PiSessionFileTests {
    /// Pi derives its per-project directory from the resolved absolute cwd:
    /// separators become hyphens, wrapped in `--`.
    @Test func mangledPathMatchesPiLayout() {
        #expect(PiSessionFile.mangled("/Users/dev/Developer/Shepherd") == "Users-dev-Developer-Shepherd")
        // Trailing separators must not produce an empty trailing component.
        #expect(PiSessionFile.mangled("/Users/dev/") == "Users-dev")
    }

    @Test func seedingCreatesAResolvableSessionThenNoOps() throws {
        // A real (temporary) cwd, so the seeded file lands in the same place
        // pi would look for it.
        let cwd = try makeScratchCwd()
        let sessionsRoot = try makeScratchSessionsRoot()
        defer { cleanUp(cwd: cwd, sessionsRoot: sessionsRoot) }

        let sessionID = UUID().uuidString
        #expect(PiSessionFile.exists(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot) == false)

        #expect(PiSessionFile.seedIfMissing(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))
        #expect(PiSessionFile.exists(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))

        // The header must be one line of JSON carrying the id and cwd, which
        // is what pi's session lister reads.
        let file = try #require(seededFile(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))
        let contents = try String(contentsOf: file, encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        #expect(object["type"] as? String == "session")
        #expect(object["id"] as? String == sessionID)
        #expect(object["version"] as? Int == 3)
        #expect(object["cwd"] as? String == URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path)

        // Seeding again must not add a second file for the same id (that would
        // make pi's "latest session" ambiguous).
        #expect(PiSessionFile.seedIfMissing(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))
        #expect(try sessionFiles(cwd: cwd, sessionsRoot: sessionsRoot).filter { $0.hasSuffix("_\(sessionID).jsonl") }.count == 1)
    }

    /// A seeded header alone is not runtime state; pi appending events (or a
    /// partial trailing line) is. Launch flags key off this distinction.
    @Test func runtimeStateRequiresEventsBeyondTheSeededHeader() throws {
        let cwd = try makeScratchCwd()
        let sessionsRoot = try makeScratchSessionsRoot()
        defer { cleanUp(cwd: cwd, sessionsRoot: sessionsRoot) }

        let sessionID = UUID().uuidString
        // No file at all: no state.
        #expect(!PiSessionFile.hasRuntimeState(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))

        // Seeded header only: still no state.
        #expect(PiSessionFile.seedIfMissing(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))
        #expect(!PiSessionFile.hasRuntimeState(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))

        // Pi appends an event (what a thinking change writes): state.
        let file = try #require(seededFile(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"thinking_level_change\",\"thinkingLevel\":\"max\"}\n".utf8))
        try handle.close()
        #expect(PiSessionFile.hasRuntimeState(sessionID: sessionID, cwd: cwd, sessionsRoot: sessionsRoot))
    }

    // MARK: helpers

    private func sessionsDirectory(cwd: String, sessionsRoot: URL) -> URL {
        PiSessionFile.projectDirectory(forCwd: cwd, sessionsRoot: sessionsRoot)
    }

    private func sessionFiles(cwd: String, sessionsRoot: URL) throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: sessionsDirectory(cwd: cwd, sessionsRoot: sessionsRoot).path
        )) ?? []
    }

    private func seededFile(sessionID: String, cwd: String, sessionsRoot: URL) -> URL? {
        guard let name = try? sessionFiles(cwd: cwd, sessionsRoot: sessionsRoot)
            .first(where: { $0.hasSuffix("_\(sessionID).jsonl") }) else {
            return nil
        }
        return sessionsDirectory(cwd: cwd, sessionsRoot: sessionsRoot).appendingPathComponent(name)
    }

    private func makeScratchCwd() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-pi-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func makeScratchSessionsRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-pi-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Remove both scratch directories. The test never touches ~/.pi.
    private func cleanUp(cwd: String, sessionsRoot: URL) {
        try? FileManager.default.removeItem(at: sessionsRoot)
        try? FileManager.default.removeItem(atPath: cwd)
    }
}
