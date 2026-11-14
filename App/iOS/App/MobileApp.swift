import Network
import SwiftUI
import ShepherdUI

/// The app's long-lived state, made once per launch and handed to the view tree through the
/// environment: `@Environment(MobileHosts.self)`, `(MobileNavigator.self)`,
/// `(ThreadStores.self)`, `(MobileAppearance.self)`, `(MobileWindows.self)`. Every window shares
/// it, except the navigator: each window has its own (`MobileWindowRoot`).
@MainActor
final class MobileApp {
    let hosts: MobileHosts
    let projects: MobileProjects
    /// The navigator of a root made without its own (the fixture harness's single window).
    let navigator: MobileNavigator
    let threads: ThreadStores
    let appearance: MobileAppearance
    let windows = MobileWindows()
    let push: PushManager
    let pushRouter = PushRouter()
    /// The Live Activities, widgets and their buttons.
    let glance: GlanceBridge
    /// When the app first shows something usable, and each reconnect (signposts; diagnostics).
    let readiness: MobileReadiness
    /// Each host's revision hints for the threads on screen in any window.
    let hints: ThreadRevisionHints
    /// Tells the hosts the network changed, so one on a later route looks at the earlier ones. Nothing polls: it fires on a change.
    private let network = NWPathMonitor()

    init(hosts: MobileHosts, appearance: MobileAppearance, push: PushManager? = nil) {
        SHFonts.register()
        self.hosts = hosts
        self.push = push ?? PushManager()
        projects = MobileProjects(hosts: hosts)
        navigator = MobileNavigator()
        threads = ThreadStores()
        threads.hostName = { [weak hosts] ref in hosts?.host(ref.host)?.record.name }
        threads.track(hosts)
        ThreadFilesStores.shared.track(hosts)
        self.appearance = appearance
        self.push.onEnabledHostsChanged = { GoalNotifications.shared.pushEnabledHosts = $0 }
        GoalNotifications.shared.pushEnabledHosts = self.push.enabledHosts
        self.push.onTokenChanged = { [weak hosts, weak push = self.push] in
            guard let hosts, let push else { return }
            Task { for host in hosts.hosts { await push.renew(host: host) } }
        }
        hosts.onHostConnected = { [weak push = self.push] host in
            MobileBrowsers.shared.connected(host)
            Task { await push?.renewOnReconnect(host: host) }
        }
        hosts.onHostDisconnected = { MobileBrowsers.shared.disconnected($0) }
        HomeFeed.of(hosts).projectNative = { [projects] ref, request in
            try await projects.native(agent: ref, request: request)
        }
        HomeFeed.of(hosts).openSnapshot = { [threads] ref in threads.liveSnapshot(for: ref) }
        glance = GlanceBridge(hosts: hosts, windows: windows)
        readiness = MobileReadiness(hosts: hosts) { MobileDiagnostics.reportFullyDisplayed() }
        // A hint marks Home's digest to read again and wakes the thread's store if one exists
        // (it pulls only while live and paced; a hidden or stopped one ignores it).
        hints = ThreadRevisionHints(hosts: hosts, threads: threads) { [weak hosts, weak threads] ref in
            guard let hosts else { return }
            HomeFeed.of(hosts).invalidate(ref.fleetRef)
            threads?.existingStore(for: ref)?.historyChanged()
        }
        // A Mac the fleet no longer has: its token and record are gone, so there is no host to revoke push on.
        hosts.onFleetLeft = { [weak self] id in self?.clear(host: id) }
        network.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(usable: usable) }
        }
        network.start(queue: DispatchQueue(label: "shepherd.ios.network"))
    }

    private var sawPath = false

    /// The path monitor's report: the first is the network at launch, the ones after it are changes.
    private func pathChanged(usable: Bool) {
        defer { sawPath = true }
        if sawPath, usable { hosts.networkChanged() }
    }

    /// The shipped app: preferences and the Keychain.
    static func live() -> MobileApp {
        MobileApp(hosts: MobileHosts(device: .current), appearance: MobileAppearance())
    }

    /// Forgets a host everywhere: its token and record, its open screens, its threads.
    func forget(host: UUID) async throws {
        // Revoke push before removing host connectivity.
        try await push.forget(host: host) { try hosts.forget(host) }
        clear(host: host)
    }

    /// What the app kept for a host that is gone.
    private func clear(host: UUID) {
        navigator.forget(host: host)
        windows.forget(host: host)
        threads.forget(host: host)
        projects.forget(host)
        SettingsStore.forget(host: host, in: hosts)
        AutomationsStore.forget(host: host, in: hosts)
        MobileTerminals.shared.forget(host: host)
        MobileBrowsers.shared.forget(host: host)
        ComposerStates.shared.forget(host: host)
        ReviewStores.shared.forget(host: host)
        ThreadFilesStores.shared.forget(host: host)
        CommitStores.shared.forget(host: host)
        WorktreeOperations.shared.forget(host: host)
        TurnUndoStore.shared.forget(host: host)
        ReviewRevertStore.shared.forget(host: host)
        HostDesignLibraries.of(hosts).forget(host)
        PadDesigns.forget(host: host, in: hosts)
        MobileDesigns.forget(host: host, in: hosts)
    }
}

extension View {
    /// The app's state and the window's navigator in the environment, for a window's root and
    /// for anything presented outside it.
    func mobileEnvironment(_ app: MobileApp, navigator: MobileNavigator, window: MobileWindowSeed) -> some View {
        environment(app.hosts)
            .environment(navigator)
            .environment(app.threads)
            .environment(app.projects)
            .environment(app.appearance)
            .environment(app.windows)
            .environment(app.push)
            .environment(app.pushRouter)
            .environment(\.mobileWindow, window)
            .environment(\.mobileApp, app)
    }
}

extension EnvironmentValues {
    /// The app itself, for the few actions that span its stores (forgetting a host).
    @Entry var mobileApp: MobileApp?
}
