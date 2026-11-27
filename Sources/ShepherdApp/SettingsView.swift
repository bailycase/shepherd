import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol

/// Settings is a modal over the window (`SettingsOverlay`). A 220pt nav on `bgBase` (search on ⌘F,
/// the pages in three groups, no icons) beside one centered 620pt column; Spaces fills the detail
/// area. Esc goes up a level: a sub-page to its parent, a page out of Settings.
///
/// Everything here is wired: a row exists only if changing it changes the app.
struct SettingsView: View {
    var vm: ShepherdViewModel
    private var themes: ThemeManager { .shared }
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The search's hits; a server found by name is a hit on Tools.
    private var hits: [SettingsSearchHit] { SettingsSection.hits(for: query, rows: [.tools: vm.mcp.rows.map(\.name)]) }

    /// Pages with a hit, or whose name matches; every page when not searching.
    private var matchingSections: [SettingsSection] {
        guard !query.isEmpty else { return SettingsSection.allCases }
        let hit = Set(hits.map(\.section))
        return SettingsSection.allCases.filter { hit.contains($0) || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            nav
            SHHairline(.vertical, width: SHSettingsNavMetrics.borderWidth)
            detail
        }
        .background(Color.sh.bgWindow)
        .overlay {
            if vm.settingsSection == .projects, vm.projects.showingBrowser,
               let project = vm.projects.selected, let removal = vm.projectCookies.pending {
                ProjectBrowserSettings(model: vm.projectCookies, project: project, scope: vm.cookieScope(for: project)).confirmation(removal)
            }
            if vm.settingsSection == .projects, vm.projects.selected != nil, vm.projects.pending != nil,
               vm.projects.category == .pi, !vm.projects.showingSettingsJSON, !vm.projects.showingBrowser, !vm.projects.showingHooks {
                SpaceSettingsLeaveDialog(model: vm.projects)
            }
            if vm.settingsSection == .projects, let project = vm.projects.selected,
               vm.projects.category == .skills, !vm.projects.showingBrowser, !vm.projects.showingHooks {
                SpaceResourceDialogs(projects: vm.projects, project: project)
            }
        }
        .preferredColorScheme(themes.mode.colorScheme)
        .onChange(of: searchText) { Self.showFirstMatch(of: matchingSections, in: vm) }
        .background {
            // ⌘F focuses the search field.
            Button("Search settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            // Esc: out of a sub-page, or out of Settings. Invisible; VoiceOver still finds the way back.
            Button("Back to Shepherd") { goBack() }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.plain)
                .foregroundStyle(.clear)
        }
    }

