import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// A restored thread read from pi's session file while its pi starts: the page pi's first
/// snapshot will hold, with the same ids, read from the end of the file.
@Suite("Pi session preview")
struct PiSessionPreviewTests {
    /// Writes a session file: pi's header, then one JSON line per entry.
    private func sessionFile(_ entries: [[String: Any]], extraLines: [String] = []) throws -> (URL, () -> Void) {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("2026-09-24T00-00-00-000Z_s.jsonl")
        var text = #"{"type":"session","version":3,"id":"s","timestamp":"2026-09-24T00:00:00.000Z","cwd":"/w"}"# + "\n"
        for entry in entries {
            text += String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        for line in extraLines { text += line + "\n" }
        try Data(text.utf8).write(to: url)
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    /// A linear conversation: entry `i` is a message whose parent is entry `i - 1`.
    private func chain(_ messages: [[String: Any]], first: String? = nil) -> [[String: Any]] {
        var parent: Any = first ?? NSNull()
        return messages.enumerated().map { index, message in
            defer { parent = "e\(index)" }
            return ["type": "message", "id": "e\(index)", "parentId": parent, "timestamp": "2026-09-24T00:00:00.000Z", "message": message]
        }
    }

    private func user(_ text: String, at ms: Double) -> [String: Any] { ["role": "user", "content": text, "timestamp": ms] }
    private func reply(_ text: String, at ms: Double, call: String? = nil) -> [String: Any] {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        if let call { content.append(["type": "toolCall", "id": call, "name": "bash", "arguments": ["command": "ls"]]) }
        return ["role": "assistant", "content": content, "provider": "anthropic", "model": "claude-x", "stopReason": call == nil ? "stop" : "toolUse", "timestamp": ms]
    }
    private func result(_ call: String, _ text: String, at ms: Double) -> [String: Any] {
        ["role": "toolResult", "toolCallId": call, "toolName": "bash", "content": [["type": "text", "text": text]], "isError": false, "timestamp": ms]
    }

    /// What pi's thread serves for the same messages, page for page.
    private func served(_ messages: [[String: Any]], like preview: NativeThreadSnapshot) throws -> [NativeThreadMessage] {
        let decoded = try JSONDecoder().decode([RPCMessage].self, from: JSONSerialization.data(withJSONObject: messages))
        let history = RPCThreadState.projectHistory(decoded)
        var page = PiSessionPreview.empty(sessionID: "s", model: preview.model, thinking: preview.thinking)
        RPCThreadState.fillPage(&page, from: history, end: history.count)
        return page.messages
    }

    @Test func aPreviewHoldsPisPageWithItsIDsModelAndThinking() throws {
        let messages = [user("fix it", at: 1000), reply("on it", at: 2000, call: "c1"), result("c1", "a\nb", at: 3000), reply("done", at: 4000)]
        let entries = [["type": "thinking_level_change", "id": "t0", "parentId": NSNull(), "timestamp": "2026-09-24T00:00:00.000Z", "thinkingLevel": "high"]]
            + chain(messages, first: "t0")
        let (url, remove) = try sessionFile(entries)
        defer { remove() }

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        #expect(preview.generation == PiSessionPreview.generation && preview.piSessionID == "s" && !preview.running)
        #expect(preview.model == "anthropic/claude-x" && preview.thinking == "high")
        #expect(preview.messages == (try served(messages, like: preview)))
        #expect(preview.messages.map(\.entryID) == ["user:1000", "assistant:2000", "t:c1", "assistant:4000"])
        #expect(preview.messages[2].argumentsText == #"{"command":"ls"}"# && preview.messages[2].startedAt == 2000)
        #expect(preview.olderCursor == nil && preview.supportedActions.contains("send"))
    }

    /// A long session: only its end is read, and the page is pi's newest page, with older
    /// history behind the cursor.
    @Test func aLongSessionPreviewsItsNewestPageFromTheEnd() throws {
        let bulk = String(repeating: "output line\n", count: 2000)
        var messages: [[String: Any]] = []
        for turn in 0..<40 {
            let t = Double(turn) * 100
            messages += [user("turn \(turn)", at: t + 1), reply("running", at: t + 2, call: "c\(turn)"), result("c\(turn)", bulk, at: t + 3)]
        }
        let (url, remove) = try sessionFile(chain(messages))
        defer { remove() }
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int > PiSessionPreview.initialWindow)

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        let expected = try served(messages, like: preview)
        #expect(!expected.isEmpty && preview.messages == expected)
        #expect(preview.olderCursor == expected.first?.entryID)
    }

    /// The newest line is the leaf: an abandoned branch stays out, as it does in pi.
    @Test func onlyTheCurrentBranchIsShown() throws {
        var entries = chain([user("first", at: 1), reply("one", at: 2), user("abandoned", at: 3)])
        entries.append(["type": "message", "id": "b0", "parentId": "e1", "timestamp": "2026-09-24T00:00:00.000Z", "message": user("instead", at: 4)])
        entries.append(["type": "message", "id": "b1", "parentId": "b0", "timestamp": "2026-09-24T00:00:00.000Z", "message": reply("two", at: 5)])
        let (url, remove) = try sessionFile(entries)
        defer { remove() }

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        #expect(preview.messages.map(\.entryID) == ["user:1", "assistant:2", "user:4", "assistant:5"])
    }

    /// A conversation whose thinking level was set to `levels` in turn, each change followed by
    /// a run of turns (`filler` characters of tool output each), then a full page of short turns,
    /// so no change sits on the page: the level pi resumes with is the newest change.
    private func sessionChangingThinking(_ levels: [String], turnsBetween: Int, filler: Int) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        var parent: Any = NSNull()
        var ms = 0.0
        func add(_ entry: [String: Any]) {
            var entry = entry
            let id = "x\(entries.count)"
            entry["id"] = id
            entry["parentId"] = parent
            entry["timestamp"] = "2026-09-24T00:00:00.000Z"
            entries.append(entry)
            parent = id
        }
        func turns(_ count: Int, filler: Int) {
            for _ in 0..<count {
                ms += 10
                add(["type": "message", "message": user("go", at: ms)])
                add(["type": "message", "message": reply("reading", at: ms + 1, call: "c\(ms)")])
                // Output that quotes a level change is not one.
                let quoted = #"{"type":"thinking_level_change","id":"q","thinkingLevel":"off"}"#
                add(["type": "message", "message": result("c\(ms)", quoted + String(repeating: "x", count: filler), at: ms + 2)])
            }
        }
        for level in levels {
            add(["type": "thinking_level_change", "thinkingLevel": level])
            turns(turnsBetween, filler: filler)
        }
        turns(RPCThreadState.pageSize, filler: 0)
        return entries
    }

