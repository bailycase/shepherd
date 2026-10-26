import SwiftUI
import UserNotifications

/// Every window is a `MobileWindowRoot` over the app's shared state. A window opens on a seed:
/// a fresh one at launch or from the system's New Window, or one naming a thread from "Open in
/// new window" (`WindowHooks`). The system keeps each window's seed, and the window keeps its
/// place in scene storage, so both come back on relaunch.
@main
struct ShepherdIOSApp: App {
    @State private var app = MobileApp.live()
    @UIApplicationDelegateAdaptor private var appDelegate: PushAppDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup(for: MobileWindowSeed.self) { $seed in
            MobileWindowRoot(app: app, seed: seed)
                .onAppear {
                    // Configure the delegate once the first window appears — the app's
                    // state is ready and windows can receive routes.
                    if appDelegate.pushRouter == nil {
                        appDelegate.configure(
                            push: app.push, router: app.pushRouter,
                            hosts: app.hosts, windows: app.windows
                        )
                    }
                    // Flush pending taps now that a window exists.
                    appDelegate.flushPending()
                }
        } defaultValue: {
            MobileWindowSeed()
        }
        .commands { MobileWindowCommands() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    // Sync push-enabled hosts into GoalNotifications to suppress duplicates.
                    GoalNotifications.shared.pushEnabledHosts = Set(
                        app.push.hostStates.filter(\.value.enabled).map(\.key)
                    )
                    // Renew relay registrations once per foreground, request token for enabled hosts.
                    // Hosts that connect later get renewed via onHostConnected.
                    await app.push.renewOnForeground(hosts: app.hosts.hosts)
                    // Flush any pending notification taps (window may have appeared by now).
                    appDelegate.flushPending()
                    app.pushRouter.drainPending(hosts: app.hosts, windows: app.windows)
                }
            case .background:
                app.push.resetSession()
            default: break
            }
        }
    }
}
