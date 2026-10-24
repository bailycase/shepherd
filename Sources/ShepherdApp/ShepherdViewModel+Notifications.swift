import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// The Mac's notifications (NotifCatalog, NotifMac; docs/design/notifications.md › Notifications and Live
// Activities › Mac): when each is posted and taken down, and what its actions do. `AgentBanners`
// words them; `AgentNotifications` posts them.
extension ShepherdViewModel {
    /// Quiet while you watch: the thing is on screen and Shepherd is in front.
    func isWatching(_ target: BannerTarget) -> Bool {
        guard NSApp.isActive else { return false }
        switch target {
        case .agent(let id): return selectedAgentID == id && selectedRemoteAgent == nil
        case .remote(let ref): return selectedRemoteAgent == ref
        case .host(let id): return selectedRemoteAgent?.hostID == id
        }
    }

    // MARK: Posting

    /// Whether an agent's turns and questions post as a thread's. A design's agent never does:
    /// its chat is the design's, and every banner here words and acts on a thread.
    static func notifiesAsThread(_ agentID: AgentID, in state: ShepherdState) -> Bool {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return !state.isDesignAgent(agentID) }
        return state.isOrdinaryThread(agent)
    }

    /// A local agent's status report: a turn that finished (with its closing line) or failed,
    /// and an asking tool that never opened a question.
    func notifyStatus(_ agent: Agent, from old: AgentStatus, failure: TurnFailure?) {
        guard notifications.available, Self.notifiesAsThread(agent.id, in: state) else { return }
        let target = BannerTarget.agent(agent.id)
        let report = UUID()
        notifications.statusReports[agent.id] = report
        let watching = isWatching(target)
        if agent.status == .blocked, old == .working, !watching { postWaitingIfNoQuestion(agent.id) }
        // No longer waiting: a "Waiting on your answer." banner (never a question's) comes down.
        if old == .blocked, agent.status != .blocked, !notifications.localAsks.isAsking(agent.id) {
            notifications.remove([AgentBanners.identifier("question", target)])
        }
        guard let banner = AgentBanners.status(of: agent, from: old, failure: failure, watching: watching) else { return }
        guard failure == nil else {
            Task { [weak self] in
                guard let self else { return }
                let thread = await self.snapshot(target)
                guard self.notifications.statusReports[agent.id] == report,
                      Self.notifiesAsThread(agent.id, in: self.state),
                      self.state.agents.first(where: { $0.id == agent.id })?.piSessionID == agent.piSessionID else { return }
                var stamped = banner
                stamped.recovery = thread.flatMap(AgentBanners.recovery(in:))
                self.notifications.post(stamped)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.snapshot(target).flatMap { AgentBanners.closingReply(in: $0.messages) }
            let current = self.state.agents.first { $0.id == agent.id } ?? agent
            let result = AgentBanners.result(reply)
            if let finished = AgentBanners.status(of: current, from: old, failure: nil, result: result, watching: false) {
                self.notifications.post(finished)
            }
        }
    }

    /// An asking tool set `blocked`; its question usually follows as `waitingOn`. If none comes,
    /// the thread still waits on you, so say that much.
    private func postWaitingIfNoQuestion(_ id: AgentID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let agent = self.state.agents.first(where: { $0.id == id }), agent.status == .blocked,
                  !self.notifications.localAsks.isAsking(id), !self.isWatching(.agent(id)) else { return }
            self.notifications.post(AgentBanners.waiting(agent))
        }
    }

    /// The questions local threads ask, from each adopted state: a new one posts, an answered one
    /// comes down, and a deleted agent's go with it.
    func notifyLocalQuestions() {
        guard notifications.available else { return }
        for agent in state.agents where Self.notifiesAsThread(agent.id, in: state) {
            let target = BannerTarget.agent(agent.id)
            switch notifications.localAsks.update(agent.id, waitingOn: agent.waitingOn) {
            case .asked(let question):
                guard !isWatching(target) else { continue }
                let automation = state.automations.contains { $0.agentID == agent.id }
                postQuestion(target, asked: question, title: agent.name, automation: automation)
            case .answered:
                notifications.remove([AgentBanners.identifier("question", target)])
            case nil:
                break
            }
        }
        let live = Set(state.agents.map(\.id))
        let gone = notifications.localAsks.prune { !live.contains($0) }
        notifications.remove(gone.map { AgentBanners.identifier("question", .agent($0)) })
    }

    /// A thread's question with the dock's choices: its dialog read from the thread.
    private func postQuestion(_ target: BannerTarget, asked: String, title: String, automation: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let dialogs = await self.snapshot(target)?.dialogs ?? []
            let still: String? = switch target {
            case .agent(let id): self.notifications.localAsks.current(id)
            case .remote(let ref): self.notifications.remoteAsks.current(ref)
            case .host: nil
            }
            guard still == asked else { return }
            let dialog = dialogs.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == asked } ?? dialogs.first
            self.notifications.post(AgentBanners.question(dialog.map(NativeQuestionPrompt.init(dialog:)), asked: asked,
                                                          title: title, target: target, automation: automation))
        }
    }

    /// The agent is gone: its question's banner goes with it. A subagent's question never posts
    /// one: it goes to its parent, which asks the user in its own thread when it must.
    func forgetNotifications(of agentID: AgentID) {
        let target = BannerTarget.agent(agentID)
        notifications.localAsks.forget(agentID)
        notifications.statusReports.removeValue(forKey: agentID)
        notifications.remove([AgentBanners.identifier("question", target)])
    }

    /// Every host's threads notify here as this Mac's do: their questions.
    /// A host that goes away while connected posts once, and its banner goes when it is back.
    func notifyRemote() {
        guard notifications.available else { return }
        var live = Set<RemoteAgentRef>()
        var hosts = Set<UUID>()
        for connection in remoteHosts.connections {
            hosts.insert(connection.id)
            let away = HostAway.reconnecting(connection.phase, lastSeen: connection.lastSeen)
            let offline = BannerTarget.host(connection.id)
            if away, notifications.offlineHosts.insert(connection.id).inserted, !isWatching(offline) {
                notifications.post(AgentBanners.hostOffline(name: connection.config.name, hostID: connection.id))
            } else if !away, notifications.offlineHosts.remove(connection.id) != nil {
                notifications.remove([AgentBanners.identifier("offline", offline)])
            }
            guard connection.phase == .connected else { continue }
            for agent in connection.state.agents where connection.state.isOrdinaryThread(agent) {
                let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
                let target = BannerTarget.remote(ref)
                live.insert(ref)
                switch notifications.remoteAsks.update(ref, waitingOn: agent.waitingOn) {
                case .asked(let question) where !isWatching(target):
                    let automation = connection.state.automations.contains { $0.agentID == agent.id }
                    postQuestion(target, asked: question, title: agent.name, automation: automation)
                case .answered:
                    notifications.remove([AgentBanners.identifier("question", target)])
                default:
                    break
                }
            }
        }
        // Agents a connected host no longer has, and every agent of a removed host. A host away
        // keeps its questions, so one still asked when it is back does not post again.
        let connected = Set(remoteHosts.connections.filter { $0.phase == .connected }.map(\.id))
        let gone = notifications.remoteAsks.prune { ref in
            !hosts.contains(ref.hostID) || (connected.contains(ref.hostID) && !live.contains(ref))
        }
        notifications.remove(gone.map { AgentBanners.identifier("question", .remote($0)) })
        for removed in notifications.offlineHosts.subtracting(hosts) {
            notifications.offlineHosts.remove(removed)
            notifications.remove([AgentBanners.identifier("offline", .host(removed))])
        }
    }

    // MARK: Responses

    /// A click or an action on a banner.
    func respond(to response: BannerResponse) {
        switch response.action {
        case nil, .open?:
            show(response.target)
        case .review?:
            show(response.target)
            switch response.target {
            case .agent(let id) where state.agents.contains(where: { $0.id == id }) && Self.notifiesAsThread(id, in: state):
                openReview(agentID: id, path: nil)
            case .remote(let ref): openRemoteReview(ref, path: nil)
            default: break
            }
        case .retry?:
            Task { await retryTurn(response.target, recovery: response.recovery) }
        case .reconnect?:
            if case .host(let id) = response.target { remoteHosts.reconnect(id: id) }
        case .option(let number, _)?:
            Task { await answer(response.target, question: response.question, option: number, words: nil) }
        case .reply?:
            Task { await answer(response.target, question: response.question, option: nil, words: response.text) }
        }
    }

    /// Brings the thing forward: the thread, a remote thread, or the Hosts page.
    private func show(_ target: BannerTarget) {
        switch target {
        case .agent(let id):
            if state.agents.contains(where: { $0.id == id }) { selectAgent(id) }
        case .remote(let ref):
            if remoteHosts.connections.first(where: { $0.id == ref.hostID })?.state.agents.contains(where: { $0.id == ref.agentID }) == true {
                selectRemoteAgent(hostID: ref.hostID, agentID: ref.agentID)
            }
        case .host:
            openDestination(.hosts)
        }
    }

    /// A notification continues the exact checkpoint too, never resends the prompt.
    private func retryTurn(_ target: BannerTarget, recovery: NativeThreadRequest?) async {
        show(target)
        let store: NativeThreadStore
        switch target {
        case .agent(let id): store = threadStores.store(for: id)
        case .remote(let ref): store = remoteThreadStores.store(for: ref)
        case .host: return
        }
        guard let thread = await snapshot(target) else {
            store.reportActionNotice("The thread is unavailable. Nothing was continued."); return
        }
        guard !thread.running else { store.reportActionNotice("Wait for the current operation before continuing."); return }
        guard thread.supportedActions.contains("checkpointRecovery"),
              let checkpoint = thread.checkpointRecovery?.checkpoint else {
            store.reportActionNotice(thread.checkpointRecovery?.refusalMessage ?? "Continue requires an updated host and Pi engine with message-free checkpoint recovery support.")
            return
        }
        guard let recovery, AgentBanners.matchesRecovery(recovery, in: thread) else {
            store.reportActionNotice("This notification does not identify the current checkpoint. Open the thread and choose Continue on the current interrupted reply.")
            return
        }
        let message: String?
        var refusalCode: String?
        do {
            let result = try await request(target, recovery)
            if case .failure(let code, let problem) = result { refusalCode = code; message = problem }
            else if case .accepted = result { message = nil }
            else { message = "Recovery delivery is unknown. Nothing will be resent automatically." }
        } catch {
            message = "Recovery delivery is unknown. Nothing will be resent automatically."
        }
        guard let message, let current = await snapshot(target), current.piSessionID == thread.piSessionID,
              current.generation == thread.generation else { return }
        if let refusalCode { store.recordRecoveryRefusal(code: refusalCode, sessionID: thread.piSessionID, checkpoint: checkpoint) }
        store.reportActionNotice(message)
    }

    /// An option or Reply…'s words, to pi's dialog that asked. A question answered elsewhere
    /// meanwhile takes nothing.
    private func answer(_ target: BannerTarget, question: String?, option: Int?, words: String?) async {
        guard let question, let thread = await snapshot(target) else { return }
        guard let dialog = thread.dialogs.first(where: { $0.id == question }) else { return }
        let prompt = NativeQuestionPrompt(dialog: dialog)
        guard let reply = AgentBanners.answer(prompt, option: option, words: words),
              let answer = prompt.dialogAnswer(reply) else { return }
        _ = try? await request(target, .answer(expectedSessionID: thread.piSessionID, generation: thread.generation,
                                               operationID: UUID(), dialogID: dialog.id, answer: answer))
    }

    // MARK: The thread

    private func request(_ target: BannerTarget, _ request: NativeThreadRequest) async throws -> NativeThreadResult? {
        switch target {
        case .agent(let id): try await server.nativeThread(agentID: id, request: request)
        case .remote(let ref): try await remoteHosts.nativeThread(ref, request: request)
        case .host: nil
        }
    }

    /// The thread's newest page, as its view would pull it.
    private func snapshot(_ target: BannerTarget) async -> NativeThreadSnapshot? {
        guard case .snapshot(let value)? = try? await request(target, .snapshot()) else { return nil }
        return value
    }
}
