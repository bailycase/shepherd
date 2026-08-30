import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import UniformTypeIdentifiers

/// The sidebar tree: waiting summary, spaces with their agents nested under
/// them, then the `+ new space` footer and the fleet dot-count strip.
/// Everything is mono, flat, and full-bleed — no chips, no vibrancy.
struct SidebarView: View {
    var vm: ShepherdViewModel
    /// Density/text-scale live in AppSettings; observing re-renders the tree
    /// when a slider moves (rows read Fonts/Metrics inside body, so parent
    /// re-render is what re-evaluates them — rows carry closures, which
    /// makes SwiftUI re-run their bodies rather than skip them).
    @ObservedObject private var appearance = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.blockedCount > 0 {
                WaitingSummary(vm: vm)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Machine roots: THIS MAC, then each host — one unified
                        // tree, so remote fleets are the same species as local.
                        // The local root only appears once a second machine
                        // exists; a purely local setup keeps today's flat tree.
                        if vm.remoteHosts.connections.isEmpty {
                            ForEach(vm.spaceTree, id: \.space.id) { group in
                                SpaceSection(vm: vm, space: group.space, agents: group.agents, depth: group.depth)
                                    .id(group.space.id)
                            }
                        } else {
                            MachineHeaderRow(
                                marker: nil,
                                name: "this mac",
                                collapsed: vm.localMachineCollapsed,
                                detail: .count(vm.state.agents.count),
                                keycap: vm.machineKeycap(forHost: nil),
                                onToggle: { vm.localMachineCollapsed.toggle() }
                            )
                            if !vm.localMachineCollapsed {
                                ForEach(vm.spaceTree, id: \.space.id) { group in
                                    SpaceSection(vm: vm, space: group.space, agents: group.agents, depth: group.depth + 1)
                                        .id(group.space.id)
                                }
                            }
                            ForEach(vm.remoteHosts.connections) { connection in
                                Rectangle().fill(Tokens.separator).frame(height: 1)
                                    .padding(.vertical, 3)
                                RemoteHostBlock(vm: vm, connection: connection)
                            }
                        }
                        if let hint = vm.agentsHintText {
                            Text(hint)
                                .font(Fonts.mono(10.5))
                                .foregroundStyle(Tokens.textDim)
                                .padding(EdgeInsets(top: 10, leading: 14, bottom: 3, trailing: 8))
                        }
                    }
                    .padding(.top, 2)
                }
                // Keyboard navigation (⌘1–9, ⌘↑/↓, ⌃⇧digits) can land on a
                // row scrolled out of view. Reveal it with a minimal animated
                // scroll; mouse and palette selections arrive here too and are
                // no-ops when the row is already visible. The trigger is a
                // counter, not the target value, so re-selecting the same row
                // still scrolls back to it.
                // The same selection may have just opened a disclosure (the
                // local machine root, an ancestor space, a host), so the row
                // can be absent from the tree at this instant — scroll on the
                // next runloop turn, once it exists.
                .onChange(of: vm.sidebarRevealRequest) {
                    guard let target = vm.sidebarRevealTarget else { return }
                    DispatchQueue.main.async {
                        withAnimation(
                            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                ? nil
                                : .easeOut(duration: 0.12) // DESIGN.md: ≤120ms
                        ) {
                            proxy.scrollTo(target)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            AutomationsSection(vm: vm)
            ShellsSection(vm: vm)
            // Breathing room under the last row now that the footer is gone.
            Color.clear.frame(height: 8)
        }
    }
}

/// `● 3 waiting` block under the traffic lights — attention lives at the top
/// of the sidebar, where scanning starts. Hidden at zero (see SidebarView).
struct WaitingSummary: View {
    var vm: ShepherdViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(Tokens.statusBlocked)
                    .frame(width: 7, height: 7)
                Text("\(vm.blockedCount) waiting")
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textSecondary)
                Spacer(minLength: 0)
            }
            Text(vm.waitingSummaryDetail)
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textMetadata)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(EdgeInsets(top: 2, leading: 14, bottom: 10, trailing: 10))
    }
}

/// One space: header row (disclosure, uppercase name, count / `+`) and its
/// agent rows nested under it. Collapsed spaces show only the header, dimmer.
struct SpaceSection: View {
    var vm: ShepherdViewModel
    let space: Space
    let agents: [Agent]
    /// 0 for a root space; deeper spaces are projects nested by path
    /// containment and indent under their parent.
    var depth: Int = 0

