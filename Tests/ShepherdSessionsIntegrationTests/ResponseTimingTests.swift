import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// What the host measures of each model request (ResponseVisibility): the status extension's
/// marks (`responseTiming`: sent, headers, first event) on the extension socket, joined with what
/// pi's RPC stream shows (first thinking, first text, the end and its usage). The two channels
/// race, so a mark may land after the stream it describes has started, or ended. Events are the
/// shapes pi 1.0.0 sends.
@Suite("Response timing", .integrationTimeLimit)
struct ResponseTimingTests {
    typealias Thread = ThreadEventTests.Thread

    static let stamp = 1_790_744_354_772.0
    static let start = #"{"type":"agent_start"}"#
    static let replyStart = #"{"type":"message_start","message":{"role":"assistant","content":[],"stopReason":"pending","timestamp":1790744354772}}"#
    static func update(_ event: String) -> String { #"{"type":"message_update","assistantMessageEvent":\#(event)}"# }
    static let thinking = [update(#"{"type":"thinking_start","contentIndex":0}"#),
                           update(#"{"type":"thinking_delta","contentIndex":0,"delta":"**Choosing a screen**\n\nCompared both."}"#)]
    static let blank = update(#"{"type":"text_start","contentIndex":1}"#)
    static let words = update(#"{"type":"text_delta","contentIndex":1,"delta":"Yes."}"#)
    static let replyEnd = #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"**Choosing a screen**\n\nCompared both."},{"type":"text","text":"Yes."}],"stopReason":"stop","timestamp":1790744354772,"provider":"anthropic","model":"claude-opus-4-5","usage":{"input":1200,"output":2900,"cacheRead":13000,"cacheWrite":0}}}"#

    private func mark(_ t: Thread, _ mark: ResponseTimingMark, seq: Int, at: Double) async {
        await withCheckedContinuation { continuation in
            t.queue.async {
                t.state.recordResponseMark(mark, seq: seq, at: at)
                continuation.resume()
            }
        }
    }

    private func reply(_ snapshot: NativeThreadSnapshot) -> NativeThreadMessage? {
        snapshot.provisional.last { $0.role == "assistant" }
    }

    /// Sent, then headers: still waiting, since headers are no model event. The stream's first
    /// thinking and text are stamped as the host reads them, the extension's earlier first event
    /// stands over the host's later reading of it, and the end brings the provider's usage.
    @Test func aRequestIsTimedFromItsSendToItsEnd() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start)
        let sent = Date().timeIntervalSince1970 * 1000 - 3_000
        await mark(t, .sent, seq: 1, at: sent)
        var snapshot = try await t.snapshot()
        #expect(snapshot.liveRequest == NativeResponseTiming(sentAt: sent), "waiting: the clock runs from the send")
        await mark(t, .headers, seq: 1, at: sent + 1_200)
        #expect(try await t.snapshot().liveRequest?.firstEventAt == nil, "headers are not a model event")

        for record in [Self.replyStart] + Self.thinking { try await t.feed(record) }
        snapshot = try await t.snapshot()
        let streaming = try #require(reply(snapshot)?.timing)
        #expect(streaming.sentAt == sent && streaming.headersAt == sent + 1_200)
        let thoughtAt = try #require(streaming.firstThinkingAt)
        #expect(streaming.firstEventAt == thoughtAt, "pi's first event, as the host read it, until the extension's lands")
        #expect(snapshot.liveRequest == streaming)

        await mark(t, .firstEvent, seq: 1, at: sent + 1_400)
        #expect(try await t.snapshot().provisional.last?.timing?.firstEventAt == sent + 1_400, "the earlier first event stands")

        try await t.feed(Self.blank)
        #expect(try await t.snapshot().provisional.last?.timing?.firstTextAt == nil, "an empty block is no visible text")
        try await t.feed(Self.words)
        try await t.feed(Self.replyEnd)
        snapshot = try await t.snapshot()
        let ended = try #require(reply(snapshot)?.timing)
        #expect(ended.firstTextAt != nil && ended.endedAt != nil && ended.endedAt! >= ended.firstTextAt!)
        #expect(ended.inputTokens == 14_200 && ended.outputTokens == 2_900, "the provider's usage, prompt and cache together")
        #expect(ended.provider == "anthropic" && ended.model == "claude-opus-4-5")
        #expect(snapshot.liveRequest == nil, "nothing is in flight")
    }

    /// The socket can lose the race to pi's stdout: a send reported after its message started
    /// joins that message, and a first event reported after the response ended joins its record.
    @Test func marksThatArriveLateJoinTheirRequest() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start)
        try await t.feed(Self.replyStart)
        #expect(try await t.snapshot().provisional.last?.timing?.sentAt == nil)
        await mark(t, .sent, seq: 4, at: 1_000)
        #expect(try await t.snapshot().provisional.last?.timing?.sentAt == 1_000)
        for record in Self.thinking + [Self.words, Self.replyEnd] { try await t.feed(record) }
        await mark(t, .message, seq: 4, at: Self.stamp)
        await mark(t, .firstEvent, seq: 4, at: 1_300)
        #expect(try await t.snapshot().provisional.last?.timing?.firstEventAt == 1_300)
        // A mark for a request that isn't this one changes nothing.
        let revision = try await t.snapshot().revision
        await mark(t, .headers, seq: 9, at: 2_000)
        #expect(try await t.snapshot().revision == revision)
    }

    @Test func marksArrivingAWholeRequestLateStillJoinTheirOwnMessage() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start)
        for record in [Self.replyStart] + Self.thinking + [Self.words, Self.replyEnd] { try await t.feed(record) }
        // Both replies reached stdout before the socket was read.
        let secondStamp = Self.stamp + 10_000
        for record in [Self.replyStart, Self.words, Self.replyEnd] {
            try await t.feed(record.replacingOccurrences(of: "1790744354772", with: "1790744364772"))
        }
        for (seq, time, sent) in [(1, Self.stamp, 1_000.0), (2, secondStamp, 50_000.0)] {
            await mark(t, .sent, seq: seq, at: sent)
            await mark(t, .headers, seq: seq, at: sent + 100)
            await mark(t, .firstEvent, seq: seq, at: sent + 200)
            await mark(t, .message, seq: seq, at: time)
        }
        let replies = try await t.snapshot().provisional.filter { $0.role == "assistant" }
        #expect(replies.map { $0.timing?.sentAt } == [1_000, 50_000])
        #expect(replies.map { $0.timing?.headersAt } == [1_100, 50_100])
        #expect(replies.allSatisfy { $0.timing?.endedAt != nil })
    }

