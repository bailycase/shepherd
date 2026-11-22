import Foundation
import ShepherdCore
import ShepherdProtocol

/// What peer requests (`agent_list`, `agent_send`, `agent_spawn`, `agent_move`, `agent_delete`)
/// start, delete and move threads with: the host's server itself (`serveThreads`).
public struct AgentPeerHosting {
    public var defaults: @MainActor () -> ThreadHosting.Defaults
    /// Starts a thread as a client's new thread does (`startRequestedAgent`), in a new worktree when it names a branch.
    public var startAgent: @MainActor (RemoteCreateAgentRequest) async throws -> AgentID
    /// Calls back once the deletion is persisted.
    public var deleteAgent: @MainActor (AgentID, @escaping @MainActor (Error?) -> Void) -> Void
    public var moveThread: @MainActor (AgentID, SpaceID) async throws -> Void

    public init(defaults: @escaping @MainActor () -> ThreadHosting.Defaults,
                startAgent: @escaping @MainActor (RemoteCreateAgentRequest) async throws -> AgentID,
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
        case .list(_, let details):
            let list = Self.peerList(in: state, sender: sender.id, details: details)
            respond(.agents(list.rows, omitted: list.omitted))

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

        case .spawn(_, let cwd, let prompt, let model, let thinking, let place, let branch, let byPerson):
            let defaults = hosting.defaults()
            guard byPerson || defaults.threadsStartThreads else {
                respond(.failed(code: "not_asked", message: "You can start a thread only when the user asks for one: this turn wasn't started by the user. "
                    + "Do the work here, or with your own subagents. (Settings ▸ Agents ▸ Threads can start threads lets you.)"))
                return
            }
            // Threads one thread started that run at once, counting ones still being made and ones made a moment ago whose pi hasn't said
            // it is working yet.
            let now = Self.nowMilliseconds()
            let running = state.agents.count { agent in
                guard let started = agent.startedBy, started.agentID == sender.id else { return false }
                return agent.status == .working || agent.status == .blocked
                    || (agent.status == .idle && agent.completedAt == nil && now - started.at < 60_000)
            }
            guard running + spawning[sender.id, default: 0] < defaults.threadCap else {
                respond(.failed(code: "held_limit", message: "You already have \(defaults.threadCap) threads you started running. Wait for one to finish."))
                return
            }
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
            var request = RemoteCreateAgentRequest(spaceID: spaceID, cwd: expanded, model: model ?? defaults.model,
                                                   thinking: thinking ?? defaults.thinking, initialPrompt: prompt)
            // It nests under the thread that started it, one deeper; nothing else ties them together.
            request.startedBy = StartedBy(agentID: sender.id, agentTitle: sender.name, at: Self.nowMilliseconds(), depth: sender.threadDepth + 1)
            if place == .checkout, branch != nil {
                respond(.failed(code: "invalid", message: "branch is for place worktree; a checkout works on the branch it has"))
                return
            }
            let worktree = (place ?? (branch != nil ? .worktree : defaults.subThreadPlace)) == .worktree
            let spacePath = state.spaces.first { $0.id == spaceID }?.path
            spawning[sender.id, default: 0] += 1
            Task { @MainActor in
                defer { spawning[sender.id, default: 1] -= 1; if spawning[sender.id] == 0 { spawning[sender.id] = nil } }
                do {
                    if worktree {
                        guard let spacePath else { throw RemoteCreateAgentError("Space no longer exists") }
                        let start = try await Task.detached { try Self.spawnWorktree(cwd: expanded, space: spacePath, branch: branch) }.value
                        request.cwd = spacePath
                        request.worktreeBranch = start.branch
                        request.worktreeBranchExists = start.exists
                        request.worktreeBase = start.base
                        request.worktreeFetchFirst = false
                        request.subdirectory = start.subdirectory
                    }
                    // Spawned threads never steal the user's focus.
                    let agentID = try await hosting.startAgent(request)
                    let agent = self.state.agents.first { $0.id == agentID }
                    respond(.agents([AgentPeerInfo(id: agentID, name: agent?.name ?? "agent", status: AgentStatus.working.rawValue,
                                                   cwd: agent.flatMap { agent in self.state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd } ?? expanded,
                                                   isSelf: false)]))
                } catch let error as RemoteCreateAgentError {
                    respond(.failed(code: "spawn_failed", message: error.message))
                } catch {
                    respond(.failed(code: "spawn_failed", message: String(describing: error)))
                }
            }
        }
    }

    /// Where a thread `agent_spawn` starts in a new worktree begins: the commit `cwd`'s checkout is at, in the same folder of the repository,
    /// on `branch` (an existing branch as it is, else a new one by that name or a made-up one). `cwd` must be in `space`'s repository.
    /// Its uncommitted edits don't go with it. Runs git: off the main actor.
    nonisolated static func spawnWorktree(cwd: String, space: String, branch: String?) throws -> (branch: String, exists: Bool, base: String?, subdirectory: String?) {
        guard case .success(let pin) = FleetDispatchGit.pin(cwd: cwd),
              (try? GitWorktree.primaryCheckout(at: pin.root)) == (try? GitWorktree.primaryCheckout(at: space)) else {
            throw RemoteCreateAgentError("\(cwd) isn't in a git checkout of its space's repository, so it can't have a worktree.")
        }
        guard let branch else { return (GitWorktree.generatedBranch(), false, pin.sha, pin.subdir) }
        let exists = ["refs/heads/\(branch)", "refs/remotes/\(branch)"].contains { ref in
            FleetDispatchGit.run(["show-ref", "--verify", "--quiet", ref], in: space)?.status == 0
        }
        return (branch, exists, exists ? nil : pin.sha, pin.subdir)
    }

    /// The most threads a detailed `agent_list` returns; the rest are counted.
    static let detailedListMax = 50

    /// What agent_list shows `sender`: every thread in every space on this host, and no design's agent. Reads state only.
    public static func peerInfos(in state: ShepherdState, sender: AgentID) -> [AgentPeerInfo] {
        peerList(in: state, sender: sender, details: false).rows
    }

    /// The same, as the plain list sends it (every thread, texts as they are) or, with `details`, newest first, at most `detailedListMax`, with
    /// how many older ones it left out, and every text one short line.
    static func peerList(in state: ShepherdState, sender: AgentID, details: Bool) -> (rows: [AgentPeerInfo], omitted: Int) {
        var agents = state.agents.filter { state.isOrdinaryThread($0) }
        if details { agents.sort { ($0.lastActiveAt ?? 0) > ($1.lastActiveAt ?? 0) } }
        let shown = details ? Array(agents.prefix(detailedListMax)) : agents
        let rows = shown.map { agent in
            let cwd = state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd ?? ""
            let space = state.spaces.first { $0.id == agent.spaceID }?.name
            // A thread id decodes from any string; a detailed row prints one only if it is a UUID, else this placeholder.
            let wellFormed = UUID(uuidString: agent.id.rawValue) != nil
            return AgentPeerInfo(
                id: details && !wellFormed ? AgentID(rawValue: "(invalid-id)") : agent.id,
                name: details ? agent.name.listLabel() : agent.name,
                status: agent.status.rawValue,
                cwd: details ? cwd.listLabel(limit: 240) : cwd,
                isSelf: agent.id == sender,
                space: details ? space?.listLabel() : space,
                lastActiveAt: agent.lastActiveAt,
                asking: agent.waitingOn != nil
            )
        }
        return (rows, agents.count - rows.count)
    }
}
