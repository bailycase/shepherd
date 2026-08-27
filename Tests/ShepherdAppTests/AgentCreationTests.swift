import ShepherdCore
import Testing
@testable import ShepherdApp

@Suite("Agent creation")
@MainActor
struct AgentCreationTests {
    @Test func quickCreateUsesTheSpaceCheckout() {
        let space = Space(
            name: "Shepherd",
            path: "/tmp/Shepherd"
        )

        let config = ShepherdViewModel.quickAgentConfig(for: space)

        #expect(config.spaceID == space.id)
        #expect(config.workingDirectory == space.path)
        #expect(config.model == nil)
        #expect(config.thinking == .medium)
        #expect(config.initialPrompt == nil)
    }

    /// The provisional name is what the sidebar shows until pi's namer lands a
    /// real title, so it must stay short and single-line.
    @Test func provisionalNameUsesTheOpeningPrompt() {
        #expect(ShepherdViewModel.provisionalName(for: "fix the sidebar") == "fix the sidebar")
    }

    @Test func provisionalNameCollapsesWhitespace() {
        let name = ShepherdViewModel.provisionalName(for: "  fix   the\nsidebar\t ")
        #expect(name == "fix the sidebar")
    }

    @Test func provisionalNameTruncatesOnAWordBoundary() {
        let prompt = String(repeating: "alpha ", count: 20)
        let name = ShepherdViewModel.provisionalName(for: prompt)
        #expect(name.count <= 49)
        #expect(name.hasSuffix("…"))
        #expect(!name.contains("alph…"))
    }

    /// ⌘N agents have no prompt yet; they start as "New agent".
    @Test func provisionalNameFallsBackToNewAgent() {
        for prompt in [nil, "", "   \n  "] as [String?] {
            #expect(ShepherdViewModel.provisionalName(for: prompt) == "New agent")
        }
    }
}
