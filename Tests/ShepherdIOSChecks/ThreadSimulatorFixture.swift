import SwiftUI
import UIKit
import ShepherdRemote

// The screenshot harness's app: the shipped app's views and stores, fed by in-process fixture
// hosts over real TCP (`FixtureHost`). run-simulator.sh compiles it from App/iOS (all but
// App/ShepherdIOSApp.swift) and the fixtures; it is never part of the shipped app, and it never
// touches the Keychain or the user's preferences.
//
// Environment (passed by run-simulator.sh as SIMCTL_CHILD_*):
//   FIXTURE_SCREEN       a name from FixtureCatalog (default "home")
//   FIXTURE_SCHEME       light or dark (default dark)
//   FIXTURE_ORIENTATION  portrait (default) or landscape
//   FIXTURE_SIDEBAR      "shown" opens the iPad sidebar over a portrait thread
// It prints "FIXTURE READY <screen>" once the screen has settled, and
// "FIXTURE REQUESTS <host> <kinds>" for every host.

@main
struct ThreadSimulatorFixture: App {
    @State private var runner = FixtureRunner()

    var body: some Scene {
        WindowGroup {
            if let app = runner.app {
                MobileRoot(app: app)
                    .task { await runner.run() }
            } else {
                Text(runner.failure ?? "Starting fixture…")
            }
        }
    }
}

@MainActor
@Observable
final class FixtureRunner {
    private(set) var app: MobileApp?
    private(set) var failure: String?
    @ObservationIgnored private var hosts: [FixtureHost] = []
    @ObservationIgnored private let screen: FixtureScreen?
    @ObservationIgnored private let environment = ProcessInfo.processInfo.environment

    init() {
        let name = ProcessInfo.processInfo.environment["FIXTURE_SCREEN"] ?? "home"
        screen = FixtureCatalog.screen(named: name)
        guard let screen else {
            failure = "No fixture screen named \(name). Known: \(FixtureCatalog.all.map(\.name).joined(separator: ", "))"
            print("FIXTURE FAILED \(failure!)")
            return
        }
        do {
            hosts = try screen.hosts.map { data in
                let host = FixtureHost(data)
                try host.start()
                return host
            }
        } catch {
            failure = String(describing: error)
            return
        }
        // A fresh preferences domain per launch, removed first so nothing carries over.
        let suite = "shepherd.ios.fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let records = hosts.map { RemoteHostRecord(id: $0.data.id, name: $0.data.name, address: "127.0.0.1", port: $0.port) }
        defaults.set(RemoteHostRecord.encodeList(records), forKey: MobileHosts.recordsKey)
        let tokens = HostTokens.memory(Dictionary(uniqueKeysWithValues: records.map { ($0.id, FixtureHostData.token) }))
        let appearance = MobileAppearance(defaults: defaults)
        appearance.mode = environment["FIXTURE_SCHEME"] == "light" ? .light : .dark
        app = MobileApp(hosts: MobileHosts(defaults: defaults, tokens: tokens, clientName: "Shepherd fixture"), appearance: appearance)
    }

    func run() async {
        guard let app, let screen else { return }
        app.hosts.setForeground(true)
        if environment["FIXTURE_ORIENTATION"] == "landscape" {
            await wait(seconds: 5) { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                    print("FIXTURE ORIENTATION \(error.localizedDescription)")
                }
                await wait(seconds: 5) { scene.effectiveGeometry.interfaceOrientation.isLandscape }
            }
        }
        let online = Set(screen.hosts.filter(\.online).map(\.id))
        await wait(seconds: 10) { app.hosts.hosts.allSatisfy { !online.contains($0.id) || $0.phase.isConnected } }
        app.navigator.tab = screen.tab
        for route in screen.routes { app.navigator.open(route) }
        if let presented = screen.presented { app.navigator.present(presented) }
        if environment["FIXTURE_SIDEBAR"] == "shown" { app.navigator.padColumns = .all }
        if let ref = app.navigator.selectedThread {
            let store = app.threads.store(for: ref)
            await wait(seconds: 10) { store.snapshot != nil }
        }
        await screen.prepare?(app)
        try? await Task.sleep(for: .seconds(2))
        for host in hosts {
            print("FIXTURE REQUESTS \(host.data.name) \(host.requests.joined(separator: ","))")
        }
        print("FIXTURE READY \(screen.name)")
        fflush(stdout)
    }

    private func wait(seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
