import Foundation
import AppKit
import SwiftUI
import ShepherdCore
import ShepherdSessions

extension ShepherdViewModel {
    // MARK: Spaces

    /// Every "new space" affordance opens the app's own directory browser
    /// (RootView presents it); local and remote are the same UI.
    func addSpaceFromPanel() {
        spacePickerTarget = .local
    }

    func importExistingWorktreeFromPanel(in spaceID: SpaceID) {
        guard let space = state.spaces.first(where: { $0.id == spaceID }) else { return }
        spacePickerTarget = .importWorktree(WorktreeImportTarget(
            spaceID: spaceID,
            startPath: GitWorktree.importDirectory(repo: space.path)
        ))
    }

    @discardableResult
    func importExistingCheckout(at url: URL, into spaceID: SpaceID? = nil) async -> AgentID? {
        let identity: GitWorktree.Identity
        do {
            identity = try await Task.detached(priority: .userInitiated) {
                try GitWorktree.identity(at: url.path)
            }.value
        } catch {
            NSLog("Shepherd: worktree import failed: \(error.localizedDescription)")
            NSSound.beep()
            return nil
        }

        let space: Space
        if let spaceID {
            guard let selected = state.spaces.first(where: { $0.id == spaceID }),
                  (try? GitWorktree.primaryCheckout(at: selected.path)) == identity.repo else {
                NSLog("Shepherd: imported worktree does not belong to the selected space")
                NSSound.beep()
                return nil
            }
            space = selected
        } else if let existing = state.spaces.first(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardized.path == identity.repo
        }) {
            space = existing
        } else {
            guard let id = await addSpace(
                at: URL(fileURLWithPath: identity.repo),
                createInitialAgent: false
            ), let added = state.spaces.first(where: { $0.id == id }) else { return nil }
            space = added
        }

        if let existing = state.agents.first(where: { $0.worktreePath == identity.path }) {
            selectAgent(existing.id)
            return existing.id
        }

