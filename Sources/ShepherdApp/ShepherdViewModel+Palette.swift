import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The ⌘K command palette: agent and space lifecycle on the keyboard instead
/// of a menu bar. Items are destinations (agents, spaces, subagent
/// runs) plus the commands the menus expose, fuzzy-filtered by PaletteSearch.
@MainActor
extension ShepherdViewModel {
    var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = []
        let keys = KeybindingsStore.shared

        // Commands.
        items.append(PaletteItem(id: "action.newAgent", kind: .action("newAgent"), section: .commands,
                                 title: "New thread", subtitle: newThreadPlaceName.map(Self.newThreadContext),
                                 shortcut: keys.display(.newAgent), icon: "plus"))
        // The New thread page's project: what the sidebar's space rows offered.
        if shownDestination == .newThread, let place = newThread.place, place.host == nil,
           let space = state.spaces.first(where: { $0.id == place.space }) {
            items.append(PaletteItem(id: "action.renameSpace", kind: .action("renameSpace"), section: .commands,
                                     title: "Rename space…", subtitle: space.name, icon: "pencil"))
            items.append(PaletteItem(id: "action.removeSpace", kind: .action("removeSpace"), section: .commands,
                                     title: "Remove space…", subtitle: space.name, icon: "trash"))
        }
        items.append(PaletteItem(id: "action.newAgentOptions", kind: .action("newAgentOptions"), section: .commands,
                                 title: "New agent with options…", shortcut: keys.display(.newAgentOptions),
                                 icon: "slider.horizontal.3"))
        items.append(PaletteItem(id: "action.newSpace", kind: .action("newSpace"), section: .commands,
                                 title: "New space…", shortcut: keys.display(.newSpace), icon: "square.stack"))
        for connection in remoteHosts.connections where connection.phase == .connected {
            items.append(PaletteItem(id: "action.newRemoteSpace.\(connection.id.uuidString)",
                                     kind: .remoteSpace(hostID: connection.id), section: .commands,
                                     title: "New space on \(connection.config.name)…", subtitle: "remote",
                                     icon: "dot.radiowaves.left.and.right"))
        }
        items.append(PaletteItem(id: "action.toggleSidebar", kind: .action("toggleSidebar"), section: .commands,
                                 title: isSidebarVisible ? "Hide sidebar" : "Show sidebar",
                                 shortcut: keys.display(.toggleSidebar), icon: "sidebar.left"))
        items.append(PaletteItem(id: "action.settings", kind: .action("settings"), section: .commands,
                                 title: "Settings…", shortcut: "⌘,", icon: "gearshape"))
        for target in remoteWorktreeOperationIDs.keys {
            items.append(PaletteItem(id: "operation.\(target.hostID).\(target.agentID)",
                                     kind: .remoteOperation(hostID: target.hostID, agentID: target.agentID),
                                     section: .commands, title: "Check remote worktree operation",
                                     subtitle: remoteHosts.connections.first { $0.id == target.hostID }?.config.name,
                                     icon: "arrow.triangle.branch"))
        }

        // This thread: what can be done to the agent on screen.
        let actionAgent = selectedRemoteAgent.map { remoteAgent($0) } ?? selectedAgent
        if let agent = actionAgent {
            items.append(PaletteItem(id: "action.rename", kind: .action("rename"), section: .thisThread,
                                     title: "Rename", subtitle: agent.name, shortcut: keys.display(.renameAgent),
                                     icon: "pencil"))
            if visibleThread != nil {
                items.append(PaletteItem(id: "action.model", kind: .action("model"), section: .thisThread,
                                         title: "Choose model…", subtitle: visibleThread?.store.model.map(nativeModelShortName),
                                         shortcut: keys.display(.modelPicker), icon: "cpu"))
            }
            items.append(PaletteItem(id: "action.reviewDiff", kind: .action("reviewDiff"), section: .thisThread,
                                     title: "Review diff", subtitle: Self.reviewDiffContext(changedFiles: agent.checkout?.changedFiles),
                                     shortcut: keys.display(.toggleRightPane), icon: "plus.forwardslash.minus"))
            items.append(PaletteItem(id: "action.reviewPR", kind: .action("reviewPR"), section: .thisThread,
                                     title: "Review PR changes", subtitle: selectedPullRequest.map(Self.pullRequestContext),
                                     icon: "arrow.triangle.pull"))
        }
        if let target = unreconciledTerminalTarget {
            let panel = terminalPanels.panel(target.key)
            items += Self.terminalPaletteItems(shown: panel.shown, maximized: panel.shown && panel.maximized,
                                               threadFocused: target.focused == nil || target.focused == target.thread,
                                               keys: keys)
        }

