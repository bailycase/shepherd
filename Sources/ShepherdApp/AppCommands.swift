import SwiftUI
import ShepherdCore
import ShepherdUI

/// What the menu bar shows, as narrow cached values. Each menu reads only its own fields, and a
/// field changes only when its value does, so an agent's status report (or any other workspace
/// churn) never rebuilds the main menu. `MenuStateSync` keeps it current.
@MainActor @Observable
final class MenuState {
    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
    }

    struct Snapshot: Equatable {
        var hasVisibleThread = false
        var hasSelection = false
        var canActOnSelection = false
        var sidebarVisible = true
        var sidebarStyle = SHSidebarStyle.activity
        var rightPaneOpen = false
        var hasMachineAgents = false
        /// The focused pane is a terminal (or review) ⌘W can close.
        var canCloseTerminal = false
        /// This Mac's selected thread: what the Agent menu's thread commands act on.
        var selectedLocalAgent: AgentID?
        /// The commands that apply to it (Finalize is a worktree agent's alone).
        var threadCommands: [ThreadCommand] = []
        /// Whether it is pinned; nil when it cannot be.
        var selectedPinned: Bool?
        /// Save in Settings ▸ Spaces or ▸ Subagents; nil hides the item.
        var saveTitle: String?
        var canSave = false
        var agents: [Item] = []
        var spaces: [Item] = []
    }

    static let unavailable = MenuState()

    private(set) var hasVisibleThread = false
    private(set) var hasSelection = false
    private(set) var canActOnSelection = false
    private(set) var sidebarVisible = true
    private(set) var sidebarStyle = SHSidebarStyle.activity
    private(set) var rightPaneOpen = false
    private(set) var hasMachineAgents = false
    private(set) var canCloseTerminal = false
    private(set) var selectedLocalAgent: AgentID?
    private(set) var threadCommands: [ThreadCommand] = []
    private(set) var selectedPinned: Bool?
    private(set) var saveTitle: String?
    private(set) var canSave = false
    private(set) var agents: [Item] = []
    private(set) var spaces: [Item] = []

    /// Writes only the fields that changed, so only the menus reading them rebuild.
    func apply(_ snapshot: Snapshot) {
        if hasVisibleThread != snapshot.hasVisibleThread { hasVisibleThread = snapshot.hasVisibleThread }
        if hasSelection != snapshot.hasSelection { hasSelection = snapshot.hasSelection }
        if canActOnSelection != snapshot.canActOnSelection { canActOnSelection = snapshot.canActOnSelection }
        if sidebarVisible != snapshot.sidebarVisible { sidebarVisible = snapshot.sidebarVisible }
        if sidebarStyle != snapshot.sidebarStyle { sidebarStyle = snapshot.sidebarStyle }
        if rightPaneOpen != snapshot.rightPaneOpen { rightPaneOpen = snapshot.rightPaneOpen }
        if hasMachineAgents != snapshot.hasMachineAgents { hasMachineAgents = snapshot.hasMachineAgents }
        if canCloseTerminal != snapshot.canCloseTerminal { canCloseTerminal = snapshot.canCloseTerminal }
        if selectedLocalAgent != snapshot.selectedLocalAgent { selectedLocalAgent = snapshot.selectedLocalAgent }
        if threadCommands != snapshot.threadCommands { threadCommands = snapshot.threadCommands }
        if selectedPinned != snapshot.selectedPinned { selectedPinned = snapshot.selectedPinned }
        if saveTitle != snapshot.saveTitle { saveTitle = snapshot.saveTitle }
        if canSave != snapshot.canSave { canSave = snapshot.canSave }
        if agents != snapshot.agents { agents = snapshot.agents }
        if spaces != snapshot.spaces { spaces = snapshot.spaces }
    }
}

