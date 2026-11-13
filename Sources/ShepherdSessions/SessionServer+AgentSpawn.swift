import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// How an agent's pi is spawned into its pane: what the caller's settings decide, as values.
public struct AgentSpawn {
    /// What an agent's pi gets for MCP, given the parent project of its folder, the state the
    /// launch read, and whether its folder was verified as a worktree of its space.
    public typealias MCP = (_ parent: String?, _ agent: Agent, _ cwd: String, _ state: ShepherdState, _ verifiedWorktree: Bool) throws -> MCPLaunch?

    public var agent: Agent
    /// The agent's folder, resolved (`AgentLaunch.resolvedCwd`).
    public var cwd: String
    public var settings: AgentLaunchSettings
    public var isAutomation = false
    /// The model this start takes whatever its session says (Use another model), taken only
    /// once the launch line is built.
    public var takeModelOverride: () -> String? = { nil }
    /// A Project follow-up restores exactly this proven conversation, or refuses (`AgentSpawnRefused`).
    public var requiredHistoryEntryID: String?
    /// A reason to start no pi at all: the agent keeps its place with it (a missing folder).
    public var problem: PiHomeProblem?
    /// A resumed pi that doesn't find its conversation is stopped (`createSession(params:resuming:)`).
    public var checksResume = true
    public var cols = 80
    public var rows = 24
    public var mcp: MCP = { _, _, _, _, _ in nil }
    /// Holds the checkout while pi starts in it; returns its release.
    public var reserveCheckout: ((String) throws -> (() -> Void))?
    /// Read last, just before pi spawns: false when the pane no longer wants it.
    public var stillWanted: () -> Bool = { true }

    public init(agent: Agent, cwd: String, settings: AgentLaunchSettings) {
        self.agent = agent
        self.cwd = cwd
        self.settings = settings
    }
}

/// A Project follow-up whose proven conversation is gone: nothing was spawned.
public struct AgentSpawnRefused: Error, CustomStringConvertible {
    public let problem: PiHomeProblem
    public var description: String { problem.description }
}

/// A respawned pi that its pane refused (`SessionServer.respawnAgent`): it is still running,
/// and the caller stops it.
public struct PaneBindingFailed: Error, CustomStringConvertible {
    public let paneID: PaneID
    public let sessionID: SessionID
    public let reason: String
    public var description: String { "failed to bind session \(sessionID) to pane \(paneID): \(reason)" }
}

extension SessionServer {
    /// Respawns an agent's pi into its own pane after a launch, and binds it there. Nil, with
    /// nothing spawned, when its pane no longer holds it or is already bound to a live session,
    /// when `startNewAgent` is still starting it, or when `stillWanted` says no. A folder that is gone keeps the agent's place with a start
    /// problem. `spawn.cwd` is ignored: the pane's folder is the agent's.
    @MainActor
    public func respawnAgent(_ spawn: AgentSpawn) async throws -> SessionInfo? {
        let agentID = spawn.agent.id, state = self.state
        guard !creatingAgents.contains(agentID),
              let agent = state.agents.first(where: { $0.id == agentID }), let paneID = agent.paneID,
              let tab = state.tabs.first(where: { $0.id == agent.tabID }),
              let pane = tab.layout.leaf(withID: paneID), pane.agentID == agentID else { return nil }
        var spawn = spawn
        spawn.agent = agent
        spawn.cwd = AgentLaunch.resolvedCwd(pane.cwd)
        if spawn.problem == nil, !Self.folderExists(pane.cwd) { spawn.problem = PiHomeProblem("folder missing: \(pane.cwd)") }
        if let bound = pane.sessionID, await sessionInfo(sessionID: bound)?.isAlive == true { return nil }
        // Read just before pi spawns: the pane still holds the agent, and nothing bound it meanwhile.
        let wanted = spawn.stillWanted
        spawn.stillWanted = { [unowned self] in
            let leaf = self.state.tabs.first(where: { $0.id == tab.id })?.layout.leaf(withID: paneID)
            return leaf?.agentID == agentID && leaf?.cwd == pane.cwd && leaf?.sessionID == pane.sessionID && wanted()
        }
        guard let info = try await spawnAgent(spawn) else { return nil }
        do {
            try await updatePaneSession(tabID: tab.id, paneID: paneID, sessionID: info.id)
        } catch {
            throw PaneBindingFailed(paneID: paneID, sessionID: info.id, reason: String(describing: error))
        }
        return info
    }

    /// Holds every agent's pi start until the first launch's copy from the user's pi has run (the
    /// app's, `YourPiModel.runFirstLaunch`), so none starts before its sign-ins come over. Past
    /// `deadline` they start anyway, as the app's restored agents did; once it ran nothing waits.
    @MainActor
    public func holdStartsForFirstCopy(deadline: Duration = .seconds(30), poll: Duration = .milliseconds(100)) {
        let imports = pi.importedState()
        firstCopy = Task.detached(priority: .userInitiated) {
            let end = ContinuousClock.now + deadline
            // ponytail: polls the copy's state file; a file watch if the wait ever matters.
            while !imports.copiedOnce, ContinuousClock.now < end { try? await Task.sleep(for: poll) }
        }
    }

