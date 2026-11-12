import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// Settings ▸ Fleet ▸ Code: whether a dispatch carries uncommitted changes, and what a space keeps home. Both sync across the fleet.
@Suite("Fleet snapshot settings")
struct FleetSnapshotSettingsTests {
    @Test func theDefaultsSendTheChangesAndExcludeNothingAndAnOlderHostDecodesToThem() throws {
        #expect(HostSettings().fleetUncommitted == .sendThem && HostSettings().fleetSnapshotExcludes.isEmpty)
        var settings = HostSettings()
        settings.apply(.fleetUncommitted(.leaveBehind))
        settings.apply(.fleetSnapshotExcludes(spaceID: "space-1", excludes: FleetSnapshotExcludes(excluded: ["dist"], included: [".build"])))
        let decoded = try JSONDecoder().decode(HostSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.fleetUncommitted == .leaveBehind)
        #expect(decoded.fleetSnapshotExcludes["fleet.snapshotExcludes.space-1"] == FleetSnapshotExcludes(excluded: ["dist"], included: [".build"]))
        // A host that never heard of either setting leaves them out.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(HostSettings())) as? [String: Any])
        object["fleetUncommitted"] = nil
        object["fleetSnapshotExcludes"] = nil
        let older = try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.fleetUncommitted == .sendThem && older.fleetSnapshotExcludes.isEmpty)
        // A value this build doesn't know reads as the default.
        object["fleetUncommitted"] = "somethingNew"
        #expect(try JSONDecoder().decode(HostSettings.self, from: JSONSerialization.data(withJSONObject: object)).fleetUncommitted == .sendThem)
    }

    @Test func emptyingASpacesListIsBackToTheDefaultsAndTheChangesNeedTheSnapshotCapability() {
        var settings = HostSettings()
        settings.apply(.fleetSnapshotExcludes(spaceID: "s", excludes: FleetSnapshotExcludes(excluded: ["dist"])))
        #expect(settings.fleetSnapshotExcludes.count == 1)
        settings.apply(.fleetSnapshotExcludes(spaceID: "s", excludes: FleetSnapshotExcludes()))
        #expect(settings.fleetSnapshotExcludes.isEmpty)
        #expect(HostSettingChange.fleetUncommitted(.sendThem).capability == RemoteProtocol.fleetSnapshotCapability)
        #expect(HostSettingChange.fleetSnapshotExcludes(spaceID: "s", excludes: FleetSnapshotExcludes()).capability == RemoteProtocol.fleetSnapshotCapability)
    }

    @Test func eachSettingIsAFleetUnitThatRoundTrips() throws {
        var settings = HostSettings()
        settings.apply(.fleetUncommitted(.leaveBehind))
        #expect(FleetHostSetting.fleetUncommitted.json(in: settings) == "\"leaveBehind\"")
        #expect(FleetHostSetting.fleetUncommitted.change(fromJSON: "\"leaveBehind\"") == .fleetUncommitted(.leaveBehind))
        #expect(FleetHostSetting.fleetUncommitted.change(fromJSON: "\"nonsense\"") == nil)
        #expect(FleetHostSetting.fleetUncommitted.isDefault(in: HostSettings()) && !FleetHostSetting.fleetUncommitted.isDefault(in: settings))

        settings.apply(.fleetSnapshotExcludes(spaceID: "space-1", excludes: FleetSnapshotExcludes(excluded: ["dist", "packages/web/out"])))
        let unit = FleetSnapshotExcludeSetting.unit(spaceID: "space-1")
        #expect(unit == "setting:fleet.snapshotExcludes.space-1" && FleetSnapshotExcludeSetting.spaceID(unit: unit) == "space-1")
        let json = try #require(FleetSnapshotExcludeSetting.values(in: settings)[unit])
        #expect(FleetSnapshotExcludeSetting.change(spaceID: "space-1", fromJSON: json) == .fleetSnapshotExcludes(spaceID: "space-1", excludes: FleetSnapshotExcludes(excluded: ["dist", "packages/web/out"])))
        #expect(FleetSnapshotExcludeSetting.change(spaceID: "space-1", fromJSON: "[1]") == nil)
        #expect(FleetSnapshotExcludeSetting.spaceID(unit: "setting:fleet.weight.x") == nil && FleetSnapshotExcludeSetting.spaceID(unit: "setting:fleet.snapshotExcludes.") == nil)
        // A space with nothing listed has no unit.
        #expect(FleetSnapshotExcludeSetting.values(in: HostSettings()).isEmpty)
    }

    @Test func theSnapshotMessagesBoundWhatAReceiverWillTake() {
        let hash = FleetHash(of: Data("x".utf8))
        let chunk = FleetBlobChunk(hash: hash, size: 10, offset: 0, data: Data(count: 10))
        #expect(chunk.isValid)
        #expect(!FleetBlobChunk(hash: hash, size: 10, offset: 5, data: Data(count: 10)).isValid, "past the end")
        #expect(!FleetBlobChunk(hash: hash, size: 1 << 20, offset: 0, data: Data(count: FleetSnapshotTransfer.chunkBytes + 1)).isValid, "a chunk over the frame's share")
        let header = FleetSnapshotHeader(commit: String(repeating: "a", count: 40), rootHash: hash, digest: hash, files: 1, directories: 0, deletions: 0, parts: 1, fileCount: 1, bytes: 1)
        #expect(header.isValid)
        var bad = header
        bad.commit = "abc"
        #expect(!bad.isValid)
        bad = header
        bad.files = FleetSnapshotTransfer.maxEntries + 1
        #expect(!bad.isValid)
    }
}
