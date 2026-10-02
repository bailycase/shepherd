import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol

/// Settings replaces the window content in place. A 232pt nav on `bgBase` (Back to Shepherd,
/// search on ⌘F, the pages, the versions pinned at the bottom) beside a 720pt content column, or
/// a wide page (Instructions, Skills, Experiments) that fills the detail area.
///
/// Everything here is wired: a row exists only if changing it changes the app.
struct SettingsView: View {
    var vm: ShepherdViewModel
    private var themes: ThemeManager { .shared }
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matchingSections: [SettingsSection] {
        guard !query.isEmpty else { return Array(SettingsSection.allCases) }
        return SettingsSection.allCases.filter { !matches($0).isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            nav
            NWHairline(.vertical)
            detail
        }
        .background(Color.nw.bgWindow)
        .background { WindowChrome() }
        .preferredColorScheme(themes.mode.colorScheme)
        .ignoresSafeArea()
        // Settings replaces the window content: it cross-fades in and out on the sheet motion
        // however `showSettings` changed (⌘,, the app menu, Back, Esc, the palette).
        .transition(NW.Motion.content.transition(reduceMotion: reduceMotion)
            .animation(NW.Motion.sheet.animation(reduceMotion: reduceMotion)))
        .onChange(of: searchText) { Self.showFirstMatch(of: matchingSections, in: vm) }
        .background {
            // ⌘F focuses the search field.
            Button("Search settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var nav: some View {
        let sections = matchingSections
        return VStack(alignment: .leading, spacing: 0) {
            // The window controls' strip: draggable, nothing else lives up here.
            Color.clear
                .frame(height: AppLayout.settingsWindowStripHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            Button { vm.showSettings = false } label: {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "chevron.left")
                        .font(.nwSans(NWSettingsNavMetrics.textSize, .semibold))
                        .imageScale(.small)
                        .frame(width: AppLayout.settingsBackGlyphWidth)
                        .accessibilityHidden(true)
                    Text("Back to Shepherd").font(.nwSans(NWSettingsNavMetrics.textSize))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, NW.Space.m)
                .frame(minHeight: AppLayout.settingsBackRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nwRow())
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.horizontal, NWSettingsNavMetrics.sidePadding)

            NWSearchField("Search settings", text: $searchText, shortcut: "⌘F")
                .focused($searchFocused)
                .nwControlScale(.settings)
                .padding(.horizontal, NWSettingsNavMetrics.sidePadding)
                .padding(.top, AppLayout.settingsSearchTop)
                .padding(.bottom, NW.Space.l)
                .task {
                    // Typing filters immediately after opening; delayed a beat because focusing
                    // while SwiftUI installs the key-view loop silently loses the request.
                    try? await Task.sleep(for: .milliseconds(150))
                    searchFocused = true
                }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: AppLayout.settingsNavRowSpacing) {
                    ForEach(sections) { section in
                        if section.isSubpage {
                            NWSettingsNavSubRow(section.title, selected: vm.settingsSection == section,
                                                attention: section == .piSignIn && vm.piSignInNeedsAttention) {
                                vm.settingsSection = section
                            }
                        } else {
                            NWSettingsNavRow(section.title, systemImage: section.symbol, selected: vm.settingsSection == section) {
                                vm.settingsSection = section
                            }
                        }
                        if !query.isEmpty {
                            ForEach(matches(section), id: \.self) { item in
                                SettingsSearchHit(title: item, section: section.title) {
                                    // A server found by name opens with its row open.
                                    vm.mcpOpenServer = section == .mcp && vm.mcp.entry(item) != nil ? item : nil
                                    vm.settingsSection = section
                                }
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text("No matching settings")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                            .padding(.horizontal, NW.Space.m)
                            .padding(.top, NW.Space.xs)
                    }
                }
                .padding(.horizontal, NWSettingsNavMetrics.sidePadding)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
            Text(versions)
                .font(.nw(.micro))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
                // Aligned with the rows' icons.
                .padding(.horizontal, NWSettingsNavMetrics.sidePadding + NWSettingsNavMetrics.rowPadding)
                .padding(.bottom, NW.Space.l)
        }
        .frame(width: AppLayout.settingsNavWidth)
        .background(Color.nw.bgBase.ignoresSafeArea())
    }

    /// A page's hits: its rows' titles, and for MCP servers its servers by name.
    private func matches(_ section: SettingsSection) -> [String] {
        section.matches(for: query, rows: section == .mcp ? vm.mcp.rows.map(\.name) : [])
    }

    /// Searching shows the first page with a match when the current one has none. It lands at
    /// once: the page cross-fades when it is picked, never per keystroke.
    static func showFirstMatch(of sections: [SettingsSection], in vm: ShepherdViewModel) {
        guard let first = sections.first, !sections.contains(vm.settingsSection) else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { vm.settingsSection = first }
    }

    private var versions: String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return Self.versions(app: "\(ShepherdEdition.current.displayName) \(app)", agent: vm.server.pi.engine.version,
                             on: vm.settingsSection)
    }

    /// "Shepherd 0.1.0 · agent 0.87.1", or "Shepherd Nightly 0.0.0-nightly.… · agent 0.87.1".
    /// The Pi pages name the program: "· pi 0.87.1", as the SettingsPi boards draw.
    static func versions(app: String, agent: String?, on section: SettingsSection) -> String {
        app + (agent.map { " · \(section.isPi ? "pi" : "agent") \($0)" } ?? "")
    }

    @ViewBuilder private var page: some View {
        switch vm.settingsSection {
        case .appearance: AppearanceSettings(vm: vm)
        case .terminal: TerminalSettings(vm: vm)
        case .agents: AgentSettings(pi: vm.server.pi, settings: vm.settings)
        case .pi: PiSettings(pi: vm.server.pi, settings: vm.settings)
        case .piSignIn: PiSignInSettings(yourPi: vm.yourPi, auth: vm.piAuth)
        case .piFromYourPi: FromYourPiSettings(model: vm.yourPi, openSkills: { vm.settingsSection = .skills })
        case .piSlashCommands: SlashCommandsSettings(model: vm.slashCommands, settings: vm.settings)
        case .worktrees: WorktreeSettings()
        case .instructions: InstructionsSettings(model: vm.instructions)
        case .skills: SkillsSettings(vm: vm, model: vm.skills)
        case .mcp: MCPSettings(vm: vm, store: vm.mcp, initiallyExpanded: vm.mcpOpenServer)
        case .remote: RemoteSettings(vm: vm, store: vm.remoteHosts)
        case .keyboard: KeyboardSettings(vm: vm)
        case .advanced: AdvancedSettings(vm: vm)
        case .experiments:
            ExperimentsSettings(model: vm.suggestions, instructions: vm.instructions, settings: vm.settings) { vm.settingsSection = .instructions }
        }
    }

    private var detail: some View {
        Group {
            if vm.settingsSection.isWide {
                // A wide page fills the area and scrolls inside itself (its editor, its side column).
                Group { page }
                    .nwTransition(.content)
                    .padding(.top, AppLayout.settingsWideTop)
                    .padding(.horizontal, AppLayout.settingsWideSides)
                    .padding(.bottom, AppLayout.settingsWideBottom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical) {
                    Group { page }
                        .nwTransition(.content)
                        .frame(maxWidth: AppLayout.settingsContentWidth, alignment: .leading)
                        .padding(.top, AppLayout.settingsTop)
                        .padding(.bottom, AppLayout.settingsBottom)
                        .padding(.horizontal, AppLayout.settingsGutter)
                        .frame(maxWidth: .infinity)
                        // A page picked in the nav cross-fades in place; search switches pages at once.
                        .nwAnimation(.content, value: vm.settingsSection)
                }
                .scrollContentBackground(.hidden)
                .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: vm.settingsSection.isWide)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) {
            // The window has no title bar; the strip above the content still drags it.
            Color.clear.frame(height: AppLayout.settingsWindowStripHeight).contentShape(Rectangle()).gesture(WindowDragGesture())
        }
    }
}

/// A row found by the search, listed under its page: jumps to the page.
private struct SettingsSearchHit: View {
    let title: String
    let section: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.nw(.caption))
                .foregroundStyle(Color.nw.textSecondary)
                .lineLimit(1)
                .padding(.leading, NWSettingsNavMetrics.rowPadding + NWSettingsNavMetrics.iconSize + NWSettingsNavMetrics.iconGap)
                .frame(maxWidth: .infinity, minHeight: NW.Height.controlS, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow())
        .accessibilityLabel("\(title), in \(section)")
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, terminal, agents, worktrees, pi, piSignIn, piFromYourPi, piSlashCommands, instructions, skills, mcp, remote, keyboard, advanced, experiments

