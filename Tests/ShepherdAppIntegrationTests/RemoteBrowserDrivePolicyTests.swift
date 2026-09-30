import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
import WebKit
@testable import ShepherdApp

/// What a host's agent can and cannot make the viewer's Mac do (docs/browser.md › Remote › What a
/// host's agent can make this Mac do), end to end against a real off-screen web view: it may open the
/// host's own loopback ports and public addresses, and nothing on the viewer's own network, however
/// it is spelled, redirected to, framed or navigated to by script.
@Suite("Remote browser drive address policy", .mainActorExclusive)
@MainActor
struct RemoteBrowserDrivePolicyTests {
    typealias Setup = RemoteBrowserDriveTests.Setup

    private let refusedWords = "network of the Mac showing this page"

    /// A resolver that knows a few names and looks nothing up.
    private static func policy(_ table: [String: [String]] = [:], own: [[UInt8]] = []) -> BrowserViewerPolicy {
        BrowserViewerPolicy(resolver: { table[$0] }, localAddresses: { own })
    }

    /// The host's dev server serves these pages, and redirects and frames that lead somewhere else.
    private static func handler(mine: @escaping @Sendable () -> UInt16 = { 0 }) -> TinyWebServer.Handler {
        let checkout = BrowserAgentTests.checkout
        return { request in
            switch request.path {
            case "/go-private":
                return TinyWebServer.Response(status: 302, headers: ["Location": "http://192.168.1.1/admin"])
            case "/go-own-loopback":
                return TinyWebServer.Response(status: 302, headers: ["Location": "http://127.0.0.2:\(mine())/secret"])
            case "/go-own-port":
                return TinyWebServer.Response(status: 302, headers: ["Location": "http://localhost:\(mine())/secret"])
            case "/frames":
                return .html("<html><head><title>Frames</title></head><body><h1>Frames</h1>"
                    + "<iframe src=\"http://192.168.1.1/inner\"></iframe><iframe srcdoc=\"<p>fine</p>\"></iframe></body></html>")
            case "/checkout":
                return .html(checkout)
            default:
                return .html("<html><head><title>\(request.path)</title></head><body><h1>\(request.path)</h1></body></html>")
            }
        }
    }

    private func setup(table: [String: [String]] = [:], handler: TinyWebServer.Handler? = nil) async throws -> Setup {
        try await RemoteBrowserDriveTests.makeSetup(handler: handler ?? Self.handler(), policy: Self.policy(table))
    }

    private func ownServer() async throws -> TinyWebServer {
        let server = try TinyWebServer(pages: ["/secret": "<html><head><title>Viewer secret</title></head><body>this Mac's own</body></html>"])
        try await server.start()
        return server
    }

    // MARK: browser_open

