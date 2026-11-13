import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The rules of the iCloud rendezvous that need no host: how a code becomes a record name, the order of writes and what a failure says.
/// A recording store stands in for CloudKit.
@Suite("Fleet rendezvous")
struct FleetRendezvousUnitTests {
    actor Log {
        var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }

    struct Store: FleetRendezvousStore {
        var log = Log()
        var held: [FleetRendezvousKey: FleetRendezvousRecord] = [:]
        var failure: FleetRendezvousError?
        /// A put takes a moment, so a delete asked after it would overtake it without the queue.
        var slowPut = false

        func put(_ record: FleetRendezvousRecord) async throws {
            if let failure { throw failure }
            if slowPut { try? await Task.sleep(for: .milliseconds(50)) }
            await log.add("put")
        }
        func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord? {
            if let failure { throw failure }
            return held[key]
        }
        func delete(_ key: FleetRendezvousKey) async throws {
            if let failure { throw failure }
            await log.add("delete")
        }
    }

    @Test func aCodeBecomesTheSameRecordNameOnEveryMacAndTheNameHoldsNoDigitsOfIt() {
        let key = FleetRendezvousKey.join(code: "482913")
        #expect(key == .join(code: "482 913") && key == .join(code: "482-913"), "what a person types between digits doesn't count")
        #expect(key != .join(code: "482914"))
        #expect(key.kind == .join && key.name.hasPrefix("join-") && key.name.count == "join-".count + 64)
        #expect(!key.name.contains("482913"))
        let id = UUID(uuidString: "B6A3C0C8-6E2D-4B9B-9F7C-1D2E3F4A5B6C")!
        #expect(FleetRendezvousKey.presence(of: id).name == "presence-b6a3c0c8-6e2d-4b9b-9f7c-1d2e3f4a5b6c")
        #expect(FleetRendezvousKey.presence(of: id).kind == .presence)
    }

    @Test func aRecordExpiresWithItsCodeAndOneWithoutAnExpiryNever() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        func record(_ expiresAt: Double?) -> FleetRendezvousRecord {
            FleetRendezvousRecord(key: .join(code: "482913"), hostID: UUID(), routes: [], expiresAt: expiresAt, updatedAt: 0)
        }
        #expect(!record(now.timeIntervalSince1970 * 1000 + 1).isExpired(at: now))
        #expect(record(now.timeIntervalSince1970 * 1000).isExpired(at: now))
        #expect(!record(nil).isExpired(at: now.addingTimeInterval(86_400 * 365)))
    }

    @Test func writesRunInTheOrderTheyWereAsked() async {
        let store = Store(slowPut: true)
        let rendezvous = FleetRendezvous(store: store)
        // A code shown and cancelled at once: the delete must not land before the write it undoes.
        rendezvous.put(FleetRendezvousRecord(key: .join(code: "482913"), hostID: UUID(), routes: [], updatedAt: 0))
        rendezvous.delete(.join(code: "482913"))
        await rendezvous.settle()
        #expect(await store.log.entries == ["put", "delete"])
    }

    @Test func aFailureIsLoggedOnceWhateverItWasAndNeverThrown() async {
        let rendezvous = FleetRendezvous(store: Store(failure: .noAccount))
        for _ in 0..<3 {
            rendezvous.put(FleetRendezvousRecord(key: .presence(of: UUID()), hostID: UUID(), routes: [], updatedAt: 0))
            rendezvous.delete(.join(code: "482913"))
        }
        await rendezvous.settle()
        #expect(await rendezvous.lookupPresence(of: UUID()) == nil)
        #expect(await rendezvous.lookupJoin(code: "482913") == .unavailable(.noAccount))
        #expect(rendezvous.warnings == 1)
    }

    @Test func anErrorThatIsNotOursCountsAsUnavailable() async {
        struct Odd: Error {}
        struct Broken: FleetRendezvousStore {
            func put(_ record: FleetRendezvousRecord) async throws { throw Odd() }
            func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord? { throw Odd() }
            func delete(_ key: FleetRendezvousKey) async throws { throw Odd() }
        }
        #expect(await FleetRendezvous(store: Broken()).lookupJoin(code: "482913") == .unavailable(.unavailable))
    }

    @Test func aLookupFindsNothingForACodeNobodyShowsAndDropsAnExpiredRecord() async {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let key = FleetRendezvousKey.join(code: "482913")
        let stale = FleetRendezvousRecord(key: key, hostID: UUID(), routes: [FleetRoute(host: "10.0.0.2", port: 7434, kind: .lan, learned: false)],
                                          expiresAt: now.timeIntervalSince1970 * 1000 - 1, updatedAt: 0)
        let live = FleetRendezvousRecord(key: key, hostID: UUID(), routes: [FleetRoute(host: "10.0.0.2", port: 7434, kind: .lan, learned: false)],
                                         expiresAt: now.timeIntervalSince1970 * 1000 + 1, updatedAt: 0)
        let store = Store(held: [key: stale])
        let rendezvous = FleetRendezvous(store: store)
        #expect(await rendezvous.lookupJoin(code: "000000", now: now) == .notFound)
        #expect(await rendezvous.lookupJoin(code: "482913", now: now) == .notFound)
        await rendezvous.settle()
        #expect(await store.log.entries == ["delete"], "the expired one was cleaned up")
        #expect(await FleetRendezvous(store: Store(held: [key: live])).lookupJoin(code: "482913", now: now) == .found(live))
    }

    @Test func theCodesAndTheCapabilityAreStable() {
        #expect(FleetProtocol.Code.notFound == "not_found" && FleetProtocol.Code.icloudUnavailable == "icloud_unavailable")
        #expect(RemoteProtocol.fleetRendezvousCapability == "fleet.rendezvous.v1")
        #expect(RemoteProtocol.fleetMemberCapabilities.contains(RemoteProtocol.fleetRendezvousCapability))
        #expect(!FleetAccess.device.isOffered(RemoteProtocol.fleetRendezvousCapability), "a client device never takes part")
    }
}
