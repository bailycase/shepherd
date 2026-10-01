import Testing
@testable import ShepherdUI

/// The question head says who asks. Only the agent does: a subagent asks its parent, never the
/// user, so no head names one.
@Suite("Question head")
struct QuestionHeadTests {
    @Test func everyQuestionHeadSaysTheAgentIsAsking() {
        #expect(NWQuestionHead.title == "Agent is asking")
    }
}