        let config = NewAgentConfig(
            spaceID: space.id,
            workingDirectory: identity.path,
            model: settings.agentDefaults.model,
            thinking: settings.agentDefaults.thinking,
            initialPrompt: nil,
            initialName: (identity.branch as NSString).lastPathComponent,
            worktreeBranch: identity.branch,
            worktreeBase: identity.base,
            worktreePath: identity.path
        )
        do {
            let id = try await startAgent(config, selectAfter: false)
            selectAgent(id)
            return id
        } catch {
            NSLog("Shepherd: imported worktree agent failed: \(error)")
            NSSound.beep()
            return nil
        }
    }

    @discardableResult
    func addSpace(at url: URL, createInitialAgent: Bool = true) async -> SpaceID? {
        let path = url.path
        let space = Space(name: url.lastPathComponent, path: path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: path)))
        do {
            try await server.addSpace(space, withTab: tab)
        } catch {
            NSLog("Shepherd: add space failed: \(error)")
            NSSound.beep()
            return nil
        }
        // The atomic server mutation publishes one canonical snapshot. Adopt
        // it here too because the callback may arrive after this await.
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
        selectSpace(space.id)
        if createInitialAgent {
            // Normal sidebar/menu creation hires one worker immediately. The
            // New Agent sheet opts out and starts exactly one on submit.
            quickCreateAgent(in: space.id)
        }
        return space.id
    }

    func selectAppearance(_ mode: AppearanceMode, systemColorScheme: ColorScheme) {
        let theme = themeManager.target(for: mode, systemColorScheme: systemColorScheme)
        guard mode != themeManager.mode || theme.id != themeManager.current.id else { return }
        if theme.id == themeManager.current.id {
            themeManager.select(mode, systemColorScheme: systemColorScheme)
            themeManager.applyApplicationAppearance()
            return
        }
        applyAppearance(theme) {
            themeManager.select(mode, systemColorScheme: systemColorScheme)
            themeManager.applyApplicationAppearance()
        }
    }

    func systemAppearanceChanged(_ colorScheme: ColorScheme) {
        guard themeManager.mode == .system else { return }
        let theme = themeManager.target(for: .system, systemColorScheme: colorScheme)
        guard theme.id != themeManager.current.id else { return }
        applyAppearance(theme) {
            _ = themeManager.updateSystemColorScheme(colorScheme)
        }
    }

    private func applyAppearance(_ theme: ShepherdTheme, update: () -> Void) {
        do {
            // Write first: running pi processes watch this file and repaint in
            // the same switch that recolors app chrome and terminal surfaces.
            try installPiTheme(theme)
        } catch {
            NSLog("Shepherd: theme update failed: \(error)")
            NSSound.beep()
            return
        }
        update()
        sessions.updateAppearance(theme.terminal)
        remoteHosts.updateAppearance(theme.terminal)
    }

    /// Surface-config changes (terminal font, custom keybinds) apply to
    /// every live ghostty surface in place, exactly like theme changes —
    /// no surface replacement, no replay, no blank panes.
    func rebuildSurfaces() {
        sessions.updateSurfaceConfiguration()
        remoteHosts.updateSurfaceConfiguration()
    }

    /// Reset all user-facing preferences in one place. Workspace state is
    /// intentionally untouched. The generated pi theme is written before the
    /// fresh terminal surfaces are built so running pi processes see the same
    /// palette as Shepherd's chrome.
    func resetSettings() {
        let theme = themeManager.resetTarget
        do {
            // The pi file is the external side effect. Write it first so a
            // failed install leaves every in-memory and persisted preference
            // untouched.
            try installPiTheme(theme)
        } catch {
            NSLog("Shepherd: default theme update failed: \(error)")
            NSSound.beep()
            return
        }
        settings.resetToDefaults()
        keybindings.resetAll()
        _ = themeManager.resetToDefault()
        themeManager.applyApplicationAppearance()
        rebuildSurfaces()
    }

    // MARK: Quick create (⌘N)

    /// ⌘N: hire a worker instantly in the current space's checkout — pi's own
    /// model/thinking defaults and no prompt. ⌘⇧N opens the sheet. Falls back
    /// to the sheet when there is no space yet or creation fails.
    func quickCreateAgent() {
        if let selectedRemoteAgent {
            guard let connection = remoteHosts.connections.first(where: { $0.id == selectedRemoteAgent.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == selectedRemoteAgent.agentID }),
                  let space = connection.state.spaces.first(where: { $0.id == agent.spaceID }) else {
                NSSound.beep()
                return
            }
            let config = Self.quickAgentConfig(for: space, defaults: settings.agentDefaults)
            Task {
                do {
                    try await createRemoteAgent(
                        hostID: selectedRemoteAgent.hostID,
                        spaceID: config.spaceID,
                        cwd: config.workingDirectory,
                        model: config.model,
                        thinking: config.thinking,
                        initialPrompt: nil
                    )
                } catch {
                    NSLog("Shepherd: remote quick create failed: \(error)")
                    showNewAgentSheetForRemote(hostID: selectedRemoteAgent.hostID, spaceID: space.id)
                }
            }
            return
        }
        quickCreateAgent(in: nil)
    }

    /// The space header's `+`: hire a worker in that specific space.
    func quickCreateAgent(in spaceID: SpaceID?) {
        let target = spaceID.flatMap { id in state.spaces.first { $0.id == id } }
        guard let space = target ?? selectedSpace ?? visibleSpaces.first else {
            showNewAgentSheet = true
            return
        }
        let config = Self.quickAgentConfig(for: space, defaults: settings.agentDefaults)
        Task {
            do {
                try await startAgent(config)
            } catch {
                NSLog("Shepherd: quick create failed: \(error)")
                showNewAgentSheet = true
            }
        }
    }

    /// Pure construction kept separate from process startup so the shortcut's
    /// shared-checkout contract can be regression-tested without spawning pi.
    static func quickAgentConfig(
        for space: Space,
        defaults: AgentDefaults = .piDefaults
    ) -> NewAgentConfig {
        NewAgentConfig(
            spaceID: space.id,
            workingDirectory: space.path,
            model: defaults.model,
            thinking: defaults.thinking,
            initialPrompt: nil
        )
    }

    /// The name an agent wears until pi's namer proposes a real title: its
    /// opening prompt, collapsed to one line and truncated on a word boundary.
    /// ⌘N agents have no prompt, so they start as "New agent".
    static func provisionalName(for prompt: String?) -> String {
        let flattened = (prompt ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flattened.isEmpty else { return "New agent" }
        let limit = 48
        guard flattened.count > limit else { return flattened }
        let clipped = flattened.prefix(limit)
        // Prefer cutting at the last space so the label never ends mid-word.
        let stem = clipped.lastIndex(of: " ").map { clipped[..<$0] } ?? clipped
        return stem.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Quiet hint under the tree when there are spaces but no agents.
    var agentsHintText: String? {
        guard state.agents.isEmpty, !state.spaces.isEmpty else { return nil }
        return "no agents yet · \(keybindings.display(.newAgent))"
    }

    // MARK: New agent

    func sessionCaption() async -> String {
        let count = await server.listSessions().count
        return "\(count) session\(count == 1 ? "" : "s") running"
    }

    /// Create and spawn an agent. `selectAfter: false` (remote requests)
    /// leaves the host GUI's selection and window focus alone — an agent
    /// created from another Mac must not yank the host user's keyboard.
    @discardableResult
    func startAgent(_ config: NewAgentConfig, selectAfter: Bool = true) async throws -> AgentID {
        guard let space = state.spaces.first(where: { $0.id == config.spaceID }) else {
            throw AgentStartFailure(message: "space no longer exists")
        }
        let cwd = (config.workingDirectory as NSString).expandingTildeInPath
        let name = config.initialName ?? Self.provisionalName(for: config.initialPrompt)
        let agentID = AgentID()
        // A new agent is exactly its pi pane. Extra panes are the agent's to
        // open (see the panes extension) or the user's via ⌘D — starting
        // split put an idle shell in front of every new agent.
        let primary = LeafPane(cwd: cwd, agentID: agentID)
        let order = (state.tabs.filter { $0.spaceID == space.id }.map(\.order).max() ?? -1) + 1
        let tab = Tab(
            spaceID: space.id,
            order: order,
            layout: .leaf(primary)
        )
        let agent = Agent(
            id: agentID,
            name: name,
            spaceID: space.id,
            tabID: tab.id,
            paneID: primary.id,
            status: .idle,
            model: config.model,
            thinkingLevel: config.thinking,
            // Provisional: pi's namer replaces it with a real title from the
            // agent's opening prompt, whether that prompt came from the sheet
            // or was typed into the TUI afterwards (⌘N). With auto-naming off
            // the provisional name is what the agent keeps, so it is final.
            nameIsFinal: !settings.autoNameAgents,
            worktreeBranch: config.worktreeBranch,
            worktreeBase: config.worktreeBase,
            worktreePath: config.worktreePath
        )

        // Reserve before addAgent broadcasts: the broadcast mounts the new
        // pane, whose view would otherwise lazily spawn its own pi process in
        // parallel with createAgentSession below (doubled TUI output).
        sessions.reserveAgentPane(primary.id)
        do {
            try await server.addAgent(agent, withTab: tab)
        } catch {
            sessions.unreserveAgentPane(primary.id)
            throw AgentStartFailure(message: "server rejected agent: \(error)")
        }

        // The mutation broadcasts on the main queue and may be adopted before
        // this continuation resumes. Always replace the mirror with the
        // canonical state; appending here used to duplicate the new agent and
        // tab in SwiftUI, producing undefined view identity and stale surfaces.
        let canonical = server.state
        sessions.stateDidChange(canonical)
        state = canonical

        // Optimistic switch: the agent's pane appears immediately, wearing
        // the launch overlay, and the spawn continues behind it. Selection
        // must not wait on the grid wait + spawn + attach below.
        beginAgentLaunch(agentID)
        if selectAfter {
            selectAgent(agentID)
            // A new agent is something you immediately talk to, so put the
            // keyboard in its terminal — input typed during boot lands in
            // pi's prompt once it draws. Selecting the agent focuses its
            // pane in our own model; this makes sure the window is actually
            // key, which it may not be when the New Agent sheet was just
            // dismissed.
            NSApp.activate(ignoringOtherApps: false)
            window?.makeKeyAndOrderFront(nil)
        }

        do {
            try await sessions.createAgentSession(pane: primary, tab: tab, agent: agent, initialPrompt: config.initialPrompt, isAutomation: config.isAutomation)
        } catch {
            // Lift the overlay so the pane's failure placeholder is visible.
            endAgentLaunch(agentID)
            throw AgentStartFailure(message: "session failed: \(error)")
        }
        return agentID
    }

    // MARK: Launch overlay

    /// How long the launch overlay may cover a pane whose pi never reports
    /// (missing binary, broken shell init, outdated pi): after this the
    /// terminal's real output must win over a tidy boot.
    static let launchOverlayTimeout: Duration = .seconds(15)

    /// Cover `id`'s pane with `AgentLaunchOverlay` until pi's status
    /// extension first reports (`applyAgentStatus`), the spawn fails, or
    /// `launchOverlayTimeout` expires.
    func beginAgentLaunch(_ id: AgentID) {
        launchingAgents.insert(id)
        launchTimeouts[id]?.cancel()
        launchTimeouts[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.launchOverlayTimeout)
            guard !Task.isCancelled else { return }
            self?.endAgentLaunch(id)
        }
    }

    func endAgentLaunch(_ id: AgentID) {
        launchTimeouts.removeValue(forKey: id)?.cancel()
        launchingAgents.remove(id)
    }

    /// The app's main window, for focus handling.
    private var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
    }

}
