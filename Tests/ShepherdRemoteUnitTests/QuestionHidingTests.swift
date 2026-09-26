import Testing
import ShepherdRemote

/// Hiding pi's question: it shrinks to its line until shown again, and only that question stays
/// hidden.
@Suite("Question hiding")
struct QuestionHidingTests {
    @Test func aQuestionArrivesOpen() {
        let hiding = NativeQuestionHiding()
        #expect(!hiding.isHidden("session:ask"))
        #expect(!hiding.isHidden(nil))
    }

    @Test func hidingKeepsTheQuestionHiddenUntilItIsShown() {
        var hiding = NativeQuestionHiding()
        hiding.hide("session:ask")
        #expect(hiding.isHidden("session:ask"))
        hiding.show()
        #expect(!hiding.isHidden("session:ask"))
    }

    @Test(arguments: ["session:next", "resumed:ask"])
    func theNextQuestionArrivesOpenAfterOneWasHidden(next: String) {
        var hiding = NativeQuestionHiding()
        hiding.hide("session:ask")
        #expect(!hiding.isHidden(next))
    }

    @Test func noQuestionIsNeverHidden() {
        var hiding = NativeQuestionHiding()
        hiding.hide("session:ask")
        #expect(!hiding.isHidden(nil))
    }
}
