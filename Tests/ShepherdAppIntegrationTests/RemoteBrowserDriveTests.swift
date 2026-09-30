import AppKit
import Foundation
import ImageIO
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import Testing
import WebKit
@testable import ShepherdApp

/// An agent on another Mac drives the page the viewer sees (docs/browser.md › Remote › The agent
/// drives the page you see), end to end: the agent's extension on a host, its server, the remote
/// connection, and a real off-screen web view on the viewer that loads the host's dev server through
/// the tunnel. The host is a second in-process Shepherd on this very Mac, so a port the page names
/// here reaches the dev server's different one (`BrowserRemote.hostPorts`).
@Suite("Remote browser drive", .mainActorExclusive)
@MainActor
struct RemoteBrowserDriveTests {
    /// A viewer and a host with one thread, connected as "build-01", and a dev server on the host.
    @MainActor struct Setup {
        let local: AppHarness
        let remote: RemoteHostHarness
        let vm: ShepherdViewModel
        let connection: RemoteHostStore.Connection
        let ref: RemoteAgentRef
        let agent: AgentFixture
        let web: TinyWebServer
        /// The viewer-side port the page names, which the forwarder carries to `web`.
        let port: UInt16

        var session: BrowserSession { vm.browsers.session(for: ref, hosts: local.remoteHosts) }
        var hostVM: ShepherdViewModel { remote.host.vm }

        func url(_ path: String) -> String { "http://localhost:\(port)\(path)" }

        func stop() {
            web.stop()
            local.stop()
            remote.stop()
        }

        /// The Browser tab comes on screen and the claim is answered.
        func showTab(_ session: BrowserSession? = nil) async throws {
            let session = session ?? self.session
            vm.browserPaneAppeared(session)
            try await eventuallyOnMain("the viewer to own the agent's browser") { session.remote?.claimant.phase == .owned }
            try await eventuallyOnMain("the host to record the owner") { remote.host.server.browserOwnerFD(of: agent.agent.id) != nil }
        }

        /// The agent's extension on the host.
        func extensionConnection() throws -> AgentConnection {
            try AgentConnection(socketPath: remote.host.scratch.socketPath, agent: agent.agent.id)
        }
    }

    /// A raw browser connection of the agent, as its extension keeps.
    final class AgentConnection: @unchecked Sendable {
        let client: ExtensionClient
        let agentID: AgentID
        private var next = 0

        init(socketPath: String, agent: AgentID) throws {
            client = try ExtensionClient(path: socketPath)
            agentID = agent
            try client.send(.helloBrowser(agentID: agent))
        }

        func ask(_ request: BrowserRequest) async throws -> ExtensionReply {
            next += 1
            try client.send(.browser(id: next, agentID: agentID, request: request))
            let client = client
            return try await Task.detached { try client.readReply(timeout: .seconds(60)) }.value
        }

        func text(_ request: BrowserRequest) async throws -> String {
            guard case .browserResult(_, let text, _) = try await ask(request) else { throw DriveError("not a result") }
            return text
        }

        func failure(_ request: BrowserRequest) async throws -> (code: String, message: String) {
            guard case .error(_, let code, let message) = try await ask(request) else { throw DriveError("not a failure") }
            return (code, message)
        }
    }

    struct DriveError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func setup(pages: [String: String] = BrowserAgentTests.pages, live: Bool = false, grace: TimeInterval? = nil,
                       policy: BrowserViewerPolicy? = nil, capabilities: [String]? = nil) async throws -> Setup {
        try await Self.makeSetup(pages: pages, handler: nil, live: live, grace: grace, policy: policy, capabilities: capabilities)
    }

    /// A viewer and a host, connected, with a dev server on the host that serves `pages` or, when given, `handler`.
    static func makeSetup(pages: [String: String] = BrowserAgentTests.pages, handler: TinyWebServer.Handler?, live: Bool = false,
                          grace: TimeInterval? = nil, policy: BrowserViewerPolicy? = nil, capabilities: [String]? = nil) async throws -> Setup {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        if let capabilities { remote.host.server.advertisedCapabilities = capabilities }
        let space = Fixture.space(path: local.dir.path)
        let agent = live ? try await remote.host.liveAgent("web", in: space) : Fixture.agent("web", in: space)
        let vm = try await local.start(with: Fixture.state(spaces: [space], agents: []))
        if let grace { vm.browsers.driveGrace = grace }
        if let policy { vm.browsers.viewerPolicy = policy }
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let web = try handler.map { try TinyWebServer($0) } ?? TinyWebServer(pages: pages)
        try await web.start()
        let port = try unusedPort()
        let s = Setup(local: local, remote: remote, vm: vm, connection: connection, ref: ref, agent: agent, web: web, port: port)
        s.session.remote?.hostPorts[Int(port)] = Int(web.port)
        return s
    }

