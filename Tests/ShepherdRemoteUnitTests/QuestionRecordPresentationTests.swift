import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote

/// A question pi asked, as the thread draws it where pi asked (QuestionAnswered): "Agent asked:"
/// and the question, then the answer as the user's bubble.
@Suite("Question record presentation")
struct QuestionRecordPresentationTests {
    typealias F = Fixture
    static let utc = TimeZone(identifier: "UTC")!
    /// 11:09 AM UTC.
    static let answeredAt = 1_758_539_340_000.0

    static func record(_ kind: NativeThreadDialog.Kind?, answer: String? = nil, confirmed: Bool? = nil,
                       outcome: NativeQuestionRecord.Outcome = .answered, question: String = "How should I handle it?") -> NativeThreadMessage {
        NativeThreadMessage(entryID: "q:d", role: "question", blocks: [], timestamp: answeredAt,
                            question: NativeQuestionRecord(kind: kind, question: question, answer: answer, confirmed: confirmed,
                                                           outcome: outcome, askedAt: answeredAt - 60_000))
    }

    static func row(_ message: NativeThreadMessage) -> NativeQuestionRecordRow {
        NativeQuestionRecordRow(entryID: message.entryID, record: message.question!, endedAt: message.timestamp)
    }

    static let answers: [(NativeThreadMessage, String?, String?)] = [
        // A select shows the option's title, without its description or "(Recommended)".
        (record(.select, answer: "Compare, keep what's unique (Recommended)\nNew branch and PR."), "Compare, keep what's unique", nil),
        (record(.select, answer: "Leave it"), "Leave it", nil),
        (record(.confirm, confirmed: true), "Yes", nil),
        (record(.confirm, confirmed: false), "No", nil),
        // Typed answers are the user's own words, not a title.
        (record(.input, answer: "release/2026-09"), nil, "release/2026-09"),
        (record(.editor, answer: "line one\nline two"), nil, "line one\nline two"),
        (record(.input, answer: "  "), nil, "An empty answer"),
        (record(nil, answer: "from a newer kind"), nil, "from a newer kind"),
    ]

    @Test(arguments: answers)
    func anAnswerIsTheBubble(message: NativeThreadMessage, title: String?, text: String?) {
        let row = Self.row(message)
        #expect(row.answered && row.title == title && row.text == text)
        #expect(row.question == "How should I handle it?")
        #expect(row.caption(timeZone: Self.utc) == "11:09 AM · answered")
        #expect(row.accessibilityLabel.hasPrefix("Agent asked: How should I handle it?, you answered: "))
    }

    @Test(arguments: [NativeQuestionRecord.Outcome.dismissed, .expired, .unknown])
    func aQuestionNobodyAnsweredHasNoBubble(outcome: NativeQuestionRecord.Outcome) {
        let row = Self.row(Self.record(.select, outcome: outcome))
        #expect(!row.answered && row.title == nil && row.text == nil && row.caption() == nil)
        #expect(row.accessibilityLabel == "Agent asked: How should I handle it?, not answered")
    }

    @Test func aQuestionWithNoWordsStillReadsAsOne() {
        #expect(Self.row(Self.record(.select, answer: "A", question: "  ")).question == "A question")
    }

    /// The record sits in the agent's turn where pi asked: after the call that asked, before
    /// pi's next reply. It is the answer's time, not pi's work: the turn ends when pi's last
    /// message landed.
    @Test func theRecordIsATurnItemWherePiAsked() {
        var ask = F.tool("ask_user", callID: "c1", timestamp: 1_000)
        ask.startedAt = 500
        var reply = F.assistant("Going with it")
        reply.timestamp = 2_000
        var question = Self.record(.select, answer: "Leave it")
        question.timestamp = 5_000
        let messages = [F.user(), ask, question, reply]
        let turns = nativeTurns(messages)
        #expect(turns.map(\.isUser) == [true, false], "one agent turn holds the record")
        let presentation = nativeTurnPresentation(turns[1].messages, live: false)
        let kinds = presentation.items.map { item -> String in
            switch item {
            case .activity: "lines"
            case .question(let row): "question:" + (row.title ?? "")
            case .prose: "prose"
            default: "other"
            }
        }
        #expect(kinds == ["lines", "question:Leave it", "prose"])
        #expect(presentation.endedAt == 2_000)
        #expect(presentation.copyText == "Going with it", "Copy takes the agent's words only")
    }
}
