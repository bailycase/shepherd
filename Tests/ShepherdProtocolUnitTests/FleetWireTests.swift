import Foundation
import Testing
import ShepherdCore
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

    // MARK: Pressure

    @Test func aSnapshotFromAHostWithoutPressureDecodesWithNoMacs() throws {
        let old = Data(#"{"enabled":true,"name":"Mac mini","addresses":[],"advertising":false,"peers":[]}"#.utf8)
        let snapshot = try JSONDecoder().decode(FleetSnapshot.self, from: old)
        #expect(snapshot.enabled && snapshot.macs.isEmpty)
    }

    @Test func aReadinessReportWithMissingFieldsDecodesWithDefaults() throws {
        let report = try JSONDecoder().decode(FleetReadinessReport.self, from: Data("{}".utf8))
        #expect(report == FleetReadinessReport())
        #expect(report.model == "Mac" && report.missing.isEmpty && report.repos.isEmpty)
    }

    @Test func hostSettingsFromAnOlderHostHoldNoWeightsAndAnUnknownWeightIsDropped() throws {
        var settings = HostSettings(defaultThinking: .low, queueDelivery: .all, worktreeBase: .fresh, fetchBeforeCreating: true, generatePRDescriptions: true,
                                    bundledExtensions: [], installedExtensions: [], updatePiDaily: false, updateExtensionsDaily: false)
        var object = try Wire.object(settings)
        object["fleetWeights"] = nil
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: object)).fleetWeights.isEmpty)
        let host = UUID()
        object["fleetWeights"] = [FleetSendWeight.settingKey(hostID: host): "preferred-by-a-newer-host", "fleet.weight.other": "prefer"]
        let decoded = try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.fleetWeights == ["fleet.weight.other": .prefer])
        settings.apply(.fleetWeight(hostID: host, weight: .lessOften))
        #expect(settings.fleetWeights[FleetSendWeight.settingKey(hostID: host)] == .lessOften)
    }
}
