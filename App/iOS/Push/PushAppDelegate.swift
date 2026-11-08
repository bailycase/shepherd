import UIKit
import UserNotifications

/// UIApplicationDelegate for APNs token callbacks and notification center delegate.
///
/// Installed once by SwiftUI's `@UIApplicationDelegateAdaptor`. Sets itself as the
/// `UNUserNotificationCenter` delegate in `didFinishLaunchingWithOptions` — before any
/// SwiftUI body runs — so cold-launch notification taps are never lost.
///
/// Payloads that arrive before `configure(…)` wires the router are buffered in
/// `pendingPayloads` and flushed on configure. A payload is only discarded after a
/// window actually handles the route (PushRouter returns success).
final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set once by `configure(…)` after the app's state is ready.
    weak var pushManager: PushManager?
    weak var pushRouter: PushRouter?
    weak var mobileHosts: MobileHosts?
    weak var mobileWindows: MobileWindows?

    /// Payloads from taps that arrived before the router was wired.
    private var pendingPayloads: [PushPayload] = []
    /// Whether `configure` has been called.
    private var configured = false
    private var earlyToken: Data?
    private var earlyTokenError: Error?

    // MARK: - UIApplicationDelegate

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Claim the notification center delegate before any notification can arrive.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(PushButtons.categories)
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            if let pushManager { pushManager.setDeviceToken(deviceToken) }
            else { earlyToken = deviceToken; earlyTokenError = nil }
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            if let pushManager { pushManager.setTokenError(error) }
            else { earlyTokenError = error }
        }
    }

    // MARK: - Configuration

    /// Wire to the app's live instances. Call once, as early as possible after `MobileApp`
    /// is created. Flushes any notification taps that arrived before this point.
    @MainActor
    func configure(push: PushManager, router: PushRouter, hosts: MobileHosts, windows: MobileWindows) {
        pushManager = push
        pushRouter = router
        mobileHosts = hosts
        mobileWindows = windows
        configured = true
        if let earlyToken { push.setDeviceToken(earlyToken) }
        if let earlyTokenError { push.setTokenError(earlyTokenError) }
        earlyToken = nil
        earlyTokenError = nil
        flushPending()
    }

    /// Attempt to route buffered payloads. Only clears a payload when routing succeeds.
    @MainActor
    func flushPending() {
        guard configured, let router = pushRouter, let hosts = mobileHosts, let windows = mobileWindows else { return }
        for payload in pendingPayloads { router.route(payload, hosts: hosts, windows: windows) }
        pendingPayloads.removeAll()
        router.drainPending(hosts: hosts, windows: windows)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Notification arrived while app is in foreground — show banner for both remote pushes
    /// and local goal notifications, including the thread currently being viewed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundPresentation
    }

    nonisolated static var foregroundPresentation: UNNotificationPresentationOptions { [.banner, .list, .sound] }

    /// User tapped a notification. If the router is wired and a window is ready, route now;
    /// otherwise buffer the payload until `flushPending()`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        guard let payload = PushPayload.from(content.userInfo) else { return }
        // An option button answers with its option, the way Reply… answers with the words.
        if let option = PushButtons.optionText(response.actionIdentifier, userInfo: content.userInfo) {
            await act(PushButtons.reply, text: option, payload: payload, thread: content.threadIdentifier)
            return
        }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await act(response.actionIdentifier, text: text, payload: payload, thread: content.threadIdentifier)
    }

    /// A tap or Open goes to the thread; Review and Open review to the changes; Reply… and
    /// Approve act on the host, saying so in a notification when they couldn't.
    @MainActor
    func act(_ action: String, text: String?, payload: PushPayload, thread: String) async {
        switch action {
        case PushButtons.reply, PushButtons.approve:
            guard let hosts = mobileHosts else { return }
            do {
                try await PushActions.perform(action, text: text, payload: payload, hosts: hosts)
                if action == PushButtons.approve { receive(payload, to: .missionReview) }
            } catch {
                let failure = (error as? GlanceFailure)?.message ?? error.localizedDescription
                let content = UNMutableNotificationContent()
                content.title = action == PushButtons.reply ? "Your answer wasn’t sent" : "Not approved"
                content.body = failure
                content.threadIdentifier = thread
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        case PushButtons.review: receive(payload, to: .changes)
        case PushButtons.openReview: receive(payload, to: .missionReview)
        case PushButtons.openMission where thread.hasPrefix("mission:"):
            receive(payload, to: .mission(String(thread.dropFirst("mission:".count))))
        default: receive(payload)
        }
    }

    @MainActor
    func receive(_ payload: PushPayload, to destination: PushPayload.Destination = .thread) {
        var payload = payload
        payload.destination = destination
        pendingPayloads.append(payload)
        flushPending()
    }
}
