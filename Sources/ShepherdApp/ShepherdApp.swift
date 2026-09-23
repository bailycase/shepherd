import SwiftUI
import ShepherdUI
import AppKit
import ShepherdSessions

/// The Mac app, exposed as a library so an Xcode app target can provide the
/// entry point. Launch it with `ShepherdMacApp.main()` — SwiftUI must own the
/// instance for the delegate adaptor and state objects to be managed.
@MainActor
public struct ShepherdMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm: ShepherdViewModel
    /// Menus rebuild when a shortcut is rebound — the App body observes the
    /// store so every `.keyboardShortcut` below re-resolves.
    @ObservedObject private var keys = KeybindingsStore.shared
    @ObservedObject private var themes = ThemeManager.shared

    public init() {
        // Geist and Geist Mono ship in the ShepherdUI bundle; register them before any view draws.
        NWFonts.register()
        _vm = State(initialValue: ShepherdViewModel(server: .shared))
    }

    public var body: some Scene {
        WindowGroup {
            RootView(vm: vm)
                // Host role: bind the remote listener if this Mac serves its
                // sessions (the toggle persists; a host stays a host). The
                // TCP listener is independent of the extension socket, so
                // ordering against server.start() does not matter.
                .task {
                    vm.applyRemoteListenerSetting()
                    PiUpdateManager.shared.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppLayout.windowDefaultWidth, height: AppLayout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommandButton(vm: vm)
                if AppUpdater.shared.available {
                    Button("Check for Updates…") {
                        AppUpdater.shared.checkForUpdates()
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Agent in Current Checkout") {
                    Task { @MainActor in vm.quickCreateAgent() }
                }
                .keyboardShortcut(keys.shortcut(.newAgent))
                Button("New Agent with Options…") {
                    Task { @MainActor in vm.showNewAgentSheet = true }
                }
                .keyboardShortcut(keys.shortcut(.newAgentOptions))
                Button("New Space…") {
                    Task { @MainActor in vm.addSpaceFromPanel() }
                }
                .keyboardShortcut(keys.shortcut(.newSpace))
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    Task { @MainActor in vm.showCommandPalette.toggle() }
                }
                .keyboardShortcut(keys.shortcut(.commandPalette))
                Button(vm.sidebarHidden ? "Show Sidebar" : "Hide Sidebar") {
                    Task { @MainActor in vm.sidebarHidden.toggle() }
                }
                .keyboardShortcut(keys.shortcut(.toggleSidebar))
                Button(vm.isRightPaneOpen ? "Close Pane" : "Review Changes") {
                    Task { @MainActor in vm.toggleRightPane() }
                }
                .keyboardShortcut(keys.shortcut(.toggleRightPane))
                .disabled(vm.visibleThread == nil)
                #if DEBUG
                Divider()
                Button("Component Gallery") {
                    Task { @MainActor in vm.showComponentGallery.toggle() }
                }
                #endif
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Pane") {
                    Task { @MainActor in vm.closeFocusedPane() }
                }
                .keyboardShortcut(keys.shortcut(.closePane))
            }
            CommandMenu("Pane") {
                Button("Split Vertically") {
                    Task { @MainActor in vm.splitFocusedPane(axis: .vertical) }
                }
                .keyboardShortcut(keys.shortcut(.splitVertical))
                Button("Split Horizontally") {
                    Task { @MainActor in vm.splitFocusedPane(axis: .horizontal) }
                }
                .keyboardShortcut(keys.shortcut(.splitHorizontal))
                Divider()
                Button("Focus Next Pane") {
                    Task { @MainActor in vm.focusAdjacentPane(1) }
                }
                .keyboardShortcut(keys.shortcut(.focusNextPane))
                Button("Focus Previous Pane") {
                    Task { @MainActor in vm.focusAdjacentPane(-1) }
                }
                .keyboardShortcut(keys.shortcut(.focusPreviousPane))
            }
            CommandMenu("Space") {
                if vm.visibleSpaces.isEmpty {
                    Button("No Spaces") {}.disabled(true)
                } else {
                    ForEach(vm.visibleSpaces) { space in
                        Button(space.name) {
                            let id = space.id
                            Task { @MainActor in vm.selectSpace(id) }
                        }
                    }
                }
            }
            CommandMenu("Agent") {
                let selected = vm.selectedRemoteAgent?.agentID ?? vm.selectedAgentID
                Button("Focus") {
                    Task { @MainActor in vm.focusSelectedAgent() }
                }
                .disabled(selected == nil && vm.selectedRemoteAgent == nil)
                Button("Rename…") {
                    Task { @MainActor in vm.renameSelectedAgent() }
                }
                .keyboardShortcut(keys.shortcut(.renameAgent))
                .disabled(selected == nil)
                Divider()
                Button("Stop") {
                    Task { @MainActor in vm.stopVisibleAgent() }
                }
                .keyboardShortcut(keys.shortcut(.stopAgent))
                .disabled(vm.visibleThread == nil)
                Button("Choose Model…") {
                    Task { @MainActor in vm.sendThreadCommand(.modelPicker) }
                }
                .keyboardShortcut(keys.shortcut(.modelPicker))
                .disabled(vm.visibleThread == nil)
                Button("Inspect Subagent") {
                    Task { @MainActor in vm.sendThreadCommand(.inspectSubagent) }
                }
                .keyboardShortcut(keys.shortcut(.inspectSubagent))
                .disabled(vm.visibleThread == nil)
                Button("Previous Turn") {
                    Task { @MainActor in vm.sendThreadCommand(.previousTurn) }
                }
                .keyboardShortcut(keys.shortcut(.previousTurn))
                .disabled(vm.visibleThread == nil)
                Button("Next Turn") {
                    Task { @MainActor in vm.sendThreadCommand(.nextTurn) }
                }
                .keyboardShortcut(keys.shortcut(.nextTurn))
                .disabled(vm.visibleThread == nil)
                Divider()
                Button("Next Agent") {
                    Task { @MainActor in vm.selectAdjacentAgent(1) }
                }
                .keyboardShortcut(keys.shortcut(.nextAgent))
                .disabled(vm.activeMachineAgents.isEmpty)
                Button("Previous Agent") {
                    Task { @MainActor in vm.selectAdjacentAgent(-1) }
                }
                .keyboardShortcut(keys.shortcut(.previousAgent))
                .disabled(vm.activeMachineAgents.isEmpty)
                Divider()
                Button("Delete Agent") {
                    Task { @MainActor in vm.deleteSelectedAgent() }
                }
                .keyboardShortcut(keys.shortcut(.deleteAgent))
                .disabled(selected == nil)
                if !vm.activeMachineAgents.isEmpty {
                    Divider()
                    ForEach(Array(vm.activeMachineAgents.prefix(9).enumerated()), id: \.element.id) { index, agent in
                        Button(agent.name) {
                            let digit = index + 1
                            Task { @MainActor in
                                vm.showCommandPalette = false
                                vm.selectAgentDigit(digit)
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    }
                }
            }
            // ⌃⇧1–9: machine jump (local is always ⌃⇧1, hosts follow in
            // configured order). Wired permanently like the agent digits.
            CommandMenu("Machines") {
                Button("This Mac") {
                    Task { @MainActor in vm.jumpToMachine(1) }
                }
                .keyboardShortcut("1", modifiers: [.control, .shift])
                ForEach(Array(vm.remoteHosts.connections.prefix(8).enumerated()), id: \.element.id) { index, connection in
                    Button("⌁ \(connection.config.name)") {
                        let digit = index + 2
                        Task { @MainActor in vm.jumpToMachine(digit) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 2)")), modifiers: [.control, .shift])
                    .disabled(connection.phase != .connected)
                }
            }
            CommandMenu("Appearance") {
                ForEach(AppearanceMode.allCases) { mode in
                    Button {
                        Task { @MainActor in
                            vm.selectAppearance(
                                mode,
                                systemColorScheme: ThemeManager.effectiveSystemColorScheme
                            )
                        }
                    } label: {
                        if themes.mode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            }
        }

    }
}

/// Bare SwiftPM executables launch as background processes; promote to a
/// regular app so the window fronts when run from a terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            _ = try ShepherdPiTheme.installedPath(for: ThemeManager.shared.current)
        } catch {
            NSLog("Shepherd: initial theme install failed: \(error)")
        }
        ThemeManager.shared.applyApplicationAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        #if DEBUG
        // Dev builds badge the Dock icon so they're distinguishable from the
        // installed copy in the Dock and ⌘Tab. Runtime-only — Release and
        // Finder are untouched.
        if let icon = NSApp.applicationIconImage {
            let badged = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                let text = "DEV" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: rect.height * 0.18),
                    .foregroundColor: NSColor.white,
                ]
                let textSize = text.size(withAttributes: attrs)
                let pad = rect.height * 0.05
                let pill = NSRect(
                    x: rect.midX - textSize.width / 2 - pad,
                    y: rect.height * 0.08,
                    width: textSize.width + pad * 2,
                    height: textSize.height + pad
                )
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                text.draw(
                    at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
                    withAttributes: attrs
                )
                return true
            }
            NSApp.applicationIconImage = badged
        }
        #endif

        // Sessions live and die with the app: start the in-process session
        // server (extension socket) and shut it down on quit so every agent
        // stops when Shepherd stops, like any terminal app.
        do {
            try SessionServer.shared.start()
        } catch {
            NSLog("Shepherd: failed to start session server: \(error)")
        }
    }

    /// Quitting kills every agent process (sessions die with the app), so a
    /// quit while agents are mid-turn asks first. Idle/done agents quit
    /// silently — their transcripts are on disk and respawn on relaunch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = SessionServer.shared.state.agents.filter {
            $0.status == .working || $0.status == .blocked
        }
        guard !busy.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busy.count == 1
            ? "1 agent is still working"
            : "\(busy.count) agents are still working"
        let names = busy.prefix(5).map(\.name).joined(separator: "\n")
        let more = busy.count > 5 ? "\n…" : ""
        alert.informativeText = "Quitting stops their processes mid-turn. Conversations stay on disk and reopen on next launch.\n\n\(names)\(more)"
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionServer.shared.stop()
    }

}
