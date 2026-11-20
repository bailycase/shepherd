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
        navigator.layout == .pad && navigator.presented == nil
            && visibleThread.map { !navigator.composerPresentation.state(for: $0).choosingModel } != false
    }

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

    var canToggleSidePane: Bool {
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
        let sidebar = SidebarThreads.of(hosts)
        let automations = AutomationsStore.of(hosts)
        let groups = sidebar.groups(model, unread: automations.unreadRuns, paused: automations.pausedTriggers,
                                    filters: sidebar.activeFilters(model))
        // The sidebar's order, without projects, designs, or runs in collapsed groups.
        let asks = groups.needsYou.filter { $0.origin != .project }.map(\.ref)
        let automationRuns = groups.manualRuns.compactMap(\.run)
            + groups.runs.filter(\.expanded).flatMap { $0.rows.map(\.ref) } + groups.matchingRuns.map(\.ref)
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
        guard canToggleSidePane else { return }
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

/// SwiftUI publishes these native menu commands to the hardware keyboard shortcuts overlay too.
struct MobileCommands: Commands {
    let target: MobileCommandTarget?

    var body: some Commands {
        if let target, target.navigator.layout == .pad {
            let canWalk = target.canWalk
            CommandMenu("Thread") {
                Button("New Thread…") { NewThreadHooks.open(navigator: target.navigator) }
                    .keyboardShortcut(MobileShortcut.newThread.shortcut)
                    .disabled(!target.available || target.app.hosts.hosts.isEmpty)
                Button("Stop") {
                    if let store = target.stoppableThread { Task { await store.abort() } }
                }
                .keyboardShortcut(MobileShortcut.stop.shortcut)
                .disabled(target.stoppableThread == nil)
                Button("Rename…") {
                    if let ref = target.visibleThread { target.navigator.present(.search(.rename(ref))) }
                }
                .keyboardShortcut(MobileShortcut.rename.shortcut)
                .disabled(!target.canRename)
                Button("Choose Model…") {
                    if let ref = target.visibleThread {
                        target.navigator.composerPresentation.state(for: ref).choosingModel = true
                    }
                }
                .keyboardShortcut(MobileShortcut.chooseModel.shortcut)
                .disabled(!target.canChooseModel)
                Divider()
                Button("Previous Thread") { target.walkThreads(forward: false) }
                    .keyboardShortcut(MobileShortcut.previousThread.shortcut)
                    .disabled(!canWalk)
                Button("Next Thread") { target.walkThreads(forward: true) }
                    .keyboardShortcut(MobileShortcut.nextThread.shortcut)
                    .disabled(!canWalk)
            }
            CommandGroup(after: .sidebar) {
                Button("Show or Hide Sidebar") { target.toggleSidebar() }
                    .keyboardShortcut(MobileShortcut.toggleSidebar.shortcut)
                    .disabled(!target.canToggleSidebar)
                Button("Show or Hide Side Pane") { target.toggleSidePane() }
                    .keyboardShortcut(MobileShortcut.toggleSidePane.shortcut)
                    .disabled(!target.canToggleSidePane)
                Button("Show or Hide Terminal") { target.toggleTerminal() }
                    .keyboardShortcut(MobileShortcut.toggleTerminal.shortcut)
                    .disabled(!target.available || target.visibleThread == nil)
            }
        }
    }
}
