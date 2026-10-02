import Foundation
import ShepherdCore
import ShepherdSessions
import Testing
import ShepherdTestKit
@testable import ShepherdApp

@Suite("Agent creation")
@MainActor
struct AgentCreationTests {
    // MARK: Provisional names

    /// The sidebar wears the opening prompt until pi's namer lands a real title, so it must
    /// stay short and single-line.
    @Test(arguments: [
        ("fix the sidebar", "fix the sidebar"),
        ("  fix   the\nsidebar\t ", "fix the sidebar"),
        (nil, "New agent"),
        ("", "New agent"),
        ("   \n  ", "New agent"),
    ] as [(String?, String)])
    func provisionalNamesAreTheOpeningPromptOnOneLine(prompt: String?, name: String) {
        #expect(ShepherdViewModel.provisionalName(for: prompt) == name)
    }

    @Test func longPromptsTruncateOnAWordBoundary() {
        let name = ShepherdViewModel.provisionalName(for: String(repeating: "alpha ", count: 20))
        #expect(name == String(repeating: "alpha ", count: 8).trimmingCharacters(in: .whitespaces) + "…")
        #expect(name.count <= 49)
    }

    @Test func aSingleOverlongWordIsClippedAtTheLimit() {
        let name = ShepherdViewModel.provisionalName(for: String(repeating: "x", count: 80))
        #expect(name == String(repeating: "x", count: 48) + "…")
    }

    @Test func aPromptAtTheLimitIsKeptWhole() {
        let prompt = String(repeating: "y", count: 48)
        #expect(ShepherdViewModel.provisionalName(for: prompt) == prompt)
    }

    // MARK: Quick create (⌘N)

    @Test func quickCreateRunsInTheSpacesOwnCheckoutWithPiDefaults() {
        let space = Fixture.space("Shepherd")
        let config = ShepherdViewModel.quickAgentConfig(for: space)
        #expect(config.spaceID == space.id)
        #expect(config.workingDirectory == space.path)
        #expect(config.model == nil && config.thinking == .medium)
        #expect(config.initialPrompt == nil && config.initialName == nil && config.worktreeBranch == nil)
    }

    @Test func quickCreateInheritsTheConfiguredDefaults() {
        let config = ShepherdViewModel.quickAgentConfig(
            for: Fixture.space("s"), defaults: AgentDefaults(model: "anthropic/claude-sonnet-4", thinking: .high)
        )
        #expect(config.model == "anthropic/claude-sonnet-4" && config.thinking == .high)
    }

    // MARK: Naming

    /// pi's namer runs only while the name is provisional and auto-naming is on.
    @Test(arguments: [(false, true, true), (false, false, false), (true, true, false), (true, false, false)])
    func theNamerRunsOnlyForProvisionalNamesWithAutoNamingOn(nameIsFinal: Bool, autoName: Bool, wants: Bool) {
        let agent = Agent(name: "fix the sidebar", spaceID: SpaceID(), tabID: TabID(), nameIsFinal: nameIsFinal)
        #expect(TerminalSessionStore.wantsNamer(for: agent, autoName: autoName) == wants)
    }

    // MARK: New Agent sheet defaults

    /// A remote host's defaults arrive late: they fill untouched fields, never overwrite an edit,
    /// and a reply for a previous target is dropped.
    @Test func lateHostDefaultsFillOnlyUneditedFields() {
        var defaults = NewAgentTargetDefaults()
        let request = defaults.begin(hostID: UUID(), model: "", thinking: .medium)
        #expect(defaults.loading && !defaults.ready)

        defaults.model = "chosen/model"
        defaults.modelEdited = true
        defaults.apply(requestID: request, model: "host/default", thinking: .low)

        #expect(defaults.ready && !defaults.loading)
        #expect(defaults.model == "chosen/model")
        #expect(defaults.thinking == .low)
    }

    @Test func aReplyForAPreviousTargetIsIgnored() {
        var defaults = NewAgentTargetDefaults()
        let stale = defaults.begin(hostID: UUID(), model: "", thinking: .medium)
        _ = defaults.begin(hostID: UUID(), model: "", thinking: .medium)

        defaults.apply(requestID: stale, model: "stale", thinking: .low)
        defaults.fail(requestID: stale)

        #expect(defaults.loading && !defaults.ready)
        #expect(defaults.model.isEmpty && defaults.thinking == .medium)
    }

