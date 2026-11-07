import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What a host with no app starts a client's threads and terminals with (`serveThreads`), read
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

/// Threads and terminals with no app: the requests a client (the app over `host.sock`, an
/// iPhone, another Mac) makes of them, and an agent's own `terminal_*` tools, answered here as the
/// app's view model answers them in process. The app keeps pane binding for its own views; here
/// a terminal's shell starts when a client asks for it.
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
        // A client opened a thread whose pi has not started since the host did.
        onNativeThreadDemand = { [weak self] agentID in
            Task { @MainActor in await self?.startThreadPi(agentID, hosting: hosting) }
        }
    }

    /// Starts a thread's pi with the host's launch settings; a failure is logged.
    @MainActor
    private func startThreadPi(_ agentID: AgentID, hosting: ThreadHosting) async {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return }
        var spawn = AgentSpawn(agent: agent, cwd: "", settings: hosting.launch())
        spawn.mcp = hosting.mcp
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
        let sessionID = state.agents.first { $0.id == agentID }.flatMap { agent in
            state.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: agent.paneID ?? PaneID())?.sessionID
        }
        let wasAlive = if let sessionID { await sessionInfo(sessionID: sessionID)?.isAlive == true } else { false }
        do {
            guard try await moveThread(agentID, to: spaceID) else { return }
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
        guard let space = state.spaces.first(where: { $0.id == request.spaceID }) else {
            throw RemoteCreateAgentError("Space no longer exists")
        }
        var config = NewAgentConfig(spaceID: request.spaceID, workingDirectory: request.cwd ?? space.path,
                                    model: request.model ?? defaults.model, thinking: request.thinking ?? defaults.thinking,
                                    initialPrompt: request.initialPrompt, initialImages: request.initialImages,
                                    serviceTier: request.serviceTier)
        if let branch = request.worktreeBranch {
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
            return .panes(TerminalPanel.tabs(in: tab.layout, thread: thread.id).map(\.leaf)
                .filter { $0.agentID == nil && $0.id != thread.id && $0.isReview != true }
                .map { PaneInfo(id: $0.id, cwd: $0.cwd, isAgentPane: false, isFocused: false, isAlive: $0.sessionID != nil) })
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
        let info = try await createSession(params: CreateSessionParams(
            cwd: AgentLaunch.resolvedCwd(leaf.cwd), command: shell.argv, env: shell.env.isEmpty ? nil : shell.env, runtime: .pty))
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
