import Foundation
import Testing
@testable import ShepherdRemote

@Suite("Remote host records")
struct RemoteHostRecordTests {
    @Test(arguments: [
        ("  studio  ", " 10.0.0.2 ", " 7433 ", "studio", "10.0.0.2", UInt16(7433)),
        ("", "mac.local", "7434", "mac.local", "mac.local", UInt16(7434)),
        ("   ", "::1", "1", "::1", "::1", UInt16(1)),
    ] as [(String, String, String, String, String, UInt16)])
    func anEntryIsTrimmedAndAnEmptyNameFallsBackToTheAddress(
        name: String, address: String, port: String, expectedName: String, expectedAddress: String, expectedPort: UInt16
    ) throws {
        let entry = try RemoteHostEntry(name: name, address: address, port: port, token: " secret ")
        #expect(entry.name == expectedName)
        #expect(entry.address == expectedAddress)
        #expect(entry.port == expectedPort)
        #expect(entry.token == "secret")
    }

    @Test(arguments: [
        ("", "7433", RemoteHostEntry.Problem.address),
        ("my mac", "7433", .address),
        ("mac.local", "0", .port),
        ("mac.local", "65536", .port),
        ("mac.local", "port", .port),
        ("mac.local", "", .port),
    ] as [(String, String, RemoteHostEntry.Problem)])
    func anEntryWithABadAddressOrPortIsRefused(address: String, port: String, problem: RemoteHostEntry.Problem) {
        #expect(throws: problem) { try RemoteHostEntry(name: "", address: address, port: port, token: "t") }
    }

    @Test(arguments: [nil, "", "   "] as [String?])
    func aBlankTokenKeepsTheSavedOneUnlessATokenIsRequired(token: String?) throws {
        #expect(try RemoteHostEntry(name: "", address: "mac", port: "7433", token: token).token == nil)
        #expect(throws: RemoteHostEntry.Problem.token) {
            try RemoteHostEntry(name: "", address: "mac", port: "7433", token: token, requireToken: true)
        }
    }

    @Test func recordsRoundTripInOrder() {
        let records = [RemoteHostRecord(name: "b", address: "10.0.0.2", port: 7433),
                       RemoteHostRecord(name: "a", address: "10.0.0.1", port: 7434)]
        #expect(RemoteHostRecord.decodeList(RemoteHostRecord.encodeList(records)) == records)
    }

    @Test func aRecordSavedBeforeRoutesIsOneRouteAndItsRoutesRoundTrip() throws {
        let id = UUID()
        let old = Data(#"[{"id":"\#(id.uuidString)","name":"Mac mini","address":"10.77.20.10","port":7434}]"#.utf8)
        let migrated = try #require(RemoteHostRecord.decodeList(old).first)
        #expect(migrated.routes == [RemoteHostRoute(host: "10.77.20.10", port: 7434)] && migrated.address == "10.77.20.10" && migrated.port == 7434)

        let fleet = RemoteHostRecord(id: id, name: "Mac mini", routes: [RemoteHostRoute(host: "10.77.20.10", port: 7434, kind: .lan),
                                                                         RemoteHostRoute(host: "mac-mini.local", port: 7434, kind: .hostname)])
        let saved = RemoteHostRecord.encodeList([fleet])
        #expect(RemoteHostRecord.decodeList(saved) == [fleet])
        // The first route is still the address and port a build before routes reads.
        let object = try #require(try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        #expect(object[0]["address"] as? String == "10.77.20.10" && object[0]["port"] as? Int == 7434)
    }

    @Test(arguments: [nil, Data(), Data("{".utf8), Data("{\"name\":\"x\"}".utf8)] as [Data?])
    func unreadableRecordsAreNoHosts(data: Data?) {
        #expect(RemoteHostRecord.decodeList(data).isEmpty)
    }

    @Test func theFirstClientsSingleHostMigratesWithTheGivenID() throws {
        let id = UUID()
        let legacy = Data(#"{"name":"Studio","host":"10.0.0.5","port":7433}"#.utf8)
        let record = try #require(RemoteHostRecord.migrating(legacy: legacy, id: id))
        #expect(record == RemoteHostRecord(id: id, name: "Studio", address: "10.0.0.5", port: 7433))
    }

    @Test(arguments: [nil, Data("[]".utf8), Data(#"{"name":"x","host":"","port":7433}"#.utf8),
                      Data(#"{"name":"x","host":"a","port":0}"#.utf8)] as [Data?])
    func aMissingOrBrokenLegacyHostMigratesToNothing(data: Data?) {
        #expect(RemoteHostRecord.migrating(legacy: data, id: UUID()) == nil)
    }

    @Test(arguments: [
        (RemoteHostPhase.connected, "Connected", true, nil),
        (.connecting, "Connecting", false, nil),
        (.disconnected, "Offline", false, nil),
        (.failed(RemoteHostFailure(kind: .unreachable, detail: "refused")), "Offline", false, RemoteHostFailure(kind: .unreachable, detail: "refused")),
    ] as [(RemoteHostPhase, String, Bool, RemoteHostFailure?)])
    func aPhaseReadsAsOneWord(phase: RemoteHostPhase, word: String, connected: Bool, failure: RemoteHostFailure?) {
        #expect(phase.word == word)
        #expect(phase.isConnected == connected)
        #expect(phase.failure == failure)
    }

    @Test func backoffDoublesToItsCapAndResets() {
        var backoff = RemoteReconnectBackoff()
        let delays = (0..<7).map { _ in backoff.next() }
        #expect(delays == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        backoff.reset()
        #expect(backoff.next() == .seconds(1))
    }
}