    private var nav: some View {
        let hits = self.hits
        let matching = Set(matchingSections.map(\.navSelection))
        let groups = SettingsSection.groups.map { group in
            (title: group.title, sections: group.sections.filter { matching.contains($0) })
        }.filter { !$0.sections.isEmpty }
        return VStack(alignment: .leading, spacing: 0) {
            SHSettingsSearchField("Search", text: $searchText, placement: .navigation)
                .focused($searchFocused)
                .padding(.horizontal, SHSettingsNavMetrics.sidePadding)
                .padding(.top, SHSettingsNavMetrics.topPadding)
                .padding(.bottom, SH.Space.m)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SHSettingsNavMetrics.groupGap) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 0) {
                            if let title = group.title {
                                SHSectionHeader(title, style: .settingsNav)
                                    .padding(.horizontal, SH.Space.m)
                                    .padding(.bottom, SHSettingsNavMetrics.groupHeaderBottom)
                                    .frame(height: SHSettingsNavMetrics.groupHeaderHeight, alignment: .bottomLeading)
                            }
                            ForEach(group.sections) { section in
                                SHSettingsNavRow(section.title, selected: vm.settingsSection.navSelection == section,
                                                 attention: section == .models && vm.piSignInNeedsAttention) {
                                    navigate(to: section)
                                }
                                if !query.isEmpty {
                                    ForEach(hits.filter { $0.section.navSelection == section }) { hit in
                                        SettingsSearchHitRow(hit: hit) {
                                            // A server found by name opens with its row open.
                                            vm.mcpOpenServer = hit.isServer && vm.mcp.entry(hit.item) != nil ? hit.item : nil
                                            navigate(to: hit.section)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if groups.isEmpty {
                        Text("No matching settings")
                            .font(.sh(.caption))
                            .foregroundStyle(Color.sh.textTertiary)
                            .padding(.horizontal, SH.Space.m)
                            .padding(.top, SH.Space.xs)
                    }
                }
                .padding(.horizontal, SHSettingsNavMetrics.sidePadding)
                .padding(.bottom, SH.Space.l)
            }
            .scrollIndicators(.hidden)
        }
        .disabled((vm.settingsSection == .projects && (vm.projectCookies.pending != nil || vm.projectCookies.clearing)) ||
                  (vm.settingsSection == .subagents && ((vm.subagentDefinitions.busy && vm.subagentDefinitions.editing) || vm.subagentDefinitions.confirmation != nil)))
        .accessibilityHidden((vm.settingsSection == .projects && vm.projectCookies.pending != nil) ||
                             (vm.settingsSection == .subagents && vm.subagentDefinitions.confirmation != nil))
        .frame(width: SHSettingsNavMetrics.width - SHSettingsNavMetrics.borderWidth)
        .background(Color.sh.bgGlass.ignoresSafeArea())
    }

    private func navigate(to section: SettingsSection) {
        if vm.settingsSection == .subagents { vm.subagentDefinitions.leave { vm.settingsSection = section } }
        else { vm.settingsSection = section }
    }

    /// The drill-in the current page has open (an editor, a skill, a server, a space): its parent's
    /// title and how to close it. Esc and the "‹" button both go through it.
    private var drill: (parent: String, close: () -> Void)? {
        switch vm.settingsSection {
        case .instructions where vm.instructions.editing: ("Instructions", { vm.instructions.editing = false })
        case .subagents where vm.subagentDefinitions.editing: ("Profiles", { vm.subagentDefinitions.back() })
        case .skills where vm.skillsOpenSkill != nil: ("Skills", { vm.skillsOpenSkill = nil })
        case .experiments where vm.experimentsPage != nil: ("Experiments", { vm.experimentsPage = nil })
        case .tools where vm.mcpOpenServer != nil: ("Tools", { vm.mcpOpenServer = nil })
        default: nil
        }
    }

    /// Esc: the guards the Back row had, then up to the parent page, or out of Settings.
    private func goBack() {
        if vm.projectCookies.pending != nil { vm.projectCookies.pending = nil; return }
        guard !vm.projectCookies.clearing else { return }
        if vm.settingsSection == .projects, vm.projects.selected != nil {
            if !vm.projects.saving && !vm.projects.resources.saving { Task { await vm.projects.stepBack() } }
            return
        }
        if let drill { drill.close(); return }
        let leave = {
            if let parent = vm.settingsSection.parent { vm.settingsSection = parent } else { vm.showSettings = false }
        }
        if vm.settingsSection == .subagents { vm.subagentDefinitions.leave(leave) } else { leave() }
    }

    /// Searching shows the first page with a match when the current one has none. It lands at
    /// once: the page cross-fades when it is picked, never per keystroke.
    static func showFirstMatch(of sections: [SettingsSection], in vm: ShepherdViewModel) {
        guard let first = sections.first, !sections.contains(vm.settingsSection) else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        if vm.settingsSection == .subagents && vm.subagentDefinitions.dirty { return }
        withTransaction(instant) { vm.settingsSection = first }
    }

    /// The page: every Settings page is this host's own; Fleet shares the content that crosses hosts.
    @ViewBuilder private var page: some View {
        if let back = drill?.parent ?? vm.settingsSection.parent?.title {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Button { goBack() } label: {
                    Text("‹ \(back)").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                }
                .buttonStyle(.plain)
                .shFocusRing(radius: SH.Radius.xs, color: .sh.running)
                .accessibilityLabel("Back to \(back)")
                localPage
            }
        } else {
            localPage
        }
    }

