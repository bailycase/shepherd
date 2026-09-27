import Foundation
import ShepherdSessions

/// The words Settings ▸ Pi and the welcome step use for a sign-in and what came from the user's
/// pi (DESIGN.md › Settings ▸ Pi). They name a provider, a kind and a variable, never a
/// credential's value.
enum YourPiText {
    /// The trailing state word of a provider's row.
    static func state(_ login: YourPiSurvey.Login) -> String {
        switch login.shepherd {
        case .subscription?, .other?: "Signed in"
        case .apiKey?: "API key"
        case nil: login.environment.isEmpty ? "Not signed in" : "From your environment"
        }
    }

    /// A provider row's description (inline markup: `code`).
    static func description(_ login: YourPiSurvey.Login) -> String {
        switch login.shepherd {
        case .subscription?:
            login.yours == .subscription
                ? "Subscription sign-in, copied from your pi. When one side refreshes it, the other may be signed out: sign in again there."
                : "Subscription sign-in."
        case .apiKey(let source)?:
            key(source, markup: true) + "."
        case .other(let type)?:
            "Signed in (\(type))."
        case nil:
            if let name = login.environment.first { "`\(name)` in your shell's environment." }
            else if login.yours != nil { "Your pi is signed in; Shepherd's pi isn't." }
            else { "Not signed in." }
        }
    }

    /// An API key by where its value comes from.
    static func key(_ source: PiKeySource, markup: Bool = false) -> String {
        switch source {
        case .literal: "API key"
        case .environment(let names):
            "API key from " + names.map { markup ? "`$\($0)`" : "$\($0)" }.joined(separator: ", ")
        case .command: "API key that runs a command"
        }
    }

    /// A copied login in the welcome step.
    static func detail(_ kind: PiLogin.Kind) -> String {
        switch kind {
        case .subscription, .other: "Signed in"
        case .apiKey(let source): key(source)
        }
    }

    /// "1 folder", "3 folders".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
