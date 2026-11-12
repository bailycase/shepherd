import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Phones, iPads and Macs' apps as clients of a fleet, between real scratch hosts: pairing a device by
/// code, what it can and cannot reach, revoking it mid connection from any Mac, and retiring the shared
/// token once every client has its own. Reuses `FleetPairingTests.Mac`.
@Suite("Fleet devices on hosts", .integrationTimeLimit)
struct FleetDevicesIntegrationTests {
    typealias Mac = FleetPairingTests.Mac

    /// A device: the identity and token it made, and the connection it holds.
    final class Device: @unchecked Sendable {
        let intro: FleetDeviceIntroduction
        let token: String
        let disconnected = Locked(false)
        var client = RemoteHostClient()

        init(_ name: String = "iPhone", kind: FleetDeviceKind = .iphone) {
            token = FleetProtocol.makeToken()
            intro = FleetDeviceIntroduction(deviceID: UUID(), name: name, kind: kind, tokenHash: FleetProtocol.hash(token))
        }

        /// Pairs with the code `mac` shows.
        func pair(with mac: Mac, code: String) async throws -> FleetDevicesResult {
            try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: mac.port, code: code, device: intro).result
        }

        /// Connects to `mac` with its own token, like a phone does.
        @discardableResult
        func connect(to mac: Mac) async throws -> RemoteHostClient {
            client.disconnect()
            client = RemoteHostClient()
            let flag = disconnected
            flag.withValue { $0 = false }
            client.onDisconnected = { _ in flag.withValue { $0 = true } }
            _ = try await client.connect(host: "127.0.0.1", port: mac.port, token: token, clientName: intro.name)
            return client
        }

