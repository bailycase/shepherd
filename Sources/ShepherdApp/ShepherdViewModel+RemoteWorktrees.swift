import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

extension ShepherdViewModel {
    func handleRemoteWorktree(_ agentID: AgentID, query: RemoteAgentQuery) async throws -> RemoteAgentResult {
        if case .deleteKeepingWorktree = query {
            try await deleteAgentPersisted(agentID)
            return .ok
        }
        if case .worktreeStatus(let id) = query {
            guard hostWorktreeOperationAgents[id] == agentID, let operation = hostWorktreeOperations[id] else {
                throw RemoteCreateAgentError("Operation is unknown. It may predate a host restart. Check the host before starting another operation.")
            }
            return .worktreeOperation(operation)
        }
        let operationID: UUID?
        switch query {
        case .deleteWorktree(let id, _, _), .finalizeWorktree(let id, _): operationID = id
        default: operationID = nil
        }
        if let id = operationID, let operation = hostWorktreeOperations[id] {
            guard hostWorktreeOperationAgents[id] == agentID else { throw RemoteCreateAgentError("Operation belongs to another agent") }
            return .worktreeOperation(operation)
        }
        guard let agent = server.state.agents.first(where: { $0.id == agentID }),
              let branch = agent.worktreeBranch,
              let space = server.state.spaces.first(where: { $0.id == agent.spaceID }) else {
            throw RemoteCreateAgentError("Worktree agent no longer exists")
        }
        let path = agent.worktreePath ?? GitWorktree.destination(repo: space.path, branch: branch)
        if case .worktreeSetup(let action) = query {
            let setup = WorktreeSetupModel(repoPath: space.path)
            switch action {
            case .check: break
            case .applyIdentity(let name, let email):
                await setup.applyIdentity(name: name, email: email)
            case .installCommandLineTools:
                await setup.installTools()
            case .enableDeleteBranchOnMerge:
                await setup.enableRepoSetting(.deleteBranchOnMerge)
            case .enableAutoMerge:
                await setup.enableRepoSetting(.allowAutoMerge)
            case .loginShell:
                let tab = try await openRemoteUtilityTerminal(agent: agent, cwd: space.path, key: "gh-login:\(agentID.rawValue)", command: "gh auth login")
                return .inspector(tab)
            }
            if let error = setup.actionError { throw RemoteCreateAgentError(error) }
            await setup.runAll()
            // Preserve a failed repair rather than replacing it with another probe.
            if setup.repoSettings.values.allSatisfy({ $0 == .unknown }), setup.states[.ghAuth]?.passed == true {
                await setup.probeRepoSettings()
            }
            return .worktreeSetup(setup.snapshot)
        }
        let identity = try await Task.detached { try GitWorktree.identity(at: path) }.value
        let repo = try await Task.detached { try GitWorktree.primaryCheckout(at: space.path) }.value
        guard identity.repo == repo, identity.branch == branch else {
            throw RemoteCreateAgentError("Checkout identity changed. Nothing was removed.")
        }
        if case .worktreeCommitCount(let base) = query {
            return .worktreeCommitCount(await WorktreeCommitCount.load(base: base, worktree: identity.path))
        }
        if case .worktreeDescription(let base, let title) = query {
            guard settings.worktreeGeneratePRDescription else { return .worktreeDescription(body: "") }
            let result = await hostPRDescriptionGenerator.generate(base: base, title: title, worktree: identity.path)
            return .worktreeDescription(body: result.body)
        }
        try verifyCheckoutUnused(identity.path, except: agentID)
        guard !hostBusyWorktrees.contains(identity.path) else {
            throw RemoteCreateAgentError("Another worktree operation is running for this checkout")
        }
        let warning = try await Task.detached { try GitWorktree.checkedUnreconciledWork(worktree: identity.path, branch: branch) }.value
        // Probes suspend the main actor. Recheck both operation identity and agent identity before accepting.
        if let id = operationID, let existing = hostWorktreeOperations[id] {
            guard hostWorktreeOperationAgents[id] == agentID else { throw RemoteCreateAgentError("Operation belongs to another agent") }
            return .worktreeOperation(existing)
        }
        guard server.state.agents.first(where: { $0.id == agentID })?.worktreeBranch == branch,
              server.state.agents.first(where: { $0.id == agentID })?.worktreePath == agent.worktreePath else {
            throw RemoteCreateAgentError("Agent changed during verification. Nothing was removed.")
        }
        try verifyCheckoutUnused(identity.path, except: agentID)
        switch query {
        case .worktreeInfo:
            let base: String
            if let recorded = agent.worktreeBase ?? identity.base {
                base = recorded
            } else {
                let head = await LoginShell.run("git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null", cwd: space.path, timeout: 20)
                let name = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                base = name.hasPrefix("origin/") ? name : "main"
            }
            return .worktreeInfo(RemoteWorktreeInfo(
                path: identity.path, branch: branch, warning: warning,
                defaults: RemoteFinalizeOptions(
                    base: base.hasPrefix("origin/") ? String(base.dropFirst(7)) : base,
                    title: agent.name, body: "", autoCommit: settings.worktreeAutoCommit,
                    deleteLocalBranch: settings.worktreeDeleteLocalBranch,
                    autoMergePR: settings.worktreeAutoMergePR, mergeMethod: settings.worktreeMergeMethod.rawValue
                ), generateDescription: settings.worktreeGeneratePRDescription,
                fingerprint: try await Task.detached { try GitWorktree.deletionFingerprint(worktree: identity.path) }.value
            ))
        case .deleteWorktree(let id, let confirmedWarning, let fingerprint):
            guard let fingerprint, warning == confirmedWarning,
                  try await Task.detached(operation: { try GitWorktree.deletionFingerprint(worktree: identity.path) }).value == fingerprint else {
                throw RemoteCreateAgentError("Worktree contents changed. Reopen the confirmation before deleting.")
            }
            guard !hostBusyWorktrees.contains(identity.path) else { throw RemoteCreateAgentError("Checkout operation already running") }
            try verifyCheckoutUnused(identity.path, except: agentID)
            acceptWorktreeOperation(id, agentID: agentID, path: identity.path)
            Task {
                defer { hostBusyWorktrees.remove(identity.path) }
                do {
                    hostWorktreeOperations[id]?.progress = ["stopping agent"]
                    try await retireWorktreeAgent(agentID)
                    // The confirmation covers the same loss warning after the writer has stopped.
                    let current = try await Task.detached {
                        try GitWorktree.checkedUnreconciledWork(worktree: identity.path, branch: branch)
                    }.value
                    guard current == confirmedWarning else {
                        throw RemoteCreateAgentError("Work changed while the agent stopped. Checkout was kept.")
                    }
                    try verifyCheckoutUnused(identity.path, except: agentID)
                    try await Task.detached { try GitWorktree.remove(repo: repo, branch: branch, worktree: identity.path, fingerprint: fingerprint) }.value
                    hostWorktreeOperations[id]?.progress = ["agent, checkout and local branch removed"]
                } catch { hostWorktreeOperations[id]?.error = String(describing: error) }
                hostWorktreeOperations[id]?.finished = true
            }
            return .worktreeOperation(hostWorktreeOperations[id]!)
        case .finalizeWorktree(let id, let options):
            guard !options.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["squash", "merge", "rebase"].contains(options.mergeMethod) else {
                throw RemoteCreateAgentError("Choose a base, title and supported merge method")
            }
            guard !hostBusyWorktrees.contains(identity.path) else { throw RemoteCreateAgentError("Checkout operation already running") }
            try verifyCheckoutUnused(identity.path, except: agentID)
            acceptWorktreeOperation(id, agentID: agentID, path: identity.path)
            Task {
                defer { hostBusyWorktrees.remove(identity.path) }
                let finalizer = WorktreeFinalizer()
                finalizer.cleanCheck = { path, branch in
                    do { return try GitWorktree.checkedUnreconciledWork(worktree: path, branch: branch) }
                    catch { return "Could not verify checkout: \(error)" }
                }
                finalizer.beforeCleanup = {
                    try self.verifyCheckoutUnused(identity.path, except: agentID)
                    try await self.retireWorktreeAgent(agentID)
                    try self.verifyCheckoutUnused(identity.path, except: agentID)
                    try await Task.detached { try GitWorktree.verifyIdentity(worktree: identity.path, repo: repo, branch: branch) }.value
                    if let work = try await Task.detached(operation: {
                        try GitWorktree.checkedUnreconciledWork(worktree: identity.path, branch: branch)
                    }).value { throw RemoteCreateAgentError("Checkout changed: \(work). Kept checkout.") }
                }
                let progress = Task {
                    while !Task.isCancelled {
                        hostWorktreeOperations[id]?.progress = Self.worktreeProgress(finalizer)
                        hostWorktreeOperations[id]?.prURL = finalizer.prURL
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                await finalizer.run(.init(repo: repo, worktree: identity.path, branch: branch,
                                          base: options.base, title: options.title, body: options.body,
                                          autoCommit: options.autoCommit, deleteLocalBranch: options.deleteLocalBranch,
                                          autoMergePR: options.autoMergePR, mergeMethod: options.mergeMethod))
                progress.cancel()
                hostWorktreeOperations[id]?.progress = Self.worktreeProgress(finalizer)
                hostWorktreeOperations[id]?.prURL = finalizer.prURL
                if finalizer.phase != .succeeded {
                    hostWorktreeOperations[id]?.error = "Finalize stopped. Review the failed step before starting another operation."
                }
                hostWorktreeOperations[id]?.finished = true
            }
            return .worktreeOperation(hostWorktreeOperations[id]!)
        default: throw RemoteCreateAgentError("Unsupported worktree request")
        }
    }

    func verifyCheckoutAvailable(_ cwd: String) throws {
        let path = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
        guard !hostBusyWorktrees.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw RemoteCreateAgentError("A worktree operation is running for this checkout")
        }
    }

    func verifyCheckoutUnused(_ path: String, except agentID: AgentID) throws {
        for cwd in startingCheckoutUsers.values {
            let canonical = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
            if canonical == path || canonical.hasPrefix(path + "/") { throw RemoteCreateAgentError("Another agent is starting in this checkout") }
        }
        let ownTabs = Set(server.state.agents.filter { $0.id == agentID }.map(\.tabID))
        let tabs = Dictionary((state.tabs + server.state.tabs).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values
        for tab in tabs where !ownTabs.contains(tab.id) && tab.inspectorFor != agentID {
            if tab.layout.leaves.contains(where: {
                let cwd = URL(fileURLWithPath: ($0.cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
                return cwd == path || cwd.hasPrefix(path + "/")
            }) { throw RemoteCreateAgentError("Another workspace uses this checkout. Checkout was kept.") }
        }
    }

    private func acceptWorktreeOperation(_ id: UUID, agentID: AgentID, path: String) {
        hostBusyWorktrees.insert(path)
        hostWorktreeOperationAgents[id] = agentID
        hostWorktreeOperations[id] = RemoteWorktreeOperation(id: id)
    }

    private static func worktreeProgress(_ finalizer: WorktreeFinalizer) -> [String] {
        WorktreeFinalizer.Step.allCases.map { step in
            let detail: String
            switch finalizer.states[step] ?? .pending {
            case .pending: detail = "pending"
            case .running: detail = "working…"
            case .done(let text): detail = text
            case .skipped(let text): detail = text
            case .failed(let text): detail = "failed: \(text)"
            }
            return "\(step.label): \(detail)"
        }
    }

    private func retireWorktreeAgent(_ agentID: AgentID) async throws {
        guard let agent = server.state.agents.first(where: { $0.id == agentID }) else {
            throw RemoteCreateAgentError("Agent no longer exists; checkout was kept")
        }
        let sessionIDs = server.state.tabs.filter { $0.id == agent.tabID || $0.inspectorFor == agentID }
            .flatMap { $0.layout.leaves.compactMap(\.sessionID) }
        if let tail = persistenceTail { await tail.value }
        try await deleteAgentPersisted(agentID, worktreeOperation: true)
        let deadline = ContinuousClock.now + .seconds(10)
        for sessionID in sessionIDs {
            while await server.sessionInfo(sessionID: sessionID)?.isAlive == true {
                guard ContinuousClock.now < deadline else { throw RemoteCreateAgentError("Agent did not stop. Checkout was kept.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
