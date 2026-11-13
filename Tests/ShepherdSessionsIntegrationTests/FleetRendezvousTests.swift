import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Macs finding each other through the user's own iCloud, with a dictionary standing in for CloudKit and real scratch hosts
/// on both ends. The real CloudKit path (`FleetCloudKitStore`) is not exercised here: it needs the container and a
/// provisioning profile.
final class FakeCloud: FleetRendezvousStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FleetRendezvousKey: FleetRendezvousRecord] = [:]
    private var failure: FleetRendezvousError?
    private(set) var operations: [String] = []

    init(failing: FleetRendezvousError? = nil) { failure = failing }

    func put(_ record: FleetRendezvousRecord) async throws {
        try lock.withLock {
            operations.append("put \(record.key.kind.rawValue)")
            if let failure { throw failure }
            stored[record.key] = record
        }
    }

    func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord? {
        try lock.withLock {
            if let failure { throw failure }
            return stored[key]
        }
    }

    func delete(_ key: FleetRendezvousKey) async throws {
        try lock.withLock {
            operations.append("delete \(key.kind.rawValue)")
            if let failure { throw failure }
            stored[key] = nil
        }
    }

    func records(_ kind: FleetRendezvousKey.Kind) -> [FleetRendezvousRecord] { lock.withLock { stored.values.filter { $0.key.kind == kind } } }
    func record(_ key: FleetRendezvousKey) -> FleetRendezvousRecord? { lock.withLock { stored[key] } }
    func plant(_ record: FleetRendezvousRecord) { lock.withLock { stored[record.key] = record } }
}

@Suite("Fleet iCloud rendezvous", .integrationTimeLimit)
struct FleetRendezvousTests {
    typealias Mac = FleetPairingTests.Mac

    /// A host that shares `cloud` and says its listener is at `127.0.0.1` (after `extra`, routes that lead nowhere).
    static func mac(_ name: String, cloud: FleetRendezvousStore, extra: [FleetAddress] = [], dir: URL? = nil, joinLifetime: TimeInterval? = nil,
                    fleet: Bool = true) async throws -> Mac {
        try await Mac(name, dir: dir, fleet: fleet) {
            $0.configureFleetRendezvous(store: cloud, routes: { port in extra + [FleetAddress(host: "127.0.0.1", port: port)] },
                                        joinLifetime: joinLifetime, lookupInterval: 0)
        }
    }

    static func findAndPair(_ mac: Mac, code: String) async throws -> FleetPeerStatus {
        try #require(try await mac.local.fleetAction(.findAndPair(code: code)).paired)
    }

    /// The code is refused with this error code and message.
    static func refusal(_ body: () async throws -> Void) async -> (code: String, message: String)? {
        do { try await body() } catch RemoteHostClientError.rejected(let code, let message) { return (code, message) } catch { return nil }
        return nil
    }

    // MARK: Join records

    @Test func aShownCodeWritesARecordThatNeverHoldsTheCodeAndTheUseOfItDeletesIt() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        defer { a.stop(); b.stop() }

        let code = try await b.startJoin()
        try await eventually("the Join record to be written") { !cloud.records(.join).isEmpty }
        let record = try #require(cloud.records(.join).first)
        #expect(cloud.records(.join).count == 1)
        #expect(record.key == FleetRendezvousKey.join(code: code))
        #expect(!"\(record)".contains(code), "the code is in no field, nor in the record's name")
        let bID = try await b.read().hostID
        #expect(record.hostID == bID && record.name == "Mac mini" && record.port == b.port)
        #expect(record.routes == [FleetAddress(host: "127.0.0.1", port: b.port)])
        let expiresAt = try #require(record.expiresAt)
        #expect(abs(expiresAt - (Date().timeIntervalSince1970 + FleetProtocol.codeLifetime) * 1000) < 30_000)

