import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// What a host keeps of the fleet's client devices (`devices.json`), how Macs merge their lists, and
/// how the shared token's retirement is tracked.
@Suite("Fleet devices")
struct FleetDevicesTests {
    static func device(_ name: String, token: String = "secret", kind: FleetDeviceKind = .iphone, paired: Double = 10) -> FleetDeviceRecord {
        FleetDeviceRecord(deviceID: UUID(), name: name, kind: kind, tokenHash: FleetProtocol.hash(token), pairedAt: paired)
    }

    @Test func aDeviceIsKnownByItsTokenAndOnlyUntilRevoked() {
        var devices = FleetDevices()
        let phone = Self.device("iPhone", token: "phone-token"), pad = Self.device("iPad", token: "pad-token", kind: .ipad)
        let added = [devices.add(phone), devices.add(pad)]
        #expect(added == [true, true])
        #expect(devices.authenticate(token: "phone-token") == phone.deviceID)
        #expect(devices.authenticate(token: "pad-token") == pad.deviceID)
        #expect(devices.authenticate(token: "other") == nil)

        let revoked = devices.revoke(phone.deviceID, at: 500)
        #expect(revoked)
        #expect(devices.authenticate(token: "phone-token") == nil, "a revoked device's token is refused")
        #expect(devices.record(phone.deviceID)?.tokenHash == nil, "its hash is gone, the tombstone stays")
        #expect(devices.active.map(\.name) == ["iPad"])
        let again = devices.revoke(phone.deviceID, at: 600), readded = devices.add(phone)
        #expect(!again, "revoking twice changes nothing")
        #expect(!readded, "a revoked id is not paired again; a device makes a new identity")
    }

    @Test func mergingConvergesWhicheverWayTheListsAreExchanged() {
        let phone = Self.device("iPhone", token: "a"), pad = Self.device("iPad", token: "b", kind: .ipad)
        var one = FleetDevices(), two = FleetDevices()
        one.add(phone)
        two.add(phone)
        two.add(pad)
        // Mac one revokes the phone while Mac two is away, then they meet.
        one.revoke(phone.deviceID, at: 700)

        let toTwo = two.merge(one.entries)
        let toOne = one.merge(two.entries)
        let second = two.merge(one.entries)
        #expect(toTwo.changed && toTwo.revoked == [phone.deviceID])
        #expect(toOne.changed && toOne.revoked.isEmpty)
        #expect(Set(one.entries) == Set(two.entries))
        #expect(two.authenticate(token: "a") == nil && two.authenticate(token: "b") == pad.deviceID)
        #expect(one.authenticate(token: "b") == pad.deviceID, "a device added elsewhere is accepted here")
        #expect(!second.changed, "a second exchange changes nothing")
    }

    @Test func aRevocationIsFinalEvenWhenAStaleListStillHasTheDevice() {
        let phone = Self.device("iPhone", token: "a")
        var devices = FleetDevices()
        devices.add(phone)
        devices.revoke(phone.deviceID, at: 700)
        let stale = FleetDeviceEntry(deviceID: phone.deviceID, name: "iPhone", kind: .iphone, tokenHash: phone.tokenHash, pairedAt: 10)
        let merged = devices.merge([stale])
        #expect(!merged.changed)
        #expect(devices.authenticate(token: "a") == nil)
    }

    @Test func theFileKeepsEverythingAndOlderFilesStillLoad() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var devices = FleetDevices()
        devices.add(Self.device("iPhone"))
        try devices.save(to: dir)
        #expect(try FleetDevices.load(from: dir) == devices)

        var mode = stat()
        #expect(stat(dir.appendingPathComponent("devices.json").path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)

        try Data("{}".utf8).write(to: dir.appendingPathComponent("devices.json"))
        let bare = try FleetDevices.load(from: dir)
        #expect(bare.devices.isEmpty)
        // A file from when a shared token was accepted keeps what it held of devices and ignores the rest.
        let old = #"{"legacy":[{"id":"Shepherd iOS@192.168.1.31","name":"Shepherd iOS","lastSeen":5000}],"sharedTokenRetired":true,"devices":[]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("devices.json"))
        #expect(try FleetDevices.load(from: dir) == FleetDevices())
        let sparse = #"{"devices":[{"deviceID":"00000000-0000-0000-0000-0000000000D1"}]}"#
        try Data(sparse.utf8).write(to: dir.appendingPathComponent("devices.json"))
        let loaded = try FleetDevices.load(from: dir).devices
        #expect(loaded.count == 1 && loaded[0].name == "" && loaded[0].kind == .iphone && loaded[0].revokedAt == nil)
    }

    /// `scripts/perf/stress.sh` seeds a scratch host with a device in this shape (only the token's SHA-256 on disk).
    @Test func aDeviceFileWrittenByTheStressScriptAuthenticatesItsToken() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = "0123456789abcdef"
        let json = #"{"devices":[{"deviceID":"00000000-0000-0000-0000-0000000000D9","name":"stress driver","kind":"macApp","pairedAt":0,"tokenHash":"\#(FleetProtocol.hash(token))"}]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("devices.json"))
        let devices = try FleetDevices.load(from: dir)
        #expect(devices.authenticate(token: token) != nil && devices.authenticate(token: "other") == nil)
    }

    @Test func theCodeOfAddADeviceIsTheJoinWindowWithItsFiveTries() {
        var window = FleetJoinWindow.open(now: FleetStoreTests.start).window
        var results: [FleetJoinWindow.Attempt] = []
        for _ in 0..<5 { results.append(window.attempt("000000x", now: FleetStoreTests.start)) }
        #expect(results == [.wrong(attemptsLeft: 4), .wrong(attemptsLeft: 3), .wrong(attemptsLeft: 2), .wrong(attemptsLeft: 1), .lockedOut])
    }

    @Test func theQRCodeCarriesTheCodeAndWhichMacShowsIt() throws {
        let id = FleetProtocol.advertisedIDHash(UUID())
        let link = FleetProtocol.pairLink(code: "482913", advertisedID: id)
        let parsed = try #require(FleetProtocol.parsePairLink(link))
        #expect(parsed.code == "482913" && parsed.advertisedID == id)
        #expect(FleetProtocol.parsePairLink("https://example.com/?code=482913&mac=\(id)") == nil)
        #expect(FleetProtocol.parsePairLink(FleetProtocol.pairLink(code: "48291", advertisedID: id)) == nil, "a short code isn't a code")
        #expect(FleetProtocol.parsePairLink("shepherd-pair://device?code=482913") == nil, "without a Mac it can't be aimed")
    }

    @Test func aDeviceIsOfferedNoFleetCapability() {
        for capability in RemoteProtocol.fleetMemberCapabilities {
            #expect(!FleetAccess.device.isOffered(capability))
            #expect(FleetAccess.member.isOffered(capability) && FleetAccess.local.isOffered(capability))
        }
        #expect(FleetAccess.device.isOffered(RemoteProtocol.nativeThreadCapability), "everything a client does today stays")
        #expect(FleetAccess.local.takesPartInFleet && FleetAccess.member.takesPartInFleet)
        #expect(!FleetAccess.device.takesPartInFleet && !FleetAccess.unauthenticated.takesPartInFleet)
    }
}
