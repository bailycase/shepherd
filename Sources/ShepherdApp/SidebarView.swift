import SwiftUI
import ShepherdDesign
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UniformTypeIdentifiers

/// The sidebar (spec §3, Components board, §9 compact form, §10 subagent nesting): THIS MAC and
/// each remote host as sections, spaces as disclosure rows with their agents nested beneath,
/// subagents nested under their agent, then Automations behind a border.
struct SidebarView: View {
    var vm: ShepherdViewModel

    var body: some View {
        let compact = vm.isRightPaneOpen
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        SidebarSection(
                            title: "This Mac",
                            detail: .count(vm.state.agents.filter { agent in vm.visibleSpaces.contains { $0.id == agent.spaceID } }.count),
                            collapsed: vm.localMachineCollapsed,
                            keycap: vm.remoteHosts.connections.isEmpty ? nil : vm.machineKeycap(forHost: nil),
                            compact: compact,
                            onToggle: { vm.localMachineCollapsed.toggle() },
                            plus: SidebarPlus(help: "New Space…") { vm.addSpaceFromPanel() }
                        )
                        if !vm.localMachineCollapsed {
                            ForEach(vm.spaceTree, id: \.space.id) { group in
                                SpaceSection(vm: vm, space: group.space, agents: group.agents, depth: group.depth, compact: compact)
                                    .id(group.space.id)
                            }
                        }
                        ForEach(vm.remoteHosts.connections) { connection in
                            RemoteHostBlock(vm: vm, connection: connection, compact: compact)
                        }
                    }
                    .padding(.horizontal, Metrics.sidebarPadding)
                    .padding(.bottom, Metrics.sidebarPadding)
                }
                // Keyboard navigation (⌘1–9, ⌘↑/↓, ⌃⇧digits) can land on a row scrolled out of
                // view; the same selection may have just opened a disclosure, so scroll on the
                // next runloop turn once the row exists. The trigger is a counter so re-selecting
                // the same row still scrolls back to it.
                .onChange(of: vm.sidebarRevealRequest) {
                    guard let target = vm.sidebarRevealTarget else { return }
                    DispatchQueue.main.async {
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.12)) {
                            proxy.scrollTo(target)
                        }
                    }
                }
            }

            if !vm.state.automations.isEmpty {
                Tokens.border.frame(height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    AutomationsSection(vm: vm, compact: compact)
                }
                .padding(Metrics.sidebarPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Rows

/// Shared chrome for every sidebar row: height, indent, hover and selection fills, tap, and
/// button semantics. Rows are tap views rather than `Button`s so they can also be dragged.
private struct SidebarRowChrome: ViewModifier {
    let selected: Bool
    let compact: Bool
    var leading: CGFloat = 8
    var interactive = true
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.leading, leading)
            .padding(.trailing, 6)
            .frame(height: compact ? Metrics.sidebarRowHeightCompact : Metrics.sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(selected: selected, hovering: hovering && interactive, radius: compact ? 5 : Radius.sm)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .accessibilityAddTraits(interactive ? .isButton : [])
            .accessibilityAction { action() }
    }
}

extension View {
    fileprivate func sidebarRow(selected: Bool = false, compact: Bool, leading: CGFloat = 8, interactive: Bool = true,
                                action: @escaping () -> Void) -> some View {
        modifier(SidebarRowChrome(selected: selected, compact: compact, leading: leading, interactive: interactive, action: action))
    }
}

/// The hover `+` in section and space headers. A real button with a label (§7).
struct SidebarPlus: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.textTertiary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A machine or block section header: 11/600 caps, trailing count or connection state, and a
/// hover `+`. Clicking toggles the section.
struct SidebarSection: View {
    enum Detail: Equatable {
        case count(Int)
        case state(String, danger: Bool)
        case none
    }

    let title: String
    let detail: Detail
    var collapsed = false
    var keycap: String?
    let compact: Bool
    var onToggle: (() -> Void)?
    var plus: SidebarPlus?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).sectionStyle(compact ? Fonts.sans(10, .semibold) : Fonts.section)
                .opacity(collapsed ? 0.7 : 1)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering, let keycap {
                Text(keycap).font(Fonts.micro).foregroundStyle(Tokens.textMuted)
            }
            switch detail {
            case .count(let count) where count > 0:
                Text("\(count)").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
            case .state(let text, let danger):
                Text(text).font(Fonts.sans(11, .medium)).foregroundStyle(danger ? Tokens.dangerText : Tokens.textMuted)
            default:
                EmptyView()
            }
            if hovering, let plus { plus }
        }
        .padding(.horizontal, 8)
        .padding(.top, compact ? 6 : 10)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onToggle?() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(title), \(collapsed ? "collapsed" : "expanded")")
        .accessibilityAction { onToggle?() }
    }
}