    private var collapsed: Bool { vm.collapsedSpaces.contains(space.id) }
    private var isActive: Bool {
        // A shell or remote agent owns the workspace; no local space reads active.
        vm.selectedShellID == nil && vm.selectedRemoteAgent == nil
            && (vm.selectedAgent?.spaceID == space.id
                || (vm.selectedAgentID == nil && vm.selectedSpaceID == space.id))
    }
    private var blockedHere: Int { agents.count { $0.status == .blocked } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceHeaderRow(
                name: space.name,
                collapsed: collapsed,
                active: isActive,
                blockedCount: blockedHere,
                agentCount: agents.count,
                worktreeCount: agents.count { $0.worktreeBranch != nil },
                depth: depth,
                onToggle: { vm.toggleSpaceCollapsed(space.id) },
                onNewAgent: { vm.quickCreateAgent(in: space.id) }
            )
            .onDrag { NSItemProvider(object: ShepherdViewModel.dragPayload(space: space.id) as NSString) }
            .sidebarDropTarget { payload in vm.dropSpace(payload: payload, on: space.id) }
            .contextMenu {
                Button("Rename…") { vm.spaceRenameTarget = space.id }
                if GitWorktree.isRepo(space.path) {
                    Button("New Worktree…") { vm.worktreeSheetTarget = space.id }
                    Button("Import Existing Worktree…") {
                        vm.importExistingWorktreeFromPanel(in: space.id)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    vm.spaceDeleteTarget = space.id
                } label: {
                    Text("Remove Space…").foregroundStyle(Tokens.destructive)
                }
            }
            if !collapsed {
                ForEach(agents) { agent in
                    let children = vm.children(of: agent.id)
                    let showsSubagents = AgentRow.showsSubagents(for: agent.status)
                    let childrenHidden = vm.collapsedChildren.contains(agent.id)
                    AgentRow(
                        agent: agent,
                        selected: vm.selectedAgentID == agent.id && vm.selectedShellID == nil
                            && vm.selectedRemoteAgent == nil && vm.inspectingAgentID == nil,
                        badge: vm.shortcutBadge(for: agent.id),
                        subCount: showsSubagents && childrenHidden ? children.count : 0,
                        subAttention: showsSubagents && childrenHidden && children.contains { $0.needsAttention },
                        depth: depth,
                        subAction: {
                            if childrenHidden {
                                vm.collapsedChildren.remove(agent.id)
                            } else {
                                vm.collapsedChildren.insert(agent.id)
                            }
                        }
                    ) {
                        // Fold/unfold only when the click is a true re-click:
                        // the agent's own terminal is already what the
                        // workspace shows. Coming back from a subagent
                        // inspector or a shell just returns to the terminal.
                        let showingAgentTerminal = vm.selectedAgentID == agent.id
                            && vm.inspectingAgentID == nil
                            && vm.selectedShellID == nil
                            && vm.selectedRemoteAgent == nil
                        if showingAgentTerminal, showsSubagents, !children.isEmpty {
                            if childrenHidden {
                                vm.collapsedChildren.remove(agent.id)
                            } else {
                                vm.collapsedChildren.insert(agent.id)
                            }
                        }
                        vm.selectAgent(agent.id)
                    }
                    .onDrag { NSItemProvider(object: ShepherdViewModel.dragPayload(agent: agent.id) as NSString) }
                    .sidebarDropTarget { payload in vm.dropAgent(payload: payload, on: agent.id) }
                    .contextMenu {
                        Button("Rename…") { vm.agentRenameTarget = agent.id }
                        Divider()
                        if agent.worktreeBranch != nil {
                            Button("Finalize Worktree…") { vm.beginFinalizeWorktree(agent.id) }
                            Divider()
                            // Confirms: deleting can also remove the checkout.
                            Button(role: .destructive) {
                                vm.worktreeDeleteTarget = agent.id
                            } label: {
                                Text("Delete Worktree Agent…").foregroundStyle(Tokens.destructive)
                            }
                        } else {
                            Button(role: .destructive) {
                                vm.deleteAgent(agent.id)
                            } label: {
                                Text("Delete Agent").foregroundStyle(Tokens.destructive)
                            }
                        }
                    }
                    // Scroll target for keyboard selection (see SidebarView).
                    .id(agent.id)
                    // Live pi-subagents child runs nest under their agent.
                    // Clicking opens the run's inspector dashboard in a pane
                    // beside the agent (steer/stop at its prompt; closing the
                    // pane never touches the run).
                    if showsSubagents, !childrenHidden {
                        ForEach(children) { child in
                            ChildRunRow(
                                child: child,
                                selected: vm.inspectingAgentID == agent.id
                                    && vm.inspectedChild[agent.id] == child.id,
                                depth: depth
                            ) {
                                vm.openChildInspector(agentID: agent.id, child: child)
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, depth == 0 ? 6 : 0)
    }
}

struct SpaceHeaderRow: View {
    let name: String
    let collapsed: Bool
    let active: Bool
    let blockedCount: Int
    let agentCount: Int
    /// Agents in this space running on their own git worktree — shown as a
    /// dim `⎇n` beside the count so the space advertises them even collapsed.
    var worktreeCount: Int = 0
    var depth: Int = 0
    let onToggle: () -> Void
    let onNewAgent: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(collapsed ? "▸" : "▾")
                .font(Fonts.mono(9))
                .foregroundStyle(collapsed ? Tokens.textDim : Tokens.textTertiary)
                .frame(width: 9)
            // Roots are UPPERCASE section headers; nested projects read as
            // paths: lowercase with a trailing slash (see DESIGN mock).
            Text(depth == 0 ? name.uppercased() : name + "/")
                .font(Fonts.mono(depth == 0 ? 10.5 : 11, .semibold))
                .tracking(depth == 0 ? 0.74 : 0)
                .foregroundStyle(collapsed ? Tokens.textDim : Tokens.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if blockedCount > 0 {
                Text("\(blockedCount)")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.statusBlocked)
            } else if agentCount > 0 {
                Text("\(agentCount)")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
            }
            if worktreeCount > 0 {
                Text("⎇\(worktreeCount)")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
                    .help("\(worktreeCount) worktree agent\(worktreeCount == 1 ? "" : "s")")
            }
            if active || hovering {
                Text("+")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onNewAgent)
                    .help("New Agent in This Space")
            }
        }
        .padding(.leading, 10 + CGFloat(depth) * 12)
        .padding(.trailing, 14)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? Tokens.rowActiveHeader : hovering ? Tokens.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
    }
}

struct AgentRow: View {
    let agent: Agent
    let selected: Bool
    var badge: Int?
    /// Hidden-children count; nonzero shows the `n sub` chip.
    var subCount: Int = 0
    /// A hidden child needs attention — the chip must not mute it.
    var subAttention: Bool = false
    var depth: Int = 0
    var subAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    enum TrailingAccessory: Equatable {
        case status(String)
        case badge(Int)
        case subagents(Int)
        case none
    }

    static func showsSubagents(for status: AgentStatus) -> Bool {
        status != .done && status != .blocked
    }

    static func trailingAccessory(
        status: AgentStatus,
        badge: Int?,
        subCount: Int
    ) -> TrailingAccessory {
        if !showsSubagents(for: status) { return .status(status.rawValue) }
        if let badge { return .badge(badge) }
        if subCount > 0 { return .subagents(subCount) }
        return .none
    }

    private var trailingAccessory: TrailingAccessory {
        Self.trailingAccessory(status: agent.status, badge: badge, subCount: subCount)
    }

    private var containsSubagentButton: Bool {
        if case .subagents = trailingAccessory { return true }
        return false
    }

    private var nameColor: Color {
        if selected { return Tokens.textPrimary }
        switch agent.status {
        case .working, .blocked: return Tokens.textSecondary
        case .done: return Tokens.textSecondary
        case .idle: return Tokens.textDim
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // A worktree agent reads as a sub-checkout of its space: a tree
            // connector (with the extra indent below) into the status marker,
            // then the branch glyph in front of its name.
            if agent.worktreeBranch != nil {
                Text("└─")
                    .font(Fonts.mono(10))
                    .foregroundStyle(Tokens.textDim)
            }
            StatusMarker(status: agent.status)
            if agent.worktreeBranch != nil {
                Text("⎇")
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.textTertiary)
            }
            // Titles are generated, so they can run long (and a provisional
            // name is a truncated prompt): keep rows one line.
            Text(agent.name)
                .font(Fonts.mono(12))
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(agent.worktreeBranch.map { "worktree \($0)" } ?? agent.name)
            Spacer(minLength: 0)
            switch trailingAccessory {
            case .status(let status):
                Text(status)
                    .font(Fonts.mono(10))
                    .foregroundStyle(Tokens.statusColor(agent.status))
            case .badge(let badge):
                Text("⌘\(badge)")
                    .font(Fonts.mono(10))
                    .foregroundStyle(Tokens.textTertiary)
                    .transition(.opacity)
            case .subagents(let count):
                Button(action: { subAction?() }) {
                    Text("\(count) sub")
                        .font(Fonts.mono(9.5))
                        .foregroundStyle(subAttention ? Tokens.statusBlocked : Tokens.textMetadata)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(subAttention ? Tokens.statusBlocked.opacity(0.5) : Tokens.chipBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(count) subagents")
            case .none:
                EmptyView()
            }
        }
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeOut(duration: 0.12),
            value: badge
        )
        .padding(.leading, 16 + CGFloat(depth) * 12 + (agent.worktreeBranch != nil ? 12 : 0))
        .padding(.trailing, 10)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Tokens.rowSelection : hovering ? Tokens.rowHover : Color.clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(Tokens.statusColor(agent.status))
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: containsSubagentButton ? .contain : .ignore)
        .accessibilityLabel(
            "\(agent.name), \(agent.worktreeBranch != nil ? "worktree, " : "")\(agent.status.rawValue), pi"
        )
    }
}


/// Plain-text drop target for sidebar reordering: highlights while a drag
/// hovers, hands the payload string to `perform`, and rejects (no flash, no
/// state change) anything `perform` returns false for — wrong row kind,
/// cross-space agent drops, self-drops.
private struct SidebarDropTarget: ViewModifier {
    let perform: (String) -> Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if hovering {
                    Rectangle().fill(Tokens.focusAccent).frame(height: 2)
                }
            }
            .onDrop(of: [.plainText], isTargeted: $hovering) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let payload = object as? String else { return }
                    Task { @MainActor in _ = perform(payload) }
                }
                return true
            }
    }
}

