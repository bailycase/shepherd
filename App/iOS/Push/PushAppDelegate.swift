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
    /// and local goal notifications.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// User tapped a notification. If the router is wired and a window is ready, route now;
    /// otherwise buffer the payload until `flushPending()`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let payload = PushPayload.from(userInfo) else { return }
        await receive(payload)
    }

    @MainActor
    func receive(_ payload: PushPayload) {
        pendingPayloads.append(payload)
        flushPending()
    }
}
