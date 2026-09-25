import Foundation
import ShepherdCore
import Testing
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
    private let paths = ["/tmp/panes.ts", "/tmp/review.ts", "/tmp/subagents.ts", "/tmp/namer.ts", "/tmp/children.ts"]

    private func command(
        enabled: Set<Int> = [],
        needsName: Bool = false,
        isAutomation: Bool = false,
        model: String? = nil,
        thinking: ThinkingLevel? = nil
    ) -> SessionCommand {
        func path(_ index: Int) -> String? { enabled.contains(index) ? paths[index] : nil }
        return StatusExtension.command(
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: path(0), reviewExtensionPath: path(1), subagentsExtensionPath: path(2),
            childrenExtensionPath: path(4), childEnvironment: ["SHEPHERD_CHILD_CONCURRENCY": "7"],
            namerExtensionPath: path(3), needsName: needsName, isAutomation: isAutomation,
            model: model, thinking: thinking
        )
    }

    @Test func aBareAgentIsJustPiOverRPCWithTheStatusExtension() {
        let bare = command()
        #expect(bare.argv == ["/bin/zsh", "-l", "-c", "exec pi --mode rpc --session-id 'current-session' -e '/tmp/status.ts'"])
        #expect(bare.env == [
            "SHEPHERD_AGENT_ID": "agent-id", "SHEPHERD_SOCKET": "/tmp/shepherd.sock", "SHEPHERD_EXT_STATUS": "/tmp/status.ts",
        ])
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
        let launch = StatusExtension.command(
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: "/tmp/panes.ts", reviewExtensionPath: nil, subagentsExtensionPath: nil,
            instructions: ("/tmp/instructions.ts", "/tmp/support/instructions"),
            model: nil, thinking: nil
        )
        #expect(launch.argv[3] == "exec pi --mode rpc --session-id 'current-session' -e '/tmp/status.ts' -e '/tmp/instructions.ts' -e '/tmp/panes.ts'")
        #expect(launch.env["SHEPHERD_INSTRUCTIONS_DIR"] == "/tmp/support/instructions")
        #expect(launch.env["SHEPHERD_SUGGEST_FILES"] == nil)
        #expect(command().env["SHEPHERD_INSTRUCTIONS_DIR"] == nil)
    }

    /// Settings ▸ Experiments ▸ Suggested instructions: an agent it is on for learns which files
    /// it may suggest for, through the instructions extension.
    @Test func suggestionsNameTheFilesAnAgentMaySuggestFor() {
        let launch = StatusExtension.command(
            agentID: AgentID(rawValue: "agent-id"), piSessionID: "current-session",
            socketPath: "/tmp/shepherd.sock", extensionPath: "/tmp/status.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil,
            instructions: ("/tmp/instructions.ts", "/tmp/support/instructions"),
            suggestFiles: ["AGENTS.md", "APPEND_SYSTEM.md"],
            model: nil, thinking: nil
        )
        #expect(launch.env["SHEPHERD_SUGGEST_FILES"] == "AGENTS.md,APPEND_SYSTEM.md")
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
        let launch = StatusExtension.command(
            agentID: AgentID(), piSessionID: "it's", socketPath: "/s", extensionPath: "/tmp/a b.ts",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil, model: nil, thinking: nil
        )
        #expect(launch.argv[3] == #"exec pi --mode rpc --session-id 'it'"'"'s' -e '/tmp/a b.ts'"#)
    }

    /// `/new` and `/resume` move pi to another session; relaunch follows the agent there.
    @Test func theCommandOpensTheAgentsCurrentSessionNotItsID() {
        let agent = Agent(name: "worker", spaceID: SpaceID(), tabID: TabID(), piSessionID: "moved-session")
        let launch = StatusExtension.command(
            agentID: agent.id, piSessionID: agent.effectivePiSessionID, socketPath: "/s", extensionPath: "/e",
            panesExtensionPath: nil, reviewExtensionPath: nil, subagentsExtensionPath: nil, model: nil, thinking: nil
        )
        #expect(launch.argv[3].contains("--session-id 'moved-session'"))
        #expect(launch.env["SHEPHERD_AGENT_ID"] == agent.id.rawValue)
    }
}
