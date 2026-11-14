import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A thread that moves between Macs, on the host that gives it up and on the one that takes it (`FleetMove.swift`, `FleetDispatchMove.swift`).
extension SessionServer {
    /// Server queue: where a thread's conversation is and what pi runs in, for a move (`FleetDispatchHost.moveSource`).
    func fleetMoveSource(_ agentID: AgentID) -> FleetMoveSource? {
        guard let agent = store.state.agents.first(where: { $0.id == agentID }),
              let tab = store.state.tabs.first(where: { $0.id == agent.tabID }),
              let leaf = agent.paneID.flatMap({ tab.layout.leaf(withID: $0) }) else { return nil }
        let cwd = AgentLaunch.resolvedCwd(leaf.cwd)
        let session = agent.effectivePiSessionID
        return FleetMoveSource(sessionID: session, transcript: PiSessionFile.file(sessionID: session, cwd: cwd, sessionsRoot: pi.sessionsRoot), cwd: cwd)
    }

    /// Stops the pi of a thread that is moving, keeping the thread (`FleetDispatchHost.stopPiForMove`): returns once it has exited, so what it
    /// wrote to its session file is whole.
    func stopPiForMove(_ agentID: AgentID) async {
        let session: SessionID? = await enqueueValue { [self] in
            guard let agent = store.state.agents.first(where: { $0.id == agentID }), let tab = store.state.tabs.first(where: { $0.id == agent.tabID }) else { return nil }
            return agent.paneID.flatMap { tab.layout.leaf(withID: $0)?.sessionID }
        }
        guard let session else { return }
        await stopKeepingAgent(sessionID: session)
        let deadline = ContinuousClock.now + .seconds(10)
        while await sessionInfo(sessionID: session)?.isAlive == true, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// The thread another Mac moved here: its conversation installed where pi will find it, and the thread made with the id it had (a
    /// thread this Mac gave up earlier comes back in its own place), then pi resumes the conversation. Idempotent on the move: a thread
    /// this move already made is the answer. Throws, leaving no thread, when it can't be made.
    @MainActor
    func adoptMovedThread(_ request: RemoteCreateAgentRequest, _ moved: RemoteCreateAgentRequest.Moved, hosting: ThreadHosting) async throws -> AgentID {
        guard let agentID = request.agentID, let path = request.worktreePath, let branch = request.worktreeBranch else {
            throw RemoteCreateAgentError("A moved thread names its id, its worktree and its branch.")
        }
        guard let space = state.spaces.first(where: { $0.id == request.spaceID }) else { throw RemoteCreateAgentError("Space no longer exists") }
        let existing = state.agents.first { $0.id == agentID }
        if let existing, existing.movedTo == nil {
            if existing.movedFrom?.moveID == moved.from.moveID { return agentID }
            throw RemoteCreateAgentError("This Mac already runs that thread.")
        }
        let identity = try await Task.detached { try GitWorktree.identity(at: path) }.value
        let repo = try await Task.detached { try GitWorktree.primaryCheckout(at: space.path) }.value
        guard identity.repo == repo, identity.branch == branch else {
            throw RemoteCreateAgentError("That checkout isn't \(branch) of \(space.name)'s repository.")
        }
        var cwd = identity.path
        if let subdirectory = request.subdirectory {
            let folder = URL(fileURLWithPath: cwd).appendingPathComponent(subdirectory).path
            if Self.folderExists(folder) { cwd = folder }
        }
        // The conversation, where pi looks for it for that folder; the note that closes it is the divider the thread draws.
        let sessionID = request.piSessionID ?? agentID.rawValue
        let root = pi.sessionsRoot
        let note = moved.note
        let installed = await Task.detached { () -> Bool in
            var source = moved.transcript
            if source == nil {
                // A thread that never ran has no conversation: pi's own header for it is the start of one.
                PiSessionFile.seedIfMissing(sessionID: sessionID, cwd: cwd, sessionsRoot: root)
                source = PiSessionFile.file(sessionID: sessionID, cwd: cwd, sessionsRoot: root)
            }
            guard let source else { return false }
            return PiSessionFile.install(source, sessionID: sessionID, cwd: cwd, sessionsRoot: root, note: note)
        }.value
        guard installed else { throw RemoteCreateAgentError("This Mac couldn't keep the conversation.") }
        let defaults = hosting.defaults()
        if existing != nil {
            try await reviveMovedThread(agentID, request: request, moved: moved, space: space, cwd: cwd, branch: branch)
            await startThreadPi(agentID, hosting: hosting)
            return agentID
        }
        var config = NewAgentConfig(spaceID: space.id, workingDirectory: cwd, model: request.model ?? defaults.model,
                                    thinking: request.thinking ?? defaults.thinking, initialPrompt: nil, serviceTier: request.serviceTier)
        config.reservedAgentID = agentID
        config.initialName = request.name
        config.piSessionID = request.piSessionID
        config.worktreeBranch = branch
        config.worktreeBase = request.worktreeBase
        config.worktreePath = identity.path
        config.dispatchedFrom = request.dispatchedFrom
        config.movedFrom = moved.from
        config.nameIsFinal = moved.nameIsFinal
        config.pushMuted = moved.pushMuted
        config.lastActiveAt = moved.lastActiveAt
        do {
            return try await startNewAgent(config, launch: hosting.launch(), defaultServiceTier: defaults.serviceTier, mcp: hosting.mcp)
        } catch {
            // The thread exists but its pi didn't start: it is here (it says why and waits for Retry), not a failed move.
            if state.agents.contains(where: { $0.id == agentID && $0.movedFrom?.moveID == moved.from.moveID }) { return agentID }
            throw error
        }
    }

    /// A thread this Mac gave up comes back: the same agent and tab, now in the worktree it arrived in, no longer a tombstone.
    @MainActor
    private func reviveMovedThread(_ agentID: AgentID, request: RemoteCreateAgentRequest, moved: RemoteCreateAgentRequest.Moved, space: Space,
                                   cwd: String, branch: String) async throws {
        try await enqueue { [self] in
            try mutateState { state in
                guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else { return }
                let tabID = state.agents[index].tabID
                state.agents[index].movedTo = nil
                state.agents[index].movedFrom = moved.from
                state.agents[index].spaceID = space.id
                state.agents[index].status = .idle
                state.agents[index].lastFailure = nil
                state.agents[index].name = request.name ?? state.agents[index].name
                state.agents[index].nameIsFinal = moved.nameIsFinal
                state.agents[index].model = request.model ?? state.agents[index].model
                state.agents[index].thinkingLevel = request.thinking ?? state.agents[index].thinkingLevel
                state.agents[index].serviceTier = request.serviceTier ?? state.agents[index].serviceTier
                state.agents[index].piSessionID = request.piSessionID
                state.agents[index].worktreeBranch = branch
                state.agents[index].worktreeOriginalBranch = nil
                state.agents[index].worktreeBase = request.worktreeBase
                state.agents[index].worktreePath = request.worktreePath
                state.agents[index].dispatchedFrom = request.dispatchedFrom
                state.agents[index].pushMuted = moved.pushMuted
                state.agents[index].lastActiveAt = moved.lastActiveAt ?? SessionServer.nowMilliseconds()
                let paneID = state.agents[index].paneID
                if let tabIndex = state.tabs.firstIndex(where: { $0.id == tabID }) {
                    state.tabs[tabIndex].spaceID = space.id
                    if let paneID { state.tabs[tabIndex].layout = state.tabs[tabIndex].layout.updatingLeaf(paneID) { $0.cwd = cwd; $0.sessionID = nil } }
                }
            }
        }
    }
}
