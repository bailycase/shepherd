import Foundation
import Testing
@testable import ShepherdProtocol

/// Pairing links (`shepherd://fleet/join?...`) and the answer of `Shepherd --fleet-where`: what they carry, what they refuse.
@Suite("Fleet pairing link")
struct FleetPairingLinkTests {
    static let id = UUID(uuidString: "5B1F7A52-0F3C-4C55-A5A3-61C0E3F2B9D4")!
    static let routes = [FleetReportedRoute(host: "192.168.20.14", kind: .lan), FleetReportedRoute(host: "mini.example.internal", kind: .hostname),
                         FleetReportedRoute(host: "100.86.12.4", kind: .tailscale)]
    static let link = FleetPairingLink(hostID: id, name: "Mac mini", port: 7434, routes: routes, code: "482913", expiresAt: 1_770_000_300_000)

    // MARK: Encode and decode

    @Test func aLinkRoundTripsThroughItsURL() throws {
        let url = Self.link.url(scheme: "shepherd")
        #expect(url.scheme == "shepherd" && url.host() == "fleet" && url.path == "/join")
        #expect(FleetPairingLink.read(url, scheme: "shepherd") == .link(Self.link))
        #expect(FleetPairingLink.read(url.absoluteString, scheme: "shepherd") == .link(Self.link))
    }

    @Test func aNameWithSpacesCommasAndEmojiSurvives() {
        let odd = FleetPairingLink(hostID: Self.id, name: "Ann's Mac mini, 2 & co. é", port: 7434, routes: Self.routes, code: "000042", expiresAt: 5)
        #expect(FleetPairingLink.read(odd.url(scheme: "shepherd"), scheme: "shepherd") == .link(odd))
    }

    @Test func aDeviceLinkSaysSoAndAJoinLinkDoesNot() {
        let device = FleetPairingLink(purpose: .device, hostID: Self.id, name: "Mac mini", port: 7434, routes: Self.routes, code: "482913", expiresAt: 5)
        #expect(device.url(scheme: "shepherd").absoluteString.contains("use=device"))
        #expect(!Self.link.url(scheme: "shepherd").absoluteString.contains("use="))
        #expect(FleetPairingLink.read(device.url(scheme: "shepherd"), scheme: "shepherd") == .link(device))
    }

    @Test func aLinkIsBoundedInRoutesAndName() {
        let many = (1...20).map { FleetReportedRoute(host: "10.0.0.\($0)", kind: .lan) }
        let long = FleetPairingLink(hostID: Self.id, name: String(repeating: "m", count: 300), port: 7434, routes: many, code: "482913", expiresAt: 5)
        guard case .link(let read) = FleetPairingLink.read(long.url(scheme: "shepherd"), scheme: "shepherd") else { Issue.record("a long link didn't read"); return }
        #expect(read.routes == Array(many.prefix(FleetPairingLink.maxRoutes)) && read.name.utf8.count == FleetPairingLink.maxNameBytes)
    }

    @Test func surroundingWhitespaceFromAPasteDoesNotCount() {
        let text = "  \n" + Self.link.url(scheme: "shepherd").absoluteString + "\n "
        #expect(FleetPairingLink.read(text, scheme: "shepherd") == .link(Self.link))
    }

    // MARK: Expiry

    @Test func aLinkExpiresWithItsCode() {
        let expiry = Date(timeIntervalSince1970: 1_770_000_300)
        #expect(!Self.link.isExpired(at: expiry.addingTimeInterval(-0.001)))
        #expect(Self.link.isExpired(at: expiry))
        #expect(Self.link.isExpired(at: expiry.addingTimeInterval(60)))
    }

    // MARK: Editions

    @Test func eachEditionHasItsOwnScheme() {
        #expect(FleetPairingLink.scheme(bundleIdentifier: "com.bailycase.shepherd") == "shepherd")
        #expect(FleetPairingLink.scheme(bundleIdentifier: "com.bailycase.shepherd.nightly") == "shepherd-nightly")
        #expect(FleetPairingLink.scheme(bundleIdentifier: "com.bailycase.shepherd.dev") == "shepherd-dev")
        #expect(FleetPairingLink.scheme(bundleIdentifier: nil) == "shepherd", "a tool or a test runner is the everyday app")
        #expect(Set(FleetPairingLink.allSchemes).count == 3)
    }