    @Test func aFailedLoadCanBeRetried() {
        var defaults = NewAgentTargetDefaults()
        let host = UUID()
        let first = defaults.begin(hostID: host, model: "", thinking: .medium)
        defaults.fail(requestID: first)
        #expect(!defaults.loading && !defaults.ready)

        let retry = defaults.begin(hostID: host, model: "", thinking: .medium)
        defaults.apply(requestID: retry, model: "host/default", thinking: .high)
        #expect(defaults.ready && defaults.model == "host/default" && defaults.thinking == .high)
    }

    /// This Mac's defaults are known immediately; switching targets resets edits.
    @Test func theLocalTargetIsReadyAtOnceAndReplacesEdits() {
        var defaults = NewAgentTargetDefaults()
        let remote = defaults.begin(hostID: UUID(), model: "", thinking: .medium)
        defaults.model = "edited"
        defaults.modelEdited = true

        _ = defaults.begin(hostID: nil, model: "local/default", thinking: .low)
        defaults.apply(requestID: remote, model: "late remote", thinking: .high)

        #expect(defaults.hostID == nil && defaults.ready && !defaults.loading)
        #expect(defaults.model == "local/default" && !defaults.modelEdited)
        #expect(defaults.thinking == .low)
    }

    /// Base resolution restarts when the host, space, directory, or worktree choice changes.
    @Test func theBaseTargetIdentityCoversHostAndWorktreeChoice() {
        let base = NewAgentBaseTarget(hostID: UUID(), spaceID: SpaceID(), cwd: "/repo", worktree: true)
        var otherHost = base
        otherHost.hostID = UUID()
        var noWorktree = base
        noWorktree.worktree = false
        #expect(base != otherHost)
        #expect(base != noWorktree)
        #expect(base == NewAgentBaseTarget(hostID: base.hostID, spaceID: base.spaceID, cwd: "/repo", worktree: true))
    }

    // MARK: Directory completion

    @Test(arguments: [
        ("ms-g", ["ms-graphql-external", "ms-graphql-internal"], "ms-graphql-"),
        ("ms-graphql-", ["ms-graphql-external", "ms-graphql-internal"], "ms-graphql-"),
        ("proj", ["Projects"], "Projects"),
        ("x", [], "x"),
        ("Dev", ["Developer", "developer-tools"], "Developer"),
    ] as [(String, [String], String)])
    func tabCompletesToTheSharedPrefixOrTheUniqueMatch(query: String, matches: [String], completion: String) {
        #expect(DirectoryCompletion.component(for: query, matches: matches) == completion)
    }

    /// Hidden folders only on request or when the filter starts with a dot; prefix matches
    /// first, then scattered ones, each in name order.
    @Test(arguments: [
        ("", false, ["apps", "Developer", "docs"]),
        ("", true, ["apps", "Developer", "docs", ".cache", ".config"]),
        (".c", false, [".cache", ".config"]),
        ("d", false, ["Developer", "docs"]),
        ("do", false, ["docs", "Developer"]),
        ("DEV", false, ["Developer"]),
        ("zz", false, []),
    ] as [(String, Bool, [String])])
    func theDirectoryListingNarrowsToTheFilter(filter: String, showHidden: Bool, listed: [String]) {
        let dirs = ["apps", "Developer", "docs", ".cache", ".config"]
        #expect(DirectoryFilter.visible(dirs, filter: filter, showHidden: showHidden) == listed)
    }

    // MARK: Worktree paths

    /// A worktree is a sibling of the checkout; branch slashes never become directories.
    @Test(arguments: [
        ("/Users/me/code/app", "worktree/calm-otter-1234", "/Users/me/code/app-worktree-calm-otter-1234"),
        ("/Users/me/code/app", "fix", "/Users/me/code/app-fix"),
    ])
    func worktreesLiveBesideTheirRepository(repo: String, branch: String, destination: String) {
        #expect(GitWorktree.destination(repo: repo, branch: branch) == destination)
    }

