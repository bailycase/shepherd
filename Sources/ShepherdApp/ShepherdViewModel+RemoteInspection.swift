import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

extension ShepherdViewModel {
    func installRemoteInspection() {
        server.onRemoteAgentQuery = { [weak self] agentID, query, completion in
            Task { @MainActor in
                guard let self else {
                    completion(.failure(RemoteCreateAgentError("Host is shutting down")))
                    return
                }
                switch query {
                case .deleteKeepingWorktree, .worktreeInfo, .deleteWorktree, .finalizeWorktree, .worktreeStatus, .worktreeSetup, .worktreeCommitCount, .worktreeDescription:
                    do { completion(.success(try await self.handleRemoteWorktree(agentID, query: query))) }
                    catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
                    return
                default: break
                }
                guard let agent = self.server.state.agents.first(where: { $0.id == agentID }),
                      let tab = self.server.state.tabs.first(where: { $0.id == agent.tabID }) else {
                    completion(.failure(RemoteCreateAgentError("Agent no longer exists")))
                    return
                }
                let cwd = tab.layout.leaves.first { $0.agentID == agentID }?.cwd ?? tab.layout.firstLeaf.cwd
                do {
                    let result: RemoteAgentResult
                    switch query {
                    case .deleteKeepingWorktree, .worktreeInfo, .deleteWorktree, .finalizeWorktree, .worktreeStatus, .worktreeSetup, .worktreeCommitCount, .worktreeDescription:
                        return
                    case .children:
                        result = .children(self.children(of: agentID))
                    case .search(let query):
                        let matches = await Task.detached {
                            PaletteContentSearch.search(query: query, agents: [(agentID, agent.effectivePiSessionID, cwd)])
                        }.value
                        result = .search(snippet: matches.first?.snippet)
                    case .reviewPane(let paneID, let pullRequest):
                        guard let review = self.reviewSessions[paneID], review.agentID == agentID else { throw RemoteCreateAgentError("Review closed on host") }
                        if let pullRequest { self.reloadReview(review, reference: pullRequest ? "pr" : nil) }
                        while review.isLoading {
                            try await Task.sleep(for: .milliseconds(50))
                            guard self.reviewSessions[paneID] === review else { throw RemoteCreateAgentError("Review closed on host") }
                        }
                        if let error = review.loadError { throw RemoteCreateAgentError(error) }
                        result = .review(files: try JSONEncoder().encode(review.files), reference: review.reference)
                    case .finishReview(let paneID, let text):
                        guard let review = self.reviewSessions[paneID], review.agentID == agentID else { throw RemoteCreateAgentError("Review closed on host") }
                        if let text {
                            guard let sessionID = tab.layout.leaves.first(where: { $0.agentID == agentID })?.sessionID else { throw RemoteCreateAgentError("Agent terminal unavailable") }
                            self.server.write(sessionID: sessionID, data: RemoteProtocol.composedInput(text: text, submit: true))
                        }
                        self.cancelReview(review)
                        result = .ok
                    case .review(let pullRequest):
                        let (files, reference) = try await Task.detached {
                            let reference = pullRequest ? GitDiff.pullRequestReference(cwd: cwd) : nil
                            return (try JSONEncoder().encode(GitDiff.load(cwd: cwd, reference: reference)), reference)
                        }.value
                        result = .review(files: files, reference: reference)
                    case .inspectorPane(let tabID, let action):
                        result = try await self.handleRemoteInspectorPane(agentID: agentID, tabID: tabID, action: action)
                    case .inspect(let childID):
                        guard let child = self.children(of: agentID).first(where: { $0.id == childID }),
                              let asyncDir = child.asyncDir else {
                            throw RemoteCreateAgentError("Child run is no longer available")
                        }
                        let runner = try InspectExtension.installedPath()
                        let command = Self.inspectorCommand(runner: runner, asyncDir: asyncDir, runID: child.runID, childIndex: child.childIndex)
                        result = .inspector(try await self.openRemoteUtilityTerminal(agent: agent, cwd: cwd, key: "\(agentID.rawValue):\(childID)", command: command))
                    }
                    completion(.success(result))
                } catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
    }

    func handleRemoteInspectorPane(agentID: AgentID, tabID: TabID, action: RemoteInspectorPaneAction) async throws -> RemoteAgentResult {
        guard let inspector = server.state.tabs.first(where: { $0.id == tabID && $0.inspectorFor == agentID }),
              hostRemoteInspectors.values.contains(tabID) else { throw RemoteCreateAgentError("Inspector does not belong to this remote agent") }
        switch action {
        case .split(let paneID, let axis):
            guard let leaf = inspector.layout.leaf(withID: paneID) else { throw RemoteCreateAgentError("Inspector pane no longer exists") }
            try verifyCheckoutAvailable(leaf.cwd)
            let pane = LeafPane(cwd: leaf.cwd)
            guard let layout = inspector.layout.splitting(pane: paneID, axis: axis, newPane: pane) else { throw RemoteCreateAgentError("Cannot split inspector") }
            try await server.updateLayoutStructure(tabID: tabID, layout: layout)
            adopt(server.state)
            sessions.stateDidChange(state)
            _ = sessions.session(for: pane, in: inspector)
            return .inspectorFocus(pane.id)
        case .close(let paneID):
            guard inspector.layout.leaf(withID: paneID) != nil else { throw RemoteCreateAgentError("Inspector pane no longer exists") }
            guard let layout = inspector.layout.closing(pane: paneID) else { throw RemoteCreateAgentError("The last inspector pane stays open; exit its shell to close it") }
            try await server.updateLayoutStructure(tabID: tabID, layout: layout)
            sessions.detachPane(paneID)
            adopt(server.state)
            return .inspectorFocus(layout.firstLeaf.id)
        case .resize(let split, let ratio):
            guard inspector.layout.containsSplit(split) else { throw RemoteCreateAgentError("Split is not in this inspector") }
            try await server.updateLayoutStructure(tabID: tabID, layout: inspector.layout.replacingSplit(split, withRatio: min(0.85, max(0.15, ratio))))
            return .ok
        }
    }

    func openRemoteUtilityTerminal(agent: Agent, cwd: String, key: String, command: String) async throws -> TabID {
        try verifyCheckoutAvailable(cwd)
        let reservation = UUID()
        startingCheckoutUsers[reservation] = cwd
        defer { startingCheckoutUsers.removeValue(forKey: reservation) }
        if let existing = hostRemoteInspectors[key], server.state.tabs.contains(where: { $0.id == existing }) {
            return existing
        }
        let pane = LeafPane(cwd: cwd)
        let tab = Tab(spaceID: agent.spaceID, order: (server.state.tabs.map(\.order).max() ?? 0) + 1,
                      layout: .leaf(pane), inspectorFor: agent.id)
        try await server.addTab(tab)
        adopt(server.state)
        sessions.stateDidChange(state)
        _ = sessions.session(for: pane, in: tab)
        guard let session = await sessions.awaitSession(forPane: pane.id, timeout: .seconds(10)) else {
            throw RemoteCreateAgentError("Host terminal failed to start")
        }
        server.write(sessionID: session, data: Data((command + "\n").utf8))
        hostRemoteInspectors[key] = tab.id
        return tab.id
    }

    func openRemoteHostReview(_ target: RemoteAgentRef, pane: LeafPane) {
        if remoteReviews[target]?.paneID == pane.id { return }
        let session = ReviewSession(agentID: target.agentID, paneID: pane.id, cwd: pane.cwd, reference: nil)
        if let draft = remoteReviews[target] {
            session.comments = draft.comments
            session.summary = draft.summary
            session.files = draft.files
            if remoteFocusedPaneID == draft.paneID { remoteFocusedPaneID = pane.id }
        }
        session.hostReviewPane = true
        remoteReviews[target] = session
        loadRemoteReview(target, session: session, pullRequest: false)
    }

    func openRemoteReview(_ target: RemoteAgentRef, pullRequest: Bool) {
        if !pullRequest, let existing = remoteReviews[target] {
            cancelReview(existing)
            return
        }
        let connection = remoteHosts.connections.first { $0.id == target.hostID }
        let agent = remoteAgent(target)
        let cwd = connection?.state.tabs.first { $0.id == agent?.tabID }?.layout.firstLeaf.cwd ?? "remote"
        let session = remoteReviews[target] ?? ReviewSession(agentID: target.agentID, paneID: PaneID(), cwd: cwd, reference: nil)
        session.isPRMode = pullRequest
        remoteReviews[target] = session
        if selectedRemoteAgent == target, remoteInspectingAgent != target { remoteFocusedPaneID = session.paneID }
        loadRemoteReview(target, session: session, pullRequest: pullRequest, hostModeOverride: session.hostReviewPane ? pullRequest : nil)
    }

    func loadRemoteReview(_ target: RemoteAgentRef, session: ReviewSession, pullRequest: Bool, hostModeOverride: Bool? = nil) {
        let requestID = UUID()
        session.loadRequestID = requestID
        session.isLoading = true
        session.loadError = nil
        Task {
            do {
                let result = try await remoteHosts.agentQuery(target, query: session.hostReviewPane ? .reviewPane(paneID: session.paneID, pullRequest: hostModeOverride) : .review(pullRequest: pullRequest))
                guard remoteReviews[target] === session, session.loadRequestID == requestID, case .review(let files, let reference) = result else { return }
                session.files = try JSONDecoder().decode([DiffFile].self, from: files)
                session.reference = reference
            } catch {
                guard remoteReviews[target] === session, session.loadRequestID == requestID else { return }
                session.loadError = String(describing: error)
            }
            guard remoteReviews[target] === session, session.loadRequestID == requestID else { return }
            session.isLoading = false
        }
    }

    func openRemoteChild(_ target: RemoteAgentRef, child: ChildRun) {
        selectRemoteAgent(hostID: target.hostID, agentID: target.agentID)
        let requestID = UUID()
        remoteInspectionRequest = requestID
        Task {
            do {
                guard case .inspector(let tabID) = try await remoteHosts.agentQuery(target, query: .inspect(childID: child.id)),
                      remoteInspectionRequest == requestID, selectedRemoteAgent == target else { return }
                showRemoteInspector(target, tabID: tabID)
            } catch {
                if remoteInspectionRequest == requestID, selectedRemoteAgent == target { remoteActionError = String(describing: error) }
            }
        }
    }

    func showRemoteInspector(_ target: RemoteAgentRef, tabID: TabID) {
        remoteInspectorTabs[target] = tabID
        remoteInspectingAgent = target
        remoteFocusedPaneID = remoteHosts.connections.first { $0.id == target.hostID }?.state.tabs.first { $0.id == tabID }?.layout.firstLeaf.id
    }

    func controlRemoteInspector(_ target: RemoteAgentRef, action: RemoteInspectorPaneAction) {
        guard let tab = remoteVisibleTab(target), tab.inspectorFor == target.agentID else { return }
        Task {
            do {
                let result = try await remoteHosts.agentQuery(target, query: .inspectorPane(tabID: tab.id, action: action))
                if case .inspectorFocus(let paneID) = result, selectedRemoteAgent == target, remoteInspectingAgent == target {
                    remoteFocusedPaneID = paneID
                }
            } catch { remoteActionError = String(describing: error) }
        }
    }

    func remoteVisibleTab(_ target: RemoteAgentRef) -> Tab? {
        guard let connection = remoteHosts.connections.first(where: { $0.id == target.hostID }), let agent = remoteAgent(target) else { return nil }
        let tabID = remoteInspectingAgent == target ? remoteInspectorTabs[target] ?? agent.tabID : agent.tabID
        return connection.state.tabs.first { $0.id == tabID }
    }

    func remoteContentRows(query: String, excluding existing: Set<String>) async -> [PaletteItem] {
        var rows: [PaletteItem] = []
        for connection in remoteHosts.connections where connection.phase == .connected && connection.supportsInspection {
            for agent in connection.state.agents {
                if Task.isCancelled { return [] }
                let id = "remoteAgent.\(connection.id.uuidString).\(agent.id.rawValue)"
                guard !existing.contains(id) else { continue }
                do {
                    let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
                    if case .search(let snippet?) = try await remoteHosts.agentQuery(target, query: .search(query: query)) {
                        rows.append(PaletteItem(id: "fuzzy.\(id)", kind: .remoteAgent(hostID: connection.id, agentID: agent.id), section: .fuzzyMatches, title: agent.name, subtitle: "agent · ⌁ \(connection.config.name)", contentSnippet: snippet))
                    }
                } catch {
                    if Task.isCancelled { return [] }
                    break
                }
            }
        }
        return rows
    }
}
