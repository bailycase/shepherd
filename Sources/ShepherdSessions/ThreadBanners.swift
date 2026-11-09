import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// When a local thread's turns and questions post a banner (NotifCatalog, NotifMac). The app and
/// a host with no app decide alike; each passes where banners go, whether someone is watching,
/// and its settings. `AgentBanners` words them.
@MainActor
public final class ThreadBanners {
    public struct Sink {
        public var post: @MainActor (AgentBanner) -> Void
        public var remove: @MainActor ([String]) -> Void
        /// The thing is on screen with Shepherd in front: its turns and questions stay quiet.
        public var isWatching: @MainActor (BannerTarget) -> Bool
        /// Settings ▸ Agents ▸ Notify when a turn finishes: the one banner that can be muted.
        public var notifyOnTurnFinished: @MainActor () -> Bool
        /// Someone else posts the turns and questions for now (the background host's own app,
        /// connected): only the notify tool's banners post here.
        public var quiet: @MainActor () -> Bool = { false }

        public init(post: @escaping @MainActor (AgentBanner) -> Void, remove: @escaping @MainActor ([String]) -> Void,
                    isWatching: @escaping @MainActor (BannerTarget) -> Bool,
                    notifyOnTurnFinished: @escaping @MainActor () -> Bool) {
            self.post = post
            self.remove = remove
            self.isWatching = isWatching
            self.notifyOnTurnFinished = notifyOnTurnFinished
        }
    }

    private let server: SessionServer
    private let state: @MainActor () -> ShepherdState
    /// The threads' requests: the server's, or the background host's for its app.
    private let request: @MainActor (AgentID, NativeThreadRequest) async throws -> NativeThreadResult
    private let sink: Sink
    /// The question each thread asks, so it posts once and goes when answered.
    public private(set) var asks = ThreadAsks<AgentID>()
    private var statusReports: [AgentID: UUID] = [:]
    /// How long a blocked thread waits for its question before "Waiting on your answer." posts.
    var waitingDelay: Duration = .seconds(2)

    /// `state` is the workspace as its host last adopted it (the app's copy, or the server's).
    public init(server: SessionServer, state: @escaping @MainActor () -> ShepherdState, sink: Sink,
                request: (@MainActor (AgentID, NativeThreadRequest) async throws -> NativeThreadResult)? = nil) {
        self.server = server
        self.state = state
        self.sink = sink
        self.request = request ?? { [server] in try await server.nativeThread(agentID: $0, request: $1) }
    }

