import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Peer threads: agents seeing, messaging, and spawning other top-level
/// agent threads. Messaging types into the target's pi prompt — exactly what
/// the user does — so pi queues it naturally when the target is mid-turn.
/// The sender's name frames every message so transcripts show the source.
@MainActor
extension ShepherdViewModel {
    func installAgentPeerControl() {
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

        switch request {
        case .list:
            let infos = state.agents.map { agent in
                let cwd = state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd ?? ""
                return AgentPeerInfo(
                    id: agent.id,
                    name: agent.name,
                    status: agent.status.rawValue,
                    cwd: cwd,
                    isSelf: agent.id == sender.id
                )
            }
            respond(.agents(infos))

        case .send(_, let targetAgentID, let text):
            guard targetAgentID != sender.id else {
                respond(.failed(code: "self_send", message: "an agent cannot message itself"))
                return
            }
            guard let target = state.agents.first(where: { $0.id == targetAgentID }) else {
                respond(.failed(code: "no_such_agent", message: "unknown agent \(targetAgentID)"))
                return
            }
            // Delivered through the target's panes extension, which injects
            // it with pi.sendUserMessage — a real queued message, not
            // keystrokes typed into the composer.
            let framed = "[from: \(sender.name)] \(text)"
            if server.pushMessage(toAgent: target.id, text: framed) {
                respond(.ok)
            } else {
                respond(.failed(code: "not_running", message: "\(target.name) has no live pi session"))
            }
            return

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
}
