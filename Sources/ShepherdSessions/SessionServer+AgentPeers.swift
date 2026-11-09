import Foundation
import ShepherdCore
import ShepherdProtocol

/// What peer requests (`agent_list`, `agent_send`, `agent_spawn`, `agent_move`, `agent_delete`)
/// start, delete and move threads with: the app's view model in process, the server itself in
/// the background host (`serveThreads`).
public struct AgentPeerHosting {
    public var defaults: @MainActor () -> (model: String?, thinking: ThinkingLevel)
    public var startAgent: @MainActor (NewAgentConfig) async throws -> AgentID
    /// Calls back once the deletion is persisted.
    public var deleteAgent: @MainActor (AgentID, @escaping @MainActor (Error?) -> Void) -> Void
    public var moveThread: @MainActor (AgentID, SpaceID) async throws -> Void

    public init(defaults: @escaping @MainActor () -> (model: String?, thinking: ThinkingLevel),
                startAgent: @escaping @MainActor (NewAgentConfig) async throws -> AgentID,
                deleteAgent: @escaping @MainActor (AgentID, @escaping @MainActor (Error?) -> Void) -> Void,
                moveThread: @escaping @MainActor (AgentID, SpaceID) async throws -> Void) {
        self.defaults = defaults
        self.startAgent = startAgent
        self.deleteAgent = deleteAgent
        self.moveThread = moveThread
    }
}

/// Peer threads: agents listing, messaging, spawning and deleting other top-level agents.
/// Messages use the target's live panes extension.
extension SessionServer {
    /// Serves peer requests from here on (`onAgentPeerRequest`). Once per server.
    @MainActor
    public func serveAgentPeers(_ hosting: AgentPeerHosting) {
        // Agent tools need no permission setting or approval UI. Ignore legacy stored choices.
        setAgentMessagePolicy(.always)
        onAgentPeerRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self else { return respond(.failed(code: "unavailable", message: "workspace is gone")) }
                self.handlePeerRequest(request, hosting: hosting, respond: respond)
            }
        }
    }

    @MainActor
    private func handlePeerRequest(_ request: AgentPeerRequest, hosting: AgentPeerHosting, respond: @escaping (AgentPeerOutcome) -> Void) {
        let state = self.state
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
            Task { @MainActor in
                if await self.pushMessage(toAgent: target.id, text: framed, delivery: delivery) {
                    respond(.ok)
                } else {
                    respond(.failed(code: "not_running", message: "\(target.name) has no live Shepherd connection, or message dispatch failed"))
                }
            }

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
                guard await self.claimAgentDeletion(requestID) else { return }
                hosting.deleteAgent(target.id) { error in
                    respond(error.map { .failed(code: "delete_failed", message: String(describing: $0)) } ?? .ok)
                }
            }

        case .move(_, let targetAgentID, let spaceID):
            Task { @MainActor in
                do {
                    try await hosting.moveThread(targetAgentID, spaceID)
                    respond(.ok)
                } catch let error as ProjectFileError {
                    respond(.failed(code: error.code, message: error.description))
                } catch {
                    respond(.failed(code: "move_failed", message: String(describing: error)))
                }
            }

        case .spawn(_, let cwd, let prompt, let model, let thinking):
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
            let defaults = hosting.defaults()
            let config = NewAgentConfig(spaceID: spaceID, workingDirectory: expanded, model: model ?? defaults.model,
                                        thinking: thinking ?? defaults.thinking, initialPrompt: prompt)
            Task { @MainActor in
                do {
                    // Spawned threads never steal the user's focus.
                    let agentID = try await hosting.startAgent(config)
                    respond(.agents([AgentPeerInfo(id: agentID, name: self.state.agents.first { $0.id == agentID }?.name ?? "agent",
                                                   status: AgentStatus.working.rawValue, cwd: expanded, isSelf: false)]))
                } catch {
                    respond(.failed(code: "spawn_failed", message: String(describing: error)))
                }
            }
        }
    }

    /// What agent_list shows `sender`: every thread, and no design's agent.
    public static func peerInfos(in state: ShepherdState, sender: AgentID) -> [AgentPeerInfo] {
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
