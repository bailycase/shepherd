import Foundation
import ShepherdProtocol

/// A remote thread header's Run control (AppsQuickAction, AppsRunning boards), as the Mac's
/// `ThreadAppsButton` draws it: the quick actions of the thread's space and the host's, the one
/// the button shows, and each menu row's second line.
public struct RemoteQuickApps: Equatable, Sendable {
    public let space: String
    public let items: [RemoteApp]

    /// Nil when the space has no quick actions: no Run control.
    public init?(_ result: RemoteAppsResult) {
        let items = result.apps.filter(\.app.quickAction)
        guard !items.isEmpty else { return nil }
        space = result.space
        self.items = items
    }

    /// What the button shows: the first running app, else the first quick action.
    public var primary: RemoteApp { items.first { $0.run?.isLive == true } ?? items[0] }

    /// What a menu row's tap does to it.
    public enum Action: Equatable, Sendable { case run, stop, restart }

    public static func action(_ app: RemoteApp) -> Action {
        switch app.run?.status {
        case .starting?, .running?: .stop
        case .exited?: .restart
        case .failed?, nil: .run
        }
    }

    /// ":3000" beside a running app's name.
    public static func portLabel(_ app: RemoteApp) -> String? { app.run?.port.map { ":\($0)" } }

    /// "Browser tab", "Terminal", "Its own window".
    public static func place(_ app: AppDefinition) -> String {
        switch app.opens {
        case .browser: "Browser tab"
        case .terminal: "Terminal"
        case .window: "Its own window"
        }
    }

    /// The menu row's second line: where it opens, or what it is doing.
    public static func detail(_ app: RemoteApp) -> String {
        switch app.run?.status {
        case .starting?: "Starting… · Stop"
        case .running?: ["Running", portLabel(app)].compactMap { $0 }.joined(separator: " · ") + " · Stop"
        case .exited(let code)?: "Exited (code \(code)) · Restart"
        case .failed?, nil: place(app.app)
        }
    }
}
