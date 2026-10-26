import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A thread row's long-press menu in the sidebar and Home: the Mac's row menu for a connected host's thread (`RemoteRowMenu`
/// with Pin), each item only where the thread's own host takes it. Every action names the row's host and agent; nothing is
/// sent to any other host, and nothing reaches this device's files. Open in new window comes first where windows exist.
struct ThreadRowMenu: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        OpenInNewWindowButton(thread: thread)
        if let host = hosts.host(thread.host), let agent = host.agent(thread.agent) {
            let abilities = FleetThreadAbilities(agent: agent, state: host.state, connected: host.phase.isConnected,
                                                 capabilities: host.capabilities)
            ThreadRowMenuItems(thread: thread, abilities: abilities, hostName: host.name)
        }
    }
}

/// The items, from the thread's abilities. A host that is offline keeps only Unpin (a pin is this device's) and says why.
struct ThreadRowMenuItems: View {
    let thread: AgentRef
    let abilities: FleetThreadAbilities
    let hostName: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let sidebar = SidebarThreads.of(hosts)
        if abilities.pin {
            let pinned = sidebar.isPinned(thread)
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : SHGlyph.pin.symbolName) {
                sidebar.togglePin(thread)
            }
        }
        if !abilities.connected {
            Button("\(hostName) is offline", systemImage: "wifi.slash") {}.disabled(true)
        } else {
            Section {
                if abilities.rename {
                    Button("Rename…", systemImage: "pencil") { navigator.present(.search(.rename(thread))) }
                }
                if !abilities.moveSpaces.isEmpty {
                    Menu("Move to Space", systemImage: "folder") {
                        ForEach(abilities.moveSpaces) { space in
                            Button(space.name) { move(to: space.id) }
                        }
                    }
                }
            }
            Section {
                if abilities.finalize {
                    Button("Finalize Worktree…", systemImage: "checkmark.seal") { navigator.present(.review(.finalize(thread))) }
                }
                if abilities.review {
                    Button("Review Uncommitted Changes", systemImage: "plus.forwardslash.minus") { review(pullRequest: false) }
                    Button("Review PR Changes", systemImage: "arrow.triangle.pull") { review(pullRequest: true) }
                }
            }
            if abilities.delete {
                Button(abilities.worktree ? "Delete Worktree Agent…" : "Delete Agent…", systemImage: "trash", role: .destructive) {
                    navigator.present(.search(.delete(thread)))
                }
            }
        }
    }

    private func move(to space: SpaceID) {
        let ref = thread
        let hosts = hosts
        AgentActions.run("Couldn’t move the thread", navigator: navigator) {
            try await AgentActions.move(ref, to: space, hosts: hosts)
        }
    }

    /// The review of the thread's own host, at the scope the Mac's item names (`ReviewStore.show(_:)`).
    private func review(pullRequest: Bool) {
        ReviewStores.shared.store(for: thread).show(pullRequest ? .pullRequest : .uncommitted)
        navigator.open(.review(.changes(thread, file: nil)))
    }
}

/// Done's "Mark all seen" chip, beside its header.
struct MarkAllSeenChip: View {
    let rows: [FleetThreadRow]
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        SHSidebarHeaderChip("Mark all seen") { SidebarThreads.of(hosts).markSeen(rows) }
    }
}

/// An automation run's long press (the Mac's This Mac run menu: Run Now or Stop, Delete Automation). Run Now acts on the
/// run's own host where it takes it; Stop and Delete open the automation, whose detail confirms them as everywhere on the
/// phone. A Project's automation says it is managed in its Project.
struct AutomationRunMenu: View {
    let row: FleetAutomationRow
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if let run = row.run { OpenInNewWindowButton(thread: run.agentRef) }
        let key = AutomationKey(host: row.host, automation: row.automationID)
        let store = AutomationsStore.of(hosts)
        let listed = store.model.row(key)
        Button("Open Automation", systemImage: SHGlyph.automation.symbolName) { AutomationsHooks.open(key, navigator: navigator) }
        if let listed {
            if listed.live {
                Button("Stop…", systemImage: "stop") { AutomationsHooks.open(key, navigator: navigator) }
                    .disabled(!listed.abilities.stop)
            } else {
                Button("Run Now", systemImage: "play") { store.run(key) }
                    .disabled(!listed.abilities.run)
            }
            if let reason = listed.abilities.readOnlyReason {
                Button(reason) {}.disabled(true)
            }
        }
    }
}
