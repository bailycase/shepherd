import Foundation
import Testing
import ShepherdProtocol

@Suite("Fleet update wire")
struct FleetUpdateWireTests {
    @Test func aStatusKeepsWhatTheHostCountedAndAnOldOneDecodesWithoutIt() throws {
        let waiting = HostUpdateStatus(version: "0.9.0", build: "671", channel: "nightly", phase: .available, offerID: UUID(), offeredVersion: "0.9.1",
                                       busyThreads: 2, waitingForIdle: true)
        #expect(try JSONDecoder().decode(HostUpdateStatus.self, from: JSONEncoder().encode(waiting)) == waiting)
        // What a Mac from before waiting sent, and what it leaves out when nothing waits.
        let old = #"{"version":"0.9.0","build":"671","channel":"nightly","phase":"available","canInstall":true}"#
        let decoded = try JSONDecoder().decode(HostUpdateStatus.self, from: Data(old.utf8))
        #expect(decoded.busyThreads == nil && !decoded.waitingForIdle && decoded.canInstall)
        let idle = String(decoding: try JSONEncoder().encode(HostUpdateStatus(version: "1", build: "2", channel: "nightly", phase: .idle)), as: UTF8.self)
        #expect(!idle.contains("waitingForIdle") && !idle.contains("busyThreads"))
    }

    @Test func aJobRoundTripsAndAnOlderOneDecodesWithDefaults() throws {
        let job = FleetUpdateStatus(hostID: UUID(), stage: .waitingForThreads, when: .idle, fromBuild: "671", offered: "0.9.1", threads: 2, startedAt: 10, updatedAt: 20)
        #expect(try JSONDecoder().decode(FleetUpdateStatus.self, from: JSONEncoder().encode(job)) == job)
        let bare = try JSONDecoder().decode(FleetUpdateStatus.self, from: Data(#"{"hostID":"\#(UUID().uuidString)","stage":"installing"}"#.utf8))
        #expect(bare.when == .idle && bare.startedAt == 0 && bare.threads == nil)
        #expect(FleetUpdateStatus.Stage.installing.isRunning && !FleetUpdateStatus.Stage.needsApp.isRunning && !FleetUpdateStatus.Stage.updated.isRunning)
    }

    @Test func aSnapshotCarriesTheJobsToADeviceAndAnOldOneHasNone() throws {
        let id = UUID()
        let job = FleetUpdateStatus(hostID: id, stage: .downloading, when: .now, startedAt: 1, updatedAt: 1)
        var snapshot = FleetSnapshot(enabled: true, name: "MacBook Pro", updates: [job], app: "Shepherd Nightly")
        snapshot.peers = [FleetPeerStatus(hostID: id, name: "Mac mini", pairedAt: 1, link: .connected, takesUpdates: true)]
        let view = snapshot.clientView
        #expect(view.updates == [job] && view.app == "Shepherd Nightly" && view.peers.first?.takesUpdates == true)
        #expect(try JSONDecoder().decode(FleetSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        let old = try JSONDecoder().decode(FleetSnapshot.self, from: Data(#"{"enabled":true,"name":"x","addresses":[],"advertising":false,"peers":[]}"#.utf8))
        #expect(old.updates.isEmpty && old.app == nil)
        let peer = #"{"hostID":"\#(UUID().uuidString)","name":"Mac mini","kind":"mac","pairedAt":1,"link":"offline"}"#
        #expect(try JSONDecoder().decode(FleetPeerStatus.self, from: Data(peer.utf8)).takesUpdates == nil)
    }

    @Test func theUpdateCapabilityIsAMemberOneAndTheViewOneIsOfferedToADevice() {
        #expect(RemoteProtocol.fleetMemberCapabilities.contains(RemoteProtocol.fleetUpdateCapability))
        #expect(RemoteProtocol.fleetLinkClientCapabilities.contains(RemoteProtocol.fleetUpdateCapability))
        #expect(FleetAccess.device.isOffered(RemoteProtocol.fleetUpdateViewCapability))
        #expect(!FleetAccess.device.isOffered(RemoteProtocol.fleetUpdateCapability))
        #expect(RemoteProtocol.fleetServiceCapabilities.contains(RemoteProtocol.fleetUpdateViewCapability))
    }
}
