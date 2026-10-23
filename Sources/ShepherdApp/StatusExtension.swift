import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Command spec for an app-spawned session.
struct SessionCommand {
    var argv: [String]
    var env: [String: String]
}

/// What an agent's pi is launched with for MCP (Settings ▸ Pi ▸ Bundled extensions ▸ MCP servers;
/// docs/mcp.md): pi's own MCP and tool search switched on over the home's `-builtin:` switches, the
/// secrets the servers' entries refer to in its environment, and, while Settings ▸ MCP servers ▸
/// Also use a repo's .mcp.json is on, the extension that registers the repo's servers. An agent in a
/// subproject also gets its parent's `.shepherd/mcp.json` servers (`sharingParent`).
struct MCPLaunch: Equatable {
    /// `-e` arguments: pi's built-ins by name, then the repo extension's file.
    var extensions: [String]
    var environment: [String: String]

    static let builtIns = ["builtin:mcp", "builtin:tool-search"]

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

    /// Worktree MCP follows the registered owning space, not folder ancestry. This only
    /// names an MCP source; it never approves the checkout's executable project resources.
    func sharingProject(_ parent: String?, agent: Agent, cwd: String, state: ShepherdState, verifiedWorktree: Bool = false,
                        install: () throws -> String = MCPParentExtension.installedPath) rethrows -> MCPLaunch {
        guard agent.worktreeBranch != nil || agent.worktreePath != nil || verifiedWorktree,
              let space = state.spaces.first(where: { $0.id == agent.spaceID }),
              !PiLaunch.isHomeFolder(space.path, userHome: NSHomeDirectory()),
              !PiLaunch.isHomeFolder(cwd, userHome: NSHomeDirectory()),
              PiHome.canonical(space.path) != PiHome.canonical(cwd),
              agent.worktreePath.map({ PiHome.canonical($0) == PiHome.canonical(cwd) }) ?? true else {
            return try sharingParent(parent, install: install)
        }
        var launch = self
        launch.extensions.append(try install())
        launch.environment["SHEPHERD_MCP_OWNING_SPACE"] = PiHome.canonical(space.path)
        launch.environment["SHEPHERD_MCP_WORKTREE_CWD"] = PiHome.canonical(cwd)
        return launch
    }

    /// This launch for an agent in a subproject of `parent` (Settings ▸ Projects, parents and
    /// subprojects): the extension that registers the parent's `.shepherd/mcp.json` servers, and the
    /// folder it reads them from. Unchanged for a top-level project.
    func sharingParent(_ parent: String?, install: () throws -> String = MCPParentExtension.installedPath) rethrows -> MCPLaunch {
        guard let parent else { return self }
        var launch = self
        launch.extensions.append(try install())
        launch.environment["SHEPHERD_PARENT_PROJECT"] = parent
        return launch
    }
}

/// The per-agent pi status extension: bundled TypeScript source installed to
/// Application Support and passed to pi via `-e`, reporting agent lifecycle
/// status to the app's extension socket.
enum StatusExtension {
    /// Write the extension source to Application Support (idempotent) and
    /// return its filesystem path.
    static func installedPath() throws -> String {
        let dir = ShepherdPaths.supportDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shepherd-status.ts")
        let source = Data(extensionSource.utf8)
        if (try? Data(contentsOf: url)) != source {
            try source.write(to: url, options: .atomic)
        }
        return url.path
    }

