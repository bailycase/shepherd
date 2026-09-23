import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import UniformTypeIdentifiers

/// The sidebar (Navigation board, `NWSidebar`): window controls and compose, "Jump to…", then
/// THIS MAC and each remote host as sections, spaces as disclosure rows with their agents
/// nested beneath, and Automations as the footer. Subagents have no rows; they live in their
/// agent's thread. Rows take plain values so an unchanged row never re-renders.
///
/// Rows arriving, leaving, reordering, and disclosing animate (`.list`) whatever changed them: a
/// broadcast, a drop, a click, a reveal. Selecting a row changes no row, so it lands at once.
struct SidebarView: View {
    var vm: ShepherdViewModel

    private var keys: KeybindingsStore { vm.keybindings }

    var body: some View {
        NWSidebar(compose: { vm.quickCreateAgent() }, composeLabel: "New agent", composeShortcut: keys.display(.newAgent),
                  jump: { vm.showCommandPalette = true }, jumpShortcut: keys.display(.commandPalette)) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                        LocalMachineSection(vm: vm)
                        ForEach(vm.remoteHosts.connections) { connection in
                            RemoteHostBlock(vm: vm, connection: connection)
                        }
                    }
                    .padding(.horizontal, AppLayout.sidebarPadding)
                    .padding(.bottom, NW.Space.m)
                }
                .scrollIndicators(.hidden)
                // Keyboard navigation (⌘1–9, ⌘↑/↓, ⌃⇧digits) can land on a row scrolled out of
                // view; the same selection may have just opened a disclosure, so scroll on the
                // next runloop turn once the row exists. The trigger is a counter so re-selecting
                // the same row still scrolls back to it.
                .onChange(of: vm.sidebarRevealRequest) {
                    guard let target = vm.sidebarRevealTarget else { return }
                    DispatchQueue.main.async {
                        withNWAnimation(.scroll) { proxy.scrollTo(target) }
                    }
                }
            }
        } footer: {
            if !vm.state.automations.isEmpty {
                AutomationsFooter(vm: vm)
                    .nwTransition(.list, edge: .bottom)
            }
        }
        .nwAnimation(.list, value: rowLayout)
    }

    /// Everything that adds, removes, reorders, or discloses rows, local and remote, and the
    /// Automations footer.
    private var rowLayout: [AnyHashable] {
        var key: [AnyHashable] = [vm.localMachineCollapsed]
        for group in vm.spaceTree {
            key += [group.space.id, vm.collapsedSpaces.contains(group.space.id), group.agents.map(\.id)]
        }
        for connection in vm.remoteHosts.connections {
            key += [connection.id, connection.phase == .connected, vm.collapsedHosts.contains(connection.id)]
            for space in connection.state.spaces where !space.hidden {
                key += [space.id, vm.isRemoteSpaceCollapsed(hostID: connection.id, spaceID: space.id),
                        ShepherdViewModel.sidebarAgents(of: space.id, in: connection.state.agents).map(\.id)]
            }
        }
        key += [vm.state.automations.map(\.id), vm.automationsExpanded]
        return key
    }
}

// MARK: This Mac

private struct LocalMachineSection: View {
    var vm: ShepherdViewModel

    var body: some View {
        NWSidebarSection(
            "This Mac",
            detail: .count(vm.localAgentCount),
            collapsed: vm.localMachineCollapsed,
            hoverHint: vm.remoteHosts.connections.isEmpty ? nil : vm.machineKeycap(forHost: nil),
            toggle: { vm.localMachineCollapsed.toggle() }
        ) {
            SidebarPlus(help: "New Space…") { vm.addSpaceFromPanel() }
        }
        if !vm.localMachineCollapsed {
            let tree = vm.spaceTree
            // A space whose next row is deeper has nested projects drawn beneath it.
            let parents = Set(tree.indices.dropLast().filter { tree[$0 + 1].depth > tree[$0].depth }.map { tree[$0].space.id })
            ForEach(tree, id: \.space.id) { group in
                SpaceSection(vm: vm, space: group.space, agents: group.agents, depth: group.depth,
                             hasChildSpaces: parents.contains(group.space.id))
            }
        }
    }
}

