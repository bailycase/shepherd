import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// An agent's browser tools reach only its own thread's page (docs/browser.md › Isolation): the
/// server serves a request only on the connection that registered as the agent it names, refuses
/// a design's agent, answers a page that never answers with a timeout, and never writes to a
/// connection that has gone.
@Suite("Browser relay", .integrationTimeLimit)
struct BrowserRelayTests {
    private let click = BrowserRequest.click(ref: "e1", double: false, note: nil)

    /// Two threads and a design's agent.
    private func workspace(_ h: ScratchServer) async throws -> (a: Agent, b: Agent, drawer: Agent) {
        let space = Fixture.space()
        let a = Fixture.agent(in: space, name: "Fix the checkout")
        let b = Fixture.agent(in: space, name: "Other thread")
        let designID = DesignID()
        var drawer = Fixture.agent(in: space, name: "Landing hero")
        drawer.agent.designID = designID
        try await h.seed(Fixture.workspace([a, b, drawer], space: space))
        _ = try await h.server.createDesign(Design(id: designID, name: "Landing hero", agentID: drawer.agent.id, createdAt: 1_000))
        return (a.agent, b.agent, drawer.agent)
    }

    /// `hello`, then a request nobody answers is not needed: a registered connection is proved by
    /// the request that follows it, so tests send their own.
    private func register(_ client: ExtensionClient, as agentID: AgentID) throws {
        try client.send(.helloBrowser(agentID: agentID))
    }

    /// What the app was asked, and how it answers.
    private final class App: @unchecked Sendable {
        let asked = Locked<[(AgentID, BrowserRequest)]>([])
        let held = Locked<[(BrowserOutcome) -> Void]>([])
    }

    private func answering(_ h: ScratchServer, _ app: App, with outcome: BrowserOutcome? = nil) {
        h.server.onBrowserRequest = { agentID, request, respond in
            app.asked.withValue { $0.append((agentID, request)) }
            if let outcome { respond(outcome) } else { app.held.withValue { $0.append(respond) } }
        }
    }

