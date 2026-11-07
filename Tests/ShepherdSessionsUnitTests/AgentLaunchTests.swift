import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestKit

/// An agent's pi line from settings passed in as values (`AgentLaunchSettings`), not read from the app.
@Suite("Agent launch")
struct AgentLaunchTests {
    let pi = PiSetup(engine: PiEngine(command: ["/tmp/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node")),
                     home: URL(fileURLWithPath: "/tmp/agent-launch/pi"))

    func command(_ agent: Agent, _ settings: AgentLaunchSettings = AgentLaunchSettings(), fresh: Bool = true,
                 override: String? = nil, mcp: MCPLaunch? = nil) throws -> SessionCommand {
        try AgentLaunch.rpcCommand(for: agent, cwd: "/tmp/project", pi: pi, settings: settings, sessionIsFresh: fresh,
                                   modelOverride: override, mcp: { mcp })
    }

    func agent(design: DesignID? = nil, model: String? = "stub/model-a") -> Agent {
        var agent = Agent(name: "a", spaceID: SpaceID(), tabID: TabID(), model: model, thinkingLevel: .high)
        agent.designID = design
        return agent
    }

    @Test func settingsChooseTheExtensions() throws {
        var on = AgentLaunchSettings()
        on.panes = true; on.browser = true; on.trimToolOutput = true; on.deferTools = true; on.nativeSubagents = true
        let all = try command(agent(), on).env
        #expect(all["SHEPHERD_EXT_PANES"] != nil)
        #expect(all["SHEPHERD_EXT_BROWSER"] != nil)
        #expect(all["SHEPHERD_EXT_CONTEXT"] != nil)
        #expect(all["SHEPHERD_DEFER_TOOLS"] != nil)
        var off = AgentLaunchSettings()
        off.panes = false; off.browser = false; off.trimToolOutput = false; off.deferTools = false
        let none = try command(agent(), off).env
        #expect(none["SHEPHERD_EXT_PANES"] == nil)
        #expect(none["SHEPHERD_EXT_BROWSER"] == nil)
        #expect(none["SHEPHERD_EXT_CONTEXT"] == nil)
        #expect(none["SHEPHERD_DEFER_TOOLS"] == nil)
    }

    @Test func aDesignsAgentGetsNeitherPanesNorBrowser() throws {
        let env = try command(agent(design: DesignID())).env
        #expect(env["SHEPHERD_EXT_PANES"] == nil)
        #expect(env["SHEPHERD_EXT_BROWSER"] == nil)
        #expect(env["SHEPHERD_DESIGN_ID"] != nil)
    }

    @Test func modelFlagsGoOnlyToAFreshSessionUnlessOverridden() throws {
        func line(fresh: Bool, override: String? = nil) throws -> String {
            try command(agent(), fresh: fresh, override: override).argv.joined(separator: " ")
        }
        #expect(try line(fresh: true).contains("model-a"))
        #expect(!(try line(fresh: false).contains("model-a")))
        #expect(try line(fresh: false, override: "stub/model-b").contains("model-b"))
    }

    /// A child space's unset startup model and thinking come from its parent spaces, and only for a
    /// fresh session the thread itself didn't choose for.
    @Test func parentDefaultsFillOnlyWhatTheThreadLeavesUnset() throws {
        let inherited = SpaceInheritedDefaults(model: "stub/parent-model", thinking: "low")
        func line(_ agent: Agent, fresh: Bool = true) throws -> String {
            try AgentLaunch.rpcCommand(for: agent, cwd: "/tmp/project", pi: pi, settings: AgentLaunchSettings(), sessionIsFresh: fresh,
                                       inherited: inherited, mcp: { nil }).argv.joined(separator: " ")
        }
        var unset = agent(model: nil); unset.thinkingLevel = nil
        let inheriting = try line(unset), chosen = try line(agent()), resumed = try line(unset, fresh: false)
        #expect(inheriting.contains("parent-model") && inheriting.contains("--thinking 'low'"))
        #expect(!chosen.contains("parent-model") && chosen.contains("--thinking 'high'"))
        #expect(!resumed.contains("parent-model"))
    }

    @Test func mcpGoesToTheLaunch() throws {
        let env = try command(agent(), mcp: MCPLaunch(extensions: MCPLaunch.builtIns, environment: ["MCP_SECRET": "x"])).env
        #expect(env["MCP_SECRET"] == "x")
    }

    @Test func aRefusedLaunchSaysWhyInsteadOfStartingPi() {
        let refused = AgentLaunch.refusedCommand(PiHomeProblem("home overlaps"))
        #expect(refused.argv == PiLaunch.refused(PiHomeProblem("home overlaps")).argv)
        #expect(refused.env.isEmpty)
    }

    @Test func aMissingFolderResolvesToHome() {
        #expect(AgentLaunch.resolvedCwd("/tmp") == "/tmp")
        #expect(AgentLaunch.resolvedCwd("/no/such/folder-\(UUID())") == FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
