import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Peer threads: agents listing, messaging, spawning and deleting other top-level agents.
/// Messages use the target's live panes extension; deletion follows the normal Delete Agent path.
@MainActor
extension ShepherdViewModel {
    func installAgentPeerControl() {
        // Agent tools need no permission setting or approval UI. Ignore legacy stored choices.
        server.setAgentMessagePolicy(.always)
        server.onAgentPeerRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failed(code: "unavailable", message: "workspace is gone"))
                    return
                }
                self.handlePeerRequest(request, respond: respond)
            }
        }
    }

    private func handlePeerRequest(_ request: AgentPeerRequest, respond: @escaping (AgentPeerOutcome) -> Void) {
        guard let sender = state.agents.first(where: { $0.id == request.agentID }) else {
            respond(.failed(code: "no_such_agent", message: "unknown agent \(request.agentID)"))
            return
        }

        // A design's agent is no thread: it has no peers, and no thread reaches it.
        guard state.isOrdinaryThread(sender) else {
            respond(.failed(code: "not_a_thread", message: "a design's agent does not coordinate with threads"))
            return
        }

        switch request {
        case .list:
            respond(.agents(Self.peerInfos(in: state, sender: sender.id)))

        case .send(_, let targetAgentID, let text, let delivery):
            guard targetAgentID != sender.id else {
                respond(.failed(code: "self_send", message: "an agent cannot message itself"))
                return
            }
            guard let target = state.agents.first(where: { $0.id == targetAgentID }) else {
                respond(.failed(code: "no_such_agent", message: "unknown agent \(targetAgentID)"))
                return
            }
            guard state.isOrdinaryThread(target) else {
                respond(.failed(code: "not_a_thread", message: "\(target.name) is not an ordinary thread"))
                return
            }
            // The target's panes extension adds report-only context or sends a user task.
            let framed = AgentMessageFraming.framed(from: sender.name, text)
            if server.pushMessage(toAgent: target.id, text: framed, delivery: delivery) {
                respond(.ok)
            } else {
                respond(.failed(code: "not_running", message: "\(target.name) has no live Shepherd connection, or message dispatch failed"))
            }
            return

        case .delete(_, let targetAgentID, let requestID):
            guard targetAgentID != sender.id else {
                respond(.failed(code: "self_control", message: "an agent cannot delete itself"))
                return
            }
            guard let target = state.agents.first(where: { $0.id == targetAgentID }) else {
                respond(.failed(code: "no_such_agent", message: "target no longer exists"))
                return
            }
            guard state.isOrdinaryThread(target) else {
                respond(.failed(code: "not_a_thread", message: "\(target.name) is not an ordinary thread"))
                return
            }
            Task { @MainActor in
                // Claim before deleting so a cancelled or expired request cannot act later.
                guard await server.claimAgentDeletion(requestID) else { return }
                deleteAgent(target.id) { error in
                    respond(error.map { .failed(code: "delete_failed", message: String(describing: $0)) } ?? .ok)
                }
            }

        case .spawn(_, let cwd, let prompt):
            let expanded = (cwd as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                respond(.failed(code: "no_such_directory", message: "\(cwd) is not a directory"))
                return
            }
            // Same space resolution as the user's flows: exact, containing,
            // else the sender's own space (never a surprise new space row).
            let spaceID = state.spaces.first { !$0.hidden && $0.path == expanded }?.id
                ?? state.spaces.first { !$0.hidden && expanded.hasPrefix($0.path + "/") }?.id
                ?? sender.spaceID
            let config = NewAgentConfig(
                spaceID: spaceID,
                workingDirectory: expanded,
                model: settings.agentDefaults.model,
                thinking: settings.defaultThinking,
                initialPrompt: prompt
            )
            Task { @MainActor in
                do {
                    // Spawned threads never steal the user's focus.
                    let agentID = try await self.startAgent(config, selectAfter: false)
                    let cwd = expanded
                    let info = AgentPeerInfo(
                        id: agentID,
                        name: self.state.agents.first { $0.id == agentID }?.name ?? "agent",
                        status: AgentStatus.working.rawValue,
                        cwd: cwd,
                        isSelf: false
                    )
                    respond(.agents([info]))
                } catch {
                    respond(.failed(code: "spawn_failed", message: String(describing: error)))
                }
            }
        }
    }

    /// What agent_list shows `sender`: every thread, and no design's agent.
    static func peerInfos(in state: ShepherdState, sender: AgentID) -> [AgentPeerInfo] {
        state.agents.filter { state.isOrdinaryThread($0) }.map { agent in
            AgentPeerInfo(
                id: agent.id,
                name: agent.name,
                status: agent.status.rawValue,
                cwd: state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd ?? "",
                isSelf: agent.id == sender
            )
        }
    }


}
