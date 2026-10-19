import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The artifacts of a thread, on the host (docs/native-thread.md › Artifacts): the files a successful `write` call made are served in pieces,
/// and nothing else is. A client names a path only as a key; the host re-derives what was written from pi's own history for this agent.
@Suite("Thread artifacts, host", .serialized, .integrationTimeLimit)
struct ThreadArtifactsTests {
    /// History in which pi wrote `ok` successfully, failed to write `failed`, and wrote `missing` (which is not on disk now).
    private static func history(ok: [String], failed: [String] = [], missing: [String] = []) -> [[String: Any]] {
        var record: [[String: Any]] = [["role": "user", "content": "write it up", "timestamp": 1_733_234_567_890]]
        var n = 0
        for (path, isError) in ok.map({ ($0, false) }) + missing.map({ ($0, false) }) + failed.map({ ($0, true) }) {
            n += 1
            record.append(["role": "assistant", "content": [["type": "toolCall", "id": "w\(n)", "name": "write", "arguments": ["path": path, "content": "x"]]],
                           "stopReason": "toolUse", "timestamp": 1_733_234_567_900 + n * 10])
            record.append(["role": "toolResult", "toolCallId": "w\(n)", "toolName": "write", "isError": isError, "timestamp": 1_733_234_567_905 + n * 10,
                           "content": [["type": "text", "text": isError ? "EACCES" : "Successfully wrote"]]])
        }
        return record
    }

    private struct Fixture {
        let h: ScratchServer
        let folder: URL
        let pi: PiAgent

        /// A folder for the agent, with the files the tests name, and a pi whose history says the agent wrote `written`.
        static func make(written: [String], failed: [String] = [], missing: [String] = [], files: (URL) throws -> Void) async throws -> (Fixture, NativeThreadSnapshot) {
            let h = try ScratchServer.fresh()
            let folder = h.dir.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try files(folder)
            let history = h.dir.appendingPathComponent("history.json")
            try JSONSerialization.data(withJSONObject: ThreadArtifactsTests.history(ok: written, failed: failed, missing: missing)).write(to: history)
            let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": history.path], cwd: folder)
            let snapshot = try await pi.snapshot("the saved history") { $0.messages.contains { $0.role == "toolResult" } }
            return (Fixture(h: h, folder: folder, pi: pi), snapshot)
        }

        func ask(_ path: String, _ session: String, offset: Int = 0) async throws -> NativeThreadResult {
            try await pi.request(.artifact(expectedSessionID: session, path: path, offset: offset))
        }

        /// The whole file as a client asks for it, a piece at a time.
        func fetch(_ path: String, _ session: String) async throws -> (data: Data, pieces: Int) {
            var data = Data()
            var total: Int?
            var pieces = 0
            while total == nil || data.count < total! {
                guard case .artifactChunk(let chunk) = try await ask(path, session, offset: data.count) else { throw WireError("no piece at \(data.count)") }
                #expect(chunk.path == path && chunk.offset == data.count && chunk.data.count <= NativeImage.chunkBytes)
                total = chunk.totalBytes
                data.append(chunk.data)
                pieces += 1
            }
            return (data, pieces)
        }
    }

    @Test func aFileTheThreadWroteIsServedInPiecesAndTheSnapshotAdvertisesIt() async throws {
        let big = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let (f, s) = try await Fixture.make(written: ["report.html", "docs/plan.md", "empty.md"]) { dir in
            try Data("<h1>hi</h1>".utf8).write(to: dir.appendingPathComponent("report.html"))
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try big.write(to: dir.appendingPathComponent("docs/plan.md"))
            try Data().write(to: dir.appendingPathComponent("empty.md"))
        }
        defer { f.h.stop() }
        #expect(s.supportedActions.contains("artifacts"))
        #expect(try await f.fetch("report.html", s.piSessionID).data == Data("<h1>hi</h1>".utf8), "a path relative to the agent's folder")
        let plan = try await f.fetch("docs/plan.md", s.piSessionID)
        #expect(plan.data == big && plan.pieces == 3, "256 KiB at a time")
        let empty = try await f.fetch("empty.md", s.piSessionID)
        #expect(empty.data.isEmpty && empty.pieces == 1, "an empty file is one empty piece")
    }

    @Test func anAbsolutePathTheThreadWroteIsServedToo() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-\(UUID().uuidString.prefix(8)).md")
        try Data("# elsewhere".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let (f, s) = try await Fixture.make(written: [outside.path]) { _ in }
        defer { f.h.stop() }
        #expect(try await f.fetch(outside.path, s.piSessionID).data == Data("# elsewhere".utf8))
    }

    /// The point of the whole design: a client that names a file the thread did not write gets nothing, however the name is spelled.
    @Test func onlyAPathAWriteCallMadeIsServed() async throws {
        let (f, s) = try await Fixture.make(written: ["report.md"], failed: ["failed.md"]) { dir in
            try Data("secret-free".utf8).write(to: dir.appendingPathComponent("report.md"))
            try Data("never written".utf8).write(to: dir.appendingPathComponent("failed.md"))
            try Data("another file".utf8).write(to: dir.appendingPathComponent("other.md"))
        }
        defer { f.h.stop() }
        _ = try await f.fetch("report.md", s.piSessionID)
        let refused = [
            "other.md",               // exists, never written
            "failed.md",              // a write that failed made nothing
            "./report.md",            // not the path the call gave
            "docs/../report.md",
            "report.md/",
            "REPORT.md",
            "/etc/passwd", "../../../etc/passwd", "~/.ssh/id_rsa", "",
        ]
        for path in refused {
            #expect(try await f.ask(path, s.piSessionID).failureCode == NativeArtifactCode.unknown, "\(path)")
        }
        // A stale session, and offsets that are no place in the file.
        #expect(try await f.ask("report.md", "another-session").failureCode == "stale_session")
        #expect(try await f.ask("report.md", s.piSessionID, offset: -1).failureCode == NativeArtifactCode.unknown)
        #expect(try await f.ask("report.md", s.piSessionID, offset: 1_000).failureCode == NativeArtifactCode.unknown)
    }