    @Test func generatedBranchesAreReadableAndDisposable() {
        let branch = GitWorktree.generatedBranch()
        #expect(branch.wholeMatch(of: /agent\/[a-z]+-[a-z]+-\d{4}/) != nil, "\(branch)")
    }
}

/// Every agent runs `pi --mode rpc` through a login shell; the launch command is the contract
/// between Shepherd's settings and the extensions pi loads.
@Suite("Agent launch command")
struct AgentLaunchCommandTests {
    /// Shepherd's pi home, with a stand-in engine (the line never names the engine: the launcher
    /// does).
    static let home = PiHome(directory: URL(fileURLWithPath: "/tmp/support/pi"),
                             engine: PiEngine(command: ["/tmp/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node")))

    private let paths = ["/tmp/panes.ts", "/tmp/review.ts", "/tmp/subagents.ts", "/tmp/namer.ts", "/tmp/children.ts"]

    private func command(
        enabled: Set<Int> = [],
        needsName: Bool = false,
        isAutomation: Bool = false,
        goalCrossProviderEvaluation: Bool = false,
        goalsEnabled: Bool = false,
        model: String? = nil,
        thinking: ThinkingLevel? = nil
    ) -> SessionCommand {
        func path(_ index: Int) -> String? { enabled.contains(index) ? paths[index] : nil }
        return try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: path(0), reviewExtensionPath: path(1), subagentsExtensionPath: path(2),
            childrenExtensionPath: path(4), childEnvironment: ["SHEPHERD_CHILD_CONCURRENCY": "7"],
            goalCrossProviderEvaluation: goalCrossProviderEvaluation, goalsEnabled: goalsEnabled,
            namerExtensionPath: path(3), needsName: needsName, isAutomation: isAutomation,
            model: model, thinking: thinking
        )
    }

    /// The line itself is `PiLaunch.agent`'s (pinned in `PiLaunchTests`).
    @Test func aBareAgentIsJustPiOverRPCWithTheStatusExtension() throws {
        let bare = command()
        #expect(bare.argv == (try PiLaunch.agent(home: Self.home, cwd: "/tmp/project", sessionID: "current-session", model: nil, thinking: nil,
                                                 extensions: ["/tmp/status.ts", "/tmp/support/pi/shepherd-service-tier.ts", "/tmp/support/pi/shepherd-goal.ts"])).argv)
        #expect(bare.env == [
            "SHEPHERD_AGENT_ID": "agent-id", "SHEPHERD_SOCKET": "/tmp/shepherd.sock", "SHEPHERD_EXT_STATUS": "/tmp/status.ts",
            "SHEPHERD_EXT_SERVICE_TIER": "/tmp/support/pi/service-tier/agent-id.json",
            "SHEPHERD_EXT_GOAL": "1", "SHEPHERD_GOALS_ENABLED": "0", "SHEPHERD_GOAL_MODELS": "",
        ])
    }

    @Test func theGoalControllerLoadsForLiveSwitchingButTheExperimentIsOffUntilChosen() {
        #expect(command().env["SHEPHERD_GOALS_ENABLED"] == "0")
        #expect(command(goalsEnabled: true).env["SHEPHERD_GOALS_ENABLED"] == "1")
        let inherited = ["SHEPHERD_GOALS_ENABLED": "1"]
        #expect(inherited.merging(command().env) { _, new in new }["SHEPHERD_GOALS_ENABLED"] == "0")
    }

    @Test func crossProviderModelsAreOptInAndOptOutOverridesInheritedConsent() {
        let inherited = ["SHEPHERD_GOAL_MODELS": "other-provider/private-model"]
        let off = command().env
        #expect(off["SHEPHERD_GOAL_MODELS"] == "", "omitting the key would inherit consent")
        #expect(inherited.merging(off) { _, new in new }["SHEPHERD_GOAL_MODELS"] == "")
        #expect(command(goalCrossProviderEvaluation: true).env["SHEPHERD_GOAL_MODELS"]
                == "anthropic/claude-haiku-4-5,openai/gpt-5.1-codex-mini,google/gemini-2.5-flash")
        #expect(command(goalCrossProviderEvaluation: false).env["SHEPHERD_GOAL_MODELS"] == "")
    }

    /// An agent in the user's home folder never trusts it as a project (`~/.pi` is their own pi);
    /// anywhere else, trust is pi's to decide.
    @Test(arguments: [("/tmp/home", true), ("/tmp/home/", true), ("/tmp/home/project", false), ("/tmp", false)])
    func anAgentInTheHomeFolderTrustsNoProjectCode(cwd: String, untrusted: Bool) throws {
        let launch = try StatusExtension.command(
            home: Self.home, cwd: cwd, agentID: AgentID(rawValue: "agent-id"), piSessionID: "s",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts", panesExtensionPath: nil, reviewExtensionPath: nil,
            subagentsExtensionPath: nil, userHome: "/tmp/home", model: nil, thinking: nil)
        #expect(launch.argv[3].contains(" --no-approve") == untrusted)
    }

    /// Every agent starts Shepherd's launcher, with its sessions in Shepherd's home, and hands its
    /// children no pi to fall back to.
    @Test func theAgentStartsShepherdsLauncherInItsHome() {
        let launch = command()
        #expect(launch.argv[3].contains("&& exec '/tmp/support/pi/bin/pi' --mode rpc --session-dir '/tmp/support/pi/sessions/--"))
        #expect(launch.env["SHEPHERD_PI_EXECUTABLE"] == nil)
    }

    /// Each optional extension adds exactly its own `-e` flag (all 32 combinations).
    @Test(arguments: 0..<32)
    func optionalExtensionsOnlyEnableTheirOwnFlags(mask: Int) {
        let enabled = Set((0..<5).filter { mask & (1 << $0) != 0 })
        let shell = command(enabled: enabled).argv[3]
        for index in paths.indices {
            #expect(shell.contains(" -e '\(paths[index])'") == enabled.contains(index))
        }
        #expect(!shell.contains("--theme") && !shell.contains("--no-extensions"))
    }

    @Test func childrenBringTheirEnvironmentOnlyWhenEnabled() {
        #expect(command().env["SHEPHERD_CHILD_CONCURRENCY"] == nil)
        let children = command(enabled: [4]).env
        #expect(children["SHEPHERD_NATIVE_CHILDREN"] == "1")
        #expect(children["SHEPHERD_EXT_CHILDREN"] == "/tmp/children.ts")
        #expect(children["SHEPHERD_CHILD_CONCURRENCY"] == "7")
    }

    /// A final name still loads the enabled namer (a manual `/name`), but never asks for an
    /// opening title.
    @Test func onlyAProvisionalNameRequestsATitle() {
        #expect(command(enabled: [3], needsName: true).env["SHEPHERD_NEEDS_NAME"] == "1")
        #expect(command(enabled: [3], needsName: false).env["SHEPHERD_NEEDS_NAME"] == nil)
        #expect(command(enabled: [], needsName: true).env["SHEPHERD_NEEDS_NAME"] == nil)
    }

    /// Settings ▸ Instructions reach pi through their extension, loaded right after status, and
    /// the directory it reads them from.
    @Test func instructionsAddTheirExtensionAndDirectory() {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: "/tmp/panes.ts", reviewExtensionPath: nil, subagentsExtensionPath: nil,
            instructions: ("/tmp/instructions.ts", "/tmp/support/instructions"),
            model: nil, thinking: nil
        )
        #expect(launch.argv[3].hasSuffix(" -e '/tmp/status.ts' -e '/tmp/support/pi/shepherd-service-tier.ts' -e '/tmp/instructions.ts' -e '/tmp/panes.ts' -e '/tmp/support/pi/shepherd-goal.ts'"))
        #expect(launch.env["SHEPHERD_INSTRUCTIONS_DIR"] == "/tmp/support/instructions")
        #expect(launch.env["SHEPHERD_SUGGEST_FILES"] == nil)
        #expect(command().env["SHEPHERD_INSTRUCTIONS_DIR"] == nil)
    }

    /// Settings ▸ Experiments ▸ Suggested instructions: an agent it is on for learns which files
    /// it may suggest for, through the instructions extension.
    @Test func suggestionsNameTheFilesAnAgentMaySuggestFor() {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil,
            instructions: ("/tmp/instructions.ts", "/tmp/support/instructions"),
            suggestFiles: ["AGENTS.md", "APPEND_SYSTEM.md"],
            model: nil, thinking: nil
        )
        #expect(launch.env["SHEPHERD_SUGGEST_FILES"] == "AGENTS.md,APPEND_SYSTEM.md")
    }

    /// A design's agent loads the design tools last, and learns its design and the skill's folder;
    /// every other agent gets neither.
    @Test func aDesignsAgentLoadsTheDesignTools() {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: "/tmp/panes.ts", reviewExtensionPath: nil, subagentsExtensionPath: nil,
            namerExtensionPath: "/tmp/namer.ts",
            design: ("/tmp/design.ts", DesignID(rawValue: "d1"), "/tmp/support/design-skill"),
            model: nil, thinking: nil
        )
        #expect(launch.argv[3].hasSuffix(" -e '/tmp/panes.ts' -e '/tmp/support/pi/shepherd-goal.ts' -e '/tmp/namer.ts' -e '/tmp/design.ts'"))
        #expect(launch.env["SHEPHERD_DESIGN_ID"] == "d1")
        #expect(launch.env["SHEPHERD_DESIGN_SKILL_DIR"] == "/tmp/support/design-skill")
        let plain = command(enabled: [0, 1, 2, 3, 4])
        #expect(!plain.argv[3].contains("design"))
        #expect(plain.env["SHEPHERD_DESIGN_ID"] == nil && plain.env["SHEPHERD_DESIGN_SKILL_DIR"] == nil)
    }

    /// A design agent's helpers use its design tools through it (docs/designs.md › Helpers): the
    /// children extension reads them from the design extension's registry, so both load into the
    /// agent's one pi, the children with their variables and the design with its own.
    @Test func aDesignsAgentLoadsTheChildrenAndTheDesignToolsIntoOnePi() {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: "/tmp/subagents.ts",
            childrenExtensionPath: "/tmp/children.ts", childEnvironment: ["SHEPHERD_CHILD_CONCURRENCY": "3"],
            design: ("/tmp/design.ts", DesignID(rawValue: "d1"), "/tmp/support/design-skill"),
            model: nil, thinking: nil
        )
        #expect(launch.argv[3].contains(" -e '/tmp/children.ts'") && launch.argv[3].contains(" -e '/tmp/design.ts'"))
        #expect(launch.env["SHEPHERD_NATIVE_CHILDREN"] == "1" && launch.env["SHEPHERD_EXT_CHILDREN"] == "/tmp/children.ts")
        #expect(launch.env["SHEPHERD_DESIGN_ID"] == "d1" && launch.env["SHEPHERD_CHILD_CONCURRENCY"] == "3")
    }

    /// design_get's extension loads for a thread with the setting on, saying whether the thread
    /// already holds a reference (it registers the tool at once) or not (only once one arrives);
    /// a design's agent never gets it, even when asked to.
    @Test(arguments: [(false, false, "on"), (true, false, "granted"), (false, true, nil), (true, true, nil)] as [(Bool, Bool, String?)])
    func aThreadLoadsDesignReferencesAndADesignsAgentNever(granted: Bool, drawsDesign: Bool, mode: String?) {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil,
            design: drawsDesign ? ("/tmp/design.ts", DesignID(rawValue: "d1"), "/tmp/support/design-skill") : nil,
            designReferences: ("/tmp/design-refs.ts", granted),
            model: nil, thinking: nil
        )
        #expect(launch.env["SHEPHERD_DESIGN_REFS"] == mode)
        #expect(launch.argv[3].contains("-e '/tmp/design-refs.ts'") == (mode != nil))
        #expect(command(enabled: [0, 1, 2, 3, 4]).env["SHEPHERD_DESIGN_REFS"] == nil)
    }

    /// Settings ▸ Pi ▸ MCP servers: the extension loads with the config, cache and client it reads,
    /// and a repo's .mcp.json only when Settings ▸ MCP servers allows it; off, none of it.
    @Test(arguments: [false, true])
    func mcpServersBringTheirExtensionAndPaths(useRepoConfig: Bool) {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: "/tmp/panes.ts", reviewExtensionPath: nil, subagentsExtensionPath: nil,
            mcp: MCPLaunch(extensionPath: "/tmp/shepherd-mcp.ts", clientPath: "/tmp/shepherd-mcp-client.mjs",
                           configPath: "/Users/me/.config/mcp/mcp.json", cachePath: "/tmp/support/mcp/tools.json",
                           useRepoConfig: useRepoConfig),
            model: nil, thinking: nil
        )
        #expect(launch.argv[3].hasSuffix(" -e '/tmp/panes.ts' -e '/tmp/support/pi/shepherd-goal.ts' -e '/tmp/shepherd-mcp.ts'"))
        #expect(launch.env["SHEPHERD_EXT_MCP"] == "/tmp/shepherd-mcp.ts")
        #expect(launch.env["SHEPHERD_EXT_MCP_CLIENT"] == "/tmp/shepherd-mcp-client.mjs")
        #expect(launch.env["SHEPHERD_EXT_MCP_CONFIG"] == "/Users/me/.config/mcp/mcp.json")
        #expect(launch.env["SHEPHERD_EXT_MCP_CACHE"] == "/tmp/support/mcp/tools.json")
        #expect(launch.env["SHEPHERD_EXT_MCP_PROJECT"] == (useRepoConfig ? "1" : nil))
        let plain = command(enabled: [0, 1, 2, 3, 4])
        #expect(!plain.argv[3].contains("mcp"))
        #expect(!plain.env.keys.contains { $0.hasPrefix("SHEPHERD_EXT_MCP") })
    }

    /// Settings ▸ Pi ▸ Browser tools: the extension loads with `SHEPHERD_EXT_BROWSER` naming it,
    /// and off (or in a design's agent) none of it does.
    @Test func theBrowserExtensionLoadsWithItsVariableAndNeverInADesignsAgent() {
        func launch(browser: String?, design: DesignID? = nil) -> SessionCommand {
            try! StatusExtension.command(
                home: Self.home, cwd: "/tmp/project",
                agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
                socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
                panesExtensionPath: "/tmp/panes.ts", reviewExtensionPath: nil, subagentsExtensionPath: nil,
                design: design.map { (extensionPath: "/tmp/design.ts", designID: $0, skillDirectory: "/tmp/skill") },
                browserExtensionPath: browser, model: nil, thinking: nil)
        }
        let on = launch(browser: "/tmp/shepherd-browser.ts")
        #expect(on.env["SHEPHERD_EXT_BROWSER"] == "/tmp/shepherd-browser.ts")
        #expect(on.argv[3].hasSuffix(" -e '/tmp/panes.ts' -e '/tmp/support/pi/shepherd-goal.ts' -e '/tmp/shepherd-browser.ts'"))
        let off = launch(browser: nil)
        #expect(off.env["SHEPHERD_EXT_BROWSER"] == nil && !off.argv[3].contains("browser"))
        let drawing = launch(browser: "/tmp/shepherd-browser.ts", design: DesignID())
        #expect(drawing.env["SHEPHERD_EXT_BROWSER"] == nil && !drawing.argv[3].contains("shepherd-browser"),
                "a design's agent has no Browser")
    }

    /// Every agent's pi loads the service tier extension (even a design's) with the agent's own
    /// tier file named; a pi run by hand in a terminal pane gets neither.
    @Test func everyAgentLoadsTheServiceTierExtensionWithItsOwnFile() {
        for design in [nil, DesignID()] as [DesignID?] {
            let launch = try! StatusExtension.command(
                home: Self.home, cwd: "/tmp/project", agentID: AgentID(rawValue: "0F2A-agent"), piSessionID: "s",
                socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
                panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil,
                design: design.map { (extensionPath: "/tmp/design.ts", designID: $0, skillDirectory: "/tmp/skill") },
                model: nil, thinking: nil)
            #expect(launch.argv[3].contains(" -e '/tmp/support/pi/shepherd-service-tier.ts'"))
            #expect(launch.env["SHEPHERD_EXT_SERVICE_TIER"] == "/tmp/support/pi/service-tier/0F2A-agent.json")
        }
        #expect(ShellIntegration.command(shell: ["/bin/zsh"]).env["SHEPHERD_EXT_SERVICE_TIER"] == "")
    }

    /// A terminal pane's shell blanks the variable, so a pi run by hand there loads no browser tools.
    @Test func aTerminalPaneBlanksTheBrowserVariable() {
        #expect(ShellIntegration.command(shell: ["/bin/zsh"]).env["SHEPHERD_EXT_BROWSER"] == "")
    }

    /// One setting decides a repo's .mcp.json (Settings ▸ MCP servers), and Settings ▸ Pi ▸ MCP
    /// servers decides whether the extension loads at all.
    @Test @MainActor func mcpLaunchFollowsTheSettings() {
        let settings = AppSettings(store: ScratchDefaults())
        let environment = ["SHEPHERD_MCP_CONFIG": "/tmp/scratch/mcp.json", "SHEPHERD_SUPPORT_DIR": "/tmp/support"]
        let install = { (extensionPath: "/tmp/support/shepherd-mcp.ts", clientPath: "/tmp/support/shepherd-mcp-client.mjs") }
        #expect(MCPLaunch.forAgents(settings: settings, environment: environment, install: install) == MCPLaunch(
            extensionPath: "/tmp/support/shepherd-mcp.ts", clientPath: "/tmp/support/shepherd-mcp-client.mjs",
            configPath: "/tmp/scratch/mcp.json", cachePath: "/tmp/support/mcp/tools.json", useRepoConfig: false))
        settings.mcpProjectConfig = true
        #expect(MCPLaunch.forAgents(settings: settings, environment: environment, install: install)?.useRepoConfig == true)
        settings.piMCPExtension = false
        #expect(MCPLaunch.forAgents(settings: settings, environment: environment, install: install) == nil)
    }

    /// Watchers must never create watchers.
    @Test func automationAgentsAreMarked() {
        #expect(command(isAutomation: true).env["SHEPHERD_AUTOMATION"] == "1")
        #expect(command().env["SHEPHERD_AUTOMATION"] == nil)
    }

    @Test func modelAndThinkingAreQuotedFlags() {
        let launch = command(enabled: [0], model: "provider/model", thinking: .high)
        #expect(launch.argv[3].contains("--model 'provider/model' --thinking 'high' -e '/tmp/status.ts'"))
        #expect(launch.env["SHEPHERD_MODEL"] == "provider/model")
        #expect(launch.env["SHEPHERD_EXT_PANES"] == "/tmp/panes.ts")
    }

    @Test func singleQuotesInValuesCannotEscapeTheShellCommand() {
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: AgentID(), piSessionID: "it's", socketPath: "/s", extensionPath: "/tmp/a b.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil, model: nil, thinking: nil
        )
        let sessions = Self.home.sessionDirectory(forCwd: "/tmp/project").path
        #expect(launch.argv[3] == #"cd -- '/tmp/project' && exec '/tmp/support/pi/bin/pi' --mode rpc --session-dir '"# + sessions
            + #"' --session-id 'it'"'"'s' -e '/tmp/a b.ts' -e '/tmp/support/pi/shepherd-service-tier.ts' -e '/tmp/support/pi/shepherd-goal.ts'"#)
    }

    /// `/new` and `/resume` move pi to another session; relaunch follows the agent there.
    @Test func theCommandOpensTheAgentsCurrentSessionNotItsID() {
        let agent = Agent(name: "worker", spaceID: SpaceID(), tabID: TabID(), piSessionID: "moved-session")
        let launch = try! StatusExtension.command(
            home: Self.home, cwd: "/tmp/project",
            agentID: agent.id, piSessionID: agent.effectivePiSessionID, socketPath: "/s", extensionPath: "/e",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil, model: nil, thinking: nil
        )
        #expect(launch.argv[3].contains("--session-id 'moved-session'"))
        #expect(launch.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue)
    }
}
