import AppKit
import Foundation
import ShepherdProtocol
@testable import ShepherdRemote
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings ▸ Fleet and its two sheets, in light and dark (FleetSettings, FleetPair, FleetStates):
/// see `PreviewTests` for how to run. Fixture Macs only.
@Suite("Fleet previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetPreviewTests {
    static let now = Date(timeIntervalSince1970: 1_750_000_000)
    static let ms = now.timeIntervalSince1970 * 1000

    static func model(peers: [FleetPeerStatus], port: UInt16? = 7434, devices: FleetDevicesSnapshot? = nil) -> FleetSettingsModel {
        let model = FleetSettingsModel()
        // The board's sync line: the Mac mini holds the same, the Mac Studio is away.
        let sync = peers.isEmpty ? nil : FleetSyncStatus(peers: peers.map {
            FleetSyncStatus.Peer(hostID: $0.hostID, name: $0.name, state: $0.link == .connected ? .inSync : .offline)
        })
        model.syncLine = sync.flatMap(FleetSyncPresentation.line)
        let snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", addresses: ["192.168.1.40"], port: port,
                                     advertising: port != nil, peers: peers, devices: devices)
        model.deviceRows = FleetDeviceRow.rows(of: snapshot, locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian))
        model.snapshot = snapshot
        model.rows = FleetMacRow.rows(of: snapshot, locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian))
        model.loaded = true
        model.devicesReady = devices != nil
        return model
    }

    static let peers = [
        FleetPeerStatus(hostID: UUID(), name: "Mac mini", host: "192.168.1.52", port: 7434, pairedAt: ms - 20 * 86_400_000, link: .connected),
        FleetPeerStatus(hostID: UUID(), name: "Mac Studio", host: "192.168.1.60", port: 7434, pairedAt: ms - 9 * 86_400_000, link: .connecting),
        FleetPeerStatus(hostID: UUID(), name: "iMac", host: "192.168.1.71", port: 7434, pairedAt: ms - 3 * 86_400_000, link: .offline,
                        lastSeen: ms - 3_600_000),
    ]

    static let found = [
        FoundMac(id: "mini", name: "Mac mini", version: "1.9", idHash: nil, address: "192.168.1.52", port: 7434),
        FoundMac(id: "studio", name: "Mac Studio", version: "1.9", idHash: nil, address: "192.168.1.60", port: 7434),
    ]

    @Test func settingsFleetWithMacs() async throws {
        let model = Self.model(peers: Self.peers)
        try await Preview.renderMatrix("fleet-settings", size: CGSize(width: 1000, height: 560)) {
            FleetSettings(model: model, serviceKeepsRunning: true).frame(width: 1000, height: 560).background(Color.sh.bgWindow)
        }
    }

    @Test func settingsFleetAloneAndWithTheServiceOff() async throws {
        let model = Self.model(peers: [])
        try await Preview.render("fleet-settings-alone", size: CGSize(width: 1000, height: 420)) {
            FleetSettings(model: model, serviceKeepsRunning: false).frame(width: 1000, height: 420).background(Color.sh.bgWindow)
        }
    }

    @Test func settingsFleetNotServing() async throws {
        let model = Self.model(peers: Self.peers, port: nil)
        try await Preview.render("fleet-settings-not-serving", size: CGSize(width: 1000, height: 600)) {
            FleetSettings(model: model, serviceKeepsRunning: true).frame(width: 1000, height: 600).background(Color.sh.bgWindow)
        }
    }

    /// A new model per drawing: closing a sheet stops its browsing and its code, which would empty the next theme's.
    static func pairing(found: [FoundMac], failure: String? = nil, code: String = "", findsByCode: Bool = false) -> FleetPairSheet {
        let model = Self.model(peers: [])
        model.findsByCode = findsByCode
        model.browse = { update in update(found); return {} }
        if let failure { model.pairing = .failed(failure) }
        return FleetPairSheet(model: model, code: code) {}
    }

    @Test func addAMac() async throws {
        try await Preview.render("fleet-pair", size: CGSize(width: 640, height: 760)) {
            Self.pairing(found: Self.found).padding(SH.Space.xxl).frame(width: 640, height: 760).background(Color.sh.scrim)
        }
    }

    /// The Mac mini sits on another subnet, where only Apple's own Bonjour types arrive: it is listed because Shepherd
    /// answered a probe at its address, in the same row as the Mac Studio Bonjour found.
    @Test func addAMacWithOneFoundThroughAppleServices() async throws {
        let mini = RemoteHostClient.FleetPeerIdentity(hostID: UUID(), name: "Mac mini", build: "1.9", fleetEnabled: true)
        let list = FleetNeighbors.merged(bonjour: [Self.found[1]],
                                         probed: [FleetNeighbors.found(mini, address: "192.168.20.5", port: 7434)])
        #expect(list.map(\.name) == ["Mac Studio", "Mac mini"])
        try await Preview.render("fleet-pair-found-by-probe", size: CGSize(width: 640, height: 760)) {
            Self.pairing(found: list).padding(SH.Space.xxl).frame(width: 640, height: 760).background(Color.sh.scrim)
        }
    }

    @Test func addAMacWithOneChosenAndTheCodeHalfEntered() async throws {
        try await Preview.render("fleet-pair-chosen", size: CGSize(width: 640, height: 760)) {
            Self.pairing(found: Array(Self.found.prefix(1)), code: "4829").padding(SH.Space.xxl).frame(width: 640, height: 760)
                .background(Color.sh.scrim)
        }
    }

    @Test func addAMacWithNobodyFoundAndAWrongCode() async throws {
        try await Preview.render("fleet-pair-none", size: CGSize(width: 640, height: 640)) {
            Self.pairing(found: [], failure: "That code isn't right. 4 tries left.").padding(SH.Space.xxl)
                .frame(width: 640, height: 640).background(Color.sh.scrim)
        }
    }

    /// Nobody Bonjour or a probe could find, the whole code typed: Add Mac is enabled and the host looks the code up in iCloud.
    @Test func addAMacByCodeThroughICloudWithNobodyFound() async throws {
        try await Preview.renderMatrix("fleet-pair-icloud", size: CGSize(width: 640, height: 640)) {
            Self.pairing(found: [], code: "482913", findsByCode: true).padding(SH.Space.xxl)
                .frame(width: 640, height: 640).background(Color.sh.scrim)
        }
    }

    @Test func addAMacByCodeWithNoICloudAccount() async throws {
        try await Preview.renderMatrix("fleet-pair-icloud-signed-out", size: CGSize(width: 640, height: 640)) {
            Self.pairing(found: [], failure: "Not signed in to iCloud: use a pairing link", code: "482913", findsByCode: true)
                .padding(SH.Space.xxl).frame(width: 640, height: 640).background(Color.sh.scrim)
        }
    }

    static func joining(_ end: FleetSettingsModel.JoinEnd?) -> FleetJoinView {
        let model = Self.model(peers: [])
        if let end { model.joinEnd = end } else { model.join = .init(code: "482913", expiresAt: Date().addingTimeInterval(4 * 60 + 12)) }
        return FleetJoinView(model: model) {}
    }

    @Test func joinAFleet() async throws {
        try await Preview.render("fleet-join", size: CGSize(width: 600, height: 380)) {
            Self.joining(nil).padding(SH.Space.xxl).frame(width: 600, height: 380).background(Color.sh.scrim)
        }
    }

    @Test func joinAFleetOpeningTheCode() async throws {
        let model = Self.model(peers: [])
        try await Preview.render("fleet-join-opening", size: CGSize(width: 600, height: 380)) {
            FleetJoinView(model: model) {}.padding(SH.Space.xxl).frame(width: 600, height: 380).background(Color.sh.scrim)
        }
    }

    @Test func joinedAndExpired() async throws {
        for (name, end) in [("fleet-joined", FleetSettingsModel.JoinEnd.joined("MacBook Pro")), ("fleet-join-expired", .closed)] {
            try await Preview.render(name, size: CGSize(width: 600, height: 280)) {
                Self.joining(end).padding(SH.Space.xxl).frame(width: 600, height: 280).background(Color.sh.scrim)
            }
        }
    }

    // MARK: Devices (slice 5)

    static let devices = FleetDevicesSnapshot(
        devices: [
            FleetDeviceStatus(deviceID: UUID(), name: "Ada's iPhone", kind: .iphone, pairedAt: ms - 6 * 86_400_000, connected: true),
            FleetDeviceStatus(deviceID: UUID(), name: "Studio iPad", kind: .ipad, pairedAt: ms - 4 * 86_400_000, connected: false, lastSeen: ms - 3_600_000),
            FleetDeviceStatus(deviceID: UUID(), name: "Mac mini", kind: .macApp, pairedAt: ms - 2 * 86_400_000, connected: false),
        ])

    @Test func settingsFleetWithDevices() async throws {
        let model = Self.model(peers: Self.peers, devices: Self.devices)
        try await Preview.renderMatrix("fleet-settings-devices", size: CGSize(width: 1000, height: 1180)) {
            FleetSettings(model: model, serviceKeepsRunning: true).frame(width: 1000, height: 1180).background(Color.sh.bgWindow)
        }
    }

    @Test func settingsFleetDevicesWithNone() async throws {
        let model = Self.model(peers: [], devices: FleetDevicesSnapshot())
        try await Preview.render("fleet-settings-devices-none", size: CGSize(width: 1000, height: 640)) {
            FleetSettings(model: model, serviceKeepsRunning: true).frame(width: 1000, height: 640).background(Color.sh.bgWindow)
        }
    }

    /// Macs this app was a client of before Fleet was how Macs connect: rows under Macs to add to the fleet or dismiss.
    static let notInFleet = [
        FleetNotInFleetMac(id: UUID(), name: "Mac Studio", host: "192.168.1.60", port: 7434),
        FleetNotInFleetMac(id: UUID(), name: "Build server", host: "build.acme.test", port: 7434),
    ]

    /// A Mac with the Mac mini in its fleet, two Macs it used to be a client of, devices and Serve this Mac.
    @Test func settingsFleetWithMigratedMacRowsDevicesAndTheListener() async throws {
        let model = Self.model(peers: [Self.peers[0]], devices: Self.devices)
        let serve = FleetServe(isOn: .constant(true), status: "Serving on port 7434", problem: nil, problemDetail: nil)
        try await Preview.renderMatrix("fleet-settings-migrated", size: CGSize(width: 1000, height: 1240)) {
            FleetSettings(model: model, serviceKeepsRunning: true, serve: serve, notInFleet: Self.notInFleet)
                .frame(width: 1000, height: 1240).background(Color.sh.bgWindow)
        }
    }

    /// A fresh Mac: nothing paired, nothing listening, Join a fleet and Add a Mac ready.
    @Test func settingsFleetOnAFreshMac() async throws {
        let model = Self.model(peers: [], port: nil, devices: FleetDevicesSnapshot())
        let serve = FleetServe(isOn: .constant(false), status: "Not listening", problem: nil, problemDetail: nil)
        try await Preview.renderMatrix("fleet-settings-fresh", size: CGSize(width: 1000, height: 760)) {
            FleetSettings(model: model, serviceKeepsRunning: true, serve: serve)
                .frame(width: 1000, height: 760).background(Color.sh.bgWindow)
        }
    }

    /// Add to fleet… on a migrated row: Add a Mac opens with that Mac picked and its saved address.
    @Test func addAMigratedMacToTheFleet() async throws {
        let model = Self.model(peers: [])
        try await Preview.render("fleet-pair-migrated", size: CGSize(width: 640, height: 700)) {
            FleetPairSheet(model: model, candidate: Self.notInFleet[0].found, code: "4829") {}
                .padding(SH.Space.xxl).frame(width: 640, height: 700).background(Color.sh.scrim)
        }
    }

    static func addingADevice(_ end: FleetSettingsModel.DeviceCodeEnd?) -> FleetDeviceSheet {
        let model = Self.model(peers: [])
        if let end { model.deviceCodeEnd = end } else { model.deviceCode = .init(code: "482913", expiresAt: Date().addingTimeInterval(4 * 60 + 12)) }
        return FleetDeviceSheet(model: model) {}
    }

    @Test func addADeviceShowsTheCodeAndItsQR() async throws {
        try await Preview.render("fleet-add-device", size: CGSize(width: 600, height: 640)) {
            Self.addingADevice(nil).padding(SH.Space.xxl).frame(width: 600, height: 640).background(Color.sh.scrim)
        }
    }

    @Test func addADeviceAddedAndExpired() async throws {
        for (name, end) in [("fleet-add-device-added", FleetSettingsModel.DeviceCodeEnd.added("Ada's iPhone")), ("fleet-add-device-expired", .closed)] {
            try await Preview.render(name, size: CGSize(width: 600, height: 280)) {
                Self.addingADevice(end).padding(SH.Space.xxl).frame(width: 600, height: 280).background(Color.sh.scrim)
            }
        }
    }
}
