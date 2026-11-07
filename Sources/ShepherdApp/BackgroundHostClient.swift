import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The app as the background host's client (`SHEPHERD_BACKGROUND_HOST=1`, until the service ships):
/// when `host.sock` answers, the host owns the workspace and the app shows its threads and
/// terminals through the remote-host paths. Otherwise the app owns the workspace itself, as it
/// always has.
enum BackgroundHostClient {
    static let environmentKey = "SHEPHERD_BACKGROUND_HOST"

    /// Who owns the workspace this launch.
    enum Owner: Equatable {
        case app
        case host
    }

    /// A host holds the workspace (its lock) but its socket hasn't answered yet: it is starting,
    /// or draining for an update.
    struct HostStarting: Error, CustomStringConvertible {
        var description: String { "Shepherd's background service is starting" }
    }

    /// This launch's owner: written once by the start, off main, before the model is made; read
    /// on main after.
    nonisolated(unsafe) static var owner = Owner.app
    /// The launchd job's status this launch, nil when it may not register (`BackgroundService`).
    /// Written once by the start, like `owner`.
    nonisolated(unsafe) static var serviceStatus: BackgroundService.Status?

    static func requested(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        ShepherdPaths.supportDirectory(environment: environment).appendingPathComponent("host.sock").path
    }

    /// The start's choice: the host when its socket answers; else the app takes the workspace.
    /// A workspace in use with no answer is a host starting: it is asked again `attempts` times,
    /// `wait` apart, then the launch says so.
    /// With the service on (`waitFirst`), the host is waited for before the app takes the
    /// workspace: launchd may still be starting it.
    static func choose(answers: () -> Bool, own: () throws -> Void, wait: () -> Void, attempts: Int = 10,
                       waitFirst: Bool = false) throws -> Owner {
        if answers() { return .host }
        if waitFirst {
            for _ in 0..<attempts {
                wait()
                if answers() { return .host }
            }
        }
        do {
            try own()
            return .app
        } catch where SessionServerError.isWorkspaceInUse(error) {
            for _ in 0..<attempts {
                wait()
                if answers() { return .host }
            }
            throw HostStarting()
        }
    }

    /// The app's server in client mode: never started, on throwaway paths, so it owns nothing,
    /// reads none of the host's files and its workspace stays empty. ponytail: the view model still
    /// needs a server; a client protocol in its place is the upgrade once local threads go.
    static func idleServer(directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("shepherd-client-\(getpid())", isDirectory: true)) -> SessionServer {
        SessionServer(socketPath: directory.appendingPathComponent("s.sock").path,
                      stateURL: directory.appendingPathComponent("state.json"))
    }

    /// Whether the app asks its host to drain: the host is an older build that takes `drain`.
    /// An older host without it drains once it sees the new bundle on disk; one whose build
    /// can't be compared is left alone.
    static func asksToDrain(appBuild: String?, hostBuild: String?, capabilities: Set<String>) -> Bool {
        guard capabilities.contains(RemoteProtocol.hostDrainCapability),
              let app = appBuild.flatMap(Int.init), let host = hostBuild.flatMap(Int.init) else { return false }
        return app > host
    }

    /// Whether the app, having lost its host, runs the workspace itself: only once the job is
    /// turned off in Login Items and its socket is silent. An enabled job is restarting (a drain,
    /// a crash) and the connection comes back on its own. An unregistered one is Quit and Stop
    /// Agents, with this app on its way out; with no job (`SHEPHERD_BACKGROUND_HOST=1` against a
    /// host run by hand) the app keeps reconnecting.
    static func runsInProcess(afterLosing status: BackgroundService.Status?, answers: Bool) -> Bool {
        status == .requiresApproval && !answers
    }

    @MainActor private static var relaunching = false

    /// The app lost its host (`RemoteHostStore.onLocalHostLost`): checks the job and the socket
    /// off main, and relaunches in process when the host is off for good.
    static func hostLost(service: BackgroundService?, socket: String) {
        Task.detached(priority: .utility) {
            let status = service?.status()
            guard runsInProcess(afterLosing: status, answers: RemoteHostClient.localSocketAnswers(socket)) else { return }
            await MainActor.run { relaunchInProcess() }
        }
    }

    /// Relaunches the app, which then owns the workspace in process (its start sees the job off),
    /// and quits this copy, which owns nothing. The new copy comes forward only if this one was.
    @MainActor static func relaunchInProcess() {
        guard !relaunching else { return }
        relaunching = true
        ShepherdLog.info("background host is off; relaunching to run agents in process")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = NSApp.isActive
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error { return NSLog("Shepherd: relaunch failed: \(error)") }
                NSApp.terminate(nil)
            }
        }
    }

    /// The host's token: the remote one, which only this user can read.
    static func token(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        (try? String(contentsOf: ShepherdPaths.remoteTokenURL(environment: environment), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
