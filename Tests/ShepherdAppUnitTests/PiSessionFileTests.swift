import Foundation
import Testing
@testable import ShepherdApp

/// Shepherd seeds pi's session file so `--session-id` finds a session instead of printing
/// "No project session found" into every never-prompted agent. Pi owns the format; these pin
/// the parts Shepherd depends on. Every test uses a scratch sessions root, never ~/.pi.
@Suite("Pi session files")
struct PiSessionFileTests {
    /// A real cwd (so realpath resolves) plus a scratch sessions root.
    private struct Scratch {
        let cwd: URL
        let root: URL

        init() throws {
            cwd = try Fixture.scratchDirectory("pi-cwd")
            root = try Fixture.scratchDirectory("pi-sessions")
        }

        func remove() {
            try? FileManager.default.removeItem(at: cwd)
            try? FileManager.default.removeItem(at: root)
        }

        var projectDirectory: URL { PiSessionFile.projectDirectory(forCwd: cwd.path, sessionsRoot: root) }

        func files(for id: String) -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)) ?? []
            return names.filter { $0.hasSuffix("_\(id).jsonl") }.map { projectDirectory.appendingPathComponent($0) }
        }

        func header(of file: URL) throws -> [String: Any] {
            let firstLine = try #require(try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
            return try #require(try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        }
    }

    // MARK: Paths

    @Test(arguments: [
        ("/Users/dev/Developer/Shepherd", "Users-dev-Developer-Shepherd"),
        ("/Users/dev/", "Users-dev"),
    ])
    func projectDirectoriesMangleTheAbsoluteCwd(cwd: String, mangled: String) {
        #expect(PiSessionFile.mangled(cwd) == mangled)
        #expect(PiSessionFile.projectDirectory(forCwd: cwd, sessionsRoot: URL(fileURLWithPath: "/r")).path == "/r/--\(mangled)--")
    }

    /// pi uses realpath(3): /tmp lives under /private, and Foundation's symlink resolution
    /// would drop that prefix and look in the wrong project directory.
    @Test func pathsResolveLikeRealpathKeepingThePrivatePrefix() throws {
        #expect(PiSessionFile.realPath("/tmp") == "/private/tmp")
        #expect(PiSessionFile.mangled("/tmp") == "private-tmp")
    }

    @Test func aMissingPathStillNormalizes() {
        #expect(PiSessionFile.realPath("/definitely/../missing/./dir") == "/missing/dir")
    }

    // MARK: Seeding

    @Test func seedingWritesAOneLineHeaderPiCanResolve() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let id = UUID().uuidString
        #expect(!PiSessionFile.exists(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))

        #expect(PiSessionFile.seedIfMissing(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))

        #expect(PiSessionFile.exists(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))
        let file = try #require(scratch.files(for: id).first)
        #expect(try String(contentsOf: file, encoding: .utf8).filter { $0 == "\n" }.count == 1)
        let header = try scratch.header(of: file)
        #expect(header["type"] as? String == "session")
        #expect(header["id"] as? String == id)
        #expect(header["version"] as? Int == 3)
        #expect(header["cwd"] as? String == PiSessionFile.realPath(scratch.cwd.path))
        #expect(header["timestamp"] as? String != nil)
    }

    /// A second file for the same id would make pi's "latest session" ambiguous.
    @Test func seedingTwiceIsANoOp() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let id = UUID().uuidString
        PiSessionFile.seedIfMissing(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root)

        #expect(PiSessionFile.seedIfMissing(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))
        #expect(scratch.files(for: id).count == 1)
    }

    /// Launch flags like `--thinking` are passed only while pi has written nothing: once pi
    /// owns the session, the file is the source of truth.
    @Test func runtimeStateMeansEventsBeyondTheSeededHeader() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let id = UUID().uuidString
        #expect(!PiSessionFile.hasRuntimeState(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))

        PiSessionFile.seedIfMissing(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root)
        #expect(!PiSessionFile.hasRuntimeState(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))

        let file = try #require(scratch.files(for: id).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"thinking_level_change""#.utf8)) // partial trailing line
        try handle.close()
        #expect(PiSessionFile.hasRuntimeState(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))
    }

    // MARK: Forking a child transcript

    private static let childTranscript = """
    {"type":"session","version":3,"id":"child-id","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/elsewhere","parentSession":"/p.jsonl"}
    {"type":"message","id":"m1","message":{"role":"user","content":"hello child"}}
    {"type":"message","id":"m2","message":{"role":"assistant","content":[{"type":"text","text":"hi parent"}]}}

    """

    @Test func forkingCopiesEveryEntryUnderAFreshResolvableID() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let child = scratch.cwd.appendingPathComponent("child.jsonl")
        try Self.childTranscript.write(to: child, atomically: true, encoding: .utf8)

        let id = try PiSessionFile.fork(sessionFile: child.path, cwd: scratch.cwd.path, sessionsRoot: scratch.root)

        #expect(id != "child-id")
        #expect(PiSessionFile.hasRuntimeState(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root))
        let copy = try #require(scratch.files(for: id).first)
        let lines = try String(contentsOf: copy, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].contains("hello child") && lines[2].contains("hi parent"))
        let header = try scratch.header(of: copy)
        #expect(header["id"] as? String == id)
        #expect(header["cwd"] as? String == PiSessionFile.realPath(scratch.cwd.path))
        #expect(header["parentSession"] == nil)
        #expect(header["timestamp"] as? String != "2026-01-01T00:00:00.000Z")
    }

    @Test func forkingLeavesTheChildUntouchedAndEachForkIsDistinct() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let child = scratch.cwd.appendingPathComponent("child.jsonl")
        try Self.childTranscript.write(to: child, atomically: true, encoding: .utf8)

        let first = try PiSessionFile.fork(sessionFile: child.path, cwd: scratch.cwd.path, sessionsRoot: scratch.root)
        let second = try PiSessionFile.fork(sessionFile: child.path, cwd: scratch.cwd.path, sessionsRoot: scratch.root)

        #expect(first != second)
        #expect(try String(contentsOf: child, encoding: .utf8) == Self.childTranscript)
    }

    @Test(arguments: ["missing", "headerless", "empty"])
    func forkingSomethingThatIsNotASessionFailsAndWritesNothing(kind: String) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = scratch.cwd.appendingPathComponent("\(kind).jsonl")
        switch kind {
        case "headerless": try #"{"type":"message"}"#.appending("\n").write(to: source, atomically: true, encoding: .utf8)
        case "empty": try Data().write(to: source)
        default: break
        }

        #expect(throws: PiSessionFile.ForkFailure.self) {
            try PiSessionFile.fork(sessionFile: source.path, cwd: scratch.cwd.path, sessionsRoot: scratch.root)
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.projectDirectory.path))
    }
}
