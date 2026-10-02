import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A tool call the model is still writing, as the thread shows it: a row from `toolcall_start`
/// that `tool_execution_start` continues, and gone when nothing will run it. The events are the
/// shapes pi 1.0.0 sends (Tests/Extensions/tool-call-stream.test.mjs pins them against the
/// real thing): `toolcall_start` names the call, each `toolcall_delta` carries the next few
/// characters of the arguments' JSON text (not the text so far), `toolcall_end` the call.
@Suite("Tool calls being written", .integrationTimeLimit)
struct ToolCallStreamTests {
    typealias Thread = ThreadEventTests.Thread

    // MARK: Events

    static let start = #"{"type":"agent_start"}"#
    static let replyStart = #"{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending","timestamp":1790744354772}}"#
    static let words = "I'll write the file now."

    static func update(_ event: String) -> String {
        #"{"type":"message_update","assistantMessageEvent":\#(event)}"#
    }

    static func quoted(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
    }

    static let textEvents = [
        update(#"{"type":"text_start","contentIndex":0}"#),
        update(#"{"type":"text_delta","contentIndex":0,"delta":\#(quoted(words))}"#),
        update(#"{"type":"text_end","contentIndex":0,"content":\#(quoted(words))}"#),
    ]
    static let callStart = update(#"{"type":"toolcall_start","contentIndex":1,"id":"call_abc","toolName":"write"}"#)

    static func fragment(_ text: String) -> String {
        update(#"{"type":"toolcall_delta","contentIndex":1,"delta":\#(quoted(text))}"#)
    }

    /// What the model wrote of a `write` call, as OpenAI-style providers cut it: an empty fragment
    /// first.
    static let fragments = ["", #"{"pa"#, #"th":"src/big"#, #".txt","con"#, #"tent":"line one\nline "#, #"two\nline three"#, #"\nline four"}"#]
    static let arguments = #"{"path":"src/big.txt","content":"line one\nline two\nline three\nline four"}"#
    static let callEnd = update(#"{"type":"toolcall_end","contentIndex":1,"toolCall":{"type":"toolCall","id":"call_abc","name":"write","arguments":{"path":"src/big.txt","content":"line one\nline two\nline three\nline four"}}}"#)

    static func replyEnd(_ stopReason: String) -> String {
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":\#(quoted(words))},{"type":"toolCall","id":"call_abc","name":"write","arguments":{"path":"src/big.txt","content":"line one\nline two\nline three\nline four"}}],"stopReason":"\#(stopReason)","timestamp":1790744354772}}"#
    }

    static let execute = #"{"type":"tool_execution_start","toolCallId":"call_abc","toolName":"write","args":{"path":"src/big.txt","content":"line one\nline two\nline three\nline four"}}"#
    static let executed = #"{"type":"tool_execution_end","toolCallId":"call_abc","toolName":"write","result":{"content":[{"type":"text","text":"Successfully wrote to src/big.txt"}]},"isError":false}"#

    /// The run up to the model naming the call.
    static let named = [start, replyStart] + textEvents + [callStart]

    private func rows(_ snapshot: NativeThreadSnapshot) -> [NativeThreadMessage] {
        snapshot.provisional.filter { $0.toolCallID == "call_abc" }
    }

    private func feed(_ t: Thread, _ records: [String]) async throws {
        for record in records { try await t.feed(record) }
    }

    // MARK: The row

    @Test func aCallIsARowFromTheMomentTheModelNamesIt() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named)

        let snapshot = try await t.snapshot()
        #expect(snapshot.provisional.map(\.role) == ["assistant", "toolResult"], "the reply, then its call")
        #expect(snapshot.provisional.first?.status == "streaming" && snapshot.running)
        let row = try #require(rows(snapshot).first)
        #expect(row.entryID == "provisional:tool:call_abc" && row.toolName == "write")
        #expect(row.status == "streaming" && row.argumentsText == nil && row.blocks.isEmpty && row.isError == nil)
        #expect(row.startedAt != nil, "its clock runs from the call's first word")
    }

    /// The row carries the path as it comes, and none of the content: a big write's body streams
    /// past without the thread holding, hashing or sending it.
    @Test func theRowFollowsTheFieldsTheLineNamesAndNothingElse() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named)
        var seen: [String?] = []
        for text in Self.fragments {
            try await t.feed(Self.fragment(text))
            seen.append(rows(try await t.snapshot()).first?.argumentsText)
        }
        #expect(seen == [nil, nil, #"{"path":"src/big"}"#, #"{"path":"src/big.txt"}"#, #"{"path":"src/big.txt"}"#,
                         #"{"path":"src/big.txt"}"#, #"{"path":"src/big.txt"}"#])
        try await t.feed(Self.callEnd)
        #expect(rows(try await t.snapshot()).first?.argumentsText == #"{"path":"src/big.txt"}"#)
        #expect(rows(try await t.snapshot()).count == 1)
    }

    @Test func aCallSentWholeIsOneStepAndTheSameRow() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named + [Self.fragment(Self.arguments), Self.callEnd])
        let row = try #require(rows(try await t.snapshot()).first)
        #expect(row.status == "streaming" && row.argumentsText == #"{"path":"src/big.txt"}"#)
    }

    /// `tool_execution_start` makes the same row the running call with its complete arguments,
    /// and its clock goes on; the call then ends as it always did.
    @Test func theRowContinuesIntoTheRunningCallAndThenTheFinishedOne() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named + Self.fragments.map(Self.fragment) + [Self.callEnd])
        let writing = try #require(rows(try await t.snapshot()).first)

