import Foundation
import Observation
import UIKit
import UserNotifications
import ShepherdProtocol
import ShepherdRemote

/// Local iPhone alerts from threads the client is already watching. This is not APNs:
/// disconnected, suspended, and never-opened threads have no live goal updates here.
@MainActor
final class GoalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = GoalNotifications()
    private var watching: Set<AgentRef> = []
    private var previous: [AgentRef: NativeGoal] = [:]
    private var wasLive: [AgentRef: Bool] = [:]
    // The fixture app must never prompt for permission or post a real notification.
    private let available = Bundle.main.bundleIdentifier == "com.bailycase.shepherd.ios"
        && UIDevice.current.userInterfaceIdiom == .phone

    override init() {
        super.init()
        if available { UNUserNotificationCenter.current().delegate = self }
    }

    func watch(_ store: NativeThreadStore, hosts: MobileHosts, ref: AgentRef) {
        guard available, watching.insert(ref).inserted else { return }
        track(store, hosts: hosts, ref: ref)
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
        // A first snapshot is a baseline, not a newly completed goal. Reconnecting must not
        // replay an old alert, and elapsed/metadata revisions must not post another one.
        guard live, previouslyLive, let goal, let old, old.id == goal.id, old.state != goal.state,
              goal.state == .met || goal.state == .needsYou else { return }
        Task { [weak self, weak store, weak hosts] in
            guard let self else { return }
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
            } catch { ShepherdLog.warning("Goal notification authorization failed: \(error.localizedDescription)"); return }
            guard watching.contains(ref), hosts?.host(ref.host)?.phase.isConnected == true,
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

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
