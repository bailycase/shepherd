import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The scene supplies its own target; a command never uses another window's selection.
@MainActor
struct MobileCommandTarget {
    let app: MobileApp
    let navigator: MobileNavigator

    var available: Bool {
        guard navigator.layout == .pad, navigator.presented == nil else { return false }
        guard let ref = visibleThread else { return true }
        let presentation = navigator.composerPresentation.state(for: ref)
        return !presentation.choosingModel && !presentation.showingContext
    }

    var canStart: Bool { available && !app.hosts.hosts.isEmpty }

    var visibleThread: AgentRef? {
        switch navigator.padPath.last {
        case nil: navigator.padSelection
        case .thread(let ref)?: ref
        default: nil
        }
    }

    var canToggleSidebar: Bool {
        available && !navigator.padShowsDesign && !navigator.padShowsForgeWide
    }

    var canToggleThreadPanes: Bool {
        available && visibleThread != nil
    }

    var canRename: Bool {
        guard available, let ref = visibleThread, let host = app.hosts.host(ref.host) else { return false }
        return host.agent(ref.agent) != nil && host.phase.isConnected && host.supports(RemoteProtocol.agentActionsCapability)
    }

    var stoppableThread: NativeThreadStore? {
        guard let store = liveThread, store.supports("abort"), store.running || !store.dialogs.isEmpty else { return nil }
        return store
    }

    var canChooseModel: Bool {
        guard let ref = visibleThread, liveThread?.supports("setModel") == true else { return false }
        // Full Changes replaces the thread, including the composer's sheet presenter.
        let pane = navigator.sidePane
        return !(pane.arranged == nil && pane.isOpen && pane.tab == .changes
            && ReviewStores.shared.store(for: ref).padLayout == .full)
    }

    private var liveThread: NativeThreadStore? {
        guard available, let ref = visibleThread, app.hosts.host(ref.host)?.phase.isConnected == true,
              let store = app.threads.existingStore(for: ref), store.isLive else { return nil }
        return store
    }

    var canWalk: Bool { available && !walkRows.isEmpty }

    private var walkRows: [FleetRef] {
        let hosts = app.hosts
        let model = HomeFeed.of(hosts).model
        let automations = AutomationsStore.of(hosts)
        let groups = SidebarThreads.of(hosts).groups(model, unread: automations.unreadRuns, paused: automations.pausedTriggers)
        // The sidebar's order, without projects, designs, or runs in collapsed groups.
        let asks = groups.needsYou.filter { $0.origin != .project }.map(\.ref)
        let automationRuns = groups.automationRuns.compactMap(\.run)
            + groups.runs.filter(\.expanded).flatMap { $0.rows.map(\.ref) }
        return asks + automationRuns + groups.working.map(\.ref) + groups.done.map(\.ref)
            + groups.pinned.map(\.ref) + groups.recents.filter { $0.design == nil }.map(\.ref)
    }

    func walkThreads(forward: Bool) {
        guard available else { return }
        let rows = walkRows
        guard !rows.isEmpty else { return }
        let index = navigator.selectedThread.flatMap { rows.firstIndex(of: $0.fleetRef) }
        let current = index ?? (forward ? rows.count - 1 : 0)
        let next = (current + (forward ? 1 : -1) + rows.count) % rows.count
        navigator.open(.thread(rows[next].agentRef))
    }

    func toggleSidebar() {
        guard canToggleSidebar else { return }
        withSHAnimation(.pane) {
            // The laptop arrangement has no split view; leave it as Back would.
            let show = navigator.sidePane.arranged != nil || navigator.padColumns == .detailOnly
            navigator.sidePane.arranged = nil
            navigator.padColumns = show ? .all : .detailOnly
        }
    }

    func toggleSidePane() {
        guard canToggleThreadPanes else { return }
        let pane = navigator.sidePane
        withSHAnimation(.pane) {
            let show = pane.arranged != nil || !pane.isOpen
            pane.arranged = nil
            pane.isOpen = show
        }
    }

    func toggleTerminal() {
        guard available, let ref = visibleThread else { return }
        let pane = navigator.sidePane
        withSHAnimation(.pane) {
            if pane.arranged == ref {
                pane.arrangedTerminal.toggle()
            } else if pane.isOpen && pane.tab == .terminal {
                pane.isOpen = false
            } else {
                navigator.open(.paneScreen(.terminal, thread: ref))
            }
        }
    }
}

