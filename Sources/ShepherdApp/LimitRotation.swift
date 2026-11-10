import Foundation
import ShepherdCore
import ShepherdRemote
import ShepherdSessions

/// A provider's limit on an agent's request, handled the same by the app in process and by the
/// host with no app: with rotation on and another saved account free, that account takes over,
/// the thread says so (`notice`), and the turn goes on with it (`continueAfterAccountSwitch`).
/// With no account to switch to, nothing happens here and the turn fails visibly.
@MainActor
struct LimitRotation {
    /// Weak: the server holds this in its `onAgentProviderError`.
    weak var server: SessionServer?
    let piAuth: PiAuthStore
    let notice: (AgentID, String) -> Void

    /// `SessionServer.onAgentProviderError`.
    func providerError(_ agentID: AgentID, provider: String, message: String) {
        guard PiAuthText.isLimit(message) else { return }
        Task {
            guard let switched = await piAuth.limitHit(provider) else { return }
            ShepherdLog.info("switched \(provider) to \(switched.to): \(switched.from) hit its limit")
            notice(agentID, PiAuthText.switched(provider, switched))
            server?.continueAfterAccountSwitch(agentID)
        }
    }
}