/// The hover `+` in section and space headers. A real button with a label.
struct SidebarPlus: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: AppLayout.sidebarPlusGlyph, weight: .medium))
        }
        .buttonStyle(.nwIcon(size: AppLayout.sidebarPlusSize))
        .nwHelp(help)
        .accessibilityLabel(help)
    }
}

/// One space: a disclosure row with its agents nested beneath.
struct SpaceSection: View {
    var vm: ShepherdViewModel
    let space: Space
    let agents: [Agent]
    /// 0 for a root space; deeper spaces are projects nested by path containment.
    var depth = 0
    var hasChildSpaces = false

    var body: some View {
        let collapsed = vm.collapsedSpaces.contains(space.id)
        SpaceRow(name: space.name, collapsed: collapsed, count: agents.count,
                 blocked: SidebarAttention.count(agents, children: vm.childRuns.rows),
                 worktrees: agents.count { $0.worktreeBranch != nil },
                 depth: depth,
                 onToggle: { vm.toggleSpaceCollapsed(space.id) },
                 onNewAgent: { vm.quickCreateAgent(in: space.id) })
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(space: space.id)) }
            .sidebarDropTarget(vm: vm, allowsBelow: collapsed || (agents.isEmpty && !hasChildSpaces)) { payload, edge, validateOnly in
                vm.dropSpace(payload: payload, on: space.id, edge: edge, validateOnly: validateOnly)
            }
            .contextMenu {
                Button("New Agent") { vm.quickCreateAgent(in: space.id) }
                Button("Rename…") { vm.spaceRenameTarget = space.id }
                if vm.spaceIsRepo(space) {
                    Button("New Worktree…") { vm.worktreeSheetTarget = space.id }
                    Button("Import Existing Worktree…") { vm.importExistingWorktreeFromPanel(in: space.id) }
                }
                Divider()
                Button("Remove Space…", role: .destructive) { vm.spaceDeleteTarget = space.id }
            }
            // The reveal target for a collapsed space; exactly one row carries the id.
            .id(space.id)
            .nwTransition(.list)
        if !collapsed {
            ForEach(agents) { agent in
                LocalAgentRow(vm: vm, model: vm.sidebarRowModel(for: agent, depth: depth + 1))
                    .nwTransition(.disclosure)
            }
        }
    }
}

struct SpaceRow: View, Equatable {
    let name: String
    let collapsed: Bool
    let count: Int
    /// Questions waiting on you (`SidebarAttention`), shown in place of the agent count.
    var blocked = 0
    var worktrees = 0
    var depth = 0
    var dimmed = false
    let onToggle: () -> Void
    var onNewAgent: (() -> Void)?

    static func == (a: SpaceRow, b: SpaceRow) -> Bool {
        a.name == b.name && a.collapsed == b.collapsed && a.count == b.count && a.blocked == b.blocked
            && a.worktrees == b.worktrees && a.depth == b.depth && a.dimmed == b.dimmed
            && (a.onNewAgent == nil) == (b.onNewAgent == nil)
    }

    var body: some View {
        NWSidebarDisclosureRow(name, expanded: !collapsed, depth: depth) { hovering in trailing(hovering: hovering) }
        .opacity(dimmed ? 0.55 : 1)
        .sidebarTapRow(action: onToggle)
        .accessibilityLabel(Self.accessibilityText(name: name, count: count, blocked: blocked, collapsed: collapsed))
        .accessibilityActions {
            if let onNewAgent { Button("New Agent in \(name)", action: onNewAgent) }
        }
    }