    /// Whether an agent's turns and questions post as a thread's. A design's agent never does:
    /// its chat is the design's, and every banner here words and acts on a thread.
    public static func notifiesAsThread(_ agentID: AgentID, in state: ShepherdState) -> Bool {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return !state.isDesignAgent(agentID) }
        return state.isOrdinaryThread(agent)
    }

    /// A status report: a turn that finished (with its closing line) or failed, and an asking
    /// tool that never opened a question.
    public func status(_ agent: Agent, from old: AgentStatus, failure: TurnFailure?) {
        guard !sink.quiet(), Self.notifiesAsThread(agent.id, in: state()) else { return }
        let target = BannerTarget.agent(agent.id)
        let report = UUID()
        statusReports[agent.id] = report
        let watching = sink.isWatching(target)
        if agent.status == .blocked, old == .working, !watching { postWaitingIfNoQuestion(agent.id) }
        // No longer waiting: a "Waiting on your answer." banner (never a question's) comes down.
        if old == .blocked, agent.status != .blocked, !asks.isAsking(agent.id) {
            sink.remove([AgentBanners.identifier("question", target)])
        }
        guard let banner = AgentBanners.status(of: agent, from: old, failure: failure, watching: watching) else { return }
        guard failure == nil else {
            Task { [weak self] in
                guard let self else { return }
                let thread = await self.snapshot(agent.id)
                guard self.statusReports[agent.id] == report,
                      Self.notifiesAsThread(agent.id, in: self.state()),
                      self.state().agents.first(where: { $0.id == agent.id })?.piSessionID == agent.piSessionID else { return }
                var stamped = banner
                stamped.recovery = thread.flatMap(AgentBanners.recovery(in:))
                self.sink.post(stamped)
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.snapshot(agent.id).flatMap { AgentBanners.closingReply(in: $0.messages) }
            let current = self.state().agents.first { $0.id == agent.id } ?? agent
            let result = AgentBanners.result(reply)
            guard self.sink.notifyOnTurnFinished() else { return }
            if let finished = AgentBanners.status(of: current, from: old, failure: nil, result: result, watching: false) {
                self.sink.post(finished)
            }
        }
    }

    /// An asking tool set `blocked`; its question usually follows as `waitingOn`. If none comes,
    /// the thread still waits on you, so say that much.
    private func postWaitingIfNoQuestion(_ id: AgentID) {
        Task { [weak self] in
            guard let delay = self?.waitingDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, let agent = self.state().agents.first(where: { $0.id == id }), agent.status == .blocked,
                  !self.asks.isAsking(id), !self.sink.isWatching(.agent(id)) else { return }
            self.sink.post(AgentBanners.waiting(agent))
        }
    }

    /// The questions threads ask, from each adopted state: a new one posts, an answered one
    /// comes down, and a deleted agent's go with it.
    public func questions() {
        guard !sink.quiet() else { return }
        let state = state()
        for agent in state.agents where Self.notifiesAsThread(agent.id, in: state) {
            let target = BannerTarget.agent(agent.id)
            switch asks.update(agent.id, waitingOn: agent.waitingOn) {
            case .asked(let question):
                guard !sink.isWatching(target) else { continue }
                let automation = state.automations.contains { $0.agentID == agent.id }
                postQuestion(agent.id, asked: question, title: agent.name, automation: automation)
            case .answered:
                sink.remove([AgentBanners.identifier("question", target)])
            case nil:
                break
            }
        }
        let live = Set(state.agents.map(\.id))
        let gone = asks.prune { !live.contains($0) }
        sink.remove(gone.map { AgentBanners.identifier("question", .agent($0)) })
    }

    /// A thread's question with the dock's choices: its dialog read from the thread.
    private func postQuestion(_ id: AgentID, asked: String, title: String, automation: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let dialogs = await self.snapshot(id)?.dialogs ?? []
            guard self.asks.current(id) == asked else { return }
            self.sink.post(Self.question(dialogs, asked: asked, title: title, target: .agent(id), automation: automation))
        }
    }

    /// The question's banner, with the dialog that asked it (or the first) for its choices.
    public static func question(_ dialogs: [NativeThreadDialog], asked: String, title: String, target: BannerTarget,
                                automation: Bool) -> AgentBanner {
        let dialog = dialogs.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == asked } ?? dialogs.first
        return AgentBanners.question(dialog.map(NativeQuestionPrompt.init(dialog:)), asked: asked, title: title,
                                     target: target, automation: automation)
    }

    /// The agent is gone: its question's banner goes with it.
    public func forget(_ id: AgentID) {
        asks.forget(id)
        statusReports.removeValue(forKey: id)
        sink.remove([AgentBanners.identifier("question", .agent(id))])
    }

    /// A host with no app acts on a banner's answer or Retry itself: an option or Reply…'s words
    /// go to the dialog that asked, and Retry continues the exact checkpoint the banner captured.
    /// Anything stale (answered elsewhere, another checkpoint) does nothing.
    public func respond(_ id: AgentID, action: BannerAction, question: String?, text: String?,
                        recovery: NativeThreadRequest?) async {
        guard let thread = await snapshot(id) else { return }
        let request: NativeThreadRequest
        switch action {
        case .option, .reply:
            let option: Int? = if case .option(let number, _) = action { number } else { nil }
            guard let question, let dialog = thread.dialogs.first(where: { $0.id == question }) else { return }
            let prompt = NativeQuestionPrompt(dialog: dialog)
            guard let reply = AgentBanners.answer(prompt, option: option, words: text),
                  let answer = prompt.dialogAnswer(reply) else { return }
            request = .answer(expectedSessionID: thread.piSessionID, generation: thread.generation,
                              operationID: UUID(), dialogID: dialog.id, answer: answer)
        case .retry:
            guard let recovery, AgentBanners.matchesRecovery(recovery, in: thread) else { return }
            request = recovery
        case .open, .review, .reconnect:
            return
        }
        if case .failure(let code, _)? = try? await self.request(id, request) {
            ShepherdLog.info("banner action on \(id) refused: \(code)")
        }
    }

    /// The thread's newest page, as its view would pull it.
    private func snapshot(_ id: AgentID) async -> NativeThreadSnapshot? {
        guard case .snapshot(let value)? = try? await request(id, .snapshot()) else { return nil }
        return value
    }
}

extension ThreadBanners {
    /// A host with no app: banners come from the server's own status reports and states, and the
    /// notify tool's always post. Wraps the server's `onAgentStatus`, `onStateChanged` and
    /// `onNotify` (whatever they were set to still runs first).
    public func observeServer() {
        var statuses = Dictionary(server.state.agents.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        let (onStatus, onState, onNotify) = (server.onAgentStatus, server.onStateChanged, server.onNotify)
        server.onAgentStatus = { [weak self] id, status, failure in
            onStatus?(id, status, failure)
            MainActor.assumeIsolated {
                guard let self, var agent = self.server.state.agents.first(where: { $0.id == id }) else { return }
                let old = statuses[id] ?? agent.status
                statuses[id] = status
                agent.status = status
                self.status(agent, from: old, failure: failure)
            }
        }
        server.onStateChanged = { [weak self] state in
            onState?(state)
            MainActor.assumeIsolated {
                let live = Set(state.agents.map(\.id))
                statuses = statuses.filter { live.contains($0.key) }
                self?.questions()
            }
        }
        server.onNotify = { [weak self] id, title, body in
            onNotify?(id, title, body)
            MainActor.assumeIsolated {
                guard let self, let agent = self.server.state.agents.first(where: { $0.id == id }) else { return }
                // The app showing these threads as its own posts it, and its click opens the thread there.
                if self.sink.quiet(), self.server.relayNotifyToLocalApp(agentID: id, title: title, body: body) { return }
                self.sink.post(AgentBanners.agentNotify(agent, title: title, body: body))
            }
        }
    }
}
