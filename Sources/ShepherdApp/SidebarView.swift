import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
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
                                    // The machine row is a section header (page 8), not a tree level:
                                    // spaces stay flush with it and agents indent once.
                                    SpaceSection(vm: vm, space: group.space, agents: group.agents, depth: group.depth)
                                        .id(group.space.id)
                                }
                            }
                            ForEach(vm.remoteHosts.connections) { connection in
                                RemoteHostBlock(vm: vm, connection: connection)
                                    .padding(.top, 6)
                            }
                        }
                        if let hint = vm.agentsHintText {
                            Text(hint)
                                .font(NativeFonts.sidebarMeta)
                                .foregroundStyle(NativeTokens.textMuted)
                                .padding(EdgeInsets(top: 10, leading: NativeMetrics.sidebarPadding + 8, bottom: 3, trailing: NativeMetrics.sidebarPadding))
                        }
                    }
                    .padding(.top, NativeMetrics.sidebarPadding)
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

            // Bottom block: Automations and Shells behind a 1pt border (spec §3).
            NativeTokens.border.frame(height: 1)
            AutomationsSection(vm: vm)
            ShellsSection(vm: vm)
            Color.clear.frame(height: NativeMetrics.sidebarPadding)
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
                    .fill(NativeTokens.warning)
                    .frame(width: 7, height: 7)
                Text("\(vm.blockedCount) waiting")
                    .font(NativeFonts.sidebarRow)
                    .foregroundStyle(NativeTokens.warningText)
                Spacer(minLength: 0)
            }
            Text(vm.waitingSummaryDetail)
                .font(NativeFonts.sidebarMeta)
                .foregroundStyle(NativeTokens.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Same inset as row content (sidebar padding + the row's own 8pt), so the dot lines up.
        .padding(EdgeInsets(top: 2, leading: NativeMetrics.sidebarPadding + 8, bottom: 10, trailing: NativeMetrics.sidebarPadding + 8))
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
                    let finished = nativeSubagentGroupIsTerminal(children)
                    // A finished group has its own fold row; the agent row's chip and re-click fold are for live groups.
                    let showsSubagents = !finished && AgentRow.showsSubagents(for: agent.status, hasActiveChildren: children.contains { !$0.isTerminal || $0.needsAttention })
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
                        // D2: the runtime is fixed per process; switching restarts pi in the
                        // same session. Confirms first (RootView sheet).
                        Button(agent.runtime == .rpc ? "Restart as Terminal Agent…" : "Restart as Native (RPC) Agent…") {
                            vm.runtimeRestartTarget = agent.id
                        }
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
                    // A finished group folds into one "↳ 3 SUBAGENTS · done 11:09" row (board: completed
                    // sidebar); clicking it toggles the child rows. Live groups keep the nested rows.
                    let showsRows = finished ? vm.unfoldedSubagentGroups.contains(agent.id) : (showsSubagents && !childrenHidden)
                    if finished {
                        SubagentGroupRow(children: children, expanded: showsRows, depth: depth) {
                            if showsRows { vm.unfoldedSubagentGroups.remove(agent.id) } else { vm.unfoldedSubagentGroups.insert(agent.id) }
                        }
                    }
                    if showsRows {
                        ForEach(children) { child in
                            ChildRunRow(
                                child: child,
                                selected: (vm.inspectingAgentID == agent.id && vm.inspectedChild[agent.id] == child.id)
                                    || (vm.selectedAgentID == agent.id && vm.subagentInspector.runByAgent[agent.id] == child.runID),
                                depth: depth,
                                inFinishedGroup: finished
                            ) {
                                vm.openChildInspector(agentID: agent.id, child: child)
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, depth == 0 ? 4 : 0)
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
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(NativeTokens.textMuted)
                .frame(width: 12)
            Text(name)
                .font(NativeFonts.sidebarRow)
                .foregroundStyle(collapsed ? NativeTokens.textSecondary : NativeTokens.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            if blockedCount > 0 {
                Text("\(blockedCount)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.warningText)
            } else if agentCount > 0 {
                Text("\(agentCount)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
            }
            if worktreeCount > 0 {
                Text("⎇\(worktreeCount)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
                    .help("\(worktreeCount) worktree agent\(worktreeCount == 1 ? "" : "s")")
            }
            if active || hovering {
                SidebarPlusButton(help: "New Agent in This Space", action: onNewAgent)
            }
        }
        // Nesting indents the content, not the row: hover/selection fills always span the sidebar (page 8).
        .padding(.leading, 8 + CGFloat(depth) * NativeMetrics.sidebarIndent)
        .padding(.trailing, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? NativeTokens.bgHoverStrong : Color.clear, in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
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

    static func showsSubagents(for status: AgentStatus, hasActiveChildren: Bool = false) -> Bool {
        hasActiveChildren || (status != .done && status != .blocked)
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
        if selected { return NativeTokens.text }
        switch agent.status {
        case .working, .blocked, .done: return NativeTokens.text
        case .idle: return NativeTokens.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            SidebarStatusDot(status: agent.status, current: selected)
            if agent.worktreeBranch != nil {
                Text("⎇")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textTertiary)
            }
            // Titles are generated, so they can run long (and a provisional
            // name is a truncated prompt): keep rows one line.
            Text(agent.name)
                .font(NativeFonts.sidebarRow)
                .foregroundStyle(nameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(agent.worktreeBranch.map { "worktree \($0)" } ?? agent.name)
            Spacer(minLength: 0)
            switch trailingAccessory {
            case .status(let status):
                // The dot already says done; only "waiting" earns a word (page 8 right slot).
                if status == "blocked" {
                    Text("waiting")
                        .font(NativeFonts.sidebarMeta)
                        .foregroundStyle(NativeTokens.warningText)
                        .fixedSize()
                }
            case .badge(let badge):
                Text("⌘\(badge)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
                    .transition(.opacity)
            case .subagents(let count):
                Button(action: { subAction?() }) {
                    Text("\(count) sub")
                        .font(NativeFonts.sidebarMeta)
                        .foregroundStyle(subAttention ? NativeTokens.warningText : NativeTokens.textMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .stroke(subAttention ? NativeTokens.warning.opacity(0.5) : NativeTokens.borderStrong, lineWidth: 1)
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
        // Nested under the space header: one indent past the chevron puts the dot under the space
        // name. The ⎇ glyph marks a worktree, no extra indent.
        .padding(.leading, 8 + CGFloat(depth + 1) * NativeMetrics.sidebarIndent)
        .padding(.trailing, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? NativeTokens.bgSelected : hovering ? NativeTokens.bgHoverStrong : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityElement(children: containsSubagentButton ? .contain : .ignore)
        .accessibilityLabel(
            "\(agent.name), \(agent.worktreeBranch != nil ? "worktree, " : "")\(agent.status.rawValue), pi"
        )
    }
}

/// 7pt status dot per the spec's sidebar table: running → success, waiting →
/// warning, idle → grey (accent when it's the open thread), done → grey.
struct SidebarStatusDot: View {
    let status: AgentStatus
    var current = false
    @State private var dimmed = false

    var color: Color {
        switch status {
        case .working: return NativeTokens.success
        case .blocked: return NativeTokens.warning
        case .idle, .done: return current ? NativeTokens.accent : NativeTokens.dotIdle
        }
    }

    var body: some View {
        Circle()
            .fill(color)
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
    /// Under a finished group row the right slot is the run's duration ("41m"), as the completed
    /// board draws it; in a live group a finished sibling still reads "done".
    var inFinishedGroup = false
    let action: () -> Void
    @State private var hovering = false

    /// The branch glyph replaces the dot and carries the state colour (board: sidebar nesting).
    private var glyphColor: Color {
        if child.needsAttention { return NativeTokens.warning }
        switch child.state {
        case "running", "queued": return NativeTokens.success
        case "failed", "stopped", "rejected": return NativeTokens.danger
        default: return selected ? NativeTokens.accent : NativeTokens.dotIdle
        }
    }

    /// Right slot: "needs you" / "done" / the failure state, or the live elapsed "37m".
    private var trailing: String {
        if child.needsAttention { return "needs you" }
        let elapsed = nativeSubagentElapsed(child, now: Date()).map(nativeSubagentShortDuration)
        if child.isTerminal { return child.state == "complete" ? (inFinishedGroup ? elapsed ?? "done" : "done") : child.state }
        return elapsed ?? ""
    }

    var body: some View {
        HStack(spacing: 8) {
            NativeBranchGlyph(color: glyphColor, size: 12)
                // Tree line from the parent row down the nested children.
                .overlay(alignment: .leading) {
                    NativeTokens.border.frame(width: 1).padding(.vertical, -NativeMetrics.sidebarRowHeight / 2).offset(x: -8)
                }
            Text(child.role ?? child.label)
                .font(NativeFonts.sidebarRow)
                .foregroundStyle(
                    selected ? NativeTokens.text
                        : child.isTerminal ? NativeTokens.textSecondary : NativeTokens.text
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .help(child.attentionText ?? child.label)
            Spacer(minLength: 0)
            // TimelineView keeps the elapsed age moving while the run lives.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(trailing)
                    .font(child.needsAttention ? NativeFonts.sidebarRowStrong : NativeFonts.sidebarMeta)
                    .foregroundStyle(child.needsAttention ? NativeTokens.warningText : child.isTerminal ? NativeTokens.textMuted : NativeTokens.textSecondary)
            }
        }
        .clipped()
        .padding(.leading, 8 + CGFloat(depth + 2) * NativeMetrics.sidebarIndent)
        .padding(.trailing, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? NativeTokens.bgSelected : hovering ? NativeTokens.bgHoverStrong : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(child.role ?? child.label), subagent, \(child.needsAttention ? "needs you" : child.state)")
    }
}

/// One row for a finished subagent group: section caps "↳ 3 SUBAGENTS" with the accent glyph,
/// right "done 11:09" (or "1 failed" in danger). Clicking toggles the child rows.
struct SubagentGroupRow: View {
    let children: [ChildRun]
    let expanded: Bool
    var depth: Int = 0
    let action: () -> Void
    @State private var hovering = false

    static func trailing(_ children: [ChildRun]) -> (text: String, failed: Bool) {
        let failed = children.count { nativeSubagentState($0) == .failed }
        if failed > 0 { return ("\(failed) failed", true) }
        if let ended = children.compactMap(\.endedAt).max() { return ("done \(nativeClockText(ended, meridiem: false))", false) }
        return ("done", false)
    }

    var body: some View {
        let trailing = Self.trailing(children)
        HStack(spacing: 8) {
            NativeBranchGlyph(color: NativeTokens.accent, size: 12)
                .overlay(alignment: .leading) {
                    NativeTokens.border.frame(width: 1).padding(.vertical, -NativeMetrics.sidebarRowHeight / 2).offset(x: -8)
                }
            Text("\(children.count) SUBAGENT\(children.count == 1 ? "" : "S")")
                .font(NativeFonts.sidebarSection).tracking(0.6).foregroundStyle(NativeTokens.textTertiary).lineLimit(1)
            Spacer(minLength: 0)
            Text(trailing.text).font(NativeFonts.sidebarMeta).monospacedDigit()
                .foregroundStyle(trailing.failed ? NativeTokens.dangerText : NativeTokens.textMuted)
        }
        .clipped()
        .padding(.leading, 8 + CGFloat(depth + 2) * NativeMetrics.sidebarIndent)
        .padding(.trailing, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? NativeTokens.bgHoverStrong : Color.clear, in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(children.count) subagents, \(trailing.text)")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// Colored dot; the word beside it (row `done` label, header `blocked 4m`,
/// waiting summary) carries the state for accessibility.
struct StatusMarker: View {
    let status: AgentStatus
    var body: some View { SidebarStatusDot(status: status) }
}

/// 11/600 caps section header with a trailing count (spec page 8).
struct SidebarSectionHeader: View {
    let title: String
    var count: Int? = nil
    var dimmed = false
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 7) {
            Text(title.uppercased())
                .font(NativeFonts.sidebarSection)
                .tracking(0.6)
                .foregroundStyle(dimmed ? NativeTokens.textMuted : NativeTokens.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
            }
            if let trailing { trailing }
        }
        .padding(.horizontal, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .padding(.horizontal, NativeMetrics.sidebarPadding)
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
            SidebarSectionHeader(title: "Automations", count: automations.count)
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
            if let agent, agent.status == .working || agent.status == .blocked {
                SidebarStatusDot(status: agent.status, current: selected)
            } else if agent != nil {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(NativeTokens.success)
                    .frame(width: 7)
            } else {
                Circle()
                    .strokeBorder(NativeTokens.textDisabled, lineWidth: 1)
                    .frame(width: 7, height: 7)
            }
            Text(automation.name)
                .font(NativeFonts.sidebarRow)
                .foregroundStyle(selected ? NativeTokens.text : NativeTokens.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(agent.map { $0.status == .working ? "running" : $0.status == .blocked ? "waiting" : "done" } ?? "stopped")
                .font(NativeFonts.sidebarMeta)
                .foregroundStyle(agent?.status == .blocked ? NativeTokens.warningText : NativeTokens.textMuted)
        }
        .padding(.horizontal, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A stopped automation has no click action (Run Now lives in the context menu),
        // so it gets no hover fill and no button semantics.
        .background(selected ? NativeTokens.bgSelected : hovering && agent != nil ? NativeTokens.bgHoverStrong : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(agent != nil ? .isButton : [])
        .accessibilityAction { action() }
        .accessibilityLabel("\(automation.name), automation, \(agent.map { $0.status == .working ? "running" : $0.status == .blocked ? "waiting" : "done" } ?? "stopped")")
    }
}

/// SHELLS: global terminal workspaces outside every space, for one-off work
/// (logs, htop, scratch dirs). Pinned above the footer, like the mock.
struct ShellsSection: View {
    var vm: ShepherdViewModel
    @State private var hoveringHeader = false

    var body: some View {
        let shells = vm.shellTabs
        SidebarSectionHeader(
            title: "Shells",
            count: shells.isEmpty ? nil : shells.count,
            dimmed: shells.isEmpty,
            trailing: hoveringHeader || shells.isEmpty ? AnyView(
                SidebarPlusButton(help: "New Shell") { vm.addShell() }
            ) : nil
        )
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
                .font(NativeFonts.sidebarRow)
                .foregroundStyle(selected ? NativeTokens.accent : NativeTokens.textMuted)
            Text(label)
                .font(NativeFonts.sidebarRow)
                .foregroundStyle(selected ? NativeTokens.text : NativeTokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let process {
                Text("· \(process)")
                    .font(NativeFonts.sidebarRow)
                    .foregroundStyle(NativeTokens.successText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let badge {
                Text(badge)
                    .font(NativeFonts.sidebarMeta)
                    .foregroundStyle(NativeTokens.textMuted)
                    .transition(.opacity)
            }
        }
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeOut(duration: 0.12),
            value: badge
        )
        .padding(.horizontal, 8)
        .frame(height: NativeMetrics.sidebarRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? NativeTokens.bgSelected : hovering ? NativeTokens.bgHoverStrong : Color.clear,
                    in: RoundedRectangle(cornerRadius: Radius.xs))
        .padding(.horizontal, NativeMetrics.sidebarPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), shell")
    }
}

/// The 16pt "+" that appears on hover in section and space headers. A real button
/// (label + button trait) rather than a tappable glyph, per spec §7.
struct SidebarPlusButton: View {
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NativeTokens.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
