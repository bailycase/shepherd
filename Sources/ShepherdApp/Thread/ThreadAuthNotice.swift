import SwiftUI
import ShepherdUI
import ShepherdSessions

/// What the end of a local agent's thread says about signing in (PiAuthStates, PiImportProgress,
/// AgentNotSignedIn; docs/design/thread.md › Thread): waiting for the first launch's copy, or not signed in.
enum ThreadAuthNotice: Equatable {
    /// Held while the first launch's copy runs (or its sheet asks for a sign-in).
    case waiting(restoredAt: Date)
    /// pi can't start: nothing signs in for `provider` (nil when pi names none). `model` is the
    /// one it uses, short; `skipped` when the user's pi had a sign-in for it that didn't come over.
    case notSignedIn(provider: String?, model: String?, at: Date, skipped: Bool)

    static let rowID = "thread.authNotice"

    /// The waiting line's words.
    static let waitingMessage = "It picks up once your pi is brought over."

    /// "restored 9:41 AM".
    static func restored(_ date: Date) -> String {
        "restored \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// The card's title name ("Anthropic", or "a provider").
    static func providerName(_ provider: String?) -> String {
        provider.map(PiSignInCatalog.name) ?? "a provider"
    }

    /// What follows "This agent uses `model`.". A provider Shepherd's pi doesn't know at all (one
    /// an extension registers, switched off) is no sign-in's fault: pick another model.
    static func reason(provider: String?, skipped: Bool) -> String {
        let name = providerName(provider)
        if let provider, !known(provider) {
            return "Shepherd’s pi has no provider named \(provider); one of your extensions, which came over switched off, may add it. "
                + "Use another model, or switch the extension on in Settings ▸ Pi. Your message is kept."
        }
        let why = skipped ? "\(name)’s sign-in was skipped when your pi came over"
            : provider == nil ? "Shepherd’s pi isn’t signed in to a provider for it" : "Shepherd’s pi isn’t signed in to \(name)"
        return "\(why), so the agent is waiting for you. Your message is kept."
    }

    /// Whether Shepherd can sign in to `provider` (pi's own, or one Shepherd's models.json configures).
    static func known(_ provider: String) -> Bool {
        PiProviders.names[provider] != nil || PiSignInCatalog.subscription(provider) != nil
    }
}

/// What the card's buttons do.
struct ThreadAuthActions {
    /// Opens Settings ▸ Pi ▸ Sign-in at the provider and starts it (nil: the page as it is).
    var signIn: (String?) -> Void
    /// Starts the agent again on another model.
    var useModel: (String) -> Void
    /// The models Shepherd's pi can use now.
    var models: () async -> [String]
}

/// The line or card itself, at the thread's end.
struct ThreadAuthNoticeView: View {
    let notice: ThreadAuthNotice
    let actions: ThreadAuthActions?
    @State private var models: [String] = []

    var body: some View {
        switch notice {
        case .waiting(let restoredAt):
            SHAgentWaitingLine(message: ThreadAuthNotice.waitingMessage, trailing: ThreadAuthNotice.restored(restoredAt))
        case .notSignedIn(let provider, let model, let at, let skipped):
            let usable = models.filter { provider == nil || !$0.hasPrefix(provider! + "/") }
            SHAgentNotSignedInCard(provider: ThreadAuthNotice.providerName(provider), model: model,
                                   reason: ThreadAuthNotice.reason(provider: provider, skipped: skipped),
                                   time: at.formatted(date: .omitted, time: .shortened), signIn: { actions?.signIn(provider) }) {
                if usable.isEmpty {
                    Text("No other model is signed in")
                } else {
                    ForEach(usable, id: \.self) { id in
                        Button(id) { actions?.useModel(id) }
                    }
                }
            }
            .task(id: notice) {
                models = await actions?.models() ?? []
            }
        }
    }
}