    @Test(arguments: [
        "http://192.168.1.50:8080/", "http://10.0.0.1/", "http://169.254.169.254/latest/meta-data/", "http://172.16.0.9/", "http://100.64.0.1/",
        "http://[fd00::1]/", "http://[fe80::1]/", "http://printer/", "http://router.local/", "http://0.0.0.0:8080/", "http://127.0.0.2:9/",
        "http://2130706433:9/", "http://0x7f.1:9/", "http://3232235777/",
    ])
    func anAddressOnTheViewersNetworkIsRefusedAndNothingLoads(_ address: String) async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let refused = try await agent.failure(.open(url: address, note: nil))
        #expect(refused.code == "refused_url" && refused.message.contains(refusedWords), "\(address): \(refused)")
        #expect(!s.session.hasPage && s.session.webView == nil, "nothing was loaded")
    }

    @Test(arguments: ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi", "ftp://example.com/x", "blob:http://localhost/x", "about:config"])
    func aSchemeThatIsNotTheWebIsRefused(_ address: String) async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let refused = try await agent.failure(.open(url: address, note: nil))
        #expect(refused.code == "refused_url", "\(address): \(refused)")
        #expect(!s.session.hasPage)
    }

    @Test func aHostnameThatResolvesToTheViewersOwnLoopbackIsRefusedWithNoClaimOnItsPort() async throws {
        let mine = try await ownServer()
        defer { mine.stop() }
        let s = try await setup(table: ["app.evil.test": ["127.0.0.1"], "lan.evil.test": ["192.168.1.20"], "both.evil.test": ["93.184.216.34", "10.0.0.1"]])
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        for name in ["app.evil.test", "lan.evil.test", "both.evil.test"] {
            let refused = try await agent.failure(.open(url: "http://\(name):\(mine.port)/secret", note: nil))
            #expect(refused.code == "refused_url" && refused.message.contains(refusedWords), "\(name): \(refused)")
        }
        #expect(mine.requested.current.isEmpty, "this Mac's own server was never asked")
        #expect(s.vm.browsers.ports.ports(of: try #require(s.session.remote).owner).isEmpty, "and no port was forwarded for a name")
        let unresolved = try await agent.failure(.open(url: "http://nowhere.evil.test/", note: nil))
        #expect(unresolved.code == "refused_url" && unresolved.message.contains("could not be resolved"))
    }

    @Test func aPortThisMacsOwnProgramHoldsIsRefusedToTheAgentAndNeverReachesThatProgram() async throws {
        let mine = try await ownServer()
        defer { mine.stop() }
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let refused = try await agent.failure(.open(url: "http://localhost:\(mine.port)/secret", note: nil))
        #expect(refused.code == "navigation_failed")
        #expect(refused.message.contains("Port \(mine.port) can't be opened in the browser right now"))
        #expect(!refused.message.contains("in use"), "the agent is not told what holds the port")
        #expect(mine.requested.current.isEmpty && !s.session.hasPage)
        #expect(s.session.notice?.message.contains("in use on this Mac") == true, "the user at this Mac is told why")
    }

    @Test func anAgentMayHaveAHandfulOfTheHostsPortsForwardedAndNoMore() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let owner = try #require(s.session.remote).owner
        // Nothing listens on these on the host, so each page fails to load; the port stays held.
        var ports: [UInt16] = []
        for _ in 0...BrowserHostGuard.maxForwardedPorts { ports.append(try RemoteBrowserDriveTests.unusedPort()) }
        for port in ports.dropLast() {
            s.session.remote?.hostPorts[Int(port)] = Int(try RemoteBrowserDriveTests.unusedPort())
            _ = try await agent.ask(.open(url: "http://localhost:\(port)/", note: nil))
        }
        #expect(s.vm.browsers.ports.ports(of: owner).count == BrowserHostGuard.maxForwardedPorts)
        let over = try #require(ports.last)
        let refused = try await agent.failure(.open(url: "http://localhost:\(over)/", note: nil))
        #expect(refused.code == "navigation_failed" && refused.message.contains("already has \(BrowserHostGuard.maxForwardedPorts)"))
        #expect(!s.vm.browsers.ports.ports(of: owner).contains(Int(over)))
    }

    // MARK: Redirects, frames and scripts

    @Test func aRedirectToAPrivateAddressIsStoppedAtTheSecondHop() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let refused = try await agent.failure(.open(url: s.url("/go-private"), note: nil))
        #expect(refused.code == "refused_url" && refused.message.contains(refusedWords), "\(refused)")
        #expect(s.session.url == nil && !s.session.hasPage, "the page never went there, and the address bar says so")
        #expect(s.session.console.lines.contains { $0.text.contains("Blocked a navigation") })
    }

    @Test func aRedirectToTheViewersLoopbackOrAPortItHoldsIsStoppedToo() async throws {
        let mine = try await ownServer()
        defer { mine.stop() }
        let s = try await setup(handler: Self.handler(mine: { mine.port }))
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let other = try await agent.failure(.open(url: s.url("/go-own-loopback"), note: nil))
        #expect(other.code == "refused_url", "127.0.0.2 is this Mac's own: \(other)")
        let held = try await agent.failure(.open(url: s.url("/go-own-port"), note: nil))
        #expect(held.code == "refused_url" || held.code == "navigation_failed", "a port this Mac's program holds: \(held)")
        #expect(mine.requested.current.isEmpty, "this Mac's own server was never asked")
    }

    @Test func anIframeToAPrivateAddressIsBlockedAndTheRestOfThePageLoads() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        let opened = try await agent.text(.open(url: s.url("/frames"), note: nil))
        #expect(opened.contains("Page: Frames") && opened.contains("Opened \(s.url("/frames"))."))
        #expect(opened.contains("A navigation was blocked: That address is on the network of the Mac showing this page"))
        #expect(s.session.console.lines.contains { $0.text.contains("Blocked a navigation") })
        let snapshot = try await agent.text(.read(selector: nil, maxChars: nil))
        #expect(snapshot.contains("heading \"Frames\""))
    }

    @Test func aScriptsOwnNavigationToAPrivateAddressIsStopped() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))
        _ = try await agent.text(.eval(expression: "location.href = 'http://192.168.1.1/admin'; 1", note: nil))
        try await eventuallyOnMain("the navigation to be stopped") {
            s.session.console.lines.contains { $0.text.contains("Blocked a navigation") }
        }
        #expect(s.session.url?.absoluteString == s.url("/checkout"), "the page stayed where it was")
        #expect(try await agent.text(.read(selector: nil, maxChars: nil)).contains("heading \"Checkout\""))
    }

    // MARK: What the agent may read back

    @Test func aPageTheUserOpenedOnTheirOwnNetworkIsNeverReadBackToTheAgent() async throws {
        let s = try await setup()
        defer { s.stop() }
        let file = s.local.dir.appendingPathComponent("notes.html")
        try Data("<html><head><title>My private notes</title></head><body>secret</body></html>".utf8).write(to: file)
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))

        // The user types a file address of their own: the address field takes it, once.
        #expect(s.session.open(address: file.absoluteString))
        try await eventuallyOnMain("the file page to load") { s.session.webView?.title == "My private notes" }
        let requests: [BrowserRequest] = [.read(selector: nil, maxChars: nil), .screenshot(ref: nil), .console(clear: false), .wait(text: "x", ref: nil, gone: false, ms: nil, timeout: 1),
                                          .eval(expression: "document.title", note: nil), .click(ref: "e1", double: false, note: nil), .reload(note: nil)]
        for request in requests {
            let refused = try await agent.failure(request)
            #expect(refused.code == "refused_url" && refused.message == BrowserHostGuard.pageMessage, "\(request): \(refused)")
            #expect(!refused.message.contains("notes") && !refused.message.contains(file.path), "neither its title nor its address")
        }

        // The agent can still open a page it may, and then everything works.
        let opened = try await agent.text(.open(url: s.url("/terms"), note: nil))
        #expect(opened.contains("Page: /terms"))
        #expect(try await agent.text(.read(selector: nil, maxChars: nil)).contains("heading \"/terms\""))
    }

    @Test func theUsersOwnAddressFieldStillOpensWhatTheyTypeWhileTheAgentDrives() async throws {
        let s = try await setup()
        defer { s.stop() }
        try await s.showTab()
        let agent = try s.extensionConnection()
        _ = try await agent.text(.open(url: s.url("/checkout"), note: nil))
        let file = s.local.dir.appendingPathComponent("mine.html")
        try Data("<html><head><title>Mine</title></head><body>mine</body></html>".utf8).write(to: file)
        #expect(s.session.open(address: file.absoluteString))
        try await eventuallyOnMain("the user's own page") { s.session.webView?.title == "Mine" }
    }
}
