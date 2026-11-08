import SwiftUI
import ShepherdUI
import UIKit
import UserNotifications
import UserNotificationsUI

// The notification content extension: what a long press on a Shepherd push opens
// (NotifPhoneRich, NotifPhoneReview). It draws the push's `shepherd.detail` and runs nothing:
// every button goes to the app, which answers, approves or opens.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private var host: UIHostingController<SHPushPreview>?

    override func viewDidLoad() {
        super.viewDidLoad()
        SHFonts.register()
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let shepherd = content.userInfo["shepherd"] as? [String: Any]
        // A detail this build can't read is left out; the push's own text still shows.
        let detail = (shepherd?["detail"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(SHPushDetail.self, from: $0) }
        let preview = SHPushPreview(title: content.title, subtitle: content.subtitle, body: content.body,
                                    date: notification.date, detail: detail)
        if let actions = PushButtons.actions(kind: content.categoryIdentifier, options: detail?.options,
                                             mission: content.threadIdentifier.hasPrefix("mission:") && detail?.lanes != nil) {
            extensionContext?.notificationActions = actions
        }
        if let host {
            host.rootView = preview
        } else {
            let host = UIHostingController(rootView: preview)
            host.view.backgroundColor = .clear
            host.sizingOptions = .preferredContentSize
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            host.didMove(toParent: self)
            self.host = host
        }
        let width = view.bounds.width
        preferredContentSize = CGSize(width: width, height: host?.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 0)
    }

    /// Every button is the app's: hand it over with the response, as without an extension.
    func didReceive(_ response: UNNotificationResponse, completionHandler completion: @escaping (UNNotificationContentExtensionResponseOption) -> Void) {
        completion(.dismissAndForwardAction)
    }
}
