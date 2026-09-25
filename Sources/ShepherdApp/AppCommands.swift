import SwiftUI
import ShepherdCore

/// What the menu bar shows, as narrow cached values. Each menu reads only its own fields, and a
/// field changes only when its value does, so an agent's status report (or any other workspace
/// churn) never rebuilds the main menu. `MenuStateSync` keeps it current.
@MainActor @Observable
final class MenuState {
    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
    }

    struct Machine: Equatable, Identifiable {
        let id: UUID
        let name: String
        let connected: Bool
    }

    struct Snapshot: Equatable {
        var hasVisibleThread = false
        var hasSelection = false
        var canActOnSelection = false
        var sidebarVisible = true
        var rightPaneOpen = false
        var hasMachineAgents = false
        /// The first nine agents of the active machine, for ⌘1–9.
        var agents: [Item] = []
        var spaces: [Item] = []
        var machines: [Machine] = []
    }

    private(set) var hasVisibleThread = false
    private(set) var hasSelection = false
    private(set) var canActOnSelection = false
    private(set) var sidebarVisible = true
    private(set) var rightPaneOpen = false
    private(set) var hasMachineAgents = false
    private(set) var agents: [Item] = []
    private(set) var spaces: [Item] = []
    private(set) var machines: [Machine] = []

    /// Writes only the fields that changed, so only the menus reading them rebuild.
    func apply(_ snapshot: Snapshot) {
        if hasVisibleThread != snapshot.hasVisibleThread { hasVisibleThread = snapshot.hasVisibleThread }
        if hasSelection != snapshot.hasSelection { hasSelection = snapshot.hasSelection }
        if canActOnSelection != snapshot.canActOnSelection { canActOnSelection = snapshot.canActOnSelection }
        if sidebarVisible != snapshot.sidebarVisible { sidebarVisible = snapshot.sidebarVisible }
        if rightPaneOpen != snapshot.rightPaneOpen { rightPaneOpen = snapshot.rightPaneOpen }
        if hasMachineAgents != snapshot.hasMachineAgents { hasMachineAgents = snapshot.hasMachineAgents }
        if agents != snapshot.agents { agents = snapshot.agents }
        if spaces != snapshot.spaces { spaces = snapshot.spaces }
        if machines != snapshot.machines { machines = snapshot.machines }
    }
}

extension MenuState.Snapshot {
    @MainActor init(_ vm: ShepherdViewModel) {
        let selected = vm.selectedRemoteAgent?.agentID ?? vm.selectedAgentID
        let machineAgents = vm.activeMachineAgents
        self.init(
            hasVisibleThread: vm.visibleThread != nil,
            hasSelection: selected != nil || vm.selectedRemoteAgent != nil,
            canActOnSelection: selected != nil,
            sidebarVisible: vm.isSidebarVisible,
            rightPaneOpen: vm.isRightPaneOpen,
            hasMachineAgents: !machineAgents.isEmpty,
            agents: machineAgents.prefix(9).map { MenuState.Item(id: $0.id.rawValue, title: $0.name) },
            spaces: vm.visibleSpaces.map { MenuState.Item(id: $0.id.rawValue, title: $0.name) },
            machines: vm.remoteHosts.connections.prefix(8).map {
                MenuState.Machine(id: $0.id, name: $0.config.name, connected: $0.phase == .connected)
            }
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

/// Settings (⌘,) and Check for Updates, in the app menu.
struct AppSettingsCommands: Commands {
    let vm: ShepherdViewModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            SettingsCommandButton(vm: vm)
            if AppUpdater.shared.available {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            }
        }
    }
}

/// File ▸ New Agent…, New Space…, and ⌘W as Close Pane.
struct FileCommands: Commands {
    let vm: ShepherdViewModel
    let keys: KeybindingsStore
    /// The rebindings, so a changed chord rebuilds these items.
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Agent in Current Checkout") { later { vm.quickCreateAgent() } }
                .keyboardShortcut(keys.shortcut(.newAgent))
            Button("New Agent with Options…") { later { vm.showNewAgentSheet = true } }
                .keyboardShortcut(keys.shortcut(.newAgentOptions))
            Button("New Space…") { later { vm.addSpaceFromPanel() } }
                .keyboardShortcut(keys.shortcut(.newSpace))
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Pane") { later { vm.closeFocusedPane() } }
                .keyboardShortcut(keys.shortcut(.closePane))
        }
    }
}

