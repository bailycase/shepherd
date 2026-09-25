import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import UniformTypeIdentifiers

/// The sidebar (Navigation board, `NWSidebar`): room for the window controls, then THIS MAC and
/// each remote host as sections, spaces as disclosure rows with their agents nested beneath,
/// and Automations as the footer. Subagents have no rows; they live in their agent's thread.
///
/// The tree is flattened into one lazy list (`SidebarTree`): a fleet runs to hundreds of rows,
/// and only the rows on screen are built. Each row is a plain value compared before it redraws,
/// so a status report or a selection redraws the rows it changed and nothing else.
///
/// Rows arriving, leaving, reordering, and disclosing animate (`.list`) whatever changed them: a
/// broadcast, a drop, a click, a reveal. Selecting a row changes no row, so it lands at once.
struct SidebarView: View {
    var vm: ShepherdViewModel
    /// The view model's, built once: the root view builds this struct again on every update it
    /// takes, and allocating a zone each time cost more than the struct itself.
    let dropZone: SidebarDropZone

    /// `dropZone` lets a test drive a reorder drag as the drop delegate does.
    init(vm: ShepherdViewModel, dropZone: SidebarDropZone? = nil) {
        self.vm = vm
        self.dropZone = dropZone ?? vm.sidebarDropZone
    }

    var body: some View {
        let _ = NWRenderProbe.tick("shell.sidebar")
        let tree = vm.sidebarTree()
        NWSidebar {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: AppLayout.sidebarRowSpacing) {
                        ForEach(tree.items) { item in
                            SidebarItemRow(vm: vm, zone: dropZone, item: item)
                                .equatable()
                                .nwTransition(item.motion)
                        }
                    }
                    .sidebarDropZone(dropZone, vm: vm)
                    .padding(.horizontal, AppLayout.sidebarPadding)
                    .padding(.bottom, NW.Space.m)
                }
                .scrollIndicators(.hidden)
                // Keyboard navigation (⌘1–9, ⌘↑/↓, ⌃⇧digits) can land on a row scrolled out of
                // view; the same selection may have just opened a disclosure, so scroll on the
                // next runloop turn once the row exists. The trigger is a counter so re-selecting
                // the same row still scrolls back to it. Rows are identified by the reveal
                // target's own ids, so the lazy list finds a row it hasn't built yet.
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
        .nwAnimation(.list, value: tree.layout)
    }
}

// MARK: Rows

/// The sidebar's rows in display order, and what its motion watches.
struct SidebarTree {
    var items: [SidebarItem] = []
    /// Everything that adds, removes, reorders, or discloses rows, local and remote, and the
    /// Automations footer.
    var layout: [AnyHashable] = []

    mutating func append(_ item: SidebarItem) {
        items.append(item)
        layout.append(item.id)
        if let collapsed = item.collapsed { layout.append(collapsed) }
    }
}

/// One row of the sidebar tree, as plain values.
enum SidebarItem: Identifiable, Equatable {
    /// A machine's section header: This Mac, or a remote host.
    case machine(SidebarMachine)
    case space(SidebarSpace)
    case agent(SidebarAgentRowModel)
    case remoteAgent(hostID: UUID, model: SidebarAgentRowModel)
    /// A host that isn't connected: one status row stands in for its spaces.
    case notice(hostID: UUID, phase: RemoteHostStore.Phase.Kind)
    /// A connected host's Automations disclosure, under its spaces.
    case remoteAutomations(SidebarRemoteAutomations)
    case remoteAutomation(SidebarRemoteAutomation)

    /// Local agents and spaces and remote agents use the ids `sidebarRevealTarget` names, so
    /// the list scrolls to them; the rest are keyed so they never collide with those.
    var id: AnyHashable {
        switch self {
        case .machine(let machine): AnyHashable(SidebarRowKey.machine(machine.hostID))
        case .space(let space):
            space.hostID.map { AnyHashable(SidebarRowKey.remoteSpace($0, space.id)) } ?? AnyHashable(space.id)
        case .agent(let model): AnyHashable(model.agent.id)
        case .remoteAgent(let hostID, let model): AnyHashable(RemoteAgentRef(hostID: hostID, agentID: model.agent.id))
        case .notice(let hostID, _): AnyHashable(SidebarRowKey.notice(hostID))
        case .remoteAutomations(let header): AnyHashable(SidebarRowKey.remoteAutomations(header.hostID))
        case .remoteAutomation(let row): AnyHashable(row.key)
        }
    }