    static func unusedPort() throws -> UInt16 {
        let server = try LoopbackServer { close($0) }
        let port = server.port
        server.stop()
        return port
    }

    private func pageText(_ session: BrowserSession, _ script: String) async throws -> String {
        let view = try #require(session.webView)
        return try await view.callAsyncJavaScript("return String(\(script))", arguments: [:], in: nil, contentWorld: .page) as? String ?? ""
    }

    /// The ref of the first snapshot line containing `needle`.
    private func ref(in snapshot: String, _ needle: String) throws -> String {
        let line = try #require(snapshot.split(separator: "\n").first { $0.contains(needle) && $0.contains("[e") }, "no ref line for \(needle)")
        let start = try #require(line.range(of: "[e"))
        let end = try #require(line[start.upperBound...].firstIndex(of: "]"))
        return String(line[line.index(after: start.lowerBound)..<end])
    }

    // MARK: The agent drives the viewer's page

    @Test func theAgentsToolsRunOnTheViewersPageThroughTheTunnelAndTheHostsOwnPageStaysEmpty() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        try await s.showTab()
        let agent = try s.extensionConnection()

        let opened = try await agent.text(.open(url: s.url("/checkout"), note: "opening the checkout"))
        #expect(opened.contains("Page: Checkout — \(s.url("/checkout"))") && opened.contains("Opened \(s.url("/checkout"))."))
        #expect(session.url?.absoluteString == s.url("/checkout"), "the viewer's own page is the one that moved")
        #expect(s.web.requested.current.contains("/checkout"), "and it loaded through the tunnel from the host's dev server")
        #expect(s.hostVM.browsers.existing(s.agent.agent.id) == nil, "the host's own page was never made")
        // The ring and card show on the viewer's pane while the agent works, with its own words.
        #expect(session.agentOverlay?.note == "opening the checkout")

        let snapshot = try await agent.text(.read(selector: nil, maxChars: nil))
        #expect(snapshot.contains("- heading \"Checkout\" [level=1]") && snapshot.contains("button \"Pay $148.00\""))
        let email = try ref(in: snapshot, "textbox \"Email\""), apply = try ref(in: snapshot, "button \"Apply promo\"")

        let typed = try await agent.text(.type(ref: email, text: "baily@acme.dev", clear: true, submit: false, note: nil))
        #expect(typed.contains("Typed 14 characters"))
        #expect(try await pageText(session, "document.getElementById('echo').textContent") == "typed: baily@acme.dev")
        #expect(session.agentOverlay?.note == "typing in “Email”")

        let clicked = try await agent.text(.click(ref: apply, double: false, note: nil))
        #expect(clicked.contains("Clicked button \"Apply promo\""))
        #expect(try await pageText(session, "document.getElementById('count').textContent") == "1")
        #expect(session.agentOverlay?.note == "clicking “Apply promo”")
        #expect(session.agentOverlay?.pointer != nil, "the pointer is where the click landed")

