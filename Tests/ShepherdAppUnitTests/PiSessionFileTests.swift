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

    /// A launch reads only the head of the file, whatever the session's length, and a
    /// session is fresh until pi writes past the header.
    @Test func preparingALaunchSeedsAFreshSessionAndKnowsALongOneFromItsHead() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fresh = UUID().uuidString
        #expect(PiSessionFile.prepareForLaunch(sessionID: fresh, cwd: scratch.cwd.path, sessionsRoot: scratch.root))
        #expect(scratch.files(for: fresh).count == 1)
        #expect(PiSessionFile.prepareForLaunch(sessionID: fresh, cwd: scratch.cwd.path, sessionsRoot: scratch.root))

        let long = UUID().uuidString
        PiSessionFile.seedIfMissing(sessionID: long, cwd: scratch.cwd.path, sessionsRoot: scratch.root)
        let file = try #require(scratch.files(for: long).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let entry = #"{"type":"message","message":{"role":"user","content":"\#(String(repeating: "x", count: 1000))"}}"# + "\n"
        try handle.write(contentsOf: Data(String(repeating: entry, count: 3 * PiSessionFile.runtimeStateProbeBytes / 1000).utf8))
        try handle.close()
        #expect(!PiSessionFile.prepareForLaunch(sessionID: long, cwd: scratch.cwd.path, sessionsRoot: scratch.root))
        #expect(PiSessionFile.file(sessionID: long, cwd: scratch.cwd.path, sessionsRoot: scratch.root) == file)
    }

    /// Session files as pi leaves them, and whether each carries pi's own state.
    enum SessionFileShape: String, CaseIterable, Sendable {
        case missing, headerOnly, headerWithoutNewline, headerAndPartialLine, headerAndEightMegabytes
        case longHeaderThenLine, headerFillingTheFirstRead, headerFillingTheFirstReadThenAByte
        case crlfHeaderOnly, crlfHeaderAndEvent

        static let header = #"{"type":"session","version":3,"id":"x"}"#
        static let event = #"{"type":"thinking_level_change","level":"high"}"#

        var contents: Data? {
            let header = Self.header, event = Self.event
            switch self {
            case .missing: return nil
            case .headerOnly: return Data((header + "\n").utf8)
            case .headerWithoutNewline: return Data(header.utf8)
            case .headerAndPartialLine: return Data((header + "\n" + #"{"type":"thinking"#).utf8)
            case .headerAndEightMegabytes:
                return Data((header + "\n" + String(repeating: event + "\n", count: 8 * 1024 * 1024 / (event.utf8.count + 1))).utf8)
            case .longHeaderThenLine: return Data((String(repeating: "x", count: 100_000) + "\n" + event + "\n").utf8)
            case .headerFillingTheFirstRead: return Data((String(repeating: "x", count: 64 * 1024 - 1) + "\n").utf8)
            case .headerFillingTheFirstReadThenAByte: return Data((String(repeating: "x", count: 64 * 1024 - 1) + "\n{").utf8)
            case .crlfHeaderOnly: return Data((header + "\r\n").utf8)
            case .crlfHeaderAndEvent: return Data((header + "\r\n" + event + "\r\n").utf8)
            }
        }

        var hasRuntimeState: Bool {
            switch self {
            case .missing, .headerOnly, .headerWithoutNewline, .headerFillingTheFirstRead, .crlfHeaderOnly: false
            case .headerAndPartialLine, .headerAndEightMegabytes, .longHeaderThenLine, .headerFillingTheFirstReadThenAByte,
                 .crlfHeaderAndEvent: true
            }
        }
    }

    /// Any byte after the header line is pi's, however long the header or the file.
    @Test(arguments: SessionFileShape.allCases)
    func runtimeStateIsAnyByteAfterTheHeaderLine(shape: SessionFileShape) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let id = UUID().uuidString
        if let contents = shape.contents {
            try FileManager.default.createDirectory(at: scratch.projectDirectory, withIntermediateDirectories: true)
            try contents.write(to: scratch.projectDirectory.appendingPathComponent("2026-01-01T00-00-00-000Z_\(id).jsonl"))
        }
        #expect(PiSessionFile.hasRuntimeState(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root) == shape.hasRuntimeState)
    }

    /// `SHEPHERD_BENCHMARK=1`: what the check costs a restored agent's spawn,
    /// beside the whole-file newline count it replaced.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_BENCHMARK"] != nil), arguments: [1, 8, 32])
    func runtimeStateCheckCost(megabytes: Int) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let id = UUID().uuidString
        let line = SessionFileShape.event + "\n"
        let body = SessionFileShape.header + "\n" + String(repeating: line, count: megabytes * 1024 * 1024 / line.utf8.count)
        try FileManager.default.createDirectory(at: scratch.projectDirectory, withIntermediateDirectories: true)
        let file = scratch.projectDirectory.appendingPathComponent("2026-01-01T00-00-00-000Z_\(id).jsonl")
        try Data(body.utf8).write(to: file)
        func median(_ body: () -> Void) -> Double {
            let samples = (0..<9).map { _ in
                let start = ContinuousClock.now
                body()
                let elapsed = ContinuousClock.now - start
                return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            }
            return samples.sorted()[samples.count / 2]
        }
        let prefix = median { _ = PiSessionFile.hasRuntimeState(sessionID: id, cwd: scratch.cwd.path, sessionsRoot: scratch.root) }
        let wholeFile = median {
            let data = (try? Data(contentsOf: file)) ?? Data()
            _ = data.filter { $0 == UInt8(ascii: "\n") }.count > 1
        }
        print(String(format: "BENCH name=piSessionFile.hasRuntimeState.%dMB value=%.3f unit=ms wholeFileScan=%.3fms", megabytes, prefix, wholeFile))
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

    @Test func forkingLeavesOutALinePiIsStillWriting() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let source = scratch.cwd.appendingPathComponent("live.jsonl")
        try (Self.childTranscript + #"{"type":"message","id":"m3","message":{"ro"#).write(to: source, atomically: true, encoding: .utf8)

        let id = try PiSessionFile.fork(sessionFile: source.path, cwd: scratch.cwd.path, sessionsRoot: scratch.root)

        let copy = try #require(scratch.files(for: id).first)
        let text = try String(contentsOf: copy, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 3)
        #expect(text.hasSuffix("\n") && !text.contains("m3"))
    }

    @Test func aForkIsNamedAfterItsAgent() {
        #expect(ShepherdViewModel.forkName("Restyle native UI") == "Restyle native UI (fork)")
    }

    // MARK: Transcripts

    private func transcript(_ lines: [String]) throws -> String? {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let file = scratch.cwd.appendingPathComponent("session.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return PiSessionFile.transcript(file: file)
    }

    @Test func aTranscriptIsWhatWasSaidNeverThinkingOrTools() throws {
        let text = try transcript([
            #"{"type":"session","version":3,"id":"s","cwd":"/x"}"#,
            #"{"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"Fix the build"}}"#,
            #"{"type":"message","id":"b","parentId":"a","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking."},{"type":"toolCall","name":"bash"}]}}"#,
            #"{"type":"message","id":"c","parentId":"b","message":{"role":"toolResult","content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"model_change","id":"d","parentId":"c","modelId":"x"}"#,
            #"{"type":"message","id":"e","parentId":"d","message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]}}"#,
        ])
        #expect(text == "user: Fix the build\n\nassistant: Looking.\n\nassistant: Fixed.")
    }

    @Test func aTranscriptFollowsTheBranchPiIsOn() throws {
        let text = try transcript([
            #"{"type":"session","version":3,"id":"s","cwd":"/x"}"#,
            #"{"type":"message","id":"a","parentId":null,"message":{"role":"user","content":"first"}}"#,
            #"{"type":"message","id":"b","parentId":"a","message":{"role":"assistant","content":"abandoned"}}"#,
            #"{"type":"message","id":"c","parentId":"a","message":{"role":"assistant","content":"kept"}}"#,
        ])
        #expect(text == "user: first\n\nassistant: kept")
    }

    @Test func aTranscriptWithoutParentLinksKeepsEveryEntry() throws {
        let text = try transcript([
            #"{"type":"session","version":3,"id":"s","cwd":"/x"}"#,
            #"{"type":"message","id":"a","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"message","id":"b","message":{"role":"assistant","content":"hi"}}"#,
        ])
        #expect(text == "user: hello\n\nassistant: hi")
    }

    @Test func aSessionWithNothingSaidHasNoTranscript() throws {
        #expect(try transcript([#"{"type":"session","version":3,"id":"s","cwd":"/x"}"#]) == nil)
    }
}