        // Typed on the other Mac, with nothing found by Bonjour and no address: the record says where.
        let paired = try await Self.findAndPair(a, code: code)
        #expect(paired.name == "Mac mini")
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        try await eventually("the used code's record to be deleted") { cloud.records(.join).isEmpty }
    }

    @Test func routesAreTriedInOrderAndOneThatDoesNotAnswerIsSkipped() async throws {
        let cloud = FakeCloud()
        // Nothing listens on port 1: the first route is refused, the second is the Mac.
        let a = try await Self.mac("MacBook Pro", cloud: cloud)
        let b = try await Self.mac("Mac mini", cloud: cloud, extra: [FleetAddress(host: "127.0.0.1", port: 1)])
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        try await eventually("the Join record") { !cloud.records(.join).isEmpty }
        #expect(try #require(cloud.records(.join).first).routes.count == 2)
        _ = try await Self.findAndPair(a, code: code)
        try await a.waitForLink(to: b)
        #expect(try await a.read().peers.first?.port == b.port, "the route that answered is where it is reached")
    }

    @Test func aWrongCodeFindsNothingAndTouchesNoMac() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        try await eventually("the Join record") { !cloud.records(.join).isEmpty }
        let wrong = code == "000000" ? "111111" : "000000"

        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: wrong) }
        #expect(refused?.code == FleetProtocol.Code.notFound)
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty)
        #expect(try await b.read().join?.attemptsLeft == FleetProtocol.maxCodeAttempts, "no try was spent on the Mac showing the code")
    }

    @Test func aRecordWhoseCodeDoesNotVerifyPairsNothing() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        defer { a.stop(); b.stop() }
        _ = try await b.startJoin()
        // A record under another code that points at Mac mini: it says where, and nothing more.
        let forged = "246810"
        cloud.plant(FleetRendezvousRecord(key: .join(code: forged), hostID: try #require(try await b.read().hostID), name: "Mac mini", port: b.port,
                                          routes: [FleetAddress(host: "127.0.0.1", port: b.port)], expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000,
                                          updatedAt: 0))
        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: forged) }
        #expect(refused?.code == FleetProtocol.Code.badCode)
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty)
    }

    @Test func aRecordNamingAnotherMacThanTheOneAtTheRouteIsNotPaired() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        defer { a.stop(); b.stop() }
        let code = try await b.startJoin()
        // The record's host id isn't the Mac that answers at its route (a stale address another Mac now holds).
        cloud.plant(FleetRendezvousRecord(key: .join(code: code), hostID: UUID(), name: "Mac mini", port: b.port,
                                          routes: [FleetAddress(host: "127.0.0.1", port: b.port)], expiresAt: Date().timeIntervalSince1970 * 1000 + 60_000,
                                          updatedAt: 0))
        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: code) }
        #expect(refused != nil)
        let (aPeers, bPeers) = (try await a.peers(), try await b.peers())
        #expect(aPeers.isEmpty && bPeers.isEmpty)
        #expect(try await b.read().join?.attemptsLeft == FleetProtocol.maxCodeAttempts, "the code was never sent to it")
    }

    @Test func aCodeThatExpiresOrIsCancelledDeletesItsRecord() async throws {
        let cloud = FakeCloud()
        let b = try await Self.mac("Mac mini", cloud: cloud, joinLifetime: 0.3)
        defer { b.stop() }
        _ = try await b.startJoin()
        try await eventually("the Join record to be written") { !cloud.records(.join).isEmpty }
        try await eventually("the expired code's record to be deleted") { cloud.records(.join).isEmpty }
        #expect(try await b.read().join == nil)

        let c = try await Self.mac("Mac Studio", cloud: cloud)
        defer { c.stop() }
        _ = try await c.startJoin()
        try await eventually("the second Join record") { !cloud.records(.join).isEmpty }
        _ = try await c.local.fleetAction(.stopJoin)
        try await eventually("the cancelled code's record to be deleted") { cloud.records(.join).isEmpty }
    }

    @Test func aRecordLeftBehindPastItsExpiryFindsNothingAndIsRemoved() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud)
        defer { a.stop() }
        let key = FleetRendezvousKey.join(code: "135790")
        cloud.plant(FleetRendezvousRecord(key: key, hostID: UUID(), name: "Mac mini", port: 7434, routes: [FleetAddress(host: "127.0.0.1", port: 7434)],
                                          expiresAt: Date().timeIntervalSince1970 * 1000 - 1, updatedAt: 0))
        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: "135 790") }
        #expect(refused?.code == FleetProtocol.Code.notFound)
        try await eventually("the stale record to be deleted") { cloud.record(key) == nil }
    }

    // MARK: Presence

    @Test func aPeerThatLostTheRouteFindsTheMacAgainFromItsPresenceRecord() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        var restarted: Mac?
        defer { a.stop(); b.stop(); restarted?.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        let bID = try #require(try await b.read().hostID)
        try await eventually("both Macs' presence records") { cloud.records(.presence).count == 2 }
        #expect(cloud.record(.presence(of: bID))?.routes == [FleetAddress(host: "127.0.0.1", port: b.port)])
        #expect(cloud.record(.presence(of: bID))?.name == "", "nothing but where it is goes through iCloud")

        // Mac mini comes back somewhere else: Mac MacBook Pro's saved route is dead.
        let (dir, oldPort) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        try await eventually("the link to Mac mini to drop") { try await a.peers().first?.link != .connected }
        let back = try await Self.mac("Mac mini", cloud: cloud, dir: dir)
        restarted = back
        try #require(back.port != oldPort)
        #expect(try await a.read().peers.first?.port == oldPort)

        try await eventually("Mac mini's new presence record") { cloud.record(.presence(of: bID))?.routes.first?.port == back.port }
        try await a.waitForLink(to: back)
        #expect(try await a.read().peers.first?.port == back.port, "reached at the route its presence record named")
        #expect(try await a.peers().count == 1, "it is the same Mac: nothing paired again")
    }

    @Test func presenceIsRemovedWhenNoPeerIsLeft() async throws {
        let cloud = FakeCloud()
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        defer { a.stop(); b.stop() }
        #expect(cloud.records(.presence).isEmpty, "a Mac with no peer has nothing to be found by")
        try await a.pair(with: b, code: try await b.startJoin())
        try await eventually("a's presence record") { cloud.records(.presence).count == 2 }
        let bID = try #require(try await b.read().hostID)
        _ = try await a.local.fleetAction(.remove(hostID: bID))
        try await eventually("a's presence record to go") { cloud.records(.presence).count == 1 }
    }

    // MARK: No iCloud

    @Test(arguments: [FleetRendezvousError.noAccount, .unavailable])
    func withNoICloudEverythingElseWorksAndTheLookupSaysSo(failure: FleetRendezvousError) async throws {
        let cloud = FakeCloud(failing: failure)
        let a = try await Self.mac("MacBook Pro", cloud: cloud), b = try await Self.mac("Mac mini", cloud: cloud)
        defer { a.stop(); b.stop() }

        // A code is still shown and the ordinary pairing (Bonjour's or a link's address) still works: nothing is shown broken.
        let code = try await b.startJoin()
        #expect(try await b.read().join != nil)
        try await a.pair(with: b, code: code)
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        #expect(cloud.records(.join).isEmpty && cloud.records(.presence).isEmpty)

        // Looking a code up says why it can't, in the words of the other ways.
        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: "482913") }
        #expect(refused?.code == FleetProtocol.Code.icloudUnavailable)
        let expected = failure == .noAccount ? "Not signed in to iCloud: use a pairing link" : "iCloud isn't available on this Mac: use a pairing link"
        #expect(refused?.message == expected)
    }

    @Test func aBuildWithoutTheContainerLooksLikeNoICloud() async throws {
        let a = try await Self.mac("MacBook Pro", cloud: UnavailableFleetRendezvousStore())
        defer { a.stop() }
        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: "482913") }
        #expect(refused?.code == FleetProtocol.Code.icloudUnavailable)
        #expect(try await a.read().enabled, "Fleet itself is untouched")
    }

    @Test func aHostWithFleetOffRefusesTheLookup() async throws {
        let a = try await Self.mac("MacBook Pro", cloud: FakeCloud(), fleet: false)
        defer { a.stop() }
        let refused = await Self.refusal { _ = try await Self.findAndPair(a, code: "482913") }
        #expect(refused?.code == FleetProtocol.Code.off)
    }

    @Test func theCapabilityIsOfferedToTheAppOnlyWhileFleetIsOn() async throws {
        let on = try await Self.mac("MacBook Pro", cloud: FakeCloud()), off = try await Self.mac("Mac mini", cloud: FakeCloud(), fleet: false)
        defer { on.stop(); off.stop() }
        #expect(on.local.capabilities.contains(RemoteProtocol.fleetRendezvousCapability))
        #expect(!off.local.capabilities.contains(RemoteProtocol.fleetRendezvousCapability))
    }
}
