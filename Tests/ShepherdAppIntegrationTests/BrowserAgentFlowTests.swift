import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// An agent's browser tools end to end: the extension socket, the server's routing, the view
/// model, and each thread's own page (docs/browser.md). The tools are driven as the pi extension
/// drives them; the stub pi stands in for the model.
@Suite("Browser agent flow", .mainActorExclusive)
@MainActor
struct BrowserAgentFlowTests {
    /// A raw browser connection of one agent, as its extension keeps.
    private final class Connection: @unchecked Sendable {
        let client: ExtensionClient
        let agentID: AgentID
        private var next = 0

        init(socketPath: String, agent: AgentID, register: Bool = true) throws {
            client = try ExtensionClient(path: socketPath)
            agentID = agent
            if register { try client.send(.helloBrowser(agentID: agent)) }
        }

        /// One request, and its reply (the main actor answers it, so the wait is off the actor).
        func ask(_ request: BrowserRequest, as agent: AgentID? = nil) async throws -> ExtensionReply {
            next += 1
            let id = next
            try client.send(.browser(id: id, agentID: agent ?? agentID, request: request))
            let client = client
            return try await Task.detached { try client.readReply(timeout: .seconds(30)) }.value
        }

        func text(_ request: BrowserRequest) async throws -> String {
            guard case .browserResult(_, let text, _) = try await ask(request) else { throw FlowError("not a result") }
            return text
        }
    }

    private struct FlowError: Error { let message: String; init(_ message: String) { self.message = message } }

    /// The tools are driven from this process, as the extension drives them from pi's: the server
    /// binds a registration to the agent's own pi process, so this process is allowed explicitly
    /// (`BrowserRelayTests` checks the real rule).
    private func harness() throws -> AppHarness {
        let app = try AppHarness()
        let own = getpid()
        app.server.browserPeerCheck = { _, peer in peer == own }
        return app
    }

    @Test func anAgentOpensAPageInItsOwnThreadAndNothingElseMoves() async throws {
        let app = try harness()
        defer { app.stop() }
        let web = try TinyWebServer(pages: BrowserAgentTests.pages)
        try await web.start()
        defer { web.stop() }
        let space = Fixture.space(path: app.dir.path)
        let mine = Fixture.agent("mine", in: space, order: 0)
        let other = Fixture.agent("other", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [mine, other]))
        vm.selectAgent(other.agent.id)
        let layouts = app.server.state.tabs.map(\.layout)

        let connection = try Connection(socketPath: app.scratch.socketPath, agent: mine.agent.id)
        let opened = try await connection.text(.open(url: web.url("/checkout").absoluteString, note: "opening the checkout"))
        #expect(opened.contains("Page: Checkout — \(web.origin)/checkout"))

