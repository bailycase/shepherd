import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Nested codemode history", .integrationTimeLimit)
struct CodemodeHistoryTests {
    @Test func reopeningAThreadRestoresNestedArgumentsOutputAndFailures() async throws {
        let dir = try makeScratchDirectory("nested-history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("messages.json")
        let messages = [RPCMessage(role: "user", content: [.text("Read two files")], timestamp: 900), try CodemodeFixture.message()]
        try JSONEncoder().encode(messages).write(to: file)
        for _ in 0..<2 {
            let t = try ThreadEventTests.Thread(env: ["STUB_PI_MESSAGES_FILE": file.path])
            defer { t.stop() }
            var snapshot: NativeThreadSnapshot?
            try await eventually("nested history to load") {
                snapshot = await t.request(.snapshot()).snapshotValue
                return snapshot?.messages.count == 4
            }
            let rows = try #require(snapshot?.messages)
            #expect(rows.map(\.toolCallID) == [nil, "script", "script/1", "script/2"])
            #expect(rows[1].isError == false && rows[3].isError == true)
            #expect(rows[2].argumentsText == #"{"path":"example.txt"}"#)
            #expect(rows[2].blocks.map(\.text) == ["first\nsecond\n"])
            #expect(rows[2].startedAt == 1000 && rows[2].timestamp == 1002)
        }
    }

    @Test func childTranscriptPagingDoesNotLoseCallsWithinOneScript() throws {
        let dir = try makeScratchDirectory("nested-transcript")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let original = try CodemodeFixture.message()
        var calls: [RPCNestedCall] = []
        for index in 0..<150 {
            var call = try #require(original.nestedCalls?.calls.first)
            call.id = "script/\(index)"
            calls.append(call)
        }
        var message = original
        message.nestedCalls?.calls = calls
        let encoded = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        try Data("{\"type\":\"message\",\"id\":\"entry\",\"message\":\(encoded)}\n".utf8).write(to: file)
        var cursor: String?, collected: [NativeThreadMessage] = []
        repeat {
            guard case .transcript(let page) = RPCThreadState.transcript(runID: "run", file: file.path, beforeEntryID: cursor) else {
                Issue.record("Expected transcript page"); return
            }
            #expect(page.messages.count <= RPCThreadState.pageSize)
            collected.insert(contentsOf: page.messages, at: 0)
            cursor = page.olderCursor
        } while cursor != nil
        #expect(collected.count == 151 && Set(collected.map(\.entryID)).count == 151)
        #expect(collected.compactMap(\.toolCallID) == ["script"] + calls.map(\.id))
    }
}