    /// argv + env for an agent: Shepherd's pi (`pi --mode rpc` through the launcher in its pi
    /// home) in `cwd`, from a login shell (so the user's PATH reaches pi's tools), reopening the
    /// pi session the agent was last in, with status reporting wired to the app's socket
    /// (`PiLaunch.agent` builds the line). The opening prompt is not passed positionally; RPC
    /// mode ignores positional messages, so the app sends it as the first `prompt` command
    /// instead. Throws when the agent's session folder would resolve outside the home.
    static func command(
        home: PiHome,
        cwd: String,
        agentID: AgentID,
        piSessionID: String,
        socketPath: String,
        extensionPath: String,
        panesExtensionPath: String?,
        reviewExtensionPath: String?,
        subagentsExtensionPath: String?,
        childrenExtensionPath: String? = nil,
        nativeChildren: Bool = true,
        childEnvironment: [String: String] = [:],
        goalCrossProviderEvaluation: Bool = false,
        goalsEnabled: Bool = false,
        namerExtensionPath: String? = nil,
        needsName: Bool = false,
        namingModel: String = "",
        isAutomation: Bool = false,
        instructions: (extensionPath: String, directory: String)? = nil,
        suggestFiles: [String] = [],
        design: (extensionPath: String, designID: DesignID, skillDirectory: String)? = nil,
        designReferences: (extensionPath: String, granted: Bool)? = nil,
        mcp: MCPLaunch? = nil,
        browserExtensionPath: String? = nil,
        contextExtensionPath: String? = nil,
        projectContext: (path: String, json: String, coordinator: Bool)? = nil,
        deferTools: Bool = false,
        userHome: String = NSHomeDirectory(),
        model: String?,
        thinking: ThinkingLevel?
    ) throws -> SessionCommand {
        // A design's agent reads its design with its own tools: never references.
        let designReferences = design == nil ? designReferences : nil
        // Nor does it get the browser: that is a thread's own page.
        let browserExtensionPath = design == nil ? browserExtensionPath : nil
        // Nor are its tools deferred: it works from all of them (docs/context-budget.md, Deferred tools).
        let deferTools = deferTools && design == nil
        // Deferred tools are loaded with pi's tool_search. With MCP on the launch already has it; without, it is the one built-in to add.
        let toolSearch = deferTools && mcp == nil ? ["builtin:tool-search"] : []
        // Child result delivery must run before the goal's final-settlement evaluator.
        var extensions = [extensionPath, ServiceTierExtension.path(in: home), instructions?.extensionPath, panesExtensionPath, reviewExtensionPath, subagentsExtensionPath,
                          childrenExtensionPath, GoalExtension.path(in: home), namerExtensionPath, design?.extensionPath, designReferences?.extensionPath,
                          browserExtensionPath].compactMap { $0 } + (mcp?.extensions ?? toolSearch) + [contextExtensionPath].compactMap { $0 }
        if let projectContext {
            if projectContext.coordinator { extensions = [extensionPath, ServiceTierExtension.path(in: home)] }
            extensions.append(projectContext.path)
        }
        let line = try PiLaunch.agent(home: home, cwd: cwd, sessionID: piSessionID, model: model, thinking: thinking?.rawValue,
                                      extensions: extensions, untrustedProject: PiLaunch.isHomeFolder(cwd, userHome: userHome),
                                      coordinator: projectContext?.coordinator == true)
        var env = [
            "SHEPHERD_AGENT_ID": agentID.rawValue,
            "SHEPHERD_SOCKET": socketPath,
            "SHEPHERD_EXT_STATUS": extensionPath,
        ]
        if let instructions { env["SHEPHERD_INSTRUCTIONS_DIR"] = instructions.directory }
        // Settings ▸ Experiments ▸ Suggested instructions, while on for this agent: the files its
        // suggest_instruction may draft a line for.
        if instructions != nil, !suggestFiles.isEmpty { env["SHEPHERD_SUGGEST_FILES"] = suggestFiles.joined(separator: ",") }
        if let panesExtensionPath { env["SHEPHERD_EXT_PANES"] = panesExtensionPath }
        // Settings ▸ Pi ▸ Browser tools: the tools on the thread's own page (docs/browser.md).
        if let browserExtensionPath { env["SHEPHERD_EXT_BROWSER"] = browserExtensionPath }
        if let childrenExtensionPath {
            env["SHEPHERD_NATIVE_CHILDREN"] = nativeChildren ? "1" : "0"
            env["SHEPHERD_EXT_CHILDREN"] = childrenExtensionPath
            env.merge(childEnvironment) { _, value in value }
        }
        if namerExtensionPath != nil && needsName {
            env["SHEPHERD_NEEDS_NAME"] = "1"
            // Settings ▸ Agents ▸ Session naming model; the namer still falls back to the agent's own model.
            if !namingModel.isEmpty { env["SHEPHERD_NAMER_MODELS"] = namingModel }
        }
        if isAutomation { env["SHEPHERD_AUTOMATION"] = "1" }
        // A design's agent: its design tools, and the skill they hand pi.
        if let design {
            env["SHEPHERD_DESIGN_ID"] = design.designID.rawValue
            env["SHEPHERD_DESIGN_SKILL_DIR"] = design.skillDirectory
        }
        // A thread's design references: design_get registers itself once it holds one.
        if let designReferences { env["SHEPHERD_DESIGN_REFS"] = designReferences.granted ? "granted" : "on" }
        // Settings ▸ MCP servers: the Keychain values pi's MCP expands into its servers' env and headers.
        if let mcp { env.merge(mcp.environment) { _, value in value } }
        // Settings ▸ Agents ▸ Trim old tool output: what the model is sent, never the thread (docs/context-budget.md).
        if let contextExtensionPath { env["SHEPHERD_EXT_CONTEXT"] = contextExtensionPath }
        // Settings ▸ Agents ▸ Defer rarely used tools: the browser, other-thread, automation and review tools are loaded by a search.
        if deferTools { env["SHEPHERD_DEFER_TOOLS"] = "1" }
        // Fast or Standard is the agent's own (the host keeps its file), so every agent gets this.
        env.merge(ServiceTierExtension.environment(for: agentID, in: home)) { _, value in value }
        // Keep the controller loaded so the experiment can change without restarting pi.
        env[GoalExtension.environmentKey] = "1"
        env["SHEPHERD_GOALS_ENABLED"] = goalsEnabled ? "1" : "0"
        // Always override an inherited opt-in; absence would leak the app's launch environment.
        env["SHEPHERD_GOAL_MODELS"] = goalCrossProviderEvaluation
            ? "anthropic/claude-haiku-4-5,openai/gpt-5.1-codex-mini,google/gemini-2.5-flash" : ""
        if let projectContext {
            env["SHEPHERD_PROJECT_CONTEXT"] = projectContext.json
            env["SHEPHERD_PROJECT_COORDINATOR"] = projectContext.coordinator ? "1" : "0"
            if projectContext.coordinator {
                for key in ["SHEPHERD_EXT_PANES", "SHEPHERD_NATIVE_CHILDREN", "SHEPHERD_EXT_CHILDREN", "SHEPHERD_EXT_BROWSER", "SHEPHERD_DEFER_TOOLS", "SHEPHERD_EXT_GOAL"] { env[key] = "" }
                env["SHEPHERD_GOALS_ENABLED"] = "0"
            }
        }
        if let model { env["SHEPHERD_MODEL"] = model }
        return SessionCommand(argv: line.argv, env: env)
    }
    static var extensionSource: String { EmbeddedExtensions.source("shepherd-status.ts") }
}