    /// Worktree count, then one slot the agent count (or waiting count) and the hover `+` share.
    @ViewBuilder func trailing(hovering: Bool) -> some View {
        if worktrees > 0 {
            Text("⎇\(worktrees)").font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                .help("\(worktrees) worktree agent\(worktrees == 1 ? "" : "s")")
                .nwContentTransition(.numeric())
                .nwAnimation(.content, value: worktrees)
        }
        // The count and the hover `+` share one slot and crossfade, so hovering resizes nothing.
        let showsPlus = hovering && onNewAgent != nil
        ZStack(alignment: .trailing) {
            ZStack(alignment: .trailing) {
                if blocked > 0 {
                    Text("\(blocked)").font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.lanternText)
                } else if count > 0 {
                    Text("\(count)").font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                }
            }
            // Counts roll, and waiting ⇄ agents cross-fade, as broadcasts change them.
            .nwContentTransition(.numeric())
            .nwAnimation(.content, value: [blocked, count])
            .opacity(showsPlus ? 0 : 1)
            if let onNewAgent {
                SidebarPlus(help: "New Agent in \(name)", action: onNewAgent)
                    .opacity(showsPlus ? 1 : 0)
                    .allowsHitTesting(showsPlus)
                    .accessibilityHidden(true)
            }
        }
    }

    static func accessibilityText(name: String, count: Int, blocked: Int, collapsed: Bool) -> String {
        var parts = [name, "\(count) agent\(count == 1 ? "" : "s")"]
        if blocked > 0 { parts.append("\(blocked) need\(blocked == 1 ? "s" : "") you") }
        parts.append(collapsed ? "collapsed" : "expanded")
        return parts.joined(separator: ", ")
    }
}

// MARK: Agent rows

/// Everything an agent row draws, as plain values. Subagents have no rows: they show in their
/// agent's thread, and one waiting on you makes its agent's row ask.
struct SidebarAgentRowModel: Equatable {
    let agent: Agent
    let selected: Bool
    let depth: Int
    var badge: Int?
    var statusSince: Date?
    /// One of the agent's subagents is waiting on your answer.
    var subagentNeedsYou: Bool
    var dimmed: Bool

    init(agent: Agent, selected: Bool, depth: Int, badge: Int? = nil, statusSince: Date? = nil,
         children: [ChildRun] = [], dimmed: Bool = false) {
        self.agent = agent
        self.selected = selected
        self.depth = depth
        self.badge = badge
        self.statusSince = statusSince
        self.subagentNeedsYou = children.contains(where: \.needsAttention)
        self.dimmed = dimmed
    }

    /// A question waits on the user: the agent's own, or one of its subagents'.
    var needsYou: Bool { agent.status == .blocked || subagentNeedsYou }

    /// The dot: needs you wins over the agent's own status.
    var state: AgentState { needsYou ? .attention : AgentState(agent.status) }

    /// The agent row's trailing slot, in priority order: the ⌘-digit hint while ⌘ is held,
    /// needs you, then elapsed time while working.
    var accessory: NWSidebarRow.Accessory {
        if let badge { return .shortcut("⌘\(badge)") }
        if needsYou { return .ask }
        if agent.status == .working, let statusSince { return .elapsed(since: statusSince, tone: .running) }
        return .none
    }

    /// "Fix the login, worktree, running".
    var accessibilityLabel: String {
        "\(agent.name), \(agent.worktreeBranch != nil ? "worktree, " : "")\(needsYou ? "needs you" : AgentRow.statusWord(agent.status))"
    }
}

/// What the sidebar counts as needing you: each blocked agent, plus each subagent asking a
/// question, so a space or host with a waiting subagent reads as waiting.
enum SidebarAttention {
    static func count(_ agents: [Agent], children: [AgentID: [ChildRun]]) -> Int {
        agents.reduce(0) { total, agent in
            total + (agent.status == .blocked ? 1 : 0) + (children[agent.id] ?? []).count(where: \.needsAttention)
        }
    }
}

