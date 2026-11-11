import Foundation
import ShepherdSessions

extension MCPLaunch {
    /// What an agent launches with under these settings: nil while Settings ▸ Pi ▸ MCP servers
    /// is off. `install` writes the repo extension and returns its path.
    @MainActor
    static func forAgents(settings: AppSettings, store: MCPStore,
                          install: () throws -> String = MCPProjectExtension.installedPath) rethrows -> MCPLaunch? {
        guard settings.piMCPExtension else { return nil }
        var extensions = builtIns
        var environment = store.launchEnvironment()
        if settings.mcpProjectConfig {
            extensions.append(try install())
            environment["SHEPHERD_EXT_MCP_PROJECT"] = "1"
        }
        return MCPLaunch(extensions: extensions, environment: environment)
    }

    /// A spawn's MCP under these settings (`AgentSpawn.mcp`): `forAgents`, shared with the
    /// folder's project.
    @MainActor
    static func spawnMCP(settings: AppSettings, store: MCPStore) -> AgentSpawn.MCP {
        { parent, agent, cwd, state, verifiedWorktree in
            try forAgents(settings: settings, store: store)?
                .sharingProject(parent, agent: agent, cwd: cwd, state: state, verifiedWorktree: verifiedWorktree)
        }
    }
}

extension AppSettings {
    /// What an agent's pi launch reads from these settings (`AgentLaunch.rpcCommand`).
    var agentLaunch: AgentLaunchSettings {
        var launch = AgentLaunchSettings()
        launch.codemode = codemode
        launch.panes = piPanesExtension
        launch.review = piReviewExtension
        launch.subagentDisplay = subagentDisplay
        launch.nativeSubagents = piNativeSubagents
        launch.childEnvironment = childEnvironment
        launch.goals = goalsEnabled
        launch.textGenerationModel = textGenerationModel
        launch.designTool = designToolEnabled
        launch.designReferences = piDesignReferences
        launch.browser = piBrowserExtension
        launch.trimToolOutput = trimToolOutput
        launch.deferTools = deferTools
        return launch
    }
}