    /// A disclosure's state, for the motion key: a chevron turns even when nothing is nested.
    var collapsed: Bool? {
        switch self {
        case .machine(let machine): machine.collapsed
        case .space(let space): space.collapsed
        case .remoteAutomations(let header): header.collapsed
        default: nil
        }
    }

    /// Agents disclose under their space; everything else arrives like a row.
    var motion: NW.Motion {
        switch self {
        case .agent, .remoteAgent, .remoteAutomation: .disclosure
        default: .list
        }
    }
}

private enum SidebarRowKey: Hashable {
    case machine(UUID?)
    case remoteSpace(UUID, SpaceID)
    case notice(UUID)
    case remoteAutomations(UUID)
}

/// A machine's section header.
struct SidebarMachine: Equatable {
    /// Nil for This Mac.
    var hostID: UUID?
    var title: String
    var detail: NWSidebarSectionDetail
    var collapsed: Bool
    var hoverHint: String?
    /// Shows the `+` for a new space (a host only while connected).
    var canAddSpace: Bool
    /// A host's worktree operations still pending: its context menu offers to check each.
    var pendingOperations: [RemoteAgentRef] = []
}

/// A space's disclosure row, local or on a host.
struct SidebarSpace: Equatable {
    /// Nil for a space on this Mac.
    var hostID: UUID?
    var id: SpaceID
    var name: String
    var collapsed: Bool
    var count: Int
    var blocked: Int
    var worktrees = 0
    var depth = 0
    /// A drop may land below the row: it is collapsed, or nothing is nested beneath it.
    var allowsDropBelow = false
    /// A git checkout: its context menu offers worktrees.
    var isRepo = false
}

/// One sidebar row, a single view whatever it shows (a lazy stack's fast path), redrawn only
/// when its values change.
private struct SidebarItemRow: View, Equatable {
    var vm: ShepherdViewModel
    let zone: SidebarDropZone
    let item: SidebarItem

    static func == (a: SidebarItemRow, b: SidebarItemRow) -> Bool { a.vm === b.vm && a.zone === b.zone && a.item == b.item }

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .machine(let machine):
                MachineHeader(vm: vm, machine: machine)
            case .space(let space):
                if let hostID = space.hostID {
                    RemoteSpaceRow(vm: vm, hostID: hostID, space: space)
                } else {
                    LocalSpaceRow(vm: vm, zone: zone, space: space)
                }
            case .agent(let model):
                LocalAgentRow(vm: vm, zone: zone, model: model)
            case .remoteAgent(let hostID, let model):
                RemoteAgentRow(vm: vm, zone: zone, hostID: hostID, model: model)
            case .notice(let hostID, let phase):
                HostNoticeRow(vm: vm, hostID: hostID, phase: phase)
            case .remoteAutomations(let header):
                RemoteAutomationsRow(vm: vm, header: header)
            case .remoteAutomation(let row):
                RemoteAutomationRow(vm: vm, row: row)
            }
        }
    }
}

extension ShepherdViewModel {
    /// The sidebar's rows in display order: This Mac's spaces and agents, then each host's.
    /// Built once per render from the memoized tree; the rows compare these values.
    func sidebarTree() -> SidebarTree {
        var tree = SidebarTree()
        let hosts = remoteHosts.connections
        tree.append(.machine(SidebarMachine(hostID: nil, title: "This Mac", detail: .count(localAgentCount),
                                            collapsed: localMachineCollapsed,
                                            hoverHint: hosts.isEmpty ? nil : machineKeycap(forHost: nil), canAddSpace: true)))
        if !localMachineCollapsed {
            let groups = spaceTree
            // A space whose next row is deeper has nested projects drawn beneath it.
            let parents = Set(groups.indices.dropLast().filter { groups[$0 + 1].depth > groups[$0].depth }.map { groups[$0].space.id })
            let badges = sidebarShortcutBadges
            let repos = spaceRepoFlags
            for group in groups {
                let collapsed = collapsedSpaces.contains(group.space.id)
                tree.append(.space(SidebarSpace(
                    id: group.space.id, name: group.space.name, collapsed: collapsed, count: group.agents.count,
                    blocked: SidebarAttention.count(group.agents, children: childRuns.rows),
                    worktrees: group.agents.count { $0.worktreeBranch != nil }, depth: group.depth,
                    allowsDropBelow: collapsed || (group.agents.isEmpty && !parents.contains(group.space.id)),
                    isRepo: repos[group.space.id] ?? spaceIsRepo(group.space))))
                guard !collapsed else { continue }
                for agent in group.agents {
                    tree.append(.agent(sidebarRowModel(for: agent, depth: group.depth + 1, badge: badges[agent.id])))
                }
            }
        }
        for connection in hosts { appendHost(connection, to: &tree) }
        tree.layout += [state.automations.map(\.id), automationsExpanded]
        return tree
    }
}

