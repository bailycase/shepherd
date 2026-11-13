import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Add a Mac when Bonjour can't find it, as the page's model drives it: a pairing link the other Mac shared, or a Mac found over SSH
/// (with the `ssh` call replaced by a fixture; the integration suite for `FleetSSHFinder` runs a fake one). Each `FleetApp` is a
/// scratch host with its app's model; their routes are the loopback address, as nothing but the test reaches them.
@Suite("Add a Mac by link or SSH", .mainActorExclusive)
@MainActor
struct FleetPairLinkFlowTests {
    typealias FleetApp = FleetSettingsFlowTests.FleetApp

    static func app(_ name: String, fleet: Bool = true, serving: Bool = false) async throws -> FleetApp {
        try await FleetApp(name, fleet: fleet, serving: serving) { server in
            server.configureFleetRendezvous(store: UnavailableFleetRendezvousStore(),
                                            routes: { port in [FleetRoute(host: "127.0.0.1", port: port, kind: .lan, learned: false)] }, lookupInterval: 0)
        }
    }

    /// The link the other Mac's Join screen offers for its open code.
    static func link(of app: FleetApp, purpose: FleetPairingLink.Purpose = .join) async throws -> FleetPairingLink {
        if purpose == .join { await app.model.startJoin() } else { await app.model.startDeviceCode() }
        await app.model.refresh()
        let shown = try #require(purpose == .join ? app.model.join : app.model.deviceCode)
        return try #require(app.model.pairingLink(for: shown, purpose: purpose))
    }

    // MARK: The link a Mac shares

    @Test func theJoinScreenOffersALinkThatSaysWhereThisMacIsAndExpiresWithTheCode() async throws {
        let b = try await Self.app("Mac mini")
        defer { b.stop() }
        let link = try await Self.link(of: b)
        let shown = try #require(b.model.join)
        #expect(link.name == "Mac mini" && link.port == b.model.snapshot.port && link.hostID == b.model.snapshot.hostID && link.code == shown.code)
        #expect(link.routes == [FleetReportedRoute(host: "127.0.0.1", kind: .lan)] && link.routes == b.model.snapshot.routes, "the list under Reachable at")
        #expect(abs(link.expiresAt - shown.expiresAt.timeIntervalSince1970 * 1000) < 1)
        #expect(link.url(scheme: b.model.linkScheme).scheme == FleetPairingLink.currentScheme)
        #expect(b.model.snapshot.routes.map { $0.kind.label } == ["LAN"])
    }

    @Test func aMacThatHasNotSaidWhereItListensOffersNoLink() async throws {
        let b = try await FleetApp("Mac mini", fleet: false)
        defer { b.stop() }
        await b.model.startDeviceCode()
        let shown = try #require(b.model.deviceCode)
        #expect(b.model.pairingLink(for: shown, purpose: .device) == nil, "no listener, no link")
    }

    // MARK: Opening a link

