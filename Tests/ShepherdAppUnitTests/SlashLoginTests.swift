import Foundation
import ShepherdSessions
import ShepherdUI
import Testing
@testable import ShepherdApp

/// `/login` and `/logout` (SlashLogin, SlashLoginArgs): what the composer takes as one, what its
/// argument menu lists, and that it never reaches pi.
@Suite("/login")
@MainActor
struct SlashLoginTests {
    typealias Command = SlashLogin.Command

    @Test(arguments: [
        ("/login", Command(verb: .login, provider: nil)),
        ("  /login  ", Command(verb: .login, provider: nil)),
        ("/login anthropic", Command(verb: .login, provider: "anthropic")),
        ("/LOGIN Anthropic", Command(verb: .login, provider: "anthropic")),
        ("/login OpenAI Codex", Command(verb: .login, provider: "openai-codex")),
        ("/login openai-codex", Command(verb: .login, provider: "openai-codex")),
        ("/login kimi", Command(verb: .login, provider: "kimi-coding")),
        ("/login deepseek", Command(verb: .login, provider: "deepseek")),
        ("/login nosuchprovider", Command(verb: .login, provider: nil)),
        ("/logout", Command(verb: .logout, provider: nil)),
        ("/logout github-copilot", Command(verb: .logout, provider: "github-copilot")),
        ("/logins", nil),
        ("/login anthropic please", Command(verb: .login, provider: "anthropic")),
        ("/login deepseek sk-fake-pasted-key-0001", Command(verb: .login, provider: "deepseek")),
        ("/login\nanthropic", Command(verb: .login, provider: "anthropic")),
        ("/logout\nsk-fake-pasted-key-0001", Command(verb: .logout, provider: nil)),
        ("login anthropic", nil),
        ("/review", nil),
    ] as [(String, Command?)])
    func aDraftStartingWithTheCommandIsOneAndNothingAfterItIsSent(draft: String, command: Command?) {
        #expect(SlashLogin.parse(draft) == command)
    }

    @Test(arguments: [
        ("/login ", SlashLogin.Verb.login, ""),
        ("/login Ant", .login, "ant"),
        ("/logout k", .logout, "k"),
    ] as [(String, SlashLogin.Verb, String)])
    func anArgumentBeingTypedOpensTheProviderList(draft: String, verb: SlashLogin.Verb, partial: String) throws {
        let query = try #require(SlashLogin.argumentQuery(draft))
        #expect(query.verb == verb && query.partial == partial)
    }

    @Test(arguments: ["/login", "/lo gin", "/login a b", "/review x", "/login a\n"])
    func anythingElseOpensNoProviderList(draft: String) {
        #expect(SlashLogin.argumentQuery(draft) == nil)
    }

    @Test func theCommandsAreShepherdsOwnTaggedOpensSettings() {
        #expect(SlashLogin.commands.map(\.name) == ["login", "logout"])
        #expect(SlashLogin.commands.allSatisfy { $0.source == SlashLogin.source && $0.arguments == "[provider]" })
        #expect(SlashMatchCache.row(SlashLogin.commands[0]).tag == "opens Settings")
        #expect(SlashLogin.commands[0].description == "Sign in to a model provider in Settings ▸ Pi ▸ Sign-in")
    }

    /// Not signed in first (that's what /login is for), subscriptions before keys, each with its
    /// plan and state.
    @Test func theProviderListPutsWhatNeedsASignInFirst() {
        var survey = YourPiSurvey()
        survey.logins = [YourPiSurvey.Login(provider: "anthropic", shepherd: .subscription),
                         YourPiSurvey.Login(provider: "openai-codex", shepherd: .subscription),
                         YourPiSurvey.Login(provider: "openai", shepherd: .apiKey(.literal))]
        survey.keys = ["openai": PiKeyDisplay(masked: "sk-••••1234")]
        let choices = SlashLogin.choices(PiSignInPage.make(survey: survey, expired: ["openai-codex"]))
        #expect(Array(choices.prefix(5).map(\.id)) == ["openai-codex", "github-copilot", "xai", "kimi-coding", "radius"])
        #expect(choices.first?.state == .init("Expired", tone: .attention) && choices.first?.plan == "ChatGPT Plus or Pro")
        let anthropic = choices.first { $0.id == "anthropic" }
        #expect(anthropic?.state == .init("Signed in", tone: .done))
        #expect(choices.first { $0.id == "openai" }?.state == .init("API key", tone: .secondary))
        #expect(choices.first { $0.id == "deepseek" }?.plan == "DeepSeek API key")

        let open = SlashLogin.matches("open", in: choices)
        #expect(open.first?.id == "openai-codex" && open.contains { $0.id == "openai" } && open.allSatisfy { $0.id.contains("open") })
        let row = SlashLogin.row(choices[0], verb: .login)
        #expect(row.lead == "/login" && row.name == "openai-codex" && row.status?.text == "Expired")
        #expect(SlashLogin.title(.login) == "Sign in to · opens Settings")
    }
}
