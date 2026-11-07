import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What a workspace owner (the app's view model in process, or the headless host) gives the
/// worktree and commit-from-review queries.
public struct WorktreeHosting {
    /// Settings ▸ Worktrees, read at each request.
    public struct Defaults: Sendable {
        public var autoCommit: Bool
        public var deleteLocalBranch: Bool
        public var autoMergePR: Bool
        public var mergeMethod: String
        public var generateDescription: Bool

        public init(autoCommit: Bool, deleteLocalBranch: Bool, autoMergePR: Bool, mergeMethod: String, generateDescription: Bool) {
            self.autoCommit = autoCommit
            self.deleteLocalBranch = deleteLocalBranch
            self.autoMergePR = autoMergePR
            self.mergeMethod = mergeMethod
            self.generateDescription = generateDescription
        }
    }

    public var defaults: @MainActor () -> Defaults
    /// Deletes an agent. `true` when a worktree operation already holds its checkout.
    public var deleteAgent: @MainActor (AgentID, Bool) async throws -> Void
    /// Tabs besides the server's that may use a checkout (the app's own copy of the workspace).
    public var tabs: @MainActor () -> [Tab]
    /// Opens a terminal tab running a command (agent, folder, key, command): `gh auth login`.
    /// Nil where the owner has no such tab.
    public var terminal: (@MainActor (Agent, String, String, String) async throws -> TabID)?
    /// A commit from review finished for this agent.
    public var committed: @MainActor (AgentID) -> Void

    public init(defaults: @escaping @MainActor () -> Defaults, deleteAgent: @escaping @MainActor (AgentID, Bool) async throws -> Void,
                tabs: @escaping @MainActor () -> [Tab] = { [] },
                terminal: (@MainActor (Agent, String, String, String) async throws -> TabID)? = nil,
                committed: @escaping @MainActor (AgentID) -> Void = { _ in }) {
        self.defaults = defaults
        self.deleteAgent = deleteAgent
        self.tabs = tabs
        self.terminal = terminal
        self.committed = committed
    }
}

/// A client's worktree requests (info, setup, delete, finalize) and commits from review, with
/// the operations they start, polled by id. One per workspace owner; the checkouts it holds
/// (`busy`) and the ones agents are starting in (`starting`) keep two operations, or an
/// operation and a new agent, out of the same checkout.
@MainActor @Observable
public final class WorktreeQueries {
    public var operations: [UUID: RemoteWorktreeOperation] = [:]
    public var operationAgents: [UUID: AgentID] = [:]
    public var busy: Set<String> = []
    public var starting: [UUID: String] = [:]
    @ObservationIgnored public var hosting: WorktreeHosting?
    @ObservationIgnored public var descriptions: WorktreePRDescriptionGenerator
    @ObservationIgnored public var commitRunner: ReviewCommitGit.Runner = { await LoginShell.run($0, cwd: $1) }
    @ObservationIgnored private unowned let server: SessionServer

    public init(server: SessionServer) {
        self.server = server
        self.descriptions = WorktreePRDescriptionGenerator(pi: server.pi)
    }

    private func hosted() throws -> WorktreeHosting {
        guard let hosting else { throw RemoteCreateAgentError("Worktrees are unavailable on the host.") }
        return hosting
    }

    public func worktree(_ agentID: AgentID, query: RemoteAgentQuery) async throws -> RemoteAgentResult {
        let hosting = try hosted()
        let defaults = hosting.defaults()
        if case .deleteKeepingWorktree = query {
            try await hosting.deleteAgent(agentID, false)
            return .ok
        }
        if case .worktreeStatus(let id) = query {
            guard operationAgents[id] == agentID, let operation = operations[id] else {
                throw RemoteCreateAgentError("Operation is unknown. It may predate a host restart. Check the host before starting another operation.")
            }
            return .worktreeOperation(operation)
        }
        let operationID: UUID?
        switch query {
        case .deleteWorktree(let id, _, _), .finalizeWorktree(let id, _): operationID = id
        default: operationID = nil
        }
        if let id = operationID, let operation = operations[id] {
            guard operationAgents[id] == agentID else { throw RemoteCreateAgentError("Operation belongs to another agent") }
            return .worktreeOperation(operation)
        }
        guard let agent = server.state.agents.first(where: { $0.id == agentID }),
              let branch = agent.worktreeBranch,
              let space = server.state.spaces.first(where: { $0.id == agent.spaceID }) else {
            throw RemoteCreateAgentError("Worktree agent no longer exists")
        }
        let path = agent.worktreePath ?? GitWorktree.existingDestination(repo: space.path, branch: branch)
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
                guard let terminal = hosting.terminal else { throw RemoteCreateAgentError("Run gh auth login in a terminal on the host.") }
                let tab = try await terminal(agent, space.path, "gh-login:\(agentID.rawValue)", "gh auth login")
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
            guard defaults.generateDescription else { return .worktreeDescription(body: "") }
            let result = await descriptions.generate(base: base, title: title, worktree: identity.path)
            return .worktreeDescription(body: result.body)
        }
        try verifyCheckoutUnused(identity.path, except: agentID)
        guard !busy.contains(identity.path) else {
            throw RemoteCreateAgentError("Another worktree operation is running for this checkout")
        }
        let warning = try await Task.detached { try GitWorktree.checkedUnreconciledWork(worktree: identity.path, branch: branch) }.value
        // Probes suspend the main actor. Recheck both operation identity and agent identity before accepting.
        if let id = operationID, let existing = operations[id] {
            guard operationAgents[id] == agentID else { throw RemoteCreateAgentError("Operation belongs to another agent") }
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
                    title: agent.name, body: "", autoCommit: defaults.autoCommit,
                    deleteLocalBranch: defaults.deleteLocalBranch,
                    autoMergePR: defaults.autoMergePR, mergeMethod: defaults.mergeMethod
                ), generateDescription: defaults.generateDescription,
                fingerprint: try await Task.detached { try GitWorktree.deletionFingerprint(worktree: identity.path) }.value
            ))
        case .deleteWorktree(let id, let confirmedWarning, let fingerprint):
            guard let fingerprint, warning == confirmedWarning,
                  try await Task.detached(operation: { try GitWorktree.deletionFingerprint(worktree: identity.path) }).value == fingerprint else {
                throw RemoteCreateAgentError("Worktree contents changed. Reopen the confirmation before deleting.")
            }
            guard !busy.contains(identity.path) else { throw RemoteCreateAgentError("Checkout operation already running") }
            try verifyCheckoutUnused(identity.path, except: agentID)
            acceptWorktreeOperation(id, agentID: agentID, path: identity.path)
            Task {
                defer { busy.remove(identity.path) }
                do {
                    operations[id]?.progress = ["stopping agent"]
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
                    operations[id]?.progress = ["agent, checkout and local branch removed"]
                } catch { operations[id]?.error = String(describing: error) }
                operations[id]?.finished = true
            }
            return .worktreeOperation(operations[id]!)
        case .finalizeWorktree(let id, let options):
            guard !options.base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !options.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["squash", "merge", "rebase"].contains(options.mergeMethod) else {
                throw RemoteCreateAgentError("Choose a base, title and supported merge method")
            }
            guard !busy.contains(identity.path) else { throw RemoteCreateAgentError("Checkout operation already running") }
            try verifyCheckoutUnused(identity.path, except: agentID)
            acceptWorktreeOperation(id, agentID: agentID, path: identity.path)
            Task {
                defer { busy.remove(identity.path) }
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
                        operations[id]?.progress = Self.worktreeProgress(finalizer)
                        operations[id]?.prURL = finalizer.prURL
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                await finalizer.run(.init(repo: repo, worktree: identity.path, branch: branch,
                                          base: options.base, title: options.title, body: options.body,
                                          autoCommit: options.autoCommit, deleteLocalBranch: options.deleteLocalBranch,
                                          autoMergePR: options.autoMergePR, mergeMethod: options.mergeMethod))
                progress.cancel()
                operations[id]?.progress = Self.worktreeProgress(finalizer)
                operations[id]?.prURL = finalizer.prURL
                if finalizer.phase != .succeeded {
                    operations[id]?.error = "Finalize stopped. Review the failed step before starting another operation."
                }
                operations[id]?.finished = true
            }
            return .worktreeOperation(operations[id]!)
        default: throw RemoteCreateAgentError("Unsupported worktree request")
        }
    }

    public func verifyCheckoutAvailable(_ cwd: String) throws {
        let path = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
        guard !busy.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw RemoteCreateAgentError("A worktree operation is running for this checkout")
        }
    }

    public func verifyCheckoutUnused(_ path: String, except agentID: AgentID) throws {
        for cwd in starting.values {
            let canonical = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
            if canonical == path || canonical.hasPrefix(path + "/") { throw RemoteCreateAgentError("Another agent is starting in this checkout") }
        }
        let ownTabs = Set(server.state.agents.filter { $0.id == agentID }.map(\.tabID))
        let tabs = Dictionary(((hosting?.tabs() ?? []) + server.state.tabs).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values
        for tab in tabs where !ownTabs.contains(tab.id) {
            if tab.layout.leaves.contains(where: {
                let cwd = URL(fileURLWithPath: ($0.cwd as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
                return cwd == path || cwd.hasPrefix(path + "/")
            }) { throw RemoteCreateAgentError("Another workspace uses this checkout. Checkout was kept.") }
        }
    }

    private func acceptWorktreeOperation(_ id: UUID, agentID: AgentID, path: String) {
        busy.insert(path)
        operationAgents[id] = agentID
        operations[id] = RemoteWorktreeOperation(id: id)
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
        let sessionIDs = server.state.tabs.filter { $0.id == agent.tabID }
            .flatMap { $0.layout.leaves.compactMap(\.sessionID) }
        try await hosted().deleteAgent(agentID, true)
        let deadline = ContinuousClock.now + .seconds(10)
        for sessionID in sessionIDs {
            while await server.sessionInfo(sessionID: sessionID)?.isAlive == true {
                guard ContinuousClock.now < deadline else { throw RemoteCreateAgentError("Agent did not stop. Checkout was kept.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    public func commit(_ agentID: AgentID, query: RemoteAgentQuery, cwd override: String? = nil) async throws -> RemoteAgentResult {
        let hosting = try hosted()
        let defaults = hosting.defaults()
        if case .worktreeStatus(let id) = query {
            guard operationAgents[id] == agentID, let operation = operations[id] else {
                throw ReviewCommitRefusal("Operation is unknown. It may predate a host restart. Check the repository before committing again.")
            }
            return .worktreeOperation(operation)
        }
        guard let agent = server.state.agents.first(where: { $0.id == agentID }) else { throw ReviewCommitRefusal("Agent no longer exists") }
        let cwd = ((override ?? agentDirectory(agent)) as NSString).expandingTildeInPath
        switch query {
        case .commitInfo:
            return .commitInfo(try await ReviewCommitGit.info(cwd: cwd, agentWorking: agent.status == .working,
                                                              draftsMessage: defaults.generateDescription,
                                                              runner: commitRunner))
        case .commitMessage(let paths):
            let root = try await ReviewCommitGit.inspect(cwd: cwd, runner: commitRunner).root
            guard defaults.generateDescription else {
                let files = try await Task.detached { try GitDiff.load(cwd: root, reference: nil) }.value
                let wanted = Set(paths)
                let fallback = reviewCommitFallbackMessage(reviewCommitFiles(files) { _ in "" }.filter { $0.paths.contains(where: wanted.contains) })
                return .commitMessage(title: fallback.title, body: fallback.body, drafted: false)
            }
            let message = await ReviewCommitGit.draftMessage(root: root, paths: paths, pi: server.pi) { await LoginShell.run($0, cwd: $1, timeout: 45) }
            return .commitMessage(title: message.title, body: message.body, drafted: message.drafted)
        case .commit(let id, let options):
            if let existing = operations[id] {
                guard operationAgents[id] == agentID else { throw ReviewCommitRefusal("Operation belongs to another agent") }
                return .worktreeOperation(existing)
            }
            if agent.status == .working && !options.confirmedWhileWorking {
                throw ReviewCommitRefusal("\(agent.name) is working, so its files may still change. Confirm to commit anyway.")
            }
            let root = try await ReviewCommitGit.inspect(cwd: cwd, runner: commitRunner).root
            let checkout = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardized.path
            // The inspection suspended: an operation with this id may have started meanwhile.
            if let existing = operations[id], operationAgents[id] == agentID { return .worktreeOperation(existing) }
            guard !busy.contains(where: { checkout == $0 || checkout.hasPrefix($0 + "/") || $0.hasPrefix(checkout + "/") }) else {
                throw ReviewCommitRefusal("Another operation is running in this checkout. Try again when it finishes.")
            }
            busy.insert(checkout)
            operationAgents[id] = agentID
            operations[id] = RemoteWorktreeOperation(id: id, progress: ["\(ReviewCommitStepLabel.check): working…"])
            let committer = ReviewCommitter()
            committer.runner = commitRunner
            Task {
                defer { busy.remove(checkout) }
                let progress = Task {
                    while !Task.isCancelled {
                        operations[id]?.progress = committer.progress
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                await committer.run(options, cwd: root)
                progress.cancel()
                operations[id]?.progress = committer.progress
                operations[id]?.prURL = committer.prURL
                if committer.phase != .succeeded {
                    operations[id]?.error = committer.failure ?? "The commit stopped. Nothing else changed."
                }
                operations[id]?.finished = true
                hosting.committed(agentID)
            }
            return .worktreeOperation(operations[id]!)
        default:
            throw ReviewCommitRefusal("Unsupported commit request")
        }
    }

    /// The directory an agent works in: its pi pane's.
    private func agentDirectory(_ agent: Agent) -> String {
        let tab = server.state.tabs.first { $0.id == agent.tabID }
        return tab?.layout.leaves.first { $0.agentID == agent.id }?.cwd ?? tab?.layout.firstLeaf.cwd ?? ""
    }

}

extension SessionServer {
    /// A client's worktree requests and commits from review, answered with no app. Once per
    /// server, before clients connect. The rest of `agentQuery` stays the app's for now.
    @MainActor
    @discardableResult
    public func serveWorktrees(_ hosting: WorktreeHosting) -> WorktreeQueries {
        let queries = WorktreeQueries(server: self)
        queries.hosting = hosting
        onRemoteAgentQuery = { agentID, query, completion in
            Task { @MainActor in
                do {
                    switch query {
                    case .deleteKeepingWorktree, .worktreeInfo, .deleteWorktree, .finalizeWorktree, .worktreeStatus, .worktreeSetup,
                         .worktreeCommitCount, .worktreeDescription:
                        completion(.success(try await queries.worktree(agentID, query: query)))
                    case .commitInfo, .commitMessage, .commit:
                        completion(.success(try await queries.commit(agentID, query: query)))
                    default:
                        throw RemoteCreateAgentError("Open Shepherd on the host for this.")
                    }
                } catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
        return queries
    }
}
