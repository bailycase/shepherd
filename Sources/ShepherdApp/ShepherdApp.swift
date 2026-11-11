import SwiftUI
import ShepherdUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

/// The one main window's scene id.
enum MainWindow {
    static let id = "main"
    /// Opens (or fronts) the main window; set once the window has appeared, used to reopen it
    /// from the Dock after it was closed.
    @MainActor static var open: (() -> Void)?
    /// The window itself while it is up, for what AppKit presents on it (the quit
    /// confirmation). `MainWindowReader` reports it.
    @MainActor static weak var window: NSWindow? {
        didSet {
            if let window, window !== oldValue { QuitConfirmation.shared.mainWindowAppeared(window) }
        }
    }
}

/// Reports the window hosting it as `MainWindow.window`.
struct MainWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReaderView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.window = window }
        }

        /// Behind the whole root view: never the target of a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// What the Dock and the quit confirmation need from the main window, installed by whatever it
/// shows first (the launch surface while the workspace opens, then the workspace): reopening
/// it from the Dock works even if it is closed before the workspace is ready.
struct MainWindowRoutes: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .background { MainWindowReader() }
            .onAppear { MainWindow.open = { [openWindow] in openWindow(id: MainWindow.id) } }
    }
}

/// The Mac app, exposed as a library so an Xcode app target can provide the
/// entry point. Launch it with `ShepherdMacApp.main()` — SwiftUI must own the
/// instance for the delegate adaptor and state objects to be managed.
@MainActor
public struct ShepherdMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The workspace is acquired off the main thread with the window already up; the model (and
    /// everything that restores agents or writes the workspace) is made once that succeeds.
    @State private var launch: ShepherdLaunch<ShepherdViewModel>
    /// Menus rebuild when a shortcut is rebound: the rebindings are passed into each menu.
    private let keys: KeybindingsStore
    private let themes: ThemeManager

    public init() {
        keys = KeybindingsStore.shared
        themes = ThemeManager.shared
        // Geist and Geist Mono ship in the ShepherdUI bundle; register them before any view draws.
        SHFonts.register()
        let launch = ShepherdLaunch<ShepherdViewModel>(
            // Acquire the workspace before constructing anything that can restore agents or write it.
            start: {
                let bundle = Bundle.main
                let service = BackgroundService.app(bundleIdentifier: bundle.bundleIdentifier ?? "")
                let status = service.prepare(may: BackgroundService.mayRegister(
                    bundleIdentifier: bundle.bundleIdentifier, bundlePath: bundle.bundlePath,
                    environment: ProcessInfo.processInfo.environment, adHoc: BackgroundService.isAdHoc()))
                BackgroundHostClient.serviceStatus = status
                // Every launch is a client: of launchd's host when the service runs one, else of the app's own child.
                let supervisor = HostSupervisor(.app(preferOwner: { status != nil && service.status() == .enabled }))
                HostSupervisor.shared = supervisor
                try supervisor.start()
            },
            makeModel: {
                // Settings ▸ Advanced reads the job's status while this launch may use it.
                let status = BackgroundHostClient.serviceStatus
                let service = status.map { _ in BackgroundService.app(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") }
                // App-side diagnostics only; the host's server metrics aren't reported to the app (#561 Q5).
                ShepherdDiagnostics.shared.start(settings: .shared)
                let vm = ShepherdViewModel(welcomesYourPi: true, browserData: .persistent)
                vm.connectLocalHost(socket: BackgroundHostClient.socketPath(), token: BackgroundHostClient.token() ?? "")
                vm.backgroundService = service
                vm.backgroundServiceStatus = status
                // The supervisor starts the host again; the store reconnects on its own.
                HostSupervisor.agents = { [weak vm] in vm?.remoteHosts.localHost?.state.agents ?? [] }
                if let supervisor = HostSupervisor.shared {
                    supervisor.onFailure = { failure in
                        if HostSupervisor.StartFailed.show(failure, canRetry: true) { supervisor.retry() } else { NSApp.terminate(nil) }
                    }
                }
                // A paired device's Update this Mac: the host relays it here, where Sparkle runs.
                AppUpdater.shared.connectRemoteUpdates(gate: .host { [weak vm] in (try? vm?.remoteHosts.thisMacHost()) ?? nil })
                return vm
            },
            failed: { error in
                NSLog("Shepherd: failed to start the session host: \(error)")
                if error is BackgroundHostClient.HostStarting { WorkspaceInUseAlert.show() }
                if let failure = error as? HostSupervisor.StartFailed { _ = HostSupervisor.StartFailed.show(failure, canRetry: false) }
                exit(EXIT_FAILURE)
            })
        launch.begin()
        _launch = State(initialValue: launch)
    }

    public var body: some Scene {
        // One window, never tabbed. Sessions belong to the app, not the window: closing it
        // leaves every agent running, and the Dock or Window menu brings it back.
        Window(ShepherdEdition.current.displayName, id: MainWindow.id) {
            Group {
                if let vm = launch.model {
                    RootView(vm: vm)
                    // Host role: bind the remote listener if this Mac serves its
                    // sessions (the toggle persists; a host stays a host). Workspace ownership
                    // was acquired before the view model was constructed.
                    .task {
                        AppSignposts.launch.emitEvent("root view task")
                        vm.applyRemoteListenerSetting()
                    }
                } else {
                    LaunchSurface()
                }
            }
            .modifier(MainWindowRoutes())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: AppLayout.windowDefaultWidth, height: AppLayout.windowDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            // Register menus immediately; their actions stay disabled until ownership is acquired.
            WorkspaceCommands(launch: launch, keys: keys, themes: themes)
        }
    }
}

/// Bare SwiftPM executables launch as background processes; promote to a
/// regular app so the window fronts when run from a terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One window: no tab bar, and no "Show Tab Bar" menu items.
        NSWindow.allowsAutomaticWindowTabbing = false
        do {
            try ShepherdThemeMarker.install(for: ThemeManager.shared.current)
        } catch {
            NSLog("Shepherd: initial theme install failed: \(error)")
        }
        ThemeManager.shared.applyApplicationAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        #if DEBUG
        // Dev builds badge the Dock icon so they're distinguishable from the
        // installed copy in the Dock and ⌘Tab. Runtime-only — Release and
        // Finder are untouched.
        if let icon = NSApp.applicationIconImage {
            let badged = NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                let text = "DEV" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: rect.height * 0.18),
                    .foregroundColor: NSColor.white,
                ]
                let textSize = text.size(withAttributes: attrs)
                let pad = rect.height * 0.05
                let pill = NSRect(
                    x: rect.midX - textSize.width / 2 - pad,
                    y: rect.height * 0.08,
                    width: textSize.width + pad * 2,
                    height: textSize.height + pad
                )
                NSColor.systemOrange.setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                text.draw(
                    at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2),
                    withAttributes: attrs
                )
                return true
            }
            NSApp.applicationIconImage = badged
        }
        #endif

        QuitConfirmation.shared.watchForPowerOff()
    }

    /// Agents keep running with the window closed; only Quit stops them.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with the window closed brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindow.open?() } }
        return true
    }

    /// When the app's own child host runs the agents, quitting stops every agent process, so a
    /// quit while agents are mid-turn asks first, in a dialog on the main window
    /// (`QuitConfirmation`), then `stop`s the child.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // launchd's background host keeps every agent running.
        if HostSupervisor.shared?.ownsAgents != true { return .terminateNow }
        if let reply = AppUpdater.shared.remoteTerminationReply { return reply }
        return QuitConfirmation.shared.shouldTerminate(agents: HostSupervisor.agents())
    }

    func applicationWillTerminate(_ notification: Notification) {
        BoundedCommand.stopForAppTermination()
        HostSupervisor.shared?.stop()
    }

}

