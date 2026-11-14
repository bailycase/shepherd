import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Phones, iPads and Macs' apps as clients of a fleet, between real scratch hosts: pairing a device by
/// code, what it can and cannot reach, revoking it mid connection from any Mac, and what a client that
/// presents the old shared token is told. Reuses `FleetPairingTests.Mac`.
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
            return code == RemoteProtocol.sharedTokenRetiredCode
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
        // The fleet's requests are a member's: a device can't read the store, pair, remove or sync (what it may read is `fleet.view.v1`: `FleetDeviceViewTests`).
        let attempts: [(String, () async throws -> Void)] = [
            ("fleetAction", { _ = try await client.fleetAction(.startJoin) }),
            ("fleetRevoke", { try await client.fleetRevoke(hostID: UUID(), at: 1) }),
            ("fleetSyncDevices", { _ = try await client.fleetSyncDevices([]) }),
            ("fleetIntroduce", { _ = try await client.fleetIntroduce(FleetIntroduce(member: FleetMember(hostID: UUID(), name: "x", host: "127.0.0.1", port: 7434), theirTokenHash: nil)) }),
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

    // MARK: The old shared token

    /// A host takes no token shared by every client: a client that presents one is told so, and what to do, and the file a
    /// host once kept it in is never read, so even a client that has its content is refused.
    @Test func aClientPresentingTheOldSharedTokenIsRefusedEvenIfTheFileStillExists() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let old = FleetProtocol.makeToken()
        try Data(old.utf8).write(to: mac.host.dir.appendingPathComponent("remote-token"))
        let client = RemoteHostClient()
        defer { client.disconnect() }
        do {
            _ = try await client.connect(host: "127.0.0.1", port: mac.port, token: old, clientName: "Shepherd iOS")
            Issue.record("the old shared token was accepted")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == RemoteProtocol.sharedTokenRetiredCode)
            #expect(message == "This Mac no longer accepts the old shared token. Pair again with a code.")
        }
        let failure = RemoteHostFailure(RemoteHostClientError.rejected(code: RemoteProtocol.sharedTokenRetiredCode, message: ""))
        #expect(failure.kind == .sharedTokenRetired && !failure.retries)
        // Nothing was written back or made of the file.
        #expect(try String(contentsOf: mac.host.dir.appendingPathComponent("remote-token"), encoding: .utf8) == old)
        // A device's own token and this Mac's own app are unchanged.
        let phone = Device()
        defer { phone.stop() }
        _ = try await phone.pair(with: mac, code: try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code)
        try await phone.connect(to: mac)
        #expect(try await mac.read().hostID != nil)
    }

    /// The `hello` of a client that has no token at all, or the wrong one, is refused the same way.
    @Test func aTokenThatIsNoDevicesAndNoMacsIsRefusedWithTheSamePairAgainMessage() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        for token in ["", "not-a-token", String(repeating: "0", count: 64)] {
            let refused = await Self.refused(token, by: mac)
            #expect(refused, "\(token.isEmpty ? "empty" : token)")
        }
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

    // MARK: A Mac with no other Mac

    /// A device needs no other Mac: a Mac that has none still takes a phone by code, lists it and revokes it, and its fleet is
    /// there for the Macs that come.
    @Test func aPhonePairsByCodeWithAMacThatHasNoOtherMac() async throws {
        let mac = try await Mac("MacBook Pro")
        defer { mac.stop() }
        let snapshot = try await mac.read()
        #expect(snapshot.enabled && snapshot.peers.isEmpty && snapshot.port == mac.port && snapshot.devices?.devices.isEmpty == true)

        let phone = Device()
        defer { phone.stop() }
        let code = try #require(try await mac.local.fleetAction(.startDeviceCode).deviceCode).code
        let paired = try await phone.pair(with: mac, code: code)
        #expect(paired.name == "MacBook Pro" && paired.members.isEmpty)
        let client = try await phone.connect(to: mac)
        #expect(!client.capabilities.contains(RemoteProtocol.fleetCapability) && !client.capabilities.contains(RemoteProtocol.fleetDevicesCapability))
        let listed = try await Self.devices(mac)
        #expect(listed.map(\.name) == ["iPhone"] && listed.first?.connected == true)

        let identity = try #require(await RemoteHostClient.fleetProbe(host: "127.0.0.1", port: mac.port))
        #expect(identity.fleetEnabled, "every host says Fleet is on")

        // Revoke works, and ends the connection.
        _ = try await mac.local.fleetAction(.revokeDevice(phone.intro.deviceID))
        try await eventually("the phone's connection to end") { phone.disconnected.current }
        let refusedAfter = await Self.refused(phone.token, by: mac)
        #expect(refusedAfter)
    }
}
