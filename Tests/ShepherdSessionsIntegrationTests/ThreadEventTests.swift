import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// `RPCThreadState` fed recorded pi events. The thread needs an `RPCSession` (it bootstraps
/// state, history, and stats from pi), so the stub answers those requests while the test injects
/// events directly — the exact projection rules without scripting every scenario into the stub.
@Suite("Thread projection from pi events", .integrationTimeLimit)
struct ThreadEventTests {
    final class Thread: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.thread")
        let session: RPCSession
        let state: RPCThreadState
        let dir: URL

        init(bootstrap: Bool = true, env: [String: String]? = nil) throws {
            dir = try makeScratchDirectory("thread")
            session = try RPCSession(params: CreateSessionParams(cwd: dir.path, command: StubPi.command, env: env, runtime: .rpc), queue: queue)
            state = RPCThreadState(session: session, queue: queue)
            session.onEvent = { [weak state] event in state?.handle(event) }
            session.start()
            if bootstrap { queue.async { self.state.bootstrap() } }
        }

        func stop() {
            queue.sync { session.shutdown() }
            try? FileManager.default.removeItem(at: dir)
        }

        /// Hand recorded pi events to the thread, in order, as the session would.
        func feed(_ records: String...) async throws {
            let events = try records.map { try JSONDecoder().decode(RPCEvent.self, from: Data($0.utf8)) }
            await withCheckedContinuation { continuation in
                queue.async {
                    events.forEach(self.state.handle)
                    continuation.resume()
                }
            }
        }

        func request(_ request: NativeThreadRequest) async -> NativeThreadResult {
            await withCheckedContinuation { continuation in
                queue.async { self.state.handle(request) { continuation.resume(returning: $0) } }
            }
        }

        func snapshot() async throws -> NativeThreadSnapshot {
            let result = await request(.snapshot())
            return try #require(result.snapshotValue, "expected a snapshot, got \(result)")
        }

        /// Hand one recorded event to the thread and take a snapshot in the same queue turn, so
        /// nothing the event scheduled on the queue (a dialog's expiry) can run in between.
        func feedThenSnapshot(_ record: String) async throws -> NativeThreadSnapshot {
            let event = try JSONDecoder().decode(RPCEvent.self, from: Data(record.utf8))
            let result = await withCheckedContinuation { continuation in
                queue.async {
                    self.state.handle(event)
                    self.state.handle(.snapshot()) { continuation.resume(returning: $0) }
                }
            }
            return try #require(result.snapshotValue, "expected a snapshot, got \(result)")
        }