        try await feed(t, [Self.replyEnd("toolUse")])
        let handed = try await t.snapshot()
        #expect(rows(handed).first?.status == "streaming", "the reply is over and the call not yet running: still the same row")
        #expect(handed.provisional.map(\.role) == ["assistant", "toolResult"])

        try await feed(t, [Self.execute])
        let running = try await t.snapshot()
        let row = try #require(rows(running).first)
        #expect(rows(running).count == 1 && running.provisional.map(\.role) == ["assistant", "toolResult"])
        #expect(row.entryID == writing.entryID && row.status == "running")
        #expect(row.argumentsText == #"{"content":"line one\nline two\nline three\nline four","path":"src/big.txt"}"#)
        #expect(row.startedAt == writing.startedAt, "one clock from the call's first word through its run")

        try await feed(t, [Self.executed])
        let done = try #require(rows(try await t.snapshot()).first)
        #expect(done.entryID == writing.entryID && done.status == "complete" && done.isError == false)
        #expect(done.blocks.first?.text == "Successfully wrote to src/big.txt")
        #expect(done.startedAt == writing.startedAt, "one clock from the call's first word to its end, as history keeps it")
    }

    // MARK: Leaving

    /// A request pi stopped or that failed runs none of its calls, even though its message still
    /// carries the one it was writing. Every other end hands them to pi.
    @Test(arguments: [("aborted", false), ("error", false), ("toolUse", true), ("length", true), ("stop", true)])
    func onlyAReplyThatEndsWithoutErrorHandsItsCallToPi(stopReason: String, keeps: Bool) async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named + Self.fragments.prefix(3).map(Self.fragment))
        #expect(rows(try await t.snapshot()).first?.status == "streaming")

        try await feed(t, [Self.callEnd, Self.replyEnd(stopReason)])
        let snapshot = try await t.snapshot()
        #expect(rows(snapshot).map(\.status) == (keeps ? ["streaming"] : []))
        #expect(!snapshot.provisional.contains { $0.toolName != nil && !keeps })
    }

    @Test func aCallWithNoEndIsGoneWithTheReplyThatFailed() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named + Self.fragments.prefix(3).map(Self.fragment))
        try await feed(t, [#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"529 overloaded"}}"#])
        let snapshot = try await t.snapshot()
        #expect(!snapshot.provisional.contains { $0.toolName != nil })
        #expect(snapshot.provisional.last?.status == "error")
    }

    @Test(arguments: ["agent_end", "agent_settled"])
    func aCallStillBeingWrittenWhenTheRunEndsLeavesNothingBehind(event: String) async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, Self.named + Self.fragments.prefix(3).map(Self.fragment))
        #expect(rows(try await t.snapshot()).count == 1)

        try await t.feed(#"{"type":"\#(event)"}"#)
        let snapshot = try await t.snapshot()
        #expect(!snapshot.provisional.contains { $0.toolName != nil })
        #expect(!snapshot.provisional.contains { $0.status == "streaming" && $0.role == "toolResult" })
    }

    /// pi moved to another session: nothing of the old one's call stays, and a fragment that
    /// arrives late brings none back.
    @Test func aSessionSwitchLeavesNoCallAndALateFragmentBringsNoneBack() async throws {
        let t = try Thread()
        defer { t.stop() }
        let before = try await t.ready()
        try await feed(t, Self.named + Self.fragments.prefix(3).map(Self.fragment))
        #expect(rows(try await t.snapshot()).count == 1)

        t.queue.async { _ = t.session.send(.prompt(message: "newsession")) }
        try await eventually("the new session") { await t.request(.snapshot()).snapshotValue?.piSessionID == "stub-session-2" }
        try await t.feed(Self.fragment(Self.fragments[3]))
        let switched = try await t.snapshot()
        #expect(switched.generation != before.generation)
        #expect(!switched.provisional.contains { $0.toolName != nil })
    }

    /// A call that never got a name is not a row: it would have no words and no id to continue.
    @Test(arguments: [
        #"{"type":"toolcall_start","contentIndex":1,"id":"call_abc"}"#,
        #"{"type":"toolcall_start","contentIndex":1,"id":"call_abc","toolName":""}"#,
        #"{"type":"toolcall_start","contentIndex":1,"toolName":"write"}"#,
    ])
    func aCallWithoutItsNameOrIdWaitsForItsExecution(event: String) async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await feed(t, [Self.start, Self.replyStart] + Self.textEvents + [Self.update(event)])
        #expect(!(try await t.snapshot()).provisional.contains { $0.toolName != nil })
        try await feed(t, [Self.callEnd, Self.replyEnd("toolUse"), Self.execute])
        #expect(rows(try await t.snapshot()).map(\.status) == ["running"])
    }

    // MARK: Cost

    #if DEBUG
    /// The content of a big write streams past: no fragment of it moves the revision, rehashes
    /// anything, or sizes more than the snapshot's fixed part; one that grows the path moves only
    /// the call's small row.
    @Test func aFragmentOfABigWriteCostsNothingAndAPathFragmentOnlyItsRow() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let output = try String(decoding: JSONEncoder().encode(String(repeating: "line of build output 00\n", count: 16_384 / 24)), as: UTF8.self)
        try await t.feed(Self.start)
        for i in 0..<20 {
            try await t.feed(
                #"{"type":"tool_execution_start","toolCallId":"t\#(i)","toolName":"bash","args":{"command":"make"}}"#,
                #"{"type":"tool_execution_end","toolCallId":"t\#(i)","toolName":"bash","result":{"content":[{"type":"text","text":\#(output)}]},"isError":false}"#)
        }
        try await feed(t, Self.named + [Self.fragment(""), Self.fragment(#"{"path":"src/"#)])
        _ = try await t.snapshot()

        func hashed() async -> Int {
            await withCheckedContinuation { continuation in
                t.queue.async { continuation.resume(returning: t.state.bytesHashedByLastCommit) }
            }
        }
        func encodes() async -> Int {
            await withCheckedContinuation { continuation in
                t.queue.async { continuation.resume(returning: t.state.encodesByLastSnapshot) }
            }
        }
        try await t.feed(Self.fragment("big"))
        let pathHashed = await hashed()
        #expect(pathHashed > 0 && pathHashed <= #"{"path":"src/big"}"#.utf8.count, "only the call's row is rehashed, not the reply or the outputs")
        _ = try await t.snapshot()
        #expect(await encodes() <= 2, "the snapshot's fixed part and that row")

        try await t.feed(Self.fragment(#".txt","content":""#))
        let mid = try await t.snapshot()
        var contentHashed = 0
        for _ in 0..<50 {
            try await t.feed(Self.fragment(String(repeating: "x", count: 200)))
            contentHashed += await hashed()
        }
        let after = try await t.snapshot()
        #expect(after.revision == mid.revision, "the content streaming moves nothing")
        #expect(contentHashed == 0, "\(contentHashed) bytes rehashed by content fragments")
        #expect(await encodes() <= 1, "a snapshot after content fragments sizes only its fixed part")
    }
    #endif
}

/// The stub pi writing a call slowly, through a real server: the row is in the snapshot while
/// the arguments stream, the same row runs the call, and a Stop mid-call leaves no row.
@Suite("A tool call being written, over RPC", .integrationTimeLimit)
struct ToolCallOverRPCTests {
    private func call(_ snapshot: NativeThreadSnapshot) -> NativeThreadMessage? {
        snapshot.provisional.first { $0.toolCallID == "call_write1" }
    }

    @Test func theCallIsOneRowFromItsFirstWordsThroughItsRunIntoHistory() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("toolcall", from: idle)

        let half = try await pi.snapshot("the call with its path half written") { call($0)?.argumentsText == #"{"path":"src/"}"# }
        let writing = try #require(call(half))
        #expect(half.running && writing.status == "streaming" && writing.toolName == "write" && writing.startedAt != nil)
        #expect(half.provisional.map(\.role) == ["user", "assistant", "toolResult"])
        #expect(half.provisional[1].blocks.first?.text == "Writing the file." && half.provisional[1].status == "streaming")

        pi.release(1)
        let path = try await pi.snapshot("the path written") { call($0)?.argumentsText == #"{"path":"src/big.txt"}"# }
        #expect(call(path)?.status == "streaming" && call(path)?.entryID == writing.entryID)
        #expect(call(path)?.startedAt == writing.startedAt)

        pi.release(2)
        let running = try await pi.snapshot("the call running") { call($0)?.status == "running" }
        let row = try #require(call(running))
        #expect(row.entryID == writing.entryID && row.startedAt == writing.startedAt, "the same row, on the same clock")
        #expect(row.argumentsText == #"{"content":"line one\nline two\nline three","path":"src/big.txt"}"#)
        #expect(running.provisional.filter { $0.toolName != nil }.count == 1)

        pi.release(3)
        let done = try await pi.snapshot("the settled history") { !$0.running && $0.provisional.isEmpty && $0.messages.contains { $0.toolCallID == "call_write1" } }
        let result = try #require(done.messages.first { $0.toolCallID == "call_write1" })
        #expect(result.entryID == "t:call_write1" && result.status != "streaming")
        #expect(result.argumentsText == row.argumentsText && result.blocks.first?.text == "Successfully wrote to src/big.txt")
        #expect(result.startedAt == writing.startedAt, "history keeps the start the host observed: when the model named the call")
        #expect(!done.messages.contains { $0.status == "streaming" })
    }

    /// Stop while the model writes the call: pi ends the request `aborted` with the call still in
    /// its message and runs nothing. The thread has no row for it, live or in history.
    @Test func aStopMidCallLeavesNoRowBehind() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let idle = try await pi.ready()
        _ = try await pi.send("toolcall", from: idle)
        let writing = try await pi.snapshot("the call being written") { call($0)?.status == "streaming" }
        #expect(writing.running)

        let stop = try await pi.request(.abort(expectedSessionID: writing.piSessionID, generation: writing.generation, operationID: UUID()))
        #expect(stop.failureCode == nil)
        let stopped = try await pi.snapshot("the stopped thread") { !$0.running && $0.provisional.isEmpty }
        #expect(!stopped.messages.contains { $0.toolName != nil || $0.toolCallID != nil }, "the call never ran, so history has no row for it")
        #expect(!stopped.messages.contains { $0.status == "streaming" })
        #expect(stopped.messages.last?.status == "aborted" && stopped.messages.last?.blocks.first?.text == "Writing the file.")
    }
}