extension ShepherdViewModel {
    /// The row values for a local agent.
    func sidebarRowModel(for agent: Agent, depth: Int) -> SidebarAgentRowModel {
        SidebarAgentRowModel(
            agent: agent, selected: selectedAgentID == agent.id && selectedRemoteAgent == nil, depth: depth,
            badge: shortcutBadge(for: agent.id), statusSince: statusSince[agent.id], children: children(of: agent.id)
        )
    }

    /// The row values for an agent on a remote host, with the children the host reports.
    func remoteSidebarRowModel(for agent: Agent, on connection: RemoteHostStore.Connection) -> SidebarAgentRowModel {
        let badge = showAgentShortcutBadges && selectedRemoteAgent?.hostID == connection.id
            ? remoteOrderedAgents(hostID: connection.id).firstIndex(where: { $0.id == agent.id }).flatMap { $0 < 9 ? $0 + 1 : nil }
            : nil
        return SidebarAgentRowModel(
            agent: agent, selected: selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: agent.id),
            depth: 1, badge: badge, children: connection.children[agent.id] ?? []
        )
    }
}

/// A local agent's row, with its drag, drop, and context menu.
struct LocalAgentRow: View, Equatable {
    var vm: ShepherdViewModel
    let model: SidebarAgentRowModel

    static func == (a: LocalAgentRow, b: LocalAgentRow) -> Bool { a.vm === b.vm && a.model == b.model }

    var body: some View {
        let agent = model.agent
        AgentRow(model: model) { vm.selectAgent(agent.id) }
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(agent: agent.id)) }
            .sidebarDropTarget(vm: vm, allowsBelow: true) { payload, edge, validateOnly in
                vm.dropAgent(payload: payload, on: agent.id, edge: edge, validateOnly: validateOnly)
            }
            .contextMenu {
                Button("Rename…") { vm.agentRenameTarget = agent.id }
                Button("Review Changes") { vm.selectAgent(agent.id); vm.openUserReview() }
                Divider()
                if agent.worktreeBranch != nil {
                    Button("Finalize Worktree…") { vm.beginFinalizeWorktree(agent.id) }
                    Divider()
                    Button("Delete Worktree Agent…", role: .destructive) { vm.worktreeDeleteTarget = agent.id }
                } else {
                    Button("Delete Agent", role: .destructive) { vm.deleteAgent(agent.id) }
                }
            }
            // Scroll target for keyboard selection.
            .id(agent.id)
    }
}

struct AgentRow: View {
    let model: SidebarAgentRowModel
    let action: () -> Void

    var body: some View {
        NWSidebarRow(model.agent.name, state: model.state, selected: model.selected,
                     depth: model.depth, worktree: model.agent.worktreeBranch != nil, dimmed: model.dimmed,
                     accessory: model.accessory)
            .help(model.agent.worktreeBranch.map { "\(model.agent.name) · worktree \($0)" } ?? model.agent.name)
            .sidebarTapRow(action: action)
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityAddTraits(model.selected ? .isSelected : [])
    }

    static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle: "idle"
        case .done: "done"
        }
    }
}

enum SidebarTime {
    /// "12s", "4m", "2h", "3d" — the sidebar's coarse elapsed time.
    static func elapsed(since start: Date, now: Date) -> String {
        NWDuration.text(now.timeIntervalSince(start))
    }
}

// MARK: Automations

/// AUTOMATIONS: saved watch prompts run by ordinary agents, as the sidebar's footer. Hidden
/// while empty; the footer discloses the rows.
private struct AutomationsFooter: View {
    var vm: ShepherdViewModel

