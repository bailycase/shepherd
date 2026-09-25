import SwiftUI

/// Every window is a `MobileWindowRoot` over the app's shared state. A window opens on a seed:
/// a fresh one at launch or from the system's New Window, or one naming a thread from "Open in
/// new window" (`WindowHooks`). The system keeps each window's seed, and the window keeps its
/// place in scene storage, so both come back on relaunch.
@main
struct ShepherdIOSApp: App {
    @State private var app = MobileApp.live()

    var body: some Scene {
        WindowGroup(for: MobileWindowSeed.self) { $seed in
            MobileWindowRoot(app: app, seed: seed)
        } defaultValue: {
            MobileWindowSeed()
        }
        .commands { MobileWindowCommands() }
    }
}
