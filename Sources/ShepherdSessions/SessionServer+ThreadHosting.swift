import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What the host starts a client's threads and terminals with (`serveThreads`), read
/// at each request.
public struct ThreadHosting {
    public struct Defaults: Sendable {
        public var model: String?
        public var thinking: ThinkingLevel
        public var serviceTier: ServiceTier
        public var worktreeBaseMode: WorktreeBaseMode
        public var worktreeFetchBeforeCreate: Bool

        public init(model: String?, thinking: ThinkingLevel, serviceTier: ServiceTier,
                    worktreeBaseMode: WorktreeBaseMode, worktreeFetchBeforeCreate: Bool) {
            self.model = model
            self.thinking = thinking
            self.serviceTier = serviceTier
            self.worktreeBaseMode = worktreeBaseMode
            self.worktreeFetchBeforeCreate = worktreeFetchBeforeCreate
        }
    }

    public var defaults: @MainActor () -> Defaults
    public var launch: @MainActor () -> AgentLaunchSettings
    /// What each agent's pi gets for MCP.
    public var mcp: AgentSpawn.MCP
    /// A terminal's shell: the user's login command.
    public var shell: @MainActor () -> SessionCommand

    public init(defaults: @escaping @MainActor () -> Defaults, launch: @escaping @MainActor () -> AgentLaunchSettings,
                mcp: @escaping AgentSpawn.MCP = { _, _, _, _, _ in nil }, shell: @escaping @MainActor () -> SessionCommand) {
        self.defaults = defaults
        self.launch = launch
        self.mcp = mcp
        self.shell = shell
    }
}

/// Threads and terminals on the host: the requests a client (the app over `host.sock`, an
/// iPhone, another Mac) makes of them, and an agent's own `terminal_*` tools, answered here. A terminal's shell starts when a client asks for it.
extension SessionServer {
    /// Serves threads and terminals from here on. Once per server, before clients connect.
    @MainActor
    public func serveThreads(_ hosting: ThreadHosting) {
        onRemoteCreationOptions = { [weak self] spaceID, cwd, fetchFirst, completion in
            Task { @MainActor in
                guard let self, let space = self.state.spaces.first(where: { $0.id == spaceID }) else {
                    return completion(.failure(RemoteCreateAgentError("Space no longer exists")))
                }
                let defaults = hosting.defaults()
                let fetch = fetchFirst ?? defaults.worktreeFetchBeforeCreate
                let resolution = await Task.detached {
                    cwd == nil ? GitWorktree.BaseResolution(startPoint: nil, display: "", note: "")
                        : GitWorktree.resolveBase(repo: cwd ?? space.path, mode: defaults.worktreeBaseMode,
                                                  fetchFirst: fetch, projectBase: space.worktreeBase)
                }.value
                completion(.success(.init(base: resolution.display, note: resolution.note, fetchFirst: fetch,
                                          model: defaults.model, thinking: defaults.thinking, serviceTier: defaults.serviceTier)))
            }
        }
        onRemoteCreateAgent = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do { completion(.success(try await self.startRequestedAgent(request, hosting: hosting))) }
                catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
        onRemoteAgentAction = { [weak self] agentID, action, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do {
                    try await self.perform(action, on: agentID, hosting: hosting)
                    completion(.success(()))
                } catch {
                    completion(.failure(RemoteCreateAgentError(String(describing: error))))
                }
            }
        }
        let panes: (PaneRequest, @escaping (PaneOutcome) -> Void) -> Void = { [weak self] request, respond in
            Task { @MainActor in
                guard let self else { return respond(.failed(code: "unavailable", message: "host is shutting down")) }
                respond(await self.handleTerminalRequest(request, hosting: hosting))
            }
        }
        onPaneRequest = panes
        onRemotePaneRequest = panes
        // An agent's agent_* tools: its peers are this host's threads.
        serveAgentPeers(AgentPeerHosting(
            defaults: { let defaults = hosting.defaults(); return (defaults.model, defaults.thinking) },
            startAgent: { [unowned self] config in
                try await startNewAgent(config, launch: hosting.launch(), defaultServiceTier: hosting.defaults().serviceTier, mcp: hosting.mcp)
            },
            deleteAgent: { [unowned self] id, done in
                Task { @MainActor in
                    do { try await deleteAgent(id); done(nil) } catch { done(error) }
                }
            },
            moveThread: { [unowned self] id, spaceID in try await moveRequestedThread(id, to: spaceID, hosting: hosting) }))
        // The branch picker's "move here" restarts pi, so it needs the launch settings here; every
        // other query goes on to `serveAgentQueries`' handler.
        let queries = onRemoteAgentQuery
        onRemoteAgentQuery = { [weak self] agentID, query, local, completion in
            guard case .moveToCheckout(let path, let branch) = query else {
                guard let queries else { return completion(.failure(RemoteCreateAgentError("Open Shepherd on the host for this."))) }
                return queries(agentID, query, local, completion)
            }
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do {
                    try await self.restartingAfterMove(agentID, hosting: hosting) {
                        try await self.moveThreadToCheckout(agentID, path: path, branch: branch)
                    }
                    completion(.success(.ok))
                } catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
        watchCheckouts()
        // A client opened a thread whose pi has not started since the host did.
        onNativeThreadDemand = { [weak self] agentID in
            Task { @MainActor in await self?.startThreadPi(agentID, hosting: hosting) }
        }
        serveDesigns(DesignHosting(startAgent: { [weak self] design, brief, options in
            guard let self else { throw RemoteCreateAgentError("host is shutting down") }
            return try await self.startDesignAgent(design, brief: brief, options: options, hosting: hosting)
        }))
        // No web view here: the app's window draws boards.
        relayDesignDrawingToApp()
        // Nor a window: review_diff and Remove space's confirmation are the app's.
        relayWindowRequestsToApp()
    }