    /// A page listed under another in the nav: Pi's Sign-in, From your pi and Slash commands.
    var isSubpage: Bool { self == .piSignIn || self == .piFromYourPi || self == .piSlashCommands }

    /// One of the Pi pages, whose footer names the program.
    var isPi: Bool { self == .pi || isSubpage }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        case .worktrees: return "Worktrees"
        case .pi: return "Pi"
        case .piSignIn: return "Sign-in"
        case .piFromYourPi: return "From your pi"
        case .piSlashCommands: return "Slash commands"
        case .instructions: return "Instructions"
        case .skills: return "Skills"
        case .mcp: return "MCP servers"
        case .remote: return "Remote"
        case .keyboard: return "Keyboard"
        case .advanced: return "Advanced"
        case .experiments: return "Experiments"
        }
    }

    /// Row titles on the page, as the search lists them under the section.
    var items: [String] {
        switch self {
        case .appearance: ["Theme", "Mode", "Organize by", "Group by host", "Keep idle threads", "Sidebar rows", "Density", "Text size",
                           "Sidebar width"]
        case .terminal: ["Font family", "Font size", "Shell"]
        case .agents: ["Default model", "Default thinking level", "Speed for new threads",
                       "When a turn ends, send the queue", "Compact at", "Trim old tool output from the model’s context"]
        case .worktrees: ["Base branch", "Fetch before creating", "Commit remaining work", "Generate PR descriptions", "Delete local branch", "Merge PR automatically"]
        case .pi: ["Shepherd's pi", "Name agents automatically", "Terminals and agent tools", "Agent-to-agent messages", "Diff review tool", "Native subagents",
                   "Subagent display", "MCP servers", "Browser tools", "Concurrency"]
        case .piSignIn: ["Re-import from your pi", "Subscriptions", "Anthropic", "OpenAI Codex", "GitHub Copilot", "xAI", "Kimi", "Radius",
                         "API keys", "Add an API key", "CLIProxyAPI", "Custom providers"]
        case .piFromYourPi: ["Source", "Last brought over", "Re-import all", "Logins", "Custom providers", "Default model", "Trusted folders",
                             "Instructions", "Skills", "Prompts", "Themes", "Extensions"]
        case .piSlashCommands: ["Search commands", "Extensions", "Prompt templates", "Skills", "Hidden commands"]
        case .instructions: ["Same on every host", "AGENTS.md", "APPEND_SYSTEM.md", "History"]
        case .skills: ["Installed skills", "Browse skills.sh", "Add from repo",
                       "Skills in the / menu", "Same skills on every host", "Update automatically"]
        case .mcp: ["Servers", "Add server", "Import…", "How the agent uses them", "Same servers on every host",
                    "Also use a repo’s .mcp.json", "Hosts"]
        case .remote: ["Hosts", "Add host", "Listener", "Token"]
        case .keyboard: ["Shortcuts", "Reset all shortcuts"]
        case .advanced: ["Workspace state", "Extension socket", "Update channel", "Check for updates", "Reset settings"]
        case .experiments: ["Goals", "Suggested instructions", "Learn from", "Can suggest for", "Waiting for you", "Added from suggestions",
                            "Design tool"]
        }
    }

    /// Words people search for that aren't row titles ("dark" → Appearance).
    private var keywords: [String: [String]] {
        switch self {
        case .appearance: ["Mode": ["dark", "light", "color", "night watch", "theme"], "Text size": ["font", "zoom", "scale"], "Sidebar rows": ["row height", "comfortable"], "Density": ["compact", "spacing"],
                           "Organize by": ["projects", "activity", "folders", "sidebar style", "tree"],
                           "Group by host": ["hosts", "machines"], "Keep idle threads": ["archive", "idle"]]
        case .terminal: ["Font family": ["ghostty", "monospace"], "Shell": ["zsh", "bash", "fish"]]
        case .agents: ["Default model": ["claude", "gpt", "provider"], "Default thinking level": ["reasoning", "effort"],
                       "Speed for new threads": ["fast", "fast mode", "priority", "service tier", "codex", "openai", "standard"],
                       "When a turn ends, send the queue": ["queue", "follow-up", "one per turn", "all at once"],
                       "Compact at": ["compaction", "compacting", "context window", "percent", "full", "tokens", "auto-compact"],
                       "Trim old tool output from the model’s context": ["tool results", "clear", "clipping", "context", "tokens", "compaction",
                                                                     "screenshots", "cache"]]
        case .worktrees: ["Base branch": ["git", "origin"], "Merge PR automatically": ["github", "pull request"]]
        case .pi: ["Native subagents": ["children", "workflows"], "Shepherd's pi": ["version", "engine", "home", "folder"],
                   "Agent-to-agent messages": ["agent_send", "agent_spawn", "message", "steer", "peer", "threads", "approve", "allow",
                                               "ask", "permission", "never", "dialog"]]
        case .piSignIn: ["Subscriptions": ["login", "log in", "sign in", "oauth", "subscription", "auth.json", "claude", "chatgpt", "copilot",
                                           "sign out", "expired"],
                         "API keys": ["api key", "key", "environment", "variable", "auth.json", "sign out"],
                         "Add an API key": ["groq", "mistral", "openrouter", "deepseek"],
                         "CLIProxyAPI": ["cpa", "proxy", "server", "connection", "refresh models"],
                         "Custom providers": ["models.json", "ollama", "gateway"],
                         "Re-import from your pi": ["import", "copy", "your pi"]]
        case .piFromYourPi: ["Source": ["~/.pi/agent", "terminal pi", "your pi"], "Re-import all": ["import", "re-import", "copy"],
                             "Logins": ["re-import", "auth.json", "sign-ins"],
                             "Custom providers": ["models.json", "re-import"], "Default model": ["re-import", "provider"],
                             "Trusted folders": ["trust.json", "project trust", "re-import"],
                             "Instructions": ["AGENTS.md", "CLAUDE.md", "SYSTEM.md", "APPEND_SYSTEM.md", "context", "re-import"],
                             "Skills": ["SKILL.md", "re-import"], "Prompts": ["prompt templates", "re-import"], "Themes": ["re-import"],
                             "Extensions": ["packages", "npm", "full access", "switch on", "didn't load"]]
        case .piSlashCommands: ["Search commands": ["slash", "/ menu", "command", "composer", "hide", "turn off", "switch"],
                                "Extensions": ["registerCommand", "pi extensions"],
                                "Prompt templates": ["prompts", "templates", "argument-hint"],
                                "Skills": ["skill:", "SKILL.md"],
                                "Hidden commands": ["off", "hidden", "turned off", "switched off"]]
        case .instructions: ["Same on every host": ["sync", "hosts"], "AGENTS.md": ["system prompt", "how you work", "context"],
                             "APPEND_SYSTEM.md": ["system prompt", "override"], "History": ["restore", "undo"]]
        case .skills: ["Installed skills": ["SKILL.md", ".agents", "agent skills", "from your pi", "copied", ".pi"],
                       "Browse skills.sh": ["directory", "search", "install"],
                       "Add from repo": ["github", "git", "folder"], "Skills in the / menu": ["slash", "command", "composer"],
                       "Same skills on every host": ["sync", "hosts"], "Update automatically": ["update", "upgrade"]]
        case .mcp: ["Servers": ["mcp", "model context protocol", "tools", "connectors", "mcp.json"],
                    "Add server": ["remote", "local", "url", "command", "stdio", "http", "sse"],
                    "Import…": ["claude desktop", "cursor", "vs code", "paste json", "mcpServers"],
                    "How the agent uses them": ["tokens", "prompt", "budget", "search", "direct", "tool search", "exposure", "oauth", "sign in", "login"],
                    "Also use a repo’s .mcp.json": ["project", "repository", ".mcp.json"]]
        case .remote: ["Hosts": ["vpn", "tailscale", "ssh"], "Listener": ["port", "serve"]]
        case .keyboard: ["Shortcuts": ["hotkey", "keybinding", "chord", "steer", "queue"]]
        case .advanced: ["Update channel": ["beta", "nightly", "sparkle"], "Workspace state": ["state.json"]]
        case .experiments: ["Suggested instructions": ["lessons", "learned"], "Learn from": ["threads", "automations"],
                            "Design tool": ["designs", "boards", "mockups"]]
        }
    }

    /// Items matching `query` by title or keyword; every item when the section's name matches.
    /// `rows` are the page's own rows found by name (MCP servers' servers).
    func matches(for query: String, rows: [String] = []) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if title.localizedCaseInsensitiveContains(query) { return items }
        return items.filter { item in
            item.localizedCaseInsensitiveContains(query)
                || (keywords[item] ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        } + rows.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var symbol: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .terminal: return "terminal"
        case .agents: return "person.2"
        case .worktrees: return "arrow.branch"
        case .pi: return "pi"
        case .piSignIn: return "key"
        case .piFromYourPi: return "square.and.arrow.down"
        case .piSlashCommands: return "slash.circle"
        case .instructions: return "doc.text"
        case .skills: return "graduationcap"
        case .mcp: return "server.rack"
        case .remote: return "dot.radiowaves.left.and.right"
        case .keyboard: return "keyboard"
        case .advanced: return "gearshape"
        case .experiments: return "flask"
        }
    }

    /// A wide page fills the detail area instead of the 720pt column.
    var isWide: Bool { self == .instructions || self == .skills || self == .mcp || self == .experiments }
}