    @Test(arguments: [("shepherd", "shepherd-nightly", "Shepherd Nightly"), ("shepherd-nightly", "shepherd", "Shepherd"), ("shepherd-dev", "shepherd-nightly", "Shepherd Nightly"),
                      ("shepherd", "shepherd-dev", "Shepherd Dev")])
    func anotherEditionsLinkIsNotOpened(_ readingApp: String, _ linkScheme: String, _ named: String) {
        #expect(FleetPairingLink.read(Self.link.url(scheme: linkScheme), scheme: readingApp) == .otherEdition(appName: named))
    }

    @Test func aPhoneReadsAnyEditionsLink() {
        for scheme in FleetPairingLink.allSchemes {
            #expect(FleetPairingLink.readAnyEdition(Self.link.url(scheme: scheme).absoluteString) == .link(Self.link))
        }
        #expect(FleetPairingLink.readAnyEdition("https://example.com/?c=482913") == .notALink)
    }

    // MARK: Refused

    private func refused(_ change: (inout [String: String]) -> Void, removing key: String? = nil, extra: [URLQueryItem] = []) -> FleetPairingLink.Reading {
        var parts = URLComponents(url: Self.link.url(scheme: "shepherd"), resolvingAgainstBaseURL: false)!
        var items = parts.queryItems!.filter { $0.name != key }
        var values = Dictionary(items.filter { $0.name != "r" }.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        change(&values)
        items = items.filter { $0.name == "r" } + values.map { URLQueryItem(name: $0.key, value: $0.value) } + extra
        parts.queryItems = items
        return FleetPairingLink.read(parts.url!, scheme: "shepherd")
    }

    @Test(arguments: ["id", "n", "p", "c", "x", "v"])
    func aLinkMissingAPartIsMalformed(_ key: String) {
        #expect(refused({ $0[key] = nil }) == .malformed)
    }

    @Test func partsOutOfBoundsAreMalformed() {
        #expect(refused({ $0["id"] = "not-a-uuid" }) == .malformed)
        #expect(refused({ $0["p"] = "0" }) == .malformed)
        #expect(refused({ $0["p"] = "70000" }) == .malformed)
        #expect(refused({ $0["c"] = "48291" }) == .malformed, "a short code isn't a code")
        #expect(refused({ $0["c"] = "48291x" }) == .malformed)
        #expect(refused({ $0["x"] = "soon" }) == .malformed)
        #expect(refused({ $0["x"] = "-4" }) == .malformed)
        #expect(refused({ $0["v"] = "2" }) == .malformed, "a version this build doesn't know")
        #expect(refused({ $0["n"] = "" }) == .malformed)
        #expect(refused({ $0["use"] = "root" }) == .malformed)
    }

    @Test func routesThatAreNotHostsAreMalformed() {
        for bad in ["10.0.0.1/evil,lan", "http://mac.local,hostname", "mac mini.local,lan", ",lan", "nokind"] {
            #expect(refused({ _ in }, removing: "r", extra: [URLQueryItem(name: "r", value: bad)]) == .malformed, "\(bad)")
        }
        #expect(refused({ _ in }, removing: "r") == .malformed, "a link that says where nothing is")
        #expect(refused({ _ in }, extra: [URLQueryItem(name: "id", value: UUID().uuidString)]) == .malformed, "two Macs say nothing")
    }

    @Test func aRouteOfAKindThisBuildDoesNotKnowIsSkippedNotRefused() {
        let reading = refused({ _ in }, extra: [URLQueryItem(name: "r", value: "10.9.9.9,wormhole")])
        guard case .link(let read) = reading else { Issue.record("a newer Mac's link wasn't read"); return }
        #expect(read.routes == Self.routes)
        #expect(refused({ _ in }, removing: "r", extra: [URLQueryItem(name: "r", value: "10.9.9.9,wormhole")]) == .malformed)
    }

    @Test func aRepeatedPartIsMalformed() {
        #expect(refused({ _ in }, extra: [URLQueryItem(name: "c", value: "000000")]) == .malformed, "two codes say nothing")
    }

    @Test func otherLinksAreNotPairingLinks() {
        for text in ["", "482913", "https://example.com/fleet/join", "shepherd://thread/abc", "shepherd://needs-you", "shepherd-pair://device?code=482913&mac=abcd", "not a url at all"] {
            #expect(FleetPairingLink.read(text, scheme: "shepherd") == .notALink, "\(text)")
        }
        #expect(FleetPairingLink.read("shepherd://fleet/other?v=1", scheme: "shepherd") == .malformed)
        #expect(FleetPairingLink.isPairingURL(URL(string: "shepherd-nightly://fleet/join?x=1")!))
        #expect(!FleetPairingLink.isPairingURL(URL(string: "shepherd://thread/abc")!))
    }
}

/// What `Shepherd --fleet-where` prints, and what an SSH find accepts of it.
@Suite("Fleet where")
struct FleetWhereTests {
    static let found = FleetWhere(hostID: FleetPairingLinkTests.id, name: "Mac mini", app: "Shepherd Nightly", build: "1.9", port: 7434, routes: FleetPairingLinkTests.routes)

