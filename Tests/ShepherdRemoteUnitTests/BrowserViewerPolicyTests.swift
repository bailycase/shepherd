import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdRemote

/// Where an agent on another Mac may take a viewer's web view (docs/browser.md › Remote › What a
/// host's agent can make this Mac do): the host's own loopback ports and public addresses, and
/// nothing on the viewer's own network. The resolver is injected, so no name is ever looked up.
@Suite("Browser viewer policy")
struct BrowserViewerPolicyTests {
    /// A policy whose resolver answers from `table` and counts what it was asked.
    final class Fixture: @unchecked Sendable {
        let asked = Locked<[String]>([])
        let clock = Locked(Date(timeIntervalSince1970: 1_000))
        let policy: BrowserViewerPolicy

        init(resolves table: [String: [String]] = [:], own: [[UInt8]] = []) {
            let asked = asked
            let clock = clock
            policy = BrowserViewerPolicy(
                resolver: { name in
                    asked.withValue { $0.append(name) }
                    return table[name]
                },
                localAddresses: { own },
                cacheSeconds: 30,
                now: { clock.current })
        }
    }

    static func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: Literal addresses

    @Test(arguments: [
        "https://example.com/", "http://93.184.216.34/", "http://8.8.8.8:8080/path", "https://[2606:4700:4700::1111]/",
        "http://1.1.1.1", "https://[2001:4860:4860::8888]:8443/", "http://172.15.255.255/", "http://172.32.0.1/", "http://100.63.255.255/",
        "http://100.128.0.1/", "http://169.253.1.1/", "http://192.167.255.255/", "http://11.0.0.1/",
    ])
    func aPublicAddressLoadsFromTheViewerAsAnyPageDoes(_ address: String) async {
        let f = Fixture(resolves: ["example.com": ["93.184.216.34", "2606:2800:220:1::1"]])
        #expect(await f.policy.verdict(for: Self.url(address)) == .web)
    }