/// What a launch says when the workspace's owner (launchd's background host) holds it but hasn't
/// answered yet, instead of quitting silently.
enum WorkspaceInUseAlert {
    static let message = "Shepherd's background service is starting"
    static let detail = "Your agents keep running. Open Shepherd again in a moment."

    @MainActor static func make() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        return alert
    }

    @MainActor static func show() {
        let alert = make()
        NSApp.activate()
        alert.runModal()
    }
}

extension ShepherdHost {
    /// What the app's view model applies to its server from Settings, applied to the host's: at
    /// start, on each change a client makes (`HostSettingsMapping`), and on each the app's own
    /// Settings pages write to the shared preferences (`followOtherProcesses`). Serve this Mac opens and
    /// closes the TCP listener with its switch, as the app did; `listener` hears each outcome (its
    /// port, or why it didn't open) and the app's Settings ▸ Remote reads it again. The
    /// listener's port, when it opened at start.
    @discardableResult
    @MainActor static func serveSettings(_ settings: AppSettings, on server: SessionServer,
                                         listener: ((UInt16?, Error?) -> Void)? = nil) -> UInt16? {
        settings.followOtherProcesses()
        server.setProjectsEnabled(settings.projectsEnabled)
        settings.onProjectsChange = { [weak server] in server?.setProjectsEnabled($0) }
        server.setDefaultQueueMode(settings.queueDelivery)
        settings.onQueueDeliveryChange = { [weak server] in server?.setDefaultQueueMode($0) }
        server.setGoalsEnabled(settings.goalsEnabled)
        settings.onGoalsChange = { [weak server] in server?.setGoalsEnabled($0) }
        server.setHiddenSlashCommands(settings.hiddenSlashCommands)
        settings.onHiddenSlashCommandsChange = { [weak server] in server?.setHiddenSlashCommands($0) }
        server.setDesignsServed(settings.designToolEnabled)
        settings.onDesignToolChange = { [weak server] in server?.setDesignsServed($0) }
        let pi = server.pi
        let compact = { (percent: Int?) in
            Task.detached(priority: .utility) { try? pi.applyCompactionThreshold(percent: percent) }
        }
        compact(settings.compactAtPercent)
        settings.onCompactAtChange = { compact($0) }
        let listen = { [weak server, settings] (on: Bool) -> UInt16? in
            guard let server, on else {
                listener?(nil, nil)
                return nil
            }
            do {
                let port = try server.startRemoteListener(port: UInt16(clamping: settings.remoteListenerPort),
                                                          tokenURL: server.supportDirectory.appendingPathComponent("remote-token"))
                listener?(port, nil)
                return port
            } catch {
                ShepherdLog.error("host's remote listener failed to start: \(error)")
                listener?(nil, error)
                return nil
            }
        }
        settings.onRemoteListenerChange = { [weak server] on in
            server?.stopRemoteListener()
            _ = listen(on)
            server?.settingsChanged(.remote)
        }
        return listen(settings.remoteListenerEnabled)
    }
}

