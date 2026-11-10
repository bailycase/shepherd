import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The pure rules behind folding what pi saved into the thread's history: where the host's own records go among the rows a
/// fold appends, what a whole read lacks, whether pi's message count agrees with the events, which live rows a fold replaces,
/// and how much a held message weighs.
@Suite("History fold rules")
struct HistoryFoldPlacementTests {
    typealias State = RPCThreadState

    // MARK: - Records

    private static func row(_ id: String, _ role: String = "user", at time: Double?, start: Double? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [], timestamp: time, startedAt: start)
    }

    private static func question(_ id: String, at time: Double) -> (at: Double, row: NativeThreadMessage) {
        (time, NativeThreadMessage(entryID: "q:\(id)", role: "question", blocks: [], timestamp: time))
    }

    /// A command's notice carries no time, so it never stretches the turn it lands in.
    private static func notice(_ id: String, at time: Double) -> (at: Double, row: NativeThreadMessage) {
        (time, NativeThreadMessage(entryID: "n:\(id)", role: "custom", blocks: [NativeThreadBlock(kind: .text, text: id)]))
    }

    /// The history a fold leaves: the rows before the trailing records, then the fold's rows with the records among them.
    private static func folded(_ history: [NativeThreadMessage], records: [(at: Double, row: NativeThreadMessage)],
                               appending rows: [NativeThreadMessage]) -> (history: [NativeThreadMessage], late: Bool, newIDs: Set<String>) {
        let placed = Set(history.filter(State.isRecordRow).map(\.entryID))
        let maxStart = history.filter { !State.isRecordRow($0) }.compactMap(State.rowStart).max() ?? -.infinity
        let needs = State.recordNeeds(in: history, records: records, placed: placed, maxStart: maxStart)
        let result = State.placingRecords(needs, among: rows, maxStart: maxStart, placed: placed)
        return (Array(history[..<needs.trailingStart]) + result.rows, needs.late, result.newRecordIDs)
    }

    struct Scenario: CustomStringConvertible {
        var description: String
        /// pi's rows before the fold, and the records the history placed.
        var before: [NativeThreadMessage]
        var placedBefore: [(at: Double, row: NativeThreadMessage)]
        /// pi's rows the fold appends, and every record the thread keeps by then.
        var fold: [NativeThreadMessage]
        var records: [(at: Double, row: NativeThreadMessage)]
    }

    static let scenarios: [Scenario] = [
        Scenario(description: "a question that ended after every row, then a reply that starts after it",
                 before: [row("user:1", at: 100), row("assistant:2", "assistant", at: 200)], placedBefore: [question("a", at: 300)],
                 fold: [row("user:3", at: 400), row("assistant:4", "assistant", at: 500)], records: [question("a", at: 300)]),
        Scenario(description: "a question that ended after the fold's first row",
                 before: [row("user:1", at: 100)], placedBefore: [question("a", at: 150)],
                 fold: [row("assistant:2", "assistant", at: 120), row("assistant:3", "assistant", at: 200)], records: [question("a", at: 150)]),
        Scenario(description: "a new question the fold places among its own rows",
                 before: [row("user:1", at: 100)], placedBefore: [],
                 fold: [row("assistant:2", "assistant", at: 200), row("t:c1", "toolResult", at: 400, start: 250), row("assistant:3", "assistant", at: 500)],
                 records: [question("a", at: 300)]),
        Scenario(description: "a tool result is placed where its call started, not where it ended",
                 before: [row("user:1", at: 100)], placedBefore: [],
                 fold: [row("t:c1", "toolResult", at: 900, start: 150), row("assistant:2", "assistant", at: 950)],
                 records: [question("a", at: 200)]),
        Scenario(description: "untimed notices and a question, none of them placed before",
                 before: [row("user:1", at: 100), row("assistant:2", "assistant", at: 200)], placedBefore: [],
                 fold: [row("user:3", at: 400)], records: [notice("x", at: 250), question("a", at: 300), notice("y", at: 450)]),
        Scenario(description: "records already placed in the middle stay where they are",
                 before: [row("user:1", at: 100), row("assistant:2", "assistant", at: 300)], placedBefore: [question("a", at: 200)],
                 fold: [row("user:3", at: 400)], records: [question("a", at: 200), question("b", at: 500)]),
        Scenario(description: "a fold of hidden messages only has no rows",
                 before: [row("user:1", at: 100)], placedBefore: [question("a", at: 150)], fold: [], records: [question("a", at: 150), notice("x", at: 160)]),
        Scenario(description: "the first rows of a thread with a record already waiting",
                 before: [], placedBefore: [question("a", at: 50)],
                 fold: [row("user:1", at: 100), row("assistant:2", "assistant", at: 200)], records: [question("a", at: 50)]),
    ]

    @Test(arguments: scenarios)
    func recordsAfterTheLastRowPlaceAsTheWholeInterleaveDoes(_ scenario: Scenario) {
        // What a whole read gave before: the records interleaved into pi's rows.
        let history = State.interleave(scenario.placedBefore, into: scenario.before)
        let result = Self.folded(history, records: scenario.records, appending: scenario.fold)
        let whole = State.interleave(scenario.records, into: scenario.before + scenario.fold)
        #expect(!result.late)
        #expect(result.history.map(\.entryID) == whole.map(\.entryID), "\(scenario)")
    }

    @Test func aRecordAtOrBeforeTheLatestStartIsLate() {
        let history = [Self.row("user:1", at: 100), Self.row("assistant:2", "assistant", at: 300)]
        for time in [300.0, 250, 100] {
            let result = Self.folded(history, records: [Self.question("a", at: time)], appending: [Self.row("user:3", at: 400)])
            #expect(result.late, "a question that ended at \(time) belongs among rows history holds")
            #expect(result.newIDs.isEmpty, "only a whole read places it")
        }
        let onTime = Self.folded(history, records: [Self.question("a", at: 301)], appending: [Self.row("user:3", at: 400)])
        #expect(!onTime.late && onTime.newIDs == ["q:a"])
    }

    @Test func aRecordThatHistoryHoldsButTheThreadNoLongerKeepsIsLate() {
        let history = State.interleave([Self.question("old", at: 150)], into: [Self.row("user:1", at: 100), Self.row("assistant:2", "assistant", at: 200)])
        let placed: Set<String> = ["q:old"]
        let gone = State.recordNeeds(in: history, records: [], placed: placed, maxStart: 200)
        #expect(gone.late, "evicted past the limit: the row is still in history until a whole read")
        let kept = State.recordNeeds(in: history, records: [Self.question("old", at: 150)], placed: placed, maxStart: 200)
        #expect(!kept.late && kept.wanted.isEmpty && !kept.hasNew)
    }

    /// After a restart the questions the origin store kept come back beside a history that starts at a compaction's summary: one that
    /// ended before the first kept row is left out by the placement, and is not a new record for the folds that follow.
    @Test func aRecordTheCompactionLeftBehindIsNotNewToTheNextFold() {
        let summary = NativeThreadMessage(entryID: "m:2", role: "compactionSummary", blocks: [], timestamp: 900)
        let projected = [Self.row("user:500", at: 500), Self.row("assistant:600", "assistant", at: 600), summary]
        let records = [Self.question("old", at: 100)]
        let history = State.interleave(records, into: projected)
        #expect(history.count == projected.count, "the record went with what was summarized")
        let handled = State.handledRecordIDs(records)
        #expect(handled == ["q:old"])
        let needs = State.recordNeeds(in: history, records: records, placed: handled, maxStart: 900)
        #expect(!needs.hasNew && !needs.late && needs.wanted.isEmpty, "nothing to read for it, at every turn end")
        let unhandled = State.recordNeeds(in: history, records: records, placed: [], maxStart: 900)
        #expect(unhandled.late, "counted as new, it would read the history whole each time")
    }

    @Test func recordsAtTheEndAreWantedAgainOnlyForTheRowsAfterThem() {
        let history = State.interleave([Self.question("a", at: 300)], into: [Self.row("user:1", at: 100)])
        let placed: Set<String> = ["q:a"]
        let needs = State.recordNeeds(in: history, records: [Self.question("a", at: 300)], placed: placed, maxStart: 100)
        #expect(needs.trailingStart == 1 && needs.trailingIDs == ["q:a"])
        #expect(needs.wanted.map(\.row.entryID) == ["q:a"] && !needs.hasNew, "re-placed with a fold, but nothing to do alone")
    }

    // MARK: - What a whole read lacks

    private static func message(_ role: String, _ text: String, at time: Double? = nil, call: String? = nil, custom: String? = nil) -> RPCMessage {
        RPCMessage(role: role, content: [.text(text)], toolCallId: call, timestamp: time, customType: custom)
    }

    @Test func unreadKeepsTheSuffixTheAnswerLacks() {
        let old = (0..<100).map { Self.message("user", "old \($0)", at: Double($0)) }
        let a = Self.message("assistant", "one", at: 1000), b = Self.message("toolResult", "two", at: 1001, call: "c"), c = Self.message("assistant", "three", at: 1002)
        #expect(State.unread([], in: old).isEmpty)
        #expect(State.unread([a, b, c], in: old + [a, b, c]).isEmpty, "the answer holds them all")
        #expect(State.unread([a, b, c], in: old + [a, b]) == [c], "a message saved after the answer was written")
        #expect(State.unread([a, b, c], in: old + [a]) == [b, c])
        #expect(State.unread([a, b, c], in: old) == [a, b, c])
        #expect(State.unread([a, b, c], in: old + [a, c]) == [b, c], "a missing message makes every later one extra, even one the answer holds")
    }

    @Test func unreadCountsRepeatsAndIgnoresACustomMessagesTime() {
        let same = Self.message("user", "again", at: 5)
        #expect(State.unread([same, same], in: [same]) == [same], "two saved in one millisecond, one in the answer")
        #expect(State.unread([same, same], in: [same, same]).isEmpty)
        let event = Self.message("custom", "report", at: 10, custom: "stub-report")
        let listed = Self.message("custom", "report", at: 99, custom: "stub-report")
        #expect(State.unread([event], in: [listed]).isEmpty, "pi lists a custom message with the time it saved it")
        #expect(State.unread([event], in: [Self.message("custom", "other", at: 99, custom: "stub-report")]) == [event])
        #expect(State.unread([event], in: [Self.message("custom", "report", at: 99, custom: "other-kind")]) == [event])
        #expect(State.unread([Self.message("user", "x", at: 1)], in: [Self.message("user", "x", at: 2)]).count == 1, "other roles match their time")
    }

    @Test func unreadLooksOnlyAtTheEndOfTheAnswer() {
        let early = Self.message("user", "twin", at: 1)
        let filler = (0..<200).map { Self.message("assistant", "filler \($0)", at: Double(10 + $0)) }
        #expect(State.unread([early], in: [early] + filler) == [early], "an equal message long before the end is not the one pending")
    }

    // MARK: - pi's count

    @Test func savedMessageCountsReadPiStats() throws {
        let full = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"totalMessages":7,"userMessages":2,"assistantMessages":3,"toolResults":1,"toolCalls":4}"#.utf8))
        var counts = try #require(State.SavedMessageCounts(stats: full))
        #expect(counts.total == 7 && counts.user == 2 && counts.assistant == 3 && counts.toolResults == 1)
        let partial = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"totalMessages":7,"userMessages":2}"#.utf8))
        #expect(State.SavedMessageCounts(stats: partial) == nil, "an engine that does not count leaves the events alone")
        #expect(State.SavedMessageCounts(stats: .null) == nil)

        for role in ["user", "assistant", "assistant", "toolResult", "system"] { counts.add(role: role) }
        #expect(counts.total == 12 && counts.user == 3 && counts.assistant == 5 && counts.toolResults == 2, "system counts in the total only")
        let difference = counts - State.SavedMessageCounts(stats: full)!
        #expect(difference.total == 5 && difference.user == 1 && difference.assistant == 2 && difference.toolResults == 1)
    }

    @Test func countsDisagreeWhenEitherSideSavedMore() {
        func counts(_ total: Int, _ user: Int, _ assistant: Int, _ results: Int) -> State.SavedMessageCounts {
            var value = State.SavedMessageCounts()
            value.total = total; value.user = user; value.assistant = assistant; value.toolResults = results
            return value
        }
        #expect(!State.countsDisagree(piDelta: counts(3, 1, 1, 1), hostDelta: counts(3, 1, 1, 1)))
        #expect(State.countsDisagree(piDelta: counts(4, 1, 2, 1), hostDelta: counts(3, 1, 1, 1)), "pi saved a message no event announced")
        #expect(State.countsDisagree(piDelta: counts(3, 1, 1, 1), hostDelta: counts(4, 1, 2, 1)), "an event repeated a saved message")
        #expect(State.countsDisagree(piDelta: counts(3, 1, 1, 1), hostDelta: counts(3, 2, 0, 1)), "the same total, a different message")
    }

    // MARK: - Live rows

    private typealias Live = State.LiveItem

    private static func live(_ kind: Live.Kind, _ id: String, role: String, status: String? = nil, time: Double? = nil, ended: Bool = true) -> Live {
        // The rows of messages pi sent keep them whole (`raw`); a tool call's row keeps none.
        let raw: RPCMessage? = switch kind {
        case .user, .assistant: RPCMessage(role: role, content: [], timestamp: time)
        default: nil
        }
        return Live(kind: kind, value: NativeThreadMessage(entryID: id, role: role, blocks: [], status: status, timestamp: time),
                    raw: raw, ended: ended)
    }

    private static func ids(_ live: [Live], leaving indexes: [Int]) -> [String] { indexes.map { live[$0].value.entryID } }

    @Test func liveRowsLeavingAFold() {
        let nested = RPCNestedCalls.decoded(#"{"complete":true,"calls":[{"id":"script/1","name":"read","status":"ok"},{"id":"script/2","name":"read","status":"ok"}]}"#)
        let folded = [
            RPCMessage(role: "user", content: [.text("hi")], timestamp: 100),
            RPCMessage(role: "assistant", content: [.text("a")], timestamp: 200),
            RPCMessage(role: "toolResult", content: [], toolCallId: "call", timestamp: 250),
            RPCMessage(role: "toolResult", content: [], toolCallId: "script", timestamp: 260, nestedCalls: nested),
        ]
        let rows = [Self.row("user:100", "user", at: 100), Self.row("assistant:200", "assistant", at: 200)]
        let live: [Live] = [
            Self.live(.user, "user:100", role: "user", time: 100),
            Self.live(.user, "user:999", role: "user", time: 999),
            Self.live(.user, "user:100#1", role: "user", time: 100, ended: false),
            Self.live(.assistant(1), "provisional:assistant:1", role: "assistant", status: "stop", time: 200),
            Self.live(.assistant(2), "provisional:assistant:2", role: "assistant", status: "streaming", time: 300, ended: false),
            Self.live(.tool("call"), "provisional:tool:call", role: "toolResult", status: "complete"),
            Self.live(.tool("script"), "provisional:tool:script", role: "toolResult", status: "complete"),
            Self.live(.tool("script/1"), "provisional:tool:script/1", role: "toolResult", status: "complete"),
            Self.live(.tool("deep/1"), "provisional:tool:deep/1", role: "toolResult", status: "complete"),
            Self.live(.tool("script/2/x"), "provisional:tool:script/2/x", role: "toolResult", status: "complete"),
            Self.live(.tool("other"), "provisional:tool:other", role: "toolResult", status: "complete"),
            Self.live(.tool("running"), "provisional:tool:running", role: "toolResult", status: "running"),
            Self.live(.question("a"), "q:a", role: "question"),
            Self.live(.question("b"), "q:b", role: "question"),
            Self.live(.notice(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), "n:00000000-0000-0000-0000-000000000001", role: "custom"),
            Self.live(.pending(UUID()), "pending:1", role: "user", ended: false),
            Self.live(.compaction("c"), "compaction:c", role: "compaction"),
        ]
        let leaving = State.liveRowsLeaving(live, folded: folded, rows: rows, placedRecordIDs: ["q:a", "n:00000000-0000-0000-0000-000000000001"],
                                            parents: ["script/1": "script", "deep/1": "script/2", "script/2/x": "script/2", "script/2": "script"])
        #expect(Self.ids(live, leaving: leaving) == [
            "user:100", "provisional:assistant:1", "provisional:tool:call", "provisional:tool:script", "provisional:tool:script/1",
            "provisional:tool:deep/1", "provisional:tool:script/2/x", "q:a", "n:00000000-0000-0000-0000-000000000001",
        ], "a user by its id, an assistant by its time, a call by its result or its script's; a running, unfinished, unplaced or pending row stays")
        #expect(leaving == leaving.sorted())
    }

    @Test func untimedMessagesPairInOrderWithTheLiveRowsAndNeverMatchOnANilTime() {
        let folded = [RPCMessage(role: "user", content: [.text("x")]), RPCMessage(role: "assistant", content: [.text("y")])]
        let live: [Live] = [
            Self.live(.user, "provisional:user:1", role: "user"),
            Self.live(.user, "provisional:user:2", role: "user"),
            Self.live(.assistant(1), "provisional:assistant:1", role: "assistant", status: "stop"),
            Self.live(.assistant(2), "provisional:assistant:2", role: "assistant", status: "stop"),
        ]
        let leaving = State.liveRowsLeaving(live, folded: folded, rows: [], placedRecordIDs: [], parents: [:])
        #expect(Self.ids(live, leaving: leaving) == ["provisional:user:1", "provisional:assistant:1"], "one folded message takes one row")
        let timed = [RPCMessage(role: "user", content: [.text("x")], timestamp: 5)]
        #expect(State.liveRowsLeaving(live, folded: timed, rows: [], placedRecordIDs: [], parents: [:]).isEmpty, "a timed message takes no untimed row")
    }

    @Test func aNestedCallLeavesOnlyWhenItsAncestorsResultFolds() {
        let live: [Live] = [Self.live(.tool("a/1"), "provisional:tool:a/1", role: "toolResult", status: "complete")]
        let parents = (1...9).reduce(into: [String: String]()) { $0["a/\($1)"] = "a/\($1 + 1)" }
        let near = RPCMessage(role: "toolResult", content: [], toolCallId: "a/3")
        let far = RPCMessage(role: "toolResult", content: [], toolCallId: "a/10")
        #expect(State.liveRowsLeaving(live, folded: [near], rows: [], placedRecordIDs: [], parents: parents) == [0])
        #expect(State.liveRowsLeaving(live, folded: [far], rows: [], placedRecordIDs: [], parents: parents).isEmpty, "up to eight levels")
    }

    // MARK: - Bytes

    @Test func approximateBytesCountsTextImagesAndArguments() {
        let arguments: JSONValue = .object(["command": .string("make test")])
        let message = RPCMessage(role: "assistant", content: [
            .text(String(repeating: "t", count: 100)), .thinking(String(repeating: "h", count: 50)),
            .image(mimeType: "image/png", data: String(repeating: "A", count: 4000)),
            .toolCall(id: "c", name: "bash", arguments: arguments), .unknown(type: "weird"),
        ])
        let bytes = State.approximateBytes(message)
        #expect(bytes >= 4150 + State.jsonLength(arguments) && bytes < 4150 + State.jsonLength(arguments) + 64)
        #expect(State.approximateBytes(RPCMessage(role: "user", content: [])) == 0)
        let small = State.approximateBytes(RPCMessage(role: "user", content: [.text("hi")]))
        #expect(small == 2)
    }
}

private extension RPCNestedCalls {
    static func decoded(_ json: String) -> RPCNestedCalls {
        try! JSONDecoder().decode(RPCNestedCalls.self, from: Data(json.utf8))
    }
}
