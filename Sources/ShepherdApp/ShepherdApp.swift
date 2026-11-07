import SwiftUI
import ShepherdUI
import AppKit
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
                guard BackgroundHostClient.requested() || status == .enabled else { return try SessionServer.shared.start() }
                let socket = BackgroundHostClient.socketPath()
                BackgroundHostClient.owner = try BackgroundHostClient.choose(
                    answers: { RemoteHostClient.localSocketAnswers(socket) },
                    own: { try SessionServer.shared.start() },
                    wait: { Thread.sleep(forTimeInterval: 0.5) }, waitFirst: status == .enabled)
            },
            makeModel: {
                // Settings ▸ Advanced reads the job's status while this launch may use it.
                let status = BackgroundHostClient.serviceStatus
                let service = status.map { _ in BackgroundService.app(bundleIdentifier: Bundle.main.bundleIdentifier ?? "") }
                if BackgroundHostClient.owner == .host {
                    let vm = ShepherdViewModel(server: BackgroundHostClient.idleServer(), ownsWorkspace: false,
                                               restoresAgentsAtLaunch: false, browserData: .persistent)
                    vm.remoteHosts.addLocalHost(name: NewThreadPlaces.thisMac,
                                                socket: BackgroundHostClient.socketPath(), token: BackgroundHostClient.token() ?? "")
                    vm.backgroundService = service
                    vm.backgroundServiceStatus = status
                    let socket = BackgroundHostClient.socketPath()
                    vm.remoteHosts.onLocalHostLost = { BackgroundHostClient.hostLost(service: service, socket: socket) }
                    return vm
                }
                AppUpdater.shared.connectRemoteUpdates(to: SessionServer.shared)
                let resourceSampler = SessionResourceSampler()
                ShepherdDiagnostics.shared.start(settings: .shared, resourceSampler: {
                    await resourceSampler.sample(SessionServer.shared.resourceState())
                })
                if ShepherdDiagnostics.shared.isActive {
                    SessionServer.shared.onDiagnosticDuration = { operation, seconds in
                        ShepherdDiagnostics.shared.recordDuration(operation, seconds: seconds)
                    }
                    SessionServer.shared.onDiagnosticActivityDetails = { name, details in
                        guard let activity = ShepherdDiagnostics.Activity(rawValue: name) else { return }
                        ShepherdDiagnostics.shared.record(activity, details: details)
                    }
                }
                let vm = ShepherdViewModel(server: .shared, welcomesYourPi: true, browserData: .persistent)
                vm.backgroundService = service
                vm.backgroundServiceStatus = status
                return vm
            },
            failed: { error in
                NSLog("Shepherd: failed to start session server: \(error)")
                if SessionServerError.isWorkspaceInUse(error) { WorkspaceInUseAlert.show() }
                if error is BackgroundHostClient.HostStarting { WorkspaceInUseAlert.show(.hostStarting) }
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
                        vm.startSkillChecks()
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

    /// Quitting kills every agent process (sessions die with the app), so a quit while agents
    /// are mid-turn asks first, in a dialog on the main window (`QuitConfirmation`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The background host keeps every agent running.
        if BackgroundHostClient.owner == .host { return .terminateNow }
        if let reply = AppUpdater.shared.remoteTerminationReply { return reply }
        return QuitConfirmation.shared.shouldTerminate(agents: SessionServer.shared.state.agents)
    }

    func applicationWillTerminate(_ notification: Notification) {
        BoundedCommand.stopForAppTermination()
        if BackgroundHostClient.owner == .app { SessionServer.shared.stop() }
    }

}

/// What a launch says when another process (the background host, or another copy of the app)
/// already owns this edition's workspace, instead of quitting silently.
enum WorkspaceInUseAlert {
    /// Another process has it, or the background host holds it but hasn't answered yet.
    enum Reason { case inUse, hostStarting }

    static var message: String { "\(ShepherdEdition.current.displayName) is already running" }
    static let detail = "Another Shepherd process has this workspace open. Quit it, then open Shepherd again."
    static let hostStartingMessage = "Shepherd's background service is starting"
    static let hostStartingDetail = "Your agents keep running. Open Shepherd again in a moment."

    @MainActor static func make(_ reason: Reason = .inUse) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = reason == .inUse ? message : hostStartingMessage
        alert.informativeText = reason == .inUse ? detail : hostStartingDetail
        alert.addButton(withTitle: "Quit")
        return alert
    }

    @MainActor static func show(_ reason: Reason = .inUse) {
        let alert = make(reason)
        NSApp.activate()
        alert.runModal()
    }
}

