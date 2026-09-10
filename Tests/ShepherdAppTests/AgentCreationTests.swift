import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

@Suite("Agent creation")
@MainActor
struct AgentCreationTests {
    @Test func baseResolutionIdentityChangesEvenWhenHostsUseTheSameDirectory() {
        let first = NewAgentBaseTarget(hostID: UUID(), spaceID: SpaceID(), cwd: "/repo", worktree: true)
        var second = first
        second.hostID = UUID()
        #expect(first != second)
        second.hostID = first.hostID
        #expect(first == second)
        second.worktree = false
        #expect(first != second)
    }

    @Test func delayedDefaultsPreserveEditsAndRejectPreviousHostResults() {
        var defaults = NewAgentTargetDefaults()
        let firstHost = UUID()
        let first = defaults.begin(hostID: firstHost, model: "", thinking: .medium)
        #expect(defaults.loading && !defaults.ready)
        defaults.model = "chosen/model"
        defaults.modelEdited = true
        defaults.thinking = .high
        defaults.thinkingEdited = true
        defaults.apply(requestID: first, model: "host/default", thinking: .low)
        #expect(defaults.ready && !defaults.loading)
        #expect(defaults.model == "chosen/model")
        #expect(defaults.thinking == .high)

        let secondHost = UUID()
        let second = defaults.begin(hostID: secondHost, model: "", thinking: .medium)
        #expect(!defaults.ready)
        defaults.apply(requestID: first, model: "stale", thinking: .low)
        #expect(defaults.loading && defaults.model.isEmpty)
        defaults.fail(requestID: second)
        #expect(!defaults.loading && !defaults.ready)
        let retry = defaults.begin(hostID: secondHost, model: "", thinking: .medium)
        defaults.apply(requestID: retry, model: "second/default", thinking: .high)
        #expect(defaults.ready && defaults.model == "second/default")

        _ = defaults.begin(hostID: nil, model: "local/default", thinking: .low)
        defaults.apply(requestID: retry, model: "late remote", thinking: .high)
        #expect(defaults.hostID == nil && defaults.ready && !defaults.loading)
        #expect(defaults.model == "local/default")
        #expect(defaults.thinking == .low)
    }

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
