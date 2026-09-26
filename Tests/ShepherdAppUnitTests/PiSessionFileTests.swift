import Foundation
import Testing
@testable import ShepherdApp
import ShepherdSessions

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
        // pi replaces `:` and `\` too, and strips only the leading separator.
        ("/Users/dev/proj:v2", "Users-dev-proj-v2"),
        ("/Users/dev/back\\slash", "Users-dev-back-slash"),
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

/// Adoption: an agent's conversation from before Shepherd ran its own pi is copied, once, from
/// "your pi" into Shepherd's home, decided by what each side holds, and the user's file is only
/// ever read.
@Suite("Adopting a conversation from your pi")
struct PiSessionAdoptionTests {
    enum Side: String, CaseIterable, CustomTestStringConvertible {
        case nothing, header, conversation, newer, linked
        var testDescription: String { rawValue }
    }

    struct Scratch {
        let cwd: URL, ours: URL, theirs: URL, outside: URL
        let id = "0b8e2c3a-adopt"

        init() throws {
            cwd = try Fixture.scratchDirectory("adopt-cwd")
            ours = try Fixture.scratchDirectory("adopt-ours")
            theirs = try Fixture.scratchDirectory("adopt-theirs")
            outside = try Fixture.scratchDirectory("adopt-outside")
        }

        func remove() { for dir in [cwd, ours, theirs, outside] { try? FileManager.default.removeItem(at: dir) } }

        var yourPi: YourPi { YourPi(agentDirectory: theirs) }
        var theirFolder: URL { theirs.appendingPathComponent("sessions/\(PiSessionFolder.name(forCwd: cwd.path))", isDirectory: true) }
        var ourFolder: URL { PiSessionFile.projectDirectory(forCwd: cwd.path, sessionsRoot: ours) }

        func header(version: Int = 3) -> String { #"{"type":"session","version":\#(version),"id":"\#(id)","cwd":"\#(cwd.path)"}"# + "\n" }
        var conversation: String { header() + #"{"type":"message","message":{"role":"user","content":"hello"}}"# + "\n" }

        /// Writes what `side` holds into "your pi", and returns its bytes.
        @discardableResult
        func put(_ side: Side) throws -> Data? {
            let file = theirFolder.appendingPathComponent("2026-01-01T00-00-00-000Z_\(id).jsonl")
            try FileManager.default.createDirectory(at: theirFolder, withIntermediateDirectories: true)
            switch side {
            case .nothing: return nil
            case .header: try Data(header().utf8).write(to: file)
            case .conversation: try Data(conversation.utf8).write(to: file)
            case .newer: try Data((header(version: 4) + "{}\n").utf8).write(to: file)
            case .linked:
                let real = outside.appendingPathComponent("real.jsonl")
                try Data(conversation.utf8).write(to: real)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: real)
            }
            return try Data(contentsOf: file)
        }

        /// Every path under "your pi", with its bytes: what must never change.
        func theirTree() throws -> [String: Data] {
            var tree: [String: Data] = [:]
            for path in try FileManager.default.subpathsOfDirectory(atPath: theirs.path) {
                tree[path] = FileManager.default.contents(atPath: theirs.appendingPathComponent(path).path) ?? Data()
            }
            return tree
        }
    }

    @Test(arguments: Side.allCases)
    func shepherdsHomeWithNothingAdoptsOnlyAConversationItCanRead(_ theirs: Side) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let bytes = try scratch.put(theirs)
        let before = try scratch.theirTree()

        let outcome = PiSessionFile.adopt(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours, yourPi: scratch.yourPi)

        let copied = PiSessionFile.file(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours)
        switch theirs {
        case .conversation, .linked:
            guard case .copied = outcome else { Issue.record("expected a copy, got \(outcome)"); return }
            let copy = try #require(copied)
            #expect(try Data(contentsOf: copy) == Data(scratch.conversation.utf8))
            var info = stat()
            #expect(lstat(copy.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1, "bytes, never a link")
            _ = bytes
        case .newer:
            #expect(outcome == .newerFormat(scratch.theirFolder.appendingPathComponent("2026-01-01T00-00-00-000Z_\(scratch.id).jsonl").path))
            #expect(copied == nil)
        case .nothing, .header:
            #expect(outcome == .nothing && copied == nil)
        }
        #expect(try scratch.theirTree() == before, "your pi is byte-identical")
        #expect(!(try scratch.theirTree().keys.contains { $0.hasSuffix(".lock") }))
    }