    /// The header's branch chip and recorded worktree branches with no app: each thread's
    /// checkout read after the events the app's view model reads it after (a thread appearing, a
    /// tool that may write files, a turn starting or ending).
    @MainActor
    private func watchCheckouts() {
        let monitor = CheckoutMonitor(read: CheckoutMonitor.git) { [weak self] ids, cwd, checkout in
            await self?.setAgentCheckouts(ids, checkout, directory: cwd)
        }
        let (onState, onTool, onStatus) = (onStateChanged, onAgentToolFinished, onAgentStatus)
        onStateChanged = { state in
            onState?(state)
            MainActor.assumeIsolated { monitor.sync(directories: CheckoutMonitor.directories(state), order: state.agents.map(\.id)) }
        }
        onAgentToolFinished = { id, tool in
            onTool?(id, tool)
            MainActor.assumeIsolated { if CheckoutMonitor.touchesFiles(tool: tool) { monitor.refresh(id, after: .seconds(1)) } }
        }
        onAgentStatus = { id, status, failure in
            onStatus?(id, status, failure)
            MainActor.assumeIsolated { monitor.refresh(id, after: .milliseconds(300)) }
        }
        // The thread the app shows, after a selection or the app coming back: a commit in a
        // terminal or an editor's save changed no state.
        onThreadFocused = { id in MainActor.assumeIsolated { monitor.refresh(id, priority: true) } }
        monitor.sync(directories: CheckoutMonitor.directories(state), order: state.agents.map(\.id))
    }