    @Test func interleavedThinkingAndToolArgumentsDoNotClaimASimplePhaseSplit() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        for record in [Self.start, Self.replyStart] + Self.thinking + [Self.words] + Self.thinking { try await t.feed(record) }
        #expect(try await t.snapshot().provisional.first?.timing?.mixedPhases == true)
        try await t.feed(Self.update(#"{"type":"toolcall_start","contentIndex":2,"id":"call_a","toolName":"write"}"#))
        #expect(try await t.snapshot().provisional.first?.timing?.mixedPhases == true)
        try await t.feed(Self.replyEnd.replacingOccurrences(of: "\"stop\"", with: "\"aborted\""))
        #expect(try await t.snapshot().liveRequest == nil, "cancellation leaves no request in flight")
    }

    /// The next request starts a new clock; settling ends it, and a request made while idle (pi's
    /// prompt-cache refresh, if the extension let one through) never shows as waiting.
    @Test func eachRequestHasItsOwnClockAndAnIdleOneShowsNone() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start)
        await mark(t, .sent, seq: 1, at: 1_000)
        for record in [Self.replyStart] + Self.thinking + [Self.words, Self.replyEnd] { try await t.feed(record) }
        await mark(t, .sent, seq: 2, at: 50_000)
        #expect(try await t.snapshot().liveRequest == NativeResponseTiming(sentAt: 50_000))
        try await t.feed(#"{"type":"agent_settled"}"#)
        #expect(try await t.snapshot().liveRequest == nil)
        await mark(t, .sent, seq: 3, at: 90_000)
        #expect(try await t.snapshot().liveRequest == nil)
    }

