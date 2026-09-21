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
            nativeExtensionPath: "/tmp/native.ts",
            piThemePath: "/tmp/theme.json",
            piThemeName: "shepherd",
            model: nil,
            thinking: nil,
            initialPrompt: nil
        )

        let shell = command.argv[3]
        #expect(shell.contains("--session-id 'moved-session-id'"))
        #expect(shell.contains("-e '/tmp/native.ts'"))
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

    /// An RPC agent launches `pi --mode rpc` through the same login shell with the same
    /// socket env, but without the theme or native extension and without a positional
    /// prompt (RPC mode ignores it; the app sends it as the first `prompt`).
    @Test func rpcCommandMirrorsTerminalWiringWithoutTUIExtensions() {
        let terminal = StatusExtension.command(
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "moved-session", socketPath: "/tmp/shepherd.sock",
            extensionPath: "/tmp/status.ts", themeExtensionPath: "/tmp/theme.ts", panesExtensionPath: "/tmp/panes.ts",
            reviewExtensionPath: "/tmp/review.ts", subagentsExtensionPath: "/tmp/subagents.ts", namerExtensionPath: "/tmp/namer.ts",
            nativeExtensionPath: "/tmp/native.ts", needsName: true, isAutomation: true, piThemePath: "/tmp/theme.json",
            piThemeName: "shepherd", model: "provider/model", thinking: .high, initialPrompt: "fix it"
        )
        let rpc = StatusExtension.rpcCommand(
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "moved-session", socketPath: "/tmp/shepherd.sock",
            extensionPath: "/tmp/status.ts", panesExtensionPath: "/tmp/panes.ts", reviewExtensionPath: "/tmp/review.ts",
            subagentsExtensionPath: "/tmp/subagents.ts", namerExtensionPath: "/tmp/namer.ts", needsName: true,
            isAutomation: true, model: "provider/model", thinking: .high
        )
        #expect(rpc.argv.prefix(3) == terminal.argv.prefix(3))
        let shell = rpc.argv[3]
        #expect(shell.hasPrefix("exec pi --mode rpc --session-id 'moved-session'"))
        #expect(!terminal.argv[3].contains("--mode rpc"))
        #expect(shell.contains("--model 'provider/model'") && shell.contains("--thinking 'high'"))
        for path in ["/tmp/status.ts", "/tmp/panes.ts", "/tmp/review.ts", "/tmp/subagents.ts", "/tmp/namer.ts"] {
            #expect(shell.contains(" -e '\(path)'"))
        }
        #expect(!shell.contains("theme") && !shell.contains("native.ts") && !shell.contains("fix it"))
        // Same env contract minus the theme keys.
        let themeKeys: Set<String> = ["SHEPHERD_EXT_THEME", "SHEPHERD_PI_THEME_PATH", "SHEPHERD_PI_THEME_NAME"]
        #expect(rpc.env == terminal.env.filter { !themeKeys.contains($0.key) })
        #expect(rpc.env["SHEPHERD_AGENT_ID"] == "agent-id" && rpc.env["SHEPHERD_NEEDS_NAME"] == "1" && rpc.env["SHEPHERD_AUTOMATION"] == "1")

        let bare = StatusExtension.rpcCommand(
            agentID: AgentID(), piSessionID: "s", socketPath: "/tmp/s", extensionPath: "/tmp/status.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil, model: nil, thinking: nil
        )
        #expect(bare.argv[3] == "exec pi --mode rpc --session-id 's' -e '/tmp/status.ts'")
        #expect(bare.env["SHEPHERD_EXT_PANES"] == nil && bare.env["SHEPHERD_MODEL"] == nil)
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
