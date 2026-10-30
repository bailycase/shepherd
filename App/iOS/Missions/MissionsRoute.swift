import SwiftUI
import ShepherdCore
import ShepherdRemote

/// The missions track's screens (MobileMissions, MobileMission, iPadMissions, iPadMissionMap,
/// iPadMissionReview boards). Missions live on their host; every screen reads its
/// `MobileHost.missions` and acts through it (docs/missions.md › Remote).
enum MissionsRoute: Hashable, Codable {
    /// Every host's missions; on iPad, beside the chosen one.
    case list
    case mission(host: UUID, mission: MissionID)
    /// The repositories' actual changes, and Publish.
    case review(host: UUID, mission: MissionID)
    /// One reviewed file's diff.
    case file(host: UUID, mission: MissionID, space: SpaceID, path: String)
    /// New mission on `host` (or the first that offers missions). Presented.
    case new(host: UUID?)

    var host: UUID? {
        switch self {
        case .list: nil
        case .mission(let host, _), .review(let host, _), .file(let host, _, _, _): host
        case .new(let host): host
        }
    }
}

struct MissionsDestination: View {
    let route: MissionsRoute

    var body: some View {
        switch route {
        case .list: MissionsScreen()
        case .mission(let host, let mission): MissionScreen(host: host, id: mission)
        case .review(let host, let mission): MissionReviewScreen(host: host, id: mission)
        case .file(let host, let mission, let space, let path): MissionFileScreen(host: host, id: mission, space: space, path: path)
        case .new(let host): NewMissionScreen(host: host)
        }
    }
}

/// How the other screens reach missions.
@MainActor
enum MissionsHooks {
    /// One mission: pushed on iPhone; on iPad the list opens with it chosen.
    static func open(host: UUID, mission: MissionID, navigator: MobileNavigator) {
        switch navigator.layout {
        case .phone: navigator.open(.missions(.mission(host: host, mission: mission)))
        case .pad:
            MissionsChoice.shared.chosen = MissionKey(host: host, mission: mission)
            navigator.open(.missions(.list))
        }
    }

    static func create(host: UUID? = nil, navigator: MobileNavigator) {
        navigator.present(.missions(.new(host: host)))
    }
}

extension MobileRoute {
    var isMissions: Bool { if case .missions = self { true } else { false } }
}

/// A mission on a host.
struct MissionKey: Hashable {
    var host: UUID
    var mission: MissionID
}

/// The iPad list's chosen mission, kept while the screen comes and goes.
@MainActor @Observable
final class MissionsChoice {
    static let shared = MissionsChoice()
    var chosen: MissionKey?
}
