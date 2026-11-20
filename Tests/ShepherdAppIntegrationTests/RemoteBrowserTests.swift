import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import Testing
import WebKit
@testable import ShepherdApp

/// A remote thread's Browser: the page renders in this Mac's own web view
/// and reaches the host's dev server through a forwarded port and a tunnel over the real remote
/// connection. The host here is a second in-process Shepherd, and its dev server a local server; both
/// are this very Mac, so the port the page names on this side reaches the dev server's different one
/// (`BrowserRemote.hostPorts`).
@Suite("Remote browser", .mainActorExclusive)
@MainActor
struct RemoteBrowserTests {
    /// A viewer and a host with one thread, connected as "build-01".
    @MainActor private struct Setup {
        let local: AppHarness
        let remote: RemoteHostHarness
        let vm: ShepherdViewModel
        let connection: RemoteHostStore.Connection
        let ref: RemoteAgentRef

        func session(_ ref: RemoteAgentRef? = nil) -> BrowserSession {
            vm.browsers.session(for: ref ?? self.ref, hosts: local.remoteHosts)
        }

        func stop() {
            local.stop()
            remote.stop()
        }
    }

    private func setup(threads: Int = 1, capabilities: [String]? = nil) async throws -> (Setup, [RemoteAgentRef]) {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        if let capabilities { remote.host.server.advertisedCapabilities = capabilities }
        let space = Fixture.space(path: local.dir.path)
        let agents = (0..<threads).map { Fixture.agent("web\($0)", in: space, order: $0) }
        let vm = try await local.start(with: Fixture.state(spaces: [space], agents: []))
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: agents))
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        let refs = agents.map { RemoteAgentRef(hostID: connection.id, agentID: $0.agent.id) }
        return (Setup(local: local, remote: remote, vm: vm, connection: connection, ref: refs[0]), refs)
    }

    /// The page's text.
    private func text(_ session: BrowserSession) async throws -> String {
        let view = try #require(session.webView)
        return try await view.callAsyncJavaScript("return document.body ? document.body.innerText : ''", arguments: [:], in: nil,
                                                  contentWorld: .page) as? String ?? ""
    }

    private func url(_ port: UInt16, _ path: String) throws -> URL {
        try #require(URL(string: "http://localhost:\(port)\(path)"))
    }

    /// A viewer port to forward, mapped to the dev server's port on the "host".
    private func map(_ session: BrowserSession, to hostPort: UInt16) throws -> UInt16 {
        let viewerPort = try unusedPort()
        session.remote?.hostPorts[Int(viewerPort)] = Int(hostPort)
        return viewerPort
    }

    private func unusedPort() throws -> UInt16 {
        let server = try LoopbackServer { _ in }
        let port = server.port
        server.stop()
        return port
    }

    // MARK: The page

    @Test func aRemotePageLoadsThroughTheTunnelAndFetchesASubresourceWithItsUrlUnchanged() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let session = s.session()
        let port = try map(session, to: dev.port)

        #expect(session.hostChip == "build-01", "nothing open: a port typed here is on the host")
        session.load(try url(port, "/page"))
        try await eventuallyOnMain("the page and its script to load through the tunnel") {
            session.webView?.title == "asset loaded"
        }
        #expect(session.url?.absoluteString == "http://localhost:\(port)/page", "the URL stays what the page named")
        #expect(session.hostChip == "build-01")
        #expect(dev.requests.current.contains("GET /page HTTP/1.1") && dev.requests.current.contains("GET /asset.js HTTP/1.1"))
        #expect(session.notice == nil)
        #expect(s.vm.browsers.ports.ports(of: try #require(session.remote).owner) == [Int(port)])
    }

    @Test func aRemotePageOnTheWebLoadsFromThisMacAndTheChipSaysSo() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let session = s.session()
        #expect(session.remote?.chip(for: URL(string: "https://example.com/")) == "This Mac")
        #expect(session.remote?.chip(for: URL(string: "http://localhost:5173/x")) == "build-01")
        #expect(session.remote?.chip(for: URL(string: "http://127.0.0.1:3000")) == "build-01")
        #expect(session.remote?.chip(for: URL(string: "about:blank")) == "build-01")
        #expect(session.remote?.chip(for: nil) == "build-01")
        #expect(session.remote?.forward(try #require(URL(string: "https://example.com/")), tab: session.tabID) == nil, "nothing to forward for the web")
        #expect(s.vm.browsers.ports.ports(of: try #require(session.remote).owner).isEmpty)
    }

    /// Pages remain separate, but threads in the same remote project reuse its login.
    @Test func twoRemoteProjectPagesShareCookies() async throws {
        let (s, refs) = try await setup(threads: 2)
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let a = s.session(refs[0]), b = s.session(refs[1])
        let portA = try map(a, to: dev.port), portB = try map(b, to: dev.port)

        a.load(try url(portA, "/cookie?set=from-a"))
        try await eventuallyAsync("its first body") { (try? await Self.bodyText(a)) == "none" }
        a.load(try url(portA, "/cookie"))
        try await eventuallyAsync("its cookie to come back") { (try? await Self.bodyText(a)) == "sid=from-a" }

        b.load(try url(portB, "/cookie"))
        try await eventuallyAsync("the shared cookie to reach the second page") { (try? await Self.bodyText(b)) == "sid=from-a" }
        #expect(try await text(b) == "sid=from-a")
        #expect(a.webView !== b.webView)
        #expect(a.webView?.configuration.websiteDataStore === b.webView?.configuration.websiteDataStore)
        let projectID = try #require(s.connection.state.agents.first { $0.id == refs[0].agentID }).spaceID
        #expect(await s.vm.browsers.cookieSites(projectID: projectID, hostID: s.connection.id)
            == [BrowserCookieSite(site: "localhost", count: 1)])
        #expect(await s.vm.browsers.cookieSites(projectID: projectID).isEmpty, "the local namespace stays separate")
        #expect(await s.vm.browsers.cookieSites(projectID: projectID,
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!).isEmpty, "another remote host stays separate")
        await s.vm.browsers.clearCookies(projectID: projectID, site: "localhost")
        #expect(await s.vm.browsers.cookieSites(projectID: projectID, hostID: s.connection.id)
            == [BrowserCookieSite(site: "localhost", count: 1)])
        await s.vm.browsers.clearCookies(projectID: projectID, hostID: s.connection.id)
        b.load(try url(portB, "/cookie"))
        try await eventuallyAsync("clearing remote cookies reaches the thread page") { (try? await Self.bodyText(b)) == "none" }
    }

    @Test func aRemoteThreadHasItsOwnStoreApartFromEveryLocalOne() throws {
        let host = UUID(), other = UUID()
        let agent = AgentID(rawValue: "same")
        let remote = BrowserDataStores.identifier(forRemote: RemoteAgentRef(hostID: host, agentID: agent))
        #expect(remote == BrowserDataStores.identifier(forRemote: RemoteAgentRef(hostID: host, agentID: agent)), "stable")
        #expect(remote != BrowserDataStores.identifier(for: agent), "never a local thread's, though its id may match")
        #expect(remote != BrowserDataStores.identifier(forRemote: RemoteAgentRef(hostID: other, agentID: agent)), "nor another host's")
    }

    // MARK: Ports

    @Test func aPortAnotherProgramOnThisMacUsesIsRefusedAndNothingLoads() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let mine = try DevServerFixture()
        defer { mine.stop() }
        let session = s.session()
        session.load(try url(mine.port, "/page"))

        let message = try #require(session.notice?.message)
        #expect(message == "Port \(mine.port) is in use on this Mac, so build-01’s \(mine.port) can’t be forwarded. Stop what is using it and try again.")
        #expect(!session.hasPage && session.webView == nil, "nothing loads, or it would show this Mac's own server as the host's")
        #expect(mine.requests.current.isEmpty, "and this Mac's server was never asked")
        session.dismissNotice()
        #expect(session.notice == nil)
    }

    @Test func aPortAnotherThreadsPageHoldsIsRefusedToTheSecond() async throws {
        let (s, refs) = try await setup(threads: 2)
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let a = s.session(refs[0]), b = s.session(refs[1])
        let port = try map(a, to: dev.port)
        b.remote?.hostPorts[Int(port)] = Int(dev.port)

        a.load(try url(port, "/hello"))
        #expect(a.notice == nil)
        b.load(try url(port, "/hello"))
        #expect(b.notice?.message == "Port \(port) is already forwarded from build-01, for another thread’s page.")
        #expect(!b.hasPage)
        // Once the first thread's page is gone, the port is the second's.
        s.vm.browsers.prune(liveRemote: [refs[1]], hosts: s.local.remoteHosts)
        b.load(try url(port, "/hello"))
        #expect(b.notice == nil && b.hasPage)
    }

    /// A page's link to another port of its host's loopback forwards that port first; one that
    /// can't be does not go, rather than reach this Mac's own port.
    @Test func aLinkToAnotherPortOfTheHostIsForwardedOrRefused() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let other = try DevServerFixture()
        defer { other.stop() }
        let session = s.session()
        let port = try map(session, to: dev.port)
        session.load(try url(port, "/page"))
        try await eventuallyOnMain("the page") { session.webView?.title == "asset loaded" }

        // This Mac's own server on `other.port`: the page must not be taken there.
        let view = try #require(session.webView)
        _ = try? await view.callAsyncJavaScript("location.href = u", arguments: ["u": "http://localhost:\(other.port)/hello"], in: nil,
                                                contentWorld: .page)
        try await eventuallyOnMain("the navigation to be refused") { session.notice != nil }
        #expect(session.notice?.message.contains("in use on this Mac") == true)
        #expect(other.requests.current.isEmpty)
        #expect(session.url?.port == Int(port), "the page stayed where it was")
    }

    // MARK: Dev servers and Start

    @Test func startOnTheHostRunsItsCommandThereAndOpensThePageOnceItAnswers() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let ran = Locked<[RemoteAgentAction]>([])
        let hostPort = try unusedPort()
        let dev = Locked<DevServerFixture?>(nil)
        defer { dev.current?.stop() }
        s.remote.host.server.onRemoteAgentAction = { _, action, done in
            ran.withValue { $0.append(action) }
            done(.success(()))
            // The dev server takes a moment to come up after its command runs.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { dev.withValue { $0 = try? DevServerFixture(port: hostPort) } }
        }
        let session = s.session()
        let viewerPort = try unusedPort()
        session.remote?.hostPorts[Int(viewerPort)] = Int(hostPort)
        let server = DevServer(script: "dev", command: "pnpm dev", packageName: "acme-web", directory: "/host/acme-web",
                               manifest: "package.json", port: Int(viewerPort))
        #expect(session.startTitle == "Start on build-01")
        #expect(server.item(startTitle: session.startTitle).startTitle == "Start on build-01")

        s.vm.startDevServer(server, in: session)
        try await eventuallyOnMain("the host to be asked to run the command") { ran.current.count == 1 }
        #expect(ran.current == [.openTerminal(cwd: "/host/acme-web", command: "pnpm dev")])
        try await eventuallyOnMain("the waiting line") { session.waitingFor != nil || session.hasPage }
        try await eventuallyOnMain("the page to open once the port answers", timeout: .seconds(60)) {
            session.hasPage && session.url?.host == "localhost" && session.url?.port == Int(viewerPort)
        }
        #expect(session.waitingFor == nil)
    }

    @Test func theHostsDevServersComeFromItsThreadsFolder() async throws {
        let folder = try makeScratchDirectory("remote-web")
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"name":"acme-web","scripts":{"dev":"vite"}}"#.utf8).write(to: folder.appendingPathComponent("package.json"))
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: folder.path)
        let agent = Fixture.agent("web", in: space, order: 0)
        let vm = try await local.start(with: Fixture.state(spaces: [space], agents: []))
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts, name: "build-01")
        let session = vm.browsers.session(for: RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id), hosts: local.remoteHosts)

        vm.loadDevServers(session)
        try await eventuallyOnMain("the host's dev servers") { session.devServers != nil }
        #expect(session.devServers?.map(\.command) == ["npm run dev"])
        #expect(session.devServers?.first?.port == 5173)
        #expect(session.devServers?.first?.detail == "from package.json · acme-web")
    }

    // MARK: Tabs and cleanup

    @Test func aRemoteThreadOnAHostThatCarriesTunnelsHasTheBrowserTabAndAnOlderHostDoesNot() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        #expect(s.connection.supportsBrowser)
        #expect(s.vm.sidePaneTabs(for: .remote(s.ref)) == [.changes, .browser, .files])
        s.vm.showSidePane(.remote(s.ref), tab: .browser)
        #expect(s.vm.subagentInspector.open.contains(.remote(s.ref)) && s.vm.subagentInspector.tab(for: .remote(s.ref)) == .browser)

        let (old, _) = try await setup(capabilities: RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.browserTunnelCapability })
        defer { old.stop() }
        #expect(!old.connection.supportsBrowser)
        #expect(old.vm.sidePaneTabs(for: .remote(old.ref)) == [.changes, .files], "no Browser tab, as before")
        old.vm.showSidePane(.remote(old.ref), tab: .browser)
        #expect(!old.vm.subagentInspector.open.contains(.remote(old.ref)), "⌃2 does nothing there")
        #expect(old.vm.sidePaneTabs(for: .local(AgentID())) == [.changes, .browser, .files])
    }

    /// Each page holds a port and has its web view (made, not loaded: what this checks is what goes
    /// with a thread, not a page in flight).
    @Test func removingAThreadOrItsHostTakesItsPageAndItsPortsWithIt() async throws {
        let (s, refs) = try await setup(threads: 2)
        defer { s.stop() }
        let a = s.session(refs[0]), b = s.session(refs[1])
        let portA = try unusedPort(), portB = try unusedPort()
        #expect(a.remote?.forward(try url(portA, "/hello"), tab: a.tabID) == nil)
        #expect(b.remote?.forward(try url(portB, "/hello"), tab: b.tabID) == nil)
        a.prepareWebView()
        b.prepareWebView()
        let ownerA = try #require(a.remote).owner, ownerB = try #require(b.remote).owner
        #expect(s.vm.browsers.ports.ports(of: ownerA) == [Int(portA)])

        // The host deletes the first thread: its page goes, and the second's stays.
        try await s.local.remoteHosts.agentAction(refs[0], action: .deleteKeepingWorktree)
        try await eventuallyOnMain("the first page to go") { s.vm.browsers.existing(refs[0]) == nil }
        #expect(s.vm.browsers.existing(refs[1]) === b)
        #expect(s.vm.browsers.ports.ports(of: ownerA).isEmpty && s.vm.browsers.ports.ports(of: ownerB) == [Int(portB)])

        // The host is removed here: the rest goes.
        s.local.remoteHosts.removeHost(id: s.connection.id)
        try await eventuallyOnMain("the second page to go") { s.vm.browsers.existing(refs[1]) == nil }
        #expect(s.vm.browsers.ports.ports(of: ownerB).isEmpty)
    }

    /// The pane's own draw of a remote page through `BrowserPane`'s state: the notice is what the
    /// session holds, shown until the next load.
    @Test func aRefusedPortClearsWithTheNextSuccessfulLoad() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let mine = try DevServerFixture()
        defer { mine.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let session = s.session()
        session.load(try url(mine.port, "/"))
        #expect(session.notice != nil)
        let port = try map(session, to: dev.port)
        session.load(try url(port, "/hello"))
        #expect(session.notice == nil)
        try await eventuallyAsync("the page") { (try? await Self.bodyText(session)) == "hello from the host" }
    }

    // MARK: A closed tab's ports

    /// A plain TCP connection to this Mac's loopback at `port`; -1 when it is refused.
    private func connectLoopback(_ port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if status != 0 { close(fd); return -1 }
        return fd
    }

    /// Whether `fd`'s peer closed it: a read that ends (0 bytes, or a reset) and does not time out.
    private func peerClosed(_ fd: Int32) async -> Bool {
        await Task.detached {
            var byte: UInt8 = 0
            while true {
                let n = read(fd, &byte, 1)
                if n < 0, errno == EINTR { continue }
                return n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
            }
        }.value
    }

    /// The tab forwards `viewerPort`.
    private func hold(_ page: BrowserSession, _ viewerPort: UInt16) throws {
        #expect(page.remote?.forward(try url(viewerPort, "/"), tab: page.tabID) == nil)
    }

    /// A live bridge through `port`: an unfinished request keeps it open, and its tunnel is up once the hub counts it.
    private func bridge(_ port: UInt16, in s: Setup) async throws -> Int32 {
        let fd = connectLoopback(port)
        #expect(fd >= 0)
        _ = "GET /hello HTTP/1.1\r\n".withCString { write(fd, $0, strlen($0)) }
        try await eventuallyAsync("the connection to be bridged") { s.connection.hubSlot.hub?.openCount == 1 }
        return fd
    }

    @Test func closingATabRefusesNewConnectionsToItsPortAndEndsItsBridge() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let root = s.session()
        let tab = try #require(root.tabs.newTab())
        let port = try map(root, to: dev.port)
        try hold(tab, port)
        let fd = try await bridge(port, in: s)
        defer { close(fd) }

        root.tabs.close(tab.tabID)

        #expect(await peerClosed(fd), "the closed tab's live bridge ends")
        #expect(connectLoopback(port) < 0, "nothing listens for a closed tab")
        #expect(s.vm.browsers.ports.ports(of: try #require(root.remote).owner).isEmpty)
    }

    @Test func aPortTwoTabsHoldStaysUpUntilTheSecondCloses() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let root = s.session()
        let a = try #require(root.tabs.newTab()), b = try #require(root.tabs.newTab())
        let port = try map(root, to: dev.port)
        try hold(a, port)
        try hold(b, port)
        let fd = try await bridge(port, in: s)
        defer { close(fd) }
        let owner = try #require(root.remote).owner

        root.tabs.close(a.tabID)
        #expect(s.vm.browsers.ports.ports(of: owner) == [Int(port)], "the other tab still holds it")
        let again = connectLoopback(port)
        #expect(again >= 0)
        close(again)

        root.tabs.close(b.tabID)
        #expect(await peerClosed(fd))
        #expect(connectLoopback(port) < 0)
        #expect(s.vm.browsers.ports.ports(of: owner).isEmpty)
    }

    @Test func closeOthersAndCloseAllReleaseTheClosedTabsPorts() async throws {
        let (s, _) = try await setup()
        defer { s.stop() }
        let dev = try DevServerFixture()
        defer { dev.stop() }
        let root = s.session()
        let keep = try #require(root.tabs.newTab()), other = try #require(root.tabs.newTab())
        let kept = try map(root, to: dev.port), dropped = try map(root, to: dev.port)
        try hold(keep, kept)
        try hold(other, dropped)
        let fd = try await bridge(dropped, in: s)
        defer { close(fd) }
        let owner = try #require(root.remote).owner
        root.tabs.select(keep.tabID)

        root.tabs.closeOthers()
        #expect(await peerClosed(fd))
        #expect(s.vm.browsers.ports.ports(of: owner) == [Int(kept)])

        root.tabs.closeAll()
        #expect(s.vm.browsers.ports.ports(of: owner).isEmpty)
        #expect(connectLoopback(kept) < 0)
    }

    private static func bodyText(_ session: BrowserSession) async throws -> String {
        let view = try #require(session.webView)
        return try await view.callAsyncJavaScript("return document.body ? document.body.innerText : ''", arguments: [:], in: nil,
                                                  contentWorld: .page) as? String ?? ""
    }
}
