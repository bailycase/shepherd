import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol

// A remote host's rows in the sidebar: its section header, then its spaces and agents with the
// same rows the local tree uses. While the host is not connected, one status row stands in for
// them ("Unreachable", Retry).

extension ShepherdViewModel {
    /// Appends a host's rows to the sidebar tree.
    func appendHost(_ connection: RemoteHostStore.Connection, to tree: inout SidebarTree) {
        let hostID = connection.id
        let connected = connection.phase == .connected
        let collapsed = collapsedHosts.contains(hostID)
        tree.append(.machine(SidebarMachine(
            hostID: hostID, title: connection.config.name, detail: Self.hostDetail(connection), collapsed: collapsed,
            hoverHint: machineKeycap(forHost: hostID), canAddSpace: connected,
            pendingOperations: remoteWorktreeOperationIDs.keys.filter { $0.hostID == hostID }
                .sorted { $0.agentID.rawValue < $1.agentID.rawValue })))
        guard !collapsed else { return }
        guard connected else {
            tree.append(.notice(hostID: hostID, phase: connection.phase.kind))
            return
        }
        let badges = remoteShortcutBadges(hostID: hostID)
        let bySpace = Self.sidebarAgentsBySpace(connection.state.agents)
        for space in connection.state.spaces where !space.hidden {
            let agents = bySpace[space.id] ?? []
            let spaceCollapsed = isRemoteSpaceCollapsed(hostID: hostID, spaceID: space.id)
            tree.append(.space(SidebarSpace(hostID: hostID, id: space.id, name: space.name, collapsed: spaceCollapsed,
                                            count: agents.count, blocked: SidebarAttention.count(agents, children: connection.children))))
            guard !spaceCollapsed else { continue }
            for agent in agents {
                tree.append(.remoteAgent(hostID: hostID, model: remoteSidebarRowModel(for: agent, on: connection, badges: badges)))
            }
        }
        appendRemoteAutomations(connection, to: &tree)
    }

    /// A connected host's agent count, or how many questions wait on you there.
    private static func hostDetail(_ connection: RemoteHostStore.Connection) -> NWSidebarSectionDetail {
        guard connection.phase == .connected else { return .none }
        let blocked = SidebarAttention.count(connection.state.agents, children: connection.children)
        return blocked > 0 ? .text("\(blocked) need you", tone: .attention) : .count(connection.state.agents.count)
    }
}

/// A space on a host: its disclosure row, and a new agent there from its `+`.
struct RemoteSpaceRow: View {
    var vm: ShepherdViewModel
    let hostID: UUID
    let space: SidebarSpace

    var body: some View {
        let id = space.id
        SpaceRow(name: space.name, collapsed: space.collapsed, count: space.count, blocked: space.blocked,
                 onToggle: { vm.toggleRemoteSpaceCollapsed(hostID: hostID, spaceID: id) },
                 onNewAgent: { vm.showNewAgentSheetForRemote(hostID: hostID, spaceID: id) })
    }
}

/// An agent on a host, with its drag, drop, and context menu.
struct RemoteAgentRow: View {
    var vm: ShepherdViewModel
    let zone: SidebarDropZone
    let hostID: UUID
    let model: SidebarAgentRowModel

    var body: some View {
        let agent = model.agent
        let ref = RemoteAgentRef(hostID: hostID, agentID: agent.id)
        AgentRow(model: model) { vm.selectRemoteAgent(hostID: hostID, agentID: agent.id) }
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(remote: ref)) }
            .sidebarDropRow(zone, id: ref, target: .remoteAgent(ref))
            .contextMenu {
                Button("Rename…") { vm.remoteRenameTarget = ref }
                Divider()
                if agent.worktreeBranch != nil {
                    Button("Finalize Worktree…") {
                        vm.remoteWorktreeFinalize = true
                        vm.remoteWorktreeSheet = ref
                    }
                }
                Button("Review Uncommitted Changes") { vm.openRemoteReview(ref, pullRequest: false) }
                Button("Review PR Changes") { vm.openRemoteReview(ref, pullRequest: true) }
                Button(agent.worktreeBranch == nil ? "Delete Agent" : "Delete Worktree Agent…", role: .destructive) {
                    vm.requestRemoteDelete(ref)
                }
            }
    }
}

/// A host's Automations disclosure: its count, or how many runs wait on you.
struct RemoteAutomationsRow: View {
    var vm: ShepherdViewModel
    let header: SidebarRemoteAutomations

    var body: some View {
        let hostID = header.hostID
        SpaceRow(name: "Automations", collapsed: header.collapsed, count: header.count, blocked: header.blocked,
                 onToggle: { vm.toggleRemoteAutomations(hostID) })
    }
}

/// An automation on a host: its run's dot and word. Clicking opens its run, or its details
/// while it has none; the context menu runs, stops, switches and deletes it on the host.
struct RemoteAutomationRow: View {
    var vm: ShepherdViewModel
    let row: SidebarRemoteAutomation

    var body: some View {
        let key = row.key
        let abilities = row.abilities
        NWSidebarRow(row.name, state: row.state, selected: row.selected, depth: 1, accessory: row.accessory)
            .opacity(row.pending ? NWListMetrics.dimmedOpacity : 1)
            .sidebarTapRow { vm.openRemoteAutomation(row) }
            .accessibilityLabel("\(row.name), automation, \(row.word)")
            .contextMenu {
                if let reason = abilities.readOnlyReason {
                    Text(reason)
                }
                if row.run == nil {
                    Button("Run Now") { vm.performRemoteAutomation(key, .run) }.disabled(!abilities.run || row.pending)
                } else {
                    Button("Stop") { vm.performRemoteAutomation(key, .stop) }.disabled(!abilities.stop || row.pending)
                }
                Toggle("Starts with Shepherd", isOn: Binding(get: { row.enabled },
                                                             set: { vm.performRemoteAutomation(key, .setEnabled(enabled: $0)) }))
                    .disabled(!abilities.toggle || row.pending)
                Button("Details and Runs…") { vm.showRemoteAutomation(key) }
                Divider()
                Button("Delete Automation", role: .destructive) { vm.performRemoteAutomation(key, .delete) }
                    .disabled(!abilities.edit || row.pending)
            }
    }
}

/// The row in place of a disconnected host's spaces: Connecting… ⇄ Unreachable ⇄ Off
/// cross-fade in one slot as the connection retries.
struct HostNoticeRow: View {
    var vm: ShepherdViewModel
    let hostID: UUID
    let phase: RemoteHostStore.Phase.Kind

    var body: some View {
        ZStack(alignment: .leading) { status }
            .nwAnimation(.content, value: phase)
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .connected:
            EmptyView()
        case .connecting:
            NWSidebarNoticeRow(.running, text: "Connecting…")
                .nwTransition(.content)
        case .failed:
            NWSidebarNoticeRow(.failed, text: "Unreachable", actionTitle: "Retry") { vm.remoteHosts.reconnect(id: hostID) }
                .nwTransition(.content)
        case .disconnected:
            NWSidebarNoticeRow(.idle, text: "Off", actionTitle: "Connect") { vm.remoteHosts.reconnect(id: hostID) }
                .nwTransition(.content)
        }
    }
}

extension RemoteHostStore.Phase {
    enum Kind { case disconnected, connecting, connected, failed }

    /// The phase without a failure's reason: what the sidebar's status row and the workspace's
    /// placeholders cross-fade between (a retry that fails again changes nothing on screen).
    var kind: Kind {
        switch self {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .failed: .failed
        }
    }
}
