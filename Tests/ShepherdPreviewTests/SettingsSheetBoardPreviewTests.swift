import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
@testable import ShepherdRemote
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Settings boards' form sheets (`gset`: SettingsFleetAddMac, AddMacSSH, AddDevice, DeviceAdded), each at the width its board
/// draws and as tall as it needs, so a render sets beside `<Board>@2x.png` at SHEPHERD_PREVIEW_SCALE=2.
@Suite("Settings sheets against their boards", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct SettingsSheetBoardPreviewTests {
    /// A sheet on the window's own fill, top aligned in a window `height` tall.
    static func framed<V: View>(_ sheet: V, width: CGFloat, height: CGFloat) -> some View {
        sheet.frame(width: width, height: height, alignment: .top).background(Color.sh.bgWindow)
    }

    @Test func fleetAddMac() async throws {
        let found = [FoundMac(id: "mini", name: "mini", version: "0.236.4", idHash: nil, address: "mini.local · 192.168.1.24", port: 7434),
                     FoundMac(id: "studio", name: "studio", version: "0.236.2", idHash: nil, address: "studio.local · 192.168.1.31", port: 7434)]
        let model = FleetPairAnywherePreviewTests.macBook(browse: found)
        let width = AppLayout.fleetPairWidth
        try await Preview.render("sheet-fleet-add-mac", size: CGSize(width: width, height: 560), ready: { model.found.count == 2 }) {
            Self.framed(FleetPairSheet(model: model, code: "482913", picked: "mini") {}, width: width, height: 560)
        }
    }

    @Test func fleetAddMacOverSSH() async throws {
        let state = await FleetPairAnywherePreviewTests.found(typed: "bailey@studio.tail0c2e.ts.net")
        let model = FleetPairAnywherePreviewTests.sshModel(state)
        model.sshTarget = "bailey@studio.tail0c2e.ts.net"
        model.pairing = .working
        let width = AppLayout.fleetPairWidth
        try await Preview.render("sheet-fleet-add-mac-ssh", size: CGSize(width: width, height: 800)) {
            Self.framed(FleetPairSheet(model: model, code: "317604") {}, width: width, height: 800)
        }
    }

    @Test func fleetAddDevice() async throws {
        let model = FleetPairAnywherePreviewTests.miniAddingADevice()
        model.deviceCode = .init(code: "482913", expiresAt: Date().addingTimeInterval(4 * 60 + 12))
        let width = AppLayout.fleetJoinWidth
        try await Preview.render("sheet-fleet-add-device", size: CGSize(width: width, height: 700)) {
            Self.framed(FleetDeviceSheet(model: model) {}, width: width, height: 700)
        }
    }

    @Test func fleetDeviceAdded() async throws {
        let model = FleetPairAnywherePreviewTests.miniAddingADevice()
        model.deviceCodeEnd = .added("Bailey’s iPhone")
        let width = AppLayout.fleetJoinWidth
        try await Preview.render("sheet-fleet-device-added", size: CGSize(width: width, height: 260)) {
            Self.framed(FleetDeviceSheet(model: model) {}, width: width, height: 260)
        }
    }

    /// Settings ▸ Fleet in the board's state (SettingsFleet): three Macs, two devices, a synced line.
    @Test func fleetPage() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        let ms = FleetPreviewTests.ms
        let peers = [FleetPeerStatus(hostID: UUID(), name: "Mac mini", host: "192.168.1.52", port: 7434, pairedAt: ms - 20 * 86_400_000, link: .connected),
                     FleetPeerStatus(hostID: UUID(), name: "Mac Studio", host: "192.168.1.60", port: 7434, pairedAt: ms - 9 * 86_400_000, link: .offline)]
        let devices = FleetDevicesSnapshot(devices: [
            FleetDeviceStatus(deviceID: UUID(), name: "iPhone", kind: .iphone, pairedAt: ms - 6 * 86_400_000, connected: true),
            FleetDeviceStatus(deviceID: UUID(), name: "iPad Pro", kind: .ipad, pairedAt: ms - 4 * 86_400_000, connected: false, lastSeen: ms - 86_400_000)])
        let model = FleetPreviewTests.model(peers: peers, devices: devices)
        vm.fleet.snapshot = model.snapshot
        vm.fleet.rows = model.rows
        vm.fleet.deviceRows = model.deviceRows
        vm.fleet.syncLine = model.syncLine
        vm.fleet.loaded = true
        vm.fleet.devicesReady = true
        vm.settingsSection = .fleet
        vm.settings.fleetAutoDispatch = true
        vm.settings.fleetThreadsCanSend = true
        vm.settings.fleetThreadCap = 2
        try await Preview.render("sheet-fleet-page", size: CGSize(width: AppLayout.settingsModalWidth, height: 1040)) {
            SettingsView(vm: vm)
        }
    }

    /// Ignored files · Per space… (SettingsFleetIgnored).
    @Test func fleetIgnored() async throws {
        let space = FleetExcludeSpace(id: SpaceID(), name: "payments-api",
                                      excludes: FleetSnapshotExcludes(excluded: ["packages/web/dist", "coverage"], included: [".build"]))
        let width = AppLayout.fleetExcludesWidth
        try await Preview.render("sheet-fleet-ignored", size: CGSize(width: width, height: 480)) {
            Self.framed(FleetExcludesSheet(spaces: [space], save: { _, _ in }, done: {}), width: width, height: 480)
        }
    }
}
