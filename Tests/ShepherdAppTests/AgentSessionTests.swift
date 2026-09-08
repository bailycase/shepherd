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

    @Test(arguments: 0..<32)
    func optionalExtensionsOnlyEnableTheirOwnLaunchFlags(enabled: Int) {
        let paths = ["/tmp/theme.ts", "/tmp/panes.ts", "/tmp/review.ts", "/tmp/subagents.ts", "/tmp/namer.ts"]
        let selected = paths.enumerated().map { index, path in
            enabled & (1 << index) != 0 ? path : nil
        }
        for isAutomation in [false, true] {
            let command = StatusExtension.command(
                agentID: AgentID(rawValue: "agent-id"),
                piSessionID: "current-session",
                socketPath: "/tmp/shepherd.sock",
                extensionPath: "/tmp/status.ts",
                themeExtensionPath: selected[0],
                panesExtensionPath: selected[1],
                reviewExtensionPath: selected[2],
                subagentsExtensionPath: selected[3],
                namerExtensionPath: selected[4],
                needsName: true,
                isAutomation: isAutomation,
                piThemePath: "/tmp/theme file.json",
                piThemeName: "shepherd",
                model: "provider/model",
                thinking: .high,
                initialPrompt: "fix user's code"
            )
            let shell = command.argv[3]
            #expect(shell.contains(" -e '/tmp/status.ts'"))
            #expect(shell.contains("--session-id 'current-session'"))
            #expect(shell.contains("--model 'provider/model'"))
            #expect(shell.contains("--thinking 'high'"))
            #expect(shell.hasSuffix("'fix user'\"'\"'s code'"))
            for index in paths.indices {
                #expect(shell.contains(" -e '\(paths[index])'") == (selected[index] != nil))
            }
            #expect(!shell.contains("--no-extensions"))
            #expect(!shell.contains("shepherd-inspect"))
            #expect(shell.contains("--theme '/tmp/theme file.json'") == (selected[0] != nil))
            #expect(shell.contains("--use-theme 'shepherd'") == (selected[0] != nil))
            #expect(command.env["SHEPHERD_AGENT_ID"] == "agent-id")
            #expect(command.env["SHEPHERD_SOCKET"] == "/tmp/shepherd.sock")
            #expect(command.env["SHEPHERD_EXT_STATUS"] == "/tmp/status.ts")
            #expect(command.env["SHEPHERD_EXT_THEME"] == selected[0])
            #expect(command.env["SHEPHERD_PI_THEME_PATH"] == (selected[0] == nil ? nil : "/tmp/theme file.json"))
            #expect(command.env["SHEPHERD_PI_THEME_NAME"] == (selected[0] == nil ? nil : "shepherd"))
            #expect(command.env["SHEPHERD_EXT_PANES"] == selected[1])
            #expect(command.env["SHEPHERD_NEEDS_NAME"] == (selected[4] == nil ? nil : "1"))
            #expect(command.env["SHEPHERD_AUTOMATION"] == (isAutomation ? "1" : nil))
        }
    }

    @Test func finalNamesStillLoadTheEnabledNamerWithoutRequestingAnOpeningTitle() {
        let command = StatusExtension.command(
            agentID: AgentID(),
            piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock",
            extensionPath: "/tmp/status.ts",
            themeExtensionPath: nil,
            panesExtensionPath: nil,
            reviewExtensionPath: nil,
            subagentsExtensionPath: nil,
            namerExtensionPath: "/tmp/namer.ts",
            needsName: false,
            piThemePath: nil,
            piThemeName: "shepherd",
            model: nil,
            thinking: nil,
            initialPrompt: nil
        )
        #expect(command.argv[3].contains(" -e '/tmp/namer.ts'"))
        #expect(command.env["SHEPHERD_NEEDS_NAME"] == nil)
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
