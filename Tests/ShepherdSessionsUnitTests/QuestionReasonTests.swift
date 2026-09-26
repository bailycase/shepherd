import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The agent's own word or two for its question ("retention?"): read from an asking tool's
/// `short` argument, and carried by the dialog that call opens.
@Suite("Question reason")
struct QuestionReasonTests {
    /// The status extension's rule, so the tools it gives `short` are the ones read here.
    @Test(arguments: [
        ("ask_user", true), ("ask", true), ("question", true), ("human.ask", true), ("QUESTION", true),
        ("questionnaire", false), ("task", false), ("bash", false), ("askUser", false), ("shepherd_parent_message", false),
    ])
    func askingToolsAreKnownByName(name: String, asks: Bool) {
        #expect(RPCThreadState.asksUser(name) == asks)
    }

    @Test(arguments: [
        (#"{"question":"Retention?","short":"retention?"}"#, "retention?" as String?),
        (#"{"short":"  approve\n  plan "}"#, "approve plan"),
        (#"{"short":"   "}"#, nil),
        (#"{"short":3}"#, nil),
        (#"{"question":"Retention?"}"#, nil),
        (#"["retention?"]"#, nil),
    ])
    func theReasonIsTheShortArgumentAsOneLine(args: String, reason: String?) throws {
        #expect(RPCThreadState.shortReason(in: try decode(args, as: JSONValue.self)) == reason)
    }

    @Test func aLongReasonIsBounded() {
        let long = JSONValue.object(["short": .string(String(repeating: "x", count: 500))])
        #expect(RPCThreadState.shortReason(in: long)?.count == RPCThreadState.shortReasonLimit)
        #expect(RPCThreadState.shortReason(in: nil) == nil)
    }

    /// The first question with a title is asked, with its own dialog's reason or none.
    @Test func theQuestionAskedFirstCarriesItsDialogsReason() {
        let untitled = NativeThreadDialog(id: "d0", kind: .input, title: "  ")
        let retention = NativeThreadDialog(id: "d1", kind: .select, title: " Retention? ", options: ["30 days", "13 months"])
        let plan = NativeThreadDialog(id: "d2", kind: .confirm, title: "Approve the plan?")
        let reasons = ["d0": "ignored", "d1": "retention?"]
        #expect(RPCThreadState.question(in: [untitled, retention, plan], reasons: reasons)
            == RPCThreadState.AgentQuestion(title: "Retention?", reason: "retention?"))
        #expect(RPCThreadState.question(in: [plan, retention], reasons: reasons)
            == RPCThreadState.AgentQuestion(title: "Approve the plan?", reason: nil))
        #expect(RPCThreadState.question(in: [untitled], reasons: reasons) == nil)
    }
}
