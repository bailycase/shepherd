import SwiftUI
import ShepherdDesign
import AppKit
import ShepherdCore
import ShepherdProtocol

/// Settings (spec §12): replaces the window content. A 232pt nav — Back to Shepherd, search
/// (⌘F), sections with icons, versions pinned at the bottom — beside a 720pt content column.
///
/// Everything here is wired: a row exists only if changing it changes the app.
struct SettingsView: View {
    var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var piUpdates = PiUpdateManager.shared
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matchingSections: [SettingsSection] {
        guard !query.isEmpty else { return Array(SettingsSection.allCases) }
        return SettingsSection.allCases.filter { !$0.matches(for: query).isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            nav
            Tokens.border.frame(width: 1)
            detail
        }
        .background(Tokens.bgSurface)
        .background { WindowChrome() }
        .preferredColorScheme(themes.mode.colorScheme)
        .ignoresSafeArea()
        .onChange(of: searchText) {
            if let first = matchingSections.first, !matchingSections.contains(vm.settingsSection) {
                vm.settingsSection = first
            }
        }
        .background {
            // ⌘F focuses the search field.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Traffic-light strip: draggable, nothing else lives up here.
            Color.clear
                .frame(height: Metrics.trafficLightHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            Button { vm.showSettings = false } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Back to Shepherd").font(Fonts.labelRegular)
                }
                .foregroundStyle(Tokens.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.horizontal, 14)
            .padding(.vertical, 6)

            SearchField("Search settings", text: $searchText, shortcut: "⌘F")
                .focused($searchFocused)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .task {
                    // Typing filters immediately after opening; delayed a beat because focusing
                    // while SwiftUI installs the key-view loop silently loses the request.
                    try? await Task.sleep(for: .milliseconds(150))
                    searchFocused = true
                }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matchingSections) { section in
                        SettingsNavRow(section: section, selected: vm.settingsSection == section) {
                            vm.settingsSection = section
                        }
                        if !query.isEmpty {
                            ForEach(section.matches(for: query), id: \.self) { item in
                                Button { vm.settingsSection = section } label: {
                                    Text(item)
                                        .font(Fonts.caption)
                                        .foregroundStyle(Tokens.textTertiary)
                                        .padding(.leading, 36)
                                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if matchingSections.isEmpty {
                        Text("No matching settings")
                            .font(Fonts.caption)
                            .foregroundStyle(Tokens.textMuted)
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
            Text(versions)
                .font(Fonts.micro)
                .foregroundStyle(Tokens.textMuted)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(width: Metrics.settingsNavWidth)
        .background(Tokens.bgCanvas.ignoresSafeArea())
    }

    /// "Shepherd 0.1.0 · pi 0.87.1"
    private var versions: String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "Shepherd \(app)" + (piUpdates.currentVersion.map { " · pi \($0)" } ?? "")
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
            .frame(maxWidth: Metrics.settingsContentWidth, alignment: .leading)
            .padding(.top, Metrics.settingsTop)
            .padding(.bottom, 48)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.bgSurface)
        .overlay(alignment: .top) {
            // The window has no title bar; the strip above the content still drags it.
            Color.clear.frame(height: Metrics.trafficLightHeight).contentShape(Rectangle()).gesture(WindowDragGesture())
        }
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
        case .appearance: ["Theme", "Mode", "Density", "Text size", "Sidebar width"]
        case .terminal: ["Font family", "Font size", "Shell"]
        case .agents: ["Default model", "Default thinking level"]
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
        case .appearance: ["Mode": ["dark", "light", "color", "basalt"], "Text size": ["font", "zoom", "scale"], "Density": ["compact", "spacing"]]
        case .terminal: ["Font family": ["ghostty", "monospace"], "Shell": ["zsh", "bash", "fish"]]
        case .agents: ["Default model": ["claude", "gpt", "provider"], "Default thinking level": ["reasoning", "effort"]]
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
        case .worktrees: return "arrow.triangle.branch"
        case .pi: return "arrow.triangle.2.circlepath"
        case .remote: return "dot.radiowaves.left.and.right"
        case .keyboard: return "keyboard"
        case .advanced: return "gearshape"
        }
    }
}

/// A nav row (32pt, radius 8): 15pt icon and 13pt label; selected is bgSelected.
private struct SettingsNavRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if section == .pi {
                        Text("π").font(Fonts.sans(15, .medium))
                    } else {
                        Image(systemName: section.symbol).font(.system(size: 13, weight: .regular))
                    }
                }
                .foregroundStyle(selected ? Tokens.text : Tokens.textSecondary)
                .frame(width: 18)
                Text(section.title)
                    .font(selected ? Fonts.label : Fonts.labelRegular)
                    .foregroundStyle(Tokens.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, radius: Radius.md))
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
