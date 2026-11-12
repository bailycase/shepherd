import Foundation
import Testing
@testable import ShepherdProtocol

@Suite("Fleet wire")
struct FleetWireTests {
    @Test func aTokenHashIsItsHexSHA256() {
        // sha256("abc")
        #expect(FleetProtocol.hash("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func tokensAreLongRandomHex() {
        let first = FleetProtocol.makeToken(), second = FleetProtocol.makeToken()
        #expect(first.count == 64 && first.allSatisfy(\.isHexDigit))
        #expect(first != second)
    }

    /// Bonjour carries a hash of the id, never the id: a Mac that finds its own entry can tell.
    @Test func theAdvertisedIDIsAHashOfTheHostID() {
        let id = UUID()
        let hash = FleetProtocol.advertisedIDHash(id)
        #expect(hash.count == 16 && !hash.contains(id.uuidString.lowercased().prefix(8)))
        #expect(hash == FleetProtocol.advertisedIDHash(id))
        #expect(hash != FleetProtocol.advertisedIDHash(UUID()))
    }

    @Test func aSnapshotOfAnOffFleetRoundTripsEmpty() throws {
        let snapshot = FleetSnapshot()
        #expect(!snapshot.enabled && snapshot.peers.isEmpty && snapshot.join == nil)
        #expect(try Wire.roundTrip(snapshot) == snapshot)
    }

    /// The code itself rides only the reply to the action that opened the window; the snapshot
    /// every client reads carries its expiry and tries left, never the code.
    @Test func aJoinStatusHoldsNoCode() throws {
        let object = try Wire.object(FleetJoinStatus(expiresAt: 5, attemptsLeft: 3))
        #expect(Set(object.keys) == ["expiresAt", "attemptsLeft"])
    }
}
