import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The sidebar (NWNavigation; Main, Running, NavNewThread, NavAutomations, NavHosts): the top bar
/// with Search and Hide sidebar, the destinations (New thread, Automations, More ▸ Hosts and
/// Extensions), Needs you, Recents, and the footer with the Mac's user and Settings. Subagents
/// have no rows; one waiting on you puts its thread in Needs you.
///
/// Needs you and Recents are one lazy list: a fleet runs to hundreds of threads, and only the rows
/// on screen are built. Each row is a plain value compared before it redraws, so a status report
/// or a selection redraws the rows it changed and nothing else.
struct SidebarView: View {
    var vm: ShepherdViewModel

    var body: some View {
        let _ = NWRenderProbe.tick("shell.sidebar")
        let keys = vm.keybindings
        NWSidebar(topBar: NWSidebarTopBar(searchShortcut: keys.display(.commandPalette), hideShortcut: keys.display(.toggleSidebar),
                                          search: { vm.showCommandPalette = true }, hide: { vm.toggleSidebar() })) {
            VStack(spacing: 0) {
                SidebarDestinations(vm: vm)
                SidebarListsView(vm: vm)
            }
        } footer: {
            let footer = vm.sidebarFooterIdentity ?? SidebarDerivation.footer
            NWSidebarFooter(name: footer.name, detail: footer.detail, settingsShortcut: "⌘,") { vm.showSettings = true }
        }
    }
}

// MARK: Destinations

/// The destinations: they never move. More discloses Hosts (with how many hosts are offline)
/// and Extensions.
private struct SidebarDestinations: View {
    var vm: ShepherdViewModel

    var body: some View {
        let rows = SidebarDerivation.destinations(shown: vm.shownDestination, moreOpen: vm.moreOpen,
                                                  offlineHosts: vm.offlineHostCount,
                                                  newThreadChord: vm.keybindings.display(.newAgent))
        VStack(alignment: .leading, spacing: NWSidebarMetrics.rowSpacing) {
            ForEach(rows) { row in
                NWSidebarDestination(row.title, icon: row.icon, selected: row.selected, child: row.child, trailing: row.trailing) {
                    vm.openSidebarDestination(row.target)
                }
                .equatable()
                .accessibilityLabel(Self.label(row))
                .nwTransition(.disclosure)
            }
        }
        .padding(.vertical, NWSidebarMetrics.destinationsPadding)
        .padding(.horizontal, AppLayout.sidebarPadding)
        .nwAnimation(.disclosure, value: vm.moreOpen)
    }

    private static func label(_ row: SidebarDerivation.Destination) -> String {
        switch (row.target, row.trailing) {
        case (.more, _): "More, \(row.icon == .disclosure(open: true) ? "expanded" : "collapsed")"
        case (_, .alert(let alert)): "\(row.title), \(alert)"
        default: row.title
        }
    }
}

// MARK: Lists

/// One element of the lazy list: a section's header or a row.
private enum SidebarItem: Identifiable, Equatable {
    case header(NWSidebarSection.Kind)
    case row(SidebarListRow)

    var id: AnyHashable {
        switch self {
        case .header(.needsYou): AnyHashable("header.needsYou")
        case .header(.recents): AnyHashable("header.recents")
        case .row(let row): AnyHashable(row.id)
        }
    }
}

/// Needs you (only while something waits) then Recents, in one lazy list that takes the rest of
/// the column.
private struct SidebarListsView: View {
    var vm: ShepherdViewModel

    var body: some View {
        let lists = vm.presentedSidebarLists
        let items = Self.items(lists)
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                    ForEach(items) { item in
                        SidebarItemView(vm: vm, item: item)
                            .equatable()
                            .nwTransition(.list)
                    }
                }
                .padding(.horizontal, AppLayout.sidebarPadding)
                .padding(.bottom, NW.Space.m)
            }
            .scrollIndicators(.hidden)
            // Keyboard selection (⌘1–9, ⌘↑/↓) can land on a row scrolled out of view: scroll on
            // the next run-loop turn, once the row exists. The trigger is a counter, so selecting
            // the same row again still scrolls back to it.
            .onChange(of: vm.sidebarRevealRequest) {
                guard let target = vm.selectedSidebarRow else { return }
                DispatchQueue.main.async {
                    withNWAnimation(.scroll) { proxy.scrollTo(AnyHashable(target)) }
                }
            }
        }
        // Rows arriving, leaving, and moving up animate; the key is the rows' ids, never the rows.
        .nwAnimation(.list, value: items.map(\.id))
    }

    private static func items(_ lists: SidebarLists) -> [SidebarItem] {
        var items: [SidebarItem] = []
        if !lists.needsYou.isEmpty {
            items.append(.header(.needsYou(count: lists.needsYou.count)))
            items += lists.needsYou.map(SidebarItem.row)
        }
        if !lists.recents.isEmpty {
            items.append(.header(.recents))
            items += lists.recents.map(SidebarItem.row)
        }
        return items
    }
}

/// One element, a single view whatever it shows (a lazy stack's fast path), redrawn only when
/// its values change.
private struct SidebarItemView: View, Equatable {
    var vm: ShepherdViewModel
    let item: SidebarItem

