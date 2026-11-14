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

    /// Dispatch signals ride the pressure sample with no new message, so a Mac on the previous Nightly sends none and ignores ours.
    @Test func aSampleFromAnOlderMacDecodesWithoutTheSignalsAndANewOneRoundTripsThem() throws {
        let old = Data(#"{"cpuUtilization":0.3,"cpuCount":8,"totalMemoryBytes":100,"availableMemoryBytes":50,"thermal":"nominal","onBattery":false,"activeAgents":2,"reserved":0}"#.utf8)
        let sample = try JSONDecoder().decode(FleetPressureSample.self, from: old)
        #expect(sample.commandAgents == nil && sample.cpuAverage == nil && sample.memoryPressure == nil && sample.limits == nil)
        let object = try Wire.object(sample)
        #expect(Set(object.keys).isDisjoint(with: ["commandAgents", "cpuAverage", "memoryPressure", "limits"]), "an unset signal is left out, as an older Mac would")
        let full = FleetPressureSample(cpuUtilization: 0.9, cpuCount: 8, totalMemoryBytes: 100, availableMemoryBytes: 50, activeAgents: 3, commandAgents: 2, cpuAverage: 0.4,
                                       memoryPressure: .critical, limits: [FleetProviderLimit(provider: "anthropic", seconds: 100)])
        #expect(try Wire.roundTrip(full) == full)
    }

    @Test func aSnapshotAndADispatchRecordFromAnOlderHostDecodeWithoutLimits() throws {
        let snapshot = try JSONDecoder().decode(FleetSnapshot.self, from: Data(#"{"enabled":true,"name":"Mac mini","addresses":[],"advertising":false,"peers":[]}"#.utf8))
        #expect(snapshot.limits.isEmpty)
        let record = FleetDispatchRecord(parentHostID: UUID(), parentHostName: "MacBook Pro", state: .waitingRoom, title: "t", task: "", repoKey: "k",
                                         reasonCodes: [FleetPlacementReason(.mostRoom, ratio: 2, commands: 0)], limitProvider: "anthropic", createdAt: 1)
        #expect(try Wire.roundTrip(record) == record)
        var object = try Wire.object(record)
        object["limitProvider"] = nil
        let older = try JSONDecoder().decode(FleetDispatchRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.limitProvider == nil && older.state == .waitingRoom, "an older host's record waits for room, as it always did")
        // A client (a phone) is told which providers are limited, and nothing else of the dispatches.
        let limited = FleetSnapshot(enabled: true, limits: [FleetLimitStatus(provider: "anthropic", seconds: 9, waiting: 1)])
        #expect(limited.clientView.limits == limited.limits)
    }

    @Test func aReadinessReportWithMissingFieldsDecodesWithDefaults() throws {
        let report = try JSONDecoder().decode(FleetReadinessReport.self, from: Data("{}".utf8))
        #expect(report == FleetReadinessReport())
        #expect(report.model == "Mac" && report.missing.isEmpty && report.repos.isEmpty && !report.noXcode)
    }

    @Test func aReportSaysWhatPlacementWeighsAndAnMCPCommandIsNeverNeeded() {
        let report = FleetReadinessReport(missing: [FleetMissingTool(kind: .binary, name: "bearcli"), FleetMissingTool(kind: .git)])
        #expect(report.lacks == [.mcpCommand("bearcli"), .git])
        // Xcode is named once, whether the report says it as a missing tool (an older Mac) or as the fact.
        #expect(FleetReadinessReport(noXcode: true).lacks == [.xcode])
        #expect(FleetReadinessReport(missing: [FleetMissingTool(kind: .xcode)], noXcode: true).lacks == [.xcode])
        #expect(FleetReadinessReport(missing: [FleetMissingTool(kind: .xcode)]).lacks == [.xcode])
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

    // MARK: What a client may read (`fleet.view.v1`)

    @Test func aClientViewKeepsTheMacsAndTheirLoadAndNothingOfHowTheyAreReached() throws {
        let mini = UUID(), here = UUID()
        let sample = FleetPressureSample(cpuUtilization: 0.2, cpuCount: 8, totalMemoryBytes: 1 << 34, availableMemoryBytes: 1 << 33)
        let snapshot = FleetSnapshot(
            enabled: true, hostID: here, name: "MacBook Pro", build: "1.9.0", addresses: ["192.168.1.40"], port: 7434, advertising: true,
            peers: [FleetPeerStatus(hostID: mini, name: "Mac mini", host: "192.168.1.52", port: 7434, pairedAt: 5, link: .connected, lastSeen: 9)],
            join: FleetJoinStatus(expiresAt: 1, attemptsLeft: 5),
            sync: FleetSyncStatus(peers: []),
            devices: FleetDevicesSnapshot(devices: [FleetDeviceStatus(deviceID: UUID(), name: "iPhone", kind: .iphone, pairedAt: 1, connected: true)]),
            macs: [FleetMacState(hostID: mini, sample: sample, sampleAge: 1, readiness: FleetReadinessReport(model: "Mac mini", repos: ["acme-web"]))])
        let view = snapshot.clientView
        #expect(view.enabled && view.hostID == here && view.name == "MacBook Pro")
        #expect(view.peers.map(\.name) == ["Mac mini"] && view.peers[0].link == .connected && view.peers[0].lastSeen == 9 && view.peers[0].pairedAt == 5)
        #expect(view.macs == snapshot.macs)
        #expect(view.addresses.isEmpty && view.port == nil && view.build == nil && !view.advertising)
        #expect(view.peers[0].host == nil && view.peers[0].port == nil)
        #expect(view.join == nil && view.sync == nil && view.devices == nil)
        // Nothing of the above is on the wire either.
        let text = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
        for hidden in ["192.168", "7434", "1.9.0", "iPhone"] { #expect(!text.contains(hidden), "\(hidden)") }
    }

    @Test func onlyADeviceMayViewTheFleet() {
        #expect(FleetAccess.device.mayViewFleet)
        #expect(!FleetAccess.member.mayViewFleet && !FleetAccess.local.mayViewFleet && !FleetAccess.unauthenticated.mayViewFleet)
        #expect(!FleetAccess.device.takesPartInFleet)
    }

    @Test func theViewCapabilityReachesADeviceAndGivesItNothingOfTheStore() {
        let view = RemoteProtocol.fleetViewCapability
        #expect(RemoteProtocol.capabilities.contains(view))
        #expect(FleetAccess.device.isOffered(view) && !FleetAccess.device.isOffered(RemoteProtocol.fleetPressureCapability))
        #expect(!RemoteProtocol.fleetMemberCapabilities.contains(view))
        #expect(HostSettingChange.fleetWeight(hostID: UUID(), weight: .prefer).capability == view)
    }
}