/// One space: a disclosure row with its agents nested beneath.
struct SpaceSection: View {
    var vm: ShepherdViewModel
    let space: Space
    let agents: [Agent]
    /// 0 for a root space; deeper spaces are projects nested by path containment.
    var depth: Int = 0
    let compact: Bool

    private var collapsed: Bool { vm.collapsedSpaces.contains(space.id) }
    private var indent: CGFloat { compact ? Metrics.sidebarIndentCompact : Metrics.sidebarIndent }

    var body: some View {
        SpaceRow(name: space.name, collapsed: collapsed, count: agents.count,
                 blocked: agents.count { $0.status == .blocked }, worktrees: agents.count { $0.worktreeBranch != nil },
                 compact: compact, leading: 8 + CGFloat(depth) * indent,
                 onToggle: { vm.toggleSpaceCollapsed(space.id) },
                 onNewAgent: { vm.quickCreateAgent(in: space.id) })
            .onDrag { NSItemProvider(object: ShepherdViewModel.dragPayload(space: space.id) as NSString) }
            .sidebarDropTarget { payload in vm.dropSpace(payload: payload, on: space.id) }
            .contextMenu {
                Button("New Agent") { vm.quickCreateAgent(in: space.id) }
                Button("Rename…") { vm.spaceRenameTarget = space.id }
                if GitWorktree.isRepo(space.path) {
                    Button("New Worktree…") { vm.worktreeSheetTarget = space.id }
                    Button("Import Existing Worktree…") { vm.importExistingWorktreeFromPanel(in: space.id) }
                }
                Divider()
                Button("Remove Space…", role: .destructive) { vm.spaceDeleteTarget = space.id }
            }
        if !collapsed {
            ForEach(agents) { agent in
                LocalAgentRows(vm: vm, agent: agent, depth: depth, compact: compact)
                    .id(agent.id)
            }
        }
    }
}

struct SpaceRow: View {
    let name: String
    let collapsed: Bool
    let count: Int
    var blocked = 0
    var worktrees = 0
    let compact: Bool
    var leading: CGFloat = 8
    let onToggle: () -> Void
    var onNewAgent: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(Tokens.textTertiary)
                .frame(width: 10)
            Text(name).font(compact ? Fonts.sans(12, .medium) : Fonts.label).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 4)
            if worktrees > 0, !compact {
                Text("⎇\(worktrees)").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                    .help("\(worktrees) worktree agent\(worktrees == 1 ? "" : "s")")
            }
            if hovering, let onNewAgent {
                SidebarPlus(help: "New Agent in \(name)", action: onNewAgent)
            } else if blocked > 0 {
                Text("\(blocked)").font(Fonts.micro).foregroundStyle(Tokens.warningText)
            } else if count > 0 {
                Text("\(count)").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
            }
        }
        .onHover { hovering = $0 }
        .sidebarRow(compact: compact, leading: leading, action: onToggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(count) agents, \(collapsed ? "collapsed" : "expanded")")
    }
}

/// An agent row plus, when it has subagents, their nested rows (or the folded group header).
struct LocalAgentRows: View {
    var vm: ShepherdViewModel
    let agent: Agent
    let depth: Int
    let compact: Bool

