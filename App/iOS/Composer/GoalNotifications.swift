import Foundation
import Observation
import UserNotifications
import ShepherdProtocol
import ShepherdRemote

/// Local goal alerts from threads the iOS client is already watching. This is not APNs:
/// disconnected, suspended, and never-opened threads have no live goal updates here.
@MainActor
final class GoalNotifications: NSObject {
    static let shared = GoalNotifications()
    private var watching: Set<AgentRef> = []
    private var previous: [AgentRef: NativeGoal] = [:]
    private var wasLive: [AgentRef: Bool] = [:]
    /// When push is enabled for a host, skip local goal alerts for its agents to avoid duplicates.
    var pushEnabledHosts: Set<UUID> = []
    private let bundleID: String?

    init(bundleID: String? = Bundle.main.bundleIdentifier) {
        self.bundleID = bundleID
        super.init()
        // The notification center delegate is set by PushAppDelegate,
        // which consolidates both push and local goal notification handling.
    }

    func watch(_ store: NativeThreadStore, hosts: MobileHosts, ref: AgentRef) {
        guard watching.insert(ref).inserted else { return }
        track(store, hosts: hosts, ref: ref)
    }

    /// Permission may suspend while another window enables push for this host.
    func authorizeLocalAlert(host: UUID, request: () async throws -> Bool) async throws -> Bool {
        // Check the bundle before asking so fixtures never prompt for real permission.
        guard GoalAlertPolicy.isAvailable(bundleID: bundleID, authorizationGranted: true),
              !pushEnabledHosts.contains(host) else { return false }
        let granted = try await request()
        return GoalAlertPolicy.isAvailable(bundleID: bundleID, authorizationGranted: granted)
            && !pushEnabledHosts.contains(host)
    }

    private func track(_ store: NativeThreadStore, hosts: MobileHosts, ref: AgentRef) {
        guard watching.contains(ref) else { return }
        guard hosts.host(ref.host) != nil else {
            watching.remove(ref)
            previous[ref] = nil
            wasLive[ref] = nil
            return
        }
        let (goal, live) = withObservationTracking {
            (store.goal, hosts.host(ref.host)?.phase.isConnected == true
                && store.isLive && store.ready && store.loadError == nil)
        } onChange: { [weak self, weak store, weak hosts] in
            Task { @MainActor [weak self, weak store, weak hosts] in
                guard let store, let hosts else { return }
                self?.track(store, hosts: hosts, ref: ref)
            }
        }
        let old = previous[ref]
        let previouslyLive = wasLive[ref] == true
        previous[ref] = goal
        wasLive[ref] = live
        // Skip local alert if push is enabled for this host (push delivers it instead).
        guard GoalAlertPolicy.shouldPost(old: old, new: goal, previouslyLive: previouslyLive,
                                         live: live, pushEnabled: pushEnabledHosts.contains(ref.host)) else { return }
        guard let goal else { return }
        Task { [weak self, weak store, weak hosts] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            do {
                guard try await authorizeLocalAlert(host: ref.host, request: {
                    try await center.requestAuthorization(options: [.alert, .sound])
                }) else { return }
            } catch { ShepherdLog.warning("Goal notification authorization failed: \(error.localizedDescription)"); return }
            guard !pushEnabledHosts.contains(ref.host),
                  watching.contains(ref), hosts?.host(ref.host)?.phase.isConnected == true,
                  let store, store.isLive, store.ready, store.loadError == nil,
                  store.goal?.id == goal.id, store.goal?.state == goal.state else { return }
            let content = UNMutableNotificationContent()
            content.title = goal.state == .met ? "Goal met" : "Goal needs you"
            content.subtitle = store.hostName ?? "Shepherd"
            content.body = goal.notificationLabel
            content.sound = .default
            content.threadIdentifier = "goal:\(ref.host.uuidString):\(ref.agent.rawValue)"
            do {
                try await center.add(UNNotificationRequest(identifier: content.threadIdentifier + ":" + goal.id,
                                                            content: content, trigger: nil))
            } catch { ShepherdLog.warning("Goal notification delivery failed: \(error.localizedDescription)") }
        }
    }

}
