import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Experiments ▸ Suggested instructions against a real server: an agent's
/// `suggest_instruction` over the extension socket is taken only while the experiment allows it,
/// and a remote client adds, dismisses and undoes the host's suggestions.
@Suite("Suggested instructions", .integrationTimeLimit)
struct SuggestionsTests {
    /// A thread and an automation's run in one space.
    private func workspace(_ h: ScratchServer) async throws -> (thread: Agent, run: Agent) {
        let space = Fixture.space()
        let thread = Fixture.agent(in: space, name: "Fix flaky ledger test")
        let run = Fixture.agent(in: space, name: "Nightly dependency bump")
        var state = Fixture.workspace([thread, run], space: space)
        var automation = Automation(name: "Nightly dependency bump", prompt: "Bump the dependencies.", cwd: space.path, enabled: true)
        automation.agentID = run.agent.id
        state.automations = [automation]
        try await h.seed(state)
        return (thread.agent, run.agent)
    }

    @Test func anAgentSuggestsOnlyWhileTheExperimentAllowsIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (thread, run) = try await workspace(h)
        let heard = Locked<[SuggestionsSnapshot]>([])
        h.server.onSuggestionsChanged = { snapshot in heard.withValue { $0.append(snapshot) } }
        let agent = try ExtensionClient(path: h.socketPath)

        // Off until the user turns it on.
        try agent.send(.suggestInstruction(id: 1, agentID: thread.id, line: "Ask for join keys first.", reason: "Two services re-ran.", file: nil))
        guard case .error(1, "suggestions_off", _) = try await agent.reply() else { Issue.record("taken while off"); return }

        try h.server.suggestions.configure(SuggestedInstructionsSettings(enabled: true, sources: [.thread], files: [.agents]))
        try agent.send(.suggestInstruction(id: 2, agentID: thread.id, line: "Ask for join keys first.", reason: "Two services re-ran.", file: nil))
        #expect(try await agent.reply() == .suggestion(id: 2, outcome: .waiting))
        try agent.send(.suggestInstruction(id: 3, agentID: thread.id, line: "- ask for join keys first", reason: "Again.", file: nil))
        #expect(try await agent.reply() == .suggestion(id: 3, outcome: .alreadyWaiting))

        // Automations don't learn here, APPEND_SYSTEM.md is off, and a suggestion is one line.
        try agent.send(.suggestInstruction(id: 4, agentID: run.id, line: "Run go mod tidy.", reason: "CI failed.", file: nil))
        guard case .error(4, "suggestions_off", _) = try await agent.reply() else { Issue.record("an automation suggested"); return }
        try agent.send(.suggestInstruction(id: 5, agentID: thread.id, line: "Never force-push.", reason: "", file: .appendSystem))
        guard case .error(5, "suggestions_off", _) = try await agent.reply() else { Issue.record("APPEND_SYSTEM.md was taken"); return }
        try agent.send(.suggestInstruction(id: 6, agentID: thread.id, line: "- One.\n- Two.", reason: "", file: nil))
        guard case .error(6, "invalid", _) = try await agent.reply() else { Issue.record("two lines were taken"); return }
        try agent.send(.suggestInstruction(id: 7, agentID: AgentID(), line: "Anything.", reason: "", file: nil))
        guard case .error(7, "no_such_agent", _) = try await agent.reply() else { Issue.record("a stranger suggested"); return }

        let waiting = h.server.suggestions.snapshot().waiting
        #expect(waiting.map(\.line) == ["- Ask for join keys first."])
        #expect(waiting.first?.reason == "Two services re-ran.")
        #expect(waiting.first?.source == SuggestionSource(kind: .thread, name: "Fix flaky ledger test"))
        // Nothing is written until the user adds it.
        #expect(h.server.instructions.snapshot().agents.isEmpty)
        try await eventually("the GUI to hear the one suggestion") { heard.current.map(\.waiting.count) == [1] }
    }

    @Test func anAutomationsSuggestionNamesItsRun() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (_, run) = try await workspace(h)
        try h.server.suggestions.configure(SuggestedInstructionsSettings(enabled: true, sources: [.automation], files: [.appendSystem]))
        let agent = try ExtensionClient(path: h.socketPath)

        try agent.send(.suggestInstruction(id: 1, agentID: run.id, line: "Run `go mod tidy` with any dependency bump.",
                                           reason: "CI failed twice on a stale go.sum.", file: .appendSystem))

        #expect(try await agent.reply() == .suggestion(id: 1, outcome: .waiting))
        let suggestion = try #require(h.server.suggestions.snapshot().waiting.first)
        #expect(suggestion.source == SuggestionSource(kind: .automation, name: "Nightly dependency bump"))
        #expect(suggestion.file == .appendSystem)
    }

    @Test func aRemoteClientActsOnTheHostsSuggestions() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let heard = Locked<Int>(0)
        host.server.onInstructionsChanged = { _ in heard.withValue { $0 += 1 } }
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.suggestionsCapability))

        let on = try await client.suggestions(.configure(SuggestedInstructionsSettings(enabled: true)))
        #expect(on.settings.enabled && on.settings.since != nil)
        let source = SuggestionSource(kind: .thread, name: "Checkout funnel events")
        _ = try host.server.suggestions.suggest(line: "Ask for join keys.", reason: "Two services re-ran.", file: .agents, source: source)
        _ = try host.server.suggestions.suggest(line: "Never skip a flaky test.", reason: "You corrected it.", file: .agents, source: source)

        let fetched = try await client.suggestions()
        #expect(fetched.waiting.map(\.line) == ["- Never skip a flaky test.", "- Ask for join keys."])
        let added = try await client.suggestions(.add(id: fetched.waiting[1].id, line: "Ask for join keys before adding an event.", file: nil))
        #expect(host.server.instructions.snapshot().agents == "- Ask for join keys before adding an event.\n")
        let dismissed = try await client.suggestions(.dismiss(id: fetched.waiting[0].id))
        #expect(dismissed.waiting.isEmpty)
        let undone = try await client.suggestions(.undo(id: try #require(added.added.first?.id)))
        #expect(undone.added.isEmpty)
        #expect(host.server.instructions.snapshot().agents.isEmpty)
        try await eventually("the GUI to hear both changes to the file") { heard.current == 2 }
    }

    @Test func actingOnASuggestionNoLongerWaitingIsRefused() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let raw = try await host.raw()

        try raw.send(.suggestions(id: 5, request: .dismiss(id: UUID())))

        guard case .error(5, let code, _) = try await raw.next() else { Issue.record("expected an error"); return }
        #expect(code == "no_such_suggestion")
    }
}
