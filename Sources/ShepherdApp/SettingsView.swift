import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol

/// The Settings window (⌘,): a category list beside grouped setting rows.
///
/// Everything here is wired — a row exists only if changing it changes the
/// app. Chrome follows the same rules as the main window: theme tokens, no
/// saturated fills, mono metadata, hairline separators.
struct SettingsView: View {
    var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @State private var searchText = ""

    private var matchingSections: [SettingsSection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(SettingsSection.allCases) }
        return SettingsSection.allCases.filter { section in
            section.title.localizedCaseInsensitiveContains(query)
                || section.items.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        // Same shell as the main window: the sidebar material runs
        // continuously behind the traffic-light strip, and the right column
        // carries its own header over the window background.
        HStack(spacing: 0) {
            categoryList
            VStack(spacing: 0) {
                header
                detail
            }
            .background(Tokens.workspaceBg)
        }
        .frame(
            minWidth: Metrics.settingsMinWidth,
            minHeight: Metrics.settingsMinHeight
        )
        .background(Tokens.workspaceBg)
        .background(WindowChrome())
        .preferredColorScheme(themes.mode.colorScheme)
        .ignoresSafeArea()
        .id(themes.current.id)
        .onChange(of: searchText) {
            if let first = matchingSections.first, !matchingSections.contains(vm.settingsSection) {
                vm.settingsSection = first
            }
        }
    }

    /// Names the pane the user is looking at. The window has no system title,
    /// so this is the only label the window carries.
    private var header: some View {
        HStack(spacing: 0) {
            Text(vm.settingsSection.title.lowercased())
                .font(Fonts.mono(12.5, .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: Metrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Tokens.workspaceBg)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private var categoryList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Traffic-light strip: draggable, nothing else lives up here.
            Color.clear
                .frame(height: Metrics.trafficLightHeight)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            // Everything below shares one 14pt content edge: the back
            // chevron, the search field's icon, the SETTINGS heading, and
            // each category row's icon all start at the same x.
            Button {
                vm.showSettings = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .medium))
                    Text("back to app")
                        .font(Fonts.mono(11.5))
                }
                .foregroundStyle(Tokens.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)

            SettingsSearchField(text: $searchText)
                .padding(.horizontal, 6)
                .padding(.top, 10)

            Text("SETTINGS")
                .font(Fonts.mono(10.5, .semibold))
                .tracking(0.74)
                .foregroundStyle(Tokens.textTertiary)
                .padding(EdgeInsets(top: 16, leading: 14, bottom: 6, trailing: 14))

            VStack(alignment: .leading, spacing: 1) {
                ForEach(matchingSections) { item in
                    SettingsCategoryRow(section: item, selected: vm.settingsSection == item) {
                        vm.settingsSection = item
                    }
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Matching rows within the section, indented to the
                        // category title's text column and clickable.
                        ForEach(item.sidebarItems(for: searchText), id: \.self) { child in
                            Button {
                                vm.settingsSection = item
                            } label: {
                                Text(child.lowercased())
                                    .font(Fonts.mono(10.5))
                                    .foregroundStyle(Tokens.textTertiary)
                                    .padding(.leading, 30)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            if matchingSections.isEmpty {
                Text("no matching settings")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .padding(EdgeInsets(top: 4, leading: 14, bottom: 0, trailing: 14))
            }
            Spacer(minLength: 0)
        }
        .frame(width: Metrics.settingsSidebarWidth)
        // Flat sidebar surface, exactly like the main window's.
        .background(Tokens.sidebarBg.ignoresSafeArea())
    }

    private var detail: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
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
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 24, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Tokens.workspaceBg)
        // System controls default to the OS accent (blue), which is the one
        // saturated color DESIGN.md rules out. One tint here covers every
        // slider, switch, and segmented selection in the pane.
        .tint(Tokens.accentButton)
    }
}

private struct SettingsSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textTertiary)
            TextField("search settings…", text: $text)
                .textFieldStyle(.plain)
                .font(Fonts.mono(11.5))
                .focused($focused)
                // Settings just opened (this view mounts with the surface):
                // typing should filter immediately, no click first. Delayed a
                // beat — focusing while SwiftUI is still installing the
                // overlay's key-view loop silently loses the request.
                .task {
                    try? await Task.sleep(for: .milliseconds(150))
                    focused = true
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Tokens.textTertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Tokens.rowActiveHeader)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.chipBorder, lineWidth: 1))
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

    var items: [String] {
        switch self {
        case .appearance: return ["Theme", "UI Density", "UI Text Scale", "Sidebar Width"]
        case .terminal: return ["Terminal Font", "Font Size", "Shell"]
        case .agents: return ["Default Model", "Default Thinking Level", "Auto-name Agents"]
        case .worktrees: return ["Base Branch", "Fetch Before Creating", "Commit Remaining Work", "Delete Local Branch", "Merge PR Automatically"]
        case .pi: return ["Update Pi", "Update Extensions", "Installed Version", "Status", "Check Now"]
        case .remote: return ["Hosts", "Serve This Mac"]
        case .keyboard: return ["New Agent", "Settings", "Pane Shortcuts"]
        case .advanced: return ["Files", "Reset Settings", "Updates", "About"]
        }
    }

    func sidebarItems(for query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.localizedCaseInsensitiveContains(query)
            ? items
            : items.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .terminal: return "terminal"
        case .agents: return "person.2"
        case .worktrees: return "arrow.triangle.branch"
        case .pi: return "arrow.triangle.2.circlepath"
        case .remote: return "antenna.radiowaves.left.and.right"
        case .keyboard: return "keyboard"
        case .advanced: return "gearshape"
        }
    }
}

/// A real `Button` (not a tap gesture) so the list is keyboard- and
/// VoiceOver-navigable like the main window's menu commands.
private struct SettingsCategoryRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Tokens.focusAccent : Tokens.textTertiary)
                    .frame(width: 14)
                Text(section.title.lowercased())
                    .font(Fonts.mono(12, selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Tokens.textPrimary : Tokens.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(selected ? Tokens.rowSelection : hovering ? Tokens.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

