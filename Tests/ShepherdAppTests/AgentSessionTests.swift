import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// An agent starts in the pi session named after its own id, but `/new` and
/// `/resume` move pi to a different one. Shepherd follows that, so closing and
/// reopening the app returns to the conversation the user was last working in
/// rather than the original session.
@Suite("Agent pi sessions")
struct AgentSessionTests {
    private func makeAgent(piSessionID: String? = nil) -> Agent {
        Agent(
            name: "worker",
            spaceID: SpaceID(),
            tabID: TabID(),
            piSessionID: piSessionID
        )
    }

    @Test func defaultsToTheAgentsOwnID() {
        let agent = makeAgent()
        #expect(agent.effectivePiSessionID == agent.id.rawValue)
    }

    @Test func followsTheAgentToAMovedSession() {
        let agent = makeAgent(piSessionID: "9f8e7d6c-0000-0000-0000-000000000000")
        #expect(agent.effectivePiSessionID == "9f8e7d6c-0000-0000-0000-000000000000")
        #expect(agent.effectivePiSessionID != agent.id.rawValue)
    }

    /// The launch command must open the session the agent moved to; opening
    /// the agent id instead is exactly the bug this fixes.
    @Test func launchCommandOpensTheCurrentSession() {
        let agent = makeAgent(piSessionID: "moved-session-id")
        let command = StatusExtension.command(
            agentID: agent.id,
            piSessionID: agent.effectivePiSessionID,
            socketPath: "/tmp/shepherd.sock",
            extensionPath: "/tmp/status.ts",
            themeExtensionPath: "/tmp/theme.ts",
            panesExtensionPath: "/tmp/panes.ts",
            reviewExtensionPath: "/tmp/review.ts",
            subagentsExtensionPath: "/tmp/subagents.ts",
            piThemePath: "/tmp/theme.json",
            piThemeName: "shepherd",
            model: nil,
            thinking: nil,
            initialPrompt: nil
        )

        let shell = command.argv[3]
        #expect(shell.contains("--session-id 'moved-session-id'"))
        #expect(!shell.contains("--session-id '\(agent.id.rawValue)'"))
        // The agent's identity is unchanged: status and naming still route by
        // agent id, only the conversation moved.
        #expect(command.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue)
    }

    /// Agents written before session tracking have no stored session and must
    /// keep opening their original conversation.
    @Test func agentsPredatingSessionTrackingKeepTheirOriginalSession() throws {
        let agent = makeAgent()
        var json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(agent)
        ) as! [String: Any]
        json.removeValue(forKey: "piSessionID")

        let decoded = try JSONDecoder().decode(
            Agent.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.piSessionID == nil)
        #expect(decoded.effectivePiSessionID == agent.id.rawValue)
    }
}