    /// History the host projects again (the run's end refreshes it from pi) keeps the timing of
    /// the replies it saw, by pi's timestamp; history it never saw has none.
    @Test func historyKeepsTheTimingOfRepliesTheHostSaw() async throws {
        let dir = try makeScratchDirectory("timing-history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("messages.json")
        let history = #"[{"role":"user","content":[{"type":"text","text":"Composer on the right?"}],"timestamp":1790744350000},{"role":"assistant","content":[{"type":"text","text":"Yes."}],"stopReason":"stop","timestamp":1790744354772}]"#
        try history.write(to: file, atomically: true, encoding: .utf8)
        let t = try Thread(env: ["STUB_PI_MESSAGES_FILE": file.path])
        defer { t.stop() }
        let first = try await t.ready()
        #expect(first.messages.last?.timing == nil, "a reply from before this host ran has none")
        try await t.feed(Self.start)
        await mark(t, .sent, seq: 1, at: 1_000)
        for record in [Self.replyStart] + Self.thinking + [Self.words, Self.replyEnd] { try await t.feed(record) }
        try await t.feed(#"{"type":"agent_end","messages":[]}"#)
        try await eventually("history projected again with the timing") {
            (try? await t.snapshot().messages.last?.timing?.sentAt) == 1_000
        }
    }

    /// Populate the row-size cache before delivering socket marks, after get_messages has
    /// replaced every ended provisional row. Both newly learned and corrected timing must
    /// reach the displayed history immediately, without another history fetch.
    @Test(arguments: [false, true])
    func lateMarksUpdateAlreadyProjectedHistory(alreadyLinked: Bool) async throws {
        let dir = try makeScratchDirectory("timing-late-history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("messages.json")
        let history = #"[{"role":"user","content":[{"type":"text","text":"Composer on the right?"}],"timestamp":1790744350000},{"role":"assistant","content":[{"type":"text","text":"Yes."}],"stopReason":"stop","timestamp":1790744354772}]"#
        try history.write(to: file, atomically: true, encoding: .utf8)
        let t = try Thread(env: ["STUB_PI_MESSAGES_FILE": file.path])
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start)
        if alreadyLinked {
            await mark(t, .sent, seq: 1, at: 1_000)
            await mark(t, .headers, seq: 1, at: 1_100)
            await mark(t, .message, seq: 1, at: Self.stamp)
        }
        for record in [Self.replyStart] + Self.thinking + [Self.words, Self.replyEnd] { try await t.feed(record) }
        try await t.feed(#"{"type":"agent_end","messages":[]}"#)
        try await eventually("history to replace the provisional reply") {
            try await t.snapshot().provisional.isEmpty
        }
        let before = try await t.snapshot()
        if !alreadyLinked {
            await mark(t, .sent, seq: 1, at: 1_000)
            await mark(t, .headers, seq: 1, at: 1_100)
        }
        await mark(t, .firstEvent, seq: 1, at: 1_200)
        await mark(t, .message, seq: 1, at: Self.stamp)
        let after = try await t.snapshot()
        let timing = try #require(after.messages.last?.timing)
        #expect(timing.sentAt == 1_000 && timing.headersAt == 1_100 && timing.firstEventAt == 1_200)
        #expect(after.revision > before.revision, "metadata-only history changes notify clients")
        let bytes = await withCheckedContinuation { continuation in
            t.queue.async { continuation.resume(returning: t.state.bytesOfLastSnapshot) }
        }
        #expect(bytes == (try JSONEncoder().encode(after).count), "the warmed history-size cache was invalidated")
        await mark(t, .message, seq: 1, at: Self.stamp)
        #expect(try await t.snapshot().revision == after.revision, "identical metadata is not a new revision")
    }

    /// The two transport channels can straddle both settlement and the next run. Keep the
    /// old request's sent/headers while its final marks update history, not the new live reply.
    @Test func lateMarksSurviveSettlementWithoutChangingTheNextRun() async throws {
        let dir = try makeScratchDirectory("timing-late-settle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("messages.json")
        let history = #"[{"role":"user","content":[{"type":"text","text":"Composer on the right?"}],"timestamp":1790744350000},{"role":"assistant","content":[{"type":"text","text":"Yes."}],"stopReason":"stop","timestamp":1790744354772}]"#
        try history.write(to: file, atomically: true, encoding: .utf8)
        let t = try Thread(env: ["STUB_PI_MESSAGES_FILE": file.path])
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start)
        await mark(t, .sent, seq: 1, at: 1_000)
        await mark(t, .headers, seq: 1, at: 1_100)
        for record in [Self.replyStart] + Self.thinking + [Self.words, Self.replyEnd] { try await t.feed(record) }
        try await t.feed(#"{"type":"agent_end","messages":[]}"#, #"{"type":"agent_settled"}"#)
        try await eventually("the first reply to settle into history") {
            let snapshot = try await t.snapshot()
            return !snapshot.running && snapshot.provisional.isEmpty
        }
        let old = try #require(try await t.snapshot().messages.last?.timing)
        #expect(old.sentAt == 1_000 && old.headersAt == 1_100)

        try await t.feed(Self.start)
        await mark(t, .sent, seq: 2, at: 50_000)
        await mark(t, .headers, seq: 2, at: 50_100)
        try await t.feed(Self.replyStart.replacingOccurrences(of: "1790744354772", with: "1790744364772"))
        for record in Self.thinking { try await t.feed(record) }
        await mark(t, .firstEvent, seq: 2, at: 50_200)
        await mark(t, .message, seq: 2, at: Self.stamp + 10_000)
        let next = try await t.snapshot()
        await mark(t, .firstEvent, seq: 1, at: 1_200)
        await mark(t, .message, seq: 1, at: Self.stamp)
        let updated = try await t.snapshot()
        let timing = try #require(updated.messages.last?.timing)
        #expect(timing.sentAt == old.sentAt && timing.headersAt == old.headersAt && timing.firstEventAt == 1_200)
        #expect(timing.endedAt == old.endedAt && timing.firstTextAt == old.firstTextAt)
        #expect(updated.liveRequest == next.liveRequest)
        #expect(updated.provisional == next.provisional, "the late old request cannot change the new assistant")

        try await t.feed(Self.replyEnd.replacingOccurrences(of: "1790744354772", with: "1790744364772"))
        try await t.feed(#"{"type":"agent_end","messages":[]}"#, #"{"type":"agent_settled"}"#)
        try await eventually("the next end's history refresh to complete") {
            try await t.snapshot().provisional.isEmpty
        }
        #expect(try await t.snapshot().messages.last?.timing == timing, "a later refresh keeps the corrected old request")

        // Correlation storage stays bounded. Even after eviction, partial late marks cannot
        // delete sent/headers already attached to the history row.
        for seq in 3...(RPCThreadState.timingLimit + 3) {
            await mark(t, .headers, seq: seq, at: 100_000 + Double(seq))
        }
        await mark(t, .firstEvent, seq: 1, at: 1_200)
        await mark(t, .message, seq: 1, at: Self.stamp)
        let evicted = try await t.snapshot()
        #expect(evicted.messages.last?.timing == timing)
        #expect(evicted.liveRequest == nil)
    }

    @Test func switchingSessionsClearsRetainedTimingCorrelations() async throws {
        let t = try Thread()
        defer { t.stop() }
        let before = try await t.ready()
        await mark(t, .sent, seq: 1, at: 1_000)
        await mark(t, .headers, seq: 1, at: 1_100)
        let result: Result<RPCResponse, RPCError> = await withCheckedContinuation { continuation in
            t.queue.async {
                t.session.request(.prompt(message: "newsession")) { continuation.resume(returning: $0) }
            }
        }
        #expect(try result.get().success)
        try await eventually("the new session generation and history to load") {
            guard let snapshot = await t.request(.snapshot()).snapshotValue else { return false }
            return snapshot.generation != before.generation && snapshot.messages.isEmpty
        }
        try await t.feed(Self.start)
        await mark(t, .sent, seq: 1, at: 50_000)
        #expect(try await t.snapshot().liveRequest == NativeResponseTiming(sentAt: 50_000),
                "the previous generation must not suppress a new send with the same sequence")
    }

    /// A call the model is writing counts the bytes of its arguments as they pass, holding none of
    /// them: its row changes only when the count reaches the next step, never per fragment.
    @Test func aCallBeingWrittenCountsItsArgumentsInSteps() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let callStart = Self.update(#"{"type":"toolcall_start","contentIndex":0,"id":"call_big","toolName":"write"}"#)
        func fragment(_ text: String) -> String {
            let quoted = String(decoding: (try? JSONEncoder().encode(text)) ?? Data(), as: UTF8.self)
            return Self.update(#"{"type":"toolcall_delta","contentIndex":0,"delta":\#(quoted)}"#)
        }
        for record in [Self.start, Self.replyStart, callStart, fragment(#"{"path":"App/Duo.swift","content":""#)] { try await t.feed(record) }
        func row() async throws -> NativeThreadMessage? { try await t.snapshot().provisional.first { $0.toolCallID == "call_big" } }
        #expect(try await row()?.argumentBytes == nil, "under 1 KB says nothing")
        let line = String(repeating: "x", count: 99) + "\n"
        var revisions: Set<UInt64> = []
        for _ in 0..<31 {
            try await t.feed(fragment(line))
            revisions.insert(try await t.snapshot().revision)
        }
        let row31 = try #require(try await row())
        #expect(row31.argumentBytes == 3 * 1024, "3,135 bytes so far, shown as 3 KB")
        #expect(revisions.count <= 4, "the row changed at 1, 2 and 3 KB, not per fragment (\(revisions.count) revisions)")
        #expect(row31.argumentsText == #"{"path":"App/Duo.swift"}"#, "the body isn't kept")
        try await t.feed(#"{"type":"tool_execution_start","toolCallId":"call_big","toolName":"write","args":{"path":"App/Duo.swift","content":"x"}}"#)
        #expect(try await row()?.argumentBytes == nil, "once it runs, its arguments are whole")
    }
}
