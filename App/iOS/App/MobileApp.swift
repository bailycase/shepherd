import SwiftUI
import ShepherdUI

/// The app's long-lived state, made once per launch and handed to the view tree through the
/// environment: `@Environment(MobileHosts.self)`, `(MobileNavigator.self)`,
/// `(ThreadStores.self)`, `(MobileAppearance.self)`, `(MobileWindows.self)`. Every window shares
/// it, except the navigator: each window has its own (`MobileWindowRoot`).
@MainActor
final class MobileApp {
    let hosts: MobileHosts
    /// The navigator of a root made without its own (the fixture harness's single window).
    let navigator: MobileNavigator
    let threads: ThreadStores
    let appearance: MobileAppearance
    let windows = MobileWindows()

    init(hosts: MobileHosts, appearance: MobileAppearance) {
        NWFonts.register()
        self.hosts = hosts
        navigator = MobileNavigator()
        threads = ThreadStores()
        self.appearance = appearance
    }

    /// The shipped app: preferences and the Keychain.
    static func live() -> MobileApp {
        MobileApp(hosts: MobileHosts(), appearance: MobileAppearance())
    }

    /// Forgets a host everywhere: its token and record, its open screens, its threads.
    func forget(host: UUID) throws {
        try hosts.forget(host)
        navigator.forget(host: host)
        windows.forget(host: host)
        threads.forget(host: host)
    }
}

extension View {
    /// The app's state and the window's navigator in the environment, for a window's root and
    /// for anything presented outside it.
    func mobileEnvironment(_ app: MobileApp, navigator: MobileNavigator, window: MobileWindowSeed) -> some View {
        environment(app.hosts)
            .environment(navigator)
            .environment(app.threads)
            .environment(app.appearance)
            .environment(app.windows)
            .environment(\.mobileWindow, window)
            .environment(\.mobileApp, app)
    }
}

extension EnvironmentValues {
    /// The app itself, for the few actions that span its stores (forgetting a host).
    @Entry var mobileApp: MobileApp?
}
