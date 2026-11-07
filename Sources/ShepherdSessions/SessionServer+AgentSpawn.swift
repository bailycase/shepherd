import Foundation
import ShepherdCore
import ShepherdProtocol

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
    /// Missions' spec-kit launch (a new agent's start, not a respawn).
    public var specKit = false
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

extension SessionServer {
    /// Spawns an agent's `pi --mode rpc` (its launch line from `AgentLaunch`) for a new agent and
    /// for a respawn alike. Nil, with nothing spawned, when the pane stopped wanting it
    /// (`stillWanted`). Binding the session to its pane is the caller's.
    @MainActor
    public func spawnAgent(_ spawn: AgentSpawn) async throws -> SessionInfo? {
        let agent = spawn.agent, cwd = spawn.cwd
        try await projects.prepareProjectConfiguration(for: cwd)
        var (fresh, problem) = (false, spawn.problem)
        if problem == nil {
            // Ready Shepherd's pi home, and give pi a session to find, so --session-id does not warn.
            (fresh, problem) = await AgentLaunch.prepare(for: agent, cwd: cwd, pi: pi, codemode: spawn.settings.codemode,
                                                         requiredHistoryEntryID: spawn.requiredHistoryEntryID)
            if spawn.requiredHistoryEntryID != nil, let problem { throw AgentSpawnRefused(problem: problem) }
        }
        let state = self.state
        let parent = await projects.parentProject(of: cwd, state: state)
        let verifiedWorktree = await Self.ownedWorktreeWithoutMetadata(agent: agent, cwd: cwd, state: state)
        // RPC mode ignores a positional prompt; an opening prompt goes to the session afterwards.
        let command = try problem.map(AgentLaunch.refusedCommand)
            ?? AgentLaunch.rpcCommand(for: agent, cwd: cwd, pi: pi, settings: spawn.settings, sessionIsFresh: fresh,
                                      isAutomation: spawn.isAutomation,
                                      project: state.projectContext(for: agent.id),
                                      worktreeOwningSpace: StatusExtension.worktreeOwningSpace(agent: agent, cwd: cwd, state: state, verifiedWorktree: verifiedWorktree),
                                      suggestFiles: suggestions.snapshot().settings.files(for: spawn.isAutomation ? .automation : .thread),
                                      modelOverride: spawn.takeModelOverride(),
                                      specKit: spawn.specKit ? state.specKitLaunch(for: agent.id, cwd: cwd) : nil,
                                      mcp: { try spawn.mcp(parent, agent, cwd, state, verifiedWorktree) })
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
