import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A new agent's opening prompt, drawn by the client that created the agent while pi starts:
/// the same row the host's first snapshot carries, so nothing moves when it lands.
@Suite("Opening prompt")
struct OpeningPromptTests {
    private static let agent = AgentID(rawValue: "3f0c9a52-6d1e-4b7a-9c3e-1a2b3c4d5e6f")

    @Test(arguments: [nil, "", "  \n"] as [String?])
    func aBlankPromptIsNeverSent(text: String?) {
        #expect(OpeningPrompt(text, agentID: Self.agent) == nil)
    }

    /// Its send is named after the agent, so every client that knows the agent names it alike.
    @Test func itsSendIsNamedAfterItsAgent() throws {
        let prompt = try #require(OpeningPrompt("Fix the build", agentID: Self.agent))
        #expect(prompt.operationID == UUID(uuidString: Self.agent.rawValue))
        #expect(OpeningPrompt("Fix the build", agentID: Self.agent) == prompt)
    }

    @Test func thePreviewIsTheHostsPendingRowAndNothingElse() throws {
        let prompt = try #require(OpeningPrompt("Fix the build", agentID: Self.agent))
        let preview = prompt.preview(model: "anthropic/claude-sonnet", thinking: "medium", at: 1_000)
        #expect(preview.messages.isEmpty)
        #expect(preview.provisional == [NativeThreadMessage.pendingSend(operationID: prompt.operationID, text: "Fix the build",
                                                                         images: 0, timestamp: 1_000)])
        let row = try #require(preview.provisional.first)
        #expect(row.entryID == "pending:\(prompt.operationID.uuidString)" && row.status == "pending" && row.role == "user")
        #expect(preview.model == "anthropic/claude-sonnet" && preview.thinking == "medium" && !preview.running)
    }

    /// Over a thread the client already drew (a new agent's known-empty one), only the row is added.
    @Test func aPreviewKeepsWhatTheClientAlreadyKnew() throws {
        let prompt = try #require(OpeningPrompt("Fix the build", agentID: Self.agent))
        let empty = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 0, running: false, model: "m",
                                         supportedActions: ["send"], dialogsSupported: true, dialogs: [], messages: [],
                                         provisional: [], clipped: false, runtime: "rpc")
        var expected = empty
        expected.provisional = [prompt.pendingRow(at: 5)]
        #expect(prompt.preview(empty, at: 5) == expected)
    }
}
