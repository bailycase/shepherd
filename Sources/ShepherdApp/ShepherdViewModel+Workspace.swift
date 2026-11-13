import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension ShepherdViewModel {
    /// The workspace follows the sidebar: selected agent → its layout;
    /// otherwise the space's main (first) layout.
    var activeTab: Tab? { workspaceSelection.activeTab }

    /// Which layouts the workspace mounts, and which one shows.
    private var workspaceSelection: WorkspaceSelection {
        WorkspaceSelection(
            state: workspaceStructure,
            selectedSpaceID: selectedSpaceID,
            selectedAgentID: selectedAgentID,
            remoteSelectionActive: selectedRemoteAgent != nil,
            // A Project page left over from before the experiment went off covers nothing.
            destination: projectsEnabled || !isProjectDestination ? destination : nil,
            parkedTabIDs: parkedTabIDs,
            shownTabIDs: shownTabIDs
        )
    }

    /// `mountedTabs` for the current inputs, built once per change: the workspace body and the
    /// parking sweep each ask on every render.
    private var resolvedMountedTabs: [Tab] {
        let selection = workspaceSelection
        if let cached = mountedTabsCache, cached.selection == selection { return cached.tabs }
        let tabs = selection.mountedTabs
        mountedTabsCache = (selection, tabs)
        return tabs
    }

    /// Cold parking bookkeeping, driven from `noteActiveTabVisited` so every
    /// selection path is covered: the newly visible layout is unparked,
    /// recorded as shown and forgotten as hidden; every other mounted layout
    /// that has no hidden timestamp yet gets one now.
    private func noteActiveTabForParking() {
        let active = activeTabID
        if let active {
            parkedTabIDs.remove(active)
            if !shownTabIDs.contains(active) { shownTabIDs.insert(active) }
            tabHiddenSince.removeValue(forKey: active)
        }
        let liveTabIDs = Set(state.tabs.map(\.id))
        for tab in mountedTabs where tab.id != active && tabHiddenSince[tab.id] == nil {
            tabHiddenSince[tab.id] = Date()
        }
        tabHiddenSince = tabHiddenSince.filter { liveTabIDs.contains($0.key) }
        parkedTabIDs = parkedTabIDs.filter { liveTabIDs.contains($0) }
        if !shownTabIDs.isSubset(of: liveTabIDs) { shownTabIDs.formIntersection(liveTabIDs) }
        syncParkSweepTimer()
    }

    /// Park layouts that have been hidden past the delay. Runs only while
    /// a layout that can park (one holding a terminal pane) is hidden and
    /// unparked, so a workspace of thread-only agents pays nothing.
    private func syncParkSweepTimer() {
        let terminalTabs = WorkspaceSelection.terminalTabs(in: state)
        let pending = tabHiddenSince.keys.contains { !parkedTabIDs.contains($0) && terminalTabs.contains($0) }
        guard pending else {
            parkSweepTimer?.invalidate()
            parkSweepTimer = nil
            return
        }
        guard parkSweepTimer == nil else { return }
        parkSweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepColdPanes() }
        }
    }

    func sweepColdPanes(now: Date = Date()) {
        let candidates = WorkspaceSelection.coldParkCandidates(
            hiddenSince: tabHiddenSince, activeTabID: activeTabID, terminalTabs: WorkspaceSelection.terminalTabs(in: state), now: now
        ).subtracting(parkedTabIDs)
        guard !candidates.isEmpty else {
            syncParkSweepTimer()
            return
        }
        parkedTabIDs.formUnion(candidates)
        syncParkSweepTimer()
    }

    /// Called by the workspace view on every active-tab change, which covers all selection
    /// paths: keeps cold-parking bookkeeping current.
    func noteActiveTabVisited() {
        noteActiveTabForParking()
    }

    /// Every layout the workspace keeps mounted (see `WorkspaceSelection`).
    var mountedTabs: [Tab] { resolvedMountedTabs }

    /// The agents whose thread a mounted layout draws, the visible one and the hidden: the threads holding row views
    /// (`NativeThreadStores.mounted`). A layout cold parking or a Project took out, or nobody has shown, holds none. A tab's
    /// thread is the one the deck draws (`AgentLayoutModel.Resolver`): its first agent's, when that agent owns a pane of it.
    func mountedThreadAgents() -> Set<AgentID> {
        var agentsByTab: [TabID: Agent] = [:]
        for agent in state.agents where agentsByTab[agent.tabID] == nil { agentsByTab[agent.tabID] = agent }
        var mounted = Set<AgentID>()
        for tab in mountedTabs {
            guard let agent = agentsByTab[tab.id],
                  tab.layout.leaves.contains(where: { primaryAgent(in: tab, pane: $0, agents: [agent]) != nil }) else { continue }
            mounted.insert(agent.id)
        }
        return mounted
    }

    /// The remote threads that are pages of the remote deck (`RemoteDeckPages`): the ones holding row views, hidden or not.
    func mountedRemoteThreads() -> Set<RemoteAgentRef> {
        var states: [UUID: ShepherdState] = [:]
        for ref in remoteDeckRefs where states[ref.hostID] == nil {
            states[ref.hostID] = remoteHosts.allConnections.first { $0.id == ref.hostID }?.state
        }
        return Set(RemoteDeckPages.pages(shown: remoteDeckRefs, selected: nil, inspecting: nil, states: states).pages)
    }

    /// Whether the person is typing or scrolling, or a thread on screen, local or remote, changed since `stream` last looked (a
    /// reply streaming in): what the stores' passes (`NativeThreadStores.busy`) wait out.
    func personAtWork(_ stream: UserActivity.Stream) -> Bool {
        let streaming = stream.changed(threadStores.shownVersions().merging(remoteThreadStores.shownVersions()) { $1 })
        return userActivity.inputRecent || streaming
    }

    /// The visible layout's id, without copying a `Tab`.
    var activeTabID: TabID? { workspaceSelection.activeTabID }

    /// The one mounted layout the user actually sees.
    func isVisibleTab(_ tab: Tab) -> Bool { workspaceSelection.isVisible(tab) }

    // MARK: Persistence plumbing

    /// Append one workspace write to the serialized host-mutation tail.
    /// Local state may lead briefly for responsive UI, but a failed write
    /// always restores both mirrors from the host's committed snapshot.
    /// `failureTitle` names a person's own edit ("Couldn’t rename the agent"): its failure shows
    /// in the error sheet instead of snapping back in silence. Exit cleanups pass none.
    func enqueuePersistence(
        _ description: String,
        failureTitle: String? = nil,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        let previous = persistenceTail
        persistenceTail = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self else { return }
            do {
                try await operation()
            } catch {
                // Silent by design: a failed background write self-heals via
                // reconcile, and audible feedback here beeps from test runs
                // and post-hoc races (e.g. removing an already-removed tab).
                NSLog("Shepherd: \(description) failed: \(error)")
                if let failureTitle { self.fail(failureTitle, error) }
                self.reconcileFromServer()
            }
        }
    }

    /// Reconcile optimistic UI state after a queued persistence failure.
    private func reconcileFromServer() {
        guard let canonical = localHost?.state else { return }
        adopt(canonical)
    }

    // MARK: Terminals

    /// Whether ⌘W has a terminal (or review, or remote inspector) to close: File ▸ Close Terminal
    /// is disabled otherwise, instead of beeping.
    var canCloseTerminal: Bool {
        if let remote = selectedRemoteAgent {
            if remoteInspectingAgent == remote, remoteVisibleTab(remote) != nil { return true }
            if let review = remoteReviews[remote], remoteFocusedPaneID == review.paneID { return true }
            guard let connection = remoteHosts.allConnections.first(where: { $0.id == remote.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
                  let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) else { return false }
            let focus = remoteFocusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil } ?? agent.paneID ?? tab.layout.firstLeaf.id
            return tab.layout.leaf(withID: focus)?.agentID == nil
        }
        guard let tab = activeTab else { return false }
        let focus = focusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil } ?? tab.layout.firstLeaf.id
        return tab.layout.leaf(withID: focus)?.agentID == nil
    }

    /// File ▸ Save: the Settings page that has a file to save, or nil for no item at all.
    var saveMenuItem: (title: String, enabled: Bool)? {
        guard showSettings else { return nil }
        switch settingsSection {
        case .subagents: return ("Save Subagent File", subagentDefinitions.canSave)
        case .projects:
            return ("Save Space File", !projects.showingBrowser && !projects.showingHooks && projects.fileLoaded && !projects.saving && projects.selected?.unavailable == nil)
        default: return nil
        }
    }

    func saveSettingsFile() async {
        guard showSettings else { return }
        if settingsSection == .subagents { await subagentDefinitions.save() } else if settingsSection == .projects { await projects.save() }
    }

    /// ⌘W: closes the terminal that has the keyboard. The thread is never closed (⌘⇧W deletes
    /// the agent): closing it would strand a running pi with nothing to come back to.
    func closeFocusedTerminal() {
        if let remote = selectedRemoteAgent {
            if remoteInspectingAgent == remote, let tab = remoteVisibleTab(remote) {
                controlRemoteInspector(remote, action: .close(paneID: remoteFocusedPaneID ?? tab.layout.firstLeaf.id))
                return
            }
            if let review = remoteReviews[remote], remoteFocusedPaneID == review.paneID { cancelReview(review); return }
            guard let connection = remoteHosts.allConnections.first(where: { $0.id == remote.hostID }),
                  let agent = connection.state.agents.first(where: { $0.id == remote.agentID }),
                  let tab = connection.state.tabs.first(where: { $0.id == agent.tabID }) else {
                NSSound.beep()
                return
            }
            let focus = remoteFocusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil }
                ?? agent.paneID ?? tab.layout.firstLeaf.id
            guard tab.layout.leaf(withID: focus)?.agentID == nil else {
                NSSound.beep()
                return
            }
            Task {
                do {
                    try await remoteHosts.closePane(
                        hostID: remote.hostID,
                        agentID: remote.agentID,
                        paneID: focus
                    )
                    remoteFocusedPaneID = agent.paneID ?? tab.layout.firstLeaf.id
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        guard let tab = activeTab else { NSSound.beep(); return }
        let focus = focusedPaneID.flatMap { tab.layout.contains($0) ? $0 : nil } ?? tab.layout.firstLeaf.id
        if tab.layout.leaf(withID: focus)?.agentID != nil {
            NSSound.beep()
            return
        }
        if !closeLocalPane(focus) { NSSound.beep() }
    }

    /// Close a local leaf using the same layout mutation as ⌘W. Review leaves have no terminal
    /// session, but using this path keeps their persisted layout and focus behavior identical to
    /// an ordinary terminal's.
    @discardableResult
    func closeLocalPane(_ paneID: PaneID) -> Bool {
        guard let tabIndex = state.tabs.firstIndex(where: { $0.layout.contains(paneID) }),
              let pane = state.tabs[tabIndex].layout.leaf(withID: paneID),
              pane.agentID == nil,
              let newLayout = state.tabs[tabIndex].layout.closing(pane: paneID) else {
            return false
        }
        let tabID = state.tabs[tabIndex].id
        guard let agent = state.agents.first(where: { $0.tabID == tabID }), let ref = localRef(agent.id) else { return false }
        // The background host closes its terminal; the layout follows its push.
        Task {
            do { try await remoteHosts.closePane(hostID: ref.hostID, agentID: ref.agentID, paneID: paneID) }
            catch { fail("Couldn’t close the terminal", error) }
        }
        discardReviewSession(paneID)
        if focusedPaneID == paneID {
            focusedPaneID = newLayout.firstLeaf.id
        }
        return true
    }

    // MARK: Session lifecycle

    /// Retry in an agent's Can't start banner: starts its pi again (`newConversation`: without
    /// looking for the conversation it was resuming).
    func retryAgentStart(_ agentID: AgentID, newConversation: Bool = false, model: String? = nil) {
        // A thread whose folder is still gone: choose where it went (Locate Folder…) instead.
        if let agent = state.agents.first(where: { $0.id == agentID }),
           let cwd = state.tabs.first(where: { $0.id == agent.tabID })?.layout.leaf(withID: agent.paneID ?? PaneID())?.cwd,
           !Self.folderExists(cwd) {
            locateSpaceFromPanel(agent.spaceID)
            return
        }
        threadStores.store(for: agentID).restarting()
        guard let ref = localRef(agentID) else { return }
        // Its row stops reading "can't start" at once, as the banner goes; a failed start says so again.
        agentStopped(agentID, problem: nil, stopped: false)
        // The background host runs the agent's pi and starts it again.
        Task {
            do { try await remoteHosts.agentAction(ref, action: .restartPi(newConversation: newConversation, model: model)) }
            catch { fail("Couldn’t start the agent", error) }
        }
    }

    /// An agent's pi stopped because an extension failed to load. When it is one of the user's
    /// own that they switched on (Settings ▸ Pi ▸ Your extensions), it is switched off for
    /// launches with pi's reason, and the agent starts again without it; any other extension's
    /// failure (Shepherd's own, a project's) leaves the agent waiting with Retry, as before.
    func switchOffFailedExtensions(_ agentID: AgentID, problem: NativeStartProblem) {
        let failures = YourPiImport.extensionFailures(in: problem.lines)
        guard !failures.isEmpty else { return }
        let imports = pi.importedState()
        Task { [weak self] in
            let names = await Task.detached(priority: .userInitiated) { () -> [String] in
                failures.compactMap { failure in (try? imports.extensionFailed(path: failure.path, reason: failure.reason, lines: problem.lines)) ?? nil }
            }.value
            guard let self, !names.isEmpty else { return }
            ShepherdLog.info("switched off your extension(s) \(names.joined(separator: ", ")) after they failed to load; starting the agent without them")
            await yourPi.refresh()
            retryAgentStart(agentID)
        }
    }

    // MARK: Agents

    func renameSelectedAgent() {
        if let remote = selectedRemoteAgent {
            remoteRenameTarget = remote
            return
        }
        guard let id = selectedAgentID else { return }
        agentRenameTarget = id
    }

    func deleteSelectedAgent() {
        if let remote = selectedRemoteAgent {
            requestRemoteDelete(remote)
            return
        }
        guard let agent = selectedAgent else { return }
        requestDeleteAgent(agent.id)
    }

    /// User-initiated local deletes confirm unless this action was remembered. Worktree
    /// deletion has its own choice and still warns about unreconciled work.
    func requestDeleteAgent(_ id: AgentID) {
        guard let agent = state.agents.first(where: { $0.id == id }) else { return }
        if agent.worktreeBranch != nil { requestWorktreeDelete(id) }
        else if settings.skipped(.deleteAgent) != nil { deleteAgent(id) }
        else { agentDeleteTarget = id }
    }

    /// A worktree agent's checkout: its own path, or where its branch's worktree would be.
    /// Empty when its space is gone.
    func worktreeCheckoutPath(_ agent: Agent) -> String {
        agent.worktreePath ?? state.spaces.first { $0.id == agent.spaceID }
            .map { GitWorktree.destination(repo: $0.path, branch: agent.worktreeBranch ?? "") } ?? ""
    }

    /// Delete Worktree Agent: the dialog, unless Settings ▸ Worktrees remembers a delete. A
    /// remembered removal probes the checkout first and still shows the dialog (with its
    /// warning) when work would be lost or there is no checkout to probe.
    func requestWorktreeDelete(_ id: AgentID) {
        guard agent(id: id) != nil else { return }
        switch settings.worktreeDeleteAction {
        case .ask: worktreeDeleteTarget = id
        case .keepWorktree: deleteAgent(id)
        case .removeWorktree:
            guard let ref = localRef(id) else { worktreeDeleteTarget = id; return }
            // The host removes the checkout, bound to the loss it reports.
            Task {
                let info = try? await localHostWorktreeInfo(ref)
                if let info, info.warning == nil { deleteLocalHostWorktreeAgent(ref, removing: info) }
                else { hostWorktreeInfo = info; worktreeDeleteTarget = id }
            }
        }
    }

    /// A hand-typed name is final: pi's namer must never overwrite it.
    func renameAgent(_ id: AgentID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let agent = state.agents.first(where: { $0.id == id }),
              agent.name != trimmed else { return }
        let (hosts, ref) = (remoteHosts, localRef(id))
        enqueuePersistence("agent rename", failureTitle: "Couldn’t rename the agent") {
            guard let ref else { throw BackgroundHostClient.HostStarting() }
            try await hosts.agentAction(ref, action: .rename(name: trimmed))
        }
    }

    /// Persist retirement and wait for the actual process exits before removing a checkout.
    func deleteWorktreeAgent(_ id: AgentID, removeWorktree: Bool) {
        guard removeWorktree else { deleteAgent(id); return }
        guard let ref = localRef(id) else { return fail("Couldn’t delete the worktree", BackgroundHostClient.HostStarting()) }
        // The checkout the dialog showed, with the loss it warned of.
        let info = hostWorktreeInfo
        Task {
            do {
                let removing = if let info { info } else { try await localHostWorktreeInfo(ref) }
                deleteLocalHostWorktreeAgent(ref, removing: removing)
            }
            catch { fail("Couldn’t delete the worktree", error) }
        }
    }

    /// `completion` hears the outcome once the deletion is persisted (a peer's `agent_delete`
    /// waits on it).
    func deleteAgent(_ id: AgentID, completion: (@MainActor (Error?) -> Void)? = nil) {
        enqueuePersistence("agent deletion") { [weak self] in
            guard let self else { return }
            do {
                try await self.deleteAgentPersisted(id)
                await MainActor.run { completion?(nil) }
            } catch {
                await MainActor.run {
                    self.fail("Couldn’t delete the agent", error)
                    completion?(error)
                }
                throw error
            }
        }
    }

    func deleteAgentPersisted(_ id: AgentID) async throws {
        guard let ref = localRef(id) else { throw BackgroundHostClient.HostStarting() }
        try await remoteHosts.agentAction(ref, action: .deleteKeepingWorktree)
        cancelReviews(for: id)
        subagentInspector.runByAgent.removeValue(forKey: id)
        childRuns.clear(agent: id)
        forgetNotifications(of: id)
        forgetPullRequestLink(id)
        if selectedAgentID == id { selectPreviousAgent(after: id) }
        else { selectionHistory.removeAll { $0 == id } }
        if let canonical = localHost?.state { adopt(canonical) }
    }

}

// MARK: Sign-in

extension ShepherdViewModel {
    /// Settings ▸ Pi ▸ Sign-in's nav dot: a sign-in expired, or a provider an agent waits on
    /// isn't signed in.
    var piSignInNeedsAttention: Bool {
        PiSignInPage.make(survey: yourPi.survey ?? YourPiSurvey(), expired: piAuth.expired, needed: piAuth.needed).needsAttention
    }

    /// Opens Settings ▸ Pi ▸ Sign-in, scrolled to `provider` when there is one, and starts its
    /// sign-in (`/login anthropic`, an agent's Sign in to Anthropic). A provider Shepherd doesn't
    /// know opens the page as it is.
    func openSignIn(_ provider: String? = nil, start: Bool = true, origin: PiSignInSession.Origin = .settings) {
        settingsSection = .piSignIn
        showSettings = true
        guard let provider else { return }
        piAuth.focus = provider
        guard start else { return }
        let known = PiSignInCatalog.subscription(provider) != nil || PiProviders.names[provider] != nil
        if known { piAuth.signIn(provider, origin: origin) }
    }
}

// MARK: Agents not signed in

extension ShepherdViewModel {
    /// The provider a local agent's model uses (its own, else the default every launch resolves to); nil when none names one.
    func provider(of agentID: AgentID) -> String? {
        let model = latestState.agents.first { $0.id == agentID }?.model ?? settings.defaultModel(piHome: pi.home)
        guard let model, let slash = model.firstIndex(of: "/"), slash != model.startIndex else { return nil }
        return String(model[..<slash])
    }
}

/// An agent whose pi can't start because nothing signs in for its model (AgentNotSignedIn).
struct NotSignedIn: Equatable {
    /// The provider it needs; nil when pi names none and its model says nothing.
    var provider: String?
    /// When its pi stopped.
    var at: Date
}

extension ShepherdViewModel {
    /// An agent's pi stopped (or started again): it waits on a sign-in when pi said it can't reach
    /// a model, and Sign-in hears which providers agents wait on.
    func noteSignIn(_ agentID: AgentID, problem: NativeStartProblem?) {
        if let problem, problem.kind == .notSignedIn {
            let agent = latestState.agents.first { $0.id == agentID }
            let fallback = settings.agentDefaults.model ?? yourPi.survey?.shepherdDefaultModel
            let provider = PiAuthText.missingProvider(lines: problem.lines, model: agent?.model, defaultModel: fallback)
            notSignedIn[agentID] = NotSignedIn(provider: provider, at: Date())
        } else if notSignedIn[agentID] != nil {
            notSignedIn[agentID] = nil
        }
        // Sign-in hears only providers it can sign in to: a model pi has no provider for is the thread's to settle.
        let needed = Set(notSignedIn.values.compactMap(\.provider).filter(ThreadAuthNotice.known))
        if piAuth.needed != needed { piAuth.needed = needed }
    }

    /// A sign-in landed for `provider`: every agent waiting on it (or on no provider pi named)
    /// starts again. Returns how many.
    func retrySignedOutAgents(_ provider: String?) -> Int {
        let ids = notSignedIn.filter { provider == nil || $0.value.provider == nil || $0.value.provider == provider }.map(\.key)
        for id in ids { retryAgentStart(id) }
        return ids.count
    }

    /// "Use another model": an agent not signed in starts again on `model`.
    func useAnotherModel(_ agentID: AgentID, model: String) {
        retryAgentStart(agentID, model: model)
    }
}

// MARK: /login

extension ShepherdViewModel {
    /// What a local agent's composer does with `/login` and `/logout`.
    var slashLoginActions: SlashLoginActions {
        SlashLoginActions(open: { [weak self] command in self?.openSlashLogin(command) },
                          choices: { [weak self] in self?.slashLoginChoices() ?? [] })
    }

    /// `/login` opens Sign-in, and with a provider scrolls there and starts it; `/logout` only
    /// scrolls there: signing out stays a click.
    func openSlashLogin(_ command: SlashLogin.Command) {
        switch command.verb {
        case .login: openSignIn(command.provider, origin: .slash)
        case .logout: openSignIn(command.provider, start: false, origin: .slash)
        }
    }

    /// The providers /login lists, with their states in Shepherd's pi now.
    func slashLoginChoices() -> [SlashLogin.Choice] {
        SlashLogin.choices(PiSignInPage.make(survey: yourPi.survey ?? YourPiSurvey(), expired: piAuth.expired))
    }
}
