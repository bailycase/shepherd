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
            // Fleet is off on every Mac: the Macs this device is paired with, the third asleep (it can't be reached).
            FixtureScreen(name: "fleet-off", hosts: FleetFixtureData.hosts(snapshot: nil), routes: [.settings(.fleet)], tab: .settings),
            // Forget this Mac, as a swipe on its row (or its context menu) leads to it.
            FixtureScreen(name: "fleet-forget", hosts: FleetFixtureData.hosts(), routes: [.settings(.fleet)], tab: .settings,
                          prepare: { app in await FleetFixtureData.settle(app) }, setup: { FleetScreen.preview = .forgetting("Mac Studio") }),
            // Check, read only: what the fleet needs against each Mac (the phone's list form of FleetCheck).
            FixtureScreen(name: "fleet-check", hosts: FleetFixtureData.hosts(snapshot: FleetFixtureData.checked()), routes: [.settings(.fleet)], tab: .settings,
                          prepare: { app in await FleetFixtureData.settle(app) }, setup: { FleetScreen.preview = .check }),
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

    /// The fleet with what each Mac found when it looked at itself (`FleetCheckReport`): Mac mini has node 20 where the repos pin 22 and no muse CLI,
    /// a Mac Studio that sleeps after 10 minutes is shown from its last look.
    static func checked() -> FleetSnapshot {
        func need(_ value: String, _ state: FleetCheckItem.State = .ok) -> FleetCheckItem {
            FleetCheckItem(id: "need:node:22", group: .needs, name: "node 22", state: state, value: value, kind: .tool, tool: "node", want: "22",
                           subjects: ["payments-api", "acme-web"], sources: [".nvmrc"])
        }
        func muse(_ state: FleetCheckItem.State) -> FleetCheckItem {
            FleetCheckItem(id: "tool:muse", group: .tools, name: "muse CLI", state: state, value: state == .ok ? "Installed" : "Missing", kind: .command,
                           tool: "muse", subjects: ["muse"])
        }
        func disk(_ gb: String, _ state: FleetCheckItem.State = .ok) -> FleetCheckItem {
            FleetCheckItem(id: "disk", group: .system, name: "Free disk", state: state, value: gb, kind: .disk)
        }
        func sleep(_ value: String, _ state: FleetCheckItem.State = .ok) -> FleetCheckItem {
            FleetCheckItem(id: "sleep", group: .system, name: "Stays awake", state: state, value: value, kind: .sleep)
        }
        var snapshot = snapshot()
        snapshot.macs[0].check = FleetCheckReport(items: [need("22.11"), muse(.ok), disk("312 GB"), sleep("On battery")], packageManager: "nix")
        snapshot.macs[0].checkAge = 120
        snapshot.macs[1].check = FleetCheckReport(items: [need("Has 20.18", .warn), muse(.warn), disk("38 GB", .warn), sleep("Never sleeps")], packageManager: "nix")
        snapshot.macs[1].checkAge = 110
        snapshot.macs[2].check = FleetCheckReport(items: [need("22.4"), muse(.ok), disk("1.2 TB"), sleep("Sleeps after 10 min", .warn)], packageManager: "brew")
        snapshot.macs[2].checkAge = 7_200
        return snapshot
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
    static func hosts(snapshot: FleetSnapshot? = snapshot()) -> [FixtureHostData] {
        FixtureData.hosts().map { host in
            var host = host
            switch host.id {
            case FixtureData.studio: (host.name, host.fleetID) = ("MacBook Pro", here)
            case FixtureData.buildBox: (host.name, host.fleetID) = ("Mac mini", mini)
            default: (host.name, host.fleetID) = ("Mac Studio", studio)
            }
            if let snapshot {
                host.fleet = host.online ? snapshot : nil
                if host.online { host.hostSettings?.fleetWeights = [FleetSendWeight.settingKey(hostID: mini): .prefer] }
            } else {
                host.fleetID = nil
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