    var body: some View {
        let selected = vm.selectedAgentID == agent.id && vm.selectedRemoteAgent == nil
        let children = vm.children(of: agent.id)
        let folded = SubagentFolding.folded(children: children, selected: selected, unfolded: vm.unfoldedSubagentGroups.contains(agent.id))
        AgentRow(agent: agent, selected: selected, compact: compact, depth: depth,
                 badge: vm.shortcutBadge(for: agent.id), statusSince: vm.statusSince[agent.id],
                 subagentCount: folded ? children.count : nil) {
            vm.selectAgent(agent.id)
        }
        .onDrag { NSItemProvider(object: ShepherdViewModel.dragPayload(agent: agent.id) as NSString) }
        .sidebarDropTarget { payload in vm.dropAgent(payload: payload, on: agent.id) }
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
        if !children.isEmpty {
            SubagentRows(children: children, depth: depth, compact: compact, folded: folded,
                         inspected: vm.subagentInspector.runByAgent[agent.id],
                         toggleFold: {
                             if vm.unfoldedSubagentGroups.contains(agent.id) { vm.unfoldedSubagentGroups.remove(agent.id) }
                             else { vm.unfoldedSubagentGroups.insert(agent.id) }
                         },
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
    let agent: Agent
    let selected: Bool
    let compact: Bool
    var depth = 0
    var badge: Int?
    var statusSince: Date?
    var subagentCount: Int?
    var dimmed = false
    let action: () -> Void

    var body: some View {
        let indent = compact ? Metrics.sidebarIndentCompact : Metrics.sidebarIndent
        HStack(spacing: 8) {
            StatusDot(Tokens.statusDot(agent.status, isCurrent: selected), size: compact ? Metrics.statusDotCompact : Metrics.statusDot)
            if agent.worktreeBranch != nil {
                Text("⎇").font(Fonts.micro).foregroundStyle(Tokens.textTertiary)
            }
            Text(agent.name)
                .font(compact ? Fonts.sans(12, selected ? .medium : .regular) : (selected ? Fonts.label : Fonts.labelRegular))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(agent.worktreeBranch.map { "\(agent.name) · worktree \($0)" } ?? agent.name)
            Spacer(minLength: 4)
            if !compact || selected { trailing }
        }
        .sidebarRow(selected: selected, compact: compact, leading: 8 + indent + CGFloat(depth) * indent, action: action)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.name), \(agent.worktreeBranch != nil ? "worktree, " : "")\(Self.statusWord(agent.status))")
    }

    @ViewBuilder private var trailing: some View {
        if let badge {
            Text("⌘\(badge)").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
        } else if agent.status == .blocked {
            Text("needs you").font(Fonts.micro).foregroundStyle(Tokens.warningText).fixedSize()
        } else if let subagentCount {
            Text("\(subagentCount) sub").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
        } else if agent.status == .working, let statusSince {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(SidebarTime.elapsed(since: statusSince, now: context.date)).font(Fonts.micro).foregroundStyle(Tokens.textMuted)
            }
        } else if agent.status == .done {
            Text("done").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
        }
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
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

/// Subagent rows under their agent: branch glyph in the state color, name, and elapsed /
/// "needs you" / duration trailing. A finished group folds behind a disclosure header.
struct SubagentRows: View {
    let children: [ChildRun]
    let depth: Int
    let compact: Bool
    let folded: Bool
    let inspected: String?
    let toggleFold: () -> Void
    let open: (ChildRun) -> Void

    var body: some View {
        let indent = compact ? Metrics.sidebarIndentCompact : Metrics.sidebarIndent
        let leading = 8 + indent * CGFloat(depth + 1) + 10
        let finished = children.allSatisfy(\.isTerminal)
        if finished {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .foregroundStyle(Tokens.textMuted)
                Text(SubagentRows.groupLabel(children)).font(Fonts.micro).foregroundStyle(Tokens.textMuted).lineLimit(1)
            }
            .sidebarRow(compact: compact, leading: leading, action: toggleFold)
            .accessibilityLabel("\(children.count) subagents, \(folded ? "collapsed" : "expanded")")
        }
        if !finished || !folded {
            ForEach(children, id: \.id) { run in
                SubagentRow(run: run, compact: compact, selected: inspected == run.runID, leading: leading) { open(run) }
            }
        }
    }

    static func groupLabel(_ children: [ChildRun]) -> String {
        let count = "\(children.count) subagent\(children.count == 1 ? "" : "s")"
        guard let ended = children.compactMap(\.endedAt).max() else { return count }
        return "\(count) · done \(nativeClockText(ended, meridiem: false))"
    }
}

struct SubagentRow: View {
    let run: ChildRun
    let compact: Bool
    let selected: Bool
    let leading: CGFloat
    let action: () -> Void

    var body: some View {
        let state = nativeSubagentState(run)
        HStack(spacing: 6) {
            // Tree line: the rows hang off their agent.
            Tokens.border.frame(width: 1).frame(maxHeight: .infinity).padding(.trailing, 2)
            BranchGlyph(SubagentStyle.color(state), size: compact ? 12 : 13)
            Text(run.role ?? run.label).font(compact ? Fonts.sans(12) : Fonts.labelRegular).foregroundStyle(Tokens.text).lineLimit(1)
            Spacer(minLength: 4)
            if !compact || selected {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let (text, color) = SubagentStyle.trailing(run, state: state, now: context.date)
                    Text(text).font(Fonts.micro).foregroundStyle(color).fixedSize()
                }
            }
        }
        .sidebarRow(selected: selected, compact: compact, leading: leading, action: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.role ?? run.label), subagent, \(SubagentStyle.word(state))")
    }
}

/// Color and words for a subagent's state, shared by sidebar rows, cards, and the palette.
enum SubagentStyle {
    @MainActor static func color(_ state: NativeSubagentState) -> Color {
        switch state {
        case .running: Tokens.accent
        case .needsYou: Tokens.warning
        case .done: Tokens.success
        case .failed: Tokens.danger
        }
    }

