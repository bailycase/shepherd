import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol

/// One machine root in the unified sidebar tree. Local wears no marker; a
/// remote host wears `⌁` (accent while connected). The trailing detail is a
/// connection state, a blocked count, or an agent count — plus the machine's
/// ⌃⇧digit keycap while its modifiers are held or on hover.
struct MachineHeaderRow: View {
    /// "⌁" for a remote host, nil for the local machine.
    let marker: String?
    let name: String
    let collapsed: Bool
    let detail: Detail
    var markerColor: Color = NativeTokens.accent
    /// "⌃⇧2"-style hint; shown on hover (discoverability without noise).
    var keycap: String?
    let onToggle: () -> Void
    var onPlus: (() -> Void)?
    var plusHelp: String = ""
    @State private var hovering = false

    private var detailLabel: String {
        switch detail {
        case .blocked(let count): "\(count) waiting"
        case .count(let count): "\(count) agent\(count == 1 ? "" : "s")"
        case .label(let text): text
        }
    }

    enum Detail {
        case count(Int)
        case blocked(Int)
        case label(String)
    }

    var body: some View {
        HStack(spacing: 7) {
            if let marker {
                Text(marker)
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(markerColor)
            }
            Text(name.uppercased())
                .font(NativeFonts.sidebarSection)
                .tracking(0.6)
                .foregroundStyle(collapsed ? NativeTokens.textMuted : NativeTokens.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if hovering, let keycap {
                Text(keycap)
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
            }
            switch detail {
            case .blocked(let count):
                Text("\(count)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.warningText)
            case .count(let count):
                Text("\(count)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
            case .label(let text):
                Text(text)
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(text == "Unreachable" ? NativeTokens.dangerText : NativeTokens.textMuted)
            }
            if hovering, let onPlus {
                SidebarPlusButton(help: plusHelp, action: onPlus)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? NativeTokens.bgHoverStrong : Color.clear, in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
        // The plus stays reachable as its own element; the row label carries the connection state.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(detailLabel), \(collapsed ? "collapsed" : "expanded")")
    }
}

/// A remote host's block in the unified tree: machine root row, then the
/// host's spaces and agents at the same depths the local tree uses.
struct RemoteHostBlock: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection

    private var detail: MachineHeaderRow.Detail {
        switch connection.phase {
        case .connected:
            let blocked = connection.state.agents.count { $0.status == .blocked }
                + connection.children.values.reduce(0) { $0 + $1.count(where: \.needsAttention) }
            return blocked > 0 ? .blocked(blocked) : .count(connection.state.agents.count)
        case .connecting: return .label("Connecting…")
        case .failed: return .label("Unreachable")
        case .disconnected: return .label("Off")
        }
    }

    var body: some View {
        MachineHeaderRow(
            marker: "⌁",
            name: connection.config.name,
            collapsed: vm.collapsedHosts.contains(connection.id),
            detail: detail,
            markerColor: connection.phase == .connected ? NativeTokens.accent : NativeTokens.textMuted,
            keycap: vm.machineKeycap(forHost: connection.id),
            onToggle: { vm.toggleHostCollapsed(connection.id) },
            onPlus: { vm.remoteSpacePickerHostID = connection.id },
            plusHelp: "New Space on \(connection.config.name)"
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
                SpaceHeaderRow(
                    name: space.name,
                    collapsed: vm.isRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id),
                    active: false,
                    blockedCount: agents.count { $0.status == .blocked } + agents.reduce(0) { $0 + (connection.children[$1.id] ?? []).count(where: \.needsAttention) },
                    agentCount: agents.count,
                    depth: 0,
                    onToggle: {
                        vm.toggleRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id)
                    },
                    onNewAgent: {
                        vm.showNewAgentSheetForRemote(hostID: connection.id, spaceID: space.id)
                    }
                )
                if !vm.isRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id) {
                    ForEach(agents) { agent in
                        RemoteChildRows(vm: vm, connection: connection, agent: agent) {
                        AgentRow(
                            agent: agent,
                            selected: vm.selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: agent.id),
                            badge: vm.showAgentShortcutBadges && vm.selectedRemoteAgent?.hostID == connection.id
                                ? vm.remoteOrderedAgents(hostID: connection.id).firstIndex(where: { $0.id == agent.id }).flatMap { $0 < 9 ? $0 + 1 : nil } : nil,
                            depth: 0
                        ) {
                            vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id)
                        }
                        .onDrag {
                            NSItemProvider(object: ShepherdViewModel.dragPayload(remote: RemoteAgentRef(hostID: connection.id, agentID: agent.id)) as NSString)
                        }
                        .sidebarDropTarget { payload in
                            vm.dropRemoteAgent(payload: payload, on: RemoteAgentRef(hostID: connection.id, agentID: agent.id))
                        }
                        .contextMenu {
                            Button("Rename…") { vm.remoteRenameTarget = RemoteAgentRef(hostID: connection.id, agentID: agent.id) }
                            Button("Focus") {
                                vm.selectRemoteAgent(hostID: connection.id, agentID: agent.id)
                            }
                            Divider()
                            if agent.worktreeBranch != nil {
                                Button("Finalize Worktree…") {
                                    vm.remoteWorktreeFinalize = true
                                    vm.remoteWorktreeSheet = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
                                }
                            }
                            Button("Review Uncommitted Changes") {
                                vm.openRemoteReview(RemoteAgentRef(hostID: connection.id, agentID: agent.id), pullRequest: false)
                            }
                            Button("Review PR Changes") {
                                vm.openRemoteReview(RemoteAgentRef(hostID: connection.id, agentID: agent.id), pullRequest: true)
                            }
                            Button(agent.worktreeBranch == nil ? "Delete Agent" : "Delete Worktree Agent…", role: .destructive) {
                                vm.requestRemoteDelete(RemoteAgentRef(hostID: connection.id, agentID: agent.id))
                            }
                        }
                        // Scroll target for machine jumps and palette picks
                        // (see SidebarView); the ref type keeps remote rows
                        // distinct from local agent ids.
                        .id(RemoteAgentRef(hostID: connection.id, agentID: agent.id))
                        .opacity(connection.phase == .connected ? 1 : 0.45)
                        .disabled(connection.phase != .connected)
                        }
                    }
                }
            }
        }
    }
}

private struct RemoteChildRows<Content: View>: View {
    var vm: ShepherdViewModel
    @ObservedObject var connection: RemoteHostStore.Connection
    let agent: Agent
    @ViewBuilder let content: () -> Content
    private var children: [ShepherdProtocol.ChildRun] { connection.children[agent.id] ?? [] }
    @State private var expanded = false

    var body: some View {
        content()
        if !children.isEmpty {
            Button(expanded ? "▾ subagents" : "▸ \(children.count) subagents") { expanded.toggle() }
                .buttonStyle(.plain)
                .font(NativeFonts.sidebarMeta)
                .foregroundStyle(children.contains(where: \.needsAttention) ? NativeTokens.warningText : NativeTokens.textMuted)
                .accessibilityLabel("\(children.count) subagents, \(children.filter(\.needsAttention).count) waiting")
                .padding(.leading, NativeMetrics.sidebarPadding + 8 + 2 * NativeMetrics.sidebarIndent)
            if expanded {
                ForEach(children) { child in
                    ChildRunRow(child: child, depth: 0) {
                        vm.openRemoteChild(RemoteAgentRef(hostID: connection.id, agentID: agent.id), child: child)
                    }
                }
            }
        }

    }
}
