import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Fleet's Devices as the host's client: Add a device shows a code, a phone pairs with it, the
/// list shows it and Revoke ends it; the shared token's retirement says what holds it back; and this
/// Mac's own app is given a token for its direct connections. Scratch hosts as `FleetSettingsFlowTests`.
@Suite("Settings ▸ Fleet devices", .mainActorExclusive)
@MainActor
struct FleetDevicesFlowTests {
    typealias FleetApp = FleetSettingsFlowTests.FleetApp

    static func pair(_ device: FleetDeviceIntroduction, with app: FleetApp, code: String) async throws -> FleetDevicesResult {
        try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: try #require(app.port), code: code, device: device).result
    }

    static func introduction(_ name: String = "iPhone", kind: FleetDeviceKind = .iphone) -> (FleetDeviceIntroduction, token: String) {
        let token = FleetProtocol.makeToken()
        return (FleetDeviceIntroduction(deviceID: UUID(), name: name, kind: kind, tokenHash: FleetProtocol.hash(token)), token)
    }

    @Test func addADeviceShowsACodeAPhonePairsWithItAndRevokeEndsIt() async throws {
        let app = try await FleetApp("MacBook Pro", serving: true)
        defer { app.stop() }
        await app.model.refresh()
        #expect(app.model.deviceRows.isEmpty && app.model.deviceCode == nil)

        await app.model.startDeviceCode()
        let shown = try #require(app.model.deviceCode)
        #expect(shown.code.count == FleetProtocol.codeLength)
        #expect(app.model.snapshot.devices?.code?.attemptsLeft == FleetProtocol.maxCodeAttempts)
        // The QR names this Mac and the same code.
        let link = FleetProtocol.pairLink(code: shown.code, advertisedID: FleetProtocol.advertisedIDHash(try #require(app.model.snapshot.hostID)))
        #expect(FleetProtocol.parsePairLink(link)?.code == shown.code)
        #expect(FleetQRCode.image(of: link) != nil)

        let (phone, token) = Self.introduction()
        _ = try await Self.pair(phone, with: app, code: shown.code)
        try await FleetSettingsFlowTests.waitFor("the device to be listed and the sheet to say so") {
            await app.model.refresh()
            return app.model.deviceCodeEnd == .added("iPhone") && app.model.deviceRows.map(\.title) == ["iPhone"]
        }
        let row = try #require(app.model.deviceRows.first)
        #expect(row.detail.hasPrefix("iPhone · paired ") && !row.connected)
        #expect(app.model.deviceCode == nil)

        let client = RemoteHostClient()
        defer { client.disconnect() }
        let dropped = Locked(false)
        client.onDisconnected = { _ in dropped.withValue { $0 = true } }
        _ = try await client.connect(host: "127.0.0.1", port: try #require(app.port), token: token, clientName: "iPhone")
        try await FleetSettingsFlowTests.waitFor("the device to show connected") {
            await app.model.refresh()
            return app.model.deviceRows.first?.detail.hasSuffix("connected here") == true
        }

        await app.model.revokeDevice(row.id)
        #expect(app.model.deviceRows.isEmpty)
        try await FleetSettingsFlowTests.waitFor("the device's connection to end") { dropped.current }
    }

    @Test func closingAddADeviceClosesItsCodeAndAnExpiredOneSaysSo() async throws {
        let app = try await FleetApp("MacBook Pro", serving: true)
        defer { app.stop() }
        await app.model.startDeviceCode()
        let code = try #require(app.model.deviceCode).code
        await app.model.stopDeviceCode()
        #expect(app.model.deviceCode == nil && app.model.deviceCodeEnd == .closed)

        let (phone, _) = Self.introduction()
        do { _ = try await Self.pair(phone, with: app, code: code); Issue.record("a closed code paired a device") }
        catch RemoteHostClientError.rejected(let refused, _) { #expect(refused == FleetProtocol.Code.notJoining) }
        #expect(app.model.deviceRows.isEmpty)
    }

    @Test func theSharedTokenStaysUntilEveryClientOnItHasSwitchedOrWasForgotten() async throws {
        let app = try await FleetApp("MacBook Pro", serving: true)
        defer { app.stop() }
        let old = RemoteHostClient()
        defer { old.disconnect() }
        _ = try await old.connect(host: "127.0.0.1", port: try #require(app.port), token: app.token, clientName: "Shepherd iOS")
        await app.model.refresh()
        let waiting = try #require(app.model.snapshot.devices?.sharedToken.waiting.first)
        #expect(waiting.name == "Shepherd iOS")

        await app.model.retireSharedToken()
        #expect(app.model.deviceProblem?.contains("One device") == true, "the host says who holds it back")
        #expect(app.model.snapshot.devices?.sharedToken.retired == false)

        await app.model.forgetWaiting(waiting.id)
        #expect(app.model.deviceProblem == nil && app.model.snapshot.devices?.sharedToken.waiting.isEmpty == true)
        await app.model.retireSharedToken()
        #expect(app.model.snapshot.devices?.sharedToken.retired == true)
    }

    /// The app's direct connection to a Mac it reached with the shared token moves to a token of its own,
    /// which every Mac of the fleet takes; the binding stays.
    @Test func aMacsAppSwitchesItsFleetManagedHostsToATokenItsHostMade() async throws {
        let a = try await FleetApp("MacBook Pro"), b = try await FleetApp("Mac mini")
        defer { a.stop(); b.stop() }
        let defaults = ScratchDefaults()
        let store = RemoteHostStore(defaults: defaults, connects: false)
        store.addHost(name: "mini", host: "127.0.0.1", port: try #require(b.port), token: b.token)
        let config = try #require(store.hosts.first)
        let outcomes = await a.model.adopt([FleetLegacyHost(id: config.id, name: "mini", host: "127.0.0.1", port: try #require(b.port), token: b.token)])
        #expect(outcomes.first?.outcome != .notFleet)
        store.markFleetManaged(id: config.id)
        #expect(store.hosts.first?.ownToken == false)

        let token = try #require(await a.model.enrollApp(name: "MacBook Pro"))
        let probe = RemoteHostClient()
        defer { probe.disconnect() }
        _ = try await probe.connect(host: "127.0.0.1", port: try #require(b.port), token: token, clientName: "MacBook Pro", capabilities: [], fetchesState: false)
        store.useOwnToken(id: config.id, token: token)

        let reloaded = try #require(RemoteHostStore(defaults: defaults, connects: false).hosts.first)
        #expect(reloaded.ownToken && reloaded.token == token && reloaded.bindingID == config.bindingID && reloaded.id == config.id)
        // A host that isn't a fleet peer keeps what it has.
        store.addHost(name: "other", host: "127.0.0.1", port: 1, token: "x")
        let other = try #require(store.hosts.last)
        store.useOwnToken(id: other.id, token: token)
        #expect(store.hosts.last?.token == "x" && store.hosts.last?.ownToken == false)
    }

    /// With Fleet off nothing needs membership: a phone pairs with a Mac by its Add a device code, and a Mac's app
    /// pairs with another Mac as a client (what Remote's Add host did) with the same flow and no pasted token.
    @Test func withFleetOffAPhonePairsAndAMacAppPairsToAnotherMacAsAClient() async throws {
        let a = try await FleetApp("MacBook Pro", fleet: false, serving: true), b = try await FleetApp("Mac mini", fleet: false, serving: true)
        defer { a.stop(); b.stop() }
        await a.model.refresh()
        #expect(a.model.devicesReady && !a.model.snapshot.enabled && a.model.rows.isEmpty && a.model.snapshot.port == a.port)

        // A phone pairs with A: code, list, revoke.
        await a.model.startDeviceCode()
        let (phone, phoneToken) = Self.introduction()
        _ = try await Self.pair(phone, with: a, code: try #require(a.model.deviceCode).code)
        try await FleetSettingsFlowTests.waitFor("the phone to be listed") {
            await a.model.refresh()
            return a.model.deviceRows.map(\.title) == ["iPhone"] && a.model.deviceCodeEnd == .added("iPhone")
        }
        let onA = RemoteHostClient()
        defer { onA.disconnect() }
        _ = try await onA.connect(host: "127.0.0.1", port: try #require(a.port), token: phoneToken, clientName: "iPhone")
        #expect(!onA.capabilities.contains(RemoteProtocol.fleetCapability))

        // A's app pairs with B as a client, through the model's pairing and the store.
        let defaults = ScratchDefaults()
        let store = RemoteHostStore(defaults: defaults, connects: false)
        a.model.pairClient = { host, port, code, expecting in try await store.pairAsClient(host: host, port: port, code: code, expecting: expecting) }
        await b.model.startDeviceCode()
        let code = try #require(b.model.deviceCode).code
        let added = await a.model.pairAsClient(with: b.found, code: code)
        #expect(added && a.model.pairing == .idle)
        let held = try #require(store.hosts.first)
        #expect(held.name == "Mac mini" && held.host == "127.0.0.1" && held.port == b.port && held.ownToken && !held.fleetManaged)
        #expect(held.token != b.token, "its own token, not the shared one")
        let reloaded = try #require(RemoteHostStore(defaults: defaults, connects: false).hosts.first)
        #expect(reloaded.ownToken && reloaded.token == held.token && reloaded.bindingID == held.bindingID)

        // B knows it as a Mac app, and it connects as a client.
        try await FleetSettingsFlowTests.waitFor("B to list the Mac app") {
            await b.model.refresh()
            return b.model.deviceRows.first?.detail.hasPrefix("Mac · paired ") == true
        }
        let asClient = RemoteHostClient()
        defer { asClient.disconnect() }
        _ = try await asClient.connect(host: "127.0.0.1", port: try #require(b.port), token: held.token, clientName: "MacBook Pro")
        #expect(!asClient.capabilities.contains(RemoteProtocol.fleetCapability))

        // The same code is spent; a wrong one says what the Mac said and adds nothing.
        let again = await a.model.pairAsClient(with: b.found, code: code)
        #expect(!again && store.hosts.count == 1)
        if case .failed(let message) = a.model.pairing { #expect(!message.isEmpty) } else { Issue.record("expected a refusal") }

        // Its row, then Remove forgets it (the Mac still lists the device until it is revoked there).
        let row = FleetMacRow.client(id: held.id, name: held.name, host: held.host, port: held.port, phase: .disconnected)
        #expect(row.title == "Mac mini" && row.detail == "127.0.0.1:\(b.port ?? 0) · disconnected" && row.state == .offline && row.hostID == held.id)
        store.removeHost(id: held.id)
        #expect(store.hosts.isEmpty)
        await b.model.refresh()
        #expect(b.model.deviceRows.count == 1)
        await b.model.revokeDevice(try #require(b.model.deviceRows.first).id)
        let refused = RemoteHostClient()
        defer { refused.disconnect() }
        do { _ = try await refused.connect(host: "127.0.0.1", port: try #require(b.port), token: held.token, clientName: "x", fetchesState: false); Issue.record("a revoked Mac app connected") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == RemoteProtocol.unauthorizedCode) }
    }

    /// A legacy host on the shared token keeps working with Fleet off, and is listed like the others.
    @Test func aLegacyHostOnTheSharedTokenStaysAndIsListedWithFleetOff() async throws {
        let a = try await FleetApp("MacBook Pro", fleet: false), b = try await FleetApp("Mac mini", fleet: false, serving: true)
        defer { a.stop(); b.stop() }
        let store = RemoteHostStore(defaults: ScratchDefaults(), connects: false)
        store.addHost(name: "mini", host: "127.0.0.1", port: try #require(b.port), token: b.token)
        let legacy = try #require(store.hosts.first)
        #expect(!legacy.ownToken && !legacy.fleetManaged)
        let probe = RemoteHostClient()
        defer { probe.disconnect() }
        _ = try await probe.connect(host: "127.0.0.1", port: try #require(b.port), token: legacy.token, clientName: "MacBook Pro")
        #expect(FleetMacRow.client(id: legacy.id, name: "mini", host: legacy.host, port: legacy.port, phase: .connected).state == .connected)
    }

    @Test func deviceRowsSayWhatEachIs() {
        let ms = 1_750_000_000_000.0
        let snapshot = FleetSnapshot(enabled: true, devices: FleetDevicesSnapshot(devices: [
            FleetDeviceStatus(deviceID: UUID(), name: "Ada's iPhone", kind: .iphone, pairedAt: ms, connected: true),
            FleetDeviceStatus(deviceID: UUID(), name: "Studio iPad", kind: .ipad, pairedAt: ms, connected: false, lastSeen: ms + 60_000),
            FleetDeviceStatus(deviceID: UUID(), name: "Mac mini", kind: .macApp, pairedAt: ms, connected: false),
        ]))
        let rows = FleetDeviceRow.rows(of: snapshot, locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian))
        #expect(rows.map(\.title) == ["Ada's iPhone", "Studio iPad", "Mac mini"])
        #expect(rows[0].detail.hasPrefix("iPhone · paired ") && rows[0].detail.hasSuffix("connected here") && rows[0].connected)
        #expect(rows[1].detail.contains("iPad") && rows[1].detail.contains("last seen") && !rows[1].connected)
        #expect(rows[2].detail.hasPrefix("Mac · paired ") && rows[2].detail.hasSuffix("not connected yet"))
        #expect(FleetDeviceRow.rows(of: FleetSnapshot(enabled: true)).isEmpty, "a host without devices lists none")
    }
}