extension MenuState.Snapshot {
    @MainActor init(_ vm: ShepherdViewModel) {
        let selected = vm.selectedRemoteAgent?.agentID ?? vm.selectedAgentID
        let local = vm.selectedRemoteAgent == nil ? vm.selectedAgent : nil
        let save = vm.saveMenuItem
        self.init(
            hasVisibleThread: vm.visibleThread != nil,
            hasSelection: selected != nil || vm.selectedRemoteAgent != nil,
            canActOnSelection: selected != nil,
            sidebarVisible: vm.isSidebarVisible,
            sidebarStyle: vm.sidebarStyle,
            rightPaneOpen: vm.isRightPaneOpen,
            hasMachineAgents: !vm.sidebarWalkRows.isEmpty,
            canCloseTerminal: vm.canCloseTerminal,
            selectedLocalAgent: local?.id,
            threadCommands: local.map(ThreadCommand.commands(for:)) ?? [],
            selectedPinned: local.map { vm.canPin(.local($0.id)) ? vm.isPinned(.local($0.id)) : nil } ?? nil,
            saveTitle: save?.title,
            canSave: save?.enabled ?? false,
            agents: vm.sidebarShortcutRows.prefix(9).map { MenuState.Item(id: "\($0.id)", title: $0.title) },
            spaces: vm.visibleSpaces.map { MenuState.Item(id: $0.id.rawValue, title: $0.name) }
        )
    }
}

/// Keeps `vm.menuState` in step with the workspace. Invisible; lives in the window.
struct MenuStateSync: View {
    var vm: ShepherdViewModel

    var body: some View {
        let snapshot = MenuState.Snapshot(vm)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: snapshot, initial: true) { vm.menuState.apply(snapshot) }
    }
}

// MARK: Menus

/// Menu actions run on the next main-queue turn, outside the menu's own event handling.
private func later(_ action: @escaping @MainActor () -> Void) {
    Task { @MainActor in action() }
}

/// Register command groups before the asynchronous workspace launch. SwiftUI can update their
/// items, but groups omitted at launch do not reliably join the main menu afterward.
struct WorkspaceCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    let keys: KeybindingsStore
    let themes: ThemeManager

    var body: some Commands {
        AppSettingsCommands(launch: launch, keys: keys, bindings: keys.overrides)
        FileCommands(launch: launch, keys: keys, bindings: keys.overrides)
        ViewCommands(launch: launch, keys: keys, bindings: keys.overrides, themes: themes)
        PaneCommands(launch: launch, keys: keys, bindings: keys.overrides)
        SpaceCommands(launch: launch, keys: keys)
        AgentCommands(launch: launch, keys: keys, bindings: keys.overrides)
    }
}

/// Settings (⌘,), Check for Updates and Quit and Stop Agents, in the app menu.
struct AppSettingsCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    let keys: KeybindingsStore
    /// Read so the menu rebuilds when a shortcut is rebound.
    let bindings: [ShortcutAction: KeyChord]
    private var vm: ShepherdViewModel? { launch.model }

    var body: some Commands {
        CommandGroup(after: .appTermination) {
            // Only while the background service runs the agents; ⌘Q leaves them running.
            if let service = vm?.backgroundService, BackgroundHostClient.owner == .host {
                Button(ShortcutAction.quitAndStopAgents.title) {
                    do { try service.unregister() } catch { NSLog("Shepherd: background service not stopped: \(error)") }
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(keys.shortcut(.quitAndStopAgents))
            }
        }
        CommandGroup(replacing: .appSettings) {
            Group {
                SettingsCommandButton(vm: vm)
                if vm != nil && AppUpdater.shared.available {
                    Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
                }
            }
            .disabled(vm == nil)
        }
    }
}

/// The File menu's creation actions also stay mounted while the workspace starts.
struct FileCreationMenuItems: View {
    let launch: ShepherdLaunch<ShepherdViewModel>
    let keys: KeybindingsStore
    private var vm: ShepherdViewModel? { launch.model }

    var body: some View {
        Group {
            Button("New Thread") { later { vm?.openNewThread() } }
                .keyboardShortcut(keys.shortcut(.newAgent))
            Button("New Agent with Options…") { later { vm?.showNewAgentSheet = true } }
                .keyboardShortcut(keys.shortcut(.newAgentOptions))
            Button("New Space…") { later { vm?.addSpaceFromPanel() } }
                .keyboardShortcut(keys.shortcut(.newSpace))
            if vm?.designToolEnabled == true {
                Divider()
                Button("Import Claude Design Project…") { later { vm?.chooseDesignProject() } }
                    .keyboardShortcut(keys.shortcut(.importDesign))
            }
        }
        .disabled(vm == nil)
    }
}

