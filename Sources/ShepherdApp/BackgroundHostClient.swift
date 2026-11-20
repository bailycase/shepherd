import Foundation
import ShepherdProtocol

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

    /// A known older host needs a handoff, even if it doesn't take `drain` on the wire.
    static func needsUpdate(appBuild: String?, hostBuild: String?) -> Bool {
        guard let app = appBuild.flatMap(Int.init), let host = hostBuild.flatMap(Int.init) else { return false }
        return app > host
    }
}
