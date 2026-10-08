import Testing
@testable import ShepherdApp

@Suite("Subagent model field")
struct SubagentModelFieldTests {
    private let ids = ["cliproxyapi/gemini-flash-2", "cliproxyapi/claude-opus-1", "openai/gpt-5"]

    @Test func anEmptyQueryListsInheritFirstThenEveryModel() {
        let options = SubagentModelField.sections(choices: ids, query: "  ", current: nil)[0].options
        #expect(options.map(\.id) == [""] + ids)
        #expect(options[0].isCurrent)
    }

    @Test func aQueryMatchesAnySubstringOfTheIdIgnoringCaseAndDropsInherit() {
        let options = SubagentModelField.sections(choices: ids, query: "GEMINI-flash", current: ids[0])[0].options
        #expect(options.map(\.id) == [ids[0]])
        #expect(options[0].isCurrent)
    }
}
