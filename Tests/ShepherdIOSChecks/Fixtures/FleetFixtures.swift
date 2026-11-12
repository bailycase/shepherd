import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Fleet on the phone, iPad and Duo (FleetA-phone, iPadFleet, DuoOpenFleet, DuoClosedFleet, DuoBookFleet): the Macs a
// paired device reads from the first Mac that serves `fleet.view.v1`. Made up Macs and projects only.
extension FixtureCatalog {
    static var fleetScreens: [FixtureScreen] {
        [
            // The Fleet screen, as a Mac's host answers it: a MacBook Pro on battery, a Mac mini with room, a Mac Studio asleep.
            FixtureScreen(name: "fleet", hosts: FleetFixtureData.hosts(), routes: [.settings(.fleet)], tab: .settings,
                          prepare: { app in await FleetFixtureData.settle(app) }),
            // Settings' own entry, among the Machines.
            FixtureScreen(name: "fleet-settings", hosts: FleetFixtureData.hosts(), routes: [.settings(.root)], tab: .settings,
                          prepare: { app in await FleetFixtureData.settle(app) }),
            // A fleet of one Mac, and one with a Mac that has no room and one that hasn't answered yet.
            FixtureScreen(name: "fleet-alone", hosts: FleetFixtureData.hosts(snapshot: FleetFixtureData.alone()), routes: [.settings(.fleet)],
                          tab: .settings, prepare: { app in await FleetFixtureData.settle(app) }),
            // iPhone Duo folded shut (the hinge's callback, which a pose set before the app starts never fires) and open or half open.
            FixtureScreen(name: "fleet-closed", hosts: FleetFixtureData.hosts(), routes: [.settings(.fleet)], tab: .settings,
                          prepare: { app in
                app.navigator.hingeClosed = true
                await FleetFixtureData.settle(app)
            }),
            FixtureScreen(name: "fleet-open", hosts: FleetFixtureData.hosts(), routes: [.settings(.fleet)], tab: .settings,
                          prepare: { app in
                app.navigator.hingeClosed = false
                await FleetFixtureData.settle(app)
            }),
            // The iPad's Settings list with Fleet beside its page.
            FixtureScreen(name: "fleet-pad-settings", hosts: FleetFixtureData.hosts(), routes: [.settings(.root)], tab: .settings,
                          prepare: { app in
                app.navigator.settingsSelection.page = .fleet
                await FleetFixtureData.settle(app)
            }),
            FixtureScreen(name: "fleet-busy", hosts: FleetFixtureData.hosts(snapshot: FleetFixtureData.busy()), routes: [.settings(.fleet)],
                          tab: .settings, prepare: { app in await FleetFixtureData.settle(app) }),
        ]
    }
}

enum FleetFixtureData {
    static let here = UUID(uuidString: "F1EE0000-0000-4000-8000-0000000000A1")!
    static let mini = UUID(uuidString: "F1EE0000-0000-4000-8000-0000000000A2")!
    static let studio = UUID(uuidString: "F1EE0000-0000-4000-8000-0000000000A3")!
    static let gib: UInt64 = 1 << 30

    /// 10:42 today, in the time zone of whoever renders it, so "since 10:42" reads the same on every machine.
    static var tenFortyTwo: Double {
        (Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: Date()) ?? Date()).timeIntervalSince1970 * 1000
    }

    /// The board's fleet, as the Mac the phone asks reports it (`FleetSnapshot.clientView`).
    static func snapshot() -> FleetSnapshot {
        FleetSnapshot(
            enabled: true, hostID: here, name: "MacBook Pro",
            peers: [FleetPeerStatus(hostID: mini, name: "Mac mini", pairedAt: 1, link: .connected),
                    FleetPeerStatus(hostID: studio, name: "Mac Studio", pairedAt: 2, link: .offline, lastSeen: tenFortyTwo)],
            macs: [
                FleetMacState(hostID: here, sample: FleetPressureSample(cpuUtilization: 0.72, cpuCount: 12, totalMemoryBytes: 36 * gib,
                                                                         availableMemoryBytes: UInt64(9.4 * Double(gib)), onBattery: true, batteryPercent: 41,
                                                                         activeAgents: 3), sampleAge: 1,
                              readiness: FleetReadinessReport(model: "MacBook Pro", chip: "M4 Pro", repos: ["acme-web", "payments-api"])),
                FleetMacState(hostID: mini, sample: FleetPressureSample(cpuUtilization: 0.18, cpuCount: 14, totalMemoryBytes: 64 * gib,
                                                                         availableMemoryBytes: 41 * gib, activeAgents: 3), sampleAge: 1,
                              readiness: FleetReadinessReport(model: "Mac mini", chip: "M4 Pro", repos: ["acme-web", "payments-api", "orders-svc"])),
                FleetMacState(hostID: studio, readiness: FleetReadinessReport(model: "Mac Studio", chip: "M3 Ultra", repos: ["acme-web"])),
            ])
    }

    /// Only the Mac the phone asks.
    static func alone() -> FleetSnapshot {
        var snapshot = snapshot()
        snapshot.peers = []
        snapshot.macs = [snapshot.macs[0]]
        return snapshot
    }

    /// The Mac mini at its CPU ceiling (no room), the Studio awake but with no reading yet.
    static func busy() -> FleetSnapshot {
        var snapshot = snapshot()
        snapshot.peers[1].link = .connecting
        snapshot.macs[1].sample?.cpuUtilization = 0.97
        snapshot.macs[2].sample = nil
        return snapshot
    }

    /// The usual hosts as Macs of one fleet: each online one serves the view, the weights are the board's (the mini preferred).
    static func hosts(snapshot: FleetSnapshot = snapshot()) -> [FixtureHostData] {
        FixtureData.hosts().map { host in
            var host = host
            switch host.id {
            case FixtureData.studio: host.name = "MacBook Pro"
            case FixtureData.buildBox: host.name = "Mac mini"
            default: host.name = "Mac Studio"
            }
            if host.online {
                host.fleet = snapshot
                host.hostSettings?.fleetWeights = [FleetSendWeight.settingKey(hostID: mini): .prefer]
            }
            return host
        }
    }

    /// Waits until the page has been read from the Mac, so the screenshot shows the Macs and not the spinner.
    @MainActor static func settle(_ app: MobileApp) async {
        let store = SettingsStore.of(app.hosts)
        for _ in 0..<200 {
            await store.fleet.refresh(store.hosts, watching: true)
            if !store.fleet.page.cards.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
