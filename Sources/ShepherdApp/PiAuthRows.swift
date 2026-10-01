import Foundation
import ShepherdProtocol
import ShepherdSessions

/// A provider's sign-in in Shepherd's pi, as Settings ▸ Pi ▸ Sign-in's row draws it (PiAuthStates'
/// `ProviderAuth`). Names a plan, a variable or a command; a key only masked.
enum ProviderAuth: Equatable {
    case signedIn(plan: String?)
    /// pi said its refresh failed: sign in again.
    case expired(plan: String?)
    case notSignedIn(plan: String?)
    case signingIn(plan: String?)
    /// A key in auth.json: its mask, the variables it reads, or the command it runs; `copied`
    /// while it is still the one copied from the user's pi.
    case key(PiKeyDisplay, copied: Bool)
    /// No stored key, but the login shell sets the provider's variable.
    case environment(variable: String)
    /// A custom provider that needs no key.
    case noKey(baseURL: String?)

    var isSignedIn: Bool {
        switch self {
        case .signedIn, .key, .environment, .noKey: true
        case .expired, .notSignedIn, .signingIn: false
        }
    }
}

/// One row of Sign-in.
struct ProviderRowModel: Equatable, Identifiable {
    var id: String
    var name: String
    var badge: String
    /// A custom provider: its id is its title, in mono.
    var custom = false
    var auth: ProviderAuth
    /// "Signing in here and in your terminal pi can sign one of them out."
    var sharedLoginNote = false
    /// How its Re-import stands; nil when the user's pi has no sign-in for it.
    var freshness: PiFreshness?
    var problem: String?
}

/// Settings ▸ Pi ▸ Sign-in's rows, derived once per change from the survey (docs/design/settings-pi.md › Pi ▸
/// Sign-in). Pure, so the state table has a unit test.
struct PiSignInPage: Equatable {
    var subscriptions: [ProviderRowModel] = []
    var apiKeys: [ProviderRowModel] = []
    var customProviders: [ProviderRowModel] = []
    /// Key providers with no row yet: Add an API key's menu.
    var addable: [String] = []
    /// The nav's lantern dot: a sign-in expired, or a provider an agent waits on isn't signed in.
    var needsAttention = false

    /// `signingIn` is the provider whose sheet is up; `expired` those pi said failed to refresh;
    /// `needed` the providers agents wait on; `problems` a failed sign-out by provider.
    static func make(survey: YourPiSurvey, signingIn: String? = nil, expired: Set<String> = [], needed: Set<String> = [],
                     problems: [String: String] = [:]) -> PiSignInPage {
        var page = PiSignInPage()
        let logins = Dictionary(survey.logins.map { ($0.provider, $0) }, uniquingKeysWith: { first, _ in first })
        let custom = Set(survey.customProviderDetails.map(\.id))

        for subscription in PiSignInCatalog.subscriptions {
            let login = logins[subscription.id]
            let auth: ProviderAuth
            if signingIn == subscription.id {
                auth = .signingIn(plan: subscription.plan)
            } else if login?.shepherd == .subscription {
                auth = expired.contains(subscription.id) ? .expired(plan: subscription.plan) : .signedIn(plan: subscription.plan)
            } else {
                auth = .notSignedIn(plan: subscription.plan)
            }
            page.subscriptions.append(ProviderRowModel(
                id: subscription.id, name: subscription.name, badge: PiSignInCatalog.badge(subscription.id), auth: auth,
                sharedLoginNote: subscription.sharedLogin, freshness: survey.freshness["login:\(subscription.id)"],
                problem: problems[subscription.id]))
        }

        for login in survey.logins where !custom.contains(login.provider) {
            let auth: ProviderAuth
            if signingIn == login.provider, PiSignInCatalog.subscription(login.provider) == nil {
                auth = .signingIn(plan: nil)
            } else if case .apiKey? = login.shepherd {
                auth = .key(survey.keys[login.provider] ?? PiKeyDisplay(masked: "••••"), copied: survey.copiedLogins.contains(login.provider))
            } else if login.shepherd == nil, let variable = login.environment.first {
                auth = .environment(variable: variable)
            } else {
                continue
            }
            page.apiKeys.append(ProviderRowModel(
                id: login.provider, name: PiSignInCatalog.name(login.provider), badge: PiSignInCatalog.badge(login.provider),
                auth: auth, freshness: survey.freshness["login:\(login.provider)"], problem: problems[login.provider]))
        }
        // A key being added shows as signing in until it lands.
        if let signingIn, PiSignInCatalog.subscription(signingIn) == nil, !custom.contains(signingIn),
           !page.apiKeys.contains(where: { $0.id == signingIn }) {
            page.apiKeys.append(ProviderRowModel(id: signingIn, name: PiSignInCatalog.name(signingIn),
                                                 badge: PiSignInCatalog.badge(signingIn), auth: .signingIn(plan: nil)))
        }
        page.apiKeys.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }

        for provider in survey.customProviderDetails {
            let auth: ProviderAuth
            if case .apiKey? = logins[provider.id]?.shepherd, let key = survey.keys[provider.id] {
                auth = .key(key, copied: survey.copiedLogins.contains(provider.id))
            } else if let key = provider.key {
                auth = .key(key, copied: false)
            } else {
                auth = .noKey(baseURL: provider.baseURL)
            }
            page.customProviders.append(ProviderRowModel(id: provider.id, name: provider.id, badge: PiSignInCatalog.badge(provider.id),
                                                         custom: true, auth: auth, problem: problems[provider.id]))
        }

        let listed = Set(page.apiKeys.map(\.id))
        page.addable = PiSignInCatalog.keyProviders.filter { !listed.contains($0) && !custom.contains($0) }
        let signedIn = Set((page.subscriptions + page.apiKeys + page.customProviders).filter { $0.auth.isSignedIn }.map(\.id))
        page.needsAttention = page.subscriptions.contains { if case .expired = $0.auth { true } else { false } }
            || needed.contains { !signedIn.contains($0) }
        return page
    }

    /// Add an API key's second line: "Groq, Mistral, Fireworks, Together and 26 more".
    static func addableSummary(_ providers: [String]) -> String {
        let preferred = ["groq", "mistral", "fireworks", "together", "openai", "openrouter", "deepseek"]
        let first = (preferred.filter(providers.contains) + providers.filter { !preferred.contains($0) }).prefix(4)
        let names = first.map(PiSignInCatalog.name)
        let rest = providers.count - names.count
        guard !names.isEmpty else { return "Every provider has a key" }
        return names.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }
}

/// What pi's words say about sign-ins: the provider a refresh failed for, and the provider a pi
/// that can't start needs.
enum PiAuthText {
    /// "OAuth refresh failed for anthropic" (pi-ai: auth/resolve.js).
    static func expiredProvider(in message: String) -> String? {
        let pattern = #"OAuth refresh (?:failed|returned a token that expires too soon) for ([A-Za-z0-9._-]+)"#
        guard let match = message.range(of: pattern, options: .regularExpression) else { return nil }
        let text = String(message[match])
        return text.split(separator: " ").last.map(String.init)
    }

    /// The provider a not-signed-in start names ("No API key found for anthropic."), else the
    /// agent's model's provider, else the default model's; nil when none says.
    static func missingProvider(lines: [String], model: String?, defaultModel: String?) -> String? {
        for line in lines {
            guard let range = line.range(of: "No API key found for ") else { continue }
            let rest = line[range.upperBound...].prefix { !$0.isWhitespace && $0 != "." }
            if !rest.isEmpty, rest != "the" { return String(rest) }
        }
        for model in [model, defaultModel].compactMap({ $0 }) {
            if let slash = model.firstIndex(of: "/"), slash != model.startIndex { return String(model[..<slash]) }
        }
        return nil
    }
}