    @Test func aLinkOpenedFromOutsideFillsInAddAMacAndPairsOnItsCode() async throws {
        let a = try await Self.app("MacBook Pro"), b = try await Self.app("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        #expect(a.model.findsByLink)
        let link = try await Self.link(of: b)

        // Finder, Messages or AirDrop hands the URL over; the sheet reads it.
        a.model.receive(link: link.url(scheme: a.model.linkScheme))
        let text = try #require(a.model.incomingLink)
        a.model.incomingLink = nil
        a.model.readLink(text, asClient: false)
        #expect(a.model.linkProblem == nil)
        let target = try #require(a.model.target)
        #expect(target.hostID == link.hostID && target.name == "Mac mini" && target.address == "127.0.0.1:\(b.port ?? 0)" && target.expiresAt == link.expiresAt)

        #expect(await a.model.pair(at: target, code: link.code, asClient: false))
        #expect(a.model.pairing == .idle)
        try await FleetSettingsFlowTests.waitFor("both Macs to list each other") {
            await a.model.refresh(); await b.model.refresh()
            return a.model.rows.map(\.state) == [.thisMac, .connected] && b.model.rows.map(\.state) == [.thisMac, .connected]
        }
        #expect(b.model.joinEnd == .joined("MacBook Pro"))
        a.model.stopFinding()
        #expect(a.model.link == nil && a.model.linkText.isEmpty, "closing the sheet forgets the link")
    }

    @Test func aLinkThatCannotBeUsedSaysWhy() async throws {
        let a = try await Self.app("MacBook Pro"), b = try await Self.app("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        let link = try await Self.link(of: b)

        a.model.readLink("   ", asClient: false)
        #expect(a.model.link == nil && a.model.linkProblem == nil, "an empty field says nothing")
        a.model.readLink("482913", asClient: false)
        #expect(a.model.linkProblem?.hasPrefix("That isn't a pairing link") == true && a.model.target == nil)
        a.model.readLink(link.url(scheme: FleetPairingLink.nightlyScheme == a.model.linkScheme ? FleetPairingLink.stableScheme : FleetPairingLink.nightlyScheme).absoluteString, asClient: false)
        #expect(a.model.linkProblem?.hasPrefix("That link is for Shepherd") == true && a.model.target == nil, "another edition's link isn't opened")
        a.model.now = { Date().addingTimeInterval(3600) }
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString, asClient: false)
        #expect(a.model.linkProblem?.hasPrefix("That link has expired") == true && a.model.target == nil)
        a.model.now = Date.init
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString + "x", asClient: false)
        #expect(a.model.linkProblem != nil && a.model.target == nil, "a damaged link")
        // A Mac's own link, and a link for the other kind of sheet.
        let own = FleetPairingLink(hostID: try #require(a.model.snapshot.hostID), name: "MacBook Pro", port: 7434, routes: [FleetReportedRoute(host: "127.0.0.1", kind: .lan)],
                                   code: "482913", expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000)
        a.model.readLink(own.url(scheme: a.model.linkScheme).absoluteString, asClient: false)
        #expect(a.model.linkProblem == "That link is for this Mac.")
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString, asClient: true)
        #expect(a.model.linkProblem?.contains("adds a Mac to a fleet") == true && a.model.target == nil, "with Fleet off a Join link adds nothing")
    }

    @Test func aLinkWhoseMacIsAnotherThanTheOneAtItsAddressPairsNothing() async throws {
        let a = try await Self.app("MacBook Pro"), b = try await Self.app("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        var link = try await Self.link(of: b)
        link.hostID = UUID()
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString, asClient: false)
        let target = try #require(a.model.target)
        #expect(!(await a.model.pair(at: target, code: link.code, asClient: false)))
        guard case .failed(let message) = a.model.pairing else { Issue.record("a wrong Mac was paired"); return }
        #expect(!message.isEmpty)
        await a.model.refresh(); await b.model.refresh()
        #expect(a.model.rows.map(\.title) == ["This Mac"] && b.model.snapshot.join?.attemptsLeft == FleetProtocol.maxCodeAttempts)
    }

    @Test func aHostFromBeforeLinksIsToldToBeRestartedNotAskedWhatItCannotDo() async throws {
        let a = try await Self.app("MacBook Pro"), b = try await Self.app("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        a.model.findsByLink = false
        let link = try await Self.link(of: b)
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString, asClient: false)
        let target = try #require(a.model.target)
        #expect(!(await a.model.pair(at: target, code: link.code, asClient: false)))
        guard case .failed(let message) = a.model.pairing else { Issue.record("an old host paired by link"); return }
        #expect(message.contains("older than this app"))
        await b.model.refresh()
        #expect(b.model.snapshot.join?.attemptsLeft == FleetProtocol.maxCodeAttempts, "nothing was sent to the other Mac")
    }

    // MARK: SSH

    @Test func aMacFoundOverSSHShowsWhereItListensAndPairsOnlyOnItsCode() async throws {
        let a = try await Self.app("MacBook Pro"), b = try await Self.app("Mac mini")
        defer { a.stop(); b.stop() }
        await a.model.refresh(); await b.model.refresh()
        let answer = FleetWhere(hostID: try #require(b.model.snapshot.hostID), name: "Mac mini", app: "Shepherd Nightly", build: "1.9", port: try #require(b.model.snapshot.port),
                                routes: b.model.snapshot.routes)
        var asked: [String] = []
        a.model.sshFind = { target in asked.append(target); return answer }

        #expect(!a.model.canFindOverSSH && a.model.ssh == .idle)
        a.model.sshTarget = "me@mini.example.internal"
        #expect(a.model.canFindOverSSH)
        await a.model.findOverSSH()
        #expect(asked == ["me@mini.example.internal"])
        guard case .found(let found) = a.model.ssh else { Issue.record("not found: \(a.model.ssh)"); return }
        #expect(found.name == "Mac mini" && found.version == "Shepherd Nightly 1.9" && found.address == "127.0.0.1:\(answer.port)")
        #expect(found.routes.map(\.host) == ["127.0.0.1", "mini.example.internal"], "what was typed after ssh is a way to it too, after the ones it gave")
        #expect(a.model.target == found)
        await b.model.refresh()
        #expect(a.model.rows.map(\.title) == ["This Mac"] && b.model.rows.map(\.title) == ["This Mac"], "finding pairs nothing")

        await b.model.startJoin()
        let code = try #require(b.model.join).code
        #expect(await a.model.pair(at: found, code: code, asClient: false))
        try await FleetSettingsFlowTests.waitFor("both Macs to list each other") {
            await a.model.refresh(); await b.model.refresh()
            return a.model.rows.map(\.state) == [.thisMac, .connected] && b.model.rows.map(\.state) == [.thisMac, .connected]
        }
    }

    @Test func aFailedFindSaysWhyAndKeepsNoTarget() async throws {
        let a = try await Self.app("MacBook Pro")
        defer { a.stop() }
        await a.model.refresh()
        a.model.sshFind = { _ in throw FleetSSHFinder.Failure.connection("ssh was refused.") }
        a.model.sshTarget = "me@mini"
        await a.model.findOverSSH()
        #expect(a.model.ssh == .failed("ssh was refused.") && a.model.target == nil)
        a.model.sshTarget = "-oProxyCommand=x"
        #expect(!a.model.canFindOverSSH)
        await a.model.findOverSSH()
        #expect(a.model.ssh == .failed(FleetSSHFinder.Failure.badTarget.message))
        // A Mac that answers as this Mac isn't offered to itself.
        a.model.sshFind = { _ in FleetWhere(hostID: a.model.snapshot.hostID ?? UUID(), name: "MacBook Pro", port: 7434, routes: [FleetReportedRoute(host: "127.0.0.1", kind: .lan)]) }
        a.model.sshTarget = "me@here"
        await a.model.findOverSSH()
        #expect(a.model.ssh == .failed("That is this Mac."))
    }

    // MARK: A device with Fleet off

    @Test func withFleetOffALinkAddsTheMacAsAClientAfterCheckingWhoAnswers() async throws {
        let a = try await Self.app("MacBook Pro", fleet: false, serving: true), b = try await Self.app("Mac mini", fleet: false, serving: true)
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        let store = RemoteHostStore(defaults: ScratchDefaults(), connects: false)
        a.model.pairClient = { host, port, code, expecting in try await store.pairAsClient(host: host, port: port, code: code, expecting: expecting) }
        let link = try await Self.link(of: b, purpose: .device)
        #expect(link.purpose == .device)

        // A Join link isn't for a Mac with Fleet off; a device link is.
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString, asClient: false)
        #expect(a.model.target == nil && a.model.linkProblem?.contains("adds a device") == true, "a Mac in a fleet is added with a Join link")
        a.model.readLink(link.url(scheme: a.model.linkScheme).absoluteString, asClient: true)
        let target = try #require(a.model.target)

        var wrong = target
        wrong.hostID = UUID()
        #expect(!(await a.model.pair(at: wrong, code: link.code, asClient: true)) && store.hosts.isEmpty, "another Mac answering is refused before the code is sent")
        #expect(await a.model.pair(at: target, code: link.code, asClient: true))
        let held = try #require(store.hosts.first)
        #expect(held.name == "Mac mini" && held.port == b.port && held.ownToken)
    }
}