    @Test func aWrittenPathThatIsNoLongerAServableFileIsUnavailable() async throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString.prefix(8)).txt")
        try Data("not the agent's".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let oversized = Data(count: NativeArtifactChunk.maxBytes + 1)
        let exactly = Data(count: NativeArtifactChunk.maxBytes)
        let (f, s) = try await Fixture.make(written: ["link.md", "dir", "big.md", "limit.md", "gone.md", "linkdir/inside.md"]) { dir in
            // The agent wrote link.md; someone then made it a link to a file outside.
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.md"), withDestinationURL: outside)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("dir"), withIntermediateDirectories: true)
            try oversized.write(to: dir.appendingPathComponent("big.md"))
            try exactly.write(to: dir.appendingPathComponent("limit.md"))
        }
        defer { f.h.stop() }
        for path in ["link.md", "dir", "big.md", "gone.md", "linkdir/inside.md"] {
            #expect(try await f.ask(path, s.piSessionID).failureCode == NativeArtifactCode.unavailable, "\(path)")
        }
        let limit = try await f.ask("limit.md", s.piSessionID)
        guard case .artifactChunk(let chunk) = limit else { throw WireError("the largest servable file was refused: \(limit)") }
        #expect(chunk.totalBytes == NativeArtifactChunk.maxBytes)
    }

    @Test func aPathTheThreadWroteThroughASymlinkedFolderStaysServable() async throws {
        // Only the file's own last component is refused as a link: a folder the user links (a worktree, /tmp) is theirs to arrange.
        let (f, s) = try await Fixture.make(written: ["linked/a.md"]) { dir in
            let real = dir.deletingLastPathComponent().appendingPathComponent("real-\(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try Data("hi".utf8).write(to: real.appendingPathComponent("a.md"))
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("linked"), withDestinationURL: real)
        }
        defer { f.h.stop() }
        #expect(try await f.fetch("linked/a.md", s.piSessionID).data == Data("hi".utf8))
    }

    // MARK: Derivation, without a server

    @Test func writtenPathsAreTheSuccessfulWritesOnly() {
        let messages: [RPCMessage] = [
            RPCMessage(role: "assistant", content: [.toolCall(id: "a", name: "write", arguments: .object(["path": .string("ok.md")])),
                                                    .toolCall(id: "b", name: "write", arguments: .object(["path": .string("failed.md")])),
                                                    .toolCall(id: "c", name: "edit", arguments: .object(["path": .string("edited.md")])),
                                                    .toolCall(id: "d", name: "write", arguments: .object(["content": .string("no path")])),
                                                    .toolCall(id: "e", name: "write", arguments: .object(["path": .string("unanswered.md")]))]),
            RPCMessage(role: "toolResult", content: [], toolName: "write", toolCallId: "a", isError: false),
            RPCMessage(role: "toolResult", content: [], toolName: "write", toolCallId: "b", isError: true),
            RPCMessage(role: "toolResult", content: [], toolName: "edit", toolCallId: "c", isError: false),
            RPCMessage(role: "toolResult", content: [], toolName: "write", toolCallId: "d", isError: false),
            // A result whose id no assistant call names, and a user message that merely says it.
            RPCMessage(role: "toolResult", content: [], toolName: "write", toolCallId: "zzz", isError: false),
            RPCMessage(role: "user", content: [.text(#"{"name":"write","path":"/etc/passwd"}"#)]),
        ]
        #expect(ThreadArtifacts.writtenPaths(in: messages) == ["ok.md"])
    }

    @Test(arguments: [("a.md", "/work", "/work/a.md"), ("./a.md", "/work", "/work/a.md"), ("sub/../a.md", "/work", "/work/a.md"),
                      ("/abs/a.md", "/work", "/abs/a.md"), ("../a.md", "/work/x", "/work/a.md")])
    func pathsResolveAgainstTheAgentsFolder(path: String, cwd: String, resolved: String) {
        #expect(ThreadArtifacts.resolved(path, cwd: cwd) == resolved)
    }

    // MARK: The projection keeps the path of a big write

    @Test func aBigWritesRowKeepsItsPathAndItsLineCount() throws {
        let content = (0..<5_000).map { "line \($0) of a long report" }.joined(separator: "\n")
        let message = RPCMessage(role: "toolResult", content: [.text("Successfully wrote")], toolName: "write", toolCallId: "w")
        let args: JSONValue = .object(["path": .string("reports/big.html"), "content": .string(content)])
        let row = RPCThreadState.project(entryID: "t:w", message: message, args: args)
        let text = try #require(row.argumentsText)
        #expect(text.utf8.count < RPCThreadState.textLimit, "the row stays within its limit")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["path"] as? String == "reports/big.html", "the path survives a content longer than the row")
        #expect(object["contentLines"] as? Int == 5_000)
    }

    @Test func aSmallCallIsLeftAlone() {
        let args: JSONValue = .object(["path": .string("a.md"), "content": .string("short")])
        #expect(RPCThreadState.fitting(args, within: RPCThreadState.textLimit) == args)
    }
}
