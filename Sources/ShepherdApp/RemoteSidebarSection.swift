import SwiftUI
import ShepherdDesign
import AppKit
import ShepherdCore
import ShepherdProtocol

/// A remote host's section in the sidebar: a section header with its connection state, then
/// its spaces and agents with the same rows the local tree uses. A disconnected host's rows dim
/// and cannot open.
struct RemoteHostBlock: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection
    let compact: Bool

    private var detail: SidebarSection.Detail {
        switch connection.phase {
        case .connected:
            let blocked = connection.state.agents.count { $0.status == .blocked }
                + connection.children.values.reduce(0) { $0 + $1.count(where: \.needsAttention) }
            return blocked > 0 ? .state("\(blocked) need you", danger: false) : .count(connection.state.agents.count)
        case .connecting: return .state("Connecting…", danger: false)
        case .failed: return .state("Unreachable", danger: true)
        case .disconnected: return .state("Off", danger: false)
        }
    }

    var body: some View {
        let connected = connection.phase == .connected
        SidebarSection(
            title: connection.config.name,
            detail: detail,
            collapsed: vm.collapsedHosts.contains(connection.id),
            keycap: vm.machineKeycap(forHost: connection.id),
            compact: compact,
            onToggle: { vm.toggleHostCollapsed(connection.id) },
            plus: connected ? SidebarPlus(help: "New Space on \(connection.config.name)") { vm.remoteSpacePickerHostID = connection.id } : nil
        )
        .contextMenu {
            ForEach(Array(vm.remoteWorktreeOperationIDs.keys.filter { $0.hostID == connection.id }), id: \.self) { target in
                Button("Check Worktree Operation…") { vm.remoteWorktreeSheet = target }
            }
            Button("New Space…") { vm.remoteSpacePickerHostID = connection.id }
            Button("Reconnect") { vm.remoteHosts.reconnect(id: connection.id) }
        }

        if !vm.collapsedHosts.contains(connection.id) {
            ForEach(connection.state.spaces.filter { !$0.hidden }) { space in
                let agents = ShepherdViewModel.sidebarAgents(of: space.id, in: connection.state.agents)
                let spaceCollapsed = vm.isRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id)
                SpaceRow(
                    name: space.name,
                    collapsed: spaceCollapsed,
                    count: agents.count,
                    blocked: agents.count { $0.status == .blocked },
                    compact: compact,
                    onToggle: { vm.toggleRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id) },
                    onNewAgent: connected ? { vm.showNewAgentSheetForRemote(hostID: connection.id, spaceID: space.id) } : nil
                )
                .opacity(connected ? 1 : 0.55)
                if !spaceCollapsed {
                    ForEach(agents) { agent in
                        remoteAgentRow(agent, connected: connected)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteAgentRow(_ agent: Agent, connected: Bool) -> some View {
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
        let selected = vm.selectedRemoteAgent == ref
        let badge = vm.showAgentShortcutBadges && vm.selectedRemoteAgent?.hostID == connection.id
            ? vm.remoteOrderedAgents(hostID: connection.id).firstIndex(where: { $0.id == agent.id }).flatMap { $0 < 9 ? $0 + 1 : nil }
            : nil
        AgentRow(agent: agent, selected: selected, compact: compact, badge: badge, dimmed: !connected) {
            if connected { vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id) }
        }
        .onDrag { NSItemProvider(object: ShepherdViewModel.dragPayload(remote: ref) as NSString) }
        .sidebarDropTarget { payload in vm.dropRemoteAgent(payload: payload, on: ref) }
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
        .disabled(!connected)
        // Scroll target for machine jumps and palette picks; the ref type keeps remote rows
        // distinct from local agent ids.
        .id(ref)
        let children = connection.children[agent.id] ?? []
        if !children.isEmpty {
            SubagentRows(children: children, depth: 0, compact: compact,
                         folded: SubagentFolding.folded(children: children, selected: selected, unfolded: false),
                         inspected: vm.subagentInspector.remoteRuns[ref], toggleFold: {},
                         open: { vm.openRemoteChild(ref, child: $0) })
        }
    }
}
