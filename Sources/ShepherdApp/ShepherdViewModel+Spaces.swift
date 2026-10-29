import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Space lifecycle from the sidebar's context menu.
@MainActor
extension ShepherdViewModel {
    /// Rename a space's sidebar label. Display-only: the checkout path (and
    /// everything derived from it — nesting, cwds, sessions) is untouched.
    func renameSpace(_ id: SpaceID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = state.spaces.firstIndex(where: { $0.id == id }),
              state.spaces[index].name != trimmed else { return }
        state.spaces[index].name = trimmed
        sessions.stateDidChange(state)
        enqueuePersistence("rename space", failureTitle: "Couldn’t rename the space") { _ = try await $0.editProject(id, edit: ProjectEdit(name: trimmed)) }
        let committed = persistenceTail
        Task { @MainActor [weak self] in
            await committed?.value
            guard let self, let projects = self.madeProjects else { return }
            await projects.load(self.projectsSources, force: true)
        }
    }

    /// Delete a space and everything in it (agents, layouts, sessions). Spaces nested under it by path are independent
    /// entities and survive — they re-root in the sidebar's derived forest.
    /// Remove Space… from the user: the dialog, or at once after its "Don't ask again".
    func requestSpaceDelete(_ id: SpaceID?) {
        guard let id else { return }
        if settings.skipped(.removeSpace) != nil { deleteSpace(id); return }
        spaceDeleteRequested = false
        spaceDeleteTarget = id
    }

    func deleteSpace(_ id: SpaceID) {
        guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
        let doomedAgents = Set(state.agents.filter { $0.spaceID == id }.map(\.id))
        let doomedTabs = state.tabs.filter { $0.spaceID == id }

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
            cancelReviews(for: agentID)
            childRuns.clear(agent: agentID)
            forgetNotifications(of: agentID)
            selectionHistory.removeAll { $0 == agentID }
            subagentInspector.runByAgent.removeValue(forKey: agentID)
        }
        if selectedAgentID.map(doomedAgents.contains) == true {
            selectedAgentID = nil
        }
        if selectedSpaceID == id {
            selectedSpaceID = visibleSpaces.first?.id
            if selectedAgentID == nil {
                if let next = state.agents.first(where: { $0.spaceID == selectedSpaceID }) {
                    if destination == nil, selectedRemoteAgent == nil {
                        willOpenSidebarThread(design(drawnBy: next).map { .design($0.id) } ?? .local(next.id))
                    }
                    selectedAgentID = next.id
                }
            }
        }
        sessions.stateDidChange(state)
        syncFocus()
        enqueuePersistence("space deletion", failureTitle: "Couldn’t remove the space") { try await $0.deleteSpace(id) }
    }
}

// MARK: Missing folders

@MainActor
extension ShepherdViewModel {
    /// How often This Mac's space folders are read again while the app runs.
    /// ponytail: a poll (one stat per space), not an FSEvents stream; switch if spaces number in the hundreds.
    static let missingSpaceInterval: Duration = .seconds(2)

    nonisolated static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// This Mac's visible spaces whose folder is gone.
    nonisolated static func missingSpaces(in spaces: [Space]) -> Set<SpaceID> {
        Set(spaces.filter { !$0.hidden && !folderExists($0.path) }.map(\.id))
    }

    /// Marks a space whose folder moved, was renamed or deleted within `missingSpaceInterval`,
    /// and clears it as soon as the folder is back.
    func installMissingSpaceWatch() {
        missingSpaceWatch?.cancel()
        missingSpaceWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.checkMissingSpaces()
                try? await Task.sleep(for: Self.missingSpaceInterval)
            }
        }
    }

    /// Reads every space's folder off the main thread (after a state change, the app coming to
    /// the front, and on the watch), writing `missingSpaces` only when it changes. A request
    /// during a pass runs one more pass after it, so the newest spaces are always read.
    func checkMissingSpaces() {
        guard !missingSpaceCheck.running else { missingSpaceCheck.again = true; return }
        missingSpaceCheck.running = true
        let spaces = state.spaces
        Task { @MainActor [weak self] in
            let missing = await Task.detached(priority: .utility) { Self.missingSpaces(in: spaces) }.value
            guard let self else { return }
            // Spaces removed while the pass ran are gone, not missing.
            let current = missing.intersection(self.state.spaces.map(\.id))
            if current != self.missingSpaces { self.missingSpaces = current }
            self.missingSpaceCheck.running = false
            if self.missingSpaceCheck.again {
                self.missingSpaceCheck.again = false
                self.checkMissingSpaces()
            }
        }
    }

    /// Locate Folder… on a missing space: choose where its folder is now.
    func locateSpaceFromPanel(_ id: SpaceID) {
        spacePickerTarget = .relocate(id)
    }

    /// Points the space at `path`, and everything recorded inside its old folder with it: child
    /// spaces, threads and terminals. Its threads stop, their conversations move to the new
    /// folder, and they start again there. A refusal shows why.
    func relocateSpace(_ id: SpaceID, to path: String) async {
        guard let old = state.spaces.first(where: { $0.id == id })?.path else { return }
        let target = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        let moving = state.agents.compactMap { agent -> (agent: Agent, from: String, to: String, session: SessionID?)? in
            guard let pane = state.tabs.first(where: { $0.id == agent.tabID })?.layout.leaf(withID: agent.paneID ?? PaneID()),
                  let to = SessionServer.relocated(pane.cwd, from: old, to: target) else { return nil }
            return (agent, pane.cwd, to, pane.sessionID)
        }
        do {
            // Stop the threads first: a pi still running would write to the conversation being moved.
            let deadline = ContinuousClock.now + .seconds(10)
            for thread in moving {
                guard let session = thread.session, await server.sessionInfo(sessionID: session)?.isAlive == true else { continue }
                await server.stopKeepingAgent(sessionID: session)
                while await server.sessionInfo(sessionID: session)?.isAlive == true {
                    guard ContinuousClock.now < deadline else { throw AgentStartFailure(message: "\(thread.agent.name) did not stop. Nothing was moved.") }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            _ = try await server.relocateSpace(id, to: path)
        } catch {
            fail("Couldn’t move the space", error)
            for thread in moving {
            threadStores.store(for: thread.agent.id).restarting()
            sessions.retryStart(thread.agent.id)
        }
            return
        }
        let root = server.pi.sessionsRoot
        let files = moving.map { ($0.agent.effectivePiSessionID, $0.from, $0.to) }
        await Task.detached(priority: .userInitiated) {
            for (session, from, to) in files { PiSessionFile.relocate(sessionID: session, from: from, to: to, sessionsRoot: root) }
        }.value
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
        for thread in moving {
            threadStores.store(for: thread.agent.id).restarting()
            sessions.retryStart(thread.agent.id)
        }
    }
}