    @Test(arguments: [
        ("http://localhost:5173/", 5173), ("http://127.0.0.1:3000/x", 3000), ("http://[::1]:8080/", 8080), ("http://LOCALHOST:4173", 4173),
        ("http://localhost/", 80), ("https://localhost/", 443), ("http://localhost", 80),
    ])
    func theHostsOwnLoopbackIsServedByTheForwardedPort(_ address: String, _ port: Int) async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url(address)) == .host(port: port))
        #expect(f.asked.current.isEmpty, "nothing is looked up for the loopback")
    }

    @Test(arguments: [
        "http://192.168.1.1/", "http://192.168.0.254:8080", "http://10.0.0.5/", "http://10.255.255.255/", "http://172.16.0.1/",
        "http://172.31.255.255/", "http://169.254.169.254/latest/meta-data/", "http://169.254.0.1", "http://100.64.0.1/",
        "http://100.127.255.255/", "http://198.18.0.1/", "http://198.19.255.255/", "http://192.0.2.1/", "http://198.51.100.1/",
        "http://203.0.113.1/", "http://224.0.0.1/", "http://239.255.255.250/", "http://240.0.0.1/", "http://255.255.255.255/",
        "http://[fd00::1]/", "http://[fc00::1]:8080/", "http://[fe80::1]/", "http://[fec0::1]/", "http://[ff02::1]/",
        "http://[2001:db8::1]/", "http://[2001::1]/", "http://[100::1]/", "http://[::2]/",
        "http://[::ffff:192.168.1.1]/", "http://[::ffff:10.0.0.1]/", "http://[64:ff9b::a00:1]/", "http://[2002:c0a8:101::1]/",
    ])
    func aPrivateOrReservedAddressIsOnTheViewersNetwork(_ address: String) async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url(address)) == .refused(.privateNetwork))
        #expect(f.asked.current.isEmpty)
    }

    @Test(arguments: [
        "http://127.0.0.2:5173/", "http://127.255.255.254/", "http://0.0.0.0:5173/", "http://0.1.2.3/", "http://[::]/",
        "http://[::ffff:127.0.0.1]:5173/", "http://127.0.0.1./", "http://localhost./", "http://foo.localhost:5173/", "http://a.b.localhost/",
        "http://2130706433/", "http://0x7f.0.0.1:5173/", "http://0177.0.0.1/", "http://127.1/", "http://017700000001/", "http://0x7f000001/",
        "http://127.000.000.001:5173/",
    ])
    func theViewersOwnLoopbackUnderAnyOtherSpellingIsRefused(_ address: String) async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url(address)) == .refused(.viewerLoopback), "\(address) must not reach this Mac's own port")
        #expect(f.asked.current.isEmpty)
    }

    @Test(arguments: ["http://3232235777/", "http://0xc0a80101/", "http://0300.0250.1.1/", "http://192.168.257/", "http://0xc0.0xa8.0x1.0x1/", "http://10.1/"])
    func aPrivateAddressInAnyNumericFormIsRefused(_ address: String) async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url(address)) == .refused(.privateNetwork), "\(address) is 192.168.x.x or 10.x")
    }

    @Test func oneOfTheViewersOwnInterfaceAddressesIsRefusedEvenWhenItIsPublic() async {
        let v4 = [8, 8, 4, 4] as [UInt8]
        let v6 = [0x26, 0x06, 0x47, 0, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11] as [UInt8]
        let f = Fixture(resolves: ["mine.example": ["8.8.4.4"]], own: [v4, v6])
        #expect(await f.policy.verdict(for: Self.url("http://8.8.4.4/")) == .refused(.viewerAddress))
        #expect(await f.policy.verdict(for: Self.url("http://[2606:4700:4700::1111]:8080/")) == .refused(.viewerAddress))
        #expect(await f.policy.verdict(for: Self.url("http://8.8.8.8/")) == .web, "another public address is fine")
        #expect(await f.policy.verdict(for: Self.url("https://mine.example/")) == .refused(.resolvesPrivately(address: "8.8.4.4")))
    }

    // MARK: Names

    @Test(arguments: [
        "http://printer/", "http://router.local/", "http://nas.LAN:8080/", "http://intranet.corp/", "http://wiki.internal/", "http://host.home.arpa/",
        "http://mac.localdomain/", "http://x.home/", "http://a.b.private/", "http://bonjour.local./",
    ])
    func aNameThatIsOnlyEverALocalNetworksIsRefusedWithoutBeingLookedUp(_ address: String) async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url(address)) == .refused(.privateNetwork))
        #expect(f.asked.current.isEmpty, "the answer does not depend on DNS")
    }

    @Test(arguments: [
        ("evil.example", ["127.0.0.1"]), ("rebind.example", ["10.0.0.7"]), ("lan.example", ["192.168.1.20"]), ("meta.example", ["169.254.169.254"]),
        ("six.example", ["::1"]), ("ula.example", ["fd12:3456::1"]), ("mapped.example", ["::ffff:192.168.1.1"]), ("cgnat.example", ["100.64.3.3"]),
        ("mixed.example", ["93.184.216.34", "192.168.1.1"]), ("mixed6.example", ["2606:2800:220:1::1", "fe80::1"]), ("zero.example", ["0.0.0.0"]),
        ("zone.example", ["fe80::1%en0"]),
    ])
    func aHostnameThatResolvesToAPrivateAddressIsRefused(_ name: String, _ answers: [String]) async {
        let f = Fixture(resolves: [name: answers])
        guard case .refused(.resolvesPrivately) = await f.policy.verdict(for: Self.url("https://\(name)/login")) else {
            Issue.record("\(name) → \(answers) was let through")
            return
        }
    }

    @Test func aHostnameThatResolvesOnlyToPublicAddressesIsLetThrough() async {
        let f = Fixture(resolves: ["example.com": ["93.184.216.34"], "v6.example": ["2606:2800:220:1::1"], "both.example": ["93.184.216.34", "2606:2800:220:1::1"]])
        #expect(await f.policy.verdict(for: Self.url("https://example.com/")) == .web)
        #expect(await f.policy.verdict(for: Self.url("https://v6.example:8443/x")) == .web)
        #expect(await f.policy.verdict(for: Self.url("http://both.example/")) == .web)
    }

    @Test func aHostnameThatDoesNotResolveIsRefused() async {
        let f = Fixture(resolves: ["empty.example": []])
        #expect(await f.policy.verdict(for: Self.url("https://nope.example/")) == .refused(.unresolved))
        #expect(await f.policy.verdict(for: Self.url("https://empty.example/")) == .refused(.unresolved))
    }

    @Test func anAnswerIsKeptBrieflyAndAskedAgainAfterwards() async {
        let f = Fixture(resolves: ["example.com": ["93.184.216.34"]])
        #expect(await f.policy.verdict(for: Self.url("https://example.com/a")) == .web)
        #expect(await f.policy.verdict(for: Self.url("https://example.com/b")) == .web)
        #expect(f.asked.current == ["example.com"], "the second page on it was not looked up again")
        f.clock.withValue { $0 = $0.addingTimeInterval(31) }
        #expect(await f.policy.verdict(for: Self.url("https://example.com/c")) == .web)
        #expect(f.asked.current == ["example.com", "example.com"], "after its time the name is looked up again")
    }

    @Test func aRefusalIsKeptTooSoAPageCannotHammerTheResolver() async {
        let f = Fixture(resolves: ["evil.example": ["127.0.0.1"]])
        for _ in 0..<3 { _ = await f.policy.verdict(for: Self.url("https://evil.example/")) }
        #expect(f.asked.current == ["evil.example"])
    }

    // MARK: Schemes

    @Test(arguments: [
        ("file:///etc/passwd", "file"), ("javascript:alert(1)", "javascript"), ("data:text/html,hi", "data"), ("ftp://example.com/x", "ftp"),
        ("blob:https://example.com/abc", "blob"), ("about:srcdoc", "about"), ("about:config", "about"), ("shepherd-design://x/y", "shepherd-design"),
        ("FILE:///Users/me/.ssh/id_rsa", "file"),
    ])
    func aMainFrameTakesOnlyWebAddressesAndAboutBlank(_ address: String, _ scheme: String) async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url(address)) == .refused(.scheme(scheme)))
    }

    @Test func aboutBlankReachesNothing() async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url("about:blank")) == .inert)
        #expect(await f.policy.verdict(for: Self.url("ABOUT:BLANK")) == .inert)
    }

    @Test func anIframeMayBeADocumentWithNoAddressOfItsOwnButNeverAFile() async {
        let f = Fixture(resolves: ["example.com": ["93.184.216.34"]])
        for inert in ["about:blank", "about:srcdoc", "blob:https://example.com/x", "data:text/html,hi"] {
            #expect(await f.policy.subframeVerdict(for: Self.url(inert)) == .inert, "\(inert)")
        }
        #expect(await f.policy.subframeVerdict(for: Self.url("file:///etc/hosts")) == .refused(.scheme("file")))
        #expect(await f.policy.subframeVerdict(for: Self.url("http://192.168.1.1/")) == .refused(.privateNetwork))
        #expect(await f.policy.subframeVerdict(for: Self.url("http://localhost:5173/")) == .host(port: 5173))
        #expect(await f.policy.subframeVerdict(for: Self.url("https://example.com/")) == .web)
    }

    @Test(arguments: ["http://", "https:///x", "http://:8080/"])
    func anAddressWithNoHostIsRefusedAsNotAnAddress(_ address: String) async {
        let f = Fixture()
        guard let url = URL(string: address) else { return }
        #expect(await f.policy.verdict(for: url) == .refused(.invalid))
    }

    // MARK: Redirects and the page open now

    /// A redirect is one more address asked of the policy: a public page that sends the browser to a
    /// private one is stopped at its second hop.
    @Test func aRedirectFromAPublicPageToAPrivateAddressIsRefusedAtTheSecondHop() async {
        let f = Fixture(resolves: ["short.example": ["93.184.216.34"]])
        #expect(await f.policy.verdict(for: Self.url("https://short.example/go")) == .web)
        #expect(await f.policy.verdict(for: Self.url("http://192.168.1.1/admin")) == .refused(.privateNetwork))
        #expect(await f.policy.verdict(for: Self.url("http://localhost:9/")) == .host(port: 9), "while one to the host's own port is carried there")
        #expect(await f.policy.verdict(for: Self.url("http://127.0.0.2:9/")) == .refused(.viewerLoopback))
    }

    @Test func thePageOpenNowIsHeldToTheSameRulesAsWhereItMayGo() async {
        let f = Fixture(resolves: ["example.com": ["93.184.216.34"]])
        #expect(await f.policy.pageVerdict(for: nil) == .inert, "no page reads nothing")
        #expect(await f.policy.pageVerdict(for: Self.url("about:blank")) == .inert)
        #expect(await f.policy.pageVerdict(for: Self.url("https://example.com/")) == .web)
        #expect(await f.policy.pageVerdict(for: Self.url("http://localhost:5173/")) == .host(port: 5173))
        #expect(await f.policy.pageVerdict(for: Self.url("file:///Users/me/notes.txt")) == .refused(.scheme("file")))
        #expect(await f.policy.pageVerdict(for: Self.url("http://192.168.1.1/admin")) == .refused(.privateNetwork))
        #expect(await f.policy.pageVerdict(for: Self.url("blob:https://example.com/abc")) == .web, "a blob is judged by the address it was made for")
        #expect(await f.policy.pageVerdict(for: Self.url("blob:http://192.168.1.1/abc")) == .refused(.privateNetwork))
    }

    // MARK: Words

    @Test func aRefusalSaysWhyInWordsForTheAgent() {
        for network: BrowserViewerRefusal in [.privateNetwork, .viewerLoopback, .viewerAddress, .resolvesPrivately(address: "10.0.0.1")] {
            #expect(network.message.contains("network of the Mac showing this page"))
            #expect(network.message.contains("localhost"), "and what to use instead")
        }
        #expect(BrowserViewerRefusal.scheme("file").message.hasPrefix("file: URLs can't be opened"))
        #expect(BrowserViewerRefusal.unresolved.message.contains("could not be resolved"))
        #expect(BrowserViewerRefusal.invalid.message.contains("not an address"))
    }

    // MARK: The host's forwarded ports

    @Test func aPortOfTheHostThatCannotBeForwardedSaysNothingOfWhatHoldsIt() {
        for refusal: BrowserPortForwarder.Refusal in [.inUse(port: 5173), .forwardedFor(port: 5173, hostName: "build-02"), .privileged(port: 80), .failed(port: 5173, errno: 48)] {
            #expect(!refusal.agentMessage.contains("build-02") && !refusal.agentMessage.contains("in use"))
            #expect(refusal.agentMessage.contains("\(refusal.port)"))
        }
        #expect(BrowserPortForwarder.Refusal.tooMany(port: 9000, limit: 8).agentMessage.contains("8"))
        #expect(BrowserPortForwarder.Refusal.tooMany(port: 9000, limit: 8).message(hostName: "build-01").contains("8 ports"))
    }

    // MARK: Parsing

    @Test(arguments: [
        ("127.0.0.1", BrowserViewerPolicy.ParsedHost.ipv4([127, 0, 0, 1])), ("2130706433", .ipv4([127, 0, 0, 1])), ("0x7f.1", .ipv4([127, 0, 0, 1])),
        ("0177.0.0.1", .ipv4([127, 0, 0, 1])), ("127.1", .ipv4([127, 0, 0, 1])), ("1.2.3.4.", .ipv4([1, 2, 3, 4])), ("0", .ipv4([0, 0, 0, 0])),
        ("255.255.255.255", .ipv4([255, 255, 255, 255])), ("4294967295", .ipv4([255, 255, 255, 255])), ("1.256", .ipv4([1, 0, 1, 0])),
        ("0x", .ipv4([0, 0, 0, 0])),
        ("[::1]", .ipv6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])), ("::ffff:1.2.3.4", .ipv6([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 1, 2, 3, 4])),
        ("fe80::1%25en0", .ipv6([0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])),
        ("Example.COM", .name("example.com")), ("a.b.c.d.e", .name("a.b.c.d.e")), ("1.2.3.4.example", .name("1.2.3.4.example")), ("localhost", .name("localhost")),
        ("0xzz", .name("0xzz")),
    ])
    func aHostIsReadTheWayWebKitReadsIt(_ host: String, _ expected: BrowserViewerPolicy.ParsedHost) {
        #expect(BrowserViewerPolicy.parse(host: host) == expected)
    }

    @Test(arguments: ["256.1.1.1", "1.2.3.4.5", "1..2", "4294967296", "089", "[::1", "::g", "", "."])
    func aHostThatLooksLikeAnAddressButIsNotOneIsNotTakenForAName(_ host: String) {
        #expect(BrowserViewerPolicy.parse(host: host) == nil, "\(host.debugDescription) is refused, not looked up")
    }

    @Test func anInvalidAddressIsRefusedAsNotAnAddress() async {
        let f = Fixture()
        #expect(await f.policy.verdict(for: Self.url("http://256.1.1.1/")) == .refused(.invalid))
        #expect(await f.policy.verdict(for: Self.url("http://1.2.3.4.5/")) == .refused(.invalid))
        #expect(f.asked.current.isEmpty)
    }
}