        let console = try await agent.text(.console(clear: false))
        #expect(console.contains("promo applied"))
        #expect(s.hostVM.browsers.existing(s.agent.agent.id) == nil)
    }

    @Test func aScreenshotOfTheViewersPageComesBackDecodedAndWithinTheCaps() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))
        guard case .browserResult(_, let text, let image?) = try await agent.ask(.screenshot(ref: nil)) else { Issue.record("no screenshot"); return }
        #expect(text.contains("Screenshot of the visible page"))
        #expect(image.mimeType == "image/jpeg" && image.data.utf8.count <= BrowserOutcome.maxImageBase64Bytes)
        let bytes = try #require(Data(base64Encoded: image.data))
        #expect(bytes.count <= BrowserImageClamp.maxBytes)
        let source = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let picture = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(picture.width, picture.height) <= BrowserImageClamp.maxEdge && picture.width > 1 && picture.height > 1)
    }

    @Test func aClickThatNavigatesAndABackStepWorkOnTheViewersPage() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))
        let snapshot = try await agent.text(.read(selector: nil, maxChars: nil))
        let terms = try ref(in: snapshot, "link \"Terms of sale\"")
        let clicked = try await agent.text(.click(ref: terms, double: false, note: nil))
        #expect(clicked.contains("The page navigated.") && clicked.contains("Page: Terms — \(s.url("/terms"))"))
        let back = try await agent.text(.back(note: nil))
        #expect(back.contains("Went back to \(s.url("/checkout"))"))
    }

    @Test func withNoClaimTheHostsOwnPageAnswersAndTheViewersTabGetsTheDot() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        let agent = try s.extensionConnection()
        let hostPage = s.web.url("/checkout").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        let opened = try await agent.text(.open(url: hostPage, note: nil))
        #expect(opened.contains("Page: Checkout"), "the host's own page loaded it, as before")
        let hostSession = try #require(s.hostVM.browsers.existing(s.agent.agent.id))
        #expect(hostSession.hasPage && !session.hasPage, "the viewer's tab is a page of its own")

        // The thread's viewers mark the Browser tab, never opening the pane by itself.
        let owner = SidePaneOwner.remote(s.ref)
        try await eventuallyOnMain("the dot on the viewer's Browser tab") { s.vm.subagentInspector.news[owner] == [.browser] }
        #expect(!s.vm.subagentInspector.open.contains(owner), "nothing opens by itself")
        #expect(session.openedByAgent?.url.absoluteString == hostPage)
        #expect(SidePaneTabs.tip(opened: session.openedByAgent)?.text == BrowserAddress.display(URL(string: hostPage))?.host.appending("/checkout"))
        #expect(s.vm.sidePaneButton(for: owner).news == "Agent opened a page in Browser")
    }

    @Test func aViewerThatHasTheTabOnScreenIsNotMarkedForWhatItAlreadySees() async throws {
        let s = try await setup()
        defer { s.stop() }
        let owner = SidePaneOwner.remote(s.ref)
        s.vm.subagentInspector.open.insert(owner)
        s.vm.subagentInspector.tabs[owner] = .browser
        s.vm.selectRemoteAgent(hostID: s.ref.hostID, agentID: s.ref.agentID)
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.web.url("/checkout").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"), note: nil))
        try await eventuallyOnMain("the tip to be kept") { s.session.openedByAgent != nil }
        #expect(s.vm.subagentInspector.news[owner] == nil, "the tab on screen needs no dot")
    }

    // MARK: Adopting the host's page

    @Test func aViewerThatClaimsWithNothingOpenOpensThePageTheAgentLeftOnTheHost() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        // The host's own page is at the address the viewer can reach through its forwarded port.
        s.remote.host.server.onBrowserPageURL = { [port = s.port] _ in "http://localhost:\(port)/checkout" }
        #expect(!session.hasPage)
        try await s.showTab()
        try await eventuallyOnMain("the host's page to open here") { session.webView?.title == "Checkout" }
        #expect(session.url?.absoluteString == s.url("/checkout"))
        #expect(s.web.requested.current.contains("/checkout"), "loaded from the host's dev server through the tunnel")
    }

    @Test func aPageTheViewerAlreadyHasIsNotReplacedByTheHostsAndAnAddressOffTheWebIsNotAdopted() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        session.load(URL(string: s.url("/terms"))!)
        try await eventuallyOnMain("the viewer's own page") { session.webView?.title == "Terms" }
        s.remote.host.server.onBrowserPageURL = { [port = s.port] _ in "http://localhost:\(port)/checkout" }
        try await s.showTab()
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.url?.absoluteString == s.url("/terms"), "a claim replaces nothing the user opened")

        let other = try await setup()
        defer { other.stop() }
        other.remote.host.server.onBrowserPageURL = { _ in "http://192.168.1.50:8080/admin" }
        try await other.showTab()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!other.session.hasPage && other.session.webView == nil, "an address on the viewer's network is not adopted")
    }

    // MARK: Take over

    @Test func takingOverOnTheViewerRefusesTheActingToolsAndTheUsersNextMessageHandsTheBack() async throws {
        let s = try await setup(live: true)
        defer { s.stop() }
        let session = s.session
        try await s.showTab()
        let agent = try s.extensionConnection()
        let snapshot0 = try await agent.text(.open(url: s.url("/checkout"), note: nil)) + (try await agent.text(.read(selector: nil, maxChars: nil)))
        let apply = try ref(in: snapshot0, "button \"Apply promo\"")

        s.vm.takeOverBrowser(session)
        #expect(session.userHasControl && session.agentOverlay == nil)
        let refused = try await agent.failure(.click(ref: apply, double: false, note: nil))
        #expect(refused.code == "taken_over" && refused.message == BrowserAgentPresence.takenOverMessage)
        #expect(try await agent.failure(.open(url: s.url("/terms"), note: nil)).code == "taken_over")
        #expect(try await pageText(session, "document.getElementById('count').textContent") == "0", "the page was not touched")
        // Observation still works, and shows no card.
        #expect(try await agent.text(.read(selector: nil, maxChars: nil)).contains("Apply promo"))
        #expect(session.agentOverlay == nil)

        // The user's message to the thread, from this Mac's own composer, gives the page back.
        _ = try await s.remote.host.readyThread(s.agent.agent.id)
        try await s.local.remoteHosts.sendUserMessage(s.ref, text: "tools:0 carry on")
        try await eventuallyOnMain("the page to be handed back") { !session.userHasControl }
        let clicked = try await agent.text(.click(ref: apply, double: false, note: nil))
        #expect(clicked.contains("Clicked button \"Apply promo\""))
    }

    @Test func aClickInTheViewersPageWhileTheCardIsUpTakesItOver() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))
        #expect(session.agentOverlay != nil)
        session.handle(.userInput)
        #expect(session.userHasControl, "the user's own input, reported by the page as a trusted event, takes the page over")
        #expect(try await agent.failure(.reload(note: nil)).code == "taken_over")
    }

    // MARK: Ownership

    @Test func theMostRecentViewerToClaimDrivesAndTheOtherIsToldAndCanTakeItBack() async throws {
        let s = try await setup()
        defer { s.stop() }
        let second = try AppHarness()
        defer { second.stop() }
        let vm2 = try await second.start(with: Fixture.state(spaces: [Fixture.space(path: second.dir.path)], agents: []))
        let connection2 = try await s.remote.connect(second.remoteHosts, name: "build-01")
        let ref2 = RemoteAgentRef(hostID: connection2.id, agentID: s.agent.agent.id)
        let session2 = vm2.browsers.session(for: ref2, hosts: second.remoteHosts)
        let port2 = try Self.unusedPort()
        session2.remote?.hostPorts[Int(port2)] = Int(s.web.port)

        let first = s.session
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/terms"), note: nil))
        #expect(first.url?.absoluteString == s.url("/terms"))

        vm2.browserPaneAppeared(session2)
        try await eventuallyOnMain("the second viewer to own it") { session2.remote?.claimant.phase == .owned }
        try await eventuallyOnMain("the first viewer to be told") { first.remote?.claimant.phase == .superseded }
        #expect(first.notice?.message == BrowserRemote.supersededMessage)

        _ = try await agent.text(.open(url: "http://localhost:\(port2)/checkout", note: nil))
        #expect(session2.url?.absoluteString == "http://localhost:\(port2)/checkout", "the winner drives")
        #expect(first.url?.absoluteString == s.url("/terms"), "the loser's page stayed where it was")

        // Showing the first tab again takes it back: the second is told.
        vm2.browserPaneDisappeared(session2)
        s.vm.browserPaneDisappeared(first)
        s.vm.browserPaneAppeared(first)
        try await eventuallyOnMain("the first to own it again") { first.remote?.claimant.phase == .owned }
        try await eventuallyOnMain("the second to be told") { session2.remote?.claimant.phase == .superseded }
        #expect(first.notice == nil, "the notice goes with the claim")
    }

    @Test func aViewerThatLeavesMidRequestEndsItAndTheNextCallReachesTheHostsPage() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))

        let waiting = Task { try await agent.ask(.wait(text: "never appears", ref: nil, gone: false, ms: nil, timeout: 20)) }
        try await eventuallyOnMain("the wait to start on the viewer") { s.session.agentOverlay?.note.hasPrefix("waiting for") == true }
        s.local.remoteHosts.removeHost(id: s.connection.id)
        guard case .error(_, "viewer_gone", _) = try await waiting.value else { Issue.record("the request was not ended with viewer_gone"); return }

        try await eventuallyOnMain("the host to drop the dead viewer's claim") { s.remote.host.server.browserOwnerFD(of: s.agent.agent.id) == nil }
        let hostPage = s.web.url("/terms").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        #expect(try await agent.text(.open(url: hostPage, note: nil)).contains("Page: Terms"), "later calls fall back to the host's own page")
        #expect(s.hostVM.browsers.existing(s.agent.agent.id)?.hasPage == true)
    }

    @Test func aTabThatStaysOutOfSightLetsTheAgentsBrowserGoBackToTheHostAndComesBackClaimingAgain() async throws {
        let s = try await setup(grace: 0.4)
        defer { s.stop() }
        let session = s.session
        try await s.showTab()
        s.vm.browserPaneDisappeared(session)
        // A quick look at another tab keeps the claim.
        try await Task.sleep(for: .milliseconds(150))
        s.vm.browserPaneAppeared(session)
        try await Task.sleep(for: .milliseconds(600))
        #expect(session.remote?.claimant.phase == .owned && s.remote.host.server.browserOwnerFD(of: s.agent.agent.id) != nil)

        s.vm.browserPaneDisappeared(session)
        try await eventuallyOnMain("the host to have its browser back") { s.remote.host.server.browserOwnerFD(of: s.agent.agent.id) == nil }
        #expect(session.remote?.claimant.phase == .idle)
        let agent = try s.extensionConnection()
        let hostPage = s.web.url("/terms").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        #expect(try await agent.text(.open(url: hostPage, note: nil)).contains("Page: Terms"), "the host's own page answers")

        s.vm.browserPaneAppeared(session)
        try await eventuallyOnMain("the tab to claim again") { session.remote?.claimant.phase == .owned }
    }

    @Test func aReconnectWhileTheTabIsOnScreenClaimsAgainOnTheNewConnection() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        try await s.showTab()
        s.local.remoteHosts.reconnect(id: s.connection.id)
        try await eventuallyOnMain("the claim to drop with the connection", timeout: .seconds(30)) { session.remote?.claimant.phase != .owned }
        try await eventuallyOnMain("the tab to claim again on the new connection", timeout: .seconds(30)) {
            session.remote?.claimant.phase == .owned && s.connection.phase == .connected
        }
        try await eventuallyOnMain("the host to record the new owner") { s.remote.host.server.browserOwnerFD(of: s.agent.agent.id) != nil }
        let agent = try s.extensionConnection()
        #expect(try await agent.text(.open(url: s.url("/terms"), note: nil)).contains("Page: Terms"))
        #expect(session.url?.absoluteString == s.url("/terms"))
    }

    @Test func aThreadThatIsDeletedOnTheHostEndsTheViewersClaim() async throws {
        let s = try await setup()
        defer { s.stop() }
        let session = s.session
        try await s.showTab()
        try await s.local.remoteHosts.agentAction(s.ref, action: .deleteKeepingWorktree)
        try await eventuallyOnMain("the page to go with the thread") { s.vm.browsers.existing(s.ref) == nil }
        #expect(s.remote.host.server.browserOwnerFD(of: s.agent.agent.id) == nil)
        _ = session
    }

    // MARK: Older peers

    @Test func anOlderHostLeavesTheViewersTabAPageOfItsOwnAsBefore() async throws {
        let s = try await setup(capabilities: RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.browserDriveCapability })
        defer { s.stop() }
        let session = s.session
        #expect(s.connection.supportsBrowser, "the tab is there: the tunnel is")
        #expect(session.remote?.driveClient == nil)
        s.vm.browserPaneAppeared(session)
        try await Task.sleep(for: .milliseconds(300))
        #expect(session.remote?.claimant.phase == .idle && s.remote.host.server.browserOwnerFD(of: s.agent.agent.id) == nil, "nothing was claimed")

        // The agent drives the host's own page, and no dot reaches the viewer.
        let agent = try s.extensionConnection()
        let hostPage = s.web.url("/terms").absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        #expect(try await agent.text(.open(url: hostPage, note: nil)).contains("Page: Terms"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.hasPage && session.openedByAgent == nil)
    }
}
