import Foundation
import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension ShepherdViewModel {
    // MARK: Spaces

    /// Every "new space" affordance opens the app's own directory browser
    /// (RootView presents it); local and remote are the same UI.
    func addSpaceFromPanel() {
        // Under the background host this Mac's spaces are the host's: the in-process server is idle,
        // and a space added to it never reaches the sidebar or the space menu.
        if !ownsWorkspace, localHost == nil, let host = remoteHosts.localHost {
            spacePickerTarget = .host(host.id)
            return
        }
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
            guard let id = await addSpace(at: URL(fileURLWithPath: identity.repo)), let added = state.spaces.first(where: { $0.id == id }) else { return nil }
            space = added
        }

        if let existing = state.agents.first(where: { $0.worktreePath == identity.path }) {
            selectAgent(existing.id)
            return existing.id
        }

        let config = NewAgentConfig(
            spaceID: space.id,
            workingDirectory: identity.path,
            model: settings.defaultModel(piHome: server.pi.home),
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

    /// Adds a project (a space) and opens the New thread page in it (`select: false` leaves the page where it is).
    @discardableResult
    func addSpace(at url: URL, select: Bool = true) async -> SpaceID? {
        let path = url.path
        do { try verifyCheckoutAvailable(path) }
        catch { fail("Couldn’t add the space", error); return nil }
        let reservation = UUID()
        startingCheckoutUsers[reservation] = path
        defer { startingCheckoutUsers.removeValue(forKey: reservation) }
        if let host = localHost {
            // The background host adds it (on top of its tree, as below), and it shows as its push lands.
            do {
                let id = try await remoteHosts.addSpace(hostID: host.id, path: path)
                for _ in 0..<100 where !state.spaces.contains(where: { $0.id == id }) { try await Task.sleep(for: .milliseconds(20)) }
                if select { selectSpace(id) }
                return id
            } catch {
                fail("Couldn’t add the space", error)
                return nil
            }
        }
        let space = Space(name: url.lastPathComponent, path: path)
        do {
            // New projects go on top of the sidebar's project tree.
            try await server.addSpace(space, first: true)
        } catch {
            NSLog("Shepherd: add space failed: \(error)")
            NSSound.beep()
            return nil
        }
        // Adopt the canonical snapshot here too: the callback may arrive after this await.
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
        if select { selectSpace(space.id) }
        return space.id
    }

    /// The Space a Project links for a folder the person chose: the one already registered at that path, else a new one. Neither opens a
    /// thread, so New project and Project settings stay where they are.
    func spaceForProject(at url: URL) async -> SpaceID? {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
        }
        let wanted = canonical(url.path)
        if let existing = server.state.spaces.first(where: { !$0.hidden && canonical($0.path) == wanted }) { return existing.id }
        return await addSpace(at: url, select: false)
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
            // Keep external editors in step with app chrome and terminal surfaces.
            try installThemeMarker(theme)
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
    /// intentionally untouched. Update the external editor marker before changing preferences.
    func resetSettings() {
        let theme = themeManager.resetTarget
        do {
            // Write first so a failed marker update leaves preferences untouched.
            try installThemeMarker(theme)
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

    // MARK: Agent config

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

    // MARK: New agent

    func sessionCaption() async -> String {
        let count = await server.listSessions().count
        return "\(count) session\(count == 1 ? "" : "s") running"
    }

    /// Create and spawn an agent. `selectAfter: false` (remote requests)
    /// leaves the host GUI's selection and window focus alone — an agent
    /// created from another Mac must not yank the host user's keyboard.
    /// `focusWindow: false` selects it without making the window key: the New thread page sends
    /// from the key window already.
    @discardableResult
    func startAgent(_ config: NewAgentConfig, selectAfter: Bool = true, focusWindow: Bool = true) async throws -> AgentID {
        if let host = localHost {
            return try await startHostedAgent(config, host: host, selectAfter: selectAfter, focusWindow: focusWindow)
        }
        guard let space = state.spaces.first(where: { $0.id == config.spaceID }) else {
            throw AgentStartFailure(message: "space no longer exists")
        }
        guard !missingSpaces.contains(space.id), Self.folderExists(config.workingDirectory) else {
            checkMissingSpaces()
            throw AgentStartFailure(message: "\(space.name)'s folder is missing. Locate it or remove the space.")
        }
        try verifyCheckoutAvailable(config.workingDirectory)
        let reservation = UUID()
        startingCheckoutUsers[reservation] = config.workingDirectory
        defer { startingCheckoutUsers.removeValue(forKey: reservation) }
        let agentID = config.reservedAgentID ?? AgentID()
        let opening = OpeningPrompt(config.initialPrompt, images: config.initialImages, agentID: agentID)
        if opening != nil || config.openingReferencesPending {
            sidebarPreparingOpeningTurns.insert(agentID)
            sidebarOpeningTurns.insert(agentID)
        }
        let (agent, tab, primary) = config.thread(id: agentID, in: state, defaultServiceTier: settings.defaultServiceTier)

        // Reserve before addAgent broadcasts: the broadcast mounts the new
        // pane, whose view would otherwise lazily spawn its own pi process in
        // parallel with createAgentSession below (doubled TUI output).
        sessions.reserveAgentPane(primary.id)
        do {
            try await server.addAgent(agent, withTab: tab)
        } catch {
            sessions.unreserveAgentPane(primary.id)
            sidebarPreparingOpeningTurns.remove(agentID)
            sidebarOpeningTurns.remove(agentID)
            throw AgentStartFailure(message: "server rejected agent: \(error)")
        }

        // The mutation broadcasts on the main queue and may be adopted before
        // this continuation resumes. Always replace the mirror with the
        // canonical state; appending here used to duplicate the new agent and
        // tab in SwiftUI, producing undefined view identity and stale surfaces.
        let canonical = server.state
        sessions.stateDidChange(canonical)
        state = canonical
        // A new agent's thread is known to be empty: it draws at once, ready to type into, while
        // pi boots behind it. A resumed session (a forked transcript) is read from its file.
        // Its opening prompt shows at once too, as the row the host's first snapshot will carry.
        if config.piSessionID == nil {
            let empty = PiSessionPreview.empty(
                sessionID: agent.effectivePiSessionID,
                model: config.model ?? PiConfig.defaultModel(in: server.pi.home),
                thinking: config.thinking.rawValue)
            threadStores.store(for: agentID).preview(opening.map { $0.preview(empty) } ?? empty)
        }

        // Optimistic switch: the agent's thread appears immediately in its connecting
        // state while pi boots behind it.
        if selectAfter {
            selectAgent(agentID)
        }
        if selectAfter, focusWindow {
            // A new agent is something you immediately talk to, so the window must be key
            // for its composer to take focus; it may not be when the New Agent sheet was just
            // dismissed.
            NSApp.activate(ignoringOtherApps: false)
            window?.makeKeyAndOrderFront(nil)
        }

        do {
            try await sessions.createAgentSession(pane: primary, tab: tab, agent: agent, openingPrompt: opening, isAutomation: config.isAutomation)
        } catch {
            sidebarPreparingOpeningTurns.remove(agentID)
            sidebarOpeningTurns.remove(agentID)
            throw AgentStartFailure(message: "session failed: \(error)")
        }
        if !config.openingReferencesPending {
            sidebarPreparingOpeningTurns.remove(agentID)
            reconcileSidebarOpeningTurn(agentID)
        }
        return agentID
    }

    /// `startAgent` as the background host's client: the host makes the thread (its worktree, when
    /// `config` names a branch without a checkout; its own folder, for a standalone thread whose
    /// space doesn't exist yet), and it shows and selects here as the host's push lands.
    private func startHostedAgent(_ config: NewAgentConfig, host: RemoteHostStore.Connection,
                                  selectAfter: Bool, focusWindow: Bool) async throws -> AgentID {
        let space = state.spaces.first { $0.id == config.spaceID }
        guard config.designID == nil, config.coordinatorFor == nil, space != nil || config.reservedAgentID != nil else {
            throw AgentStartFailure(message: space == nil ? "space no longer exists" : "Shepherd's background service can't start this kind of thread yet.")
        }
        let id = try await remoteHosts.startThread(hostID: host.id, RemoteThreadStart(
            spaceID: space?.id, cwd: space == nil ? nil : config.workingDirectory, model: config.model, thinking: config.thinking,
            serviceTier: config.serviceTier, initialPrompt: config.initialPrompt, initialImages: config.initialImages,
            name: config.initialName, piSessionID: config.piSessionID, agentID: config.reservedAgentID,
            worktreeBranch: config.worktreeBranch, worktreeBase: config.worktreeBase, worktreePath: config.worktreePath))
        // The prompt shows while the host's pi starts, as the row the host's first snapshot carries.
        let empty = PiSessionPreview.empty(sessionID: "", model: config.model ?? PiConfig.defaultModel(in: server.pi.home),
                                           thinking: config.thinking.rawValue)
        let opening = OpeningPrompt(config.initialPrompt, images: config.initialImages, agentID: id)
        threadStores.store(for: id).preview(opening.map { $0.preview(empty) } ?? empty)
        // ponytail: polls for the host's push (it usually lands before the reply); a push waiter if this shows.
        for _ in 0..<100 where !state.agents.contains(where: { $0.id == id }) { try await Task.sleep(for: .milliseconds(20)) }
        if selectAfter {
            selectAgent(id)
            if focusWindow {
                NSApp.activate(ignoringOtherApps: false)
                window?.makeKeyAndOrderFront(nil)
            }
        }
        return id
    }

    /// The app's main window, for focus handling.
    private var window: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }

}