    @Test func theAnswerIsOneLineOfJSON() throws {
        let line = Self.found.line()
        #expect(!line.contains("\n") && line.hasPrefix("{"))
        #expect(FleetWhere.read(Data((line + "\n").utf8)) == Self.found)
    }

    @Test func aLoginShellsOwnLinesAroundItAreIgnored() {
        let output = "Last login: Tue\nWelcome to the mini\n" + Self.found.line() + "\nlogout\n"
        #expect(FleetWhere.read(Data(output.utf8)) == Self.found)
    }

    @Test func anAnswerThatIsNotShepherdsIsNil() {
        #expect(FleetWhere.read(Data()) == nil)
        #expect(FleetWhere.read(Data("{}".utf8)) == nil)
        #expect(FleetWhere.read(Data("<html>nope</html>".utf8)) == nil)
        var bad = Self.found
        bad.routes = [FleetReportedRoute(host: "http://x", kind: .lan)]
        #expect(FleetWhere.read(Data(bad.line().utf8)) == nil, "routes are words of address characters")
        bad = Self.found
        bad.port = 0
        #expect(FleetWhere.read(Data(bad.line().utf8)) == nil)
        bad = Self.found
        bad.v = 9
        #expect(FleetWhere.read(Data(bad.line().utf8)) == nil, "a version this build doesn't read")
        bad = Self.found
        bad.routes = []
        #expect(FleetWhere.read(Data(bad.line().utf8)) == nil)
    }

    @Test func aHostThatIsNotListeningHasNothingToSay() throws {
        #expect(throws: FleetWhere.Unavailable.notServing) { try FleetWhere(snapshot: FleetSnapshot(enabled: true, hostID: UUID(), name: "Mac mini"), app: nil) }
        let snapshot = FleetSnapshot(enabled: true, hostID: FleetPairingLinkTests.id, name: "Mac mini", build: "1.9", port: 7434, routes: FleetPairingLinkTests.routes)
        #expect(try FleetWhere(snapshot: snapshot, app: "Shepherd Nightly") == Self.found)
    }

    @Test func theAnswerNamesNoCodeOrToken() {
        let line = Self.found.line().lowercased()
        #expect(!line.contains("token") && !line.contains("code"))
    }
}

/// The routes a Mac says it has, in its snapshot.
@Suite("Fleet snapshot routes")
struct FleetSnapshotRoutesTests {
    @Test func aSnapshotFromAHostBeforePairingLinksHasNoRoutes() throws {
        let old = Data(#"{"enabled":true,"name":"Mac mini","addresses":["10.0.0.4"],"advertising":false,"peers":[]}"#.utf8)
        #expect(try JSONDecoder().decode(FleetSnapshot.self, from: old).routes.isEmpty)
    }

    @Test func routesRoundTripAndAClientIsNeverToldThem() throws {
        let snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "Mac mini", port: 7434, routes: FleetPairingLinkTests.routes)
        #expect(try JSONDecoder().decode(FleetSnapshot.self, from: JSONEncoder().encode(snapshot)).routes == FleetPairingLinkTests.routes)
        #expect(snapshot.clientView.routes.isEmpty, "where a Mac listens is for its own app and its members")
    }
}
