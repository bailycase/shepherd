import SwiftUI
import ShepherdUI

/// The app's long-lived state, made once per launch and handed to the view tree through the
/// environment: `@Environment(MobileHosts.self)`, `(MobileNavigator.self)`,
/// `(ThreadStores.self)`, `(MobileAppearance.self)`.
@MainActor
final class MobileApp {
    let hosts: MobileHosts
    let navigator: MobileNavigator
    let threads: ThreadStores
    let appearance: MobileAppearance

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
        threads.forget(host: host)
    }
}

extension View {
    /// The app's state in the environment, for the root and for anything presented outside it.
    func mobileEnvironment(_ app: MobileApp) -> some View {
        environment(app.hosts)
            .environment(app.navigator)
            .environment(app.threads)
            .environment(app.appearance)
            .environment(\.mobileApp, app)
    }
}

extension EnvironmentValues {
    /// The app itself, for the few actions that span its stores (forgetting a host).
    @Entry var mobileApp: MobileApp?
}