// MARK: This Mac

/// A machine's section header: This Mac, or a host, whose context menu reconnects it.
private struct MachineHeader: View {
    var vm: ShepherdViewModel
    let machine: SidebarMachine

    var body: some View {
        if let hostID = machine.hostID {
            header { vm.toggleHostCollapsed(hostID) } plus: {
                if machine.canAddSpace {
                    SidebarPlus(help: "New Space on \(machine.title)") { vm.remoteSpacePickerHostID = hostID }
                }
            }
            .contextMenu {
                ForEach(machine.pendingOperations, id: \.self) { target in
                    Button("Check Worktree Operation…") { vm.remoteWorktreeSheet = target }
                }
                Button("New Space…") { vm.remoteSpacePickerHostID = hostID }
                Button("Reconnect") { vm.remoteHosts.reconnect(id: hostID) }
            }
        } else {
            header { vm.localMachineCollapsed.toggle() } plus: {
                SidebarPlus(help: "New Space…") { vm.addSpaceFromPanel() }
            }
        }
    }

    private func header(toggle: @escaping () -> Void, @ViewBuilder plus: @escaping () -> some View) -> some View {
        NWSidebarSection(machine.title, detail: machine.detail, collapsed: machine.collapsed, hoverHint: machine.hoverHint,
                         toggle: toggle, accessory: plus)
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

/// A space on this Mac: its disclosure row, dragged to reorder, with its context menu. Its
/// agents follow it in the list.
private struct LocalSpaceRow: View {
    var vm: ShepherdViewModel
    let zone: SidebarDropZone
    let space: SidebarSpace

    var body: some View {
        let id = space.id
        SpaceRow(name: space.name, collapsed: space.collapsed, count: space.count, blocked: space.blocked,
                 worktrees: space.worktrees, depth: space.depth,
                 onToggle: { vm.toggleSpaceCollapsed(id) },
                 onNewAgent: { vm.quickCreateAgent(in: id) })
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(space: id)) }
            .sidebarDropRow(zone, id: id, target: .space(id, allowsBelow: space.allowsDropBelow))
            .contextMenu {
                Button("New Agent") { vm.quickCreateAgent(in: id) }
                Button("Rename…") { vm.spaceRenameTarget = id }
                if space.isRepo {
                    Button("New Worktree…") { vm.worktreeSheetTarget = id }
                    Button("Import Existing Worktree…") { vm.importExistingWorktreeFromPanel(in: id) }
                }
                Divider()
                Button("Remove Space…", role: .destructive) { vm.spaceDeleteTarget = id }
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
    /// The agent's last turn ended in an error.
    var turnFailed: Bool
    var dimmed: Bool

    init(agent: Agent, selected: Bool, depth: Int, badge: Int? = nil, statusSince: Date? = nil,
         children: [ChildRun] = [], turnFailed: Bool = false, dimmed: Bool = false) {
        self.agent = agent
        self.turnFailed = turnFailed
        self.selected = selected
        self.depth = depth
        self.badge = badge
        self.statusSince = statusSince
        self.subagentNeedsYou = children.contains(where: \.needsAttention)
        self.dimmed = dimmed
    }

    /// A question waits on the user: the agent's own, or one of its subagents'.
    var needsYou: Bool { agent.status == .blocked || subagentNeedsYou }

    /// A finished agent whose turn ended in an error reads failed, not done.
    private var failed: Bool { turnFailed && agent.status == .done }

    /// The dot: needs you wins over the agent's own status.
    var state: AgentState { needsYou ? .attention : failed ? .failed : AgentState(agent.status) }

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
        let word = needsYou ? "needs you" : AgentRow.statusWord(agent.status, turnFailed: turnFailed)
        return "\(agent.name), \(agent.worktreeBranch != nil ? "worktree, " : "")\(word)"
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
        sidebarRowModel(for: agent, depth: depth, badge: shortcutBadge(for: agent.id))
    }

    /// The row values for a local agent, with its ⌘-digit badge already looked up.
    func sidebarRowModel(for agent: Agent, depth: Int, badge: Int?) -> SidebarAgentRowModel {
        SidebarAgentRowModel(
            agent: agent, selected: selectedAgentID == agent.id && selectedRemoteAgent == nil, depth: depth,
            badge: badge, statusSince: statusSince[agent.id], children: children(of: agent.id),
            turnFailed: failedTurns.contains(agent.id)
        )
    }

    /// The row values for an agent on a remote host, with the children the host reports.
    func remoteSidebarRowModel(for agent: Agent, on connection: RemoteHostStore.Connection) -> SidebarAgentRowModel {
        remoteSidebarRowModel(for: agent, on: connection, badges: remoteShortcutBadges(hostID: connection.id))
    }

    /// The row values for an agent on a remote host, with the host's ⌘-digit badges.
    func remoteSidebarRowModel(for agent: Agent, on connection: RemoteHostStore.Connection,
                               badges: [AgentID: Int]) -> SidebarAgentRowModel {
        SidebarAgentRowModel(
            agent: agent, selected: selectedRemoteAgent == RemoteAgentRef(hostID: connection.id, agentID: agent.id),
            depth: 1, badge: badges[agent.id], children: connection.children[agent.id] ?? []
        )
    }

    /// ⌘-digit badges for a host's first nine agents while ⌘ is held with one of its agents
    /// selected; empty otherwise.
    func remoteShortcutBadges(hostID: UUID) -> [AgentID: Int] {
        guard showAgentShortcutBadges, selectedRemoteAgent?.hostID == hostID else { return [:] }
        return Dictionary(remoteOrderedAgents(hostID: hostID).prefix(9).enumerated().map { ($1.id, $0 + 1) }) { first, _ in first }
    }
}

/// A local agent's row, with its drag, drop, and context menu.
struct LocalAgentRow: View, Equatable {
    var vm: ShepherdViewModel
    let zone: SidebarDropZone
    let model: SidebarAgentRowModel

