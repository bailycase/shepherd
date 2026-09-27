import Foundation
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

/// `/login` and `/logout` (SlashLogin, SlashLoginArgs; DESIGN.md › Composer › /login and /logout):
/// two commands of Shepherd's own in a local agent's slash menu that never reach pi. Sending one
/// opens Settings ▸ Pi ▸ Sign-in; with a provider, `/login` scrolls there and starts its sign-in.
enum SlashLogin {
    enum Verb: String, Equatable, CaseIterable {
        case login, logout
    }

    /// A `/login …` or `/logout …` the composer won't send.
    struct Command: Equatable {
        var verb: Verb
        /// The provider it names, by id; nil for none, or a name Shepherd doesn't know.
        var provider: String?
    }

    /// Shepherd's source for its own commands: their tag reads "opens Settings".
    static let source = "shepherd"
    static let tag = "opens Settings"

    static let commands: [NativeCommand] = [
        NativeCommand(name: "login", description: "Sign in to a model provider in Settings ▸ Pi ▸ Sign-in", source: source, arguments: "[provider]"),
        NativeCommand(name: "logout", description: "Sign out of a provider in Settings ▸ Pi ▸ Sign-in", source: source, arguments: "[provider]"),
    ]

    /// The draft as one of these, or nil: "/login", "/login anthropic", "/LOGIN  Anthropic " (a
    /// provider by id or by name, case aside), "/logout kimi". Anything after a second word, or on
    /// a second line, is a prompt for pi.
    static func parse(_ draft: String) -> Command? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/"), !text.contains("\n") else { return nil }
        let words = text.dropFirst().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, let verb = Verb(rawValue: first.lowercased()), words.count <= 2 else { return nil }
        return Command(verb: verb, provider: words.count == 2 ? provider(named: words[1]) : nil)
    }

    /// A provider by id or name, as Sign-in lists them.
    static func provider(named name: String) -> String? {
        let wanted = name.lowercased()
        return providers.first { $0.lowercased() == wanted || PiSignInCatalog.name($0).lowercased() == wanted }
    }

    /// Every provider /login completes: the subscriptions, then the key providers.
    static var providers: [String] {
        PiSignInCatalog.subscriptions.map(\.id) + PiSignInCatalog.keyProviders.filter { PiSignInCatalog.subscription($0) == nil }
    }

    /// "/login " or "/login ant" while it is being typed: the verb, and the argument so far.
    static func argumentQuery(_ draft: String) -> (verb: Verb, partial: String)? {
        guard draft.hasPrefix("/"), !draft.contains("\n"), let space = draft.firstIndex(of: " ") else { return nil }
        guard let verb = Verb(rawValue: draft[draft.index(after: draft.startIndex)..<space].lowercased()) else { return nil }
        let partial = String(draft[draft.index(after: space)...])
        guard !partial.contains(where: \.isWhitespace) else { return nil }
        return (verb, partial.lowercased())
    }

    /// One provider /login offers, with its state in Shepherd's pi.
    struct Choice: Equatable, Identifiable {
        var id: String
        var plan: String
        var state: NWSlashCommand.Status

        /// Not signed in comes first: that's what /login is for.
        var needsSignIn: Bool { state.tone == .tertiary || state.tone == .attention }
    }

    /// The providers `page` lists, as /login's rows: not signed in (or expired) first, then by
    /// name; each with its plan, or what signs in for a key provider.
    static func choices(_ page: PiSignInPage) -> [Choice] {
        let rows = page.subscriptions + page.apiKeys
        var seen = Set<String>()
        var choices: [Choice] = []
        for provider in providers where seen.insert(provider).inserted {
            let row = rows.first { $0.id == provider }
            let plan = PiSignInCatalog.subscription(provider)?.plan ?? "\(PiSignInCatalog.name(provider)) API key"
            let state: NWSlashCommand.Status
            switch row?.auth {
            case .signedIn?: state = .init("Signed in", tone: .done)
            case .expired?: state = .init("Expired", tone: .attention)
            case .key?: state = .init("API key", tone: .secondary)
            case .environment?: state = .init("From your environment", tone: .secondary)
            case .signingIn?: state = .init("Signing in…", tone: .secondary)
            case .notSignedIn?, .noKey?, nil: state = .init("Not signed in", tone: .tertiary)
            }
            choices.append(Choice(id: provider, plan: plan, state: state))
        }
        let subscriptions = Set(PiSignInCatalog.subscriptions.map(\.id))
        // Subscriptions first among equals, then the rest by name.
        return choices.enumerated().sorted { a, b in
            if a.element.needsSignIn != b.element.needsSignIn { return a.element.needsSignIn }
            let sa = subscriptions.contains(a.element.id), sb = subscriptions.contains(b.element.id)
            if sa != sb { return sa }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The rows for `partial`: ids or names that start with it first, then those that contain it.
    static func matches(_ partial: String, in choices: [Choice]) -> [Choice] {
        guard !partial.isEmpty else { return choices }
        let prefixed = choices.filter { $0.id.hasPrefix(partial) || PiSignInCatalog.name($0.id).lowercased().hasPrefix(partial) }
        let containing = choices.filter { choice in
            !prefixed.contains(choice) && (choice.id.contains(partial) || PiSignInCatalog.name(choice.id).lowercased().contains(partial))
        }
        return prefixed + containing
    }

    static func row(_ choice: Choice, verb: Verb) -> NWSlashCommand {
        NWSlashCommand(name: choice.id, description: choice.plan, lead: "/" + verb.rawValue, status: choice.state)
    }

    /// The argument menu's header.
    static func title(_ verb: Verb) -> String {
        verb == .login ? "Sign in to · \(tag)" : "Sign out of · \(tag)"
    }
}

/// What the composer does with `/login` and `/logout`: opens Sign-in, and lists providers.
struct SlashLoginActions {
    var open: (SlashLogin.Command) -> Void
    /// The providers with their states now (read only while the menu shows).
    var choices: () -> [SlashLogin.Choice]
}
