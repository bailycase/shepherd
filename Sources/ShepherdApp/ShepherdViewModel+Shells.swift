import Foundation
import AppKit
import ShepherdCore

/// Global shells: plain terminal workspaces outside every space (the
/// sidebar's SHELLS section), for one-off tasks that belong to no project.
/// A shell is an ordinary persisted Tab with `spaceID == nil` — its layout,
/// splits, and ⌘D behavior are exactly a space workspace's. The processes
/// die with the app like every session; the layout persists and respawns.
@MainActor
extension ShepherdViewModel {
    /// SHELLS rows in sidebar order.
    var shellTabs: [Tab] {
        state.tabs.filter(\.isShell).sorted { $0.order < $1.order }
    }

    func selectShell(_ id: TabID) {
        guard state.tabs.contains(where: { $0.id == id && $0.isShell }) else { return }
        inspectingAgentID = nil
        selectedRemoteAgent = nil
        selectedShellID = id
        focusedPaneID = restoredFocus(forTab: id, fallback: nil)
    }

    /// The `+` in the SHELLS header: a new shell in the home directory,
    /// selected immediately. Named after its cwd until renamed. `running`
    /// rides the restore-command path: the command is typed into the fresh
    /// shell — visible and cancelable, not a hidden exec (the worktree setup
    /// wizard uses this for `gh auth login`).
    func addShell(named name: String? = nil, running command: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let order = (shellTabs.map(\.order).max() ?? -1) + 1
        let tab = Tab(
            spaceID: nil,
            order: order,
            layout: .leaf(LeafPane(cwd: home)),
            name: name,
            nameIsFinal: name != nil,
            restoreCommand: command
        )
        state.tabs.append(tab)
        sessions.stateDidChange(state)
        enqueuePersistence("add shell") { try await $0.addTab(tab) }
        selectShell(tab.id)
        syncShellProcessTimer()
    }

    func renameShell(_ id: TabID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = state.tabs.firstIndex(where: { $0.id == id && $0.isShell }) else { return }
        state.tabs[index].name = trimmed
        state.tabs[index].nameIsFinal = true
        sessions.stateDidChange(state)
        let tab = state.tabs[index]
        enqueuePersistence("rename shell") { try await $0.updateTab(tab) }
    }

    func deleteShell(_ id: TabID) {
        guard let index = state.tabs.firstIndex(where: { $0.id == id && $0.isShell }) else { return }
        let tab = state.tabs[index]
        for leaf in tab.layout.leaves {
            if let sessionID = leaf.sessionID { server.killSession(sessionID) }
            sessions.detachPane(leaf.id)
        }
        state.tabs.remove(at: index)
        if selectedShellID == id {
            selectedShellID = shellTabs.first?.id
        }
        sessions.stateDidChange(state)
        enqueuePersistence("delete shell") { try await $0.removeTab(id) }
        syncFocus()
        syncShellProcessTimer()
    }

