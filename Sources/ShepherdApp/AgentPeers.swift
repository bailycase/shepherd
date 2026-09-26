import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// Peer threads: agents listing, messaging, spawning, and asking to delete other top-level
/// agents. Messages go through the target's live panes extension; a deletion waits for the
/// user's answer in `PeerDeleteDialog` and then follows the normal Delete Agent path.
@MainActor
extension ShepherdViewModel {
    func installAgentPeerControl() {
        server.onAgentPeerCancellation = { [weak self] token in
            MainActor.assumeIsolated {
                if self?.peerDeleteConfirmation?.requestID == token {
                    self?.peerDeleteConfirmation = nil
                }
            }
        }
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
        guard !state.isDesignAgent(sender) else {
            respond(.failed(code: "not_a_thread", message: "a design's agent does not coordinate with threads"))
            return
        }

        switch request {
        case .list:
            respond(.agents(Self.peerInfos(in: state, sender: sender.id)))

        case .send(_, let targetAgentID, let text):
            guard targetAgentID != sender.id else {
                respond(.failed(code: "self_send", message: "an agent cannot message itself"))
                return
            }
            guard let target = state.agents.first(where: { $0.id == targetAgentID }) else {
                respond(.failed(code: "no_such_agent", message: "unknown agent \(targetAgentID)"))
                return
            }
            guard !state.isDesignAgent(target) else {
                respond(.failed(code: "not_a_thread", message: "\(target.name) draws a design; it is not a thread"))
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

        case .delete(_, let targetAgentID, let requestID):
            guard targetAgentID != sender.id else {
                respond(.failed(code: "self_control", message: "an agent cannot delete itself"))
                return
            }
            guard let target = state.agents.first(where: { $0.id == targetAgentID }) else {
                respond(.failed(code: "no_such_agent", message: "target no longer exists"))
                return
            }
            guard !state.isDesignAgent(target) else {
                respond(.failed(code: "not_a_thread", message: "\(target.name) draws a design; it is not a thread"))
                return
            }
            guard peerDeleteConfirmation == nil else {
                respond(.failed(code: "busy", message: "another deletion is awaiting user confirmation"))
                return
            }
            peerDeleteConfirmation = PeerDeleteConfirmation(requestID: requestID, agent: target,
                                                          senderName: sender.name, respond: respond)

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
        state.agents.filter { !state.isDesignAgent($0) }.map { agent in
            AgentPeerInfo(
                id: agent.id,
                name: agent.name,
                status: agent.status.rawValue,
                cwd: state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd ?? "",
                isSelf: agent.id == sender
            )
        }
    }

    func cancelPeerDeletion(requestID: String) {
        guard let confirmation = peerDeleteConfirmation,
              confirmation.requestID == requestID else { return }
        peerDeleteConfirmation = nil
        confirmation.respond(.failed(code: "cancelled", message: "user cancelled deletion; agent kept"))
    }

    /// The dialog's destructive button, and nothing else: it dismisses the dialog, claims the
    /// request (a timed-out or cancelled one can no longer delete), waits `dismissal` so the
    /// sheet is gone before a layout is torn down, then deletes through Delete Agent.
    func confirmPeerDeletion(requestID: String, dismissal: Duration = .zero) async {
        guard let confirmation = peerDeleteConfirmation,
              confirmation.requestID == requestID else { return }
        peerDeleteConfirmation = nil
        guard await server.claimAgentDeletion(confirmation.requestID) else { return }
        if dismissal > .zero { try? await Task.sleep(for: dismissal) }
        deleteAgent(confirmation.agent.id) { error in
            confirmation.respond(error.map { .failed(code: "delete_failed", message: String(describing: $0)) } ?? .ok)
        }
    }
}