extension View {
    func sidebarDropTarget(perform: @escaping (String) -> Bool) -> some View {
        modifier(SidebarDropTarget(perform: perform))
    }
}

/// One pi-subagents child run, nested under its agent. Ephemeral: rows come
/// and go with the run (see `ChildRuns`). The trailing text is elapsed time
/// while live, the terminal state once finished.
struct ChildRunRow: View {
    let child: ChildRun
    /// True while this child's inspector is what the workspace shows.
    var selected = false
    var depth: Int = 0
    let action: () -> Void
    @State private var hovering = false

    private var dotColor: Color {
        if child.needsAttention { return Tokens.statusBlocked }
        switch child.state {
        case "running", "queued": return Tokens.statusWorking
        case "complete": return Tokens.statusDone
        case "failed", "stopped", "rejected": return Tokens.statusBlocked
        default: return Tokens.textDim
        }
    }

    private var trailing: String {
        if child.needsAttention { return "waiting" }
        if child.isTerminal { return child.state == "complete" ? "done" : child.state }
        guard let started = child.startedAt else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - started / 1000))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        default: return "\(seconds / 3600)h"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(child.label)
                .font(Fonts.mono(11.5, selected ? .semibold : .regular))
                .foregroundStyle(
                    selected ? Tokens.textPrimary
                        : child.isTerminal ? Tokens.textDim : Tokens.textSecondary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .help(child.attentionText ?? child.label)
            Spacer(minLength: 0)
            // TimelineView keeps the elapsed age moving while the run lives.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(trailing)
                    .font(Fonts.mono(10))
                    .foregroundStyle(child.needsAttention ? Tokens.statusBlocked : Tokens.textMetadata)
            }
        }
        .padding(.leading, 30 + CGFloat(depth) * 12)
        .padding(.trailing, 10)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Tokens.rowSelection : hovering ? Tokens.rowHover : Color.clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(dotColor).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(child.label), subagent, \(child.state)")
    }
}

