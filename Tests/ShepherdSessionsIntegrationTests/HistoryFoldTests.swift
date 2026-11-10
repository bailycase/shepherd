import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// What pi saved folds into the thread's history from its own events, in O(the turn); the whole history is read only where
/// events cannot say what pi saved. Counts come from what the stub received (`get_messages`), the thread's counters and the
/// decoder hook, so a regression shows as work done, not as time taken.
@Suite("History folds", .integrationTimeLimit)
struct HistoryFoldTests {
    typealias Reason = RPCThreadState.HistoryRefetchReason

    private struct Work: Equatable {
        var projections = 0, folds = 0, folded = 0, readMessages = 0
        var reason: Reason?
    }

    private func launch(env: [String: String] = [:]) async throws -> (ScratchServer, PiAgent, NativeThreadSnapshot) {
        let h = try ScratchServer.fresh()
        do {
            let pi = try await PiAgent.launch(on: h, env: env)
            return (h, pi, try await pi.ready())
        } catch { h.stop(); throw error }
    }

    private func work(_ pi: PiAgent) async throws -> Work {
        try await pi.thread { Work(projections: $0.historyProjectionCount, folds: $0.historyFoldCount, folded: $0.historyFoldedMessageCount,
                                   readMessages: $0.historyReadMessageCount, reason: $0.lastRefetchReason) }
    }

    /// The `get_messages` requests the stub has received.
    private func readCount(_ pi: PiAgent) -> Int { pi.stdin("get_messages").count }

    /// Sends `text` and waits for the run to settle with pi's reply `reply` last in history.
    @discardableResult
    private func turn(_ pi: PiAgent, _ text: String, reply: String? = nil, from s: NativeThreadSnapshot,
                      tools: ClosedRange<Int>? = nil) async throws -> NativeThreadSnapshot {
        if let tools { for k in tools { pi.finishTool(k) } }
        let result = try await pi.send(text, from: s)
        #expect(result.failureCode == nil, "\(result)")
        let expected = "Reply to \(reply ?? text)"
        let settled = try await pi.snapshot("\(text) to settle") { !$0.running && $0.messages.last?.blocks.first?.text == expected }
        try await pi.historySettled()
        return settled
    }

    /// The rows with the timing of replies pi stamped in one millisecond left out. The host keys a reply's timing and thinking time by
    /// pi's timestamp, so a read gives the first of two such replies the second's, where a fold gave each its own. The stub's
    /// replies come a few microseconds apart; pi's, behind a model call, never do.
    private func comparable(_ rows: [NativeThreadMessage]) -> [NativeThreadMessage] {
        var keys: [String: Int] = [:]
        for row in rows where row.role == "assistant" { keys[String(row.entryID.split(separator: "#")[0]), default: 0] += 1 }
        return rows.map { row in
            guard row.role == "assistant", keys[String(row.entryID.split(separator: "#")[0])] ?? 0 > 1 else { return row }
            var row = row
            row.timing = nil
            row.thinkingSeconds = nil
            return row
        }
    }

    /// Reads the whole history now and says whether the thread held exactly that already: its rows and its context estimate.
    private func holdsWhatAWholeReadGives(_ pi: PiAgent, _ what: String = "") async throws -> Bool {
        try await pi.historySettled()
        let before = try await pi.thread { ($0.history, $0.estimate) }
        let landed = Locked(false)
        try await pi.thread { $0.refreshMessages { _ in landed.withValue { $0 = true } } }
        try await eventually("a whole read to land") { landed.current }
        try await pi.historySettled()
        let after = try await pi.thread { ($0.history, $0.estimate) }
        let (folded, read) = (comparable(before.0), comparable(after.0))
        if folded != read {
            let first = zip(folded, read).enumerated().first { $0.element.0 != $0.element.1 }
            var fields: [String] = []
            if let (_, rows) = first.map({ ($0.offset, $0.element) }) {
                for (one, other) in zip(Mirror(reflecting: rows.0).children, Mirror(reflecting: rows.1).children)
                where "\(one.value)" != "\(other.value)" { fields.append("\(one.label ?? "?"): \(one.value) / \(other.value)") }
            }
            Issue.record("\(what) the folded rows differ from a whole read: \(folded.count) vs \(read.count) rows; first difference at \(first.map { "\($0.offset): \($0.element.0.entryID)" } ?? "the end"): \(fields.joined(separator: "; "))")
        }
        if before.1 != after.1 { Issue.record("\(what) the folded context estimate differs from a whole read") }
        return folded == read && before.1 == after.1
    }

