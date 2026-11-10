import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// The Mac's notifications (NotifCatalog, NotifMac): when each is posted and taken down, and what its actions do. `AgentBanners`
// words them; `AgentNotifications` posts them.
extension ShepherdViewModel {
    /// Quiet while you watch: the thing is on screen and Shepherd is in front.
    func isWatching(_ target: BannerTarget) -> Bool {
        // No NSApp in a test process: nothing is in front.
        guard NSApp?.isActive == true else { return false }
        switch target {
        case .agent(let id): return threadIsOnScreen && selectedAgentID == id && selectedRemoteAgent == nil
        case .remote(let ref): return threadIsOnScreen && selectedRemoteAgent == ref
        case .host(let id): return selectedRemoteAgent?.hostID == id
        }
    }

    /// A page, Settings or the gallery covers the selected thread without clearing the selection:
    /// the person is not looking at it, so its turns and questions post.
    var threadIsOnScreen: Bool {
        destination == nil && !showSettings && !showComponentGallery
    }

    /// Tells the server which local thread you are watching, so its phone pushes stay quiet too.
    func syncFocusedThread() {
        let watched = selectedAgentID.flatMap { isWatching(.agent($0)) ? $0 : nil }
        if localHost != nil { remoteHosts.focusLocalThread(watched) } else { server.setFocusedThread(watched) }
    }

    /// Calls `syncFocusedThread` now and whenever the selection or what covers it changes.
    /// `NSApp.isActive` is not observable: the activation observers call it themselves.
    func trackFocusedThread() {
        withObservationTracking { syncFocusedThread() } onChange: {
            Task { @MainActor [weak self] in self?.trackFocusedThread() }
        }
    }

    // MARK: Posting

    /// Whether an agent's turns and questions post as a thread's (`ThreadBanners.notifiesAsThread`).
    static func notifiesAsThread(_ agentID: AgentID, in state: ShepherdState) -> Bool {
        ThreadBanners.notifiesAsThread(agentID, in: state)
    }

    /// A local agent's status report (`ThreadBanners.status`).
    func notifyStatus(_ agent: Agent, from old: AgentStatus, failure: TurnFailure?) {
        guard notifications.available else { return }
        threadBanners.status(agent, from: old, failure: failure)
    }

    /// The questions local threads ask, from each adopted state (`ThreadBanners.questions`).
    func notifyLocalQuestions() {
        guard notifications.available else { return }
        threadBanners.questions()
    }

    /// A remote thread's question with the dock's choices: its dialog read from the thread.
    private func postQuestion(_ ref: RemoteAgentRef, asked: String, title: String, automation: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let dialogs = await self.snapshot(.remote(ref))?.dialogs ?? []
            guard self.notifications.remoteAsks.current(ref) == asked else { return }
            self.notifications.post(ThreadBanners.question(dialogs, asked: asked, title: title, target: .remote(ref),
                                                           automation: automation))
        }
    }

    /// The agent is gone: its question's banner goes with it. A subagent's question never posts
    /// one: it goes to its parent, which asks the user in its own thread when it must.
    func forgetNotifications(of agentID: AgentID) {
        threadBanners.forget(agentID)
    }

    /// Every host's threads notify here as this Mac's do: their questions.
    /// A host that goes away while connected posts once, and its banner goes when it is back.
    func notifyRemote() {
        guard notifications.available else { return }
        var live = Set<RemoteAgentRef>()
        var hosts = Set<UUID>()
        // The background host's threads the app shows as its own post as in process; the rest of
        // its threads (automation runs, Projects' workers) post here, as a host's.
        let own = localHost.map { host in (host.id, Set(state.agents.map(\.id))) }
        for connection in remoteHosts.allConnections {
            hosts.insert(connection.id)
            let mirrored = own.flatMap { $0.0 == connection.id ? $0.1 : nil }
            let away = HostAway.reconnecting(connection.phase, lastSeen: connection.lastSeen, thisMac: connection.isThisMac)
            let offline = BannerTarget.host(connection.id)
            if mirrored != nil {
                // Transport only: losing it is `onLocalHostLost`'s, never a host-offline banner.
            } else if away, notifications.offlineHosts.insert(connection.id).inserted, !isWatching(offline) {
                notifications.post(AgentBanners.hostOffline(name: connection.config.name, hostID: connection.id))
            } else if !away, notifications.offlineHosts.remove(connection.id) != nil {
                notifications.remove([AgentBanners.identifier("offline", offline)])
            }
            guard connection.phase == .connected else { continue }
            for agent in connection.state.agents where connection.state.isOrdinaryThread(agent) && mirrored?.contains(agent.id) != true {
                let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.id)
                let target = BannerTarget.remote(ref)
                live.insert(ref)
                switch notifications.remoteAsks.update(ref, waitingOn: agent.waitingOn) {
                case .asked(let question) where !isWatching(target):
                    let automation = connection.state.automations.contains { $0.agentID == agent.id }
                    postQuestion(ref, asked: question, title: agent.name, automation: automation)
                case .answered:
                    notifications.remove([AgentBanners.identifier("question", target)])
                default:
                    break
                }
            }
        }
        // Agents a connected host no longer has, and every agent of a removed host. A host away
        // keeps its questions, so one still asked when it is back does not post again.
        let connected = Set(remoteHosts.allConnections.filter { $0.phase == .connected }.map(\.id))
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
            if remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.state.agents.contains(where: { $0.id == ref.agentID }) == true {
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
        case .agent(let id): try await nativeThread(id, request: request)
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