        let page = try #require(vm.browsers.existing(mine.agent.id))
        #expect(page.pageURLString == web.origin + "/checkout")
        #expect(vm.browsers.existing(other.agent.id) == nil, "the other thread has no page")
        // Nothing opens by itself: the tab and the header's button take pi's dot.
        let owner = SidePaneOwner.local(mine.agent.id)
        #expect(!vm.subagentInspector.open.contains(owner) && vm.subagentInspector.news[owner] == [.browser])
        #expect(vm.sidePaneButton(for: owner).news == "Agent opened a page in Browser")
        #expect(vm.selectedAgentID == other.agent.id, "the user stays where they were")
        #expect(app.server.state.tabs.map(\.layout) == layouts, "the layout is untouched")
        let tip = SidePaneTabs.tip(opened: page.openedByAgent)
        #expect(tip?.text == "127.0.0.1:\(web.port)/checkout")
        page.close()
    }

    @Test func twoThreadsEachDriveTheirOwnPageAndNeitherReachesTheOther() async throws {
        let app = try harness()
        defer { app.stop() }
        let web = try TinyWebServer(pages: BrowserAgentTests.pages)
        try await web.start()
        defer { web.stop() }
        let space = Fixture.space(path: app.dir.path)
        let a = Fixture.agent("a", in: space, order: 0)
        let b = Fixture.agent("b", in: space, order: 1)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [a, b]))
        let first = try Connection(socketPath: app.scratch.socketPath, agent: a.agent.id)
        let second = try Connection(socketPath: app.scratch.socketPath, agent: b.agent.id)

        _ = try await first.text(.open(url: web.url("/checkout").absoluteString, note: nil))
        _ = try await second.text(.open(url: web.url("/checkout").absoluteString, note: nil))
        _ = try await first.text(.eval(expression: "document.cookie = 'cart=a; path=/'; localStorage.setItem('cart', 'from a'); 1", note: nil))
        let seenByB = try await second.text(.eval(expression: "[document.cookie, localStorage.getItem('cart')]", note: nil))
        #expect(seenByB.contains("Result: [\"\",null]"), "\(seenByB)")
        let seenByA = try await first.text(.eval(expression: "[document.cookie, localStorage.getItem('cart')]", note: nil))
        #expect(seenByA.contains("Result: [\"cart=a\",\"from a\"]"))

        // a's connection cannot name b's page, and b's clicks land on b's page alone.
        guard case .error(_, "not_registered", _) = try await first.ask(.read(selector: nil, maxChars: nil), as: b.agent.id) else {
            Issue.record("a reached b's page")
            return
        }
        let readB = try await second.text(.read(selector: nil, maxChars: nil))
        let apply = try #require(readB.split(separator: "\n").first { $0.contains("Apply promo") }
            .flatMap { line in line.range(of: "[e").map { String(line[$0.upperBound...].prefix { $0 != "]" }) } })
        _ = try await second.text(.click(ref: "e" + apply, double: false, note: nil))
        let counts = try await first.text(.eval(expression: "document.getElementById('count').textContent", note: nil))
        #expect(counts.contains("Result: \"0\""), "a's page did not hear b's click")
        let countB = try await second.text(.eval(expression: "document.getElementById('count').textContent", note: nil))
        #expect(countB.contains("Result: \"1\""))
        #expect(vm.browsers.existing(a.agent.id) !== vm.browsers.existing(b.agent.id))
        vm.browsers.existing(a.agent.id)?.close()
        vm.browsers.existing(b.agent.id)?.close()
    }

    @Test func aTakeOverRefusesTheAgentUntilTheUserMessagesTheThread() async throws {
        let app = try harness()
        defer { app.stop() }
        let web = try TinyWebServer(pages: BrowserAgentTests.pages)
        try await web.start()
        defer { web.stop() }
        let space = Fixture.space(path: app.dir.path)
        let live = try await app.liveAgent("live", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [live]))
        let ready = try await app.readyThread(live.agent.id)
        let connection = try Connection(socketPath: app.scratch.socketPath, agent: live.agent.id)
        let read = { try await connection.text(.open(url: web.url("/checkout").absoluteString, note: nil)) }
        _ = try await read()
        let page = try #require(vm.browsers.existing(live.agent.id))
        let snapshot = try await connection.text(.read(selector: nil, maxChars: nil))
        #expect(snapshot.contains("Apply promo"))

        // The card's Take over.
        vm.takeOverBrowser(page)
        guard case .error(_, "taken_over", let message) = try await connection.ask(.eval(expression: "1", note: nil)) else {
            Issue.record("the agent was not refused")
            return
        }
        #expect(message == BrowserAgentPresence.takenOverMessage)
        _ = try await connection.text(.read(selector: nil, maxChars: nil))

        // A peer's message does not give it back; the user's message to the thread does.
        #expect(app.server.pushMessage(toAgent: live.agent.id, text: "[from: worker] hi", delivery: .report) == false, "no panes connection here")
        #expect(page.userHasControl)
        let operation = UUID()
        let result = try await app.server.nativeThread(agentID: live.agent.id, request: .send(
            expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: operation, text: "hello", delivery: .followUp))
        #expect(result == .accepted(operationID: operation))
        try await eventuallyOnMain("control to come back") { !page.userHasControl }
        #expect(try await connection.text(.eval(expression: "1 + 1", note: nil)).contains("Result: 2"))
        page.close()
    }
}