    @Test func aRegisteredConnectionReachesItsOwnPageAndNotAnothers() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, b, _) = try await workspace(h)
        let app = App()
        answering(h, app, with: .text("Clicked button \"Pay\"."))
        let client = try ExtensionClient(path: h.socketPath)
        try register(client, as: a.id)

        try client.send(.browser(id: 1, agentID: a.id, request: click))
        #expect(try await client.reply() == .browserResult(id: 1, text: "Clicked button \"Pay\".", image: nil))
        #expect(app.asked.current.count == 1 && app.asked.current[0].0 == a.id && app.asked.current[0].1 == click)

        // Naming another thread is refused, whatever the connection is registered as.
        try client.send(.browser(id: 2, agentID: b.id, request: click))
        guard case .error(2, "not_registered", _) = try await client.reply() else { Issue.record("another thread's page was reached"); return }
        try client.send(.browser(id: 3, agentID: AgentID(), request: click))
        guard case .error(3, "not_registered", _) = try await client.reply() else { Issue.record("a stranger's page was reached"); return }
        #expect(app.asked.current.count == 1, "the app was asked only for its own agent")

        // The other thread's own connection reaches its own page, not the first's.
        let other = try ExtensionClient(path: h.socketPath)
        try register(other, as: b.id)
        try other.send(.browser(id: 4, agentID: b.id, request: .read(selector: nil, maxChars: nil)))
        #expect(try await other.reply() == .browserResult(id: 4, text: "Clicked button \"Pay\".", image: nil))
        #expect(app.asked.current.last?.0 == b.id)
        try other.send(.browser(id: 5, agentID: a.id, request: click))
        guard case .error(5, "not_registered", _) = try await other.reply() else { Issue.record("b reached a's page"); return }
    }

    @Test func anUnregisteredConnectionAndAnUnknownAgentAreRefused() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, _, _) = try await workspace(h)
        let app = App()
        answering(h, app, with: .text("no"))

        let bare = try ExtensionClient(path: h.socketPath)
        try bare.send(.browser(id: 1, agentID: a.id, request: click))
        guard case .error(1, "not_registered", _) = try await bare.reply() else { Issue.record("an unregistered connection was served"); return }

        // A panes connection is no browser connection.
        let panes = try ExtensionClient(path: h.socketPath)
        try panes.send(.helloAgent(agentID: a.id))
        try panes.send(.browser(id: 2, agentID: a.id, request: click))
        guard case .error(2, "not_registered", _) = try await panes.reply() else { Issue.record("a panes connection was served"); return }

        let stranger = try ExtensionClient(path: h.socketPath)
        let unknown = AgentID()
        try register(stranger, as: unknown)
        try stranger.send(.browser(id: 3, agentID: unknown, request: click))
        guard case .error(3, "not_registered", _) = try await stranger.reply() else { Issue.record("an unknown agent was served"); return }
        #expect(app.asked.current.isEmpty)
    }

    @Test func aDesignsAgentGetsNoBrowser() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (_, _, drawer) = try await workspace(h)
        let app = App()
        answering(h, app, with: .text("no"))
        let client = try ExtensionClient(path: h.socketPath)
        try register(client, as: drawer.id)
        try client.send(.browser(id: 1, agentID: drawer.id, request: .open(url: "http://localhost:5173/", note: nil)))
        guard case .error(1, "not_registered", _) = try await client.reply() else { Issue.record("a design's agent was served"); return }
        #expect(app.asked.current.isEmpty)
    }

    @Test func aFailureCarriesItsCodeAndMessage() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, _, _) = try await workspace(h)
        let app = App()
        answering(h, app, with: .failure(code: "taken_over", message: BrowserAgentPresenceWords.takenOver))
        let client = try ExtensionClient(path: h.socketPath)
        try register(client, as: a.id)
        try client.send(.browser(id: 1, agentID: a.id, request: click))
        #expect(try await client.reply() == .error(id: 1, code: "taken_over", message: BrowserAgentPresenceWords.takenOver))
    }

    @Test func withoutTheAppTheAnswerIsUnavailable() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, _, _) = try await workspace(h)
        let client = try ExtensionClient(path: h.socketPath)
        try register(client, as: a.id)
        try client.send(.browser(id: 1, agentID: a.id, request: click))
        guard case .error(1, "unavailable", _) = try await client.reply() else { Issue.record("expected unavailable"); return }
    }

    @Test func aRequestTheAppNeverAnswersTimesOutAndALateAnswerIsDropped() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        h.server.setBrowserDeadline(0.3)
        let (a, _, _) = try await workspace(h)
        let app = App()
        answering(h, app)
        let client = try ExtensionClient(path: h.socketPath)
        try register(client, as: a.id)
        try client.send(.browser(id: 1, agentID: a.id, request: click))
        guard case .error(1, "timeout", _) = try await client.reply(timeout: .seconds(5)) else { Issue.record("expected a timeout"); return }

        // The app answers after the deadline: nothing more is written for it.
        try await eventually("the request to reach the app") { app.held.current.count == 1 }
        app.held.current[0](.text("too late"))
        try client.send(.browser(id: 2, agentID: a.id, request: click))
        try await eventually("the next request") { app.held.current.count == 2 }
        app.held.current[1](.text("on time"))
        #expect(try await client.reply() == .browserResult(id: 2, text: "on time", image: nil), "the late answer wrote nothing")
    }

    @Test func aClosedConnectionGetsNoReplyAndItsSlotDoesNotLeak() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, _, _) = try await workspace(h)
        let app = App()
        answering(h, app)
        let first = try ExtensionClient(path: h.socketPath)
        try register(first, as: a.id)
        try first.send(.browser(id: 1, agentID: a.id, request: click))
        try await eventually("the request to reach the app") { app.held.current.count == 1 }
        first.closeConnection()
        try await Task.sleep(for: .milliseconds(100))

        // A new connection (perhaps on the same descriptor) hears only its own answers.
        let second = try ExtensionClient(path: h.socketPath)
        try register(second, as: a.id)
        app.held.current[0](.text("for nobody"))
        try second.send(.browser(id: 9, agentID: a.id, request: click))
        try await eventually("the second request") { app.held.current.count == 2 }
        app.held.current[1](.text("for the second"))
        #expect(try await second.reply() == .browserResult(id: 9, text: "for the second", image: nil))
    }

    @Test func aSecondConnectionForTheSameAgentReplacesTheFirst() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, _, _) = try await workspace(h)
        let app = App()
        answering(h, app, with: .text("ok"))
        let first = try ExtensionClient(path: h.socketPath)
        try register(first, as: a.id)
        try first.send(.browser(id: 1, agentID: a.id, request: click))
        _ = try await first.reply()
        let second = try ExtensionClient(path: h.socketPath)
        try register(second, as: a.id)
        #expect(try await first.disconnected(timeout: .seconds(5)), "one live browser connection per agent")
        try second.send(.browser(id: 2, agentID: a.id, request: click))
        #expect(try await second.reply() == .browserResult(id: 2, text: "ok", image: nil))
    }

    /// The user's next message to a thread gives the agent its browser back after a take over: it
    /// reaches the app from the composer, local or remote, and not from a peer's `agent_send`.
    @Test func aUsersMessageToAThreadIsHeardButAPeersIsNot() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let heard = Locked<[AgentID]>([])
        h.server.onUserMessage = { agentID in heard.withValue { $0.append(agentID) } }
        let ready = try await pi.ready()

        // A peer's message is pushed to the agent's panes connection and never counts.
        let panes = try ExtensionClient(path: h.socketPath)
        try panes.send(.helloAgent(agentID: pi.agent.id))
        try panes.send(.listPanes(id: 1, agentID: pi.agent.id))
        _ = try await panes.reply()
        #expect(h.server.pushMessage(toAgent: pi.agent.id, text: "[from: worker] CI is green", delivery: .report))
        try await Task.sleep(for: .milliseconds(150))
        #expect(heard.current.isEmpty, "a peer's message is not the user's")

        _ = try await pi.send("tools:0 hello", from: ready)
        try await eventually("the user's message heard") { heard.current == [pi.agent.id] }
    }

    @Test func aReplyStaysUnderTheFrameCap() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let (a, _, _) = try await workspace(h)
        let app = App()
        let huge = String(repeating: "line “ünicode”\n", count: 20_000)
        answering(h, app, with: .result(text: huge, image: BrowserImage(data: String(repeating: "A", count: 500 * 1024), mimeType: "image/jpeg")))
        let client = try ExtensionClient(path: h.socketPath)
        try register(client, as: a.id)
        try client.send(.browser(id: 1, agentID: a.id, request: .screenshot(ref: nil)))
        guard case .browserResult(1, let text, let image) = try await client.reply() else { Issue.record("expected a result"); return }
        #expect(text.utf8.count <= BrowserOutcome.maxTextBytes + 64)
        #expect(text.contains("[truncated]") && text.contains("screenshot was too large"))
        #expect(image == nil)

        answering(h, app, with: .result(text: "ok", image: BrowserImage(data: String(repeating: "A", count: 390 * 1024), mimeType: "image/jpeg")))
        try client.send(.browser(id: 2, agentID: a.id, request: .screenshot(ref: nil)))
        guard case .browserResult(2, "ok", let kept?) = try await client.reply() else { Issue.record("expected the image"); return }
        #expect(kept.data.utf8.count == 390 * 1024)
    }
}

/// The refusal text a take over carries, as the app words it.
private enum BrowserAgentPresenceWords {
    static let takenOver = "The user took over the browser. Wait for their next message before acting on it; browser_read, browser_screenshot and browser_console still work."
}
