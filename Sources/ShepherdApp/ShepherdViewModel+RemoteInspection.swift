import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

extension ShepherdViewModel {
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
        let connection = remoteHosts.allConnections.first { $0.id == target.hostID }
        let agent = remoteAgent(target)
        let cwd = connection?.state.tabs.first { $0.id == agent?.tabID }?.layout.firstLeaf.cwd ?? "remote"
        if remoteReviews[target] == nil, connection?.supportsChanges == true {
            // A host with the Changes engine: its scopes, lists and files over `changes*`.
            let session = ReviewSession(agentID: target.agentID, paneID: PaneID(), cwd: cwd, reference: nil, isLoading: true)
            session.engine = remoteChangesEngine(target)
            let latest = remoteThreadStores.store(for: target).snapshot?.turnChanges?.last
            session.followedTurn = latest
            let replied = repliedSinceReview(.remote(target), latest: latest)
            session.scope = pullRequest ? .pullRequest : replied ? .lastTurn : agent?.worktreeBase != nil ? .branch(base: nil) : .uncommitted
            session.scopeChosen = pullRequest || replied
            remoteReviews[target] = session
            loadChanges(session)
            return
        }
        let session = remoteReviews[target] ?? ReviewSession(agentID: target.agentID, paneID: PaneID(), cwd: cwd, reference: nil)
        if session.engine != nil {
            setChangesScope(session, pullRequest ? .pullRequest : session.scope)
            return
        }
        session.isPRMode = pullRequest
        remoteReviews[target] = session
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

    /// A remote agent's subagent opens in the same native side panel as a local one; the
    /// transcript comes from the host through the agent's native thread snapshot.
    func openRemoteChild(_ target: RemoteAgentRef, child: ChildRun) {
        selectRemoteAgent(hostID: target.hostID, agentID: target.agentID)
        subagentInspector.remoteRuns[target] = child.runID
    }

    func showRemoteInspector(_ target: RemoteAgentRef, tabID: TabID) {
        remoteInspectorTabs[target] = tabID
        remoteInspectingAgent = target
        remoteFocusedPaneID = remoteHosts.allConnections.first { $0.id == target.hostID }?.state.tabs.first { $0.id == tabID }?.layout.firstLeaf.id
    }

    func controlRemoteInspector(_ target: RemoteAgentRef, action: RemoteInspectorPaneAction) {
        guard let tab = remoteVisibleTab(target), tab.inspectorFor == target.agentID else { return }
        Task {
            do {
                let result = try await remoteHosts.agentQuery(target, query: .inspectorPane(tabID: tab.id, action: action))
                if case .inspectorFocus(let paneID) = result, selectedRemoteAgent == target, remoteInspectingAgent == target {
                    remoteFocusedPaneID = paneID
                }
            } catch { fail("The host refused the action", error) }
        }
    }

    func remoteVisibleTab(_ target: RemoteAgentRef) -> Tab? {
        guard let connection = remoteHosts.allConnections.first(where: { $0.id == target.hostID }), let agent = remoteAgent(target) else { return nil }
        let tabID = remoteInspectingAgent == target ? remoteInspectorTabs[target] ?? agent.tabID : agent.tabID
        return connection.state.tabs.first { $0.id == tabID }
    }

    func remoteContentRows(query: String, excluding existing: Set<String>) async -> [PaletteItem] {
        var rows: [PaletteItem] = []
        for connection in remoteHosts.connections where connection.phase == .connected && connection.supportsInspection {
            for agent in connection.state.agents where connection.state.isOrdinaryThread(agent) {
                if Task.isCancelled { return [] }
                let id = "remoteAgent.\(connection.id.uuidString).\(agent.id.rawValue)"
                guard !existing.contains(id) else { continue }
                do {
                    let target = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
                    if case .search(let snippet?) = try await remoteHosts.agentQuery(target, query: .search(query: query)) {
                        rows.append(PaletteItem(id: "fuzzy.\(id)", kind: .remoteAgent(hostID: connection.id, agentID: agent.id), section: .conversations, title: agent.name, subtitle: connection.config.name, icon: "text.magnifyingglass", contentSnippet: snippet))
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
