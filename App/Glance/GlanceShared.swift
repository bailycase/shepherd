import ActivityKit
import Foundation
import ShepherdUI

// What the app and its widget extension share (docs/design/notifications.md › Glance): the
// Live Activities' attributes, the snapshot the widgets read, and the links back into the app.
// The app is the only writer: it reads its hosts and publishes `SHGlance`; the extension draws it.

/// The Watch: every host's work in one activity.
struct WatchActivity: ActivityAttributes {
    typealias ContentState = SHGlance
}

/// Follow: one thread, its content a glance holding that thread alone.
struct FollowActivity: ActivityAttributes {
    typealias ContentState = SHGlance
    /// `SHGlance.Item.id`: "<host>/<agent>".
    var item: String
}

/// The last glance the app published, in the app group both processes read.
enum GlanceStore {
    static let group = "group.com.bailycase.shepherd.ios"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("glance.json")
    }

    static func read() -> SHGlance? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SHGlance.self, from: data)
    }

    static func write(_ glance: SHGlance) {
        guard let url, let data = try? JSONEncoder().encode(glance) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// `shepherd://` links from a widget or an activity to the screen they name.
enum GlanceLink: Equatable {
    case thread(host: UUID, agent: String)
    case review(host: UUID, agent: String)
    case needsYou
    case newThread

    static let scheme = "shepherd"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .thread(let host, let agent):
            components.host = "thread"
            components.path = "/\(host.uuidString)/\(agent)"
        case .review(let host, let agent):
            components.host = "review"
            components.path = "/\(host.uuidString)/\(agent)"
        case .needsYou: components.host = "needs-you"
        case .newThread: components.host = "new-thread"
        }
        return components.url!
    }

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host() {
        case "needs-you": self = .needsYou
        case "new-thread": self = .newThread
        case "thread", "review":
            guard parts.count == 2, let host = UUID(uuidString: parts[0]), !parts[1].isEmpty else { return nil }
            self = url.host() == "thread" ? .thread(host: host, agent: parts[1]) : .review(host: host, agent: parts[1])
        default: return nil
        }
    }

    /// The thread an item names.
    static func thread(_ item: SHGlance.Item) -> URL? {
        UUID(uuidString: item.host).map { GlanceLink.thread(host: $0, agent: item.agent).url }
    }

    static func review(_ item: SHGlance.Item) -> URL? {
        UUID(uuidString: item.host).map { GlanceLink.review(host: $0, agent: item.agent).url }
    }
}
