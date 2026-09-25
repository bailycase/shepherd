import SwiftUI
import ShepherdUI

/// One window of the shipped app: its own navigator, put back where it was from the scene's
/// storage when the system restores the window, or opened on its seed's route when it is new.
/// iPad can show several side by side (Split View, Stage Manager); iPhone shows one.
struct MobileWindowRoot: View {
    let app: MobileApp
    let seed: MobileWindowSeed
    @State private var navigator = MobileNavigator()
    @State private var ready = false
    @SceneStorage("shepherd.window.navigation") private var saved: Data?
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if ready {
                MobileRoot(app: app, navigator: navigator, window: seed)
            } else {
                Color.nw.bgWindow.ignoresSafeArea()
            }
        }
        .onAppear(perform: start)
        .onChange(of: ready ? navigator.restoration : nil) { _, value in
            guard let value else { return }
            saved = try? JSONEncoder().encode(value)
        }
    }

    private func start() {
        guard !ready else { return }
        let hosts = Set(app.hosts.hosts.map(\.id))
        if let saved, let value = try? JSONDecoder().decode(MobileNavigator.Restoration.self, from: saved) {
            navigator.restore(value, hosts: hosts)
        } else if let route = seed.opening, route.host.map(hosts.contains) ?? true {
            // A window the system brings back before it saved a place opens its seed's thread,
            // unless that thread's host was forgotten meanwhile.
            navigator.adopt(sizeClass == .regular ? .pad : .phone)
            navigator.open(route)
        }
        ready = true
    }
}

/// The app's keyboard commands, for the focused window.
struct MobileWindowCommands: Commands {
    @FocusedValue(\.mobileNavigator) private var navigator

    var body: some Commands {
        SearchCommands(navigator: navigator)
    }
}