        func stop() { client.disconnect() }
    }

    static func devices(_ mac: Mac) async throws -> [FleetDeviceStatus] { try await mac.read().devices?.devices ?? [] }

    static func refused(_ token: String, by mac: Mac) async -> Bool {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        do {
            // No capabilities: a probe, not a client someone uses, so the host doesn't wait for it.
            _ = try await client.connect(host: "127.0.0.1", port: mac.port, token: token, clientName: "probe", capabilities: [], fetchesState: false)
            return false
        } catch RemoteHostClientError.rejected(let code, _) {
            return code == RemoteProtocol.unauthorizedCode
        } catch { return false }
    }

    // MARK: Pairing

    @Test func aDevicePairsByCodeAndConnectsWithATokenOfItsOwn() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let phone = Device()
        defer { phone.stop() }

        let code = try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code
        #expect(code.count == FleetProtocol.codeLength && code.allSatisfy(\.isNumber))
        let paired = try await phone.pair(with: mac, code: code)
        #expect(paired.name == "MacBook Pro" && paired.members.isEmpty)
        #expect(try await mac.read().devices?.code == nil, "the code is spent")

        let client = try await phone.connect(to: mac)
        _ = client
        let listed = try await Self.devices(mac)
        #expect(listed.map(\.name) == ["iPhone"] && listed.first?.kind == .iphone && listed.first?.connected == true)

        // Only the hash of its token is kept, in a private file.
        let file = mac.host.dir.appendingPathComponent("fleet/devices.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(FleetProtocol.hash(phone.token)) && !text.contains(phone.token))
        var mode = stat()
        #expect(stat(file.path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)
    }

    @Test func wrongCodesLockTheDeviceCodeOutAndAMacNotShowingOneTakesNone() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let phone = Device()

        func attempt(_ code: String) async -> String? {
            do { _ = try await phone.pair(with: mac, code: code); return nil }
            catch RemoteHostClientError.rejected(let code, _) { return code }
            catch { return "other" }
        }
        #expect(await attempt("123456") == FleetProtocol.Code.notJoining)

        let code = try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code
        let wrong = code == "000000" ? "111111" : "000000"
        for _ in 0..<(FleetProtocol.maxCodeAttempts - 1) { #expect(await attempt(wrong) == FleetProtocol.Code.badCode) }
        #expect(await attempt(wrong) == FleetProtocol.Code.lockedOut)
        #expect(await attempt(code) == FleetProtocol.Code.notJoining, "even the right code is dead now")
        #expect(try await Self.devices(mac).isEmpty)
        let refusedAfter = await Self.refused(phone.token, by: mac)
        #expect(refusedAfter)
    }

    @Test func theJoinCodeOfAMacAndTheCodeOfADeviceAreNotInterchangeable() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let joinCode = try await mac.startJoin()
        let phone = Device()
        do { _ = try await phone.pair(with: mac, code: joinCode); Issue.record("a device paired with a Mac's join code") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.notJoining) }
        #expect(try await Self.devices(mac).isEmpty)
    }

    // MARK: A client, not a member

    @Test func aDeviceIsOfferedNoFleetCapabilityAndCannotUseTheFleetsRequests() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        let phone = Device()
        defer { phone.stop() }
        _ = try await phone.pair(with: a, code: try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code)
        let client = try await phone.connect(to: a)

        #expect(!client.capabilities.contains(RemoteProtocol.fleetCapability))
        #expect(client.capabilities.contains(RemoteProtocol.nativeThreadCapability), "what a client does today is unchanged")
        // The same host offers it to a client still on the shared token (to be given its own).
        let legacy = try await RemoteHostClient.connected(to: a)
        defer { legacy.disconnect() }
        #expect(legacy.capabilities.contains(RemoteProtocol.fleetCapability))

        // The fleet's requests are a member's: a device can't read the store, pair, remove or sync (what it may read is `fleet.view.v1`: `FleetDeviceViewTests`).
        let attempts: [(String, () async throws -> Void)] = [
            ("fleetAction", { _ = try await client.fleetAction(.retireSharedToken) }),
            ("fleetRevoke", { try await client.fleetRevoke(hostID: UUID(), at: 1) }),
            ("fleetSyncDevices", { _ = try await client.fleetSyncDevices([]) }),
            ("fleetEstablish", { _ = try await client.fleetEstablish(from: FleetIntroduction(hostID: UUID(), name: "x", myTokenHash: FleetProtocol.hash("t"), port: 7434)) }),
            ("fleetIntroduce", { _ = try await client.fleetIntroduce(FleetIntroduce(member: FleetMember(hostID: UUID(), name: "x", host: "127.0.0.1", port: 7434), theirTokenHash: nil)) }),
            ("fleetEnrollDevice", { _ = try await client.fleetEnrollDevice(Device("other").intro) }),
        ]
        for (name, attempt) in attempts {
            do { try await attempt(); Issue.record("\(name): a device used a member's request") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden, "\(name)") }
        }
        #expect(try await Self.devices(a).count == 1, "nothing it tried changed the fleet")
    }

    @Test func aDeviceTokenNeverLinksAMac() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        let phone = Device()
        _ = try await phone.pair(with: a, code: try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code)
        // A peer's link needs a peer's token: a device's, presented as a member would, only gets client powers.
        let client = try await phone.connect(to: a)
        defer { client.disconnect() }
        let atPeers = try await a.peers(), btPeers = try await b.peers()
        #expect(atPeers.isEmpty && btPeers.isEmpty)
    }

    // MARK: One pairing, every Mac

    @Test func aDevicePairedToOneMacWorksOnEveryMacOfTheFleetAndAnyMacRevokesIt() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        let phone = Device()
        defer { phone.stop() }
        let paired = try await phone.pair(with: a, code: try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code)
        #expect(paired.members.map(\.name) == ["Mac mini"] && paired.members.first?.port == b.port)

        // B knew the device by the time A answered: the phone connects to it at once.
        let atA = try await phone.connect(to: a)
        let atB = RemoteHostClient()
        defer { atA.disconnect(); atB.disconnect() }
        _ = try await atB.connect(host: "127.0.0.1", port: b.port, token: phone.token, clientName: "iPhone")
        #expect(try await Self.devices(b).map(\.name) == ["iPhone"])

        // B revokes it: A hears, and the connection there ends too.
        let id = try #require(try await Self.devices(b).first).deviceID
        _ = try await b.local.fleetAction(.revokeDevice(id))
        try await eventually("A's connection of the device to end") { phone.disconnected.current }
        let refusedAtA = await Self.refused(phone.token, by: a), refusedAtB = await Self.refused(phone.token, by: b)
        #expect(refusedAtA && refusedAtB)
        try await eventually("A to drop the device from its list") { try await Self.devices(a).isEmpty }
    }

    @Test func aMacThatWasAwayHearsOfARevocationWhenItsLinkComesBack() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        var restarted: Mac?
        defer { a.stop(); b.stop(); restarted?.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)
        let phone = Device()
        _ = try await phone.pair(with: a, code: try #require(try await a.local.fleetAction(.startDeviceCode).deviceCode).code)
        try await eventually("B to know the device") { try await Self.devices(b).count == 1 }

        // B goes away; the device is revoked on A meanwhile.
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await eventually("A to lose its link") { try await a.peers().first?.link != .connected }
        _ = try await a.local.fleetAction(.revokeDevice(try #require(try await Self.devices(a).first).deviceID))

        let back = try await Mac("Mac mini", dir: dir, port: port)
        restarted = back
        try await a.waitForLink(to: back)
        try await eventually("B to hear of the revocation") { await Self.refused(phone.token, by: back) }
    }

    // MARK: Revoking

    @Test func revokingADeviceEndsItsConnectionAndRefusesItsTokenAfter() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let phone = Device(), pad = Device("iPad", kind: .ipad)
        defer { phone.stop(); pad.stop() }
        for device in [phone, pad] {
            _ = try await device.pair(with: mac, code: try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code)
            try await device.connect(to: mac)
        }
        let listed = try await Self.devices(mac)
        #expect(Set(listed.map(\.name)) == ["iPhone", "iPad"] && listed.allSatisfy(\.connected))

        _ = try await mac.local.fleetAction(.revokeDevice(phone.intro.deviceID))
        try await eventually("the phone's connection to end") { phone.disconnected.current }
        #expect(!pad.disconnected.current, "the other device is untouched")
        let phoneRefused = await Self.refused(phone.token, by: mac)
        #expect(phoneRefused)
        #expect(try await Self.devices(mac).map(\.name) == ["iPad"])

        // It pairs again as a new device, and the revoked identity can't be reused.
        do { _ = try await phone.pair(with: mac, code: try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code); Issue.record("a revoked identity paired") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.deviceRevoked) }
        let fresh = Device()
        defer { fresh.stop() }
        _ = try await fresh.pair(with: mac, code: try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code)
        try await fresh.connect(to: mac)
        do { _ = try await mac.local.fleetAction(.revokeDevice(UUID())); Issue.record("revoked a device that doesn't exist") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.invalid) }
    }

    @Test func devicesSurviveARestartAndStayRevoked() async throws {
        let mac = try await Mac("MacBook Pro")
        var restarted: Mac?
        defer { mac.stop(); restarted?.stop() }
        let phone = Device(), gone = Device("iPad", kind: .ipad)
        for device in [phone, gone] { _ = try await device.pair(with: mac, code: try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code) }
        _ = try await mac.local.fleetAction(.revokeDevice(gone.intro.deviceID))
        let (dir, port) = (mac.host.dir, mac.port)
        mac.stop(keepFiles: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let back = try await Mac("MacBook Pro", dir: dir, port: port)
        restarted = back
        try await phone.connect(to: back)
        let goneRefused = await Self.refused(gone.token, by: back)
        #expect(goneRefused)
        #expect(try await Self.devices(back).map(\.name) == ["iPhone"])
    }

    // MARK: The shared token

    /// An older iPhone on the shared token is offered a token of its own, stores it and carries on; its
    /// shared token stays good until retired.
    @Test func aClientOnTheSharedTokenIsOfferedItsOwnAndRetiringTheSharedTokenIsRefusedUntilItHasOne() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let old = try await RemoteHostClient.connected(to: mac)
        defer { old.disconnect() }
        #expect(old.capabilities.contains(RemoteProtocol.fleetCapability))
        var shared = try #require(try await mac.read().devices?.sharedToken)
        #expect(shared.waiting.map(\.name) == ["iPhone"] && !shared.retired && shared.switched == 0)

        // Not yet: the client hasn't switched.
        do { _ = try await mac.local.fleetAction(.retireSharedToken); Issue.record("retired with a client waiting") }
        catch RemoteHostClientError.rejected(let code, let message) { #expect(code == "devices_waiting" && message.contains("One device")) }
        let still = try await RemoteHostClient.connected(to: mac)
        still.disconnect()

        // It is given a token of its own and stores it (here: the test is the device).
        let phone = Device("iPhone")
        defer { phone.stop() }
        let answer = try await old.fleetEnrollDevice(phone.intro)
        #expect(answer.name == "MacBook Pro")
        shared = try #require(try await mac.read().devices?.sharedToken)
        #expect(shared.waiting.isEmpty && shared.switched == 1)
        _ = try await phone.connect(to: mac)
        #expect(try await Self.devices(mac).map(\.name) == ["iPhone"])

        // Asking again with the same identity changes nothing (a lost answer).
        _ = try await old.fleetEnrollDevice(phone.intro)
        #expect(try await Self.devices(mac).count == 1)
        // The shared token still works until it is retired.
        let another = try await RemoteHostClient.connected(to: mac)
        another.disconnect()
    }

    @Test func theSharedTokenIsRefusedOnlyAfterItIsRetired() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let old = try await RemoteHostClient.connected(to: mac)
        let phone = Device()
        defer { phone.stop() }
        _ = try await old.fleetEnrollDevice(phone.intro)
        let connection = Locked(false)
        old.onDisconnected = { _ in connection.withValue { $0 = true } }
        try await phone.connect(to: mac)
        let before = await Self.refused(mac.sharedToken, by: mac)
        #expect(!before, "accepted before retirement")

        let after = try await mac.local.fleetAction(.retireSharedToken)
        #expect(after.snapshot.devices?.sharedToken.retired == true)
        try await eventually("what connected on the shared token to end") { connection.current }
        let after2 = await Self.refused(mac.sharedToken, by: mac)
        #expect(after2, "refused after retirement")
        #expect(!phone.disconnected.current, "a device on its own token stays")
        #expect(try await mac.read().hostID != nil, "this Mac's own app stays")
        try await phone.connect(to: mac)
    }

    @Test func aRetiredSharedTokenStaysRetiredWhenFleetIsTurnedOffAndOn() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        _ = try await mac.local.fleetAction(.retireSharedToken)
        mac.server.setFleetEnabled(false)
        try await eventually("Fleet to be off") { try await mac.read().enabled == false }
        let whileOff = await Self.refused(mac.sharedToken, by: mac)
        #expect(whileOff, "turning Fleet off does not open the old token again")
        mac.server.setFleetEnabled(true)
        try await eventually("Fleet to be on") { try await mac.read().devices?.sharedToken.retired == true }
    }

    @Test func aClientThatConnectsWithItsOwnTokenIsNoLongerWaitedFor() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        // One phone on the shared token at both Macs; enrolling at A tells B by sync, and its first
        // connection to B with the new token is what stops B waiting for it.
        let atA = try await RemoteHostClient.connected(to: a), atB = try await RemoteHostClient.connected(to: b)
        defer { atA.disconnect(); atB.disconnect() }
        let phone = Device("iPhone")
        defer { phone.stop() }
        _ = try await atA.fleetEnrollDevice(phone.intro)
        #expect(try await b.read().devices?.sharedToken.waiting.count == 1)
        try await eventually("B to hold the device") { try await Self.devices(b).count == 1 }
        try await phone.connect(to: b)
        #expect(try await b.read().devices?.sharedToken.waiting.isEmpty == true)
        _ = try await a.local.fleetAction(.retireSharedToken)
        _ = try await b.local.fleetAction(.retireSharedToken)
    }

    @Test func aWaitingClientCanBeForgottenSoTheSharedTokenCanBeRetired() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let old = try await RemoteHostClient.connected(to: mac)
        defer { old.disconnect() }
        let waiting = try #require(try await mac.read().devices?.sharedToken.waiting.first)
        let forgotten = try await mac.local.fleetAction(.forgetLegacyClient(waiting.id))
        #expect(forgotten.snapshot.devices?.sharedToken.waiting.isEmpty == true)
        let retired = try await mac.local.fleetAction(.retireSharedToken)
        #expect(retired.snapshot.devices?.sharedToken.retired == true)
    }

    /// A Mac's own app gets a token from its own host for its direct connections to the Macs of the fleet.
    @Test func aMacsAppIsGivenATokenOfItsOwnByItsHost() async throws {
        let a = try await Mac("MacBook Pro"), b = try await Mac("Mac mini")
        defer { a.stop(); b.stop() }
        try await a.pair(with: b, code: try await b.startJoin())
        try await a.waitForLink(to: b)
        try await b.waitForLink(to: a)

        let result = try await a.local.fleetAction(.enrollApp(name: "MacBook Pro"))
        let token = try #require(result.appToken)
        #expect(result.snapshot.devices?.devices.first?.kind == .macApp)
        // Every Mac in the fleet accepts it, as a client.
        let app = RemoteHostClient()
        defer { app.disconnect() }
        _ = try await app.connect(host: "127.0.0.1", port: b.port, token: token, clientName: "MacBook Pro")
        #expect(!app.capabilities.contains(RemoteProtocol.fleetCapability))
        // The host never keeps it, and a remote client can't ask for one.
        #expect(!(try String(contentsOf: a.host.dir.appendingPathComponent("fleet/devices.json"), encoding: .utf8)).contains(token))
        let remote = try await RemoteHostClient.connected(to: a)
        defer { remote.disconnect() }
        do { _ = try await remote.fleetAction(.enrollApp(name: "x")); Issue.record("a remote client was given an app token") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
    }

    // MARK: Fleet off

    /// Devices don't need fleet membership: with Fleet off a Mac that serves still takes a phone by code,
    /// lists it, revokes it and retires the shared token; only what is a member's stays refused.
    @Test func withFleetOffAPhonePairsByCodeAndMembershipStaysRefused() async throws {
        let mac = try await Mac("MacBook Pro", fleet: false)
        defer { mac.stop() }
        let snapshot = try await mac.read()
        #expect(!snapshot.enabled && snapshot.peers.isEmpty && snapshot.port == mac.port && snapshot.devices?.devices.isEmpty == true)

        let phone = Device()
        defer { phone.stop() }
        let code = try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code
        let paired = try await phone.pair(with: mac, code: code)
        #expect(paired.name == "MacBook Pro" && paired.members.isEmpty)
        let client = try await phone.connect(to: mac)
        #expect(!client.capabilities.contains(RemoteProtocol.fleetCapability) && !client.capabilities.contains(RemoteProtocol.fleetDevicesCapability))
        let listed = try await Self.devices(mac)
        #expect(listed.map(\.name) == ["iPhone"] && listed.first?.connected == true)

        // What is a member's is refused as it always was.
        for attempt: () async throws -> Void in [
            { _ = try await mac.local.fleetAction(.startJoin) },
            { _ = try await mac.local.fleetAction(.remove(hostID: UUID())) },
            { _ = try await mac.local.fleetAction(.adopt([])) },
        ] {
            do { try await attempt(); Issue.record("a member's action worked with Fleet off") }
            catch RemoteHostClientError.rejected(let refused, _) { #expect(refused == FleetProtocol.Code.off) }
        }
        let identity = try await RemoteHostClient.connected(to: mac)
        defer { identity.disconnect() }
        #expect(!identity.capabilities.contains(RemoteProtocol.fleetCapability), "fleet.v1 is offered only while Fleet is on")
        #expect(try await identity.fleetIdentify().fleetEnabled == false)

        // Revoke works, and ends the connection.
        _ = try await mac.local.fleetAction(.revokeDevice(phone.intro.deviceID))
        try await eventually("the phone's connection to end") { phone.disconnected.current }
        let refusedAfter = await Self.refused(phone.token, by: mac)
        #expect(refusedAfter)
    }

    /// An older phone on the shared token is offered its own token with Fleet off too, and the shared token
    /// can be retired there.
    @Test func withFleetOffAClientOnTheSharedTokenIsOfferedItsOwnAndTheSharedTokenRetires() async throws {
        let mac = try await Mac("MacBook Pro", fleet: false)
        defer { mac.stop() }
        let old = try await RemoteHostClient.connected(to: mac)
        defer { old.disconnect() }
        #expect(old.capabilities.contains(RemoteProtocol.fleetDevicesCapability))
        let phone = Device()
        defer { phone.stop() }
        _ = try await old.fleetEnrollDevice(phone.intro)
        try await phone.connect(to: mac)
        _ = try await mac.local.fleetAction(.retireSharedToken)
        let refusedShared = await Self.refused(mac.sharedToken, by: mac)
        #expect(refusedShared)
        try await eventually("the phone to stay") { !phone.disconnected.current }
    }

    /// Turning Fleet off keeps its devices connected (only Macs' links end), and on again is the same fleet.
    @Test func switchingFleetOffAndOnLeavesDevicesConnected() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let phone = Device()
        defer { phone.stop() }
        _ = try await phone.pair(with: mac, code: try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code)
        try await phone.connect(to: mac)
        mac.server.setFleetEnabled(false)
        try await eventually("Fleet to be off") { try await mac.read().enabled == false }
        #expect(!phone.disconnected.current)
        #expect(try await Self.devices(mac).map(\.name) == ["iPhone"])
        mac.server.setFleetEnabled(true)
        try await eventually("Fleet to be on") { try await mac.read().enabled }
        #expect(!phone.disconnected.current)
    }
}
