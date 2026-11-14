import Foundation
import ShepherdProtocol
import ShepherdSessions

/// `Shepherd --fleet-where`, for the launcher shim: prints where this Mac's Shepherd listens and exits, with no UI
/// (`FleetWhereCommand`). The other Mac's Add a Mac ▸ Connect over SSH runs it through `shepherd-cli fleet-where`.
public enum ShepherdFleetWhere {
    public static var requested: Bool { CommandLine.arguments.dropFirst().contains(FleetWhereCommand.argument) }

    public static func main() -> Never {
        FleetWhereCommand.main(socket: BackgroundHostClient.socketPath(),
                               app: ShepherdEdition.current.displayName,
                               version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    }
}
