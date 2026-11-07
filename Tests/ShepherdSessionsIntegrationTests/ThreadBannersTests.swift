import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A host with no app posts threads' banners from the server's own reports
/// (`ThreadBanners.observeServer`), into a sink standing in for the Mac's notifications.
@Suite("Thread banners hosted by the server")
struct ThreadBannersTests {
    final class Setup: @unchecked Sendable {
        let pi: PiAgent
        let posted = Locked<[AgentBanner]>([])
        let removed = Locked<[String]>([])
        let watching = Locked(false)
        let banners: ThreadBanners

        init() async throws {
            pi = try await PiAgent.launch(on: try ScratchServer.fresh())
            let server = pi.server
            banners = await MainActor.run { [posted, removed, watching] in
                let banners = ThreadBanners(server: server, state: { server.state }, sink: .init(
                    post: { banner in posted.withValue { $0.append(banner) } },
                    remove: { ids in removed.withValue { $0.append(contentsOf: ids) } },
                    isWatching: { _ in watching.current },
                    notifyOnTurnFinished: { true }))
                banners.observeServer()
                return banners
            }
        }

        func report(_ status: AgentStatus) async throws {
            let client = try ExtensionClient(path: pi.host.socketPath)
            try client.send(.setAgentStatus(agentID: pi.agent.id, status: status))
            try await eventually("the \(status) report") { self.pi.server.state.agents.first { $0.id == self.pi.agent.id }?.status == status }
        }

        func stop() { pi.host.stop() }
    }

    @Test func aFinishedTurnPostsWithNoAppRunning() async throws {
        let s = try await Setup()
        defer { s.stop() }
        let ready = try await s.pi.ready()
        _ = try await s.pi.send("hello", from: ready)
        _ = try await s.pi.snapshot("the turn to settle") { !$0.running && $0.messages.count > ready.messages.count }
        try await s.report(.working)
        try await s.report(.done)
        try await eventually("the turn finished banner") { !s.posted.current.isEmpty }
        let banner = try #require(s.posted.current.first)
        #expect(banner.subtitle == "Turn finished")
        #expect(banner.target == .agent(s.pi.agent.id))
        #expect(banner.title == s.pi.agent.name)
        #expect(banner.actions == [.review])
    }

    @Test func aWatchedThreadPostsNothing() async throws {
        let s = try await Setup()
        defer { s.stop() }
        s.watching.withValue { $0 = true }
        let ready = try await s.pi.ready()
        _ = try await s.pi.send("hello", from: ready)
        let settled = try await s.pi.snapshot("the turn to settle") { !$0.running && $0.messages.count > ready.messages.count }
        try await s.report(.working)
        try await s.report(.done)
        _ = try await s.pi.send("select", from: settled)
        try await eventually("the question to reach state") { s.pi.server.state.agents.first?.waitingOn == "Pick one" }
        // The notify tool's banner is always posted; it comes after the others, so once it is
        // in, nothing else was.
        let client = try ExtensionClient(path: s.pi.host.socketPath)
        try client.send(.notify(agentID: s.pi.agent.id, title: "CI passed", body: "PR #42 is green"))
        try await eventually("the notify banner") { !s.posted.current.isEmpty }
        try await drainMainQueue()
        #expect(s.posted.current.map(\.title) == ["CI passed"])
        #expect(s.posted.current.first?.body == "\(s.pi.agent.name)\nPR #42 is green")
    }

    @Test func aQuestionPostsItsChoicesAndAnAnswerTakesItDown() async throws {
        let s = try await Setup()
        defer { s.stop() }
        let ready = try await s.pi.ready()
        _ = try await s.pi.send("select", from: ready)
        try await eventually("the question banner") { !s.posted.current.isEmpty }
        let banner = try #require(s.posted.current.first)
        #expect(banner.subtitle == "Question")
        #expect(banner.body == "Pick one")
        #expect(banner.actions.map(\.title) == ["Allow", "Deny"])
        let question = try #require(banner.question)

        // The banner's Allow, as the host answers it.
        await s.banners.respond(s.pi.agent.id, action: banner.actions[0], question: question, text: nil, recovery: nil)
        try await eventually("the banner to come down") {
            s.removed.current.contains(AgentBanners.identifier("question", .agent(s.pi.agent.id)))
        }
        #expect(s.posted.current.count == 1, "one question posts once")
    }
}