    @ViewBuilder private var localPage: some View {
        switch vm.settingsSection {
        case .general: GeneralSettings(vm: vm)
        case .appearance: AppearanceSettings(vm: vm)
        case .keyboard: KeyboardSettings(vm: vm)
        case .models: ModelsSettings(pi: vm.pi, yourPi: vm.yourPi, auth: vm.piAuth, settings: vm.settings,
                                     openYourPi: { vm.settingsSection = .fromYourPi }, openExtensions: {
                                         vm.settingsSection = .tools
                                         vm.settingsScrollTarget = ExtensionsSettingsGroup.scrollID
                                     }, openExtension: { destination in
                                         vm.settingsSection = .tools
                                         vm.settingsScrollTarget = ExtensionsSettingsGroup.rowScrollID(destination)
                                     })
        case .fromYourPi: FromYourPiSettings(model: vm.yourPi) { vm.settingsSection = .tools }
        case .agents: AgentSettings(pi: vm.pi, settings: vm.settings, profiles: vm.subagentDefinitions.definitions.map(\.name)) { vm.settingsSection = .subagents }
        case .subagents: SubagentsSettings(model: vm.subagentDefinitions, settings: vm.settings)
        case .instructions: InstructionsSettings(model: vm.instructions)
        case .skills: SkillsSettings(vm: vm, model: vm.skills)
        case .tools: ToolsSettings(vm: vm, store: vm.mcp, settings: vm.settings) { vm.settingsSection = .piSlashCommands }
        case .piSlashCommands: SlashCommandsSettings(model: vm.slashCommands, settings: vm.settings)
        case .hooks: HooksSettings(model: vm.hooks)
        case .projects: ProjectsSettings(vm: vm, model: vm.projects)
        case .worktrees: WorktreeSettings()
        case .apps: AppsSettings(vm: vm, model: vm.apps)
        case .fleet:
            FleetSettings(model: vm.fleet, serviceKeepsRunning: vm.backgroundServiceStatus?.keepsAgentsRunning,
                          serve: FleetServe(isOn: Binding(get: { vm.remoteListenerEnabled }, set: { vm.setRemoteListenerEnabled($0) }),
                                            status: vm.remoteListenerStatus, problem: vm.remoteListenerProblem,
                                            problemDetail: vm.remoteListenerProblemDetail),
                          notInFleet: vm.remoteHosts.notInFleet.map {
                              FleetNotInFleetMac(id: $0.id, name: $0.name, host: $0.host, port: $0.port)
                          },
                          dismissNotInFleet: { vm.remoteHosts.dismissNotInFleet(id: $0) },
                          code: FleetCodeSettings(
                              uncommitted: vm.settings.fleetUncommitted, setUncommitted: { vm.settings.fleetUncommitted = $0 },
                              spaces: vm.state.spaces.filter { !$0.hidden && $0.repoKey != nil }.map {
                                  FleetExcludeSpace(id: $0.id, name: $0.name, excludes: vm.settings.fleetExcludes(of: $0.id))
                              },
                              setExcludes: { vm.settings.setFleetExcludes($1, of: $0) }),
                          dispatch: FleetDispatchControls(
                              autoDispatch: Binding(get: { vm.settings.autoDispatch(pairedMacs: vm.fleetPage.snapshot.peers.count) },
                                                    set: { vm.settings.fleetAutoDispatch = $0 }),
                              threadsCanSend: Binding(get: { vm.settings.fleetThreadsCanSend }, set: { vm.settings.fleetThreadsCanSend = $0 }),
                              threadCap: Binding(get: { vm.settings.fleetThreadCap }, set: { vm.settings.fleetThreadCap = $0 }),
                              batteryCountsHalf: Binding(get: { vm.settings.fleetBatteryCountsHalf }, set: { vm.settings.fleetBatteryCountsHalf = $0 })))
                .task { await vm.refreshRemoteListener() }
        case .advanced: AdvancedSettings(vm: vm)
        case .experiments:
            ExperimentsSettings(model: vm.suggestions, instructions: vm.instructions, settings: vm.settings,
                                page: Binding(get: { vm.experimentsPage }, set: { vm.experimentsPage = $0 })) { vm.settingsSection = .instructions }
        }
    }

