import Foundation
import ShepherdSessions
import Testing
@testable import ShepherdApp

/// Settings ▸ Pi ▸ Sign-in's rows from Shepherd's pi and the user's (PiAuthStates' `ProviderRow`
/// states), and what pi's words say about sign-ins.
@Suite("Sign-in rows")
struct PiAuthRowsTests {
    typealias Login = YourPiSurvey.Login

    static let survey: YourPiSurvey = {
        var survey = YourPiSurvey(folder: "/Users/you/.pi/agent")
        survey.logins = [
            Login(provider: "anthropic", shepherd: .subscription, yours: .subscription),
            Login(provider: "openai-codex", shepherd: .subscription, yours: .subscription),
            Login(provider: "kimi-coding", yours: .subscription),
            Login(provider: "openai", shepherd: .apiKey(.literal), yours: .apiKey(.literal)),
            Login(provider: "deepseek", shepherd: .apiKey(.environment(["DEEPSEEK_API_KEY"]))),
            Login(provider: "openrouter", environment: ["OPENROUTER_API_KEY"]),
            Login(provider: "northwind-gateway", shepherd: .apiKey(.command)),
        ]
        survey.keys = ["openai": PiKeyDisplay(masked: "sk-proj-••••3kQz"), "deepseek": PiKeyDisplay(variables: ["DEEPSEEK_API_KEY"]),
                       "northwind-gateway": PiKeyDisplay(command: "op read op://Dev/northwind/api-key")]
        survey.copiedLogins = ["openai", "anthropic"]
        survey.customProviderDetails = [PiCustomProvider(id: "northwind-gateway"), PiCustomProvider(id: "ollama", baseURL: "http://localhost:11434")]
        survey.freshness = ["login:anthropic": .sameAsYourPi, "login:openai-codex": .newerInYourPi, "login:openai": .sameAsYourPi]
        return survey
    }()

    static func row(_ page: PiSignInPage, _ id: String) -> ProviderRowModel? {
        (page.subscriptions + page.apiKeys + page.customProviders).first { $0.id == id }
    }

    struct State: CustomTestStringConvertible, Sendable {
        let provider: String
        let auth: ProviderAuth
        var testDescription: String { provider }
    }

    @Test(arguments: [
        State(provider: "anthropic", auth: .signedIn(plan: "Claude Pro or Max")),
        State(provider: "openai-codex", auth: .expired(plan: "ChatGPT Plus or Pro")),
        State(provider: "kimi-coding", auth: .notSignedIn(plan: "Kimi For Coding")),
        State(provider: "github-copilot", auth: .signingIn(plan: "Copilot Pro or Business")),
        State(provider: "openai", auth: .key(PiKeyDisplay(masked: "sk-proj-••••3kQz"), copied: true)),
        State(provider: "deepseek", auth: .key(PiKeyDisplay(variables: ["DEEPSEEK_API_KEY"]), copied: false)),
        State(provider: "openrouter", auth: .environment(variable: "OPENROUTER_API_KEY")),
        State(provider: "northwind-gateway", auth: .key(PiKeyDisplay(command: "op read op://Dev/northwind/api-key"), copied: false)),
        State(provider: "ollama", auth: .noKey(baseURL: "http://localhost:11434")),
    ])
    func eachProviderRowTakesItsState(row: State) throws {
        let page = PiSignInPage.make(survey: Self.survey, signingIn: "github-copilot", expired: ["openai-codex"])
        #expect(try #require(Self.row(page, row.provider)).auth == row.auth)
    }

    @Test func theGroupsHoldWhatTheBoardsDraw() {
        let page = PiSignInPage.make(survey: Self.survey)
        #expect(page.subscriptions.map(\.id) == ["anthropic", "openai-codex", "github-copilot", "xai", "kimi-coding", "radius"])
        #expect(page.apiKeys.map(\.id) == ["deepseek", "openai", "openrouter"])
        #expect(page.customProviders.map(\.id) == ["northwind-gateway", "ollama"] && page.customProviders.allSatisfy(\.custom))
        #expect(page.subscriptions.filter(\.sharedLoginNote).map(\.id) == ["anthropic", "openai-codex", "kimi-coding", "radius"])
        #expect(!page.addable.contains("openai") && page.addable.contains("groq") && !page.addable.contains("northwind-gateway"))
        #expect(Self.row(page, "openai-codex")?.freshness == .newerInYourPi && Self.row(page, "xai")?.freshness == nil)
    }

    @Test func aKeyBeingAddedShowsAsSigningInUntilItLands() {
        let page = PiSignInPage.make(survey: Self.survey, signingIn: "groq")
        #expect(Self.row(page, "groq")?.auth == .signingIn(plan: nil) && !page.addable.contains("groq"))
    }

    @Test func theNavDotShowsForAnExpiredSignInOrAProviderAnAgentWaitsOn() {
        #expect(!PiSignInPage.make(survey: Self.survey).needsAttention)
        #expect(PiSignInPage.make(survey: Self.survey, expired: ["anthropic"]).needsAttention)
        #expect(PiSignInPage.make(survey: Self.survey, needed: ["kimi-coding"]).needsAttention)
        #expect(!PiSignInPage.make(survey: Self.survey, needed: ["anthropic", "openrouter"]).needsAttention, "those are signed in")
    }

    @Test func addingAKeySummarisesTheProvidersNotListed() {
        #expect(PiSignInPage.addableSummary(["groq", "mistral", "fireworks", "together", "a", "b"]) == "Groq, Mistral, Fireworks, Together and 2 more")
        #expect(PiSignInPage.addableSummary(["deepseek"]) == "DeepSeek")
    }

    @Test(arguments: [
        ("Turn failed: OAuth refresh failed for anthropic: invalid_grant", "anthropic"),
        ("OAuth refresh returned a token that expires too soon for openai-codex", "openai-codex"),
        ("429 rate limited", nil),
    ] as [(String, String?)])
    func aFailedRefreshNamesItsProvider(message: String, provider: String?) {
        #expect(PiAuthText.expiredProvider(in: message) == provider)
    }

    @Test(arguments: [
        (["No API key found for anthropic.", "", "Use /login…"], nil, nil, "anthropic"),
        (["No models available. Use /login"], "openai-codex/gpt-5", "anthropic/claude", "openai-codex"),
        (["No models available."], nil, "anthropic/claude", "anthropic"),
        (["No API key found for the selected model."], nil, nil, nil),
    ] as [([String], String?, String?, String?)])
    func aNotSignedInStartNamesTheProviderItNeeds(lines: [String], model: String?, defaultModel: String?, provider: String?) {
        #expect(PiAuthText.missingProvider(lines: lines, model: model, defaultModel: defaultModel) == provider)
    }
}