    var body: some View {
        let automations = vm.state.automations
        let blocked = automations.contains { vm.automationAgent($0)?.status == .blocked }
        VStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
            NWSidebarFooter("Automations", systemImage: "bolt", count: automations.count,
                            tone: blocked ? .attention : .neutral, expanded: vm.automationsExpanded) {
                vm.automationsExpanded.toggle()
            }
            if vm.automationsExpanded {
                VStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                    ForEach(automations) { automation in
                        let agent = vm.automationAgent(automation)
                        AutomationRow(automation: automation, agent: agent,
                                      selected: agent != nil && vm.selectedAgentID == agent?.id) {
                            if let agent { vm.selectAgent(agent.id) }
                        }
                        .contextMenu {
                            if automation.agentID == nil {
                                Button("Run Now") { Task { @MainActor in try? await vm.startAutomation(automation.id) } }
                            } else {
                                Button("Stop") { vm.stopAutomation(automation.id) }
                            }
                            Divider()
                            Button("Delete Automation", role: .destructive) { vm.deleteAutomation(automation.id) }
                        }
                        .nwTransition(.list)
                    }
                }
                .padding(.horizontal, AppLayout.sidebarPadding)
                .padding(.bottom, NW.Space.m)
                .nwTransition(.disclosure)
            }
        }
    }
}

struct AutomationRow: View {
    let automation: Automation
    /// The agent currently running this automation, nil when stopped.
    let agent: Agent?
    let selected: Bool
    let action: () -> Void

    private var stateWord: String {
        guard let agent else { return "stopped" }
        return switch agent.status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle, .done: "done"
        }
    }

    private var state: AgentState {
        guard let agent else { return .idle }
        return agent.status == .idle ? .done : AgentState(agent.status)
    }

    var body: some View {
        NWSidebarRow(automation.name, state: state, selected: selected,
                     accessory: agent?.status == .blocked ? .ask : .text(stateWord))
            .sidebarTapRow(enabled: agent != nil, action: action)
            .accessibilityLabel("\(automation.name), automation, \(stateWord)")
    }
}

// MARK: Interaction

extension View {
    /// Row interaction: rows are tap views with button traits (not `Button`s) so they can also
    /// be dragged to reorder.
    func sidebarTapRow(enabled: Bool = true, action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(enabled ? .isButton : [])
            .accessibilityAction { if enabled { action() } }
    }
}

// MARK: Reordering

/// Drop target for sidebar reordering: a 2pt running line at the row's top or bottom edge
/// (by pointer half) while a valid drag hovers. Only drags that started in this sidebar
/// qualify; their payload type is private to the process.
private struct SidebarDropTarget: ViewModifier {
    var vm: ShepherdViewModel
    let allowsBelow: Bool
    /// `(payload, edge, validateOnly)`: whether the drop is (or would be) accepted.
    let perform: (String, SidebarDropEdge, Bool) -> Bool
    @State private var edge: SidebarDropEdge?
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .overlay(alignment: edge == .below ? .bottom : .top) {
                if edge != nil { NWDropIndicator().nwTransition(.hover) }
            }
            .nwAnimation(.hover, value: edge)
            .onDrop(of: [.shepherdSidebarItem], delegate: SidebarDropDelegate(
                vm: vm, height: height, allowsBelow: allowsBelow, edge: $edge, perform: perform))
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let vm: ShepherdViewModel
    let height: CGFloat
    let allowsBelow: Bool
    @Binding var edge: SidebarDropEdge?
    let perform: (String, SidebarDropEdge, Bool) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.shepherdSidebarItem]) && vm.sidebarDragPayload != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposed = SidebarDropEdge.at(y: info.location.y, height: height, allowsBelow: allowsBelow)
        guard let payload = vm.sidebarDragPayload, perform(payload, proposed, true) else {
            edge = nil
            return DropProposal(operation: .forbidden)
        }
        edge = proposed
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            edge = nil
            vm.sidebarDragPayload = nil
        }
        guard let payload = vm.sidebarDragPayload, let edge else { return false }
        return perform(payload, edge, false)
    }
}

extension View {
    /// `perform(payload, edge, validateOnly)` answers whether the drop is accepted, and
    /// applies it unless `validateOnly`.
    func sidebarDropTarget(vm: ShepherdViewModel, allowsBelow: Bool,
                           perform: @escaping (String, SidebarDropEdge, Bool) -> Bool) -> some View {
        modifier(SidebarDropTarget(vm: vm, allowsBelow: allowsBelow, perform: perform))
    }
}
