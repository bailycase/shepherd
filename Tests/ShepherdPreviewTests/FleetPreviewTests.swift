import AppKit
import Foundation
import ShepherdProtocol
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

    static func model(peers: [FleetPeerStatus], port: UInt16? = 7434) -> FleetSettingsModel {
        let model = FleetSettingsModel()
        let snapshot = FleetSnapshot(enabled: true, hostID: UUID(), name: "MacBook Pro", addresses: ["192.168.1.40"], port: port,
                                     advertising: port != nil, peers: peers)
        model.snapshot = snapshot
        model.rows = FleetMacRow.rows(of: snapshot, locale: Locale(identifier: "en_US"), calendar: Calendar(identifier: .gregorian))
        model.loaded = true
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
    static func pairing(found: [FoundMac], failure: String? = nil, code: String = "") -> FleetPairSheet {
        let model = Self.model(peers: [])
        model.browse = { update in update(found); return {} }
        if let failure { model.pairing = .failed(failure) }
        return FleetPairSheet(model: model, code: code) {}
    }

    @Test func addAMac() async throws {
        try await Preview.render("fleet-pair", size: CGSize(width: 640, height: 760)) {
            Self.pairing(found: Self.found).padding(SH.Space.xxl).frame(width: 640, height: 760).background(Color.sh.scrim)
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
}
