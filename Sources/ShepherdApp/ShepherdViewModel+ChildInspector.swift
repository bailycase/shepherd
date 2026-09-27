import Foundation
import ShepherdCore
import ShepherdProtocol

/// Subagent inspection happens in the native side panel inside the parent agent's own
/// workspace: picking a run in the palette selects the parent and opens that run beside the
/// thread.
@MainActor
extension ShepherdViewModel {
    func openChildInspector(agentID: AgentID, child: ChildRun) {
        selectAgent(agentID)
        subagentInspector.runByAgent[agentID] = child.runID
    }

    /// Toggle the side panel for a run (card click, ⌘I, × on the panel).
    func toggleSubagentInspector(agentID: AgentID, runID: String) {
        subagentInspector.toggle(agentID: agentID, runID: runID)
    }

    /// The tray's Steer: the run's inspector, with its Steer field focused.
    func steerSubagent(agentID: AgentID, runID: String) {
        subagentInspector.runByAgent[agentID] = runID
        subagentInspector.steerRun = runID
    }

    /// "Fork as new agent": copy the finished child's transcript into its cwd's pi session
    /// directory under a fresh id and start an RPC agent on it in the parent's space. The new
    /// agent is named "<role> (fork)" provisionally so the namer can retitle it. Throws with a
    /// user-facing message when the transcript is missing or the copy fails; nothing is created then.
    @discardableResult
    func forkSubagent(agentID: AgentID, run: ChildRun) async throws -> AgentID {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else {
            throw PiSessionFile.ForkFailure(message: "The parent agent is no longer listed.")
        }
        guard let file = run.sessionFile else {
            throw PiSessionFile.ForkFailure(message: "The subagent's session file is not known.")
        }
        let cwd = run.cwd ?? agentCwd(agent)
        let sessionID = try PiSessionFile.fork(sessionFile: file, cwd: cwd, sessionsRoot: server.pi.sessionsRoot)
        var config = NewAgentConfig(spaceID: agent.spaceID, workingDirectory: cwd, model: run.model ?? agent.model,
                                    thinking: run.thinking.flatMap(ThinkingLevel.init(rawValue:)) ?? agent.thinkingLevel ?? .medium,
                                    initialPrompt: nil)
        config.initialName = "\(run.role ?? run.label) (fork)"
        config.piSessionID = sessionID
        return try await startAgent(config)
    }

    func agentCwd(_ agent: Agent) -> String {
        state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd
            ?? state.spaces.first { $0.id == agent.spaceID }?.path
            ?? NSHomeDirectory()
    }
}