    static func == (a: SidebarItemView, b: SidebarItemView) -> Bool { a.vm === b.vm && a.item == b.item }

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .header(let kind):
                NWSidebarSection(kind)
            case .row(let row):
                NWSidebarRow(row.title, leading: row.leading, selected: row.selected, dimmed: row.offline,
                             accessory: row.accessory)
                    .help(row.help)
                    .sidebarTapRow { vm.selectSidebarRow(row.id) }
                    .accessibilityLabel(row.accessibilityLabel)
                    .accessibilityAddTraits(row.selected ? .isSelected : [])
                    .contextMenu { SidebarRowMenu(vm: vm, row: row) }
            }
        }
    }
}

/// A row's context menu: every action the agent had in the old tree.
private struct SidebarRowMenu: View {
    var vm: ShepherdViewModel
    let row: SidebarListRow

    var body: some View {
        switch row.id {
        case .local(let id):
            if let automation = row.automation {
                // A settled run reads done and runs again, replacing it; only a live one
                // (starting included) stops.
                if row.automationLive {
                    Button("Stop") { vm.stopAutomation(automation) }
                } else {
                    Button("Run Now") { vm.runAutomationNow(automation) }
                }
                Divider()
                Button("Delete Automation", role: .destructive) { vm.deleteAutomation(automation) }
            } else {
                // NWComposer's agent menu: Rename… with its keys, Fork and Copy with their glyphs.
                Button("Rename…") { vm.agentRenameTarget = id }
                    .keyboardShortcut(KeybindingsStore.shared.shortcut(.renameAgent))
                Button("Fork from Here", systemImage: "arrow.branch") { vm.forkAgent(id) }
                Button("Copy Transcript", systemImage: "doc.on.doc") { vm.copyAgentTranscript(id) }
                Divider()
                Button("Review Changes") { vm.selectAgent(id); vm.openUserReview() }
                Button("Open in Finder") { vm.openAgentInFinder(id) }
                Divider()
                if row.worktree {
                    Button("Finalize Worktree…") { vm.beginFinalizeWorktree(id) }
                    Divider()
                    Button("Delete Worktree Agent…", role: .destructive) { vm.worktreeDeleteTarget = id }
                } else {
                    Button("Delete Agent", role: .destructive) { vm.deleteAgent(id) }
                }
            }
        case .remote(let ref):
            if row.offline {
                // Every action goes through the host, which is not connected.
                Button("Host Offline") {}.disabled(true)
            } else {
                RemoteRowMenu(vm: vm, row: row, ref: ref)
            }
        }
    }
}

/// A connected host's thread: what its row offered in the old tree.
private struct RemoteRowMenu: View {
    var vm: ShepherdViewModel
    let row: SidebarListRow
    let ref: RemoteAgentRef

    var body: some View {
        Button("Rename…") { vm.remoteRenameTarget = ref }
        Divider()
        if row.worktree {
            Button("Finalize Worktree…") {
                vm.remoteWorktreeFinalize = true
                vm.remoteWorktreeSheet = ref
            }
        }
        Button("Review Uncommitted Changes") { vm.openRemoteReview(ref, pullRequest: false) }
        Button("Review PR Changes") { vm.openRemoteReview(ref, pullRequest: true) }
        Button(row.worktree ? "Delete Worktree Agent…" : "Delete Agent", role: .destructive) {
            vm.requestRemoteDelete(ref)
        }
    }
}

// MARK: Words

/// The status language's words for an agent row.
enum AgentRow {
    /// A finished agent whose turn ended in an error reads failed.
    static func statusWord(_ status: AgentStatus, turnFailed: Bool = false) -> String {
        switch status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle: "idle"
        case .done: turnFailed ? "failed" : "done"
        }
    }
}

/// An automation run's state, as its row and menu read it.
enum AutomationRow {
    /// A run still starting (idle before its first turn settled) reads running; one that has
    /// settled reads done, or failed when its last turn ended in an error.
    static func stateWord(_ agent: Agent?, run: AutomationRun?, turnFailed: Bool) -> String {
        guard let agent else { return "stopped" }
        return switch agent.status {
        case .blocked: "needs you"
        case .working, .idle, .done:
            if isLive(agent, run: run) { "running" } else { turnFailed && agent.status == .done ? "failed" : "done" }
        }
    }

    /// Its run is going (`AutomationRun.isLive`, the rule the host refuses Run Now by): the
    /// menu offers Stop rather than Run Now.
    static func isLive(_ agent: Agent?, run: AutomationRun?) -> Bool {
        agent.map { AutomationRun.isLive(agentStatus: $0.status, run: run) } ?? false
    }

    static func state(_ agent: Agent?, run: AutomationRun?, turnFailed: Bool) -> AgentState {
        guard let agent else { return .idle }
        if agent.status == .blocked { return .attention }
        if isLive(agent, run: run) { return .running }
        return turnFailed && agent.status == .done ? .failed : .done
    }
}

// MARK: Interaction

extension View {
    /// Row interaction: a tap view with button traits (a `Button` would bring an AppKit
    /// focus-ring view per row, built as each scrolls in).
    func sidebarTapRow(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(enabled ? .isButton : [])
            .accessibilityAction { if enabled { action() } }
    }
}
