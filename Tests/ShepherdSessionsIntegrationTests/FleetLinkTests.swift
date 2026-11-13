import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// A gate a test closes to hold something back (a Mac's readings, its dialing) and opens to let it through.
actor FleetTestGate {
    private var closed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func close() { closed = true }

    func open() {
        closed = false
        let held = waiters
        waiters = []
        for waiter in held { waiter.resume() }
    }

    /// How many are held at the gate now.
    var waiting: Int { waiters.count }

    func pass() async {
        guard closed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// What the Mac's network is, for the routes it reports: addresses a test sets, and the change notice a test fires.
final class FakeNetwork: @unchecked Sendable {
    private struct State {
        var routes: [FleetReportedRoute]
        var onChange: (@Sendable () -> Void)?
    }
    private let state: Locked<State>

    init(_ routes: [FleetReportedRoute] = []) { state = Locked(State(routes: routes)) }

    var network: FleetNetwork {
        FleetNetwork(routes: { [state] in state.current.routes }, watch: { [state] onChange in
            state.withValue { $0.onChange = onChange }
            return { state.withValue { $0.onChange = nil } }
        })
    }

    /// The Mac's addresses changed.
    func change(_ routes: [FleetReportedRoute]) {
        state.withValue { $0.routes = routes }
        fire()
    }

    /// The system says the network changed (with the addresses as they are).
    func fire() { state.current.onChange?() }
}

/// How one Mac reaches the others: which addresses its router blocks, which names stand for which listener, and what it tried. A Mac
/// here dials 127.0.0.1 at the port of the route, unless the route is refused or is a name.
final class LinkRouting: @unchecked Sendable {
    private struct State {
        var refusedPorts: Set<UInt16> = []
        var refusedHosts: Set<String> = []
        var names: [String: UInt16] = [:]
        var tried: [FleetRoute] = []
    }
    private let state = Locked(State())
    let network: FakeNetwork
    /// Held while a test wants this Mac not to have dialed yet.
    let dialing = FleetTestGate()
    let drain: Duration
    let recheck: Duration
    let legacy: Bool

    init(network: FakeNetwork = FakeNetwork(), drain: Duration = .milliseconds(50), recheck: Duration = .seconds(3600), legacy: Bool = false) {
        self.network = network
        self.drain = drain
        self.recheck = recheck
        self.legacy = legacy
    }

    func refuse(port: UInt16) { _ = state.withValue { $0.refusedPorts.insert(port) } }
    func allow(port: UInt16) { _ = state.withValue { $0.refusedPorts.remove(port) } }
    func refuse(host: String) { _ = state.withValue { $0.refusedHosts.insert(host) } }
    func allow(host: String) { _ = state.withValue { $0.refusedHosts.remove(host) } }
    func name(_ host: String, is port: UInt16) { state.withValue { $0.names[host] = port } }
    var tried: [FleetRoute] { state.current.tried }

    var options: SessionServer.FleetLinkOptions {
        let dialing = dialing, legacy = legacy
        return SessionServer.FleetLinkOptions(network: network.network, dialer: { [state] client, route, token, peer, clientName in
            await dialing.pass()
            let port: UInt16? = state.withValue { state in
                state.tried.append(route)
                if state.refusedHosts.contains(route.host) || state.refusedPorts.contains(route.port) { return nil }
                return state.names[route.host] ?? route.port
            }
            guard let port else { throw RemoteHostClientError.rejected(code: "unreachable", message: "No route to \(route.host).") }
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: clientName,
                                         capabilities: legacy ? [] : RemoteProtocol.fleetLinkClientCapabilities, expectingHostID: peer, fetchesState: false)
        }, drainGrace: drain, recheckInterval: recheck, networkSettle: .milliseconds(10), predatesLinks: legacy)
    }
}

/// Fleet links that work in one direction, and routes: two scratch hosts where one can't dial the other, a pair that both dial, a
/// Mac whose address changes, and a Mac from before links. Each test says what it proves.
@Suite("Fleet links", .mainActorExclusive)
@MainActor
struct FleetLinkTests {
    typealias Mac = FleetDispatchTests.Mac

    // MARK: Fixtures

    /// Two Macs that share an origin, each reaching the others as its routing says. Not paired yet.
    static func macs(_ a: LinkRouting = LinkRouting(), _ b: LinkRouting = LinkRouting(), gateA: FleetTestGate? = nil, gateB: FleetTestGate? = nil)
        async throws -> (a: Mac, b: Mac, origin: FleetDispatchTests.Origin) {
        try StubPi.installAsEngine()
        let origin = try FleetDispatchTests.makeOrigin(extra: [".gitignore": FleetSnapshotTransferTests.ignores, "src/app.ts": "export const app = 1\n"])
        let a = try await Mac("MacBook Pro", origin: origin, links: a.options, gate: gateA)
        let b = try await Mac("Mac mini", origin: origin, links: b.options, gate: gateB)
        return (a, b, origin)
    }

    /// Settings sync both ways: an edit on each Mac reaches the other.
    static func syncBothWays(_ a: Mac, _ b: Mac) async throws {
        _ = try await a.local.instructions(.save(file: .agents, content: "# From the MacBook\n", origin: "", sync: false))
        try await FleetDispatchTests.wait("\(b.name) to read what \(a.name) saved") { b.server.instructions.content(.agents) == "# From the MacBook\n" }
        _ = try await b.local.instructions(.save(file: .appendSystem, content: "From the mini.", origin: "", sync: false))
        try await FleetDispatchTests.wait("\(a.name) to read what \(b.name) saved") { a.server.instructions.content(.appendSystem) == "From the mini." }
    }

    /// A thread on `from` sends work to `to`; it runs there, settles, and its result goes back to the parent.
    static func dispatchAndResult(from: Mac, to: Mac, key: String) async throws {
        let parent = try await from.parent()
        try parent.hello()
        _ = try parent.info(try await parent.dispatch("Fix the flaky payment test.", key: key, title: "Fix flaky payment test", host: to.name))
        try await FleetDispatchTests.wait("\(to.name) to run the dispatched thread") { to.dispatched.count == 1 }
        let thread = try #require(to.dispatched.first)
        try await FleetDispatchTests.wait("\(from.name) to follow the dispatch as running") { from.sent().first?.state == .running && to.taken().first?.state == .running }
        try to.report(thread.id, .working)
        try await FleetDispatchTests.wait("\(to.name) to see the thread working") {
            to.server.queue.sync { to.server.fleet?.dispatch.inbound.values.first?.startedWorking } == true
        }
        try to.report(thread.id, .done)
        let result = try #require(await parent.nextMessage())
        #expect(result.text.contains("Result from Fix flaky payment test on \(to.name):"), "the result came back to \(from.name)'s thread")
        try await FleetDispatchTests.wait("both records to finish") { from.sent().first?.state == .done && to.taken().first?.state == .done }
    }

    static func link(_ mac: Mac, to other: Mac) async throws -> (route: FleetRoute?, viaItsLink: Bool) {
        let id = try await other.hostID()
        return try #require(mac.server.queue.sync { mac.server.fleet?.linkRoute(id) })
    }

    static func peerStatus(_ mac: Mac, _ other: Mac) async throws -> FleetPeerStatus {
        try await peerStatus(mac, id: try await other.hostID())
    }

    static func peerStatus(_ mac: Mac, id: UUID) async throws -> FleetPeerStatus {
        try #require(try await mac.local.fleetRead().snapshot.peers.first { $0.hostID == id })
    }

    // MARK: One connection, one direction

    /// The VLAN case: the Mac mini can reach nobody at the MacBook's addresses, the MacBook reaches the mini. Everything the mini sends
    /// goes back over the connection the MacBook opened.
    @Test func aLinkWorksInBothDirectionsWhenOnlyOneMacCanDial() async throws {
        let (blocked, open) = (LinkRouting(), LinkRouting())
        let (a, b, _) = try await Self.macs(open, blocked)
        defer { a.stop(); b.stop() }
        blocked.refuse(port: a.port)
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)

        // Pressure and readiness came both ways: each Mac holds the other's report.
        let mini = try await Self.peerStatus(a, b), book = try await Self.peerStatus(b, a)
        #expect(mini.link == .connected && book.link == .connected)
        // The page says how: the MacBook over its own connection to the mini's address, the mini over the MacBook's link.
        #expect(mini.reach == FleetPeerReach(host: "127.0.0.1", kind: .lan, viaItsLink: false))
        #expect(book.reach == FleetPeerReach(host: nil, kind: nil, viaItsLink: true))
        let aID = try await a.hostID()
        #expect(b.server.queue.sync { b.server.fleet?.holdsOwnConnection(to: aID) } == false, "the mini never held a connection of its own")

        // Sync both ways.
        try await Self.syncBothWays(a, b)
        // A dispatch each way, with its result: the mini's create and result ride the MacBook's connection.
        try await Self.dispatchAndResult(from: a, to: b, key: "to-the-mini")
        try await Self.dispatchAndResult(from: b, to: a, key: "to-the-macbook")
        #expect(try await Self.peerStatus(b, a).reach?.viaItsLink == true, "still one connection, never a second")
    }

    /// A snapshot and its contents (a 300 KB file goes in two pushes) from the Mac that can't dial, to the one that can.
    @Test func aSnapshotAndItsBlobsTravelOverTheLinkTheOtherMacOpened() async throws {
        let (blocked, open) = (LinkRouting(), LinkRouting())
        let (a, b, _) = try await Self.macs(open, blocked)
        defer { a.stop(); b.stop() }
        blocked.refuse(port: a.port)
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)

        try FleetSnapshotTransferTests.write("# acme-web\nedited on the mini\n", to: "README.md", in: b.folder)
        try FleetSnapshotTransferTests.write("take notes\n", to: "NOTES.md", in: b.folder)
        try FleetSnapshotTransferTests.write("API_KEY=made-up-value\n", to: ".env", in: b.folder)
        try FleetSnapshotTransferTests.writeBinary(300_000, to: "assets/logo.bin", in: b.folder)
        let expected = try FleetSnapshotTransferTests.tree(of: b.folder)

        let parent = try await b.parent()
        try parent.hello()
        _ = try await parent.dispatch("Fix the flaky payment test.", key: "snap", title: "Fix flaky payment test", host: "MacBook Pro")
        try await FleetDispatchTests.wait("the MacBook to run the dispatched thread", timeout: .seconds(60)) { !a.dispatched.isEmpty }
        let worktree = URL(fileURLWithPath: try #require(a.dispatched.first?.worktreePath))
        let built = try FleetSnapshotTransferTests.tree(of: worktree)
        #expect(built == expected, "the worktree is the mini's checkout, byte for byte; differs at \(FleetSnapshotTransferTests.difference(built, expected))")
        #expect(try await Self.link(b, to: a).viaItsLink, "the mini sent it over the MacBook's connection")
    }

    // MARK: Both dial

    /// Both Macs dial each other: one connection is kept, the lower id's, and the other closes. The link never goes down while that happens.
    @Test func whenBothMacsDialTheLowerIdsConnectionIsKeptAndTheOtherCloses() async throws {
        let (a, b, _) = try await Self.macs()
        defer { a.stop(); b.stop() }
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())
        let (lower, higher) = aID.uuidString < bID.uuidString ? (a, b) : (b, a)
        let (lowerID, higherID) = aID.uuidString < bID.uuidString ? (aID, bID) : (bID, aID)

        // The higher id's own connection closes once nothing is in flight on it: one connection is left, the lower's, and each Mac's
        // link says so.
        try await FleetDispatchTests.wait("the higher id's connection to close") {
            higher.server.queue.sync { higher.server.fleet?.holdsOwnConnection(to: lowerID) } == false
                && lower.server.queue.sync { lower.server.fleet?.connectionCount(from: higherID) } == 0
        }
        let (keptByLower, keptByHigher) = (try await Self.link(lower, to: higher), try await Self.link(higher, to: lower))
        #expect(!keptByLower.viaItsLink && keptByHigher.viaItsLink)
        #expect(lower.server.queue.sync { lower.server.fleet?.holdsOwnConnection(to: higherID) } == true)
        #expect(higher.server.queue.sync { higher.server.fleet?.connectionCount(from: lowerID) } == 1)
        // Nothing dropped on the way: neither Mac saw the other go.
        for (mac, other) in [(a, b), (b, a)] {
            let status = try await Self.peerStatus(mac, other)
            #expect(status.link == .connected && status.lastSeen == nil, "\(mac.name) never lost the link")
        }
        // And it works: both ways, over the one connection.
        try await Self.syncBothWays(a, b)
        try await Self.dispatchAndResult(from: higher, to: lower, key: "up")
    }

    /// The Mac that loses holds a request in flight on its own connection while the other Mac's connection comes up: the request is
    /// answered, and only then does that connection close.
    @Test func aRequestInFlightOnTheConnectionThatLosesIsAnsweredBeforeItCloses() async throws {
        let (routingA, routingB) = (LinkRouting(), LinkRouting())
        let (gateA, gateB) = (FleetTestGate(), FleetTestGate())
        let (a, b, _) = try await Self.macs(routingA, routingB, gateA: gateA, gateB: gateB)
        defer { a.stop(); b.stop() }
        let (aID, bID) = (try await a.hostID(), try await b.hostID())
        let aIsLower = aID.uuidString < bID.uuidString
        let (lower, higher, lowerID, higherID) = aIsLower ? (a, b, aID, bID) : (b, a, bID, aID)
        let (lowerRouting, lowerGate) = aIsLower ? (routingA, gateA) : (routingB, gateB)

        // The lower id doesn't dial yet, so the higher id's connection is the only one.
        await lowerRouting.dialing.close()
        try await a.pair(with: b)
        try await FleetDispatchTests.wait("the higher id's connection to carry the link") {
            higher.server.queue.sync { higher.server.fleet?.holdsOwnConnection(to: lowerID) } == true
                && lower.server.queue.sync { lower.server.fleet?.holdsConnection(from: higherID) } == true
        }
        try await FleetDispatchTests.waitForReports(a, b)
        let client = try #require(higher.server.queue.sync { higher.server.fleet?.channel(to: lowerID) })

        // A request in flight on it: the lower id's reading is held back.
        await lowerGate.close()
        let call = Task { try await client.fleetPressureNow() }
        try await FleetDispatchTests.wait("the request to reach the lower id") { await lowerGate.waiting >= 1 }

        // The lower id's own connection comes up: the link moves to it, and the higher id's stays open for the request.
        await lowerRouting.dialing.open()
        try await FleetDispatchTests.wait("the link to move to the lower id's connection") {
            higher.server.queue.sync { higher.server.fleet?.linkRoute(lowerID)?.viaItsLink } == true
        }
        #expect(higher.server.queue.sync { higher.server.fleet?.holdsOwnConnection(to: lowerID) } == true, "closed with a request in flight")

        await lowerGate.open()
        let answer = try await call.value
        #expect(answer.sample.cpuCount > 0, "the request was answered, not lost")
        try await FleetDispatchTests.wait("the higher id's connection to close") {
            higher.server.queue.sync { higher.server.fleet?.holdsOwnConnection(to: lowerID) } == false
                && lower.server.queue.sync { lower.server.fleet?.connectionCount(from: higherID) } == 0
        }
        let (higherSees, lowerSees) = (try await Self.peerStatus(higher, lower), try await Self.peerStatus(lower, higher))
        #expect(higherSees.lastSeen == nil && lowerSees.lastSeen == nil, "the link never dropped")
        try await Self.syncBothWays(a, b)
    }

    // MARK: Routes

    static let lan = FleetReportedRoute(host: "10.77.20.10", kind: .lan)
    static let name = FleetReportedRoute(host: "mac-mini.local", kind: .hostname)

    /// The routes a Mac keeps of another, in order: what it was given, then what the Mac reported.
    static func routes(_ mac: Mac, of other: Mac) async throws -> [FleetRoute] {
        let id = try await other.hostID()
        return mac.server.queue.sync { mac.server.fleet?.routes(of: id) } ?? []
    }

    /// A Mac reports every address and name it has while linked, and again when they change; the other keeps them as learned routes,
    /// in the file too, and drops the one the Mac stops reporting.
    @Test func aMacReportsItsRoutesWhileLinkedAndAgainWhenTheyChange() async throws {
        let (reporting, quiet) = (LinkRouting(network: FakeNetwork([Self.lan, Self.name])), LinkRouting())
        let (a, b, _) = try await Self.macs(reporting, quiet)
        defer { a.stop(); b.stop() }
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)

        // B holds A's routes after the address it was given.
        try await FleetDispatchTests.wait("the MacBook's routes to reach the mini") {
            try await Self.routes(b, of: a).map(\.host) == ["127.0.0.1", "10.77.20.10", "mac-mini.local"]
        }
        let held = try await Self.routes(b, of: a)
        #expect(held.map(\.learned) == [false, true, true] && held.map(\.kind) == [.lan, .lan, .hostname])
        #expect(held.allSatisfy { $0.port == a.port })
        // And in peers.json, where they survive a restart (`learned` decodes to nothing in a file from before).
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: b.peersFile)) as? [String: Any])
        let record = try #require((file["peers"] as? [[String: Any]])?.first)
        #expect((record["learned"] as? [[String: Any]])?.compactMap { $0["host"] as? String } == ["10.77.20.10", "mac-mini.local"])

        // Its address changes: the new one replaces the old, the name stays.
        reporting.network.change([FleetReportedRoute(host: "10.77.30.7", kind: .lan), Self.name])
        try await FleetDispatchTests.wait("the new address to reach the mini") {
            try await Self.routes(b, of: a).map(\.host) == ["127.0.0.1", "10.77.30.7", "mac-mini.local"]
        }
        // The Mac that was reported to reports nothing: A learns nothing of B (the network reports no routes).
        #expect(try await Self.routes(a, of: b).map(\.learned) == [false])
    }

    /// What a test of a link that fell back to a name holds: the MacBook (restarted on the address it had) and the mini, which dials.
    struct Fallback {
        var a: Mac
        var b: Mac
        var finding: LinkRouting
        func stop() { a.stop(); b.stop() }
    }

    /// The mini reaches the MacBook only by dialing (the MacBook's own dialing is refused). The MacBook goes away and comes back; of the
    /// routes the mini holds for it, the two before its name no longer answer, so the link falls back to the name.
    static func fallBack(recheck: Duration) async throws -> Fallback {
        let (reporting, finding) = (LinkRouting(network: FakeNetwork([lan, name])), LinkRouting(recheck: recheck))
        let (a, b, origin) = try await macs(reporting, finding)
        var running = [a, b]
        do {
            reporting.refuse(port: b.port)
            try await a.pair(with: b)
            try await FleetDispatchTests.waitForReports(a, b)
            try await FleetDispatchTests.wait("the routes to reach the mini") { try await routes(b, of: a).count == 3 }
            #expect(try await link(b, to: a).route?.host == "127.0.0.1")

            finding.refuse(host: "127.0.0.1")
            finding.refuse(host: "10.77.20.10")
            finding.name("mac-mini.local", is: a.port)
            let (dir, port, aID) = (a.host.dir, a.port, try await a.hostID())
            a.stop(keepFiles: true)
            running = [b]
            try await FleetDispatchTests.wait("the link to the MacBook to drop") { try await peerStatus(b, id: aID).link != .connected }
            let back = try await Mac("MacBook Pro", origin: origin, dir: dir, port: port, links: reporting.options)
            running.append(back)
            try await FleetDispatchTests.wait("the mini to find the MacBook again") { try await peerStatus(b, back).link == .connected }
            return Fallback(a: back, b: b, finding: finding)
        } catch {
            for mac in running { mac.stop() }
            throw error
        }
    }

    /// A Mac's address changes while it is away (it comes back on another): the other Mac finds it again by a name it reported, tried
    /// after the address that no longer answers.
    @Test func aMacWhoseAddressChangedIsFoundAgainByARouteItReported() async throws {
        let fallback = try await Self.fallBack(recheck: .seconds(3600))
        defer { fallback.stop() }
        let found = try await Self.link(fallback.b, to: fallback.a)
        #expect(found.route?.host == "mac-mini.local" && found.route?.kind == .hostname && found.viaItsLink == false)
        let hosts = fallback.finding.tried.map(\.host)
        let address = try #require(hosts.lastIndex(of: "10.77.20.10")), name = try #require(hosts.lastIndex(of: "mac-mini.local"))
        #expect(address < name, "it tried the address that no longer answers before the name")
    }

    /// While the link is on a later route, the earlier ones are looked at again when the network changes (the timer is an hour here) and
    /// the link moves back to the first that answers. The connection it leaves closes once nothing is in flight on it, and nothing drops.
    @Test func aLinkOnALaterRouteMovesBackWhenANetworkChangeLetsAnEarlierOneAnswer() async throws {
        let fallback = try await Self.fallBack(recheck: .seconds(3600))
        defer { fallback.stop() }
        let (a, b) = (fallback.a, fallback.b)
        let bID = try await b.hostID()
        fallback.finding.allow(host: "127.0.0.1")
        fallback.finding.network.fire()
        try await FleetDispatchTests.wait("the link to move back to the first route") { try await Self.link(b, to: a).route?.host == "127.0.0.1" }
        try await FleetDispatchTests.wait("the connection it left to close") { a.server.queue.sync { a.server.fleet?.connectionCount(from: bID) } == 1 }
        let after = try await Self.peerStatus(b, a)
        #expect(after.lastSeen == nil && after.link == .connected, "the move dropped nothing")
        try await Self.syncBothWays(a, b)
    }

    /// The same without a network change: the earlier routes are tried again on a timer (every 60 s; 100 ms here).
    @Test func aLinkOnALaterRouteMovesBackOnItsTimerToo() async throws {
        let fallback = try await Self.fallBack(recheck: .milliseconds(100))
        defer { fallback.stop() }
        let (a, b) = (fallback.a, fallback.b)
        fallback.finding.allow(host: "127.0.0.1")
        try await FleetDispatchTests.wait("the link to move back to the first route") { try await Self.link(b, to: a).route?.host == "127.0.0.1" }
        #expect(try await Self.peerStatus(b, a).link == .connected)
    }

    // MARK: Compatibility

    /// A Mac from before links neither lists the capability nor takes calls over a connection, and reports no routes: the new Mac keeps its
    /// old behavior with it. Each pushes over its own connection, nothing is sent that the old Mac does not know, and everything works.
    @Test func aMacFromBeforeLinksPairsAndLinksAsItAlwaysDid() async throws {
        let (new, old) = (LinkRouting(network: FakeNetwork([Self.lan, Self.name])), LinkRouting(network: FakeNetwork([Self.lan, Self.name]), legacy: true))
        let (a, b, _) = try await Self.macs(new, old)
        defer { a.stop(); b.stop() }
        b.server.advertisedCapabilities.removeAll { $0 == RemoteProtocol.fleetLinkCapability }
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())

        // Two connections, each Mac's own; neither is sent a call over a connection it opened, or a report of routes.
        try await FleetDispatchTests.wait("each Mac to hold its own connection") {
            a.server.queue.sync { a.server.fleet?.holdsOwnConnection(to: bID) } == true && b.server.queue.sync { b.server.fleet?.holdsOwnConnection(to: aID) } == true
        }
        #expect(a.server.queue.sync { a.server.fleet?.connectionCount(from: bID) } == 0, "the old Mac's connection can't carry calls")
        let (aVia, bVia) = (try await Self.link(a, to: b), try await Self.link(b, to: a))
        #expect(!aVia.viaItsLink && !bVia.viaItsLink)
        let (aHolds, bHolds) = (try await Self.routes(a, of: b), try await Self.routes(b, of: a))
        #expect(aHolds.allSatisfy { !$0.learned } && bHolds.allSatisfy { !$0.learned }, "no routes were exchanged")
        let reach = try await Self.peerStatus(a, b).reach
        #expect(reach?.host == "127.0.0.1" && reach?.viaItsLink == false)

        try await Self.syncBothWays(a, b)
        try await Self.dispatchAndResult(from: a, to: b, key: "to-the-old-one")
        try await Self.dispatchAndResult(from: b, to: a, key: "from-the-old-one")
        // The old Mac's connection stayed: nothing closed a link it relies on.
        let (bSees, aSees) = (try await Self.peerStatus(b, a), try await Self.peerStatus(a, b))
        #expect(bSees.link == .connected && aSees.lastSeen == nil)
    }

    /// A host that is not this build, as the wire shows it: it answers `hello` without `fleet.link.v1`, and records every request it is
    /// sent. A Mac that links to it pushes over its own connection as it always did, and is never sent a request that host doesn't know.
    @Test func aHostThatDoesNotOfferLinksIsSentNothingItDoesNotKnow() async throws {
        let (oldID, oldToken) = (UUID(), FleetProtocol.makeToken())
        let heard = Locked<[(type: String, capabilities: [String]?)]>([])
        let presented = Locked<String?>(nil)
        let offered = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.fleetLinkCapability }
        let oldHost = try LoopbackServer { fd in
            func reply(_ reply: RemoteReply) { LoopbackServer.writeAll(fd, (try? NDJSON.encode(reply)) ?? Data()) }
            while let line = FleetPairingTests.readLine(fd) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String,
                      let request = try? NDJSON.decode(RemoteRequest.self, from: line) else { continue }
                heard.withValue { $0.append((type, object["capabilities"] as? [String])) }
                switch request {
                case .fleetIdentify(let id): reply(.fleetIdentity(id: id, hostID: oldID, name: "Mac mini", build: "old", fleetEnabled: true))
                case .fleetPair(let id, _, let from):
                    presented.withValue { $0 = from.myTokenHash }
                    reply(.fleetPaired(id: id, hostID: oldID, name: "Mac mini", myTokenHash: FleetProtocol.hash(oldToken)))
                case .hello(let id, let token, _, _, _):
                    guard FleetProtocol.hash(token) == presented.current else { return reply(.error(id: id, code: RemoteProtocol.unauthorizedCode, message: "bad token")) }
                    reply(.helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: offered, hostBuild: "old", hostID: oldID))
                case .fleetPressure(let id, _), .fleetReadiness(let id, _): reply(.ok(id: id))
                default: reply(.error(id: 0, code: "unsupported", message: "The host does not take this request."))
                }
            }
        }
        defer { oldHost.stop() }
        let a = try await FleetPairingTests.Mac("MacBook Pro")
        defer { a.stop() }

        _ = try await a.local.fleetAction(.pair(host: "127.0.0.1", port: oldHost.port, code: "482913"))
        try await FleetDispatchTests.wait("the old host to be pushed A's load") { heard.current.contains { $0.type == "fleetPressure" } }
        let peers = try await a.peers()
        #expect(peers.first?.link == .connected && peers.first?.reach == FleetPeerReach(host: "127.0.0.1", kind: .lan, viaItsLink: false))

        // It was told what it always was, and said hello with what a Mac that links lists; no report of routes, no answer to a call.
        let kinds = Set(heard.current.map(\.type))
        #expect(kinds.isSuperset(of: ["fleetIdentify", "fleetPair", "hello", "fleetPressure"]))
        #expect(kinds.isDisjoint(with: ["fleetRoutes", "fleetPeerAnswer"]), "sent \(kinds)")
        #expect(heard.current.first { $0.type == "hello" }?.capabilities == RemoteProtocol.fleetLinkClientCapabilities)
        let record = try a.record(of: "Mac mini")
        #expect(record["learned"] == nil || (record["learned"] as? [Any])?.isEmpty == true)
    }

    /// Reporting routes and answering calls are a member's: a client on the shared token is refused, and a report that no Mac could have
    /// made is refused by the Mac that would keep it.
    @Test func aRoutesReportIsAMembersAndMustBeWellFormed() async throws {
        let (a, b, _) = try await Self.macs()
        defer { a.stop(); b.stop() }
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)

        let shared = RemoteHostClient()
        _ = try await shared.connect(host: "127.0.0.1", port: b.port, token: b.token, clientName: "phone", fetchesState: false)
        defer { shared.disconnect() }
        do { try await shared.fleetRoutes(FleetRouteReport(port: 7434, routes: [Self.lan])); Issue.record("a client on the shared token reported routes") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }

        // A Mac's own connection to the mini, as the MacBook's host makes it.
        let peer = try await b.connectAsPeer(a)
        defer { peer.disconnect() }
        for bad in [FleetRouteReport(port: 0, routes: [Self.lan]), FleetRouteReport(port: 7434, routes: [FleetReportedRoute(host: "10.0.0.1/evil", kind: .lan)]),
                    FleetRouteReport(port: 7434, routes: Array(repeating: Self.lan, count: FleetRouteReport.maxRoutes + 1))] {
            do { try await peer.fleetRoutes(bad); Issue.record("a malformed report was taken: \(bad)") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.invalid) }
        }
        try await peer.fleetRoutes(FleetRouteReport(port: 7434, routes: [Self.lan]))
        #expect(try await Self.routes(b, of: a).map(\.host).contains("10.77.20.10"), "a well formed one is kept")
    }
}
