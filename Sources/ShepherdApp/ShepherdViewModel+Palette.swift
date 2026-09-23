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
        _ = remoteProjectionRevision
        var items: [PaletteItem] = []
        let keys = KeybindingsStore.shared

        // Commands.
        let creationSpace = selectedRemoteAgent.flatMap { target in
            remoteHosts.connections.first { $0.id == target.hostID }?.state.spaces.first { $0.id == remoteAgent(target)?.spaceID }
        } ?? selectedSpace ?? state.spaces.first
        if let space = creationSpace {
            items.append(PaletteItem(id: "action.newAgent", kind: .action("newAgent"), section: .commands,
                                     title: "New agent", subtitle: "in \(space.name)/",
                                     shortcut: keys.display(.newAgent), icon: "plus"))
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
                                         title: "Choose model…", subtitle: visibleThread?.store.snapshot?.model.map(nativeModelShortName),
                                         shortcut: keys.display(.modelPicker), icon: "cpu"))
            }
            items.append(PaletteItem(id: "action.reviewDiff", kind: .action("reviewDiff"), section: .thisThread,
                                     title: "Review diff", subtitle: "working tree", icon: "plus.forwardslash.minus"))
            items.append(PaletteItem(id: "action.reviewPR", kind: .action("reviewPR"), section: .thisThread,
                                     title: "Review PR changes", icon: "arrow.triangle.pull"))
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

        // Destinations: agents in sidebar order, then remote agents and spaces.
        for agent in orderedAgents {
            let space = state.spaces.first { $0.id == agent.spaceID }
            items.append(PaletteItem(id: "agent.\(agent.id.rawValue)", kind: .agent(agent.id), section: .agents,
                                     title: agent.name, subtitle: space.map { "\($0.name) · \(Self.statusWord(agent.status))" },
                                     icon: "bubble.left"))
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

    private static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle: "idle"
        case .done: "done"
        }
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
            case "newAgent": quickCreateAgent()
            case "newAgentOptions": showNewAgentSheet = true
            case "newSpace": addSpaceFromPanel()
            case "rename": renameSelectedAgent()
            case "model": sendThreadCommand(.modelPicker)
            case "toggleSidebar": toggleSidebar()
            case "settings": showSettings = true
            case "reviewDiff": openUserReview()
            case "reviewPR": openUserPRReview()
            default: break
            }
        }
    }
}
