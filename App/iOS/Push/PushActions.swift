import Foundation
import LocalAuthentication
import UserNotifications
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The buttons under a push, by its kind: the relay names the category after the event's kind.
/// iPhone shows them on a long press, iPad under the banner and in Notification Center
/// (NotifPhoneReview, NotifiPadBanner, NotifiPadCenter).
enum PushActions {
    static let reply = "reply"
    static let open = "open"
    static let review = "review"
    static let approve = "approve"
    static let openReview = "openReview"

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
            // Approving starts the merge train: it opens Shepherd, which asks for Face ID even on
            // an unlocked phone before it publishes.
            category("review", [
                UNNotificationAction(identifier: approve, title: "Approve · start train",
                                     options: [.foreground, .authenticationRequired],
                                     icon: UNNotificationActionIcon(systemImageName: "faceid")),
                UNNotificationAction(identifier: openReview, title: "Open review", options: [.foreground],
                                     icon: UNNotificationActionIcon(systemImageName: "chevron.right")),
            ]),
        ]
    }

    /// What Reply…'s words answer: the option they name, else the words where the question takes
    /// words. Nil when this question can't be answered from a notification.
    static func answer(_ text: String, to dialog: NativeThreadDialog) -> NativeDialogAnswer? {
        let prompt = NativeQuestionPrompt(dialog: dialog)
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.blocked == nil, !words.isEmpty else { return nil }
        if let option = prompt.options.first(where: { $0.title.caseInsensitiveCompare(words) == .orderedSame }) {
            return prompt.dialogAnswer(.option(option))
        }
        return prompt.dialogAnswer(.words(words))
    }

    /// Runs `action` on `payload`'s host. Throws `GlanceFailure` with the words to show.
    @MainActor
    static func perform(_ action: String, text: String?, payload: PushPayload, hosts: MobileHosts,
                        authenticate: () async throws -> Void = faceID) async throws {
        guard let ref = payload.agentRef else { return }
        switch action {
        case reply:
            try await hosts.withClient(ref.host) { client in
                guard case .snapshot(let thread) = try await client.nativeThread(agentID: ref.agent, request: .snapshot()),
                      let dialog = thread.dialogs.first else { throw GlanceFailure("That question was already answered.") }
                guard let answer = answer(text ?? "", to: dialog) else { throw GlanceFailure("Open Shepherd to answer this one.") }
                let result = try await client.nativeThread(agentID: ref.agent, request: .answer(
                    expectedSessionID: thread.piSessionID, generation: thread.generation, operationID: UUID(),
                    dialogID: dialog.id, answer: answer))
                if case .failure(_, let message) = result { throw GlanceFailure(message) }
            }
        case approve:
            guard let mission = payload.mission else { return }
            try await authenticate()
            try await hosts.withClient(ref.host) { client in
                _ = try await client.mission(.action(missionID: MissionID(rawValue: mission.id), revision: mission.revision,
                                                     action: .publish(fingerprint: mission.fingerprint)))
            }
        default:
            return
        }
    }

    /// Face ID (or the passcode where there is none), asked even on an unlocked device.
    static func faceID() async throws {
        let context = LAContext()
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Approve and start the merge train")
        } catch {
            throw GlanceFailure("Not approved: Face ID didn’t confirm it was you.")
        }
    }
}
