import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UniformTypeIdentifiers

/// The sidebar (Navigation board, `NWSidebar`): window controls and compose, "Jump to…", then
/// THIS MAC and each remote host as sections, spaces as disclosure rows with their agents
/// nested beneath, subagents under their agent, and Automations as the footer. Rows take plain
/// values so an unchanged row never re-renders.
struct SidebarView: View {
    var vm: ShepherdViewModel

    private var keys: KeybindingsStore { vm.keybindings }

    var body: some View {
        NWSidebar(compose: { vm.quickCreateAgent() }, composeLabel: "New agent", composeShortcut: keys.display(.newAgent),
                  jump: { vm.showCommandPalette = true }, jumpShortcut: keys.display(.commandPalette)) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 1) {
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
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: NW.Motion.hover.duration)) {
                            proxy.scrollTo(target)
                        }
                    }
                }
            }
        } footer: {
            if !vm.state.automations.isEmpty {
                AutomationsFooter(vm: vm)
            }
        }
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
            Image(systemName: "plus").font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.nwIcon(size: 18))
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
                 blocked: agents.count { $0.status == .blocked }, worktrees: agents.count { $0.worktreeBranch != nil },
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
        if !collapsed {
            ForEach(agents) { agent in
                LocalAgentRows(vm: vm, model: vm.sidebarRowModel(for: agent, depth: depth + 1))
            }
        }
    }
}

struct SpaceRow: View, Equatable {
    let name: String
    let collapsed: Bool
    let count: Int
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
        NWSidebarDisclosureRow(name, expanded: !collapsed, depth: depth) { hovering in
            if worktrees > 0 {
                Text("⎇\(worktrees)").font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                    .help("\(worktrees) worktree agent\(worktrees == 1 ? "" : "s")")
            }
            if hovering, let onNewAgent {
                SidebarPlus(help: "New Agent in \(name)", action: onNewAgent)
            } else if blocked > 0 {
                Text("\(blocked)").font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.lanternText)
            } else if count > 0 {
                Text("\(count)").font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
            }
        }
        .opacity(dimmed ? 0.55 : 1)
        .sidebarTapRow(action: onToggle)
        .accessibilityLabel(Self.accessibilityText(name: name, count: count, blocked: blocked, collapsed: collapsed))
        .accessibilityActions {
            if let onNewAgent { Button("New Agent in \(name)", action: onNewAgent) }
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

/// Everything an agent row and its subagent rows draw, as plain values.
struct SidebarAgentRowModel: Equatable {
    let agent: Agent
    let selected: Bool
    let depth: Int
    var badge: Int?
    var statusSince: Date?
    var children: [ChildRun] = []
    var folded = false
    var inspectedRunID: String?
    var dimmed = false

    /// The agent row's trailing slot, in priority order: the ⌘-digit hint while ⌘ is held,
    /// needs you, a folded subagent count, then elapsed time while working.
    var accessory: NWSidebarRow.Accessory {
        if let badge { return .shortcut("⌘\(badge)") }
        if agent.status == .blocked { return .ask }
        if folded, !children.isEmpty { return .text("\(children.count) sub") }
        if agent.status == .working, let statusSince { return .elapsed(since: statusSince, tone: .running) }
        return .none
    }

    /// Subagent rows show while any run is live, and for a finished group while unfolded.
    var showsChildRows: Bool { !children.isEmpty && !folded }

    /// "Fix the login, worktree, running".
    var accessibilityLabel: String {
        "\(agent.name), \(agent.worktreeBranch != nil ? "worktree, " : "")\(AgentRow.statusWord(agent.status))"
    }
}

extension ShepherdViewModel {
    /// The row values for a local agent.
    func sidebarRowModel(for agent: Agent, depth: Int) -> SidebarAgentRowModel {
        let selected = selectedAgentID == agent.id && selectedRemoteAgent == nil
        let children = children(of: agent.id)
        return SidebarAgentRowModel(
            agent: agent, selected: selected, depth: depth,
            badge: shortcutBadge(for: agent.id), statusSince: statusSince[agent.id], children: children,
            folded: SubagentFolding.folded(children: children, selected: selected, unfolded: unfoldedSubagentGroups.contains(agent.id)),
            inspectedRunID: subagentInspector.runByAgent[agent.id]
        )
    }

    /// Opens or folds a finished subagent group under an agent row (local or remote).
    func toggleSubagentGroup(_ agentID: AgentID) {
        if unfoldedSubagentGroups.contains(agentID) { unfoldedSubagentGroups.remove(agentID) }
        else { unfoldedSubagentGroups.insert(agentID) }
    }
}

/// An agent row plus, when it has subagents, their nested rows (or the folded group header).
struct LocalAgentRows: View, Equatable {
    var vm: ShepherdViewModel
    let model: SidebarAgentRowModel

    static func == (a: LocalAgentRows, b: LocalAgentRows) -> Bool { a.vm === b.vm && a.model == b.model }

    var body: some View {
        let agent = model.agent
        AgentRow(model: model) { vm.selectAgent(agent.id) }
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(agent: agent.id)) }
            .sidebarDropTarget(vm: vm, allowsBelow: !model.showsChildRows) { payload, edge, validateOnly in
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
            // Scroll target for keyboard selection: only the agent's own row carries its id.
            .id(agent.id)
        if !model.children.isEmpty {
            SubagentRows(children: model.children, depth: model.depth + 1, folded: model.folded,
                         inspected: model.inspectedRunID,
                         toggleFold: { vm.toggleSubagentGroup(agent.id) },
                         open: { vm.openChildInspector(agentID: agent.id, child: $0) })
        }
    }
}

