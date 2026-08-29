import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol

/// The ⌘K command palette: agent and space lifecycle on the keyboard instead
/// of a menu bar. Items are destinations (agents, spaces, shells, subagent
/// runs) plus the commands the menus expose, fuzzy-filtered by PaletteSearch.
@MainActor
extension ShepherdViewModel {
    var paletteItems: [PaletteItem] {
        var items: [PaletteItem] = []
        let keys = KeybindingsStore.shared

        // Commands first, matching the mock's ordering.
        if let space = selectedSpace ?? state.spaces.first {
            items.append(PaletteItem(
                id: "action.newAgent",
                kind: .action("newAgent"),
                section: .commands,
                title: "new agent in \(space.name)/",
                shortcut: keys.display(.newAgent)
            ))
        }
        items.append(PaletteItem(
            id: "action.newAgentOptions",
            kind: .action("newAgentOptions"),
            section: .commands,
            title: "new agent with options…",
            shortcut: keys.display(.newAgentOptions)
        ))
        items.append(PaletteItem(
            id: "action.newSpace",
            kind: .action("newSpace"),
            section: .commands,
            title: "new space…",
            shortcut: keys.display(.newSpace)
        ))
        items.append(PaletteItem(
            id: "action.importCheckout",
            kind: .action("importCheckout"),
            section: .commands,
            title: "import existing worktree…"
        ))
        items.append(PaletteItem(
            id: "action.newShell",
            kind: .action("newShell"),
            section: .commands,
            title: "new shell",
            shortcut: keys.display(.newShell)
        ))
        for connection in remoteHosts.connections where connection.phase == .connected {
            items.append(PaletteItem(
                id: "action.newRemoteSpace.\(connection.id.uuidString)",
                kind: .remoteSpace(hostID: connection.id),
                section: .commands,
                title: "new space on ⌁ \(connection.config.name)…"
            ))
        }
        if let agent = selectedAgent {
            items.append(PaletteItem(
                id: "action.rename",
                kind: .action("rename"),
                section: .commands,
                title: "rename \(agent.name)",
                shortcut: keys.display(.renameAgent)
            ))
        }
        // Settings is omitted: opening a Window scene needs the SwiftUI
        // environment's openWindow, which a view-model action cannot reach
        // (the ⌘, chord and app menu already cover it).

        // Remote agents are destinations too — same rows as the sidebar's
        // REMOTE section, reachable from the keyboard.
        for connection in remoteHosts.connections where connection.phase == .connected {
            for agent in connection.state.agents {
                items.append(PaletteItem(
                    id: "remoteAgent.\(connection.id.uuidString).\(agent.id.rawValue)",
                    kind: .remoteAgent(hostID: connection.id, agentID: agent.id),
                    section: .threads,
                    title: agent.name,
                    subtitle: "agent · ⌁ \(connection.config.name)"
                ))
            }
        }

        // Destinations: agents (sidebar order), spaces, shells, live children.
        for agent in orderedAgents {
            let space = state.spaces.first { $0.id == agent.spaceID }
            items.append(PaletteItem(
                id: "agent.\(agent.id.rawValue)",
                kind: .agent(agent.id),
                section: .threads,
                title: agent.name,
                subtitle: space.map { "agent · \($0.name)" } ?? "agent"
            ))
        }
        for space in visibleSpaces {
            items.append(PaletteItem(
                id: "space.\(space.id.rawValue)",
                kind: .space(space.id),
                section: .spaces,
                title: space.name,
                subtitle: "space"
            ))
        }
        for shell in shellTabs {
            items.append(PaletteItem(
                id: "shell.\(shell.id.rawValue)",
                kind: .shell(shell.id),
                section: .shells,
                title: Self.shellLabel(shell),
                subtitle: "shell"
            ))
        }
        for (agentID, children) in childRuns.rows {
            guard let agent = state.agents.first(where: { $0.id == agentID }) else { continue }
            for child in children {
                items.append(PaletteItem(
                    id: "child.\(child.id)",
                    kind: .child(agentID: agentID, child: child),
                    section: .subagents,
                    title: child.label,
                    subtitle: "subagent · \(agent.name)"
                ))
            }
        }
        return items
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
                section: .fuzzyMatches,
                title: agent.name,
                subtitle: space.map { "agent · \($0.name)" } ?? "agent",
                contentSnippet: match.snippet
            )
        }
    }

    /// ⌘digit while the palette is open: run the nth visible row. The
    /// palette view keeps `paletteVisibleRows` current with its filter.
    func runPaletteQuickPick(_ digit: Int) {
        let rows = paletteVisibleRows
        guard rows.indices.contains(digit - 1) else { return }
        runPaletteItem(rows[digit - 1])
    }

    func runPaletteItem(_ item: PaletteItem) {
        showCommandPalette = false
        switch item.kind {
        case .agent(let id):
            selectAgent(id)
        case .space(let id):
            selectSpace(id)
        case .shell(let id):
            selectShell(id)
        case .child(let agentID, let child):
            openChildInspector(agentID: agentID, child: child)
        case .remoteAgent(let hostID, let agentID):
            selectRemoteAgent(hostID: hostID, agentID: agentID)
        case .remoteSpace(let hostID):
            remoteSpacePickerHostID = hostID
        case .action(let action):
            switch action {
            case "newAgent": quickCreateAgent()
            case "newAgentOptions": showNewAgentSheet = true
            case "newSpace": addSpaceFromPanel()
            case "importCheckout": importExistingCheckoutFromPanel()
            case "newShell": addShell()
            case "rename": agentRenameTarget = selectedAgentID
            default: break
            }
        }
    }
}
