import Testing
@testable import ShepherdApp

/// Hiding pi's question: it shrinks to its line until shown again, and only that question stays
/// hidden.
@Suite("Question hiding")
struct QuestionHidingTests {
    @Test func aQuestionArrivesOpen() {
        let hiding = QuestionHiding()
        #expect(!hiding.isHidden("session:ask"))
        #expect(!hiding.isHidden(nil))
    }

    @Test func hidingKeepsTheQuestionHiddenUntilItIsShown() {
        var hiding = QuestionHiding()
        hiding.hide("session:ask")
        #expect(hiding.isHidden("session:ask"))
        hiding.show()
        #expect(!hiding.isHidden("session:ask"))
    }

    @Test(arguments: ["session:next", "resumed:ask"])
    func theNextQuestionArrivesOpenAfterOneWasHidden(next: String) {
        var hiding = QuestionHiding()
        hiding.hide("session:ask")
        #expect(!hiding.isHidden(next))
    }

    @Test func noQuestionIsNeverHidden() {
        var hiding = QuestionHiding()
        hiding.hide("session:ask")
        #expect(!hiding.isHidden(nil))
    }
}