/// View ▸ Command Palette, sidebar, right pane (and the Debug component gallery).
struct ViewCommands: Commands {
    let vm: ShepherdViewModel
    let menu: MenuState
    let keys: KeybindingsStore
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Command Palette") { later { vm.showCommandPalette.toggle() } }
                .keyboardShortcut(keys.shortcut(.commandPalette))
            Button(menu.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { later { vm.toggleSidebar() } }
                .keyboardShortcut(keys.shortcut(.toggleSidebar))
            Button(menu.rightPaneOpen ? "Hide Side Pane" : "Show Side Pane") { later { vm.toggleRightPane() } }
                .keyboardShortcut(keys.shortcut(.toggleRightPane))
                .disabled(!menu.hasVisibleThread)
            // ⌃1–4 pick the side pane's tabs: fixed, like ⌃⇧1–9 (no ⌘, so never rebound).
            ForEach(SidePaneTab.allCases, id: \.self) { tab in
                Button(tab.title) { later { vm.selectSidePaneTab(tab) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(tab.digit)")), modifiers: .control)
                    .disabled(!menu.hasVisibleThread)
            }
            #if DEBUG
            Divider()
            Button("Component Gallery") { later { vm.showComponentGallery.toggle() } }
            #endif
        }
    }
}

struct PaneCommands: Commands {
    let vm: ShepherdViewModel
    let keys: KeybindingsStore
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandMenu("Pane") {
            Button("Split Vertically") { later { vm.splitFocusedPane(axis: .vertical) } }
                .keyboardShortcut(keys.shortcut(.splitVertical))
            Button("Split Horizontally") { later { vm.splitFocusedPane(axis: .horizontal) } }
                .keyboardShortcut(keys.shortcut(.splitHorizontal))
            Divider()
            Button("Focus Next Pane") { later { vm.focusAdjacentPane(1) } }
                .keyboardShortcut(keys.shortcut(.focusNextPane))
            Button("Focus Previous Pane") { later { vm.focusAdjacentPane(-1) } }
                .keyboardShortcut(keys.shortcut(.focusPreviousPane))
            Divider()
            Button("Show or Hide Terminal") { later { vm.toggleTerminalPanel() } }
                .keyboardShortcut(keys.shortcut(.toggleTerminal))
            Button("Maximize or Restore Terminal") { later { vm.toggleTerminalMaximized() } }
                .keyboardShortcut(keys.shortcut(.maximizeTerminal))
            Button("New Terminal") { later { vm.newTerminalTab() } }
        }
    }
}

struct SpaceCommands: Commands {
    let vm: ShepherdViewModel
    let menu: MenuState

    var body: some Commands {
        CommandMenu("Space") {
            if menu.spaces.isEmpty {
                Button("No Spaces") {}.disabled(true)
            } else {
                ForEach(menu.spaces) { space in
                    Button(space.title) { later { vm.selectSpace(SpaceID(rawValue: space.id)) } }
                }
            }
        }
    }
}

struct AgentCommands: Commands {
    let vm: ShepherdViewModel
    let menu: MenuState
    let keys: KeybindingsStore
    let bindings: [ShortcutAction: KeyChord]

    var body: some Commands {
        CommandMenu("Agent") {
            Button("Focus") { later { vm.focusSelectedAgent() } }
                .disabled(!menu.hasSelection)
            Button("Rename…") { later { vm.renameSelectedAgent() } }
                .keyboardShortcut(keys.shortcut(.renameAgent))
                .disabled(!menu.canActOnSelection)
            Divider()
            Button("Stop") { later { vm.stopVisibleAgent() } }
                .keyboardShortcut(keys.shortcut(.stopAgent))
                .disabled(!menu.hasVisibleThread)
            Button("Choose Model…") { later { vm.sendThreadCommand(.modelPicker) } }
                .keyboardShortcut(keys.shortcut(.modelPicker))
                .disabled(!menu.hasVisibleThread)
            Button("Inspect Subagent") { later { vm.sendThreadCommand(.inspectSubagent) } }
                .keyboardShortcut(keys.shortcut(.inspectSubagent))
                .disabled(!menu.hasVisibleThread)
            Button("Previous Turn") { later { vm.sendThreadCommand(.previousTurn) } }
                .keyboardShortcut(keys.shortcut(.previousTurn))
                .disabled(!menu.hasVisibleThread)
            Button("Next Turn") { later { vm.sendThreadCommand(.nextTurn) } }
                .keyboardShortcut(keys.shortcut(.nextTurn))
                .disabled(!menu.hasVisibleThread)
            Divider()
            Button("Next Agent") { later { vm.selectAdjacentAgent(1) } }
                .keyboardShortcut(keys.shortcut(.nextAgent))
                .disabled(!menu.hasMachineAgents)
            Button("Previous Agent") { later { vm.selectAdjacentAgent(-1) } }
                .keyboardShortcut(keys.shortcut(.previousAgent))
                .disabled(!menu.hasMachineAgents)
            Divider()
            Button("Delete Agent") { later { vm.deleteSelectedAgent() } }
                .keyboardShortcut(keys.shortcut(.deleteAgent))
                .disabled(!menu.canActOnSelection)
            if !menu.agents.isEmpty {
                Divider()
                ForEach(Array(menu.agents.enumerated()), id: \.element.id) { index, agent in
                    Button(agent.title) {
                        later {
                            vm.showCommandPalette = false
                            vm.selectAgentDigit(index + 1)
                        }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

/// ⌃⇧1–9: machine jumps (this Mac is always ⌃⇧1; hosts follow in configured order).
struct MachineCommands: Commands {
    let vm: ShepherdViewModel
    let menu: MenuState

    var body: some Commands {
        CommandMenu("Machines") {
            Button("This Mac") { later { vm.jumpToMachine(1) } }
                .keyboardShortcut("1", modifiers: [.control, .shift])
            ForEach(Array(menu.machines.enumerated()), id: \.element.id) { index, machine in
                Button("⌁ \(machine.name)") { later { vm.jumpToMachine(index + 2) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: [.control, .shift])
                    .disabled(!machine.connected)
            }
        }
    }
}

/// Reads the mode in its own body, so a change re-renders this menu alone.
struct AppearanceCommands: Commands {
    let vm: ShepherdViewModel
    let themes: ThemeManager

    var body: some Commands {
        CommandMenu("Appearance") {
            ForEach(AppearanceMode.allCases) { option in
                Button {
                    later { vm.selectAppearance(option, systemColorScheme: ThemeManager.effectiveSystemColorScheme) }
                } label: {
                    if themes.mode == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        }
    }
}
