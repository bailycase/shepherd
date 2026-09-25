import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol

/// Settings replaces the window content in place. A 232pt nav on `bgBase` (Back to Shepherd,
/// search on ⌘F, the pages, the versions pinned at the bottom) beside a 720pt content column.
///
/// Everything here is wired: a row exists only if changing it changes the app.
struct SettingsView: View {
    var vm: ShepherdViewModel
    private var themes: ThemeManager { .shared }
    private var piUpdates: PiUpdateManager { .shared }
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matchingSections: [SettingsSection] {
        guard !query.isEmpty else { return Array(SettingsSection.allCases) }
        return SettingsSection.allCases.filter { !$0.matches(for: query).isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
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
            // Traffic-light strip: draggable, nothing else lives up here.
            Color.clear
                .frame(height: AppLayout.trafficLightHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            Button { vm.showSettings = false } label: {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "chevron.left")
                        .font(.nw(.ui, weight: .semibold))
                        .imageScale(.small)
                        .frame(width: NW.Space.xl)
                        .accessibilityHidden(true)
                    Text("Back to Shepherd").font(.nw(.ui))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.nw.textSecondary)
                .padding(.horizontal, NW.Space.m)
                .frame(minHeight: NW.Height.row)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nwRow())
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.horizontal, NW.Space.s)

            NWSearchField("Search settings", text: $searchText, shortcut: "⌘F")
                .focused($searchFocused)
                .padding(.horizontal, NW.Space.m)
                .padding(.top, NW.Space.m)
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
                        NWSettingsNavRow(section.title, systemImage: section.symbol, selected: vm.settingsSection == section) {
                            vm.settingsSection = section
                        }
                        if !query.isEmpty {
                            ForEach(section.matches(for: query), id: \.self) { item in
                                SettingsSearchHit(title: item, section: section.title) { vm.settingsSection = section }
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
                .padding(.horizontal, NW.Space.s)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
            Text(versions)
                .font(.nw(.micro))
                .foregroundStyle(Color.nw.textTertiary)
                .lineLimit(1)
                .padding(.horizontal, NW.Space.s + NW.Space.m)
                .padding(.bottom, NW.Space.l)
        }
        .frame(width: AppLayout.settingsNavWidth)
        .background(Color.nw.bgBase.ignoresSafeArea())
    }

    /// Searching shows the first page with a match when the current one has none. It lands at
    /// once: the page cross-fades when it is picked, never per keystroke.
    static func showFirstMatch(of sections: [SettingsSection], in vm: ShepherdViewModel) {
        guard let first = sections.first, !sections.contains(vm.settingsSection) else { return }
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { vm.settingsSection = first }
    }

    /// "Shepherd 0.1.0 · agent 0.87.1", or "Shepherd Nightly 0.0.0-nightly.… · agent 0.87.1"
    private var versions: String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "\(ShepherdEdition.current.displayName) \(app)" + (piUpdates.currentVersion.map { " · agent \($0)" } ?? "")
    }

    private var detail: some View {
        ScrollView(.vertical) {
            Group {
                switch vm.settingsSection {
                case .appearance: AppearanceSettings(vm: vm)
                case .terminal: TerminalSettings(vm: vm)
                case .agents: AgentSettings()
                case .pi: PiSettings()
                case .worktrees: WorktreeSettings()
                case .remote: RemoteSettings(vm: vm, store: vm.remoteHosts)
                case .keyboard: KeyboardSettings(vm: vm)
                case .advanced: AdvancedSettings(vm: vm)
                }
            }
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
        .background(Color.nw.bgWindow)
        .overlay(alignment: .top) {
            // The window has no title bar; the strip above the content still drags it.
            Color.clear.frame(height: AppLayout.trafficLightHeight).contentShape(Rectangle()).gesture(WindowDragGesture())
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
                .padding(.leading, NW.Space.m + NW.Space.xl + NW.Space.m)
                .frame(maxWidth: .infinity, minHeight: NW.Height.controlS, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow())
        .accessibilityLabel("\(title), in \(section)")
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, terminal, agents, worktrees, pi, remote, keyboard, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .agents: return "Agents"
        case .worktrees: return "Worktrees"
        case .pi: return "Pi"
        case .remote: return "Remote"
        case .keyboard: return "Keyboard"
        case .advanced: return "Advanced"
        }
    }

    /// Row titles on the page, as the search lists them under the section.
    var items: [String] {
        switch self {
        case .appearance: ["Theme", "Mode", "Sidebar rows", "Density", "Text size", "Sidebar width"]
        case .terminal: ["Font family", "Font size", "Shell"]
        case .agents: ["Default model", "Default thinking level", "Return while the agent is working", "When a turn ends, send the queue"]
        case .worktrees: ["Base branch", "Fetch before creating", "Commit remaining work", "Generate PR descriptions", "Delete local branch", "Merge PR automatically"]
        case .pi: ["Name agents automatically", "Sync pi theme", "Panes and agent tools", "Diff review tool", "Native subagents", "Subagent display", "Concurrency", "Update pi daily", "Update extensions daily", "Check now"]
        case .remote: ["Hosts", "Add host", "Listener", "Token"]
        case .keyboard: ["Shortcuts", "Reset all shortcuts"]
        case .advanced: ["Workspace state", "Extension socket", "Update channel", "Check for updates", "Reset settings"]
        }
    }

    /// Words people search for that aren't row titles ("dark" → Appearance).
    private var keywords: [String: [String]] {
        switch self {
        case .appearance: ["Mode": ["dark", "light", "color", "night watch", "theme"], "Text size": ["font", "zoom", "scale"], "Sidebar rows": ["row height", "comfortable"], "Density": ["compact", "spacing"]]
        case .terminal: ["Font family": ["ghostty", "monospace"], "Shell": ["zsh", "bash", "fish"]]
        case .agents: ["Default model": ["claude", "gpt", "provider"], "Default thinking level": ["reasoning", "effort"],
                       "Return while the agent is working": ["steer", "queue", "enter", "follow-up"],
                       "When a turn ends, send the queue": ["queue", "follow-up", "one per turn", "all at once"]]
        case .worktrees: ["Base branch": ["git", "origin"], "Merge PR automatically": ["github", "pull request"]]
        case .pi: ["Native subagents": ["children", "workflows"], "Update pi daily": ["version", "upgrade"]]
        case .remote: ["Hosts": ["vpn", "tailscale", "ssh"], "Listener": ["port", "serve"]]
        case .keyboard: ["Shortcuts": ["hotkey", "keybinding", "chord"]]
        case .advanced: ["Update channel": ["beta", "nightly", "sparkle"], "Workspace state": ["state.json"]]
        }
    }

    /// Items matching `query` by title or keyword; every item when the section's name matches.
    func matches(for query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if title.localizedCaseInsensitiveContains(query) { return items }
        return items.filter { item in
            item.localizedCaseInsensitiveContains(query)
                || (keywords[item] ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "circle.lefthalf.filled"
        case .terminal: return "terminal"
        case .agents: return "person.2"
        case .worktrees: return "arrow.branch"
        case .pi: return "pi"
        case .remote: return "desktopcomputer"
        case .keyboard: return "keyboard"
        case .advanced: return "gearshape"
        }
    }
}
