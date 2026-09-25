import Testing
@testable import ShepherdUI

/// The question head names who asks: the agent itself, or a subagent by name.
@Suite("Question head")
struct QuestionHeadTests {
    @Test(arguments: [
        (NWQuestionAsker.agent, "Agent is asking"),
        (.subagent("reviewer"), "reviewer is asking"),
        (.subagent("  planner \n"), "planner is asking"),
        (.subagent(""), "Subagent is asking"),
    ])
    func theHeadNamesTheAsker(asker: NWQuestionAsker, title: String) {
        #expect(asker.title == title)
    }
}