    /// pi resumes with the newest thinking level on the path, even when it was set long before
    /// the page, far back in a long file, with output quoting a change after it.
    @Test(arguments: [(3, 0), (40, 30_000)])
    func aThinkingLevelSetBeforeThePageIsTheOnePiResumesWith(turnsBetween: Int, filler: Int) throws {
        let (url, remove) = try sessionFile(sessionChangingThinking(["high", "max"], turnsBetween: turnsBetween, filler: filler))
        defer { remove() }

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        #expect(preview.thinking == "max")
        #expect(preview.messages.count == RPCThreadState.pageSize)
    }

    /// After a compaction pi's context is its summary, the entries it kept, and what followed.
    @Test func aCompactionKeepsWhatPiKeeps() throws {
        var entries = chain((0..<6).map { user("m\($0)", at: Double($0 + 1)) })
        entries.append(["type": "compaction", "id": "c", "parentId": "e5", "timestamp": "2026-09-24T00:00:01.500Z",
                        "summary": "earlier work", "firstKeptEntryId": "e4", "tokensBefore": 10])
        entries.append(["type": "message", "id": "after", "parentId": "c", "timestamp": "2026-09-24T00:00:02.000Z", "message": user("after", at: 9)])
        let (url, remove) = try sessionFile(entries)
        defer { remove() }

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        #expect(preview.messages.map(\.entryID) == ["compactionSummary:1790208001500", "user:5", "user:6", "user:9"])
        #expect(preview.olderCursor == nil)
    }