        // Subagents, live and recent.
        for (agentID, children) in childRuns.rows {
            guard let agent = state.agents.first(where: { $0.id == agentID }) else { continue }
            for child in children {
                items.append(PaletteItem(id: "child.\(child.id)", kind: .child(agentID: agentID, child: child),
                                         section: .subagents, title: child.label,
                                         subtitle: Self.subagentContext(child, parent: agent.name),
                                         icon: "arrow.turn.down.right"))
            }
        }
        for (target, children) in remoteChildren {
            guard let connection = remoteHosts.connections.first(where: { $0.id == target.hostID }), connection.phase == .connected,
                  let agent = remoteAgent(target) else { continue }
            for child in children {
                items.append(PaletteItem(id: "remoteChild.\(target.hostID).\(target.agentID).\(child.id)",
                                         kind: .remoteChild(hostID: target.hostID, agentID: target.agentID, child: child),
                                         section: .subagents, title: child.label,
                                         subtitle: Self.subagentContext(child, parent: "\(agent.name) · \(connection.config.name)"),
                                         icon: "arrow.turn.down.right"))
            }
        }

        // Destinations: this Mac's agents in sidebar order (Needs you, then Recents), then remote
        // agents and spaces.
        let spaceNames = Dictionary(state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        for id in localRecentsOrder {
            guard let agent = state.agents.first(where: { $0.id == id }) else { continue }
            let context = spaceNames[agent.spaceID].map {
                Self.agentContext(space: $0, status: agent.status, turnFailed: failedTurns.contains(agent.id),
                                  since: statusSince[agent.id], now: now)
            }
            items.append(PaletteItem(id: "agent.\(agent.id.rawValue)", kind: .agent(agent.id), section: .agents,
                                     title: agent.name, subtitle: context, icon: "bubble.left"))
        }
        for connection in remoteHosts.connections where connection.phase == .connected {
            for agent in connection.state.agents {
                items.append(PaletteItem(id: "remoteAgent.\(connection.id.uuidString).\(agent.id.rawValue)",
                                         kind: .remoteAgent(hostID: connection.id, agentID: agent.id), section: .agents,
                                         title: agent.name, subtitle: connection.config.name, icon: "bubble.left"))
            }
        }
        for space in visibleSpaces {
            items.append(PaletteItem(id: "space.\(space.id.rawValue)", kind: .space(space.id), section: .spaces,
                                     title: space.name, subtitle: (space.path as NSString).abbreviatingWithTildeInPath,
                                     icon: "folder"))
        }
        return items
    }