/// A view observes the models and publishes changed enablement through the focused scene value.
/// The target references alone don't change when a thread starts running or its host disconnects.
struct MobileCommandFocus: ViewModifier {
    let target: MobileCommandTarget
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

    func body(content: Content) -> some View {
        let menu = target.menu(supportsMultipleWindows: supportsMultipleWindows)
        content.focusedSceneValue(\.mobileCommandFocus, Value(target: target, menu: menu))
    }

    struct Value {
        let target: MobileCommandTarget
        let menu: MenuState?
    }

    struct MenuState: Equatable {
        let canStart: Bool
        let canStop: Bool
        let canRename: Bool
        let canChooseModel: Bool
        let canOpenWindows: Bool
        let canWalk: Bool
        let canToggleSidebar: Bool
        let canToggleThreadPanes: Bool
    }
}

extension MobileCommandTarget {
    func menu(supportsMultipleWindows: Bool) -> MobileCommandFocus.MenuState? {
        guard navigator.layout == .pad else { return nil }
        let canOpenWindows = WindowAvailability.canOpenWindows(supportsMultipleWindows: supportsMultipleWindows,
                                                               hinge: navigator.hingeClosed != nil,
                                                               regularWidth: true,
                                                               tallWindow: navigator.padSidebarOverlays)
        return .init(canStart: canStart, canStop: stoppableThread != nil,
                     canRename: canRename, canChooseModel: canChooseModel, canOpenWindows: canOpenWindows,
                     canWalk: canWalk, canToggleSidebar: canToggleSidebar, canToggleThreadPanes: canToggleThreadPanes)
    }
}

/// SwiftUI publishes these native menu commands to the hardware keyboard shortcuts overlay too.
struct MobileCommands: Commands {
    let focus: MobileCommandFocus.Value?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        if let focus, let menu = focus.menu {
            let target = focus.target
            CommandGroup(replacing: .newItem) {
                Button("New Thread…") {
                    if target.canStart { NewThreadHooks.open(navigator: target.navigator) }
                }
                .keyboardShortcut(MobileShortcut.newThread.shortcut)
                .disabled(!menu.canStart)
                if menu.canOpenWindows {
                    Button("New Window") { openWindow(value: MobileWindowSeed()) }
                        .keyboardShortcut(MobileShortcut.newWindow.shortcut)
                }
            }
            CommandMenu("Thread") {
                Button("Stop") {
                    if let store = target.stoppableThread { Task { await store.abort() } }
                }
                .keyboardShortcut(MobileShortcut.stop.shortcut)
                .disabled(!menu.canStop)
                Button("Rename…") {
                    if target.canRename, let ref = target.visibleThread { target.navigator.present(.search(.rename(ref))) }
                }
                .keyboardShortcut(MobileShortcut.rename.shortcut)
                .disabled(!menu.canRename)
                Button("Choose Model…") {
                    if target.canChooseModel, let ref = target.visibleThread {
                        target.navigator.composerPresentation.state(for: ref).choosingModel = true
                    }
                }
                .keyboardShortcut(MobileShortcut.chooseModel.shortcut)
                .disabled(!menu.canChooseModel)
                Divider()
                Button("Previous Thread") { target.walkThreads(forward: false) }
                    .keyboardShortcut(MobileShortcut.previousThread.shortcut)
                    .disabled(!menu.canWalk)
                Button("Next Thread") { target.walkThreads(forward: true) }
                    .keyboardShortcut(MobileShortcut.nextThread.shortcut)
                    .disabled(!menu.canWalk)
            }
            CommandGroup(replacing: .sidebar) {
                Button("Show or Hide Sidebar") { target.toggleSidebar() }
                    .keyboardShortcut(MobileShortcut.toggleSidebar.shortcut)
                    .disabled(!menu.canToggleSidebar)
                Button("Show or Hide Side Pane") { target.toggleSidePane() }
                    .keyboardShortcut(MobileShortcut.toggleSidePane.shortcut)
                    .disabled(!menu.canToggleThreadPanes)
                Button("Show or Hide Terminal") { target.toggleTerminal() }
                    .keyboardShortcut(MobileShortcut.toggleTerminal.shortcut)
                    .disabled(!menu.canToggleThreadPanes)
            }
        }
    }
}