extension ShepherdHost {
    /// What the app's view model applies to its server from Settings, applied to the host's: at
    /// start and on each change a client makes (`HostSettingsMapping`). Serve this Mac opens the
    /// TCP listener as the app would; a change to it takes effect when the host next starts. The
    /// listener's port, when it opened.
    @discardableResult
    @MainActor static func serveSettings(_ settings: AppSettings, on server: SessionServer) -> UInt16? {
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
        guard settings.remoteListenerEnabled else { return nil }
        do {
            return try server.startRemoteListener(port: UInt16(clamping: settings.remoteListenerPort),
                                                  tokenURL: server.supportDirectory.appendingPathComponent("remote-token"))
        } catch {
            ShepherdLog.error("host's remote listener failed to start: \(error)")
            return nil
        }
    }
}

/// The headless host entry (`Shepherd --host`), for the launcher shim: the session server with
/// no UI until SIGTERM. Nothing launches it yet.
public enum ShepherdHost {
    public static let argument = "--host"

    /// Agents respawn, and automation runs start, with the app's settings and its MCP servers
    /// (their Keychain secrets read here, as the app reads them). Merged threads close per
    /// Settings ▸ Worktrees. Banners post as the app's would, with nobody watching; a click opens
    /// the app, and answers and Retry act here.
    public static func main() -> Never {
        let settings = AppSettings.shared
        let (mcpStore, notifications) = MainActor.assumeIsolated {
            (MCPStore(dependencies: .app(pi: SessionServer.shared.pi, openURL: { _ in }, copy: { _ in })),
             AgentNotifications(activate: { NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init()) }))
        }
        let mcp = MainActor.assumeIsolated { MCPLaunch.spawnMCP(settings: settings, store: mcpStore) }
        MainActor.assumeIsolated {
            notifications.onResponse = { response in
                guard case .agent(let id) = response.target, let action = response.action else { return }
                Task { await SessionHost.banners?.respond(id, action: action, question: response.question,
                                                          text: response.text, recovery: response.recovery) }
            }
        }
        SessionHost.run(respawn: {
            var spawn = AgentSpawn(agent: $0, cwd: "", settings: settings.agentLaunch)
            spawn.mcp = mcp
            return spawn
        }, configure: { server in
            HostSettingsMapping.serve(on: server, settings: settings)
            serveSettings(settings, on: server)
            // Settings ▸ MCP, Subagents and Sign-in, with the MCP store agents launch with.
            let subagents = SubagentDefinitionsModel(pi: server.pi)
            HostStores(mcp: mcpStore, subagents: { subagents }, piAuth: PiAuthStore(pi: server.pi), yourPi: YourPiModel(pi: server.pi),
                       remoteSignIns: RemoteSignIns()).serve(on: server)
            server.serveAgentQueries(WorktreeHosting(defaults: { settings.worktreeHostingDefaults },
                                                      deleteAgent: { id, _ in try await server.deleteAgent(id) }))
        }, threads: { server in
            ThreadHosting(defaults: {
                ThreadHosting.Defaults(model: settings.defaultModel(piHome: server.pi.home), thinking: settings.defaultThinking,
                                       serviceTier: settings.defaultServiceTier, worktreeBaseMode: settings.worktreeBaseMode,
                                       worktreeFetchBeforeCreate: settings.worktreeFetchBeforeCreate)
            }, launch: { settings.agentLaunch }, mcp: mcp, shell: { ShellIntegration.command(shell: settings.shellCommand) })
        }, automations: { server in
            var hosting = server.headlessAutomationHosting(launch: { settings.agentLaunch }, mcp: mcp, defaults: {
                AutomationHosting.Defaults(model: settings.defaultModel(piHome: server.pi.home), thinking: settings.defaultThinking,
                                           serviceTier: settings.defaultServiceTier,
                                           worktreeFetchBeforeCreate: settings.worktreeFetchBeforeCreate,
                                           projectsEnabled: settings.projectsEnabled)
            })
            hosting.notify = { notifications.post(AgentBanners.automation(title: $0, body: $1)) }
            return hosting
        }, pullRequests: { server in
            var hosting = server.headlessPullRequestHosting(closeOnMerge: { settings.worktreeCloseOnMerge })
            hosting.closed = { agent, link, branch, remote in
                notifications.post(AgentBanners.pullRequestClosed(agent, number: link.ref.number, branch: branch, remote: remote))
            }
            hosting.keptOpen = { agent, link, reason in
                notifications.post(AgentBanners.pullRequestKept(agent, number: link.ref.number, reason: reason))
            }
            return hosting
        }, banners: { _ in
            ThreadBanners.Sink(post: notifications.post, remove: notifications.remove, isWatching: { _ in false },
                               notifyOnTurnFinished: { settings.notifyOnTurnFinished })
        })
    }
}
