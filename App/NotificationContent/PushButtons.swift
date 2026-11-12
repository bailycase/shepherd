import Foundation
import UserNotifications

// Shared by the app (which registers the categories and acts on a button) and the notification
// content extension (which swaps in a push's own buttons while it is open).

/// The buttons under a push, by its kind: the relay names the category after the event's kind.
/// iPhone shows them on a long press, iPad under the banner and in Notification Center
/// (NotifPhoneReview, NotifiPadBanner, NotifiPadCenter).
enum PushButtons {
    static let reply = "reply"
    static let open = "open"
    static let review = "review"
    /// A question's option, by its index in `shepherd.detail.options`: "option:0".
    static let option = "option:"

    /// The buttons a long press shows for a push the content extension draws, in place of its
    /// category's: a question's options before Reply… and Open (NotifPhoneRich's per-question
    /// buttons). Nil keeps the category's.
    static func actions(kind: String, options: [String]?) -> [UNNotificationAction]? {
        if kind == "needsAnswer", let options, !options.isEmpty {
            let buttons = options.enumerated().map { index, title in
                UNNotificationAction(identifier: option + String(index), title: title, options: [.authenticationRequired])
            }
            return buttons + Array(categories.first { $0.identifier == kind }?.actions ?? [])
        }
        return nil
    }

    /// The option an `option:<n>` button names, from the push it sits under.
    static func optionText(_ action: String, userInfo: [AnyHashable: Any]) -> String? {
        guard action.hasPrefix(option), let index = Int(action.dropFirst(option.count)),
              let options = ((userInfo["shepherd"] as? [String: Any])?["detail"] as? [String: Any])?["options"] as? [String],
              options.indices.contains(index) else { return nil }
        return options[index]
    }

    static var categories: Set<UNNotificationCategory> {
        let open = UNNotificationAction(identifier: open, title: "Open", options: [.foreground])
        func category(_ kind: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(identifier: kind, actions: actions, intentIdentifiers: [])
        }
        return [
            category("needsAnswer", [
                UNTextInputNotificationAction(identifier: reply, title: "Reply…", options: [.authenticationRequired],
                                              icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                              textInputButtonTitle: "Send", textInputPlaceholder: "Your answer"),
                open,
            ]),
            category("error", [open]),
            category("done", [UNNotificationAction(identifier: review, title: "Review", options: [.foreground],
                                                   icon: UNNotificationActionIcon(systemImageName: "chevron.right"))]),
        ]
    }
}
