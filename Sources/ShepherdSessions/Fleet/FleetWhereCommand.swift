import Foundation
import ShepherdProtocol
import ShepherdRemote

/// `Shepherd --fleet-where`: what another Mac's `shepherd-cli fleet-where` runs (`FleetSSHFinder`). It reads this Mac's own host over
/// `host.sock`, as the app does, and prints where it listens (`FleetWhere`) as one line of JSON. It changes nothing and holds no
/// code or token in its output.
public enum FleetWhereCommand {
    public static let argument = "--fleet-where"
    /// The exit status when no host answers on `host.sock`, and when one answers but isn't listening.
    public static let notRunningStatus: Int32 = 3
    public static let notServingStatus: Int32 = 4

    public enum Outcome: Equatable, Sendable {
        case found(FleetWhere)
        case notRunning
        case notServing

        public var status: Int32 {
            switch self {
            case .found: 0
            case .notRunning: FleetWhereCommand.notRunningStatus
            case .notServing: FleetWhereCommand.notServingStatus
            }
        }
    }

    /// Asks the host whose local socket is `socket` (opened with `token`) who and where it is.
    public static func read(socket: String, token: String, app: String? = nil, version: String? = nil) async -> Outcome {
        let client = RemoteHostClient(localSocket: socket)
        defer { client.disconnect() }
        let snapshot: FleetSnapshot
        do {
            _ = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            snapshot = try await client.fleetRead().snapshot
        } catch {
            return .notRunning
        }
        guard let found = try? FleetWhere(snapshot: snapshot, app: app, version: version) else { return .notServing }
        return .found(found)
    }

    /// The command: prints the answer (or why there is none, on stderr) and exits.
    public static func main(socket: String, token: String, app: String?, version: String?) -> Never {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome = Outcome.notRunning
        Task {
            outcome = await read(socket: socket, token: token, app: app, version: version)
            done.signal()
        }
        done.wait()
        switch outcome {
        case .found(let found): print(found.line())
        case .notRunning: FileHandle.standardError.write(Data("shepherd: Shepherd isn't running\n".utf8))
        case .notServing: FileHandle.standardError.write(Data("shepherd: Shepherd isn't serving\n".utf8))
        }
        exit(outcome.status)
    }
}
