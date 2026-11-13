import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What a paired phone or iPad may do with a fleet (`fleet.view.v1`), between real scratch hosts: read the
/// Macs, their load and readiness; ask a Mac to sample while it looks; choose where work is sent through the
/// Mac's own host setting, which the fleet then syncs. Nothing of the fleet's store, no pairing, no removing,
/// and no way to speak for a Mac. Every phone here pairs with a made up code and holds a token of its own.
@Suite("Fleet view for devices", .integrationTimeLimit)
struct FleetDeviceViewTests {
    typealias Phone = FleetDevicesIntegrationTests.Device

    /// A phone paired with `mac` and connected to it.
    static func phone(port: UInt16, local: RemoteHostClient) async throws -> (phone: Phone, client: RemoteHostClient) {
        let phone = Phone("Ada's iPhone")
        let code = try #require(try await local.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: port, code: code, device: phone.intro)
        phone.client.disconnect()
        phone.client = RemoteHostClient()
        _ = try await phone.client.connect(host: "127.0.0.1", port: port, token: phone.token, clientName: phone.intro.name)
        return (phone, phone.client)
    }

    static func forbidden(_ what: String, _ attempt: () async throws -> Void) async {
        do { try await attempt(); Issue.record("\(what): a device did what a member does") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden, "\(what): \(code)") }
        catch { Issue.record("\(what): \(error)") }
    }

    // MARK: Reading

    @Test func aPairedDeviceReadsEachMacsLoadAndReadinessAndNothingOfHowTheyAreReached() async throws {
        let a = try await FleetPressureIntegrationTests.Mac("MacBook Pro", busy: 30), b = try await FleetPressureIntegrationTests.Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await FleetPressureIntegrationTests.pair(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())
        let (phone, client) = try await Self.phone(port: a.port, local: a.local)
        defer { phone.stop() }

        // The view is offered; the member's capabilities are not.
        #expect(client.capabilities.contains(RemoteProtocol.fleetViewCapability))
        for capability in RemoteProtocol.fleetMemberCapabilities { #expect(!client.capabilities.contains(capability), "\(capability)") }

        // Each Mac's reading and readiness arrive, this one's own and the peer's it was pushed.
        try await eventually("the device to read both Macs' samples and reports") {
            let macs = try await client.fleetRead().snapshot.macs
            return [aID, bID].allSatisfy { id in macs.first { $0.hostID == id }.map { $0.sample != nil && $0.readiness != nil } ?? false }
        }
        let view = try await client.fleetRead().snapshot
        #expect(view.enabled && view.hostID == aID && view.name == "MacBook Pro")
        #expect(view.peers.map(\.name) == ["Mac mini"] && view.peers.first?.hostID == bID && view.peers.first?.link == .connected)
        let mini = try #require(view.macs.first { $0.hostID == bID })
        #expect(mini.readiness?.model == "Mac mini" && mini.readiness?.missing == [FleetMissingTool(kind: .git)])
        #expect(try #require(mini.sample).cpuCount == 8)

        // How the Macs are reached, who is paired and what syncs stay on the Mac.
        #expect(view.addresses.isEmpty && view.port == nil && view.build == nil && !view.advertising)
        #expect(view.peers.allSatisfy { $0.host == nil && $0.port == nil })
        #expect(view.join == nil && view.sync == nil && view.devices == nil)
        let full = try await a.read()
        #expect(!full.addresses.isEmpty || full.port != nil, "the Mac's own app still reads all of it")
        #expect(full.devices?.devices.map(\.name) == ["Ada's iPhone"])
    }

    @Test func aDeviceThatIsRefusedAnythingElseOfTheFleetChangesNothing() async throws {
        let a = try await FleetPressureIntegrationTests.Mac("MacBook Pro", busy: 30), b = try await FleetPressureIntegrationTests.Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await FleetPressureIntegrationTests.pair(a, b)
        let bID = try await b.hostID()
        let (phone, client) = try await Self.phone(port: a.port, local: a.local)
        defer { phone.stop() }
        let before = try await a.read()

        // A member's requests: no sync, no pushing load, no speaking for a Mac.
        let sample = FleetPressureSample(cpuUtilization: 0.01, cpuCount: 64, totalMemoryBytes: 1 << 40, availableMemoryBytes: 1 << 40)
        await Self.forbidden("fleetSync") { _ = try await client.fleetSyncState(.hello(vector: FleetVersionVector())) }
        await Self.forbidden("fleetBlob") { _ = try await client.fleetSync(.blob(hash: "00", offset: 0)) }
        await Self.forbidden("fleetPressure") { try await client.fleetPressure(sample) }
        await Self.forbidden("fleetReadiness") { try await client.fleetReadiness(FleetReadinessReport(model: "Mac Pro")) }
        await Self.forbidden("fleetPressureNow") { _ = try await client.fleetPressureNow() }
        await Self.forbidden("fleetRevoke") { try await client.fleetRevoke(hostID: bID, at: 1) }
        // The app's actions: no pairing, joining, removing, reconnecting, handing over, or managing devices and tokens.
        let actions: [FleetAction] = [
            .startJoin, .stopJoin, .pair(host: "127.0.0.1", port: b.port, code: "000000"), .remove(hostID: bID), .adopt([]),
            .reconnect(hostID: bID), .startDeviceCode, .stopDeviceCode, .revokeDevice(UUID()), .forgetLegacyClient("x"), .retireSharedToken,
            .enrollApp(name: "Mac app"),
        ]
        for action in actions { await Self.forbidden("\(action)") { _ = try await client.fleetAction(action) } }

        // Nothing moved: the same Macs, no code window, no device gone, the shared token still accepted.
        let after = try await a.read()
        #expect(after.peers.map(\.hostID) == before.peers.map(\.hostID) && after.peers.allSatisfy { $0.link == .connected })
        #expect(after.join == nil && after.devices?.code == nil && after.devices?.devices.count == 1 && after.devices?.sharedToken.retired == false)
        #expect(try await b.read().peers.map(\.hostID) == [try await a.hostID()], "the other Mac never heard of a removal")
        #expect(try await a.state(of: try await a.hostID())?.sample?.cpuCount == 8, "no reading was filed in a Mac's name")
    }

    @Test func aClientOnTheSharedTokenReadsTheSameView() async throws {
        let a = try await FleetPressureIntegrationTests.Mac("MacBook Pro", busy: 30), b = try await FleetPressureIntegrationTests.Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await FleetPressureIntegrationTests.pair(a, b)
        let client = RemoteHostClient()
        defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: a.port, token: a.sharedToken, clientName: "Shepherd iOS")
        let view = try await client.fleetRead().snapshot
        #expect(view.peers.map(\.name) == ["Mac mini"] && view.addresses.isEmpty && view.devices == nil)
        await Self.forbidden("fleetAction") { _ = try await client.fleetAction(.startJoin) }
    }

    // MARK: Looking makes the host sample

    @Test func aMacWithNoPeerSamplesWhileADeviceLooksAndStopsWhenItStopsOrGoes() async throws {
        let a = try await FleetPressureIntegrationTests.Mac("MacBook Pro", busy: 30)
        defer { a.stop() }
        let (phone, client) = try await Self.phone(port: a.port, local: a.local)
        defer { phone.stop() }
        #expect(!a.isSampling)
        _ = try await client.fleetAction(.watching(true))
        try await eventually("the Mac to sample for the device") { a.isSampling }
        let view = try await client.fleetRead().snapshot
        #expect(view.addresses.isEmpty, "watching answers the same cut down view")
        _ = try await client.fleetAction(.watching(false))
        try await eventually("sampling to stop") { !a.isSampling }

        _ = try await client.fleetAction(.watching(true))
        try await eventually("the Mac to sample again") { a.isSampling }
        phone.stop()
        try await eventually("sampling to stop when the device's connection closes") { !a.isSampling }
    }

    @Test func withFleetOffADeviceIsOfferedNoViewAndIsRefused() async throws {
        let a = try await FleetPressureIntegrationTests.Mac("MacBook Pro", busy: 30)
        defer { a.stop() }
        let (phone, client) = try await Self.phone(port: a.port, local: a.local)
        defer { phone.stop() }
        #expect(client.capabilities.contains(RemoteProtocol.fleetViewCapability))
        a.server.setFleetEnabledAndWait(false)
        try await eventually("the capability to be withdrawn") { !client.capabilities.contains(RemoteProtocol.fleetViewCapability) }
        for attempt in [{ _ = try await client.fleetRead() }, { _ = try await client.fleetAction(.watching(true)) }] as [() async throws -> Void] {
            do { try await attempt(); Issue.record("a device read a fleet that is off") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.off) }
        }
        #expect(!a.isSampling)
    }

    // MARK: The one write

    /// The weight is a fleet setting: a device writes it to one Mac through the Mac's host setting request, the
    /// Mac applies it as its own Settings would, and the fleet syncs it to the others.
    @Test func aDeviceChoosesWhereWorkIsSentThroughOneMacAndTheFleetFollows() async throws {
        let (a, b) = try await FleetSyncTests.pair()
        defer { a.stop(); b.stop() }
        a.server.onRemoteHostSettings = { [a] request, completion in
            if case .change(let change) = request { a.change(change) }
            completion(.success(a.settings.current))
        }
        let (phone, client) = try await Self.phone(port: a.port, local: a.local)
        defer { phone.stop() }
        let studio = UUID()
        let key = FleetSendWeight.settingKey(hostID: studio)

        // The device is offered the change (it is a view capability, not a member's).
        #expect(client.capabilities.contains(RemoteProtocol.fleetViewCapability) && !client.capabilities.contains(RemoteProtocol.fleetPressureCapability))
        #expect(try await client.hostSettings().fleetWeights.isEmpty)
        let written = try await client.hostSettings(.change(.fleetWeight(hostID: studio, weight: .prefer)))
        #expect(written.fleetWeights[key] == .prefer)
        try await eventually("the other Mac to hold the weight the device chose on the first") { b.settings.current.fleetWeights[key] == .prefer }

        // A later choice on the other Mac reaches the device's Mac, and the device reads it back.
        b.change(.fleetWeight(hostID: studio, weight: .manualOnly))
        try await eventually("the device's Mac to follow") { a.settings.current.fleetWeights[key] == .manualOnly }
        #expect(try await client.hostSettings().fleetWeights[key] == .manualOnly)
    }
}