    static func == (a: LocalAgentRow, b: LocalAgentRow) -> Bool { a.vm === b.vm && a.zone === b.zone && a.model == b.model }

    var body: some View {
        let agent = model.agent
        AgentRow(model: model) { vm.selectAgent(agent.id) }
            .onDrag { vm.beginSidebarDrag(ShepherdViewModel.dragPayload(agent: agent.id)) }
            .sidebarDropRow(zone, id: agent.id, target: .agent(agent.id))
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

    /// The status language's word; a finished agent whose turn ended in an error reads failed.
    static func statusWord(_ status: AgentStatus, turnFailed: Bool = false) -> String {
        switch status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle: "idle"
        case .done: turnFailed ? "failed" : "done"
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
                                      turnFailed: agent.map { vm.failedTurns.contains($0.id) } ?? false,
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
    /// The run's last turn ended in an error.
    let turnFailed: Bool
    let selected: Bool
    let action: () -> Void

    private var stateWord: String { Self.stateWord(agent, turnFailed: turnFailed) }
    private var state: AgentState { Self.state(agent, turnFailed: turnFailed) }

    /// A run that has ended reads done, or failed when its last turn ended in an error.
    static func stateWord(_ agent: Agent?, turnFailed: Bool) -> String {
        guard let agent else { return "stopped" }
        return switch agent.status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle, .done: turnFailed && agent.status == .done ? "failed" : "done"
        }
    }

    static func state(_ agent: Agent?, turnFailed: Bool) -> AgentState {
        guard let agent else { return .idle }
        if turnFailed && agent.status == .done { return .failed }
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

/// Sidebar reordering: a 2pt running line at a row's top or bottom edge (by pointer half) while
/// a valid drag hovers it. Only drags that started in this sidebar qualify; their payload type
/// is private to the process.
///
/// One drop target covers the whole list, and each row on screen registers its frame and how it
/// takes a drop. A drop target is an AppKit registration: one per row, built as each row scrolled
/// into view, cost about four times the rest of the row and made scrolling drop frames.
@MainActor @Observable
final class SidebarDropZone {
    /// How a row takes a drop.
    enum Target: Equatable {
        /// `allowsBelow`: a drop may land below the row (see `SidebarSpace.allowsDropBelow`).
        case space(SpaceID, allowsBelow: Bool)
        case agent(AgentID)
        case remoteAgent(RemoteAgentRef)

        var allowsBelow: Bool {
            if case .space(_, let allowsBelow) = self { return allowsBelow }
            return true
        }
    }

    /// Where the line is drawn: the hovered row's frame in the list, and its edge.
    struct Line: Equatable {
        var row: AnyHashable
        var frame: CGRect
        var edge: SidebarDropEdge
    }

    /// The list's coordinate space: rows register their frames in it, and drops arrive in it.
    nonisolated static let space = "sidebar.list"

    private(set) var line: Line?
    @ObservationIgnored private var frames: [AnyHashable: CGRect] = [:]
    @ObservationIgnored private var targets: [AnyHashable: Target] = [:]

    func setFrame(_ frame: CGRect, of row: AnyHashable) { frames[row] = frame }
    func setTarget(_ target: Target, of row: AnyHashable) { targets[row] = target }

    /// A row that left the screen can't be hovered.
    func remove(_ row: AnyHashable) {
        frames[row] = nil
        targets[row] = nil
    }

    func show(_ line: Line?) {
        if self.line != line { self.line = line }
    }

    /// The drop row under `point`, in the list's coordinate space.
    func row(at point: CGPoint) -> (id: AnyHashable, frame: CGRect, target: Target)? {
        for (id, frame) in frames where frame.minY <= point.y && point.y < frame.maxY {
            if let target = targets[id] { return (id, frame, target) }
        }
        return nil
    }

    /// A drag of `payload` moved to `point`: draws the line where it would land, and answers
    /// whether it would.
    func hover(_ payload: String?, at point: CGPoint, vm: ShepherdViewModel) -> Bool {
        guard let payload, let row = row(at: point) else {
            show(nil)
            return false
        }
        let edge = SidebarDropEdge.at(y: point.y - row.frame.minY, height: row.frame.height, allowsBelow: row.target.allowsBelow)
        guard vm.dropOnSidebar(payload, at: row.target, edge: edge, validateOnly: true) else {
            show(nil)
            return false
        }
        show(Line(row: row.id, frame: row.frame, edge: edge))
        return true
    }

    /// Drops `payload` where the line is, and clears the line.
    func drop(_ payload: String?, vm: ShepherdViewModel) -> Bool {
        defer { show(nil) }
        guard let payload, let line, let target = targets[line.row] else { return false }
        return vm.dropOnSidebar(payload, at: target, edge: line.edge, validateOnly: false)
    }
}

extension ShepherdViewModel {
    /// Applies (or with `validateOnly`, answers whether it would apply) a sidebar drop of
    /// `payload` at `edge` of the row `target` describes.
    func dropOnSidebar(_ payload: String, at target: SidebarDropZone.Target, edge: SidebarDropEdge, validateOnly: Bool) -> Bool {
        switch target {
        case .space(let id, _): dropSpace(payload: payload, on: id, edge: edge, validateOnly: validateOnly)
        case .agent(let id): dropAgent(payload: payload, on: id, edge: edge, validateOnly: validateOnly)
        case .remoteAgent(let ref): dropRemoteAgent(payload: payload, on: ref, edge: edge, validateOnly: validateOnly)
        }
    }
}

private struct SidebarDropDelegate: DropDelegate {
    let vm: ShepherdViewModel
    let zone: SidebarDropZone

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.shepherdSidebarItem]) && vm.sidebarDragPayload != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: zone.hover(vm.sidebarDragPayload, at: info.location, vm: vm) ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) { zone.show(nil) }

