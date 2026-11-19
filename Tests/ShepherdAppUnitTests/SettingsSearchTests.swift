import Testing
@testable import ShepherdApp

/// The Settings search field lists matching rows under their section and jumps to the first
/// section with a match.
@Suite("Settings search")
struct SettingsSearchTests {
    @Test func theNavListsEveryPageInDesignOrder() {
        #expect(SettingsSection.groups.map { $0.sections.map(\.title) } == [
            ["General", "Appearance", "Keyboard"],
            ["Models", "Agents", "Instructions", "Skills", "Tools", "Hooks"],
            ["Spaces", "Git", "Apps", "Fleet"],
            ["Advanced", "Experiments"],
        ])
        #expect(SettingsSection.groups.map(\.title) == [nil, "Agents", "Work", nil])
    }

    /// Sub-pages open from a page and highlight it in the nav.
    @Test func subPagesHighlightTheirParent() {
        #expect(SettingsSection.allCases.filter { $0.parent != nil } == [.subagents, .piSlashCommands, .fromYourPi])
        #expect(SettingsSection.subagents.navSelection == .agents)
        #expect(SettingsSection.piSlashCommands.navSelection == .tools)
        #expect(SettingsSection.fromYourPi.navSelection == .models)
        #expect(SettingsSection.groups.flatMap(\.sections).count + 3 == SettingsSection.allCases.count)
    }

    /// A hit is named by its page and its title, so one title on two pages is two hits.
    @Test func hitsAreKeyedBySectionAndTitle() {
        let hits = SettingsSection.hits(for: "re-import")
        #expect(Set(hits.map(\.id)).count == hits.count)
        #expect(hits.contains(SettingsSearchHit(section: .fromYourPi, item: "Logins")))
        #expect(SettingsSearchHit(section: .models, item: "Instructions").id != SettingsSearchHit(section: .fromYourPi, item: "Instructions").id)
    }

    @Test func everyPageListsItsRows() {
        for section in SettingsSection.allCases {
            #expect(!section.items.isEmpty, "\(section.title) has no searchable rows")
        }
    }

    @Test(arguments: [
        // Row titles, case-insensitively.
        ("font", SettingsSection.appearance, ["Text size", "Font", "Size"]),
        ("SHELL", .appearance, ["Shell"]),
        ("default model", .models, ["Model"]),
        // Keywords people search for that aren't row titles.
        ("dark", .appearance, ["Mode"]),
        ("zoom", .appearance, ["Text size"]),
        ("iphone", .fleet, ["Phones and tablets"]),
        ("qr", .fleet, ["Add a device"]),
        ("port", .fleet, ["Listener"]),
        ("hotkey", .keyboard, ["Shortcuts"]),
        ("nightly", .general, ["Channel"]),
        ("telemetry", .advanced, ["Share diagnostics"]),
        ("privacy", .advanced, ["Share diagnostics"]),
        ("errors", .advanced, ["Share diagnostics"]),
        ("sentry", .advanced, []),
        ("reasoning", .models, ["Thinking"]),
        ("fast mode", .models, ["Speed"]),
        ("service tier", .models, ["Speed"]),
        ("speed", .models, ["Speed"]),
        ("github", .worktrees, ["Close the thread when its PR merges"]),
        ("queue", .agents, ["Send queued messages"]),
        ("steer", .keyboard, ["Shortcuts"]),
        ("all at once", .agents, ["Send queued messages"]),
        ("compaction", .agents, ["Compact at", "Trim old tool output"]),
        ("auto-compact", .agents, ["Compact at"]),
        ("tool results", .agents, ["Trim old tool output"]),
        ("tool search", .agents, ["Load rarely used tools on demand"]),
        ("defer", .agents, ["Load rarely used tools on demand"]),
        ("system prompt", .instructions, ["AGENTS.md", "APPEND_SYSTEM.md"]),
        ("restore", .instructions, ["History"]),
        ("append", .instructions, ["APPEND_SYSTEM.md"]),
        ("lessons", .experiments, ["Suggested instructions"]),
        ("projects", .experiments, ["Projects"]),
        ("new project", .experiments, ["Projects"]),
        ("automations", .experiments, ["Learn from"]),
        ("slash", .skills, ["Show in the / menu"]),
        ("github", .skills, ["Add from repo"]),
        // Every skill Shepherd's pi loads is installed, copies from your pi among them.
        (".pi", .skills, ["Installed"]),
        (".shepherd", .skills, ["Installed"]),
        ("copied", .skills, ["Installed"]),
        ("agent skills", .skills, ["Installed"]),
        ("oauth", .tools, ["In every prompt"]),
        ("exposure", .tools, ["In every prompt"]),
        // Settings ▸ Pi ▸ Sign-in, and what comes from your pi.
        ("auth.json", .models, ["Subscriptions", "API keys"]),
        ("subscription", .models, ["Subscriptions"]),
        ("login", .models, ["Subscriptions"]),
        ("anthropic", .models, ["Anthropic"]),
        ("groq", .models, ["Add an API key"]),
        ("models.json", .models, ["Custom providers"]),
        ("re-import", .fromYourPi, ["Re-import all", "Logins", "Custom providers", "Default model", "Instructions",
                            "Skills", "Prompts", "Themes"]),
        ("CLAUDE.md", .fromYourPi, ["Instructions"]),
        ("full access", .fromYourPi, ["Imported extensions"]),
        // Settings ▸ Slash commands.
        ("hide", .piSlashCommands, ["Off"]),
        ("registerCommand", .piSlashCommands, ["Extensions"]),
        ("argument-hint", .piSlashCommands, ["Prompt templates"]),
        ("turned off", .piSlashCommands, ["Off"]),
        ("engine", .models, ["Shepherd's pi"]),
        ("browser", .tools, ["Browser"]),
        ("text generation", .models, ["Titles and commit messages"]),
        ("session naming", .models, ["Titles and commit messages"]),
        ("vision", .models, ["Describe images for"]),
        ("native subagents", .agents, ["Native subagents"]),
        ("profiles", .subagents, ["New profile"]),
        ("restore defaults", .subagents, ["Restore defaults"]),
        ("claude desktop", .tools, ["Import…"]),
        (".mcp.json", .tools, ["Also use a repo’s .mcp.json"]),
    ] as [(String, SettingsSection, [String])])
    func rowsMatchByTitleOrKeyword(query: String, section: SettingsSection, rows: [String]) {
        #expect(section.matches(for: query) == rows)
    }

    /// Searching the new feature's name finds its experiment, never the Spaces page that used to be called Projects.
    @Test func searchingProjectsFindsTheExperimentAndNotSpaces() {
        for query in ["projects", "new project"] {
            #expect(SettingsSection.allCases.filter { !$0.matches(for: query).isEmpty } == [.experiments], "\(query)")
        }
        #expect(SettingsSection.experiments.items.contains("Projects"))
    }

    @Test func peerPermissionsAreNotListedOrFoundBySearch() {
        for section in SettingsSection.allCases {
            #expect(!section.items.contains("Agent-to-agent messages"))
            #expect(!section.matches(for: "agent-to-agent").contains("Agent-to-agent messages"))
        }
    }

    /// Naming the page lists everything on it.
    @Test(arguments: SettingsSection.allCases)
    func matchingASectionTitleListsAllItsRows(section: SettingsSection) {
        #expect(section.matches(for: "  \(section.title.lowercased()) ") == section.items)
    }

    /// MCP servers' own rows are found by the server's name, after the page's rows.
    @Test func mcpServersAreFoundByName() {
        #expect(SettingsSection.tools.matches(for: "lin", rows: ["linear", "notion"]) == ["linear"])
        #expect(SettingsSection.tools.matches(for: "stdio", rows: ["postgres"]) == ["Add server"])
        #expect(SettingsSection.fleet.matches(for: "lin").isEmpty)
    }

    @Test func aKeywordFindsOnlyTheSectionsThatOwnIt() {
        let hits = SettingsSection.allCases.filter { !$0.matches(for: "dark").isEmpty }
        #expect(hits == [.appearance])
    }

    /// ↩ always queues while pi works and ⌘↩ steers now, so Agents has no Return setting: only how
    /// the queue goes. The keys are Keyboard's.
    @Test func agentsHasNoReturnWhileWorkingSetting() {
        #expect(!SettingsSection.agents.items.contains("Return while the agent is working"))
        #expect(SettingsSection.agents.matches(for: "steer").isEmpty)
        #expect(SettingsSection.agents.matches(for: "next step").isEmpty)
    }

    /// "theme" finds only the themes copied from your pi, never a theme-sync switch.
    @Test func piThemeSyncIsNotASetting() {
        #expect(SettingsSection.fromYourPi.matches(for: "theme") == ["Themes"])
        #expect(!SettingsSection.fromYourPi.items.contains("Sync pi theme"))
    }

    @Test(arguments: ["", "   ", "zzzz-no-such-setting"])
    func emptyOrUnmatchedQueriesListNothing(query: String) {
        for section in SettingsSection.allCases {
            #expect(section.matches(for: query).isEmpty)
        }
    }
}