    /// Starts a thread's pi with the host's launch settings; a failure is logged.
    @MainActor
    private func startThreadPi(_ agentID: AgentID, hosting: ThreadHosting, checksResume: Bool = true, model: String? = nil) async {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return }
        var spawn = AgentSpawn(agent: agent, cwd: "", settings: hosting.launch())
        spawn.mcp = hosting.mcp
        spawn.checksResume = checksResume
        if let model { spawn.takeModelOverride = { model } }
        do {
            _ = try await respawnAgent(spawn)
        } catch let failed as PaneBindingFailed {
            killSession(failed.sessionID)
        } catch {
            ShepherdLog.warning("start of \(agentID) failed: \(error)")
        }
    }

    /// Moves a thread to another space as the app's drag does (`moveThread` stops its pi). A pi
    /// that ran starts again in the new space, or in the old one when the move failed after
    /// stopping it; a thread that was dormant stays dormant until a client opens it.
    @MainActor
    private func moveRequestedThread(_ agentID: AgentID, to spaceID: SpaceID, hosting: ThreadHosting) async throws {
        try await restartingAfterMove(agentID, hosting: hosting) { try await self.moveThread(agentID, to: spaceID) }
    }

    /// `move` stops the thread's pi (`relocateThread`); a pi that ran starts again afterwards,
    /// wherever the thread now is.
    @MainActor
    private func restartingAfterMove(_ agentID: AgentID, hosting: ThreadHosting, _ move: () async throws -> Bool) async throws {
        let sessionID = state.agents.first { $0.id == agentID }.flatMap { agent in
            state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: agent.paneID ?? PaneID())?.sessionID
        }
        let wasAlive = if let sessionID { await sessionInfo(sessionID: sessionID)?.isAlive == true } else { false }
        do {
            guard try await move() else { return }
        } catch {
            // Only a pi the move had already stopped starts again.
            if wasAlive, let sessionID, await sessionInfo(sessionID: sessionID)?.isAlive != true { await startThreadPi(agentID, hosting: hosting) }
            throw error
        }
        if wasAlive { await startThreadPi(agentID, hosting: hosting) }
    }

    /// A client's new thread, in a new worktree when it names a branch.
    @MainActor
    func startRequestedAgent(_ request: RemoteCreateAgentRequest, hosting: ThreadHosting) async throws -> AgentID {
        let defaults = hosting.defaults()
        var spaceID = request.spaceID, cwd = request.cwd
        if request.standalone, let agentID = request.agentID {
            (spaceID, cwd) = try await standaloneThreadFolder(for: agentID)
        }
        guard let space = state.spaces.first(where: { $0.id == spaceID }) else {
            throw RemoteCreateAgentError("Space no longer exists")
        }
        var config = NewAgentConfig(spaceID: spaceID, workingDirectory: cwd ?? space.path,
                                    model: request.model ?? defaults.model, thinking: request.thinking ?? defaults.thinking,
                                    initialPrompt: request.initialPrompt, initialImages: request.initialImages,
                                    serviceTier: request.serviceTier)
        config.initialName = request.name
        config.piSessionID = request.piSessionID
        config.reservedAgentID = request.agentID
        if let path = request.worktreePath, let branch = request.worktreeBranch {
            // An existing checkout (an imported worktree): it must be the space's repository's, on `branch`.
            let identity = try await Task.detached { try GitWorktree.identity(at: path) }.value
            let repo = try await Task.detached { try GitWorktree.primaryCheckout(at: space.path) }.value
            guard identity.repo == repo, identity.branch == branch else {
                throw RemoteCreateAgentError("That checkout isn't \(branch) of \(space.name)'s repository.")
            }
            config.workingDirectory = identity.path
            config.worktreeBranch = branch
            config.worktreeBase = request.worktreeBase
            config.worktreePath = identity.path
        } else if let branch = request.worktreeBranch {
            let repo = config.workingDirectory
            let fetchFirst = request.worktreeFetchFirst ?? defaults.worktreeFetchBeforeCreate
            let chosen = request.worktreeBase?.trimmingCharacters(in: .whitespacesAndNewlines)
            let (path, base) = try await Task.detached {
                guard try GitWorktree.primaryCheckout(at: repo) == GitWorktree.primaryCheckout(at: space.path) else {
                    throw RemoteCreateAgentError("Choose a directory in the selected space's repository")
                }
                if let chosen, !chosen.isEmpty { return (try GitWorktree.add(repo: repo, branch: branch, from: chosen), chosen) }
                let resolution = GitWorktree.resolveBase(repo: repo, mode: defaults.worktreeBaseMode, fetchFirst: fetchFirst,
                                                         projectBase: space.worktreeBase)
                return (try GitWorktree.add(repo: repo, branch: branch, from: resolution.startPoint), resolution.display)
            }.value
            config.workingDirectory = path
            config.worktreeBranch = branch
            config.worktreeBase = base
            config.worktreePath = path
        }
        config.dispatchedFrom = request.dispatchedFrom
        // A thread Fleet started for work in a folder of the repository starts in that folder of its fresh checkout.
        if let subdirectory = request.subdirectory, config.worktreePath != nil {
            let folder = URL(fileURLWithPath: config.workingDirectory).appendingPathComponent(subdirectory).path
            if Self.folderExists(folder) { config.workingDirectory = folder }
        }
        return try await startNewAgent(config, launch: hosting.launch(), defaultServiceTier: defaults.serviceTier, mcp: hosting.mcp)
    }

    /// A client's action on one of its threads.
    @MainActor
    func perform(_ action: RemoteAgentAction, on agentID: AgentID, hosting: ThreadHosting) async throws {
        switch action {
        case .rename(let name): try await renameAgent(agentID, to: name)
        case .reorder(let target): try await reorderAgent(agentID, onto: target)
        case .deleteKeepingWorktree: try await deleteAgent(agentID)
        case .move(let spaceID): try await moveRequestedThread(agentID, to: spaceID, hosting: hosting)
        case .renameTerminal(let paneID, let title):
            let (tab, _) = try terminal(paneID, of: agentID)
            let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            try await updateLayoutStructure(tabID: tab.id, layout: tab.layout.updatingLeaf(paneID) {
                $0.title = name?.isEmpty == false ? name : nil
            })
        case .killTerminalProcess(let paneID):
            let (_, leaf) = try terminal(paneID, of: agentID)
            guard let session = leaf.sessionID, await killForegroundCommand(sessionID: session) else {
                throw RemoteCreateAgentError("Nothing is running in that terminal.")
            }
        case .startTerminal(let paneID):
            let (tab, _) = try terminal(paneID, of: agentID)
            _ = try await startTerminal(paneID, inTab: tab.id, shell: hosting.shell())
        case .openTerminal(let cwd, let command):
            let (_, thread) = try threadPane(of: agentID)
            let root = URL(fileURLWithPath: (thread.cwd as NSString).expandingTildeInPath).standardizedFileURL.path
            let target = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).standardizedFileURL.path
            guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
                throw RemoteCreateAgentError("That folder is not in the thread's folder.")
            }
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteCreateAgentError("Nothing to run.") }
            let outcome = await handleTerminalRequest(.open(agentID: agentID, axis: .vertical, cwd: target, relativeTo: nil, command: command),
                                                      hosting: hosting)
            if case .failed(_, let message) = outcome { throw RemoteCreateAgentError(message) }
        case .restartPi(let newConversation, let model):
            let (_, thread) = try threadPane(of: agentID)
            if let session = thread.sessionID {
                guard await sessionInfo(sessionID: session)?.isAlive != true else { return }
                await retryStart(sessionID: session)
            }
            await startThreadPi(agentID, hosting: hosting, checksResume: !newConversation, model: model)
        case .markSeen(let upTo): try await markCompletionSeen(agentID, upTo: upTo)
        case .mutePushes(let muted): try await setPushMuted(agentID, muted: muted)
        case .readCheckout: onThreadFocused?(agentID)
        }
    }

    /// An agent's `terminal_*` tool, or a client's terminal request: only the agent's own
    /// terminals, never its thread. A terminal is a tab of its own, so where to split is ignored.
    @MainActor
    func handleTerminalRequest(_ request: PaneRequest, hosting: ThreadHosting) async -> PaneOutcome {
        let agentID = request.agentID
        guard let (tab, thread) = try? threadPane(of: agentID) else {
            return .failed(code: "no_such_agent", message: "unknown agent \(agentID)")
        }
        func lookup(_ id: PaneID, threadCode: String) -> Result<LeafPane, PaneLookupRefusal> {
            guard let leaf = tab.layout.leaf(withID: id), leaf.isReview != true else {
                return .failure(PaneLookupRefusal(code: "no_such_terminal", message: "terminal \(id) is not in this agent's layout"))
            }
            guard leaf.agentID == nil, leaf.id != thread.id else {
                return .failure(PaneLookupRefusal(code: threadCode, message: "\(id) is the agent's own thread, not a terminal"))
            }
            return .success(leaf)
        }
        switch request {
        case .list:
            let focused: PaneID? = await enqueueValue { self.localFocusedPane }
            let leaves: [LeafPane] = TerminalPanel.tabs(in: tab.layout, thread: thread.id).map(\.leaf)
                .filter { $0.agentID == nil && $0.id != thread.id && $0.isReview != true }
            return .panes(leaves.map { PaneInfo(id: $0.id, cwd: $0.cwd, isAgentPane: false, isFocused: $0.id == focused, isAlive: $0.sessionID != nil) })
        case .open(_, _, let cwd, _, let command):
            let terminal = LeafPane(cwd: cwd.map { ($0 as NSString).expandingTildeInPath } ?? thread.cwd)
            guard let layout = tab.layout.splitting(pane: thread.id, axis: .horizontal, newPane: terminal) else {
                return .failed(code: "open_failed", message: "could not open a terminal beside the thread")
            }
            do {
                try await updateLayoutStructure(tabID: tab.id, layout: layout)
                let session = try await startTerminal(terminal.id, inTab: tab.id, shell: hosting.shell())
                if let command, !command.isEmpty { typeCommand(command, sessionID: session) }
                return .opened(PaneInfo(id: terminal.id, cwd: terminal.cwd, isAgentPane: false, isFocused: false, isAlive: true))
            } catch {
                return .failed(code: "open_failed", message: String(describing: error))
            }
        case .close(_, let id):
            switch lookup(id, threadCode: "not_closable") {
            case .failure(let refusal): return .failed(code: refusal.code, message: refusal.message)
            case .success(let leaf):
                guard let layout = tab.layout.closing(pane: id) else {
                    return .failed(code: "not_closable", message: "the layout's only terminal cannot be closed")
                }
                if let session = leaf.sessionID { killSession(session) }
                do { try await updateLayoutStructure(tabID: tab.id, layout: layout) }
                catch { return .failed(code: "close_failed", message: String(describing: error)) }
                return .ok
            }
        case .focus(_, let id):
            // Nothing has the keyboard with no app.
            if case .failure(let refusal) = lookup(id, threadCode: "no_such_terminal") {
                return .failed(code: refusal.code, message: refusal.message)
            }
            return .ok
        case .sendInput(_, let id, let text, let submit):
            switch lookup(id, threadCode: "not_writable") {
            case .failure(let refusal): return .failed(code: refusal.code, message: refusal.message)
            case .success(let leaf):
                guard let session = leaf.sessionID else {
                    return .failed(code: "no_session", message: "terminal \(id) has no running process yet")
                }
                write(sessionID: session, data: Data((submit ? text + "\n" : text).utf8))
                return .ok
            }
        case .read(_, let id):
            switch lookup(id, threadCode: "no_such_terminal") {
            case .failure(let refusal): return .failed(code: refusal.code, message: refusal.message)
            case .success(let leaf):
                guard let session = leaf.sessionID else { return .content(paneID: id, lines: []) }
                return .content(paneID: id, lines: await screenText(sessionID: session) ?? [])
            }
        }
    }

    /// Starts the shell of terminal `paneID` in tab `tabID` and binds it, unless one is already
    /// running there: its session either way.
    @MainActor
    public func startTerminal(_ paneID: PaneID, inTab tabID: TabID, shell: SessionCommand) async throws -> SessionID {
        guard let leaf = state.tabs.first(where: { $0.id == tabID })?.layout.leaf(withID: paneID), leaf.agentID == nil else {
            throw SessionServerError.noSuchPane(paneID)
        }
        if let bound = leaf.sessionID, await sessionInfo(sessionID: bound)?.isAlive == true { return bound }
        // ponytail: a second request while one starts is refused, not queued; the client retries on its next attach.
        guard startingTerminals.insert(paneID).inserted else { throw RemoteCreateAgentError("That terminal is starting.") }
        defer { startingTerminals.remove(paneID) }
        // No view has measured it yet: start at the grid this Mac's terminals last reported.
        let grid = await enqueueValue { self.lastLocalGrid } ?? (cols: 80, rows: 24)
        let info = try await createSession(params: CreateSessionParams(
            cwd: AgentLaunch.resolvedCwd(leaf.cwd), command: shell.argv, cols: grid.cols, rows: grid.rows,
            env: shell.env.isEmpty ? nil : shell.env, runtime: .pty))
        do {
            try await updatePaneSession(tabID: tabID, paneID: paneID, sessionID: info.id)
        } catch {
            killSession(info.id)
            throw error
        }
        return info.id
    }

    @MainActor
    private func threadPane(of agentID: AgentID) throws -> (Tab, LeafPane) {
        guard let agent = state.agents.first(where: { $0.id == agentID }),
              let tab = state.tabs.first(where: { $0.id == agent.tabID }) else { throw SessionServerError.noSuchAgent(agentID) }
        return (tab, agent.paneID.flatMap { tab.layout.leaf(withID: $0) } ?? tab.layout.firstLeaf)
    }

    @MainActor
    private func terminal(_ paneID: PaneID, of agentID: AgentID) throws -> (Tab, LeafPane) {
        let (tab, thread) = try threadPane(of: agentID)
        guard let leaf = tab.layout.leaf(withID: paneID), leaf.agentID == nil, leaf.id != thread.id, leaf.isReview != true else {
            throw RemoteCreateAgentError("That is not a terminal of this thread.")
        }
        return (tab, leaf)
    }
}

struct PaneLookupRefusal: Error {
    let code: String
    let message: String
}