/// The headless host entry (`Shepherd --host`), for the launcher shim: the session server with
/// no UI until SIGTERM or a drain. launchd runs it as Shepherd Nightly's background service
/// (`BackgroundService`).
public enum ShepherdHost {
    public static let argument = "--host"
    /// With `argument`: the app's own child (`HostSupervisor`), not launchd's service.
    static let supervisedArgument = "--supervised"
    /// What the host serves, kept for the life of the process.
    @MainActor private static var services: Services?

    /// Agents respawn, and automation runs start, with the app's settings and its MCP servers
    /// (their Keychain secrets read here, as the app reads them). Merged threads close per
    /// Settings ▸ Worktrees. Banners post as the app's would, with nobody watching; a click opens
    /// the app, and answers and Retry act here.
    public static func main() -> Never {
        MainActor.assumeIsolated {
            let settings = AppSettings.shared
            let mcpStore = MCPStore(dependencies: .app(pi: SessionServer.shared.pi, openURL: { _ in }, copy: { _ in }))
            let notifications = AgentNotifications(activate: { NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init()) })
            notifications.onResponse = { response in
                guard case .agent(let id) = response.target, let action = response.action else { return }
                Task { await SessionHost.banners?.respond(id, action: action, question: response.question,
                                                          text: response.text, recovery: response.recovery) }
            }
            // The host is the service: it says so from launchd's own status of its job.
            let service = BackgroundService.app(bundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            let services = Services(settings: settings, mcpStore: mcpStore, notifications: notifications) { service.status().keepsAgentsRunning }
            Self.services = services
            SessionHost.run(supervised: CommandLine.arguments.contains(supervisedArgument), respawn: services.respawn,
                            configure: services.configure, threads: services.threads, automations: services.automations,
                            pullRequests: services.pullRequests, banners: services.banners)
        }
    }

