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
        report.copied = [
            YourPiCopy(kind: .instructions, name: "APPEND_SYSTEM.md", source: "/u/.pi/agent/APPEND_SYSTEM.md", destination: "APPEND_SYSTEM.md"),
            YourPiCopy(kind: .instructions, name: "CLAUDE.md", source: "/u/.pi/agent/CLAUDE.md", destination: "CLAUDE.md"),
            YourPiCopy(kind: .skills, name: "pdf", source: "/u/.pi/agent/skills/pdf", destination: "skills/pdf"),
            YourPiCopy(kind: .skills, name: "xlsx", source: "/u/.agents/skills/xlsx", destination: "skills/xlsx"),
            YourPiCopy(kind: .prompts, name: "review", source: "/u/.pi/agent/prompts/review.md", destination: "prompts/review.md"),
            YourPiCopy(kind: .extensions, name: "gate", source: "/u/.pi/agent/extensions/gate.ts", destination: "your-extensions/files/gate.ts"),
        ]
        report.defaultModel = "anthropic/claude-fixture-4"
        report.trustedFolders = 3
        var survey = YourPiSurvey(folder: "/u/.pi/agent")
        survey.logins = [Login(provider: "anthropic", shepherd: .subscription), Login(provider: "openai", environment: ["OPENAI_API_KEY"])]
        let sections = PiWelcomeSheet.sections(.init(report: report, survey: survey))
        #expect(sections.broughtOver == [
            .init(title: "Anthropic", detail: "Signed in"),
            .init(title: "Google", detail: "API key from $GEMINI_API_KEY"),
            .init(title: "Custom providers", detail: "local-llm"),
            .init(title: "Instructions, skills and prompts", detail: "CLAUDE.md · 2 skills · 1 prompt"),
            .init(title: "Default model", detail: "anthropic/claude-fixture-4"),
            .init(title: "Trusted folders", detail: "3"),
            .init(title: "Extensions", detail: "1 found", switchedOff: true),
        ])
        #expect(sections.environment == [.init(title: "OPENAI_API_KEY", detail: "OpenAI")])
        #expect(sections.missing.isEmpty)
    }

    /// Settings ▸ Pi ▸ Copied's rows: the instructions file pi picks with its lines and the
    /// others it reads, and names, never paths of Shepherd's home.
    @Test func theCopiedRowsNameWhatCameOver() {
        var survey = YourPiSurvey(folder: "/u/.pi/agent")
        survey.copies = [YourPiCopy(kind: .instructions, name: "AGENTS.md", source: "/u/.pi/agent/AGENTS.md", destination: "AGENTS.md"),
                         YourPiCopy(kind: .instructions, name: "SYSTEM.md", source: "/u/.pi/agent/SYSTEM.md", destination: "SYSTEM.md")]
        survey.instructionLines = 38
        #expect(YourPiText.instructions(survey) == "`AGENTS.md` · 38 lines · `SYSTEM.md` · no `APPEND_SYSTEM.md`")
        #expect(YourPiText.instructions(YourPiSurvey()) == "None copied: your pi has no `AGENTS.md` or `CLAUDE.md`.")
        let prompts = (1...8).map { YourPiCopy(kind: .prompts, name: "p\($0)", source: "/p\($0).md", destination: "prompts/p\($0).md") }
        #expect(YourPiText.names(Array(prompts.prefix(2)), prefix: "/", none: "") == "`/p1` `/p2`")
        #expect(YourPiText.names(prompts, prefix: "/", none: "") == "`/p1` `/p2` `/p3` `/p4` `/p5` `/p6` and 2 more")
        #expect(YourPiText.skills([]) == "None copied.")
        let row = YourPiExtensionRow(copy: YourPiCopy(kind: .extensions, name: "gate", source: "/u/.pi/agent/extensions/gate.ts",
                                                      destination: "your-extensions/files/gate.ts"), on: true, summary: "Blocks force-pushes.")
        #expect(YourPiText.extensionDescription(row).hasPrefix("`/u/.pi/agent/extensions/gate.ts` · Blocks force-pushes.\nRuns with full access"))
        #expect(!YourPiText.extensionDescription(YourPiExtensionRow(copy: row.copy)).contains("full access"))
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
