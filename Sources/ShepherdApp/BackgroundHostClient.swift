import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The app as its host's client: launchd's background host or the app's own child
/// (`HostSupervisor`) owns the workspace, and the app shows its threads and terminals through
/// `host.sock`.
enum BackgroundHostClient {
    /// A host holds the workspace (its lock) but its socket hasn't answered yet: it is starting,
    /// or draining for an update.
    struct HostStarting: Error, CustomStringConvertible {
        var description: String { "Shepherd's background service is starting" }
    }

    /// The launchd job's status this launch, nil when it may not register (`BackgroundService`).
    /// Written once by the start, off main, before the model is made; read on main after.
    nonisolated(unsafe) static var serviceStatus: BackgroundService.Status?

    static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        ShepherdPaths.supportDirectory(environment: environment).appendingPathComponent("host.sock").path
    }

    /// Whether the app asks its host to drain: the host is an older build that takes `drain`.
    /// An older host without it drains once it sees the new bundle on disk; one whose build
    /// can't be compared is left alone.
    static func asksToDrain(appBuild: String?, hostBuild: String?, capabilities: Set<String>) -> Bool {
        guard capabilities.contains(RemoteProtocol.hostDrainCapability),
              let app = appBuild.flatMap(Int.init), let host = hostBuild.flatMap(Int.init) else { return false }
        return app > host
    }

    /// The host's token: the remote one, which only this user can read.
    static func token(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        (try? String(contentsOf: ShepherdPaths.remoteTokenURL(environment: environment), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
