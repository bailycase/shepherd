import Testing
@testable import ShepherdApp

@Suite("Directory completion")
struct DirectoryCompletionTests {
    @Test func ambiguousMatchesCompleteOnlyToTheirSharedPrefix() {
        let matches = ["ms-graphql-external", "ms-graphql-internal"]

        #expect(DirectoryCompletion.component(for: "ms-g", matches: matches) == "ms-graphql-")
        #expect(DirectoryCompletion.component(for: "ms-graphql-", matches: matches) == "ms-graphql-")
    }

    @Test func uniqueMatchCompletesFully() {
        #expect(DirectoryCompletion.component(
            for: "proj",
            matches: ["Projects"]
        ) == "Projects")
    }
}