/// File ▸ New Thread, New Agent with Options…, New Space…, Import Claude Design Project… (⇧⌘I,
/// with the Design tool on), and ⌘W as Close Terminal.
struct FileCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    private var vm: ShepherdViewModel? { launch.model }
    private var menu: MenuState { vm?.menuState ?? .unavailable }
    let keys: KeybindingsStore
    /// The rebindings, so a changed chord rebuilds these items.
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            FileCreationMenuItems(launch: launch, keys: keys)
        }
        CommandGroup(replacing: .saveItem) {
            Group {
                // Save exists only in Settings ▸ Spaces and ▸ Subagents; elsewhere there is no item.
                if let title = menu.saveTitle {
                    Button(title) { Task { await vm?.saveSettingsFile() } }
                        .keyboardShortcut(keys.shortcut(.saveProjectFile))
                        .disabled(!menu.canSave)
                }
                // Disabled with nothing to close, so ⌘W is not a beep.
                Button("Close Terminal") { later { vm?.closeFocusedTerminal() } }
                    .keyboardShortcut(keys.shortcut(.closeTerminal))
                    .disabled(!menu.canCloseTerminal)
            }
            .disabled(vm == nil)
        }
    }
}

/// View ▸ Command Palette, sidebar, right pane, Appearance (and the Debug component gallery).
struct ViewCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    private var vm: ShepherdViewModel? { launch.model }
    private var menu: MenuState { vm?.menuState ?? .unavailable }
    let keys: KeybindingsStore
    let bindings: [ShortcutAction: KeyChord]
    let themes: ThemeManager

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Group {
                // Over a design it opens Jump to a board instead (JumpInContext).
                Button("Command Palette") { later { vm?.toggleCommandPaletteOrJump() } }
                    .keyboardShortcut(keys.shortcut(.commandPalette))
                Button(menu.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { later { vm?.toggleSidebar() } }
                    .keyboardShortcut(keys.shortcut(.toggleSidebar))
                // Settings ▸ Appearance ▸ Sidebar ▸ Organize by, here too (Sidebar — Projects). A picker
                // puts the check in the state column, where VoiceOver reads it.
                Picker("Organize Sidebar By", selection: Binding(get: { menu.sidebarStyle }, set: { style in later { vm?.setSidebarStyle(style) } })) {
                    ForEach(SHSidebarStyle.allCases) { style in Text(style.title).tag(style) }
                }
                .pickerStyle(.inline)
                Picker("Appearance", selection: Binding(get: { themes.mode }, set: { option in
                    later { vm?.selectAppearance(option, systemColorScheme: ThemeManager.effectiveSystemColorScheme) }
                })) {
                    ForEach(AppearanceMode.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.inline)
                Button(menu.rightPaneOpen ? "Hide Side Pane" : "Show Side Pane") { later { vm?.toggleRightPane() } }
                    .keyboardShortcut(keys.shortcut(.toggleRightPane))
                    .disabled(!menu.hasVisibleThread)
                // ⌃1–7 pick the side pane's tabs: fixed, like ⌃⇧1–9 (no ⌘, so never rebound).
                ForEach(SidePaneTab.allCases, id: \.self) { tab in
                    Button(tab.title) { later { vm?.selectSidePaneTab(tab) } }
                        .keyboardShortcut(KeyEquivalent(Character("\(tab.digit)")), modifiers: .control)
                        .disabled(!menu.hasVisibleThread)
                }
                #if DEBUG
                Divider()
                Button("Component Gallery") { later { vm?.showComponentGallery.toggle() } }
                #endif
            }
            .disabled(vm == nil)
        }
    }
}

/// The Terminal menu: New Terminal, show or hide the panel, maximize it, and the tab to go to.
struct PaneCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    private var vm: ShepherdViewModel? { launch.model }
    let keys: KeybindingsStore
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandMenu("Terminal") {
            Group {
                Button("New Terminal") { later { vm?.newTerminalTab() } }
                    .keyboardShortcut(keys.shortcut(.newTerminal))
                Divider()
                Button("Show or Hide Terminal") { later { vm?.toggleTerminalPanel() } }
                    .keyboardShortcut(keys.shortcut(.toggleTerminal))
                Button("Maximize or Restore Terminal") { later { vm?.toggleTerminalMaximized() } }
                    .keyboardShortcut(keys.shortcut(.maximizeTerminal))
                Divider()
                Button("Next Terminal") { later { vm?.selectAdjacentTerminal(1) } }
                    .keyboardShortcut(keys.shortcut(.nextTerminal))
                Button("Previous Terminal") { later { vm?.selectAdjacentTerminal(-1) } }
                    .keyboardShortcut(keys.shortcut(.previousTerminal))
            }
            .disabled(vm == nil)
        }
    }
}