    // MARK: - Turns that fold

    @Test func ordinaryTurnsFoldWithoutReadingTheHistory() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi), start = try await work(pi)
        for number in 1...5 {
            try await turn(pi, "tools:2 turn \(number)", from: ready, tools: (2 * number - 1)...(2 * number))
            let now = try await work(pi)
            #expect(readCount(pi) == reads, "turn \(number) read the history")
            #expect(now.projections == start.projections, "turn \(number) projected a whole history")
            #expect(now.folded == start.folded + 6 * number, "user, three replies, two results: \(now.folded - start.folded) after \(number)")
        }
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    @Test func aTurnEndOnALongHistoryDecodesNoLargeRecord() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let decoded = Locked(0)
        h.server.beforeOffQueueDecode = { decoded.withValue { $0 += 1 } }
        let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_HISTORY_BYTES": String(4 * 1024 * 1024)])
        let ready = try await pi.ready()
        let start = decoded.current
        #expect(start >= 1, "the seeded history is a large record: it is read once, at bootstrap")
        for number in 1...3 { try await turn(pi, "tools:0 turn \(number)", from: ready) }
        #expect(decoded.current == start, "a turn end read the history again")
    }

    @Test func aLongRunFoldsItsEndedRowsWhileItRuns() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi), start = try await work(pi)
        for k in 1...55 { pi.finishTool(k) }
        #expect(try await pi.send("tools:60 a long run", from: ready).failureCode == nil)
        let running = try await pi.snapshot("the run to reach its 56th call") { $0.running && $0.provisional.contains { $0.toolCallID == "call_q56" && $0.status == "running" } }
        let now = try await work(pi)
        #expect(now.folds > start.folds, "ended rows folded into history while the run goes on")
        #expect(running.clips?.live == nil, "nothing of the run is left out of the snapshot")
        #expect(running.provisional.count < RPCThreadState.pageSize, "the live run holds what has not ended: \(running.provisional.count) rows")
        #expect(readCount(pi) == reads)
        for k in 56...60 { pi.finishTool(k) }
        _ = try await pi.snapshot("the run to end") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to tools:60 a long run" }
        #expect(readCount(pi) == reads)
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    /// A steer into a running turn, a queued follow-up, a question answered, Stop, a picture, a compaction, a turn after it:
    /// at each point the folded history is what a whole read gives, and only the compaction read anything.
    @Test func foldsAfterMixedTurnsMatchAWholeRead() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        var reads = readCount(pi)
        func nothingRead(_ what: String) async throws {
            #expect(readCount(pi) == reads, "\(what) read the history")
            #expect(try await holdsWhatAWholeReadGives(pi, what))
            reads = readCount(pi)
        }

        // A steer into a running turn.
        #expect(try await pi.send("tools:1 first", from: ready).failureCode == nil)
        let running = try await pi.snapshot("the first call to run") { $0.running && $0.provisional.contains { $0.status == "running" } }
        #expect(try await pi.send("steered words", delivery: .steer, from: running).failureCode == nil)
        pi.finishTool(1)
        _ = try await pi.snapshot("the steer answered") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to steered words" }
        try await pi.historySettled()
        try await nothingRead("a steer")

        // A follow-up queued behind a running turn.
        #expect(try await pi.send("tools:1 second", from: ready).failureCode == nil)
        let second = try await pi.snapshot("the second call to run") { $0.running && $0.provisional.contains { $0.status == "running" } }
        #expect(try await pi.send("tools:0 queued behind", delivery: .followUp, from: second).failureCode == nil)
        pi.finishTool(2)
        _ = try await pi.snapshot("the queue to drain") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to tools:0 queued behind" }
        try await pi.historySettled()
        try await nothingRead("a queued follow-up")

        // A question, answered.
        #expect(try await pi.send("question", from: ready).failureCode == nil)
        let asking = try await pi.snapshot("the question") { !$0.dialogs.isEmpty }
        let dialog = try #require(asking.dialogs.first)
        #expect(try await pi.request(.answer(expectedSessionID: asking.piSessionID, generation: asking.generation, operationID: UUID(),
                                             dialogID: dialog.id, answer: .select(value: try #require(dialog.options?.first)))).failureCode == nil)
        _ = try await pi.snapshot("the question recorded") { !$0.running && $0.messages.contains { $0.question != nil } }
        try await pi.historySettled()
        try await nothingRead("a question")

        // Stop in the middle of a turn.
        #expect(try await pi.send("tools:2 stopped", from: ready).failureCode == nil)
        let stopping = try await pi.snapshot("a call to run") { $0.running && $0.provisional.contains { $0.status == "running" } }
        let op = UUID()
        #expect(try await pi.request(.abort(expectedSessionID: stopping.piSessionID, generation: stopping.generation, operationID: op)) == .accepted(operationID: op))
        _ = try await pi.snapshot("the run to stop") { !$0.running }
        try await pi.historySettled()
        try await nothingRead("Stop")

        // A picture.
        let png = ThreadImagesTests.nativeImage(ThreadImagesTests.png(side: 16))
        #expect(try await pi.send("tools:0 with a picture", images: [png], from: ready).failureCode == nil)
        let pictured = try await pi.snapshot("the picture turn") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to tools:0 with a picture" }
        #expect(pictured.messages.contains { $0.blocks.contains { $0.imageID != nil } })
        try await pi.historySettled()
        try await nothingRead("a picture")

        // A compaction: the one thing that reads.
        let compacting = UUID()
        #expect(try await pi.request(.compact(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: compacting)) == .accepted(operationID: compacting))
        _ = try await pi.snapshot("the summary") { snapshot in snapshot.messages.contains { $0.role == "compactionSummary" } }
        try await pi.historySettled()
        #expect(readCount(pi) > reads, "a compaction reads the history")
        reads = readCount(pi)
        #expect(try await holdsWhatAWholeReadGives(pi, "the compaction"))
        reads = readCount(pi)

        // And a turn after it folds onto what the read gave.
        pi.finishTool(4)
        try await turn(pi, "tools:1 after", from: ready)
        try await nothingRead("a turn after the compaction")
    }

    /// Nested calls of a script never get a `message_end` of their own: they leave the live run with the script's result.
    @Test func aScriptsNestedCallsLeaveTheLiveTurnWithIt() async throws {
        let t = try ThreadEventTests.Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let result = CodemodeFixture.json.replacingOccurrences(of: "script", with: "call_1")
        let call = #"{"role":"assistant","content":[{"type":"toolCall","id":"call_1","name":"codemode","arguments":{"code":"await tools.read()"}}],"stopReason":"toolUse","timestamp":900}"#
        try await t.feed(
            #"{"type":"agent_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_end","message":\#(call)}"#,
            #"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"codemode","args":{"code":"await tools.read()"}}"#,
            #"{"type":"tool_execution_start","toolCallId":"call_1/1","parentToolCallId":"call_1","toolName":"read","args":{"path":"example.txt"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"call_1/1","parentToolCallId":"call_1","toolName":"read","result":{"content":[{"type":"text","text":"first"}]},"isError":false}"#,
            #"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"codemode","result":{"content":[{"type":"text","text":"handled"}]},"isError":false}"#,
            #"{"type":"message_start","message":\#(result)}"#,
            #"{"type":"message_end","message":\#(result)}"#)
        let running = try await t.snapshot()
        #expect(running.provisional.map(\.entryID).contains("provisional:tool:call_1/1"), "the nested call has a live row of its own")

        let ended = try await t.feedThenSnapshot(#"{"type":"agent_end","messages":[]}"#)
        let ids = ended.messages.map(\.entryID)
        #expect(ids.contains("t:call_1") && ids.contains("t:call_1:nested:call_1/1"), "history holds the script and its nested call: \(ids)")
        #expect(!ended.provisional.contains { $0.role == "toolResult" }, "no live tool row is left beside them: \(ended.provisional.map(\.entryID))")
        #expect(ended.provisional.isEmpty)
    }

    // MARK: - Reads that remain

    @Test func aMessagePiSavedWithoutItsEventIsReadOnce() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi)
        _ = try await pi.send("fill", from: ready)
        let filled = try await pi.snapshot("the filler rows") { !$0.running && $0.messages.last?.blocks.first?.text == "filler 119" }
        try await pi.historySettled()
        #expect(readCount(pi) == reads + 1)
        #expect(try await work(pi).reason == .countMismatch)
        #expect(filled.messages.count == RPCThreadState.pageSize)
        #expect(try await pi.thread { $0.history.filter { $0.blocks.first?.text.hasPrefix("filler ") == true }.count } == 120)

        try await turn(pi, "tools:0 afterwards", from: ready)
        #expect(readCount(pi) == reads + 1, "the next turn's count agrees: nothing reads")
    }

    @Test func aDisplayedCustomMessageStillReadsTheHistory() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi)
        let commands = try await pi.snapshot("the command list") { $0.commands != nil }
        #expect(try await pi.send("/session-name report hello", from: commands).failureCode == nil)
        let shown = try await pi.snapshot("the report") { $0.messages.contains { $0.blocks.first?.text == "hello" } }
        try await pi.historySettled()
        let row = try #require(shown.messages.last { $0.blocks.first?.text == "hello" })
        let time = try #require(row.timestamp)
        #expect(row.entryID == "custom:\(Int64(time))", "the id pi's list gives it: \(row.entryID)")
        #expect((reads + 1)...(reads + 2) ~= readCount(pi), "the message's read, and the command's")
        _ = ready
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    @Test func anExtensionCommandReadsTheHistoryOnceItAnswers() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let commands = try await pi.snapshot("the command list") { $0.commands != nil }
        let reads = readCount(pi), records = pi.stdin().count
        #expect(try await pi.send("/session-name info hi", from: commands).failureCode == nil)
        try await eventually("the command's read") { readCount(pi) > reads }
        try await pi.historySettled()
        #expect(readCount(pi) == reads + 1)
        #expect(try await work(pi).reason == .command)
        let types = pi.stdin().dropFirst(records).compactMap { $0["type"] as? String }
        let state = try #require(types.firstIndex(of: "get_state")), read = try #require(types.firstIndex(of: "get_messages"))
        #expect(state < read, "get_state shows a switched session before the read: \(types)")
        _ = ready
    }

    @Test func aBoundaryCompactionIsRead() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi)
        _ = try await pi.send("entry-compaction", from: ready)
        let compacted = try await pi.snapshot("the compaction") { $0.messages.contains { $0.role == "compactionSummary" } }
        try await pi.historySettled()
        #expect(compacted.messages.contains { $0.role == "compactionSummary" })
        #expect(readCount(pi) == reads + 1)
        #expect(try await work(pi).reason == .entry)
    }

    @Test func aDroppedRecordIsRead() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi)
        _ = try await pi.send("malformed-record", from: ready)
        _ = try await pi.snapshot("the turn") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to malformed-record" }
        try await eventually("the read for the lost record") { readCount(pi) > reads }
        try await pi.historySettled()
        #expect(readCount(pi) == reads + 1)
        #expect(try await work(pi).reason == .droppedRecord)
    }

    // MARK: - Reads in flight

    /// A history with a picture, so a read can be held while its images are read (`beforeHistoryImages`).
    private func held() async throws -> (ScratchServer, PiAgent, NativeThreadSnapshot, release: () -> Void, landed: Locked<Bool>) {
        let h = try ScratchServer.fresh()
        do {
            let file = h.dir.appendingPathComponent("history.json")
            let history: [[String: Any]] = [
                ["role": "user", "content": [["type": "text", "text": "look"], ["type": "image", "data": ThreadImagesTests.png(side: 16).base64EncodedString(), "mimeType": "image/png"]], "timestamp": 1_733_234_000_000],
                ["role": "assistant", "content": [["type": "text", "text": "seen"]], "stopReason": "stop", "timestamp": 1_733_234_000_001],
            ]
            try JSONSerialization.data(withJSONObject: history).write(to: file)
            let pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": file.path])
            let ready = try await pi.ready()
            let gate = DispatchSemaphore(value: 0), entered = Locked(false), landed = Locked(false)
            try await pi.thread { thread in
                thread.beforeHistoryImages = { entered.withValue { $0 = true }; gate.wait() }
                thread.refreshMessages { _ in landed.withValue { $0 = true } }
            }
            try await eventually("an explicit read to be held") { entered.current }
            // Reads from here on are not held.
            try await pi.thread { $0.beforeHistoryImages = nil }
            return (h, pi, ready, { gate.signal() }, landed)
        } catch { h.stop(); throw error }
    }

    @Test func aFoldAskedForDuringAReadBecomesARead() async throws {
        let (h, pi, ready, release, landed) = try await held()
        defer { release(); h.stop() }
        let reads = readCount(pi)
        try await turn(pi, "tools:0 while a read is held", from: ready)
        #expect(try await work(pi).reason == .readInFlight)
        #expect(readCount(pi) == reads + 1, "one superseding read, not a fold the held answer could erase")
        release()
        try await eventually("the held read to finish") { landed.current }
        try await pi.historySettled()
        let done = try await pi.snapshot("the turn once") { $0.messages.last?.blocks.first?.text == "Reply to tools:0 while a read is held" }
        #expect(done.messages.filter { $0.blocks.first?.text == "tools:0 while a read is held" }.count == 1)
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    @Test func aHeldOlderReadStopsBlockingFoldsOnceANewerOneInstalls() async throws {
        let (h, pi, ready, release, landed) = try await held()
        defer { release(); h.stop() }
        try await turn(pi, "tools:0 first", from: ready)
        let reads = readCount(pi), folds = try await work(pi).folds
        try await turn(pi, "tools:0 second", from: ready)
        #expect(!landed.current, "the older read is still held")
        #expect(readCount(pi) == reads, "the second turn folds: the held answer can no longer install")
        #expect(try await work(pi).folds > folds)
        release()
        try await eventually("the held read to finish") { landed.current }
        try await pi.historySettled()
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    // MARK: - Questions, rows and entries

    @Test func aQuestionThatTimesOutAfterTheTurnStillLands() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi)
        _ = try await pi.send("question-timeout-late-host", from: ready)
        let done = try await pi.snapshot("the late timeout record in history") { $0.dialogs.isEmpty && $0.messages.contains { $0.question?.outcome == .expired } }
        try await pi.historySettled()
        #expect(done.messages.filter { $0.question != nil }.count == 1)
        #expect(!done.provisional.contains { $0.question != nil })
        #expect(readCount(pi) == reads, "the record is a trailing row a fold places: nothing read")
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    @Test func aBoundaryRowFoldsWithTheTimePiSavedIt() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi)
        _ = try await pi.send("boundary-row", from: ready)
        let shown = try await pi.snapshot("the hook row") { $0.messages.contains { $0.customType == "shepherd.hook" } }
        try await pi.historySettled()
        let row = try #require(shown.messages.last { $0.customType == "shepherd.hook" })
        let time = try #require(row.timestamp)
        #expect(row.entryID == "custom:\(Int64(time))")
        #expect(row.hook != nil && row.blocks.first?.text == "Stop hook: the tests still fail.")
        #expect(readCount(pi) == reads)
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    @Test func aGoalContinuationFoldsWithoutARead() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi), start = try await work(pi)
        _ = try await pi.send("boundary-hidden", from: ready)
        let done = try await pi.snapshot("the turn") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to boundary-hidden" }
        try await pi.historySettled()
        #expect(!done.messages.contains { $0.role == "custom" }, "a continuation prompt has no row")
        #expect(readCount(pi) == reads)
        #expect(try await work(pi).folded == start.folded + 3, "the user message, the reply and the hidden message")
        #expect(try await holdsWhatAWholeReadGives(pi))
    }

    @Test(arguments: ["entry-custom", "entry-usage"])
    func customAndUsageEntriesReadNothing(_ prompt: String) async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi), start = try await work(pi)
        try await turn(pi, prompt, from: ready)
        #expect(readCount(pi) == reads, "pi's transcript lists no \(prompt): nothing to read")
        #expect(try await work(pi).folded == start.folded + 2)
        #expect(try await work(pi).reason == nil)
    }

    @Test func aTailOverItsByteBudgetFoldsMidRun() async throws {
        let (h, pi, ready) = try await launch()
        defer { h.stop() }
        let reads = readCount(pi), start = try await work(pi)
        try await pi.thread { $0.tailByteLimit = 1 }
        pi.finishTool(1); pi.finishTool(2)
        #expect(try await pi.send("tools:3 a small budget", from: ready).failureCode == nil)
        _ = try await pi.snapshot("the third call to run") { $0.running && $0.provisional.contains { $0.toolCallID == "call_q3" && $0.status == "running" } }
        let now = try await work(pi)
        #expect(now.folds >= start.folds + 3 && now.folded >= start.folded + 5, "the run's messages folded before it ended: \(now)")
        #expect(readCount(pi) == reads)
        pi.finishTool(3)
        _ = try await pi.snapshot("the run to end") { !$0.running && $0.messages.last?.blocks.first?.text == "Reply to tools:3 a small budget" }
        try await pi.historySettled()
        #expect(readCount(pi) == reads)
        #expect(try await holdsWhatAWholeReadGives(pi))
    }
}
