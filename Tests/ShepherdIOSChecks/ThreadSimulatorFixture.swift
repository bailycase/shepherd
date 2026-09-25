import SwiftUI
import UIKit
import ShepherdRemote
import ShepherdUI

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
// A screen may open more windows (`FixtureWindows.open`); windows left from an earlier run close.
// It prints "FIXTURE READY <screen>" once the screen has settled, and
// "FIXTURE REQUESTS <host> <kinds>" for every host.

@main
struct ThreadSimulatorFixture: App {
    @State private var runner = FixtureRunner()

    var body: some Scene {
        // Windows as the shipped app has them: a window a screen opens (`FixtureWindows.open`) is
        // a `MobileWindowRoot`; any other (the launch window, or one the system restored from an
        // earlier run, which `closeOthers` then closes) runs the fixture with the app's navigator.
        WindowGroup(for: MobileWindowSeed.self) { $seed in
            if let app = runner.app {
                if !FixtureWindows.shared.opened.contains(seed.id) {
                    FixturePrimaryWindow(app: app)
                        .background(FixtureSceneProbe { scene in
                            if FixtureWindows.shared.primary == nil { FixtureWindows.shared.primary = scene }
                        })
                        .background(FixtureWindowOpener())
                        .task { await runner.run() }
                } else {
                    MobileWindowRoot(app: app, seed: seed)
                }
            } else {
                Text(runner.failure ?? "Starting fixture…")
            }
        } defaultValue: {
            MobileWindowSeed()
        }
    }
}

/// The screen's window, or, once a screen asks for Split View (`FixtureWindows.split`), it and a
/// second window side by side as iPadOS draws them: each a whole window of the app with its own
/// navigator, at half the width. The simulator can't be put in Split View headless, so the two
/// windows share one scene here; everything inside each is what the shipped app shows.
private struct FixturePrimaryWindow: View {
    let app: MobileApp

    var body: some View {
        let split = FixtureWindows.shared.split
        HStack(spacing: split == nil ? 0 : NW.Space.xs) {
            MobileRoot(app: app)
                .clipShape(RoundedRectangle(cornerRadius: split == nil ? 0 : NW.Radius.l))
            if let split {
                MobileWindowRoot(app: app, seed: split)
                    .clipShape(RoundedRectangle(cornerRadius: NW.Radius.l))
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// Opens more windows for a screen, and closes the ones an earlier run left behind (the system
/// restores a killed app's windows).
@MainActor
@Observable
final class FixtureWindows {
    static let shared = FixtureWindows()

    /// A second window beside the screen's own.
    private(set) var split: MobileWindowSeed?
    @ObservationIgnored var openWindow: OpenWindowAction?
    @ObservationIgnored var primary: UIWindowScene?
    /// Windows this run opened.
    @ObservationIgnored private(set) var opened: Set<UUID> = []

    /// A real new window: in the simulator's full-screen mode it takes the screen.
    func open(_ route: MobileRoute) {
        let seed = MobileWindowSeed(opening: route)
        opened.insert(seed.id)
        openWindow?(value: seed)
    }

    /// A second window beside the screen's own, as Split View shows it.
    func openBeside(_ route: MobileRoute) {
        split = MobileWindowSeed(opening: route)
    }

    func closeOthers() {
        for session in UIApplication.shared.openSessions where session != primary?.session {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
                print("FIXTURE WINDOW \(error.localizedDescription)")
            }
        }
    }

    /// Waits up to `seconds` for `condition`.
    static func wait(seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private struct FixtureWindowOpener: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear { FixtureWindows.shared.openWindow = openWindow }
    }
}

/// Reports the window scene a view lands in.
private struct FixtureSceneProbe: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.found = found
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var found: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found?(scene) }
        }
    }
}

@MainActor
@Observable
final class FixtureRunner {
    private(set) var app: MobileApp?
    private(set) var failure: String?
    @ObservationIgnored private var started = false
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
        guard let app, let screen, !started else { return }
        started = true
        await wait(seconds: 5) { FixtureWindows.shared.primary != nil }
        FixtureWindows.shared.closeOthers()
        await wait(seconds: 5) { UIApplication.shared.openSessions.count <= 1 }
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
        let online = Set(screen.hosts.filter { $0.online && !$0.refusesToken }.map(\.id))
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