    static func word(_ state: NativeSubagentState) -> String {
        switch state {
        case .running: "running"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        }
    }

    @MainActor static func trailing(_ run: ChildRun, state: NativeSubagentState, now: Date) -> (String, Color) {
        switch state {
        case .needsYou: return ("needs you", Tokens.warningText)
        case .failed: return ("failed", Tokens.dangerText)
        case .running:
            let elapsed = nativeSubagentElapsed(run, now: now).map(nativeSubagentShortDuration) ?? ""
            return (elapsed, Tokens.accentText)
        case .done:
            return (nativeSubagentElapsed(run, now: now).map(nativeSubagentShortDuration) ?? "done", Tokens.textMuted)
        }
    }
}

// MARK: Automations

/// AUTOMATIONS: saved watch prompts run by ordinary agents. Hidden while empty. Compact form is
/// one row with the count.
struct AutomationsSection: View {
    var vm: ShepherdViewModel
    let compact: Bool

    var body: some View {
        let automations = vm.state.automations
        if !automations.isEmpty {
            if compact {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.success).frame(width: 10)
                    Text("Automations").font(Fonts.sans(12)).foregroundStyle(Tokens.text)
                    Spacer(minLength: 4)
                    Text("\(automations.count)").font(Fonts.micro).foregroundStyle(Tokens.textMuted)
                }
                .sidebarRow(compact: true, interactive: false) {}
            } else {
                SidebarSection(title: "Automations", detail: .count(automations.count), compact: false)
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

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let agent, agent.status == .working || agent.status == .blocked {
                    StatusDot(Tokens.statusDot(agent.status, isCurrent: selected))
                } else if agent != nil {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Tokens.success)
                } else {
                    Circle().strokeBorder(Tokens.textDisabled, lineWidth: 1).frame(width: 7, height: 7)
                }
            }
            .frame(width: 10)
            Text(automation.name).font(Fonts.labelRegular).foregroundStyle(Tokens.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(stateWord).font(Fonts.micro)
                .foregroundStyle(agent?.status == .blocked ? Tokens.warningText : Tokens.textMuted)
        }
        .sidebarRow(selected: selected, compact: false, interactive: agent != nil, action: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(automation.name), automation, \(stateWord)")
    }
}

// MARK: Reordering

/// Plain-text drop target for sidebar reordering: a 2pt accent line while a drag hovers, the
/// payload string handed to `perform`, and anything `perform` rejects ignored.
private struct SidebarDropTarget: ViewModifier {
    let perform: (String) -> Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if hovering { Rectangle().fill(Tokens.accent).frame(height: 2) }
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
