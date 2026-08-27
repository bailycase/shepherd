import AppKit
import UserNotifications
import ShepherdCore

/// System notifications for agent lifecycle: an agent finishing a turn or
/// asking a question posts a banner, clicking it selects that agent. Enabled/
/// disabled through macOS System Settings — no in-app toggle.
@MainActor
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Set by the view model; called with the agent id when a notification
    /// is clicked.
    var onSelectAgent: ((AgentID) -> Void)?

    /// UNUserNotificationCenter traps without a bundle (swift test, bare
    /// SwiftPM runs), so everything guards on this.
    private let available = Bundle.main.bundleIdentifier != nil
    private var requestedAuthorization = false

    override init() {
        super.init()
        // The delegate must be in place before launch finishes, or a click
        // that cold-launches the app is dropped instead of selecting the agent.
        if available {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func agentStatusChanged(_ agent: Agent, from old: AgentStatus, isAgentVisible: Bool) {
        guard available else { return }
        // Only working→done / working→blocked are "your attention is
        // wanted" moments; idle churn (launch resets, session restarts) is not.
        guard old == .working, agent.status == .done || agent.status == .blocked else { return }
        // Watching the agent already — no banner needed.
        if isAgentVisible && NSApp.isActive { return }

        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let content = UNMutableNotificationContent()
        content.title = agent.name
        content.body = agent.status == .done ? "Agent finished" : "Agent needs your input"
        if agent.status == .blocked { content.sound = .default }
        content.userInfo = ["agentID": agent.id.rawValue]
        // One notification per agent: a newer status replaces the older banner.
        center.add(UNNotificationRequest(
            identifier: "agent-status-\(agent.id.rawValue)",
            content: content,
            trigger: nil
        ))
    }

    /// A custom notification from an agent's notify tool. Always posted —
    /// the agent explicitly asked, so visibility rules don't apply.
    func agentNotify(_ agent: Agent, title: String, body: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.isEmpty ? agent.name : "\(agent.name)\n\(body)"
        content.sound = .default
        content.userInfo = ["agentID": agent.id.rawValue]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Sessions die with the app; their notifications should too.
    func removeAll() {
        guard available else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo["agentID"] as? String
        Task { @MainActor in
            NSApp.activate()
            if let raw {
                self.onSelectAgent?(AgentID(rawValue: raw))
            }
            completionHandler()
        }
    }

    /// Show banners even while the app is frontmost (a different agent than
    /// the one you're watching may finish).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
