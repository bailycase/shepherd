import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Issues & PRs on this Mac: the destination, its pins in the sidebar, and the agent actions,
/// which hand a `ForgeBrief` to the existing thread paths (send to a thread, or start one).
@MainActor
extension ShepherdViewModel {
    /// The destination row and the palette's Open Issues & PRs.
    func openForge() {
        openDestination(.forge)
        Task { await forgeStore.start() }
    }

    /// A pin or a link: the destination on that item.
    func openForgeItem(_ ref: ForgeItemRef) {
        openDestination(.forge)
        Task {
            await forgeStore.start()
            await forgeStore.open(ref)
        }
    }

    /// The destination's back button: the thread it covered, else New thread.
    func leaveForge() {
        if let id = selectedAgentID, state.agents.contains(where: { $0.id == id }) {
            selectAgent(id)
        } else {
            openDestination(.newThread)
        }
        Task { await forgeStore.loadSidebar() }
    }

    func unpinForgeItem(_ ref: ForgeItemRef, title: String) {
        Task { await forgeStore.perform(.setPinned(ref: ref, title: title, pinned: false)) }
    }

    static func openForgeURL(_ ref: ForgeItemRef) {
        if let url = URL(string: ref.url) { NSWorkspace.shared.open(url) }
    }

    static func copyForgeLink(_ ref: ForgeItemRef) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ref.url, forType: .string)
    }

    // MARK: Agent actions

    /// Review with agent: a new thread reads the diff and reports.
    func forgeReviewWithAgent() {
        guard let detail = forgeStore.pullRequest else { return }
        runForgeBrief(ForgeBriefs.reviewPrompt(detail, repoPath: forgeStore.path(of: detail.ref.repo)),
                      name: "Review #\(detail.ref.number)", done: "Started a review of #\(detail.ref.number)")
    }

    /// Ask the agent: the pull request's thread, else a new one.
    func forgeAsk(_ question: String) async -> Bool {
        guard let detail = forgeStore.pullRequest else { return false }
        return await runForgeBriefNow(ForgeBriefs.askPrompt(detail, question: question, repoPath: forgeStore.path(of: detail.ref.repo)),
                                      name: nil, done: "Asked the agent about #\(detail.ref.number)")
    }

    /// Fix with agent on a failing check, with its log's tail.
    func forgeFixCheck(_ check: ForgeCheck) {
        guard let detail = forgeStore.pullRequest else { return }
        Task {
            let log = await forgeStore.loadLog(check)
            _ = await runForgeBriefNow(ForgeBriefs.fixCheckPrompt(detail, check: check, log: log, repoPath: forgeStore.path(of: detail.ref.repo)),
                                       name: "Fix \(check.displayName)", done: "Asked an agent to fix \(check.displayName)")
        }
    }

    /// Hand it to an agent (IssueReview): a thread on a new worktree named after the issue, which
    /// the page then shows as its linked thread (IssueStarted).
    func forgeStartIssueThread() {
        guard let issue = forgeStore.issue else { return }
        Task {
            if await runForgeBriefNow(ForgeBriefs.issueThreadPrompt(issue, repoPath: forgeStore.path(of: issue.ref.repo)),
                                      name: issue.summary.title, done: "Started a thread on #\(issue.ref.number)") {
                await forgeStore.loadDetail()
            }
        }
    }

    /// The Changes tab's Send to agent: its line comments, as review feedback.
    func forgeSendLineComments(_ session: ReviewSession) {
        guard let detail = forgeStore.pullRequest, !session.comments.isEmpty else { return }
        let comments = session.comments.enumerated().map { index, comment in
            ForgeLineComment(id: index, author: detail.viewer ?? "me", path: comment.filePath, line: comment.lineNumber,
                             diffHunk: comment.marker + comment.content, body: comment.text, createdAt: comment.createdAt)
        }
        session.isSubmitting = true
        Task {
            let sent = await runForgeBriefNow(ForgeBriefs.feedbackPrompt(detail, comments: comments, repoPath: forgeStore.path(of: detail.ref.repo)),
                                              name: nil, done: "Sent \(comments.count) comment\(comments.count == 1 ? "" : "s") to the agent")
            session.isSubmitting = false
            if sent { session.comments = [] }
        }
    }

    /// Merge (PRReviewMerge's options); Remove the worktree goes through the confirmed Delete
    /// Worktree path once the merge went through now.
    func forgeMerge() {
        guard let detail = forgeStore.pullRequest else { return }
        let options = forgeStore.mergeOptions
        Task {
            let merged = await forgeStore.perform(.merge(ref: detail.ref, method: options.method, whenReady: options.whenReady,
                                                         deleteBranch: options.deleteBranch))
            if merged, !options.whenReady, options.removeWorktree, let thread = detail.summary.thread, thread.worktreePath != nil {
                requestWorktreeDelete(thread.agentID)
            }
        }
    }

    /// Remove worktree (a merged or closed pull request's thread): the confirmed Delete Worktree path.
    func forgeRemoveWorktree() {
        guard let thread = forgeStore.pullRequest?.summary.thread, thread.worktreePath != nil else { return }
        requestWorktreeDelete(thread.agentID)
    }

    // MARK: Briefs

    private func runForgeBrief(_ brief: ForgeBrief, name: String?, done: String) {
        Task { _ = await runForgeBriefNow(brief, name: name, done: done) }
    }

    /// Sends the brief to its thread or starts one, then says so over the page.
    @discardableResult
    func runForgeBriefNow(_ brief: ForgeBrief, name: String?, done: String) async -> Bool {
        do {
            let id = try await deliverForgeBrief(brief, name: name)
            forgeStore.notice = ForgeNotice(text: done, agentID: id)
            return true
        } catch {
            forgeStore.actionError = ForgeError(.failed, (error as? CustomStringConvertible)?.description ?? "\(error)")
            return false
        }
    }

    /// `brief.agentID` set: the send-message path. Otherwise the create-thread path in `brief.cwd`,
    /// on a new worktree named `brief.worktreeBranch` when set.
    private func deliverForgeBrief(_ brief: ForgeBrief, name: String?) async throws -> AgentID {
        if let id = brief.agentID {
            guard state.agents.contains(where: { $0.id == id }) else { throw AgentStartFailure(message: "That thread is gone.") }
            try await sendUserMessage(brief.prompt, to: id)
            return id
        }
        guard let cwd = brief.cwd else {
            throw AgentStartFailure(message: "This repository has no checkout on this Mac. Add it as a space to hand work to an agent.")
        }
        guard let spaceID = await forgeSpace(for: cwd) else { throw AgentStartFailure(message: "Couldn’t add a space for \(cwd).") }
        var config = NewAgentConfig(spaceID: spaceID, workingDirectory: cwd, model: settings.defaultModel(piHome: server.pi.home),
                                    thinking: settings.defaultThinking, initialPrompt: brief.prompt)
        config.initialName = name
        if let branch = brief.worktreeBranch {
            let mode = settings.worktreeBaseMode
            let fetch = settings.worktreeFetchBeforeCreate
            let (path, base) = try await Task.detached(priority: .userInitiated) { () -> (String, String) in
                let resolution = GitWorktree.resolveBase(repo: cwd, mode: mode, fetchFirst: fetch)
                return (try GitWorktree.add(repo: cwd, branch: branch, from: resolution.startPoint), resolution.display)
            }.value
            config.workingDirectory = path
            config.worktreeBranch = branch
            config.worktreeBase = base
            config.worktreePath = path
        }
        return try await startAgent(config, selectAfter: false, focusWindow: false)
    }

    /// The space a brief's folder belongs to: the one at that path, the space of the agent working
    /// there, else a new one.
    private func forgeSpace(for cwd: String) async -> SpaceID? {
        func canonical(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
        }
        let wanted = canonical(cwd)
        if let space = state.spaces.first(where: { !$0.hidden && canonical($0.path) == wanted }) { return space.id }
        if let agent = state.agents.first(where: { $0.worktreePath.map(canonical) == wanted }) { return agent.spaceID }
        return await spaceForProject(at: URL(fileURLWithPath: cwd))
    }
}
