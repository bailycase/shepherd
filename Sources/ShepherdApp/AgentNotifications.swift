import AppKit
import UserNotifications
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// What the person did with a banner: clicked it (`action` nil) or chose one of its actions.
struct BannerResponse: Equatable {
    let target: BannerTarget
    let action: BannerAction?
    /// Reply…'s words.
    let text: String?
    /// The question the banner asked (pi's dialog id, or a subagent run's id).
    let question: String?
}

/// Posts the Mac's system notifications (`AgentBanners` decides what they say) and hands back
/// what the person does with them. Turned on and off in System Settings; no in-app toggle.
@MainActor
final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Set by the view model: a click or an action on a banner.
    var onResponse: ((BannerResponse) -> Void)?

    /// UNUserNotificationCenter traps without a bundle (swift test, bare SwiftPM runs), so
    /// everything guards on this, and callers skip the work a banner would need.
    let available = Bundle.main.bundleIdentifier != nil
    private var requestedAuthorization = false
    /// Each banner's actions, by identifier, to read a response against.
    private var posted: [String: [BannerAction]] = [:]
    /// The categories registered so far, newest last: one per set of actions.
    private var categories: [(id: String, category: UNNotificationCategory)] = []
    private static let categoryLimit = 64

    // What has been posted about, so each question posts once and goes when answered.
    var localAsks = ThreadAsks<AgentID>()
    var remoteAsks = ThreadAsks<RemoteAgentRef>()
    var localSubagents = SubagentAsks<AgentID>()
    var remoteSubagents = SubagentAsks<RemoteAgentRef>()
    /// Hosts whose offline banner is up.
    var offlineHosts: Set<UUID> = []

    override init() {
        super.init()
        // The delegate must be in place before launch finishes, or a click that cold-launches
        // the app is dropped instead of selecting the agent.
        if available {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func post(_ banner: AgentBanner) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = banner.title
        if let subtitle = banner.subtitle { content.subtitle = subtitle }
        content.body = banner.body
        if banner.sound { content.sound = .default }
        content.interruptionLevel = banner.level == .passive ? .passive : .active
        content.threadIdentifier = banner.group
        content.categoryIdentifier = register(banner.actions)
        content.userInfo = Self.userInfo(banner)
        if !banner.actions.isEmpty { posted[banner.identifier] = banner.actions }
        center.add(UNNotificationRequest(identifier: banner.identifier, content: content, trigger: nil))
    }

    /// Takes banners down: a question answered, a host back.
    func remove(_ identifiers: [String]) {
        guard available, !identifiers.isEmpty else { return }
        for identifier in identifiers { posted.removeValue(forKey: identifier) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// A custom notification from an agent's notify tool. Always posted — the agent explicitly
    /// asked, so visibility rules don't apply. Grouped with its thread.
    func agentNotify(_ agent: Agent, title: String, body: String) {
        let target = BannerTarget.agent(agent.id)
        post(AgentBanner(identifier: UUID().uuidString, target: target, title: title, subtitle: nil,
                         body: body.isEmpty ? agent.name : "\(agent.name)\n\(body)", level: .active, actions: [],
                         group: AgentBanners.group(target)))
    }

    /// Sessions die with the app; their notifications should too.
    func removeAll() {
        guard available else { return }
        posted.removeAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: Categories

    /// The category for `actions`, registered once: macOS shows the first as the banner's
    /// button and the rest under Options.
    private func register(_ actions: [BannerAction]) -> String {
        guard !actions.isEmpty else { return "" }
        let id = "shepherd." + actions.map { "\($0.identifier)=\($0.title)" }.joined(separator: "|")
        if categories.contains(where: { $0.id == id }) { return id }
        let category = UNNotificationCategory(identifier: id, actions: actions.map(Self.notificationAction),
                                              intentIdentifiers: [], options: [])
        categories.append((id, category))
        if categories.count > Self.categoryLimit { categories.removeFirst(categories.count - Self.categoryLimit) }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories.map(\.category)))
        return id
    }

    private static func notificationAction(_ action: BannerAction) -> UNNotificationAction {
        let options: UNNotificationActionOptions = action.opensShepherd ? [.foreground] : []
        let icon = symbol(action).map { UNNotificationActionIcon(systemImageName: $0) }
        if case .reply(let placeholder) = action {
            return UNTextInputNotificationAction(identifier: action.identifier, title: action.title, options: options,
                                                icon: icon, textInputButtonTitle: "Send", textInputPlaceholder: placeholder)
        }
        return UNNotificationAction(identifier: action.identifier, title: action.title, options: options, icon: icon)
    }

    /// The boards' glyphs: Retry `arrow.clockwise`, Reply… `text.bubble`, Open `chevron.right`.
    private static func symbol(_ action: BannerAction) -> String? {
        switch action {
        case .retry, .reconnect: "arrow.clockwise"
        case .reply: "text.bubble"
        case .open: "chevron.right"
        case .review, .option: nil
        }
    }

    // MARK: Responses

    private static func userInfo(_ banner: AgentBanner) -> [String: String] {
        var info: [String: String] = ["banner": banner.identifier]
        switch banner.target {
        case .agent(let id): info["agentID"] = id.rawValue
        case .remote(let ref): info["agentID"] = ref.agentID.rawValue; info["hostID"] = ref.hostID.uuidString
        case .host(let id): info["hostID"] = id.uuidString
        }
        if let question = banner.question { info["question"] = question }
        return info
    }

    nonisolated static func target(_ info: [AnyHashable: Any]) -> BannerTarget? {
        let agent = (info["agentID"] as? String).map { AgentID(rawValue: $0) }
        let host = (info["hostID"] as? String).flatMap(UUID.init(uuidString:))
        switch (agent, host) {
        case (let agent?, let host?): return .remote(RemoteAgentRef(hostID: host, agentID: agent))
        case (let agent?, nil): return .agent(agent)
        case (nil, let host?): return .host(host)
        case (nil, nil): return nil
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let banner = info["banner"] as? String ?? response.notification.request.identifier
        let actionID = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let question = info["question"] as? String
        let target = Self.target(info)
        Task { @MainActor in
            defer { completionHandler() }
            guard actionID != UNNotificationDismissActionIdentifier else { return }
            let clicked = actionID == UNNotificationDefaultActionIdentifier
            let action = clicked ? nil : BannerAction.named(actionID, in: self.posted[banner] ?? []) ?? Self.fallback(actionID)
            guard clicked || action != nil else { return }
            if action?.opensShepherd ?? true { NSApp.activate() }
            guard let target else { return }
            self.onResponse?(BannerResponse(target: target, action: action, text: text, question: question))
        }
    }

    /// An action on a banner from before a relaunch, whose actions this run never posted: the
    /// fixed ones still mean what they say.
    private static func fallback(_ identifier: String) -> BannerAction? {
        switch identifier {
        case "open": .open
        case "retry": .retry
        case "review": .review
        case "reconnect": .reconnect
        default: nil
        }
    }

    /// Show banners even while the app is frontmost (a different agent than the one you're
    /// watching may finish).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