    /// Startup respawn with no app: every agent whose unfinished work may be recovered
    /// (`agentsNeedingStartupRecovery`), in workspace order, one at a time. Recovery resumes each
    /// turn once its pi serves. Other agents wait for demand. A failed respawn is logged.
    @MainActor
    public func respawnAgentsNeedingRecovery(_ spawn: (Agent) -> AgentSpawn) async {
        let recovering = await agentsNeedingStartupRecovery()
        for agent in state.agents where recovering.contains(agent.id) {
            do {
                _ = try await respawnAgent(spawn(agent))
            } catch let failed as PaneBindingFailed {
                ShepherdLog.warning("respawn of \(agent.id) refused: \(failed)")
                killSession(failed.sessionID)
            } catch {
                ShepherdLog.warning("respawn of \(agent.id) failed: \(error)")
            }
        }
    }

    /// Spawns an agent's `pi --mode rpc` (its launch line from `AgentLaunch`) for a new agent and
    /// for a respawn alike. Nil, with nothing spawned, when the pane stopped wanting it
    /// (`stillWanted`). Binding the session to its pane is the caller's.
    @MainActor
    public func spawnAgent(_ spawn: AgentSpawn) async throws -> SessionInfo? {
        let agent = spawn.agent, cwd = spawn.cwd
        spawningAgents += 1
        defer { spawningAgents -= 1 }
        if let firstCopy {
            waitingForFirstCopy += 1
            await firstCopy.value
            waitingForFirstCopy -= 1
        }
        var (fresh, problem) = (false, spawn.problem)
        if problem == nil {
            // In a fleet, the newest sign-ins of the other Macs come first: a refresh token another Mac rotated is no use here.
            await fleetCredentialFence()
            // Ready Shepherd's pi home, and give pi a session to find, so --session-id does not warn.
            (fresh, problem) = await AgentLaunch.prepare(for: agent, cwd: cwd, pi: pi, codemode: spawn.settings.codemode,
                                                         requiredHistoryEntryID: spawn.requiredHistoryEntryID)
            if spawn.requiredHistoryEntryID != nil, let problem { throw AgentSpawnRefused(problem: problem) }
        }
        let state = self.state
        let inheritance = await projects.inheritance(of: cwd, state: state)
        let parent = inheritance?.parent
        let inherited = await projects.launchDefaults(for: cwd)
        let verifiedWorktree = await Self.ownedWorktreeWithoutMetadata(agent: agent, cwd: cwd, state: state)
        let owningSpace = StatusExtension.worktreeOwningSpace(agent: agent, cwd: cwd, state: state, verifiedWorktree: verifiedWorktree)
        let mcpSpace = await projects.mcpSpace(of: owningSpace ?? cwd, state: state)
        // RPC mode ignores a positional prompt; an opening prompt goes to the session afterwards.
        let command = try problem.map(AgentLaunch.refusedCommand)
            ?? AgentLaunch.rpcCommand(for: agent, cwd: cwd, pi: pi, settings: spawn.settings, sessionIsFresh: fresh,
                                      isAutomation: spawn.isAutomation,
                                      project: state.projectContext(for: agent.id),
                                      worktreeOwningSpace: owningSpace,
                                      suggestFiles: suggestions.snapshot().settings.files(for: spawn.isAutomation ? .automation : .thread),
                                      modelOverride: spawn.takeModelOverride(),
                                      inherited: inherited,
                                      mcp: {
                                          // Parent skills and commands come through the same extension, so a child space gets them with MCP off too.
                                          let launch = try spawn.mcp(parent, agent, cwd, state, verifiedWorktree)
                                              ?? (parent == nil ? nil : MCPLaunch(extensions: spawn.settings.deferTools ? ["builtin:tool-search"] : [], environment: [:]).sharingParent(parent))
                                          var scoped = launch?.excluding(inheritance?.excluded ?? SpaceInheritanceExclusions())
                                              .loadingParentExtensions(inheritance?.extensions ?? [])
                                          // Project MCP sign-ins belong to the space (Shepherd's pi engine patch).
                                          scoped?.environment["SHEPHERD_MCP_SPACE"] = mcpSpace
                                          return scoped
                                      })
        // A forked transcript resumes: pi not finding it is a start problem, never a new session.
        let resuming = spawn.checksResume && !fresh ? agent.effectivePiSessionID : nil
        guard spawn.stillWanted() else { return nil }
        let releaseCheckout = try spawn.reserveCheckout?(cwd)
        defer { releaseCheckout?() }
        return try await createSession(
            params: CreateSessionParams(cwd: cwd, command: command.argv, cols: spawn.cols, rows: spawn.rows,
                                        env: command.env.isEmpty ? nil : command.env, runtime: .rpc),
            resuming: resuming)
    }

    static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Forked threads retain space ownership and cwd but not worktree-management metadata.
    /// Verify Git's actual relationship off the main actor, never infer ownership from sibling names.
    static func ownedWorktreeWithoutMetadata(agent: Agent, cwd: String, state: ShepherdState) async -> Bool {
        guard agent.worktreeBranch == nil, agent.worktreePath == nil,
              let space = state.spaces.first(where: { $0.id == agent.spaceID }),
              PiHome.canonical(space.path) != PiHome.canonical(cwd) else { return false }
        let owner = PiHome.canonical(space.path)
        return await Task.detached(priority: .userInitiated) {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: cwd).appendingPathComponent(".git").path,
                                                 isDirectory: &directory), !directory.boolValue else { return false }
            return (try? GitWorktree.containsCheckout(repo: owner, checkout: cwd)) == true
        }.value
    }
}
