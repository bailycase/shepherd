import Foundation
import AppKit
import ShepherdCore
import ShepherdSessions

@MainActor
extension ShepherdViewModel {
    func installReviewHandler() {
        server.onReviewRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failed(code: "unavailable", message: "workspace is gone"))
                    return
                }
                guard case .start(let agentID, let cwd, let reference) = request else {
                    respond(.failed(code: "invalid_request", message: "unsupported review request"))
                    return
                }
                self.beginReview(agentID: agentID, cwd: cwd, reference: reference, respond: respond)
            }
        }
    }

    /// The header button toggles: open a review pane for the selected agent,
    /// or close the one already open (comments are discarded like cancel).
    func openUserReview() {
        guard let agent = selectedAgent else {
            NSSound.beep()
            return
        }
        if let existing = reviewSessions.values.first(where: { $0.agentID == agent.id }) {
            cancelReview(existing)
            return
        }
        beginReview(agentID: agent.id, cwd: nil, reference: nil, respond: nil)
    }

    func submitReview(_ session: ReviewSession) {
        guard reviewSessions[session.paneID] === session else { return }
        let text = formatReview(
            files: session.files,
            comments: session.comments,
            summary: session.summary,
            reference: session.reference
        )
        if let piSessionID = piSessionID(for: session.agentID) {
            server.write(sessionID: piSessionID, data: Data((text + "\n").utf8))
        } else {
            NSSound.beep()
        }
        reviewSessions.removeValue(forKey: session.paneID)
        closeLocalPane(session.paneID)
    }

    func cancelReview(_ session: ReviewSession) {
        guard reviewSessions[session.paneID] === session else { return }
        reviewSessions.removeValue(forKey: session.paneID)
        closeLocalPane(session.paneID)
    }

    func discardReviewSession(_ paneID: PaneID) {
        reviewSessions.removeValue(forKey: paneID)
    }

    func cancelReviews(for agentID: AgentID) {
        let doomed = reviewSessions.values.filter { $0.agentID == agentID }.map(\.paneID)
        for paneID in doomed {
            reviewSessions.removeValue(forKey: paneID)
        }
    }

    func pruneReviewSessions() {
        let liveReviewPanes = Set(
            state.tabs.flatMap { $0.layout.leaves }.filter { $0.isReview == true }.map(\.id)
        )
        let liveAgents = Set(state.agents.map(\.id))
        let doomed = reviewSessions.values.filter {
            !liveReviewPanes.contains($0.paneID) || !liveAgents.contains($0.agentID)
        }
        for session in doomed {
            reviewSessions.removeValue(forKey: session.paneID)
        }
    }

    /// Open the pane immediately (empty, loading), then fill in the parsed
    /// diff when git finishes — the pane must never wait on a subprocess.
    private func beginReview(
        agentID: AgentID,
        cwd requestedCwd: String?,
        reference: String?,
        respond: ((ReviewOutcome) -> Void)?
    ) {
        guard let agent = state.agents.first(where: { $0.id == agentID }),
              let tab = state.tabs.first(where: { $0.id == agent.tabID }),
              let piPane = tab.layout.leaves.first(where: { $0.agentID == agentID }) else {
            respond?(.failed(code: "no_such_agent", message: "unknown agent \(agentID)"))
            return
        }
        let cwdPath = ((requestedCwd ?? piPane.cwd) as NSString).expandingTildeInPath

        let reviewPane = LeafPane(cwd: cwdPath, isReview: true)
        guard let layout = tab.layout.splitting(
            pane: piPane.id,
            axis: .vertical,
            newPane: reviewPane,
            ratio: 0.5
        ) else {
            respond?(.failed(code: "split_failed", message: "could not split the agent pane"))
            return
        }

        let visible = isVisibleTab(tab)
        setLayout(layout, forTab: tab.id)
        let session = ReviewSession(
            agentID: agentID,
            paneID: reviewPane.id,
            cwd: cwdPath,
            reference: reference,
            isLoading: true
        )
        reviewSessions[reviewPane.id] = session
        if visible {
            focusedPaneID = reviewPane.id
        }
        // The tool returns immediately; the review itself arrives later as a
        // typed prompt message when the user submits.
        respond?(.submitted(
            text: "Review pane opened. The user's review will arrive as a message when they submit; continue only if you have unrelated work."
        ))

        Task.detached(priority: .userInitiated) {
            let result = Result { try GitDiff.load(cwd: cwdPath, reference: reference) }
            await MainActor.run {
                // The user may have closed the pane before git finished.
                guard self.reviewSessions[reviewPane.id] === session else { return }
                session.isLoading = false
                switch result {
                case .success(let files): session.files = files
                case .failure(let error): session.loadError = String(describing: error)
                }
            }
        }
    }

    private func piSessionID(for agentID: AgentID) -> SessionID? {
        guard let agent = state.agents.first(where: { $0.id == agentID }),
              let tab = state.tabs.first(where: { $0.id == agent.tabID }) else { return nil }
        return tab.layout.leaves.first(where: { $0.agentID == agentID })?.sessionID
    }
}