/// Colored dot; the word beside it (row `done` label, header `blocked 4m`,
/// waiting summary) carries the state for accessibility.
struct StatusMarker: View {
    let status: AgentStatus
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(Tokens.statusColor(status))
            .frame(width: 7, height: 7)
            .opacity(status == .working && dimmed ? 0.45 : 1)
            .onAppear {
                guard status == .working,
                      !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// AUTOMATIONS: saved monitoring prompts run by ordinary agents. Pinned
/// above SHELLS. A row's chip mirrors its running agent's status; clicking a
/// running row selects that agent. Hidden entirely while empty — automations
/// are created by pi (the skill) or a running agent, not a sidebar `+`.
struct AutomationsSection: View {
    var vm: ShepherdViewModel

    var body: some View {
        let automations = vm.state.automations
        if !automations.isEmpty {
            Rectangle().fill(Tokens.separator).frame(height: 1)
            HStack(spacing: 7) {
                Text("AUTOMATIONS")
                    .font(Fonts.mono(10.5, .semibold))
                    .tracking(0.74)
                    .foregroundStyle(Tokens.textSecondary)
                Spacer(minLength: 0)
                Text("\(automations.count)")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
            }
            .padding(.horizontal, 14)
            .frame(height: Metrics.rowHeight)
            ForEach(automations) { automation in
                let agent = vm.automationAgent(automation)
                AutomationRow(
                    automation: automation,
                    agent: agent,
                    selected: agent != nil && vm.selectedAgentID == agent?.id && vm.selectedShellID == nil
                ) {
                    // Click selects a running agent; a stopped row does
                    // nothing — starting is deliberate (context menu Run Now).
                    if let agent { vm.selectAgent(agent.id) }
                }
                .contextMenu {
                    if automation.agentID == nil {
                        Button("Run Now") {
                            Task { @MainActor in try? await vm.startAutomation(automation.id) }
                        }
                    } else {
                        Button("Stop") { vm.stopAutomation(automation.id) }
                    }
                    Divider()
                    Button(role: .destructive) {
                        vm.deleteAutomation(automation.id)
                    } label: {
                        Text("Delete Automation").foregroundStyle(Tokens.destructive)
                    }
                }
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let agent {
                StatusMarker(status: agent.status)
            } else {
                Circle()
                    .strokeBorder(Tokens.textDim, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
            Text(automation.name)
                .font(Fonts.mono(12))
                .foregroundStyle(selected ? Tokens.textPrimary : Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(agent.map { $0.status == .working ? "running" : $0.status.rawValue } ?? "stopped")
                .font(Fonts.mono(10))
                .foregroundStyle(Tokens.textMetadata)
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: Metrics.rowHeight)
        .background(selected ? Tokens.rowSelection : hovering ? Tokens.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}

/// SHELLS: global terminal workspaces outside every space, for one-off work
/// (logs, htop, scratch dirs). Pinned above the footer, like the mock.
struct ShellsSection: View {
    var vm: ShepherdViewModel
    @State private var hoveringHeader = false

    var body: some View {
        let shells = vm.shellTabs
        if !shells.isEmpty || hoveringHeader {
            Rectangle().fill(Tokens.separator).frame(height: 1)
        }
        HStack(spacing: 7) {
            Text("SHELLS")
                .font(Fonts.mono(10.5, .semibold))
                .tracking(0.74)
                .foregroundStyle(shells.isEmpty ? Tokens.textDim : Tokens.textSecondary)
            Spacer(minLength: 0)
            if !shells.isEmpty {
                Text("\(shells.count)")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
            }
            if hoveringHeader || shells.isEmpty {
                Text("+")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textTertiary)
                    .contentShape(Rectangle())
                    .onTapGesture { vm.addShell() }
                    .help("New Shell")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onHover { hoveringHeader = $0 }
        ForEach(vm.shellTabs) { shell in
            ShellRow(
                label: ShepherdViewModel.shellLabel(shell),
                selected: vm.selectedShellID == shell.id,
                process: vm.shellProcessLabel(for: shell.id),
                badge: vm.shellShortcutBadge(for: shell.id)
            ) {
                vm.selectShell(shell.id)
            }
            .contextMenu {
                Button("Rename…") { vm.shellRenameTarget = shell.id }
                Divider()
                Button(role: .destructive) {
                    vm.deleteShell(shell.id)
                } label: {
                    Text("Close Shell").foregroundStyle(Tokens.destructive)
                }
            }
        }
    }
}

struct ShellRow: View {
    let label: String
    let selected: Bool
    /// Foreground process, when it isn't the login shell itself ("pi").
    var process: String?
    var badge: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(Fonts.mono(11))
                .foregroundStyle(selected ? Tokens.focusAccent : Tokens.textDim)
            Text(label)
                .font(Fonts.mono(12))
                .foregroundStyle(selected ? Tokens.textPrimary : Tokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let process {
                Text("· \(process)")
                    .font(Fonts.mono(11))
                    .foregroundStyle(Tokens.statusWorking)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(Fonts.mono(10))
                    .foregroundStyle(Tokens.textTertiary)
                    .transition(.opacity)
            }
        }
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeOut(duration: 0.12),
            value: badge
        )
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Tokens.rowSelection : hovering ? Tokens.rowHover : Color.clear)
        .overlay(alignment: .leading) {
            if selected {
                Rectangle().fill(Tokens.focusAccent).frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), shell")
    }
}

/// `+ new space` row and the fleet dot-count strip.