/// Subagent groups: always expanded while any run is live; once every run has finished the
/// group gets a disclosure header, expanded for the selected thread and folded for others
/// (whose agent row then shows "n sub").
enum SubagentFolding {
    static func folded(children: [ChildRun], selected: Bool, unfolded: Bool) -> Bool {
        guard !children.isEmpty, children.allSatisfy(\.isTerminal) else { return false }
        return !(selected || unfolded)
    }
}

struct AgentRow: View {
    let model: SidebarAgentRowModel
    let action: () -> Void

    var body: some View {
        NWSidebarRow(model.agent.name, state: AgentState(model.agent.status), selected: model.selected,
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

/// Subagent rows under their agent: the run's state dot, name, and elapsed / ASK / duration
/// trailing. A finished group folds behind a disclosure header.
struct SubagentRows: View, Equatable {
    let children: [ChildRun]
    let depth: Int
    let folded: Bool
    let inspected: String?
    let toggleFold: () -> Void
    let open: (ChildRun) -> Void

    static func == (a: SubagentRows, b: SubagentRows) -> Bool {
        a.children == b.children && a.depth == b.depth && a.folded == b.folded && a.inspected == b.inspected
    }

    var body: some View {
        if children.allSatisfy(\.isTerminal) {
            SubagentGroupRow(label: SubagentRows.groupLabel(children), folded: folded, depth: depth)
                .sidebarTapRow(action: toggleFold)
                .accessibilityLabel("\(children.count) subagents, \(folded ? "collapsed" : "expanded")")
        }
        if !folded {
            ForEach(children, id: \.id) { run in
                SubagentRow(run: run, selected: inspected == run.runID, depth: depth) { open(run) }
            }
        }
    }

    static func groupLabel(_ children: [ChildRun]) -> String {
        let count = "\(children.count) subagent\(children.count == 1 ? "" : "s")"
        guard let ended = children.compactMap(\.endedAt).max() else { return count }
        return "\(count) · done \(nativeClockText(ended, meridiem: false))"
    }
}

/// "3 subagents · done 14:02" with a chevron: folds a finished group.
private struct SubagentGroupRow: View {
    let label: String
    let folded: Bool
    let depth: Int
    @Environment(\.nwDensity) private var density

    var body: some View {
        HStack(spacing: NW.Space.s) {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(folded ? 0 : 90))
                .foregroundStyle(Color.nw.textTertiary)
                .frame(width: 6)
            Text(label).font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, NWSidebarMetrics.rowPadding + CGFloat(depth) * NWSidebarMetrics.indentStep)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
    }
}

struct SubagentRow: View {
    let run: ChildRun
    let selected: Bool
    let depth: Int
    let action: () -> Void

    var body: some View {
        let state = nativeSubagentState(run)
        NWSidebarRow(run.role ?? run.label, state: AgentState(state), selected: selected, depth: depth,
                     accessory: SubagentStyle.accessory(run, state: state))
            .sidebarTapRow(action: action)
            .accessibilityLabel("\(run.role ?? run.label), subagent, \(SubagentStyle.word(state))")
    }
}

/// Color and words for a subagent's state, shared by sidebar rows, cards, and the palette.
enum SubagentStyle {
    @MainActor static func color(_ state: NativeSubagentState) -> Color { AgentState(state).color }

    static func word(_ state: NativeSubagentState) -> String {
        switch state {
        case .running: "running"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        }
    }

    /// Needs you asks; a live run counts up from its start; a finished one shows how long it
    /// took (in `failed` when it failed).
    static func accessory(_ run: ChildRun, state: NativeSubagentState, now: Date = Date()) -> NWSidebarRow.Accessory {
        switch state {
        case .needsYou:
            return .ask
        case .running:
            guard let started = run.startedAt else { return .none }
            return .elapsed(since: Date(timeIntervalSince1970: started / 1000), tone: .running)
        case .done, .failed:
            let duration = nativeSubagentElapsed(run, now: now).map(nativeSubagentShortDuration)
            let tone: AgentState? = state == .failed ? .failed : nil
            return duration.map { .text($0, tone: tone) } ?? .text(word(state), tone: tone)
        }
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
        VStack(alignment: .leading, spacing: 1) {
            NWSidebarFooter("Automations", systemImage: "bolt", count: automations.count,
                            tone: blocked ? .attention : .neutral, expanded: vm.automationsExpanded) {
                vm.automationsExpanded.toggle()
            }
            if vm.automationsExpanded {
                VStack(alignment: .leading, spacing: 1) {
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
                    }
                }
                .padding(.horizontal, AppLayout.sidebarPadding)
                .padding(.bottom, NW.Space.m)
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
                if edge != nil { NWDropIndicator() }
            }
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