    /// Everything the host serves on its server beside the server's own: Settings, its stores,
    /// threads, worktrees, automations, Missions and Projects, pull request links and banners,
    /// each with the app's settings. `main` runs it; app tests serve their in-process host with it.
    @MainActor final class Services {
        let settings: AppSettings
        let mcpStore: MCPStore
        let notifications: AgentNotifications
        let keepsAgentsRunning: @MainActor () -> Bool?
        let mcp: AgentSpawn.MCP
        /// The shell a client's terminal starts.
        var shell: () -> SessionCommand
        /// Missions and the Project runtime, served for the life of the host.
        private(set) var runtime: (missions: MissionController, coordinator: ProjectCoordinatorController,
                                   execution: ProjectExecutionController)?
        /// Worktree requests and commits from review, served for the life of the host.
        private(set) var worktrees: WorktreeQueries?
        /// Serve this Mac's listener as it started, for Settings ▸ Remote.
        private(set) var listener: (port: UInt16?, failure: RemoteListenerFailure?) = (nil, nil)
        /// Stands in for `gh` in looking up a thread's pull request (tests).
        var pullRequestLookup: (@MainActor (String) async -> ThreadPullRequest?)?

        init(settings: AppSettings, mcpStore: MCPStore, notifications: AgentNotifications, keepsAgentsRunning: @escaping @MainActor () -> Bool?) {
            self.settings = settings
            self.mcpStore = mcpStore
            self.notifications = notifications
            self.keepsAgentsRunning = keepsAgentsRunning
            mcp = MCPLaunch.spawnMCP(settings: settings, store: mcpStore)
            shell = { ShellIntegration.command(shell: settings.shellCommand) }
        }

        /// `SessionHost.serve` with these services, for a host the test process runs.
        @discardableResult
        func serve(_ server: SessionServer, socket: String, tokenURL: URL, recovering: Bool = true) async -> ThreadBanners? {
            await SessionHost.serve(server, socket: socket, tokenURL: tokenURL, recovering: recovering, respawn: respawn, configure: configure,
                                    threads: threads, automations: automations, pullRequests: pullRequests, banners: banners)
        }

        var respawn: @MainActor (Agent) -> AgentSpawn {
            { [settings, mcp] in
                var spawn = AgentSpawn(agent: $0, cwd: "", settings: settings.agentLaunch)
                spawn.mcp = mcp
                return spawn
            }
        }