    /// The Pane menu's terminal commands, for the thread on screen: Show or Hide, New, and
    /// Maximize or Restore, named for what they do now. ⌘D opens a terminal only from the thread
    /// (in a terminal it splits that one), so New shows it only then.
    static func terminalPaletteItems(shown: Bool, maximized: Bool, threadFocused: Bool, keys: KeybindingsStore) -> [PaletteItem] {
        [
            PaletteItem(id: "action.toggleTerminal", kind: .action("toggleTerminal"), section: .thisThread,
                        title: shown ? "Hide terminal" : "Show terminal", shortcut: keys.display(.toggleTerminal),
                        icon: "terminal"),
            PaletteItem(id: "action.newTerminal", kind: .action("newTerminal"), section: .thisThread,
                        title: "New terminal", shortcut: threadFocused ? keys.display(.splitVertical) : nil,
                        icon: "plus.rectangle"),
            PaletteItem(id: "action.maximizeTerminal", kind: .action("maximizeTerminal"), section: .thisThread,
                        title: maximized ? "Restore terminal" : "Maximize terminal", shortcut: keys.display(.maximizeTerminal),
                        icon: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"),
        ]
    }

    /// The project the New thread page last chose, which the palette's New thread starts in.
    private var newThreadPlaceName: String? {
        guard let place = newThread.place else { return nil }
        if let host = place.host {
            return remoteHosts.connections.first { $0.id == host }?.state.spaces.first { $0.id == place.space }?.name
        }
        return state.spaces.first { $0.id == place.space }?.name
    }

    /// The pull request the on-screen agent's review found (its Changes engine's overview).
    private var selectedPullRequest: ChangesPullRequest? {
        if let target = selectedRemoteAgent { return remoteReviews[target]?.overview?.pullRequest }
        guard let id = selectedAgentID else { return nil }
        return reviewSessions.values.first { $0.agentID == id }?.overview?.pullRequest
    }

    /// "in Shepherd/".
    static func newThreadContext(_ space: String) -> String { "in \(space)/" }

    /// "working tree · 4 files"; "working tree" until the host has read the checkout.
    static func reviewDiffContext(changedFiles: Int?) -> String {
        guard let changedFiles else { return "working tree" }
        return "working tree · \(changedFiles) file\(changedFiles == 1 ? "" : "s")"
    }

    /// "PR #24" ("PR #24 draft").
    static func pullRequestContext(_ pullRequest: ChangesPullRequest) -> String { "PR \(pullRequest.label)" }

    /// "payments · running · 8m": the space, the status word, and a working agent's time in it.
    static func agentContext(space: String, status: AgentStatus, turnFailed: Bool, since: Date?, now: Date) -> String {
        let word = AgentRow.statusWord(status, turnFailed: turnFailed)
        guard status == .working, let since else { return "\(space) · \(word)" }
        return "\(space) · \(word) · \(nativeSubagentShortDuration(now.timeIntervalSince(since)))"
    }

    /// "Fix remote nightly · running 4m" — the parent thread and the run's state.
    private static func subagentContext(_ child: ChildRun, parent: String) -> String {
        let state = nativeSubagentState(child)
        let elapsed = nativeSubagentElapsed(child, now: Date()).map(nativeSubagentShortDuration)
        let status = switch state {
        case .running: elapsed.map { "running \($0)" } ?? "running"
        case .needsYou: "needs you"
        case .done: "done"
        case .failed: "failed"
        }
        return "\(parent) · \(status)"
    }

    /// Agents' current sessions for content search, resolved off the state.
    var paletteSearchTargets: [(id: AgentID, piSessionID: String, cwd: String)] {
        state.agents.map { agent in
            let cwd = state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd
                ?? state.spaces.first { $0.id == agent.spaceID }?.path
                ?? NSHomeDirectory()
            return (agent.id, agent.effectivePiSessionID, cwd)
        }
    }

    /// Rows for agents whose *session content* matched, in their own "fuzzy
    /// matches" section, deduped against title-matched thread rows.
    func paletteContentRows(matches: [PaletteContentSearch.Match], excluding existing: Set<String>) -> [PaletteItem] {
        matches.compactMap { match in
            let id = "agent.\(match.agentID.rawValue)"
            guard !existing.contains(id),
                  let agent = state.agents.first(where: { $0.id == match.agentID }) else { return nil }
            let space = state.spaces.first { $0.id == agent.spaceID }
            return PaletteItem(
                id: "fuzzy.\(match.agentID.rawValue)",
                kind: .agent(agent.id),
                section: .conversations,
                title: agent.name,
                subtitle: space?.name,
                icon: "text.magnifyingglass",
                contentSnippet: match.snippet
            )
        }
    }

    func runPaletteItem(_ item: PaletteItem) {
        showCommandPalette = false
        switch item.kind {
        case .agent(let id):
            selectAgent(id)
        case .space(let id):
            selectSpace(id)
        case .child(let agentID, let child):
            openChildInspector(agentID: agentID, child: child)
        case .remoteAgent(let hostID, let agentID):
            selectRemoteAgent(hostID: hostID, agentID: agentID)
        case .remoteChild(let hostID, let agentID, let child):
            openRemoteChild(RemoteAgentRef(hostID: hostID, agentID: agentID), child: child)
        case .remoteOperation(let hostID, let agentID):
            remoteWorktreeSheet = RemoteAgentRef(hostID: hostID, agentID: agentID)
        case .remoteSpace(let hostID):
            remoteSpacePickerHostID = hostID
        case .action(let action):
            switch action {
            case "newAgent": openNewThread()
            case "renameSpace": spaceRenameTarget = newThread.place?.space
            case "removeSpace": spaceDeleteTarget = newThread.place?.space
            case "newAgentOptions": showNewAgentSheet = true
            case "newSpace": addSpaceFromPanel()
            case "rename": renameSelectedAgent()
            case "model": sendThreadCommand(.modelPicker)
            case "toggleSidebar": toggleSidebar()
            case "settings": showSettings = true
            case "reviewDiff": openUserReview()
            case "reviewPR": openUserPRReview()
            case "toggleTerminal": toggleTerminalPanel()
            case "newTerminal": newTerminalTab()
            case "maximizeTerminal": toggleTerminalMaximized()
            default: break
            }
        }
    }
}
