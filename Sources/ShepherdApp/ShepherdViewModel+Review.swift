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

    /// Show the agent's Changes tab scrolled to `path`, in front of an inspected subagent: the
    /// thread's "review ›" links and the inspector's file links land here.
    func openReview(agentID: AgentID, path: String?) {
        showSidePane(.local(agentID), tab: .changes)
        focus(reviewSessions.values.first { $0.agentID == agentID }, path: path)
    }

    func openRemoteReview(_ target: RemoteAgentRef, path: String?) {
        showSidePane(.remote(target), tab: .changes)
        focus(remoteReviews[target], path: path)
    }

    /// A changes card's Review and its file rows (ChangesCard): the Changes tab on that turn.
    func openTurnReview(_ owner: SidePaneOwner, turnID: UUID?, path: String?) {
        showSidePane(owner, tab: .changes)
        let session: ReviewSession? = switch owner {
        case .local(let agentID): reviewSessions.values.first { $0.agentID == agentID }
        case .remote(let target): remoteReviews[target]
        }
        guard let session else { return }
        if let turnID, session.engine != nil, session.scope != .turn(id: turnID) {
            session.scopeChosen = true
            setChangesScope(session, .turn(id: turnID))
        }
        focus(session, path: path)
    }

    /// Scroll to `path` now or, while the diff loads, once it arrives (ReviewPane resolves
    /// a pending `focusFile` on appear and whenever `focusRequest` changes).
    private func focus(_ session: ReviewSession?, path: String?) {
        guard let session, let path else { return }
        session.focusFile = path
        session.focusRequest = UUID()
    }

    /// Review Changes (the sidebar's menu, the palette): the side pane on Changes for the
    /// selected agent.
    func openUserReview() {
        guard sidePaneOwner != nil else { NSSound.beep(); return }
        selectSidePaneTab(.changes)
    }

    /// Review the changes sitting in this branch's PR, on the Changes tab.
    func openUserPRReview() {
        if let target = selectedRemoteAgent {
            showSidePane(.remote(target), tab: .changes)
            if let session = remoteReviews[target] {
                if session.engine != nil { setChangesScope(session, .pullRequest) } else { reloadReview(session, reference: "pr") }
            }
            return
        }
        guard let agent = selectedAgent else {
            NSSound.beep()
            return
        }
        if let existing = reviewSessions.values.first(where: { $0.agentID == agent.id }) {
            if existing.engine != nil { setChangesScope(existing, .pullRequest) } else { reloadReview(existing, reference: "pr") }
        } else {
            beginReview(agentID: agent.id, cwd: nil, reference: "pr")
        }
        showSidePane(.local(agent.id), tab: .changes)
    }

    /// Send to agent: the comments as the agent's next turn, under the scope they were written
    /// against. The pane stays; its comments clear once the send succeeds (they survive a failed
    /// one), and the agent's reply turns it to Last turn.
    func submitReview(_ session: ReviewSession) {
        let text = session.engine == nil && !session.summary.isEmpty
            ? formatReview(files: session.files, comments: session.comments, summary: session.summary, reference: session.reference)
            : formatChangesReview(fileIDs: session.files.map(\.id), comments: session.comments, scopeTitle: session.scopeTitle)
        finishReview(session, sending: text, closes: session.hostReviewPane)
    }

    /// Commit: the agent commits what is under review (the review's comments ride along).
    func commitReview(_ session: ReviewSession) {
        finishReview(session, sending: formatCommitRequest(files: session.files, comments: session.comments, summary: session.summary,
                                                           reference: session.scopeTitle), closes: session.hostReviewPane)
    }

    /// Discard: drop the unsent comments.
    func discardReviewComments(_ session: ReviewSession) {
        session.comments = []
        session.summary = ""
    }

    /// Send `text` as the agent's next turn. A review a remote host's layout holds closes with
    /// it (`closes`); the Changes tab stays, its comments cleared.
    private func finishReview(_ session: ReviewSession, sending text: String, closes: Bool) {
        let sent = { [weak self] in
            session.sentAt = Date().timeIntervalSince1970 * 1000
            if let owner = self?.owner(of: session) { self?.reviewSentAt[owner] = session.sentAt }
            session.scopeChosen = false
            session.comments = []
            session.summary = ""
            guard closes, let self else { return }
            if let target = self.remoteReviews.first(where: { $0.value === session })?.key {
                self.remoteReviews.removeValue(forKey: target)
                self.subagentInspector.open.remove(.remote(target))
            }
        }
        if let target = remoteReviews.first(where: { $0.value === session })?.key {
            guard !session.isSubmitting else { return }
            session.isSubmitting = true
            Task {
                defer { session.isSubmitting = false }
                do {
                    if session.hostReviewPane {
                        _ = try await remoteHosts.agentQuery(target, query: .finishReview(paneID: session.paneID, text: text))
                    } else { try await remoteHosts.sendUserMessage(target, text: text) }
                    if remoteReviews[target] === session { sent() }
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
                if reviewSessions[session.paneID] === session { sent() }
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
        let owner: SidePaneOwner? = remote ? remoteReviews.first { $0.value === session }.map { .remote($0.key) } : .local(session.agentID)
        return ReviewActions(
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
            commitClosed: { [weak self] in self?.reviewCommitClosed(session) },
            setScope: { [weak self] scope in
                session.scopeChosen = true
                self?.setChangesScope(session, scope)
            },
            setOptions: { [weak self] options in self?.setChangesOptions(session, options) },
            refresh: { [weak self] in self?.reloadReview(session, reference: session.reference) },
            loadWholeFile: { [weak self] fileID in self?.loadWholeFile(session, fileID: fileID) },
            loadBranches: { [weak self] in self?.loadChangesBranches(session) },
            copyPatch: { [weak self] command in self?.copyChangesPatch(session, asCommand: command) },
            discard: { [weak self] in self?.discardReviewComments(session) },
            toggleMaximized: owner.map { owner in { [weak self] in self?.toggleSidePaneMaximized(owner) } }
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
            subagentInspector.open.remove(.remote(target))
            subagentInspector.clearNews(.remote(target), .changes)
            return
        }
        guard reviewSessions[session.paneID] === session else { return }
        removeReview(session)
    }

    /// Reviews dock in the side pane's Changes tab, which closes with its review; a review a
    /// remote client adopted from a layout leaf (older hosts split the layout) also closes that
    /// leaf.
    private func removeReview(_ session: ReviewSession) {
        reviewSessions.removeValue(forKey: session.paneID)
        let owner = SidePaneOwner.local(session.agentID)
        if subagentInspector.open.contains(owner) { subagentInspector.open.remove(owner) }
        subagentInspector.clearNews(owner, .changes)
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
        subagentInspector.forget(.local(agentID))
    }

    func pruneReviewSessions() {
        let liveAgents = Set(state.agents.map(\.id))
        let doomed = reviewSessions.values.filter { !liveAgents.contains($0.agentID) }
        for session in doomed {
            reviewSessions.removeValue(forKey: session.paneID)
        }
        let panes = subagentInspector
        for case .local(let id) in panes.open.union(panes.news.keys) where !liveAgents.contains(id) { panes.forget(.local(id)) }
    }

    // MARK: Loading

    /// Loads the review again: a Changes review its scope, a legacy review its side (nil the
    /// working tree, "pr" the PR). Comments are kept and re-anchor to the lines they were written
    /// on where the diff still has them.
    func reloadReview(_ session: ReviewSession, reference: String?) {
        if session.engine != nil {
            loadChanges(session)
            return
        }
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

    /// Resolve and load a legacy session's diff off the main thread, filling the session in place
    /// when done.
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
                session.adopt(files: result.files, truncated: [])
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

    /// Whether `session` is still the one its owner shows (a load that finishes after the review
    /// closed or was replaced drops its result).
    private func isCurrent(_ session: ReviewSession) -> Bool {
        reviewSessions[session.paneID] === session || remoteReviews.values.contains { $0 === session }
    }

    /// Loads a Changes review's scope: the list, then every file's hunks from its revision,
    /// landing together so the pane never shows one list's files with another's hunks. The scope
    /// menu's overview loads beside it.
    func loadChanges(_ session: ReviewSession) {
        guard let engine = session.engine else { return }
        let requestID = UUID()
        session.loadRequestID = requestID
        session.isLoading = true
        session.loadError = nil
        session.loadErrorIsNotice = false
        let scope = session.scope
        let options = session.options
        Task {
            do {
                let list = try await engine.list(scope, options)
                let diff = try await engine.diffs(list, options)
                guard isCurrent(session), session.loadRequestID == requestID else { return }
                let order = Dictionary(list.files.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
                session.list = list
                session.adopt(files: diff.files.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }, truncated: diff.truncated)
            } catch {
                guard isCurrent(session), session.loadRequestID == requestID else { return }
                session.list = nil
                session.files = []
                let changes = error as? ChangesError
                session.loadError = changes?.message ?? String(describing: error)
                session.loadErrorIsNotice = [ChangesError.unavailable, ChangesError.notARepository].contains(changes?.code)
            }
            session.isLoading = false
            if case .local(let agentID)? = owner(of: session) { checkouts?.refresh(agentID) }
        }
        loadChangesOverview(session)
    }

    /// The scope menu's counts, commits and pull request. The engine's default scope replaces
    /// the pane's guess while the reader has not picked one.
    func loadChangesOverview(_ session: ReviewSession) {
        guard let engine = session.engine else { return }
        Task {
            guard let overview = try? await engine.overview(), isCurrent(session) else { return }
            session.overview = overview
            if !session.scopeChosen, session.sentAt == nil, overview.repository != nil, overview.defaultScope != session.scope,
               session.scope.kind != .lastTurn {
                session.scope = overview.defaultScope
                loadChanges(session)
            }
        }
    }

    /// Picks what the pane compares, and loads it.
    func setChangesScope(_ session: ReviewSession, _ scope: ChangesScope) {
        guard session.engine != nil else { return }
        if session.scope != scope { session.scope = scope }
        loadChanges(session)
    }

    /// Hide whitespace changes, Load full files: the diff loads again with them.
    func setChangesOptions(_ session: ReviewSession, _ options: ChangesOptions) {
        guard session.options != options else { return }
        session.options = options
        loadChanges(session)
    }

    /// A fold between hunks opened: the file comes again, whole, from the same revision.
    func loadWholeFile(_ session: ReviewSession, fileID: String) {
        guard let engine = session.engine, let list = session.list, let entry = list.files.first(where: { $0.id == fileID }) else { return }
        var options = session.options
        options.fullFiles = true
        Task {
            do {
                let diff = try await engine.file(list.revision, entry, options)
                guard isCurrent(session), session.list?.revision == list.revision,
                      let index = session.files.firstIndex(where: { $0.id == fileID }) else { return }
                var files = session.files
                files[index] = diff.file
                var truncated = session.truncated
                if diff.truncated { truncated.insert(fileID) } else { truncated.remove(fileID) }
                session.adopt(files: files, truncated: truncated)
            } catch { remoteActionError = (error as? ChangesError)?.message ?? String(describing: error) }
        }
    }

    func loadChangesBranches(_ session: ReviewSession) {
        guard let engine = session.engine else { return }
        Task {
            do {
                let branches = try await engine.branches()
                if isCurrent(session) { session.branches = branches }
            } catch { remoteActionError = (error as? ChangesError)?.message ?? String(describing: error) }
        }
    }

    /// Copy as patch, or as a `git apply` command that applies it.
    func copyChangesPatch(_ session: ReviewSession, asCommand: Bool) {
        guard let engine = session.engine, let list = session.list else { return }
        let options = session.options
        Task {
            do {
                let patch = try await engine.patch(list.revision, options)
                guard !patch.truncated else {
                    remoteActionError = "This diff is too big to copy from the host. Nothing was copied."
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asCommand ? changesApplyCommand(patch.text) : patch.text, forType: .string)
            } catch { remoteActionError = (error as? ChangesError)?.message ?? String(describing: error) }
        }
    }

    private func owner(of session: ReviewSession) -> SidePaneOwner? {
        if reviewSessions[session.paneID] === session { return .local(session.agentID) }
        return remoteReviews.first { $0.value === session }.map { .remote($0.key) }
    }

    // MARK: Engines

    func makeChangesEngine(_ agentID: AgentID, _ cwd: String) -> ChangesEngine {
        changesEngineOverride?(agentID, cwd) ?? localChangesEngine(agentID: agentID, cwd: cwd)
    }

    /// Whether the agent has replied since its review was last sent: a review opened now starts
    /// on Last turn.
    func repliedSinceReview(_ owner: SidePaneOwner, latest: ChangesTurn?) -> Bool {
        guard let sentAt = reviewSentAt[owner], let latest, latest.startedAt >= sentAt else { return false }
        return latest.state != .running
    }

    /// This Mac's engine for an agent's review (`cwd`: the directory under review).
    func localChangesEngine(agentID: AgentID, cwd: String) -> ChangesEngine {
        let changes = server.changes
        return ChangesEngine(
            overview: { try await changes.overview(agentID: agentID, cwd: cwd) },
            list: { scope, options in try await changes.list(agentID: agentID, scope: scope, options: options, cwd: cwd) },
            diffs: { list, options in
                let files = try await changes.diffs(agentID: agentID, revision: list.revision, options: options, cwd: cwd)
                // The engine cuts a file at `ChangesLimits.fileLines`; one that reaches it was cut.
                let cut = files.filter { $0.hunks.reduce(0) { $0 + $1.lines.count } >= ChangesLimits.fileLines }
                return (files, Set(cut.map(\.id)))
            },
            file: { revision, file, options in
                try await changes.file(agentID: agentID, revision: revision, path: file.path, oldPath: file.oldPath, options: options, cwd: cwd)
            },
            branches: { try await changes.branches(agentID: agentID, cwd: cwd) },
            patch: { revision, options in (try await changes.patch(agentID: agentID, revision: revision, options: options, cwd: cwd), false) })
    }

    /// A remote host's engine (`changes.v1`): each file's hunks is its own request, a few at a
    /// time, each kept under the frame cap.
    func remoteChangesEngine(_ target: RemoteAgentRef) -> ChangesEngine {
        let query: @MainActor (RemoteAgentQuery) async throws -> RemoteAgentResult = { [weak self] query in
            guard let self else { throw ChangesError(ChangesError.unavailable, "Shepherd is closing.") }
            return try await self.remoteHosts.agentQuery(target, query: query)
        }
        func unexpected() -> ChangesError { ChangesError(ChangesError.invalid, "The host answered with something else.") }
        return ChangesEngine(
            overview: {
                guard case .changesOverview(let overview) = try await query(.changesOverview) else { throw unexpected() }
                return overview
            },
            list: { scope, options in
                guard case .changesList(let list) = try await query(.changesList(scope: scope, options: options)) else { throw unexpected() }
                return list
            },
            diffs: { list, options in
                var files: [DiffFile] = []
                var truncated: Set<String> = []
                try await withThrowingTaskGroup(of: ChangesFileDiff.self) { group in
                    var pending = list.files.makeIterator()
                    func next() {
                        guard let file = pending.next() else { return }
                        group.addTask { @MainActor in
                            guard case .changesFile(let diff) = try await query(.changesFile(revision: list.revision, path: file.path,
                                                                                               oldPath: file.oldPath, options: options))
                            else { throw unexpected() }
                            return diff
                        }
                    }
                    for _ in 0..<ChangesRemote.concurrentFiles { next() }
                    while let diff = try await group.next() {
                        files.append(diff.file)
                        if diff.truncated { truncated.insert(diff.file.id) }
                        next()
                    }
                }
                return (files, truncated)
            },
            file: { revision, file, options in
                guard case .changesFile(let diff) = try await query(.changesFile(revision: revision, path: file.path, oldPath: file.oldPath,
                                                                                 options: options)) else { throw unexpected() }
                return diff
            },
            branches: {
                guard case .changesBranches(let branches) = try await query(.changesBranches) else { throw unexpected() }
                return branches
            },
            patch: { revision, options in
                guard case .changesPatch(let text, let truncated) = try await query(.changesPatch(revision: revision, options: options))
                else { throw unexpected() }
                return (text, truncated)
            })
    }

    // MARK: Turns

    /// A changes card's Undo: puts back the turn's edits in the worktree. A refusal (a file
    /// changed since) names the files and changes nothing.
    func undoTurn(_ owner: SidePaneOwner, turnID: UUID) async -> String? {
        await runTurn(owner, turnID: turnID, redo: false)
    }

    func redoTurn(_ owner: SidePaneOwner, turnID: UUID) async -> String? {
        await runTurn(owner, turnID: turnID, redo: true)
    }

    private func runTurn(_ owner: SidePaneOwner, turnID: UUID, redo: Bool) async -> String? {
        do {
            switch owner {
            case .local(let agentID):
                _ = redo ? try await server.changes.redoTurn(agentID: agentID, turnID: turnID)
                    : try await server.changes.undoTurn(agentID: agentID, turnID: turnID)
            case .remote(let target):
                _ = try await remoteHosts.agentQuery(target, query: redo ? .changesRedoTurn(turnID: turnID) : .changesUndoTurn(turnID: turnID))
            }
            return nil
        } catch let error as ChangesError {
            return changesTurnRefusal(error, redo: redo)
        } catch {
            return String(describing: error)
        }
    }

    /// Start the agent's review (loading at once, filled in when git finishes: the pane must
    /// never wait on a subprocess). An agent's `review_diff` (`respond`) never opens the side pane
    /// or takes it from an inspected subagent: the Changes tab takes a dot, and with the pane
    /// closed so does the header's button (PaneStates: nothing opens by itself). Callers the user
    /// drove show the pane themselves (`showSidePane`).
    func beginReview(
        agentID: AgentID,
        cwd requestedCwd: String?,
        reference: String?,
        respond: ((ReviewOutcome) -> Void)? = nil
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
        let owner = SidePaneOwner.local(agentID)
        let panes = subagentInspector
        // What the agent is told, and the dot when the Changes tab is out of sight.
        func told(_ reloaded: Bool) {
            guard let respond else { return }
            let showing = panes.open.contains(owner) && panes.run(for: owner) == nil && panes.tab(for: owner) == .changes
            if !showing { panes.addNews(owner, .changes) }
            let lead = showing ? "Review pane already open; reloaded." : reloaded
                ? "Review reloaded in the side pane's Changes tab, which the user opens when they choose."
                : "Review ready in the side pane's Changes tab; the user opens it when they choose."
            respond(.submitted(text: lead + " The user's review will arrive as a message when they submit; continue only if you have unrelated work."))
        }
        // A git reference other than the PR's is not a scope: that review loads the old way.
        let usesEngine = reference == nil || reference == "pr"

        // One review per agent, regardless of entry point: an agent re-requesting a review
        // reloads the one it has.
        if let existing = reviewSessions.values.first(where: { $0.agentID == agentID }), (existing.engine != nil) == usesEngine {
            if existing.cwd != cwdPath {
                existing.retarget(cwd: cwdPath)
                if usesEngine { existing.engine = makeChangesEngine(agentID, cwdPath) }
            }
            if usesEngine {
                if reference == "pr" { existing.scope = .pullRequest; existing.scopeChosen = true }
                loadChanges(existing)
            } else {
                reloadReview(existing, reference: reference)
            }
            told(true)
            return
        }
        if let stale = reviewSessions.values.first(where: { $0.agentID == agentID }) { reviewSessions.removeValue(forKey: stale.paneID) }

        // The review sits in the agent's side pane: a view slot, not a layout leaf, so it never
        // touches the persisted layout.
        let session = ReviewSession(
            agentID: agentID,
            paneID: PaneID(),
            cwd: cwdPath,
            agentCwd: (piPane.cwd as NSString).expandingTildeInPath,
            reference: usesEngine ? nil : reference,
            isLoading: true
        )
        reviewSessions[session.paneID] = session
        // The tool returns immediately; the review itself arrives later as a
        // typed prompt message when the user submits.
        told(false)
        if usesEngine {
            session.engine = makeChangesEngine(agentID, cwdPath)
            // Branch for a worktree agent, else Uncommitted, until the engine's overview says;
            // Last turn once the agent has replied to a review.
            let replied = repliedSinceReview(owner, latest: threadStores.store(for: agentID).snapshot?.turnChanges?.last)
            session.scope = reference == "pr" ? .pullRequest : replied ? .lastTurn : agent.worktreeBase != nil ? .branch(base: nil) : .uncommitted
            session.scopeChosen = reference == "pr" || replied
            loadChanges(session)
        } else {
            loadReviewDiff(session)
        }
    }
}

enum ChangesRemote {
    /// Files a remote review asks for at once.
    static let concurrentFiles = 4
}

/// A shell command that applies `patch` in the current checkout (Copy git apply command).
func changesApplyCommand(_ patch: String) -> String {
    var marker = "SHEPHERD_PATCH"
    while patch.contains(marker) { marker += "_" }
    let body = patch.hasSuffix("\n") ? patch : patch + "\n"
    return "git apply --3way <<'\(marker)'\n\(body)\(marker)\n"
}

/// What the card says when Undo or Redo refuses.
func changesTurnRefusal(_ error: ChangesError, redo: Bool) -> String {
    guard error.code == ChangesError.changedSince, !error.files.isEmpty else { return error.message }
    let names = error.files.prefix(3).map { ($0 as NSString).lastPathComponent }
    let more = error.files.count > 3 ? " and \(error.files.count - 3) more" : ""
    let list = names.joined(separator: ", ") + more
    return redo ? "Didn’t redo: \(list) changed after the undo. Nothing was touched."
        : "Didn’t undo: \(list) changed after the turn. Nothing was touched."
}