        var configure: @MainActor (SessionServer) -> Void {
            { [self] server in
                HostSettingsMapping.serve(on: server, settings: settings, backgroundService: keepsAgentsRunning) { [weak self] in
                    self?.listener ?? (nil, nil)
                }
                serveSettings(settings, on: server) { [weak self, settings] port, error in
                    self?.listener = (port, error.map { RemoteListenerFailure($0, port: UInt16(clamping: settings.remoteListenerPort)) })
                }
                // Settings ▸ MCP, Subagents and Sign-in, with the MCP store agents launch with.
                let subagents = SubagentDefinitionsModel(pi: server.pi)
                let stores = HostStores(mcp: mcpStore, subagents: { subagents }, piAuth: PiAuthStore(pi: server.pi), yourPi: YourPiModel(pi: server.pi),
                                        remoteSignIns: RemoteSignIns())
                stores.serve(on: server)
                stores.serveTurnErrors(on: server)
                let settings = settings
                let worktrees = server.serveAgentQueries(WorktreeHosting(defaults: { settings.worktreeHostingDefaults },
                                                                         deleteAgent: { id, _ in try await server.deleteAgent(id) }))
                self.worktrees = worktrees
                // Missions and Projects run here, where their agents run: they keep acting with the app quit.
                runtime = RuntimeHosting.headless(server: server, settings: settings, worktrees: worktrees, mcp: mcp) { [notifications] in
                    notifications.post(AgentBanners.automation(title: $0, body: $1))
                }.serve()
                // Skills look for newer commits a minute in, then hourly once the last check is a day old.
                let skills = server.skills
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: .seconds(60))
                    while !Task.isCancelled {
                        skills.checkUpdatesIfDue()
                        try? await Task.sleep(for: .seconds(3_600))
                    }
                }
            }
        }

        var threads: @MainActor (SessionServer) -> ThreadHosting {
            { [settings, mcp, shell] server in
                ThreadHosting(defaults: {
                    ThreadHosting.Defaults(model: settings.defaultModel(piHome: server.pi.home), thinking: settings.defaultThinking,
                                           serviceTier: settings.defaultServiceTier, worktreeBaseMode: settings.worktreeBaseMode,
                                           worktreeFetchBeforeCreate: settings.worktreeFetchBeforeCreate)
                }, launch: { settings.agentLaunch }, mcp: mcp, shell: shell)
            }
        }

        var automations: @MainActor (SessionServer) -> AutomationHosting {
            { [settings, mcp, notifications] server in
                var hosting = server.headlessAutomationHosting(launch: { settings.agentLaunch }, mcp: mcp, defaults: {
                    AutomationHosting.Defaults(model: settings.defaultModel(piHome: server.pi.home), thinking: settings.defaultThinking,
                                               serviceTier: settings.defaultServiceTier,
                                               worktreeFetchBeforeCreate: settings.worktreeFetchBeforeCreate,
                                               projectsEnabled: settings.projectsEnabled)
                })
                hosting.notify = { notifications.post(AgentBanners.automation(title: $0, body: $1)) }
                return hosting
            }
        }

        var pullRequests: @MainActor (SessionServer) -> PullRequestLinkHosting {
            { [weak self, settings, notifications] server in
                var hosting = server.headlessPullRequestHosting(closeOnMerge: { settings.worktreeCloseOnMerge })
                let lookup = hosting.lookup
                hosting.lookup = { [weak self] cwd in
                    if let stand = self?.pullRequestLookup { return await stand(cwd) }
                    return await lookup(cwd)
                }
                hosting.closed = { agent, link, branch, remote in
                    notifications.post(AgentBanners.pullRequestClosed(agent, number: link.ref.number, branch: branch, remote: remote))
                }
                hosting.keptOpen = { agent, link, reason in
                    notifications.post(AgentBanners.pullRequestKept(agent, number: link.ref.number, reason: reason))
                }
                return hosting
            }
        }

        var banners: @MainActor (SessionServer) -> ThreadBanners.Sink {
            { [settings, notifications] server in
                var sink = ThreadBanners.Sink(post: notifications.post, remove: notifications.remove, isWatching: { _ in false },
                                              notifyOnTurnFinished: { settings.notifyOnTurnFinished })
                // The app, connected and showing these threads as its own, posts their banners.
                sink.quiet = { server.localAppConnected }
                return sink
            }
        }
    }
}