    /// Custom messages follow the thread's rules, a context edit replaces its target's content,
    /// and lines that are not JSON are skipped.
    @Test func customMessagesEditsAndBrokenLinesFollowPisProjection() throws {
        var entries = chain([user("hello", at: 1), reply("draft", at: 2)])
        entries.append(["type": "custom_message", "id": "note", "parentId": "e1", "timestamp": "2026-09-24T00:00:00.100Z",
                        "customType": "note", "content": "shown", "display": true])
        entries.append(["type": "custom_message", "id": "hidden", "parentId": "note", "timestamp": "2026-09-24T00:00:00.200Z",
                        "customType": "memo", "content": "model only", "display": false])
        entries.append(["type": "context_edit", "id": "edit", "parentId": "hidden", "timestamp": "2026-09-24T00:00:00.300Z",
                        "targetId": "e1", "replacement": ["content": "edited"]])
        let (url, remove) = try sessionFile(entries, extraLines: ["{not json", #"{"type":"message","id":"torn"#])
        defer { remove() }

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        #expect(preview.messages.map(\.entryID) == ["user:1", "assistant:2", "custom:1790208000100"])
        #expect(preview.messages[1].blocks.map(\.text) == ["edited"])
        #expect(preview.messages[2].blocks.map(\.text) == ["shown"])
    }

    /// A session nobody has spoken in yet is a known-empty thread; anything that is not pi's is
    /// no preview at all.
    @Test func aSeededSessionIsEmptyAndAnythingElseIsNoPreview() throws {
        let (seeded, remove) = try sessionFile([])
        defer { remove() }
        let empty = try #require(PiSessionPreview.snapshot(file: seeded, sessionID: "s"))
        #expect(empty.messages.isEmpty && empty.olderCursor == nil)

        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appendingPathComponent("other.jsonl")
        try Data(#"{"type":"message","id":"x"}"#.utf8).write(to: other)
        #expect(PiSessionPreview.snapshot(file: other, sessionID: "s") == nil)
        #expect(PiSessionPreview.snapshot(file: dir.appendingPathComponent("missing.jsonl"), sessionID: "s") == nil)
    }

    /// A file in an older format (entries without ids, "hookMessage" roles) is no preview:
    /// pi rewrites it when it loads it, and the thread waits for pi until then.
    @Test(arguments: [
        #"{"type":"session","id":"s","timestamp":"2026-09-24T00:00:00.000Z","cwd":"/w"}"#,
        #"{"type":"session","version":2,"id":"s","timestamp":"2026-09-24T00:00:00.000Z","cwd":"/w"}"#,
    ])
    func aSessionInAnOlderFormatIsNoPreview(header: String) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("old.jsonl")
        let message = #"{"type":"message","timestamp":"2026-09-24T00:00:00.000Z","message":{"role":"user","content":"hi","timestamp":1}}"#
        try Data((header + "\n" + message + "\n").utf8).write(to: url)

        #expect(PiSessionPreview.snapshot(file: url, sessionID: "s") == nil)
    }

    /// One tool result bigger than the first window: the reader looks further back.
    @Test func aPageThatReachesPastTheWindowIsReadFurtherBack() throws {
        let huge = String(repeating: "x", count: PiSessionPreview.initialWindow * 3 / 2)
        let messages = [user("go", at: 1), reply("reading", at: 2, call: "c"), result("c", huge, at: 3)]
        let (url, remove) = try sessionFile(chain(messages))
        defer { remove() }

        let preview = try #require(PiSessionPreview.snapshot(file: url, sessionID: "s"))

        #expect(preview.messages.map(\.entryID) == (try served(messages, like: preview)).map(\.entryID))
        #expect(preview.messages.contains { $0.entryID == "user:1" })
    }
}