    /// A conversation already in Shepherd's home wins, whatever "your pi" holds.
    @Test func aConversationAlreadyHereIsKept() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.put(.conversation)
        try FileManager.default.createDirectory(at: scratch.ourFolder, withIntermediateDirectories: true)
        let ours = scratch.ourFolder.appendingPathComponent("2026-02-02T00-00-00-000Z_\(scratch.id).jsonl")
        let mine = scratch.header() + #"{"type":"message","message":{"role":"user","content":"mine"}}"# + "\n"
        try Data(mine.utf8).write(to: ours)

        #expect(PiSessionFile.adopt(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours, yourPi: scratch.yourPi) == .alreadyHere)
        #expect(try String(contentsOf: ours, encoding: .utf8) == mine)
    }

    /// A header Shepherd seeded before is replaced by the conversation: one file for the id.
    @Test func aSeededHeaderGivesWayToTheConversation() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.put(.conversation)
        PiSessionFile.seedIfMissing(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours)

        guard case .copied = PiSessionFile.adopt(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours, yourPi: scratch.yourPi) else {
            Issue.record("expected a copy"); return
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.ourFolder.path).filter { $0.hasSuffix("_\(scratch.id).jsonl") }
        #expect(names == ["2026-01-01T00-00-00-000Z_\(scratch.id).jsonl"])
        #expect(PiSessionFile.hasRuntimeState(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours))
    }

    /// With no "your pi" there is nothing to read.
    @Test func withoutYourPiNothingIsAdopted() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.put(.conversation)
        #expect(PiSessionFile.adopt(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours, yourPi: nil) == .nothing)
    }

    /// A session file in Shepherd's home that links to the user's (a symlink or a hard link) is
    /// replaced with a copy of its bytes before pi opens it, so pi never appends to theirs.
    @Test(arguments: [false, true])
    func aSessionFileLinkedIntoYourPiBecomesACopy(_ hardLink: Bool) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let theirs = try #require(try scratch.put(.conversation))
        let theirFile = scratch.theirFolder.appendingPathComponent("2026-01-01T00-00-00-000Z_\(scratch.id).jsonl")
        try FileManager.default.createDirectory(at: scratch.ourFolder, withIntermediateDirectories: true)
        let ours = scratch.ourFolder.appendingPathComponent(theirFile.lastPathComponent)
        if hardLink {
            try FileManager.default.linkItem(at: theirFile, to: ours)
        } else {
            try FileManager.default.createSymbolicLink(at: ours, withDestinationURL: theirFile)
        }
        let before = try scratch.theirTree()

        #expect(PiSessionFile.adopt(sessionID: scratch.id, cwd: scratch.cwd.path, sessionsRoot: scratch.ours, yourPi: nil) == .alreadyHere)
        #expect(PiSessionFile.isOwnFile(ours), "a file of Shepherd's own")
        #expect(try Data(contentsOf: ours) == theirs)
        try Data("appended by pi\n".utf8).append(to: ours)
        #expect(try scratch.theirTree() == before, "your pi is byte-identical")
    }

    /// A project folder in Shepherd's home that links into the user's pi gets no adopted copy, no
    /// seeded header and no fork.
    @Test func aProjectFolderLinkedIntoYourPiGetsNothingWritten() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let bytes = try #require(try scratch.put(.conversation))
        try FileManager.default.createDirectory(at: scratch.ours, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: scratch.ourFolder, withDestinationURL: scratch.theirFolder)
        let source = scratch.theirFolder.appendingPathComponent("2026-01-01T00-00-00-000Z_\(scratch.id).jsonl")
        let before = try scratch.theirTree()

        #expect(PiSessionFile.adopt(sessionID: "other-id", cwd: scratch.cwd.path, sessionsRoot: scratch.ours, yourPi: scratch.yourPi) == .nothing)
        #expect(!PiSessionFile.seedIfMissing(sessionID: "other-id", cwd: scratch.cwd.path, sessionsRoot: scratch.ours))
        #expect(throws: PiSessionFile.ForkFailure.self) {
            try PiSessionFile.fork(sessionFile: source.path, cwd: scratch.cwd.path, sessionsRoot: scratch.ours)
        }
        #expect(try scratch.theirTree() == before, "your pi is byte-identical")
        #expect(try Data(contentsOf: source) == bytes)
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
