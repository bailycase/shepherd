import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// A child's transcript is paged straight from its pi session JSONL with the same projection
/// rules as the parent thread.
@Suite("Subagent transcript")
struct SubagentTranscriptTests {
    /// A session file: a header, `pairs` user/assistant exchanges, then the extra lines.
    private func sessionFile(pairs: Int, extra: [String] = []) throws -> (dir: URL, file: String) {
        let dir = try makeTempDirectory()
        var lines = [#"{"type":"session","id":"child","version":3,"cwd":"/tmp"}"#]
        for i in 0..<pairs {
            lines.append(#"{"type":"message","id":"u\#(i)","message":{"role":"user","content":"step \#(i)"}}"#)
            lines.append(#"{"type":"message","id":"a\#(i)","message":{"role":"assistant","content":[{"type":"text","text":"reply \#(i)"}],"stopReason":"stop"}}"#)
        }
        lines += extra
        let url = dir.appendingPathComponent("child.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return (dir, url.path)
    }

    private func page(_ file: String, before: String? = nil) throws -> NativeSubagentTranscript {
        let result = RPCThreadState.transcript(runID: "native-1", file: file, beforeEntryID: before)
        guard case .transcript(let value) = result else {
            throw TranscriptError(result: result)
        }
        return value
    }

    private struct TranscriptError: Error { let result: NativeThreadResult }

    @Test func theNewestPageComesFirstWithACursorToOlderEntries() throws {
        let (dir, file) = try sessionFile(pairs: 60)
        defer { try? FileManager.default.removeItem(at: dir) }
        let newest = try page(file)
        #expect(newest.runID == "native-1")
        #expect(newest.messages.count == RPCThreadState.pageSize)
        #expect(newest.earlierCount == 70)
        #expect(newest.messages.last?.entryID == "c:a59")
        #expect(newest.olderCursor == newest.messages.first?.entryID)
    }

    @Test func pagingWalksBackToTheFirstEntryWithoutOverlap() throws {
        let (dir, file) = try sessionFile(pairs: 60)
        defer { try? FileManager.default.removeItem(at: dir) }
        let newest = try page(file)
        let older = try page(file, before: newest.olderCursor)
        #expect(older.messages.count == 50)
        #expect(older.earlierCount == 20)
        #expect(older.messages.last?.entryID != newest.messages.first?.entryID)
        let oldest = try page(file, before: older.olderCursor)
        #expect(oldest.messages.count == 20)
        #expect(oldest.messages.first?.entryID == "c:u0")
        #expect(oldest.olderCursor == nil)
        #expect(oldest.earlierCount == 0)
    }

    @Test func aCursorNotInTheFileIsStale() throws {
        let (dir, file) = try sessionFile(pairs: 2)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(RPCThreadState.transcript(runID: "r", file: file, beforeEntryID: "c:gone")
            == .failure(code: "stale_cursor", message: "History changed. Refresh the recent page."))
    }

    @Test func modelOnlyCustomsAndNonMessageLinesAreSkipped() throws {
        let (dir, file) = try sessionFile(pairs: 1, extra: [
            #"{"type":"message","id":"c1","message":{"role":"custom","customType":"x","display":false,"content":[{"type":"text","text":"hidden"}]}}"#,
            #"{"type":"message","id":"c2","message":{"role":"custom","customType":"note","display":true,"content":[{"type":"text","text":"shown"}]}}"#,
            #"{"type":"model_change","id":"m","provider":"p","modelId":"m"}"#,
            #"not json at all"#,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let value = try page(file)
        #expect(value.messages.map(\.entryID) == ["c:u0", "c:a0", "c:c2"])
        #expect(value.messages.last?.blocks.first?.text == "shown")
    }

    @Test func toolResultsBorrowTheirCallsArgumentsAndStartTime() throws {
        let (dir, file) = try sessionFile(pairs: 0, extra: [
            #"{"type":"message","id":"t0","message":{"role":"assistant","timestamp":1700000000000,"content":[{"type":"toolCall","id":"call_e","name":"edit","arguments":{"path":"A.swift"}}],"stopReason":"toolUse"}}"#,
            #"{"type":"message","id":"t1","message":{"role":"toolResult","toolCallId":"call_e","toolName":"edit","content":[{"type":"text","text":"ok"}],"isError":false}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try #require(try page(file).messages.last)
        #expect(result.entryID == "c:t1")
        #expect(result.toolName == "edit")
        #expect(result.argumentsText == #"{"path":"A.swift"}"#)
        #expect(result.startedAt == 1700000000000)
    }

    @Test func anUnreadableFileIsReportedNotThrown() {
        #expect(RPCThreadState.transcript(runID: "r", file: "/nonexistent/child.jsonl", beforeEntryID: nil)
            == .failure(code: "transcript_unavailable", message: "The subagent's session file is not readable."))
    }
}
