import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdRemote

/// The headless host: `Shepherd --host` owns the workspace with no UI. It starts the session
/// server, serves until SIGTERM or SIGINT, then stops every session and exits. Nothing launches
/// it yet; the app still owns the workspace itself.
public enum SessionHost {
    /// Kept alive for the life of the process.
    nonisolated(unsafe) private static var signalSources: [DispatchSourceSignal] = []
    /// The threads' banners, while `run` was given somewhere to post them.
    nonisolated(unsafe) public private(set) static var banners: ThreadBanners?

    /// Runs `server` until a termination signal; never returns. A start that fails (another
    /// owner holds the workspace) exits with a failure status. `ready` runs once the server is
    /// up, on the main queue's thread (tests). `respawn` gives each agent with unfinished work its
    /// spawn settings; the host respawns them once it serves. `automations`, when given, hosts
    /// automations: their requests and triggers are served, and enabled ones start.
    /// `pullRequests`, when given, keeps each thread's pull request link on the poll. `banners`,
    /// when given, is where threads' turn, question and notify-tool banners go.
    public static func run(_ server: SessionServer = .shared, respawn: @escaping @MainActor (Agent) -> AgentSpawn,
                           automations: (@MainActor (SessionServer) -> AutomationHosting)? = nil,
                           pullRequests: (@MainActor (SessionServer) -> PullRequestLinkHosting)? = nil,
                           banners: (@MainActor (SessionServer) -> ThreadBanners.Sink)? = nil,
                           ready: () -> Void = {}) -> Never {
        // Signals arrive through dispatch sources, so the default action (die without
        // stopping pi processes) is turned off before anything starts.
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                ShepherdLog.info("host stopping on signal \(number)")
                BoundedCommand.stopForAppTermination()
                server.stop()
                exit(EXIT_SUCCESS)
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
