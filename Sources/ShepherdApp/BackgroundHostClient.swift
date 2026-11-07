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

    /// The host's token: the remote one, which only this user can read.
    static func token(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        (try? String(contentsOf: ShepherdPaths.remoteTokenURL(environment: environment), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
