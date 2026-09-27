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
        let rows = PiWelcomeSheet.rows(.init(report: report, survey: survey))
        #expect(rows == [
            .init(title: "Anthropic", detail: "Signed in"),
            .init(title: "Google", detail: "API key from $GEMINI_API_KEY"),
            .init(title: "Custom providers", detail: "local-llm"),
            .init(title: "Instructions", detail: "CLAUDE.md, read live"),
            .init(title: "Skills and prompts", detail: "2 folders, read in place"),
            .init(title: "Default model", detail: "anthropic/claude-fixture-4"),
            .init(title: "Trusted folders", detail: "3"),
            .init(title: "OPENAI_API_KEY", detail: "In your environment"),
        ])
    }
}