    private var detail: some View {
        Group {
            if vm.settingsSection == .projects && vm.projects.selected != nil {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    Group { page }
                        .shTransition(.content)
                        .frame(maxWidth: AppLayout.settingsColumnWidth, alignment: .leading)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("SettingsPageContent")
                        .padding(.top, AppLayout.settingsTop)
                        .padding(.bottom, AppLayout.settingsBottom)
                        .padding(.horizontal, SH.Space.xxxl)
                        // The one column, centered; a page picked in the nav cross-fades in place and
                        // search switches pages at once.
                        .frame(maxWidth: .infinity)
                        .shAnimation(.content, value: vm.settingsSection)
                }
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    // The page fades into the modal's foot (the board's 32pt `gs-scroll` shade).
                    LinearGradient(colors: [Color.sh.bgWindow.opacity(0), Color.sh.bgWindow], startPoint: .top, endPoint: .bottom)
                        .frame(height: AppLayout.settingsFadeHeight)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .shTransition(.content)
                // A link into another page's group (Sign-in's Add a provider): after the page lays out.
                .task(id: vm.settingsScrollTarget) {
                    guard let target = vm.settingsScrollTarget else { return }
                    await Task.yield()
                    withAnimation(SH.Motion.content.animation(reduceMotion: false)) { proxy.scrollTo(target, anchor: .top) }
                    vm.settingsScrollTarget = nil
                }
                }
            }
        }
        .shAnimation(.content, value: vm.settingsSection == .projects && vm.projects.selected != nil)
        .background(Color.sh.bgWindow)
    }

    /// ✕ and a click on the scrim: out of Settings, through an unsaved profile's guard.
    static func close(_ vm: ShepherdViewModel) {
        guard vm.projectCookies.pending == nil, !vm.projectCookies.clearing else { return }
        let leave = { vm.showSettings = false }
        if vm.settingsSection == .subagents { vm.subagentDefinitions.leave(leave) } else { leave() }
    }
}

/// Settings as a modal (SettingsModal): 980 × 680 at most, centered over the window on its scrim,
/// radius 12 with a `lineStrong` line and the popover's shadow, ✕ in its top-right corner.
struct SettingsOverlay: View {
    var vm: ShepherdViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if vm.showSettings {
                    Color.sh.modalScrim
                        .contentShape(Rectangle())
                        .onTapGesture { SettingsView.close(vm) }
                        .accessibilityHidden(true)
                        .shTransition(.content)
                    let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
                    SettingsView(vm: vm)
                        .clipShape(shape)
                        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.l)
                        .shFloatBackground(shape.fill(Color.sh.bgWindow))
                        .overlay(alignment: .topTrailing) {
                            Button { SettingsView.close(vm) } label: {
                                Image(systemName: "xmark")
                                    .font(.sh(.caption))
                                    .foregroundStyle(Color.sh.textSecondary)
                                    .frame(width: SH.Height.controlS, height: SH.Height.controlS)
                                    .background(Color.sh.bgHover, in: Circle())
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .shHelp("Close (Esc)")
                            .accessibilityLabel("Close settings")
                            .padding(SH.Space.l)
                        }
                        .frame(width: min(AppLayout.settingsModalWidth, geo.size.width - 2 * AppLayout.settingsModalMargin),
                               height: min(AppLayout.settingsModalHeight, geo.size.height - 2 * AppLayout.settingsModalMargin))
                        // VoiceOver stays inside Settings while it is up.
                        .accessibilityAddTraits(.isModal)
                        .shTransition(.overlay, anchor: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(vm.showSettings)
        // However `showSettings` changed: ⌘,, the app menu, ✕, Esc, the palette.
        .shAnimation(.overlay, value: vm.showSettings)
    }
}

/// A row found by the search, listed under its page: jumps to the page.
private struct SettingsSearchHitRow: View {
    let hit: SettingsSearchHit
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(hit.item)
                .font(.sh(.caption))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .padding(.leading, SHSettingsNavMetrics.rowPadding + SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: SH.Height.controlS, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(radius: SH.Radius.m))
        .accessibilityLabel("\(hit.item), in \(hit.section.title)")
    }
}

/// A row the search found: its page and its title, which together name it.
struct SettingsSearchHit: Identifiable, Hashable {
    let section: SettingsSection
    let item: String
    /// A row found by its own name (an MCP server), not a titled row: a server named like a toggle keeps its own hit.
    var isServer = false
    var id: String { "\(section.rawValue)/\(isServer ? "server/" : "")\(item)" }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    // The nav's order, then the pages under another.
    case general, appearance, keyboard
    case models, agents, instructions, skills, tools, hooks
    case projects, worktrees, apps, fleet
    case advanced, experiments
    case subagents, piSlashCommands, fromYourPi

    var id: String { rawValue }

    /// The nav's groups: a label for each run of pages, or none.
    static let groups: [(title: String?, sections: [SettingsSection])] = [
        (nil, [.general, .appearance, .keyboard]),
        ("Agents", [.models, .agents, .instructions, .skills, .tools, .hooks]),
        ("Work", [.projects, .worktrees, .apps, .fleet]),
        (nil, [.advanced, .experiments]),
    ]