        /// Once pi's state, history, stats, and commands have all landed.
        func ready() async throws -> NativeThreadSnapshot {
            var latest: NativeThreadSnapshot?
            try await eventually("the bootstrap to land") {
                latest = await request(.snapshot()).snapshotValue
                return latest.map { !$0.piSessionID.isEmpty && $0.messages.count == 2 && $0.stats != nil && $0.commands != nil } ?? false
            }
            return try #require(latest)
        }
    }

    // MARK: - Bootstrap and revisions

    @Test func theBootstrapProjectsPisStateHistoryStatsAndCommands() async throws {
        let t = try Thread()
        defer { t.stop() }
        let s = try await t.ready()
        #expect(s.piSessionID == "stub-session")
        #expect(UUID(uuidString: s.generation) != nil)
        #expect(s.model == "anthropic/claude-sonnet-4-20250514")
        #expect(s.thinking == "medium")
        #expect(!s.running)
        #expect(s.runtime == "rpc" && s.dialogsSupported)
        #expect(s.supportedActions == ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents"])
        #expect(s.messages.map(\.entryID) == ["user:1733234567890", "assistant:1733234567891"])
        #expect(s.messages.first?.blocks == [NativeThreadBlock(kind: .text, text: "Hello!")])
        #expect(s.stats == NativeThreadStats(contextTokens: 60000, contextWindow: 200000, contextPercent: 30, totalTokens: 105000, cost: 0.45))
        #expect(s.commands?.map(\.name) == ["session-name", "fix-tests"])
        #expect(s.provisional.isEmpty && s.dialogs.isEmpty && s.widgets == [] && !s.clipped && s.olderCursor == nil)
    }

    @Test func requestsBeforePiReportsItsSessionAreStarting() async throws {
        let t = try Thread(bootstrap: false)
        defer { t.stop() }
        #expect(await t.request(.snapshot()) == .failure(code: NativeThreadCode.starting, message: "pi is starting."))
    }

    /// pi reads stdin only once it has started, so a pi slower than the request deadline
    /// answers requests already given up on. The bootstrap asks again until one lands.
    @Test func aPiSlowerThanTheRequestDeadlineIsAskedAgainUntilItAnswers() async throws {
        let t = try Thread(bootstrap: false, env: ["STUB_PI_STARTUP_GATE": "release-pi"])
        defer { t.stop() }
        t.queue.async { t.state.bootstrap(timeout: 0.2) }
        try await eventually("the bootstrap to ask again") {
            await withCheckedContinuation { continuation in t.queue.async { continuation.resume(returning: t.state.bootstrapAttempts >= 2) } }
        }
        #expect(await t.request(.snapshot()).failureCode == NativeThreadCode.starting)

        FileManager.default.createFile(atPath: t.dir.appendingPathComponent("release-pi").path, contents: nil)
        let s = try await t.ready()
        #expect(s.piSessionID == "stub-session")
    }

    @Test func anUnchangedThreadAnswersUnchangedAndAChangeBumpsTheRevision() async throws {
        let t = try Thread()
        defer { t.stop() }
        let s = try await t.ready()
        #expect(await t.request(.snapshot(afterRevision: s.revision)) == .unchanged(piSessionID: s.piSessionID, generation: s.generation, revision: s.revision))
        #expect(await t.request(.snapshot(expectedSessionID: "other")) == .failure(code: "stale_session", message: "Refresh the thread before acting."))

        try await t.feed(#"{"type":"agent_start"}"#)
        let running = try await t.snapshot()
        #expect(running.running)
        #expect(running.revision > s.revision)
    }

    /// One event after its setup, and how many revisions it is worth.
    struct RevisionCase: Sendable, CustomTestStringConvertible {
        let name: String
        let setup: [String]
        let event: String
        let revisions: UInt64
        var testDescription: String { name }
    }

    private static let start = #"{"type":"agent_start"}"#
    private static let messageStart = #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#
    private static let textStart = #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#
    private static func textDelta(_ text: String) -> String {
        #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"\#(text)"}}"#
    }
    private static let toolStart = #"{"type":"tool_execution_start","toolCallId":"c1","toolName":"bash","args":{"command":"ls"}}"#
    private static let toolUpdate = #"{"type":"tool_execution_update","toolCallId":"c1","toolName":"bash","partialResult":{"content":[{"type":"text","text":"out"}]}}"#
    private static let queueUpdate = #"{"type":"queue_update","steering":[],"followUp":["later"]}"#

    static let revisionCases: [RevisionCase] = [
        .init(name: "an agent starting", setup: [], event: start, revisions: 1),
        .init(name: "a message starting", setup: [start], event: messageStart, revisions: 1),
        .init(name: "a text delta", setup: [start, messageStart, textStart], event: textDelta("Hi"), revisions: 1),
        .init(name: "a tool starting", setup: [start], event: toolStart, revisions: 1),
        .init(name: "a tool's output", setup: [start, toolStart], event: toolUpdate, revisions: 1),
        .init(name: "a tool ending", setup: [start, toolStart],
              event: #"{"type":"tool_execution_end","toolCallId":"c1","toolName":"bash","result":{"content":[]},"isError":false}"#, revisions: 1),
        .init(name: "a dialog", setup: [], event: #"{"type":"extension_ui_request","id":"d1","method":"select","title":"Pick","options":["a"]}"#, revisions: 1),
        .init(name: "a widget", setup: [], event: #"{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"k","widgetLines":["hi"]}"#, revisions: 1),
        .init(name: "a repeated queue update", setup: [queueUpdate], event: queueUpdate, revisions: 0),
        .init(name: "an unknown event", setup: [], event: #"{"type":"compaction_start","reason":"threshold"}"#, revisions: 0),
        .init(name: "an idle agent settling", setup: [], event: #"{"type":"agent_settled"}"#, revisions: 0),
        .init(name: "a repeated tool output", setup: [start, toolStart, toolUpdate], event: toolUpdate, revisions: 0),
        .init(name: "an empty text delta", setup: [start, messageStart, textStart, textDelta("Hi")], event: textDelta(""), revisions: 0),
    ]

    /// A change a snapshot would show moves the revision exactly once; an event that changes
    /// nothing leaves it, and a client polling after it hears `unchanged`.
    @Test(arguments: revisionCases)
    func eachVisibleChangeMovesTheRevisionOnceAndNothingElseDoes(_ c: RevisionCase) async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        for record in c.setup { try await t.feed(record) }
        let before = try await t.snapshot()

        try await t.feed(c.event)
        let after = try await t.snapshot()
        #expect(after.revision - before.revision == c.revisions)
        if c.revisions == 0 {
            #expect(await t.request(.snapshot(afterRevision: before.revision))
                == .unchanged(piSessionID: before.piSessionID, generation: before.generation, revision: before.revision))
        }
    }

    #if DEBUG
    /// A streamed delta rehashes the message it grew, never the turn's tool output beside it.
    @Test func aDeltaRehashesOnlyTheMessageItGrew() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let output = try String(decoding: JSONEncoder().encode(String(repeating: "line of build output 00\n", count: 16_384 / 24)), as: UTF8.self)
        try await t.feed(Self.start)
        for i in 0..<50 {
            try await t.feed(
                #"{"type":"tool_execution_start","toolCallId":"t\#(i)","toolName":"bash","args":{"command":"make"}}"#,
                #"{"type":"tool_execution_end","toolCallId":"t\#(i)","toolName":"bash","result":{"content":[{"type":"text","text":\#(output)}]},"isError":false}"#)
        }
        try await t.feed(Self.messageStart, Self.textStart, Self.textDelta("Hello"), Self.textDelta(" world"))
        let bytes = await withCheckedContinuation { continuation in
            t.queue.async { continuation.resume(returning: t.state.bytesHashedByLastCommit) }
        }
        #expect(bytes > 0 && bytes <= "Hello world".utf8.count)
    }

    /// Snapshots size their rows once: after a delta, the next snapshot encodes only its fixed
    /// part and the message that grew, and its arithmetic is its encoded size.
    @Test func aSnapshotAfterADeltaEncodesOnlyItsFixedPartAndTheGrownMessage() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(Self.start, Self.toolStart, Self.toolUpdate, Self.messageStart, Self.textStart, Self.textDelta("Hello"))
        _ = try await t.snapshot()

        try await t.feed(Self.textDelta(" world"))
        let snapshot = try await t.snapshot()
        let (encodes, bytes) = await withCheckedContinuation { continuation in
            t.queue.async { continuation.resume(returning: (t.state.encodesByLastSnapshot, t.state.bytesOfLastSnapshot)) }
        }
        #expect(encodes == 2)
        #expect(bytes == (try JSONEncoder().encode(snapshot).count))
        #expect(snapshot.messages.count == 2 && snapshot.provisional.count == 2)
    }
    #endif

    // MARK: - Streaming

    @Test func deltasBuildOneProvisionalAssistantMessage() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(
            #"{"type":"agent_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_start","contentIndex":0}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"Hel"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"lo"}}"#
        )
        let streaming = try await t.snapshot()
        #expect(streaming.provisional.map(\.entryID) == ["provisional:assistant:1"])
        #expect(streaming.provisional.first?.status == "streaming")
        #expect(streaming.provisional.first?.blocks.map(\.text) == ["Hello"])

        try await t.feed(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Hello there"}],"stopReason":"stop"}}"#)
        let ended = try await t.snapshot()
        #expect(ended.provisional.first?.status == "stop")
        #expect(ended.provisional.first?.blocks.map(\.text) == ["Hello there"])
    }

    /// Spawned mid-turn: the first event seen is a delta, and it still starts a message.
    @Test func aDeltaWithoutMessageStartStartsAProvisionalMessage() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":0,"delta":"mid-turn"}}"#)
        #expect(try await t.snapshot().provisional.map { $0.blocks.map(\.text) } == [["mid-turn"]])
    }

    @Test func userAndToolMessagesDoNotOpenAssistantRows() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(
            #"{"type":"message_start","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"message_end","message":{"role":"user","content":"hi"}}"#
        )
        #expect(try await t.snapshot().provisional.isEmpty)
    }

    /// "Thought for Ns": measured live, frozen once the answer starts, and carried onto the
    /// history row with the same pi timestamp after the refresh.
    @Test func thinkingTimeIsMeasuredLiveAndSurvivesIntoHistory() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(
            #"{"type":"agent_start"}"#,
            #"{"type":"message_start","message":{"role":"assistant","content":[]}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_start","contentIndex":0}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"hmm"}}"#
        )
        let thinking = try #require(try await t.snapshot().provisional.first?.thinkingSeconds)
        try await t.feed(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"Answer"}}"#)
        let answered = try #require(try await t.snapshot().provisional.first?.thinkingSeconds)
        #expect(answered >= thinking)
        try await t.feed(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":" more"}}"#)
        #expect(try await t.snapshot().provisional.first?.thinkingSeconds == answered, "frozen once the answer began")

        // The stub's seeded assistant message carries this timestamp.
        try await t.feed(
            #"{"type":"message_end","message":{"role":"assistant","timestamp":1733234567891,"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Answer more"}],"stopReason":"stop"}}"#,
            #"{"type":"agent_end","messages":[]}"#
        )
        var history: NativeThreadSnapshot?
        try await eventually("the refresh to replace the provisional row") {
            history = try await t.snapshot()
            return history?.provisional.isEmpty == true && history?.running == false
        }
        #expect(history?.messages.last?.thinkingSeconds == answered)
    }

    @Test func toolExecutionsKeepTheirArgumentsAndStartTime() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"make"}}"#)
        let started = try #require(try await t.snapshot().provisional.first)
        #expect(started.entryID == "provisional:tool:call_1")
        #expect(started.role == "toolResult" && started.status == "running" && started.toolName == "bash")
        #expect(started.argumentsText == #"{"command":"make"}"#)
        let startedAt = try #require(started.startedAt)

        try await t.feed(#"{"type":"tool_execution_update","toolCallId":"call_1","toolName":"bash","partialResult":{"content":[{"type":"text","text":"building…"}]}}"#)
        let partial = try #require(try await t.snapshot().provisional.first)
        #expect(partial.blocks.map(\.text) == ["building…"])
        #expect(partial.argumentsText == #"{"command":"make"}"#, "an update without args keeps the call's arguments")
        #expect(partial.startedAt == startedAt)

        try await t.feed(#"{"type":"tool_execution_end","toolCallId":"call_1","toolName":"bash","result":{"content":[{"type":"text","text":"failed"}]},"isError":true}"#)
        let ended = try #require(try await t.snapshot().provisional.first)
        #expect(ended.status == "complete" && ended.isError == true)
        #expect(ended.startedAt == startedAt)
        #expect(ended.timestamp != nil)
    }

    @Test func atMostAPageOfProvisionalRowsIsKept() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let records = (0..<(RPCThreadState.pageSize + 5)).map {
            #"{"type":"tool_execution_start","toolCallId":"call_\#($0)","toolName":"bash"}"#
        }
        for record in records { try await t.feed(record) }
        let s = try await t.snapshot()
        #expect(s.provisional.count == RPCThreadState.pageSize)
        #expect(s.provisional.first?.toolCallID == "call_5")
        #expect(s.clipped)
    }

    /// Active output is bounded before history fills the rest of the snapshot budget.
    @Test func largeProvisionalOutputIsClippedToTheActiveBudget() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let big = String(repeating: "x", count: 15 * 1024)
        for i in 0..<12 {
            try await t.feed(#"{"type":"tool_execution_update","toolCallId":"call_\#(i)","toolName":"bash","partialResult":{"content":[{"type":"text","text":"\#(big)"}]}}"#)
        }
        let s = try await t.snapshot()
        #expect(s.clipped)
        #expect(s.provisional.count < 12)
        #expect(s.provisional.last?.toolCallID == "call_11", "the newest output is what stays")
        #expect(try JSONEncoder().encode(s).count <= RPCThreadState.snapshotLimit)
    }

    // MARK: - Dialogs

    /// pi's timeout (150 ms) runs from the event, so the first look shares its queue turn: a later
    /// one, behind a busy machine, could find the dialog already gone.
    @Test func aDialogIsShownUntilItsTimeoutExpires() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let shown = try await t.feedThenSnapshot(
            #"{"type":"extension_ui_request","id":"d1","method":"input","title":"Name?","placeholder":"name","prefill":"x","timeout":150}"#)
        #expect(shown.dialogs == [
            NativeThreadDialog(id: "d1", kind: .input, title: "Name?", placeholder: "name", prefill: "x", timeout: 150),
        ])
        try await eventually("the dialog to expire") { try await t.snapshot().dialogs.isEmpty }
    }

    @Test func aRepeatedDialogIDReplacesTheDialog() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(
            #"{"type":"extension_ui_request","id":"d1","method":"confirm","title":"First?"}"#,
            #"{"type":"extension_ui_request","id":"d1","method":"confirm","title":"Second?"}"#
        )
        #expect(try await t.snapshot().dialogs.map(\.title) == ["Second?"])
    }

    @Test func anOversizedDialogIsShownUnavailableAndCannotBeAnswered() async throws {
        let t = try Thread()
        defer { t.stop() }
        let s = try await t.ready()
        let huge = String(repeating: "m", count: RPCThreadState.dialogBytes)
        try await t.feed(#"{"type":"extension_ui_request","id":"big","method":"editor","title":"Edit","prefill":"\#(huge)"}"#)
        let shown = try await t.snapshot()
        #expect(shown.dialogs == [NativeThreadDialog(id: "big", kind: .editor, title: "Dialog too large for native thread", unavailable: "payload-limit")])
        #expect(shown.clipped)

        let answer = NativeThreadRequest.answer(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                                dialogID: "big", answer: .editor(value: "x"))
        #expect(await t.request(answer).failureCode == "dialog_unavailable")
    }

    @Test func atMostEightDialogsAreSent() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        for i in 0..<10 {
            try await t.feed(#"{"type":"extension_ui_request","id":"d\#(i)","method":"confirm","title":"Q\#(i)"}"#)
        }
        #expect(try await t.snapshot().dialogs.map(\.id) == (0..<RPCThreadState.dialogLimit).map { "d\($0)" })
    }

    // MARK: - Widgets

    @Test func widgetsShowTextWithoutANSIAndClearByKey() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(#"{"type":"extension_ui_request","id":"w","method":"setWidget","widgetKey":"plan","widgetLines":["\u001b[1mStep 1\u001b[22m","Step 2"]}"#)
        #expect(try await t.snapshot().widgets == [NativeThreadWidget(namespace: "pi", key: "plan", kind: .text, text: "Step 1\nStep 2")])

        try await t.feed(#"{"type":"extension_ui_request","id":"w","method":"setWidget","widgetKey":"plan"}"#)
        #expect(try await t.snapshot().widgets == [])
    }

    /// Footer chrome, toasts, titles, and machine payloads meant for an extension's own TUI
    /// component are not conversation content.
    @Test func statusToastsTitlesAndMachineWidgetsAreNotShown() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        try await t.feed(
            #"{"type":"extension_ui_request","id":"1","method":"setStatus","statusKey":"build","statusText":"ok"}"#,
            #"{"type":"extension_ui_request","id":"2","method":"notify","message":"loaded","notifyType":"info"}"#,
            #"{"type":"extension_ui_request","id":"3","method":"setTitle","title":"pi"}"#,
            #"{"type":"extension_ui_request","id":"4","method":"setWidget","widgetKey":"m","widgetLines":["PI_SUBAGENT_ASYNC_JSON:{\"kind\":\"snapshot\"}"]}"#
        )
        #expect(try await t.snapshot().widgets == [])
    }

    @Test func widgetsOverTheirLimitsAreDropped() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let longKey = String(repeating: "k", count: 129)
        let longText = String(repeating: "t", count: RPCThreadState.widgetTextBytes + 1)
        try await t.feed(
            #"{"type":"extension_ui_request","id":"1","method":"setWidget","widgetKey":"\#(longKey)","widgetLines":["x"]}"#,
            #"{"type":"extension_ui_request","id":"2","method":"setWidget","widgetKey":"long","widgetLines":["\#(longText)"]}"#
        )
        #expect(try await t.snapshot().widgets == [])

        for i in 0..<(RPCThreadState.widgetItems + 1) {
            try await t.feed(#"{"type":"extension_ui_request","id":"w","method":"setWidget","widgetKey":"w\#(i)","widgetLines":["item"]}"#)
        }
        #expect(try await t.snapshot().widgets?.count == RPCThreadState.widgetItems)
    }

    @Test func widgetsAreBoundedByAnAggregateBudget() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let text = String(repeating: "a", count: 4000)
        for i in 0..<9 {
            try await t.feed(#"{"type":"extension_ui_request","id":"w","method":"setWidget","widgetKey":"w\#(i)","widgetLines":["\#(text)"]}"#)
        }
        let widgets = try #require(try await t.snapshot().widgets)
        #expect(widgets.count == 8, "the ninth would exceed \(RPCThreadState.widgetAggregateBytes) bytes")
        #expect(try JSONEncoder().encode(widgets).count <= RPCThreadState.widgetAggregateBytes)
    }
}
