import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

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

    /// Open the agent's review (right pane) scrolled to `path`, reusing an open one: the
    /// thread's "review ›" links land here.
    func openReview(agentID: AgentID, path: String?) {
        let existing = reviewSessions.values.first { $0.agentID == agentID }
        subagentInspector.runByAgent.removeValue(forKey: agentID)
        if existing == nil { beginReview(agentID: agentID, cwd: nil, reference: nil, respond: nil) }
        focus(reviewSessions.values.first { $0.agentID == agentID }, path: path)
    }

    func openRemoteReview(_ target: RemoteAgentRef, path: String?) {
        subagentInspector.remoteRuns.removeValue(forKey: target)
        if remoteReviews[target] == nil { openRemoteReview(target, pullRequest: false) }
        focus(remoteReviews[target], path: path)
    }

    /// Scroll to `path` now or, while the diff loads, once it arrives (ReviewPane resolves
    /// a pending `focusFile` on appear and whenever `focusRequest` changes).
    private func focus(_ session: ReviewSession?, path: String?) {
        guard let session, let path else { return }
        session.focusFile = path
        session.focusRequest = UUID()
    }

    /// The header button toggles: open a review pane for the selected agent,
    /// or close the one already open (comments are discarded like cancel).
    func openUserReview() {
        if let target = selectedRemoteAgent {
            openRemoteReview(target, pullRequest: false)
            return
        }
        guard let agent = selectedAgent else {
            NSSound.beep()
            return
        }
        if let existing = reviewSessions.values.first(where: { $0.agentID == agent.id }) {
            cancelReview(existing)
            return
        }
        subagentInspector.runByAgent.removeValue(forKey: agent.id)
        beginReview(agentID: agent.id, cwd: nil, reference: nil, respond: nil)
    }

    /// Review the changes sitting in this branch's PR (merge-base diff
    /// against the PR base, falling back to the remote default branch).
    /// Replaces an open review for the agent.
    func openUserPRReview() {
        if let target = selectedRemoteAgent {
            openRemoteReview(target, pullRequest: true)
            return
        }
        guard let agent = selectedAgent else {
            NSSound.beep()
            return
        }
        subagentInspector.runByAgent.removeValue(forKey: agent.id)
        if let existing = reviewSessions.values.first(where: { $0.agentID == agent.id }) {
            reloadReview(existing, reference: "pr")
            return
        }
        beginReview(agentID: agent.id, cwd: nil, reference: "pr", respond: nil)
    }

    func submitReview(_ session: ReviewSession) {
        finishReview(session, sending: formatReview(files: session.files, comments: session.comments, summary: session.summary, reference: session.reference))
    }

    /// Commit: the agent commits what is under review (the review's comments ride along).
    func commitReview(_ session: ReviewSession) {
        finishReview(session, sending: formatCommitRequest(files: session.files, comments: session.comments, summary: session.summary, reference: session.reference))
    }

    /// Send `text` as the agent's next turn and close the review.
    private func finishReview(_ session: ReviewSession, sending text: String) {
        if let target = remoteReviews.first(where: { $0.value === session })?.key {
            guard !session.isSubmitting else { return }
            session.isSubmitting = true
            Task {
                defer { session.isSubmitting = false }
                do {
                    if session.hostReviewPane {
                        _ = try await remoteHosts.agentQuery(target, query: .finishReview(paneID: session.paneID, text: text))
                    } else { try await remoteHosts.sendUserMessage(target, text: text) }
                    if remoteReviews[target] === session { remoteReviews.removeValue(forKey: target) }
                } catch { remoteActionError = String(describing: error) }
            }
            return
        }
        guard reviewSessions[session.paneID] === session, !session.isSubmitting else { return }
        session.isSubmitting = true
        let agentID = session.agentID
        Task {
            defer { session.isSubmitting = false }
            do {
                try await sendUserMessage(text, to: agentID)
                if reviewSessions[session.paneID] === session { removeReview(session) }
            } catch { remoteActionError = String(describing: error) }
        }
    }

    /// Discard one file's changes (the pane confirmed first) in `cwd`, the directory its diff
    /// came from, then reload the diff in place. A review retargeted meanwhile is left alone.
    func revertReviewFile(_ session: ReviewSession, file: DiffFile, in cwd: String) {
        guard reviewSessions[session.paneID] === session, !session.isPRMode else { return }
        Task {
            do {
                try await Task.detached { try GitDiff.revert(file, cwd: cwd) }.value
            } catch {
                remoteActionError = "Could not revert \(file.displayPath): \(error)"
            }
            guard reviewSessions[session.paneID] === session, session.cwd == cwd else { return }
            session.comments.removeAll { $0.fileID == file.id }
            session.viewed.remove(file.id)
            reloadReview(session, reference: session.reference)
        }
    }

    /// Open a reviewed file in Xcode (the system default editor when Xcode is absent).
    func openReviewFile(_ session: ReviewSession, file: DiffFile) {
        let cwd = session.cwd
        Task {
            let root = await Task.detached { GitDiff.repositoryRoot(cwd: cwd) }.value
            let url = URL(fileURLWithPath: root).appendingPathComponent(file.displayPath)
            if let xcode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The pane's actions for `session`, local or remote.
    func reviewActions(for session: ReviewSession, remote: Bool) -> ReviewActions {
        ReviewActions(
            setPullRequest: { [weak self] pr in self?.reloadReview(session, reference: pr ? "pr" : nil) },
            requestChanges: { [weak self] in self?.submitReview(session) },
            commit: { [weak self] in self?.commitReview(session) },
            close: { [weak self] in self?.cancelReview(session) },
            revert: remote ? nil : { [weak self] file, cwd in self?.revertReviewFile(session, file: file, in: cwd) },
            open: remote ? nil : { [weak self] file in self?.openReviewFile(session, file: file) },
            focusThread: { [weak self] in
                guard let self else { return }
                if remote { self.remoteFocusedPaneID = nil } else { self.focusedPaneID = self.activeTab?.layout.firstLeaf.id }
            },
            canCommitDirectly: { [weak self] in self?.reviewCanCommit(session) ?? false },
            commitStore: { [weak self] in self?.reviewCommitStore(for: session) },
            commitClosed: { [weak self] in self?.reviewCommitClosed(session) }
        )
    }

    /// Queue `text` as the agent's next user turn: delivered now when idle, as a follow-up
    /// when the agent is mid-turn.
    func sendUserMessage(_ text: String, to agentID: AgentID) async throws {
        guard case .snapshot(let snapshot) = try await server.nativeThread(agentID: agentID, request: .snapshot()),
              !snapshot.piSessionID.isEmpty else {
            throw AgentStartFailure(message: "The agent is not ready yet. Try again in a moment.")
        }
        let result = try await server.nativeThread(agentID: agentID, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
            operationID: UUID(), text: text, delivery: .followUp))
        if case .failure(_, let message) = result { throw AgentStartFailure(message: message) }
    }

    func cancelReview(_ session: ReviewSession) {
        if let target = remoteReviews.first(where: { $0.value === session })?.key {
            if session.hostReviewPane {
                Task {
                    do { _ = try await remoteHosts.agentQuery(target, query: .finishReview(paneID: session.paneID, text: nil)) }
                    catch { remoteActionError = String(describing: error) }
                }
            }
            remoteReviews.removeValue(forKey: target)
            return
        }
        guard reviewSessions[session.paneID] === session else { return }
        removeReview(session)
    }

    /// Reviews dock in the right pane; a review a remote client adopted from a layout leaf
    /// (older hosts split the layout) also closes that leaf.
    private func removeReview(_ session: ReviewSession) {
        reviewSessions.removeValue(forKey: session.paneID)
        if state.tabs.contains(where: { $0.layout.contains(session.paneID) }) { closeLocalPane(session.paneID) }
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
        let liveAgents = Set(state.agents.map(\.id))
        let doomed = reviewSessions.values.filter { !liveAgents.contains($0.agentID) }
        for session in doomed {
            reviewSessions.removeValue(forKey: session.paneID)
        }
    }

    /// Switch an open review between uncommitted (nil) and PR ("pr") mode:
    /// clear the loaded diff and reload in place. Comments are kept — they
    /// re-anchor by file/line where the diff still contains them.
    func reloadReview(_ session: ReviewSession, reference: String?) {
        if let target = remoteReviews.first(where: { $0.value === session })?.key {
            session.isPRMode = reference == "pr"
            loadRemoteReview(target, session: session, pullRequest: session.isPRMode, hostModeOverride: session.hostReviewPane ? session.isPRMode : nil)
            return
        }
        guard reviewSessions[session.paneID] === session else { return }
        session.reference = reference
        session.isPRMode = reference == "pr"
        session.isLoading = true
        session.loadError = nil
        loadReviewDiff(session)
    }

    /// Resolve and load the session's diff off the main thread, filling the
    /// session in place when done.
    private func loadReviewDiff(_ session: ReviewSession) {
        let cwdPath = session.cwd
        let reference = session.reference
        let paneID = session.paneID
        let requestID = UUID()
        session.loadRequestID = requestID
        let loader = reviewDiffLoader
        Task {
            do {
                let result = try await loader(cwdPath, reference)
                guard reviewSessions[paneID] === session, session.loadRequestID == requestID else { return }
                session.reference = result.reference
                session.files = result.files
            } catch {
                guard reviewSessions[paneID] === session, session.loadRequestID == requestID else { return }
                session.loadError = String(describing: error)
            }
            session.isLoading = false
            // The header's count follows what the review just read (a commit or a revert
            // reloads it too).
            checkouts?.refresh(session.agentID)
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
              let piPane = tab.layout.leaves.first(where: { $0.agentID == agentID }) ?? tab.layout.leaves.first else {
            respond?(.failed(code: "no_such_agent", message: "unknown agent \(agentID)"))
            return
        }

        // Never changes the agent's own directory; no cwd means the agent's, even when the open
        // review targets another repository.
        let cwdPath = ((requestedCwd ?? piPane.cwd) as NSString).expandingTildeInPath

        // One review per agent, regardless of entry point: an agent re-requesting a review
        // reloads the open one and brings it back in front of an inspected subagent.
        if let existing = reviewSessions.values.first(where: { $0.agentID == agentID }) {
            if existing.cwd != cwdPath { existing.retarget(cwd: cwdPath) }
            subagentInspector.runByAgent.removeValue(forKey: agentID)
            reloadReview(existing, reference: reference)
            respond?(.submitted(
                text: "Review pane already open; reloaded. The user's review will arrive as a message when they submit."
            ))
            return
        }

        // The review docks in the agent's right pane: a view slot, not a layout leaf, so it
        // never touches the persisted layout.
        let session = ReviewSession(
            agentID: agentID,
            paneID: PaneID(),
            cwd: cwdPath,
            agentCwd: (piPane.cwd as NSString).expandingTildeInPath,
            reference: reference,
            isLoading: true
        )
        session.isPRMode = reference == "pr"
        subagentInspector.runByAgent.removeValue(forKey: agentID)
        reviewSessions[session.paneID] = session
        // The tool returns immediately; the review itself arrives later as a
        // typed prompt message when the user submits.
        respond?(.submitted(
            text: "Review pane opened. The user's review will arrive as a message when they submit; continue only if you have unrelated work."
        ))

        loadReviewDiff(session)
    }
}
