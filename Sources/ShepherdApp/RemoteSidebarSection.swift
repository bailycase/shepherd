import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol

/// A remote host's section in the sidebar: a section header, then its spaces and agents with
/// the same rows the local tree uses. While the host is not connected, one status row stands in
/// for them ("Unreachable", Retry).
struct RemoteHostBlock: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection

    private var detail: NWSidebarSectionDetail {
        guard connection.phase == .connected else { return .none }
        let blocked = connection.state.agents.count { $0.status == .blocked }
            + connection.children.values.reduce(0) { $0 + $1.count(where: \.needsAttention) }
        return blocked > 0 ? .text("\(blocked) need you", tone: .attention) : .count(connection.state.agents.count)
    }

    var body: some View {
        let connected = connection.phase == .connected
        NWSidebarSection(
            connection.config.name,
            detail: detail,
            collapsed: vm.collapsedHosts.contains(connection.id),
            hoverHint: vm.machineKeycap(forHost: connection.id),
            toggle: { vm.toggleHostCollapsed(connection.id) }
        ) {
            if connected {
                SidebarPlus(help: "New Space on \(connection.config.name)") { vm.remoteSpacePickerHostID = connection.id }
            }
        }
        .contextMenu {
            ForEach(Array(vm.remoteWorktreeOperationIDs.keys.filter { $0.hostID == connection.id }), id: \.self) { target in
                Button("Check Worktree Operation…") { vm.remoteWorktreeSheet = target }
            }
            Button("New Space…") { vm.remoteSpacePickerHostID = connection.id }
            Button("Reconnect") { vm.remoteHosts.reconnect(id: connection.id) }
        }

        if !vm.collapsedHosts.contains(connection.id) {
            if connected {
                ForEach(connection.state.spaces.filter { !$0.hidden }) { space in
                    let agents = ShepherdViewModel.sidebarAgents(of: space.id, in: connection.state.agents)
                    let spaceCollapsed = vm.isRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id)
                    SpaceRow(
                        name: space.name,
                        collapsed: spaceCollapsed,
                        count: agents.count,
                        blocked: agents.count { $0.status == .blocked },
                        onToggle: { vm.toggleRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id) },
                        onNewAgent: { vm.showNewAgentSheetForRemote(hostID: connection.id, spaceID: space.id) }
                    )
                    if !spaceCollapsed {
                        ForEach(agents) { agent in
                            remoteAgentRows(agent)
                        }
                    }
                }
            } else {
                statusRow
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch connection.phase {
        case .connected:
            EmptyView()
        case .connecting:
            NWSidebarNoticeRow(.running, text: "Connecting…")
        case .failed:
            NWSidebarNoticeRow(.failed, text: "Unreachable", actionTitle: "Retry") { vm.remoteHosts.reconnect(id: connection.id) }
        case .disconnected:
            NWSidebarNoticeRow(.idle, text: "Off", actionTitle: "Connect") { vm.remoteHosts.reconnect(id: connection.id) }
        }
    }

    @ViewBuilder
    private func remoteAgentRows(_ agent: Agent) -> some View {
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        let selected = vm.selectedRemoteAgent == ref
        let badge = vm.showAgentShortcutBadges && vm.selectedRemoteAgent?.hostID == connection.id
            ? vm.remoteOrderedAgents(hostID: connection.id).firstIndex(where: { $0.id == agent.id }).flatMap { $0 < 9 ? $0 + 1 : nil }
            : nil
        let children = connection.children[agent.id] ?? []
        let folded = SubagentFolding.folded(children: children, selected: selected,
                                            unfolded: vm.unfoldedSubagentGroups.contains(agent.id))
        let model = SidebarAgentRowModel(agent: agent, selected: selected, depth: 1, badge: badge,
                                         children: children, folded: folded,
                                         inspectedRunID: vm.subagentInspector.remoteRuns[ref])
        AgentRow(model: model) { vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id) }
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(remote: ref)) }
            .sidebarDropTarget(vm: vm, allowsBelow: !model.showsChildRows) { payload, edge, validateOnly in
                vm.dropRemoteAgent(payload: payload, on: ref, edge: edge, validateOnly: validateOnly)
            }
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
            // Scroll target for machine jumps and palette picks; the ref type keeps remote rows
            // distinct from local agent ids.
            .id(ref)
        if !children.isEmpty {
            SubagentRows(children: children, depth: 2, folded: folded,
                         inspected: vm.subagentInspector.remoteRuns[ref], toggleFold: { vm.toggleSubagentGroup(agent.id) },
                         open: { vm.openRemoteChild(ref, child: $0) })
        }
    }
}
