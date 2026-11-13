import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Fleet page, its sidebar row and its palette row in light and dark (FleetA, FleetSidebar,
/// CommandPalette): three fixture Macs through the real derivations. A MacBook Pro on battery at
/// 72% CPU, a Mac mini with room that lacks a CLI, and a Mac Studio asleep.
@Suite("Fleet page previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetPagePreviewTests {
    static let gib: UInt64 = 1 << 30
    static let here = UUID(), mini = UUID(), studio = UUID()
    static let seenAt = Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date())!.timeIntervalSince1970 * 1000

    static var snapshot: FleetSnapshot {
        FleetSnapshot(
            enabled: true, hostID: here, name: "MacBook Pro", addresses: ["192.168.1.40"], port: 7434, advertising: true,
            peers: [FleetPeerStatus(hostID: mini, name: "Mac mini", host: "192.168.1.52", port: 7434, pairedAt: 1, link: .connected),
                    FleetPeerStatus(hostID: studio, name: "Mac Studio", host: "192.168.1.60", port: 7434, pairedAt: 2, link: .offline, lastSeen: seenAt)],
            macs: [
                FleetMacState(hostID: here, sample: FleetPressureSample(cpuUtilization: 0.72, cpuCount: 12, totalMemoryBytes: 36 * gib,
                                                                         availableMemoryBytes: UInt64(9.4 * Double(gib)), thermal: .fair, onBattery: true,
                                                                         batteryPercent: 41, activeAgents: 3), sampleAge: 1,
                              readiness: FleetReadinessReport(model: "MacBook Pro", chip: "M4 Pro", repos: ["acme-web", "payments-api", "web"])),
                FleetMacState(hostID: mini, sample: FleetPressureSample(cpuUtilization: 0.18, cpuCount: 14, totalMemoryBytes: 64 * gib,
                                                                         availableMemoryBytes: 41 * gib, activeAgents: 3), sampleAge: 2,
                              readiness: FleetReadinessReport(model: "Mac mini", chip: "M4 Pro", missing: [FleetMissingTool(kind: .binary, name: "muse")],
                                                              repos: ["acme-web", "payments-api", "orders-svc"])),
                FleetMacState(hostID: studio, readiness: FleetReadinessReport(model: "Mac Studio", chip: "M3 Ultra", repos: ["acme-web", "ml-eval"])),
            ])
    }

    /// Fleet on in the view model with the fixture Macs, and no host answering over them: the
    /// preview's own host never starts a fleet (no listener, no advertisement), and what it says
    /// of one when the app connects must not replace them.
    static func seedFleet(_ workspace: PreviewWorkspace) {
        workspace.settings.onFleetChange = nil
        workspace.vm.fleet.onSnapshot = nil
        workspace.settings.fleetEnabled = true
        workspace.settings.setFleetWeight(.prefer, of: mini)
        workspace.vm.fleetPage.update(snapshot)
    }

    static func page(_ snapshot: FleetSnapshot = snapshot, weights: [UUID: FleetSendWeight] = [mini: .prefer]) -> FleetPage {
        FleetPagePresentation.make(snapshot: snapshot, weight: { weights[$0] ?? .normal })
    }

    static let noActions = FleetPageActions(choose: { _, _ in }, retry: { _ in }, openSettings: {}, addMac: {})

    @Test func fleetPage() async throws {
        let page = Self.page()
        try await Preview.renderMatrix("fleet3a-page", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: page, actions: Self.noActions).frame(width: 1208, height: 900)
        }
    }

    /// The Dispatches log with real records: a sent thread, one the person picked a Mac for, a finished one, one
    /// waiting for a sleeping Mac, a held one and a refused one.
    @Test func dispatchesLog() async throws {
        let now = Date()
        func record(_ title: String, _ state: FleetDispatchState, ago: TimeInterval, kind: FleetDispatchRecord.Kind = .agentDispatch, parent: String = "Speed up checkout CI",
                    host: String? = "Mac mini", reasons: [FleetPlacementReason] = [], failure: String? = nil) -> FleetDispatchRecord {
            FleetDispatchRecord(kind: kind, parentHostID: Self.here, parentHostName: "MacBook Pro", parentTitle: kind == .userThread ? "" : parent,
                                targetHostName: host, state: state, failure: failure, title: title, task: "", repoKey: "github.com/acme/web",
                                reasonCodes: reasons, createdAt: (now.timeIntervalSince1970 - ago) * 1000)
        }
        var snapshot = Self.snapshot
        snapshot.dispatches = [
            record("Fix flaky payment test", .running, ago: 240, reasons: [FleetPlacementReason(.localIneligible, skip: "cpu"), FleetPlacementReason(.mostRoom)]),
            record("Migrate orders to Postgres 17", .running, ago: 1_320, kind: .userThread, reasons: [FleetPlacementReason(.named)]),
            record("Bump Swift tools to 6.2", .done, ago: 3_600, parent: "Regenerate API client", reasons: [FleetPlacementReason(.mostRoom)]),
            record("Profile cold launch", .waitingWake, ago: 7_200, kind: .userThread, host: "Mac Studio"),
            record("Add retry to webhooks", .heldLimit, ago: 9_000, host: nil),
            record("Index the changelog", .failed, ago: 10_800, parent: "Regenerate API client", host: nil, failure: FleetDispatchCode.repoMissing),
        ]
        let page = FleetPagePresentation.make(snapshot: snapshot, weight: { [Self.mini: FleetSendWeight.prefer][$0] ?? .normal }, now: now)
        try await Preview.renderMatrix("fleet4a-page-dispatches", size: CGSize(width: 1208, height: 990)) {
            FleetPageContent(page: page, actions: Self.noActions).frame(width: 1208, height: 990)
        }
    }

    /// A Mac with nothing reported yet, one connecting, a full one, and a lone Mac: the other states.
    @Test func fleetPageStates() async throws {
        var snapshot = Self.snapshot
        snapshot.peers[0].link = .connecting
        snapshot.macs.removeAll { $0.hostID == Self.mini }
        snapshot.macs[0].sample?.cpuUtilization = 0.97
        snapshot.macs[0].readiness?.missing = [FleetMissingTool(kind: .xcode), FleetMissingTool(kind: .binary, name: "muse")]
        let page = Self.page(snapshot, weights: [Self.here: .manualOnly])
        try await Preview.renderMatrix("fleet3a-page-states", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: page, actions: Self.noActions).frame(width: 1208, height: 900)
        }
        var alone = Self.snapshot
        alone.peers = []
        alone.macs = [alone.macs[0]]
        let lone = Self.page(alone)
        try await Preview.render("fleet3a-page-alone", size: CGSize(width: 1208, height: 620)) {
            FleetPageContent(page: lone, actions: Self.noActions).frame(width: 1208, height: 620)
        }
    }

    /// FleetA's window: the sidebar with its Fleet row beside the page, through the real view model.
    @Test func fleetInTheWindow() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let space = Space(name: "acme-web", path: workspace.dir.path)
        var rows: [(Agent, ShepherdCore.Tab)] = []
        for (index, (name, status)) in [("Pick a retention window", AgentStatus.blocked), ("Speed up checkout CI", .working),
                                        ("Migrate orders to Postgres 17", .working), ("Regenerate API client", .idle)].enumerated() {
            var (agent, tab) = try await workspace.agent(name, in: space, order: index, status: status)
            agent.lastActiveAt = Date().timeIntervalSince1970 * 1000 - Double(index) * 60_000
            if status == .blocked { agent.waitingOn = "Keep 30 or 90 days?"; agent.waitingReason = "retention" }
            rows.append((agent, tab))
        }
        try await workspace.seed(ShepherdState(spaces: [space], tabs: rows.map(\.1), agents: rows.map(\.0)))
        // The preview's host never starts a fleet: no listener, no advertisement.
        Self.seedFleet(workspace)
        workspace.vm.openDestination(.fleet)
        #expect(workspace.vm.shownDestination == .fleet)
        #expect(workspace.vm.settings.fleetEnabled && !workspace.vm.fleetPage.page.cards.isEmpty)
        let page = workspace.vm.fleetPage.page
        try await Preview.renderMatrix("fleet3a-window", size: CGSize(width: 1440, height: 900)) {
            HStack(spacing: 0) {
                SidebarView(vm: workspace.vm).frame(width: AppLayout.sidebarDefaultWidth)
                FleetPageContent(page: page, actions: Self.noActions)
            }
            .frame(width: 1440, height: 900)
        }
    }

    /// The footer: Fleet closed, selected, nothing asleep, and a Mac alone; with Fleet off it is the user's row.
    @Test func sidebarFooter() async throws {
        let all = Self.page().footer
        let awake = Self.page(Self.awake).footer
        var lone = Self.snapshot
        lone.peers = []
        lone.macs = [lone.macs[0]]
        let alone = Self.page(lone).footer
        try await Preview.renderMatrix("fleet3a-footer", size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 4 * 64)) {
            VStack(spacing: 0) {
                SidebarFleetFooter(footer: all, selected: false, open: {}, settings: {})
                SidebarFleetFooter(footer: all, selected: true, open: {}, settings: {})
                SidebarFleetFooter(footer: awake, selected: false, open: {}, settings: {})
                SidebarFleetFooter(footer: alone, selected: false, open: {}, settings: {})
            }
            .frame(width: AppLayout.sidebarDefaultWidth)
            .background(Color.sh.bgBase)
        }
    }

    static var awake: FleetSnapshot {
        var snapshot = Self.snapshot
        snapshot.peers[1].link = .connected
        snapshot.macs[2].sample = snapshot.macs[1].sample
        snapshot.macs[2].sampleAge = 3
        return snapshot
    }

    /// "fleet" in the palette finds Open Fleet with how many Macs sleep, from the view model's own items.
    @Test func openFleetInThePalette() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await workspace.seed(ShepherdState())
        Self.seedFleet(workspace)
        let item = try #require(workspace.vm.paletteItems.first { $0.id == "action.openFleet" })
        #expect(item.title == "Open Fleet" && item.subtitle == "1 asleep")
        try await Preview.renderMatrix("fleet3a-palette", size: CGSize(width: 1000, height: 420)) {
            Color.sh.bgWindow
                .shCommandPalette(isPresented: .constant(true)) {
                    PaletteCard(items: workspace.vm.paletteItems, run: { _ in }, close: {}, initialQuery: "open f")
                }
        }
    }
}