    /// Poll the foreground process of every shell's pane while shells exist,
    /// so rows can read `$ ~ · pi`. 2s cadence; two syscalls per shell.
    func syncShellProcessTimer() {
        if shellTabs.isEmpty {
            shellProcessTimer?.invalidate()
            shellProcessTimer = nil
            if !shellProcesses.isEmpty { shellProcesses = [:] }
            return
        }
        guard shellProcessTimer == nil else { return }
        shellProcessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshShellProcesses() }
        }
        refreshShellProcesses()
    }

    private func refreshShellProcesses() {
        let targets = shellTabs.compactMap { tab -> (TabID, SessionID)? in
            sessions.liveSession(forPane: tab.layout.firstLeaf.id).map { (tab.id, $0) }
        }
        guard !targets.isEmpty else {
            if !shellProcesses.isEmpty { shellProcesses = [:] }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var next: [TabID: String] = [:]
            for (tabID, sessionID) in targets {
                if let name = await self.server.foregroundProcessName(sessionID: sessionID) {
                    next[tabID] = name
                }
                if let cwd = await self.server.foregroundWorkingDirectory(sessionID: sessionID) {
                    await self.updateShellWorkingDirectory(tabID: tabID, cwd: cwd)
                }
                await self.recordShellRestoreCommand(tabID: tabID, sessionID: sessionID)
            }
            if next != self.shellProcesses { self.shellProcesses = next }
        }
    }

    /// Track what each shell is running so relaunch can restart it. Only
    /// persists on change; a bare prompt clears it.
    private func recordShellRestoreCommand(tabID: TabID, sessionID: SessionID) async {
        let commandLine = await server.foregroundCommandLine(sessionID: sessionID)
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID && $0.isShell }) else { return }
        let shellName = (AppSettings.shared.shellPath as NSString).lastPathComponent
        // The login shell itself means "at a prompt": nothing to restore.
        let restore = commandLine.flatMap { line -> String? in
            let name = line.split(separator: " ").first.map(String.init) ?? line
            return name == shellName || name.isEmpty ? nil : line
        }
        guard state.tabs[index].restoreCommand != restore else { return }
        state.tabs[index].restoreCommand = restore
        let tab = state.tabs[index]
        sessions.stateDidChange(state)
        enqueuePersistence("shell restore command") { try await $0.updateTab(tab) }
    }

    /// Trailing process label for a shell row ("pi", "htop"); nil at a bare
    /// prompt — the user's login shell name is noise, not signal.
    func shellProcessLabel(for id: TabID) -> String? {
        guard let name = shellProcesses[id] else { return nil }
        let shellName = (AppSettings.shared.shellPath as NSString).lastPathComponent
        return name == shellName || name.isEmpty ? nil : name
    }

    /// Keycap text for a shell row while the shell-digit modifiers are held
    /// ("⌃1", "⌥⌘2"), from the user's configured chord. Nil when hidden or
    /// past the ninth shell.
    func shellShortcutBadge(for id: TabID) -> String? {
        guard showShellShortcutBadges,
              let index = shellTabs.prefix(9).firstIndex(where: { $0.id == id }) else { return nil }
        var chord = KeybindingsStore.shared.chord(for: .shellDigits)
        chord.key = "\(index + 1)"
        return chord.display
    }

    /// Rename a space's sidebar label. Display-only: the checkout path (and
    /// everything derived from it — nesting, cwds, sessions) is untouched.
    func renameSpace(_ id: SpaceID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = state.spaces.firstIndex(where: { $0.id == id }),
              state.spaces[index].name != trimmed else { return }
        state.spaces[index].name = trimmed
        sessions.stateDidChange(state)
        let space = state.spaces[index]
        enqueuePersistence("rename space") { try await $0.updateSpace(space) }
    }

    /// Delete a space and everything in it (agents, layouts, inspector
    /// tabs, sessions). Spaces nested under it by path are independent
    /// entities and survive — they re-root in the sidebar's derived forest.
    func deleteSpace(_ id: SpaceID) {
        guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
        let doomedAgents = Set(state.agents.filter { $0.spaceID == id }.map(\.id))
        let doomedTabs = state.tabs.filter { tab in
            tab.spaceID == id || tab.inspectorFor.map(doomedAgents.contains) == true
        }

        // Detach views before the server kills processes (same ordering as
        // deleteAgent: no exit callback may race a half-removed UI tree).
        for tab in doomedTabs {
            for leaf in tab.layout.leaves {
                sessions.detachPane(leaf.id)
            }
        }

        let doomedTabIDs = Set(doomedTabs.map(\.id))
        state.spaces.remove(at: index)
        state.agents.removeAll { doomedAgents.contains($0.id) }
        state.tabs.removeAll { doomedTabIDs.contains($0.id) }
        for agentID in doomedAgents {
            childRuns.clear(agent: agentID)
            selectionHistory.removeAll { $0 == agentID }
            collapsedChildren.remove(agentID)
            inspectedChild.removeValue(forKey: agentID)
            if inspectingAgentID == agentID { inspectingAgentID = nil }
        }
        collapsedSpaces.remove(id)
        if selectedAgentID.map(doomedAgents.contains) == true {
            selectedAgentID = nil
        }
        if selectedSpaceID == id {
            selectedSpaceID = state.spaces.first?.id
            if selectedAgentID == nil {
                selectedAgentID = state.agents.first { $0.spaceID == selectedSpaceID }?.id
            }
        }
        sessions.stateDidChange(state)
        syncFocus()
        enqueuePersistence("space deletion") { try await $0.deleteSpace(id) }
    }

    /// Update the shell's tracked cwd. Automatically-derived names are kept
    /// in sync; explicit renames (nameIsFinal equivalent) are preserved.
    private func updateShellWorkingDirectory(tabID: TabID, cwd: String) async {
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID && $0.isShell }) else { return }
        let tab = state.tabs[index]
        let oldCwd = tab.layout.firstLeaf.cwd
        guard oldCwd != cwd else { return }
        state.tabs[index].layout = tab.layout.updatingLeaf(tab.layout.firstLeaf.id) { $0.cwd = cwd }
        // nil is the automatic-title marker. Keep explicit user renames intact;
        // also migrate the old default "~" marker to automatic behavior.
        if !tab.nameIsFinal { state.tabs[index].name = nil }
        let updated = state.tabs[index]
        sessions.stateDidChange(state)
        enqueuePersistence("shell cwd") { try await $0.updateTab(updated) }
    }

    /// Display label: explicit name, else the cwd with at most two trailing
    /// directory components (for example `~/Projects/shepherd`).
    static func shellLabel(_ tab: Tab) -> String {
        if let name = tab.name, !name.isEmpty { return name }
        return shellLabel(for: tab.layout.firstLeaf.cwd)
    }

    private static func shellLabel(for cwd: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let display = expanded == home ? "~" : (expanded.hasPrefix(home + "/") ? "~" + expanded.dropFirst(home.count) : expanded)
        if display == "~" { return display }
        let prefix = display.hasPrefix("~/") ? "~/" : (display.hasPrefix("/") ? "/" : "")
        let body = display.dropFirst(prefix.count)
        let parts = body.split(separator: "/")
        return prefix + parts.suffix(2).joined(separator: "/")
    }
}
