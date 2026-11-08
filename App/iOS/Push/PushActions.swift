import Foundation
import LocalAuthentication
import UserNotifications
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What a push's buttons do: Reply… and an option answer the question, Approve publishes the
/// reviewed mission. The buttons themselves are `PushButtons`, shared with the content extension.
enum PushActions {
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
        case PushButtons.reply:
            try await hosts.withClient(ref.host) { client in
                guard case .snapshot(let thread) = try await client.nativeThread(agentID: ref.agent, request: .snapshot()),
                      let dialog = thread.dialogs.first else { throw GlanceFailure("That question was already answered.") }
                guard let answer = answer(text ?? "", to: dialog) else { throw GlanceFailure("Open Shepherd to answer this one.") }
                let result = try await client.nativeThread(agentID: ref.agent, request: .answer(
                    expectedSessionID: thread.piSessionID, generation: thread.generation, operationID: UUID(),
                    dialogID: dialog.id, answer: answer))
                if case .failure(_, let message) = result { throw GlanceFailure(message) }
            }
        case PushButtons.approve:
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
