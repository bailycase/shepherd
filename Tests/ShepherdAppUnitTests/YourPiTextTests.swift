import Testing
import ShepherdSessions
@testable import ShepherdApp

/// What Settings ▸ Pi says about each provider's sign-in, and what the welcome step lists: kinds
/// and variable names, never a value.
@Suite("Sign-in wording")
struct YourPiTextTests {
    typealias Login = YourPiSurvey.Login

    @Test(arguments: [
        (Login(provider: "anthropic", shepherd: .subscription, yours: .subscription), "Signed in",
         "Subscription sign-in, copied from your pi. When one side refreshes it, the other may be signed out: sign in again there."),
        (Login(provider: "anthropic", shepherd: .subscription), "Signed in", "Subscription sign-in."),
        (Login(provider: "openai", shepherd: .apiKey(.literal), yours: .apiKey(.literal)), "API key", "API key."),
        (Login(provider: "google", shepherd: .apiKey(.environment(["GEMINI_API_KEY"]))), "API key", "API key from `$GEMINI_API_KEY`."),
        (Login(provider: "groq", shepherd: .apiKey(.command)), "API key", "API key that runs a command."),
        (Login(provider: "xai", environment: ["XAI_API_KEY"]), "From your environment", "`XAI_API_KEY` in your shell's environment."),
        (Login(provider: "mistral", yours: .apiKey(.literal)), "Not signed in", "Your pi is signed in; Shepherd's pi isn't."),
        (Login(provider: "future", shepherd: .other("passkey")), "Signed in", "Signed in (passkey)."),
    ])
    func eachProviderRowSaysWhatShepherdsPiUses(login: Login, state: String, description: String) {
        #expect(YourPiText.state(login) == state)
        #expect(YourPiText.description(login) == description)
    }

    @Test func theWelcomeStepListsWhatCameOverByKindAndName() {
        var report = YourPiImportReport()
        report.first = true
        report.logins = [PiLogin(provider: "anthropic", kind: .subscription), PiLogin(provider: "google", kind: .apiKey(.environment(["GEMINI_API_KEY"])))]
        report.customProviders = ["local-llm"]
        report.instructions = "CLAUDE.md"
        report.skills = ["/u/.pi/agent/skills", "!**/draft"]
        report.prompts = ["/u/.pi/agent/prompts"]
        report.defaultModel = "anthropic/claude-fixture-4"
        report.trustedFolders = 3
        var survey = YourPiSurvey(folder: "/u/.pi/agent")
        survey.logins = [Login(provider: "anthropic", shepherd: .subscription), Login(provider: "openai", environment: ["OPENAI_API_KEY"])]
        let sections = PiWelcomeSheet.sections(.init(report: report, survey: survey))
        #expect(sections.broughtOver == [
            .init(title: "Anthropic", detail: "Signed in"),
            .init(title: "Google", detail: "API key from $GEMINI_API_KEY"),
            .init(title: "Custom providers", detail: "local-llm"),
            .init(title: "Instructions", detail: "CLAUDE.md, read live"),
            .init(title: "Skills and prompts", detail: "2 folders, read in place"),
            .init(title: "Default model", detail: "anthropic/claude-fixture-4"),
            .init(title: "Trusted folders", detail: "3"),
        ])
        #expect(sections.environment == [.init(title: "OPENAI_API_KEY", detail: "OpenAI")])
        #expect(sections.missing.isEmpty)
    }

    /// The start gate and the sign-in ask: restored agents wait for the step only when no
    /// provider can start them; the step asks to sign in then, or for the default model's
    /// provider when nothing covers it, listing it only while something else can start agents.
    @Test(arguments: [
        // (a login in Shepherd's pi, a key in the environment, missing providers) → holds, asks, missing rows
        (false, false, [String](), true, true, [String]()),
        (false, false, ["anthropic"], true, true, []),
        (true, false, [], false, false, []),
        (false, true, [], false, false, []),
        (true, false, ["google"], false, true, ["Google"]),
    ])
    func theStepHoldsAgentsOnlyWhenNothingCanStartThem(login: Bool, environment: Bool, missing: [String],
                                                       holds: Bool, asks: Bool, missingRows: [String]) {
        var report = YourPiImportReport()
        report.first = true
        var survey = YourPiSurvey()
        if login { survey.logins.append(Login(provider: "anthropic", shepherd: .subscription)) }
        if environment { survey.logins.append(Login(provider: "openai", environment: ["OPENAI_API_KEY"])) }
        let welcome = YourPiModel.Welcome(report: report, survey: survey, missing: missing)
        #expect(welcome.holdsAgents == holds)
        #expect(welcome.asksToSignIn == asks)
        #expect(PiWelcomeSheet.sections(welcome).missing.map(\.title) == missingRows)
        #expect(PiWelcomeSheet.sections(welcome).missing.allSatisfy { $0.detail == "Not signed in" })
    }
}
