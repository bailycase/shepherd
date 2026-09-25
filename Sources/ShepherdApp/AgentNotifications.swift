import AppKit
import UserNotifications
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// System notifications for agent lifecycle: an agent finishing a turn, failing one, or
/// asking a question posts a banner (`AgentBanners` decides which), clicking it selects that
/// agent. Enabled/disabled through macOS System Settings — no in-app toggle.
@MainActor
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Set by the view model; called with the agent id when a notification
    /// is clicked.
    var onSelectAgent: ((AgentID) -> Void)?

    /// UNUserNotificationCenter traps without a bundle (swift test, bare
    /// SwiftPM runs), so everything guards on this.
    private let available = Bundle.main.bundleIdentifier != nil
    private var requestedAuthorization = false
    private var subagentAsks = SubagentAsks()

    override init() {
        super.init()
        // The delegate must be in place before launch finishes, or a click
        // that cold-launches the app is dropped instead of selecting the agent.
        if available {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func agentStatusChanged(_ agent: Agent, from old: AgentStatus, failure: TurnFailure?, isAgentVisible: Bool) {
        guard available else { return }
        // Watching the agent already — no banner needed.
        let watching = isAgentVisible && NSApp.isActive
        guard let banner = AgentBanners.status(of: agent, from: old, failure: failure, watching: watching) else { return }
        post(banner)
    }

    /// An agent's subagents as published: a run that starts asking posts a banner, by the same
    /// rules as the agent's own question.
    func subagentsChanged(_ agent: Agent, children: [ChildRun], isAgentVisible: Bool) {
        let asking = subagentAsks.update(agentID: agent.id, children: children)
        guard available, !asking.isEmpty, !(isAgentVisible && NSApp.isActive) else { return }
        for run in asking { post(AgentBanners.subagentQuestion(run, of: agent)) }
    }

    /// The agent is gone; its subagents' questions go with it.
    func forgetSubagents(of agentID: AgentID) {
        subagentAsks.forget(agentID)
    }

    private func post(_ banner: AgentBanner) {
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = banner.title
        content.body = banner.body
        if banner.sound { content.sound = .default }
        content.userInfo = ["agentID": banner.agentID.rawValue]
        center.add(UNNotificationRequest(identifier: banner.identifier, content: content, trigger: nil))
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