    /// The page a sub-page opens from; nil for a page in the nav.
    var parent: SettingsSection? {
        switch self {
        case .subagents: .agents
        case .piSlashCommands: .tools
        case .fromYourPi: .models
        default: nil
        }
    }

    /// The nav row this page highlights.
    var navSelection: SettingsSection { parent ?? self }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .keyboard: return "Keyboard"
        case .models: return "Models"
        case .agents: return "Agents"
        case .instructions: return "Instructions"
        case .skills: return "Skills"
        case .tools: return "Tools"
        case .hooks: return "Hooks"
        case .projects: return "Spaces"
        case .worktrees: return "Git"
        case .apps: return "Apps"
        case .fleet: return "Fleet"
        case .advanced: return "Advanced"
        case .experiments: return "Experiments"
        case .subagents: return "Subagents"
        case .piSlashCommands: return "Slash commands"
        case .fromYourPi: return "Your pi"
        }
    }

    /// Row titles on the page, as the search lists them under the section.
    var items: [String] {
        switch self {
        case .general: ["Keep agents running", "Turn finished", "Open files in", "By file type", "Channel", "Check automatically", "Version"]
        case .appearance: ["Mode", "Sidebar rows", "Density", "Text size", "Sidebar width", "Organize by", "Keep idle threads",
                           "Font", "Size", "Shell"]
        case .models: ["Re-import from pi", "Subscriptions", "Anthropic", "OpenAI Codex", "GitHub Copilot", "xAI", "Kimi", "Radius",
                       "API keys", "Add an API key", "Add a provider", "Custom providers",
                       "Model", "Thinking", "Speed", "Titles and commit messages", "Describe images for",
                       "Shepherd's pi", "Models", "Your pi"]
        case .agents: ["Send queued messages", "Threads can start threads", "Where they work", "Compact at",
                       "Trim old tool output", "Load rarely used tools on demand", "Codemode",
                       "Native subagents", "Show subagent runs", "Run at most", "Model", "Thinking", "Context", "Profiles"]
        case .worktrees: ["Branch from", "Fetch first", "Draft commit messages", "Close the thread when its PR merges", "Worktree"]
        case .subagents: ["New profile", "Restore defaults", "Where they live"]
        case .projects: ["Add space", "Instructions", "Pi settings", "Skills", "Extensions", "MCP servers"]
        case .fromYourPi: ["Last brought over", "Re-import all", "Logins", "Custom providers", "Default model",
                           "Instructions", "Skills", "Prompts", "Themes", "Extensions"]
        case .tools: ["Add server", "Import…", "Also use a repo’s .mcp.json",
                      "Terminals and agent tools", "Diff review", "MCP servers", "Browser", "Subscription usage", "Design references",
                      "Extensions", "Commands in the / menu"]
        case .piSlashCommands: ["Off", "Extensions", "Prompt templates", "Skills"]
        case .apps: ["Add app", "On this Mac", "Run", "Quick action"]
        case .hooks: ["Add hook", "Yours", "Claude Code", "Codex"]
        case .instructions: ["AGENTS.md", "APPEND_SYSTEM.md", "History"]
        case .skills: ["Installed", "Browse skills.sh", "Add from repo", "Show in the / menu", "Update automatically"]
        case .fleet: ["Auto", "Threads can send work to other Macs", "At most per thread", "On battery", "Uncommitted changes",
                      "Ignored files", "Macs", "Add a Mac", "Join a fleet", "Phones and tablets", "Add a device", "Revoke", "Listener"]
        case .keyboard: ["Shortcuts", "Reset all shortcuts"]
        case .advanced: ["Share diagnostics", "Workspace state", "Extension socket", "Confirmations you skipped", "All settings"]
        case .experiments: ["Suggested instructions", "Waiting", "Learn from", "Can suggest for", "Where lines go",
                            "Design tool", "Goals", "Projects", "Computer use", "Allowed apps"]
        }
    }

    /// Words people search for that aren't row titles ("dark" → Appearance).
    private var keywords: [String: [String]] {
        switch self {
        case .general: ["Turn finished": ["banner", "notification", "alert", "notify", "finished"],
                        "Keep agents running": ["quit", "login items", "background"],
                        "Open files in": ["editor", "xcode", "zed", "vs code", "textedit", "links"],
                        "Channel": ["beta", "nightly", "sparkle", "update channel"],
                        "Check automatically": ["updates", "sparkle"], "Version": ["check for updates", "agent"]]
        case .appearance: ["Mode": ["dark", "light", "color", "shepherd design", "theme"], "Text size": ["font", "zoom", "scale"], "Sidebar rows": ["row height", "comfortable"], "Density": ["compact", "spacing"],
                           "Organize by": ["spaces", "activity", "folders", "sidebar style", "tree"],
                           "Keep idle threads": ["archive", "idle"],
                           "Font": ["ghostty", "monospace", "terminal", "font family"], "Size": ["terminal", "font size"],
                           "Shell": ["zsh", "bash", "fish", "terminal"]]
        case .models: ["Add a provider": ["sign-in extension", "provider extension", "custom sign-in"],
                       "Model": ["claude", "gpt", "provider", "default model"], "Titles and commit messages": ["name", "title", "rename", "haiku", "naming", "session naming", "generate", "text generation"],
                       "Describe images for": ["vision", "images", "screenshots", "pictures", "describe", "multimodal", "image reading"], "Thinking": ["reasoning", "effort", "default thinking level"],
                       "Speed": ["fast", "fast mode", "priority", "service tier", "codex", "openai", "standard", "speed for new threads"],
                       "Subscriptions": ["login", "log in", "sign in", "oauth", "subscription", "auth.json", "claude", "chatgpt", "copilot",
                                         "sign out", "expired"],
                       "API keys": ["api key", "key", "environment", "variable", "auth.json", "sign out"],
                       "Add an API key": ["groq", "mistral", "openrouter", "deepseek"],
                       "Custom providers": ["models.json", "ollama", "gateway"],
                       "Re-import from pi": ["import", "copy", "your pi"],
                       "Shepherd's pi": ["version", "engine", "home", "folder", "pi"],
                       "Your pi": ["~/.pi/agent", "terminal pi", "from pi", "import"]]
        case .agents: ["Send queued messages": ["queue", "follow-up", "one per turn", "all at once"],
                       "Threads can start threads": ["sub-threads", "subthreads", "agent_spawn", "spawn", "nested", "depth"],
                       "Where they work": ["sub-threads", "worktree", "checkout", "branch", "agent_spawn"],
                       "Compact at": ["compaction", "compacting", "context window", "percent", "full", "tokens", "auto-compact"],
                       "Trim old tool output": ["tool results", "clear", "clipping", "context", "tokens", "compaction",
                                                "screenshots", "cache"],
                       "Load rarely used tools on demand": ["tool search", "tool_search", "deferred", "defer", "tokens"],
                       "Codemode": ["javascript", "script", "batch", "tools", "space"],
                       "Native subagents": ["children", "workflows"], "Run at most": ["parallel", "limit", "concurrency"],
                       "Profiles": ["children", "helpers", "agents", "scout", "reviewer", "planner", "worker"]]
        case .worktrees: ["Branch from": ["git", "origin", "base branch"], "Fetch first": ["fetch", "remote"],
                          "Draft commit messages": ["pr description", "commit"],
                          "Close the thread when its PR merges": ["merged", "auto-close", "delete branch", "github", "pull request"],
                          "Worktree": ["deleting", "keep", "remove", "ask", "delete"]]
        case .subagents: ["New profile": ["children", "helpers", "profiles", "agents", "Markdown", "subagent"], "Restore defaults": ["scout", "reviewer", "planner", "worker"]]
        case .projects: ["Add space": ["folders", "directory", "space settings"], "Instructions": ["AGENTS.md", "APPEND_SYSTEM.md"], "Pi settings": [".shepherd", "settings.json"]]
        case .fromYourPi: ["Re-import all": ["import", "re-import", "copy", "~/.pi/agent", "terminal pi", "your pi", "from pi"],
                           "Logins": ["re-import", "auth.json", "sign-ins"],
                           "Custom providers": ["models.json", "re-import"], "Default model": ["re-import", "provider"],
                           "Instructions": ["AGENTS.md", "CLAUDE.md", "SYSTEM.md", "APPEND_SYSTEM.md", "context", "re-import"],
                           "Skills": ["SKILL.md", "re-import"], "Prompts": ["prompt templates", "re-import"], "Themes": ["re-import"],
                           "Extensions": ["packages", "npm", "re-import"]]
        case .tools: ["Extensions": ["sign-in extension", "provider extension", "oauth", "git", "add extension", "full access", "switch on", "didn't load"],
                      "Add server": ["remote", "local", "url", "command", "stdio", "http", "sse", "mcp", "servers", "connectors"],
                      "Import…": ["claude desktop", "cursor", "vs code", "paste json", "mcpServers"],
                      "Also use a repo’s .mcp.json": ["project", "repository", ".mcp.json"],
                      "Terminals and agent tools": ["panes", "notifications", "automations"],
                      "Diff review": ["review_diff"], "MCP servers": ["tool search"], "Browser": ["screenshots"],
                      "Subscription usage": ["limits", "anthropic", "codex"],
                      "Design references": ["design_get"],
                      "Commands in the / menu": ["slash", "/ menu", "command", "composer"]]
        case .piSlashCommands: ["Off": ["slash", "/ menu", "command", "composer", "hide", "hidden", "turn off", "turned off", "switch", "disabled"],
                                "Extensions": ["registerCommand", "pi extensions"],
                                "Prompt templates": ["prompts", "templates", "argument-hint"],
                                "Skills": ["skill:", "SKILL.md"]]
        case .apps: ["Add app": ["dev server", "storybook", "simulator", "command", "apps.json", "package.json", "script"],
                     "Run": ["stop", "running", "start", "localhost", "port"]]
        case .hooks: ["Add hook": ["PreToolUse", "PostToolUse", "Stop", "SessionStart", "UserPromptSubmit", "matcher", "command", "hooks.json"],
                      "Claude Code": ["claude", "settings.json", ".claude", "read hooks"], "Codex": ["codex", "config.toml", ".codex", "read hooks"]]
        case .instructions: ["AGENTS.md": ["system prompt", "how you work", "context"],
                             "APPEND_SYSTEM.md": ["system prompt", "override"], "History": ["restore", "undo"]]
        case .skills: ["Installed": ["SKILL.md", ".agents", "agent skills", "from your pi", "copied", ".pi", ".shepherd"],
                       "Browse skills.sh": ["directory", "search", "install"],
                       "Add from repo": ["github", "git", "folder"], "Show in the / menu": ["slash", "command", "composer"],
                       "Update automatically": ["update", "upgrade"]]
        case .fleet: ["Macs": ["pair", "code", "bonjour", "peers", "machines", "lan"], "Add a Mac": ["pair", "code", "6 digit"],
                      "Join a fleet": ["code", "address", "pair"],
                      "Phones and tablets": ["iphone", "ipad", "phone", "tablet", "client", "token", "remote", "devices"],
                      "Add a device": ["qr", "code", "pair", "scan"], "Listener": ["port", "serve", "remote"],
                      "Ignored files": [".env", "node_modules", "build caches", "exclude"]]
        case .keyboard: ["Shortcuts": ["hotkey", "keybinding", "chord", "steer", "queue"]]
        case .advanced: ["Workspace state": ["state.json"], "Confirmations you skipped": ["don't ask again", "confirm", "dialog", "skipped"],
                         "All settings": ["reset", "defaults"],
                         "Share diagnostics": ["telemetry", "privacy", "errors", "crash", "performance", "memory"]]
        case .experiments: ["Projects": ["coordinate", "project work", "new project"],
                            "Suggested instructions": ["lessons", "learned"], "Learn from": ["threads", "automations"],
                            "Design tool": ["designs", "boards", "mockups"],
                            "Computer use": ["apps", "click", "type", "control", "desktop", "permissions"],
                            "Allowed apps": ["accessibility", "screen recording", "permissions"]]
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

    /// Every hit for `query`, page by page in nav order; a hit is named by its page and title.
    /// `rows` are pages' own rows found by name (Tools' MCP servers).
    static func hits(for query: String, rows: [SettingsSection: [String]] = [:]) -> [SettingsSearchHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allCases.flatMap { section in
            section.matches(for: query).map { SettingsSearchHit(section: section, item: $0) }
                + (needle.isEmpty ? [] : (rows[section] ?? []).filter { $0.localizedCaseInsensitiveContains(needle) }
                    .map { SettingsSearchHit(section: section, item: $0, isServer: true) })
        }
    }

}
