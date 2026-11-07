import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdRemote

/// The headless host: `Shepherd --host` owns the workspace with no UI. It starts the session
/// server, serves until SIGTERM or SIGINT, then stops every session and exits. It also exits once
/// quiet after its bundle changes or a newer app asks it to drain (`HostDrain`); launchd starts
/// it again from the bundle there now.
public enum SessionHost {
    /// Kept alive for the life of the process.
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
    /// The threads' banners, while `run` was given somewhere to post them.
    nonisolated(unsafe) public private(set) static var banners: ThreadBanners?
    /// The host's own bundle, watched for an update while the host runs.
    nonisolated(unsafe) private static var watch: BundleVersionWatch?

    /// Runs `server` until a termination signal; never returns. A start that fails (another
    /// owner holds the workspace) exits with a failure status. `ready` runs once the server is
    /// up, on the main queue's thread (tests). `respawn` gives each agent with unfinished work its
    /// spawn settings; the host respawns them once it serves. `automations`, when given, hosts
    /// automations: their requests and triggers are served, and enabled ones start.
    /// `pullRequests`, when given, keeps each thread's pull request link on the poll. `banners`,
    /// when given, is where threads' turn, question and notify-tool banners go. `threads`, when
    /// given, serves clients' threads and terminals: new threads, their actions, shells.
    /// `configure` runs first, on the main actor, once the server is up: the caller's settings
    /// and listeners.
    public static func run(_ server: SessionServer = .shared, respawn: @escaping @MainActor (Agent) -> AgentSpawn,
                           configure: (@MainActor (SessionServer) -> Void)? = nil,
                           threads: (@MainActor (SessionServer) -> ThreadHosting)? = nil,
                           automations: (@MainActor (SessionServer) -> AutomationHosting)? = nil,
                           pullRequests: (@MainActor (SessionServer) -> PullRequestLinkHosting)? = nil,
                           banners: (@MainActor (SessionServer) -> ThreadBanners.Sink)? = nil,
                           ready: () -> Void = {}) -> Never {
        // Signals arrive through dispatch sources, so the default action (die without
        // stopping pi processes) is turned off before anything starts.
        let stop = {
            BoundedCommand.stopForAppTermination()
            server.stop()
            exit(EXIT_SUCCESS)
        }
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                ShepherdLog.info("host stopping on signal \(number)")
                stop()
            }
            source.activate()
            return source
        }
        do {
            try server.start()
        } catch {
            ShepherdLog.error(SessionServerError.isWorkspaceInUse(error)
                ? "host not started: another Shepherd owns this workspace"
                : "host not started: \(error)")
            exit(EXIT_FAILURE)
        }
        ShepherdLog.info("host serving (pid \(getpid()))")
        Task { @MainActor in
            // Handoff: a changed bundle, or a newer app's `drain`, lets the host exit once quiet.
            let drain = HostDrain(server: server, exit: stop)
            server.onDrainRequest = { drain.begin("a newer app asked") }
            let bundle = Bundle.main.bundleURL
            if bundle.pathExtension == "app" {
                watch = BundleVersionWatch(bundle: bundle, running: server.hostBuild) {
                    drain.begin("bundle version \(server.hostBuild ?? "?") is now \($0 ?? "gone")")
                }
            }
            configure?(server)
            if let threads { server.serveThreads(threads(server)) }
            // The app's way in (`host.sock`), once its threads are served; a path too long for a
            // unix socket leaves the app to run in process.
            let support = server.supportDirectory
            do {
                try server.startLocalListener(path: support.appendingPathComponent("host.sock").path,
                                              tokenURL: support.appendingPathComponent("remote-token"))
            } catch {
                ShepherdLog.error("host has no local socket: \(error)")
            }
            if let banners {
                let observer = ThreadBanners(server: server, state: { server.state }, sink: banners(server))
                observer.observeServer()
                Self.banners = observer
            }
            await server.respawnAgentsNeedingRecovery(respawn)
            if let pullRequests { server.servePullRequestLinks(pullRequests(server)).startPolling() }
            guard let automations else { return }
            server.serveAutomations(automations(server))
            await server.autoStartAutomations()
        }
        ready()
        signalSources = sources
        if Thread.isMainThread { dispatchMain() }
        // Called off the main thread (an exit test): whoever runs the main thread serves the
        // main queue, where the signal handler and the server's callbacks run.
        while true { pause() }
    }
}

extension SessionServerError {
    /// The refusal a start gets when another process (the app, or the host) owns the workspace.
    public static func isWorkspaceInUse(_ error: Error) -> Bool {
        guard case .system("bind", EADDRINUSE)? = error as? SessionServerError else { return false }
        return true
    }
}
