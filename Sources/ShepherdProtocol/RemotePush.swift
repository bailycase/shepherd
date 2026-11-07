import Foundation

/// A phone authorizes one host to send generic alerts to its relay registration.
/// The device's APNs token and management credential never travel to the host.
public struct RemotePushRegistration: Codable, Hashable, Sendable {
    public let id: String
    public let sendToken: String
    /// What this phone wants sent (Settings ▸ Notifications). Nil from an older phone: everything.
    public var preferences: RemotePushPreferences?

    public init(id: String, sendToken: String, preferences: RemotePushPreferences? = nil) {
        self.id = id
        self.sendToken = sendToken
        self.preferences = preferences
    }
}

/// Settings ▸ Notifications on the phone (NotifSettings), applied by the host before it sends.
public struct RemotePushPreferences: Codable, Hashable, Sendable {
    /// What an alert is about, as the Send me switches name it.
    public enum Topic: String, Codable, Sendable, CaseIterable {
        case questions, blocked, failures, finished
    }

    /// One mission's own choice, over the Send me switches.
    public enum MissionLevel: String, Codable, Sendable, CaseIterable {
        case everything, onlyBlocked, onlyFailures, nothing

        public func allows(_ topic: Topic) -> Bool {
            switch self {
            case .everything: true
            case .onlyBlocked: topic == .blocked
            case .onlyFailures: topic == .failures
            case .nothing: false
            }
        }
    }

    public var topics: Set<Topic>
    /// Only when the Mac has been idle a while: the Mac's own banner comes first.
    public var awayOnly: Bool
    /// By mission id; a mission not here follows `topics`.
    public var missions: [String: MissionLevel]

    public init(topics: Set<Topic> = Set(Topic.allCases), awayOnly: Bool = true, missions: [String: MissionLevel] = [:]) {
        self.topics = topics
        self.awayOnly = awayOnly
        self.missions = missions
    }

    /// Whether an alert about `topic`, from `mission` if a mission's, goes to this phone.
    public func allows(_ topic: Topic, mission: String?) -> Bool {
        guard topics.contains(topic) else { return false }
        return mission.flatMap { missions[$0] }?.allows(topic) ?? true
    }

    /// How long the Mac must have been idle before an away-only phone hears anything.
    public static let awayAfter: TimeInterval = 120
}