struct SpaceCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    private var vm: ShepherdViewModel? { launch.model }
    private var menu: MenuState { vm?.menuState ?? .unavailable }
    let keys: KeybindingsStore

    var body: some Commands {
        CommandMenu("Space") {
            Group {
                if menu.spaces.isEmpty {
                    Button("No Spaces") {}.disabled(true)
                    Divider()
                } else {
                    ForEach(menu.spaces) { space in
                        Button(space.title) { later { vm?.selectSpace(SpaceID(rawValue: space.id)) } }
                    }
                    Divider()
                }
                // The empty state offers the next step.
                Button("New Space…") { later { vm?.addSpaceFromPanel() } }
                    .keyboardShortcut(keys.shortcut(.newSpace))
            }
            .disabled(vm == nil)
        }
    }
}

struct AgentCommands: Commands {
    let launch: ShepherdLaunch<ShepherdViewModel>
    private var vm: ShepherdViewModel? { launch.model }
    private var menu: MenuState { vm?.menuState ?? .unavailable }
    let keys: KeybindingsStore
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandMenu("Agent") {
            Group {
                Button("Focus") { later { vm?.focusSelectedAgent() } }
                    .disabled(!menu.hasSelection)
                Button("Rename…") { later { vm?.renameSelectedAgent() } }
                    .keyboardShortcut(keys.shortcut(.renameAgent))
                    .disabled(!menu.canActOnSelection)
                Divider()
                Button("Stop") { later { vm?.stopVisibleAgent() } }
                    .keyboardShortcut(keys.shortcut(.stopAgent))
                    .disabled(!menu.hasVisibleThread)
                Button("Choose Model…") { later { vm?.sendThreadCommand(.modelPicker) } }
                    .keyboardShortcut(keys.shortcut(.modelPicker))
                    .disabled(!menu.hasVisibleThread)
                Button("Inspect Subagent") { later { vm?.sendThreadCommand(.inspectSubagent) } }
                    .keyboardShortcut(keys.shortcut(.inspectSubagent))
                    .disabled(!menu.hasVisibleThread)
                Button("Previous Turn") { later { vm?.sendThreadCommand(.previousTurn) } }
                    .keyboardShortcut(keys.shortcut(.previousTurn))
                    .disabled(!menu.hasVisibleThread)
                Button("Next Turn") { later { vm?.sendThreadCommand(.nextTurn) } }
                    .keyboardShortcut(keys.shortcut(.nextTurn))
                    .disabled(!menu.hasVisibleThread)
                Divider()
                Button("Next Agent") { later { vm?.selectAdjacentAgent(1) } }
                    .keyboardShortcut(keys.shortcut(.nextAgent))
                    .disabled(!menu.hasMachineAgents)
                Button("Previous Agent") { later { vm?.selectAdjacentAgent(-1) } }
                    .keyboardShortcut(keys.shortcut(.previousAgent))
                    .disabled(!menu.hasMachineAgents)
                Divider()
                // The sidebar row's commands, on the selected local thread (ThreadCommand).
                if let vm, let agentID = menu.selectedLocalAgent {
                    PinMenuItem(vm: vm, target: .local(agentID), pinned: menu.selectedPinned)
                    ForEach(menu.threadCommands.filter { !$0.isDestructive }) { command in
                        Button(command.title, systemImage: command.symbol) { later { vm.perform(command, on: agentID) } }
                    }
                    Divider()
                }
                Button("Delete Agent…", role: .destructive) { later { vm?.deleteSelectedAgent() } }
                    .keyboardShortcut(keys.shortcut(.deleteAgent))
                    .disabled(!menu.canActOnSelection)
                if !menu.agents.isEmpty {
                    Divider()
                    ForEach(Array(menu.agents.enumerated()), id: \.element.id) { index, agent in
                        Button(agent.title) {
                            later {
                                vm?.showCommandPalette = false
                                vm?.selectAgentDigit(index + 1)
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
            .disabled(vm == nil)
        }
    }
}
