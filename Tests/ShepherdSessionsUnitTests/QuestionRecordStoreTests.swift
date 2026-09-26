import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// pi's questions as the host keeps them (QuestionAnswered): in the session's origins file, and
/// placed into pi's history where pi asked.
@Suite("Question records on the host")
struct QuestionRecordStoreTests {
    typealias Question = ThreadOriginStore.Question

    static func question(_ id: String, endedAt: Double, outcome: NativeQuestionRecord.Outcome = .answered) -> Question {
        Question(id: id, record: NativeQuestionRecord(kind: .select, question: "Which way?", answer: outcome == .answered ? "Left" : nil,
                                                      outcome: outcome, askedAt: endedAt - 5),
                 endedAt: endedAt)
    }

    static func row(_ id: String, _ role: String, at time: Double?, startedAt: Double? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [], timestamp: time, startedAt: startedAt)
    }

    /// A turn where an `ask_user` call (started with its assistant message at 20) asked, and pi
    /// replied at 40; its result landed at 35.
    static let turn = [
        row("user:10", "user", at: 10),
        row("assistant:20", "assistant", at: 20),
        row("t:call", "toolResult", at: 35, startedAt: 20),
        row("assistant:40", "assistant", at: 40),
    ]

    @Test(arguments: [
        (30.0, ["user:10", "assistant:20", "t:call", "q:a", "assistant:40"]),
        (40.0, ["user:10", "assistant:20", "t:call", "q:a", "assistant:40"]),
        (50.0, ["user:10", "assistant:20", "t:call", "assistant:40", "q:a"]),
        (5.0, ["q:a", "user:10", "assistant:20", "t:call", "assistant:40"]),
    ])
    func aQuestionGoesBeforeTheFirstMessageThatStartedOnceItEnded(endedAt: Double, order: [String]) {
        let placed = RPCThreadState.interleave([Self.question("a", endedAt: endedAt)], into: Self.turn)
        #expect(placed.map(\.entryID) == order)
        let record = placed.first { $0.role == "question" }
        #expect(record?.timestamp == endedAt && record?.question?.answer == "Left" && record?.blocks.isEmpty == true)
    }

    @Test func questionsKeepTheOrderTheyEndedIn() {
        let placed = RPCThreadState.interleave([Self.question("b", endedAt: 32), Self.question("a", endedAt: 31)], into: Self.turn)
        #expect(placed.map(\.entryID) == ["user:10", "assistant:20", "t:call", "q:a", "q:b", "assistant:40"])
    }

    /// After a compaction pi lists only what it kept: a question from before went with what
    /// was summarized.
    @Test func aQuestionBeforeACompactionsKeptMessagesIsLeftOut() {
        let compacted = [Self.row("assistant:20", "assistant", at: 20), Self.row("compactionSummary:60", "compactionSummary", at: 60)]
        let placed = RPCThreadState.interleave([Self.question("old", endedAt: 5), Self.question("new", endedAt: 70)], into: compacted)
        #expect(placed.map(\.entryID) == ["assistant:20", "compactionSummary:60", "q:new"])
    }

    @Test func questionsRoundTripBesideTheOrigins() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadOriginStore(directory: dir)
        let steered = try #require(ThreadOriginStore.Record(.steered))
        let questions = [Self.question("a", endedAt: 30), Self.question("b", endedAt: 40, outcome: .expired)]
        store.save(sessionID: "s", records: [("user:1", steered)], questions: questions)
        store.flush()
        #expect(store.loadQuestions(sessionID: "s") == questions)
        #expect(store.load(sessionID: "s").map(\.id) == ["user:1"])
        #expect(store.loadQuestions(sessionID: "other").isEmpty)
    }

    @Test func onlyTheNewestQuestionsAreKept() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThreadOriginStore(directory: dir)
        store.save(sessionID: "s", records: [], questions: (0..<(ThreadOriginStore.questionLimit + 2)).map {
            Self.question("\($0)", endedAt: Double($0))
        })
        store.flush()
        let loaded = store.loadQuestions(sessionID: "s")
        #expect(loaded.count == ThreadOriginStore.questionLimit && loaded.first?.id == "2")
    }

    /// A file written before questions were kept still loads its origins, with no questions.
    @Test func anOlderFileHasNoQuestions() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"version":1,"entries":[{"id":"user:1","record":{"steered":true}}]}"#.utf8)
            .write(to: dir.appendingPathComponent("s.json"))
        let store = ThreadOriginStore(directory: dir)
        #expect(store.load(sessionID: "s").map(\.id) == ["user:1"])
        #expect(store.loadQuestions(sessionID: "s").isEmpty)
    }
}