    func performDrop(info: DropInfo) -> Bool {
        defer { vm.sidebarDragPayload = nil }
        return zone.drop(vm.sidebarDragPayload, vm: vm)
    }
}

/// The drop line over the list: a fresh line fades in at each row and edge it moves to.
private struct SidebarDropLine: View {
    let zone: SidebarDropZone

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let line = zone.line {
                NWDropIndicator()
                    .frame(width: line.frame.width)
                    .offset(x: line.frame.minX, y: line.edge == .above ? line.frame.minY : line.frame.maxY - NWDropIndicator.thickness)
                    .id([line.row, AnyHashable(line.edge == .above)])
                    .nwTransition(.hover)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .nwAnimation(.hover, value: zone.line)
        .allowsHitTesting(false)
    }
}

extension View {
    /// The list's single reorder drop target and its drop line.
    func sidebarDropZone(_ zone: SidebarDropZone, vm: ShepherdViewModel) -> some View {
        coordinateSpace(.named(SidebarDropZone.space))
            .onDrop(of: [.shepherdSidebarItem], delegate: SidebarDropDelegate(vm: vm, zone: zone))
            .overlay { SidebarDropLine(zone: zone) }
    }

    /// Registers this row with the list's drop target while it is on screen.
    func sidebarDropRow(_ zone: SidebarDropZone, id: AnyHashable, target: SidebarDropZone.Target) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarDropZone.space)) } action: { zone.setFrame($0, of: id) }
            .onChange(of: target, initial: true) { zone.setTarget(target, of: id) }
            .onDisappear { zone.remove(id) }
    }
}
