import Foundation
import ShepherdSessions
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The first launch's sheet (PiImport* boards): its steps as the copy goes, how it ends, and what
/// it says came over. Names and counts, never a value.
@Suite("Bringing over your pi")
struct PiImportSheetTests {
    typealias Login = YourPiSurvey.Login

    static let report: YourPiImportReport = {
        var report = YourPiImportReport()
        report.first = true
        report.from = "/Users/you/.pi/agent"
        report.logins = [PiLogin(provider: "anthropic", kind: .subscription), PiLogin(provider: "openai-codex", kind: .subscription),
                         PiLogin(provider: "openai", kind: .apiKey(.literal)), PiLogin(provider: "openrouter", kind: .apiKey(.environment(["OPENROUTER_API_KEY"])))]
        report.customProviders = ["northwind-gateway", "ollama"]
        report.defaultModel = "anthropic/claude-opus"
        report.trustedFolders = 4
        report.copied = [YourPiCopy(kind: .instructions, name: "AGENTS.md", source: "/a", destination: "AGENTS.md"),
                         YourPiCopy(kind: .skills, name: "pdf", source: "/s", destination: "skills/pdf"),
                         YourPiCopy(kind: .prompts, name: "review", source: "/p", destination: "prompts/review.md"),
                         YourPiCopy(kind: .extensions, name: "gate", source: "/e", destination: "your-extensions/files/gate.ts")]
        return report
    }()

    static func sheet(_ states: [YourPiImportStep: PiImportSheetState.StepState], report: YourPiImportReport = report) -> PiImportSheetState {
        var sheet = PiImportSheetState(from: report.from)
        sheet.steps = states
        sheet.report = report
        return sheet
    }

    @Test func whileItRunsEveryItemIsListedTheCurrentOneLiveAndCountsOnlyOnceDone() {
        let sheet = Self.sheet([.logins: .done, .apiKeys: .done, .customProviders: .done, .defaultModel: .running])
        #expect(sheet.rows.map(\.title) == ["Logins", "API keys", "Custom providers", "Default model", "Trusted folders",
                                            "Instructions, skills and prompts", "Extensions"])
        #expect(sheet.rows.map(\.state) == [.done, .done, .done, .now, .pending, .pending, .pending])
        #expect(sheet.rows[0].detail == "Anthropic, OpenAI Codex" && sheet.rows[0].count == "2 subscriptions")
        #expect(sheet.rows[1].detail == "OpenAI, OpenRouter" && sheet.rows[1].count == "2 keys")
        #expect(sheet.rows[2].count == "2 providers" && sheet.rows[3].count == nil, "the running step has no count yet")
        #expect(sheet.rows[5].detail == "Copied into Shepherd" && sheet.rows[6].detail == "Listed, switched off")
    }

    @Test func anItemYourPiHasNoneOfIsLeftOutOnceTheCopyKnows() {
        var report = YourPiImportReport()
        report.from = "/u/.pi/agent"
        report.logins = [PiLogin(provider: "anthropic", kind: .subscription)]
        let done = Dictionary(uniqueKeysWithValues: YourPiImportStep.allCases.map { ($0, PiImportSheetState.StepState.done) })
        #expect(Self.sheet(done, report: report).rows.map(\.title) == ["Logins"])
    }

    @Test func unreadableSignInsAreOneFailedRowAndTheRestStillComesOver() {
        var report = Self.report
        report.logins = []
        report.signInsUnreadable = ("/Users/you/.pi/agent/auth.json", "Unexpected character around line 31, column 5.")
        let done = Dictionary(uniqueKeysWithValues: YourPiImportStep.allCases.map { ($0, PiImportSheetState.StepState.done) })
        let rows = Self.sheet(done.merging([.logins: .failed]) { $1 }, report: report).rows
        #expect(rows.first == .init(id: "loginsAndKeys", title: "Logins and API keys", detail: "auth.json isn’t valid JSON", state: .failed))
        #expect(!rows.contains { $0.title == "API keys" })
        #expect(rows.last?.count == "1 found")
    }

    struct Ending: CustomTestStringConvertible, Sendable {
        let name: String
        let hasPi: Bool
        let unreadable: Bool
        let canStart: Bool
        let missing: Bool
        let stage: PiImportSheetState.Stage?
        var testDescription: String { name }
    }

    @Test(arguments: [
        Ending(name: "everything came over", hasPi: true, unreadable: false, canStart: true, missing: false, stage: .done),
        Ending(name: "a provider still needs you", hasPi: true, unreadable: false, canStart: true, missing: true, stage: .missing),
        Ending(name: "auth.json unreadable", hasPi: true, unreadable: true, canStart: false, missing: true, stage: .failed),
        Ending(name: "a new user", hasPi: false, unreadable: false, canStart: false, missing: false, stage: .newUser),
        Ending(name: "a new user signed in already", hasPi: false, unreadable: false, canStart: true, missing: false, stage: nil),
    ])
    func theSheetEndsOneOfFiveWays(row: Ending) {
        var report = YourPiImportReport()
        report.from = row.hasPi ? "/u/.pi/agent" : nil
        if row.unreadable { report.signInsUnreadable = ("/u/.pi/agent/auth.json", "Unexpected end of file") }
        var survey = YourPiSurvey()
        if row.canStart { survey.logins = [Login(provider: "openai", shepherd: .apiKey(.literal))] }
        let missing = row.missing ? [PiImportSheetState.Missing(id: "anthropic", detail: "Your pi isn’t signed in to it")] : []
        #expect(PiImportSheetState.stage(report: report, survey: survey, missing: missing) == row.stage)
    }

    @Test func onlyTheStagesThatAskForASignInHoldAgents() {
        #expect([PiImportSheetState.Stage.progress, .done, .missing, .newUser, .failed].filter(\.holdsAgents) == [.missing, .newUser, .failed])
    }

    @Test func aProviderAgentsNeedIsMissingUntilSomethingCoversIt() {
        var survey = YourPiSurvey()
        survey.logins = [Login(provider: "kimi-coding", yours: .subscription), Login(provider: "openrouter", environment: ["OPENROUTER_API_KEY"])]
        let missing = PiImportSheetState.missing(survey: survey, models: ["openai-codex/gpt-5", "kimi-coding/k2", "openrouter/x", "anthropic/claude"])
        #expect(missing == [.init(id: "openai-codex", detail: "Your pi isn’t signed in to it"),
                            .init(id: "kimi-coding", detail: "Your pi’s sign-in couldn’t be copied"),
                            .init(id: "anthropic", detail: "Your pi isn’t signed in to it")])
        var sheet = PiImportSheetState(from: "/u")
        sheet.survey = survey
        sheet.missing = missing
        #expect(!sheet.allSignedIn)
        sheet.survey.logins = [Login(provider: "openai-codex", shepherd: .subscription),
                               Login(provider: "kimi-coding", shepherd: .subscription, yours: .subscription),
                               Login(provider: "anthropic", shepherd: .subscription)]
        #expect(sheet.allSignedIn, "Done enables once they're all signed in")
    }

    @Test func theSummarySaysWhatCameOverWithCountsFirst() {
        var sheet = Self.sheet([:])
        sheet.stage = .done
        #expect(sheet.summary == [.init("logins", count: 2), .init("API keys", count: 2), .init("custom providers"),
                                  .init("default model", value: "claude-opus"), .init("trusted folders", count: 4),
                                  .init("instructions"), .init("skill", count: 1, comma: true), .init("prompt", count: 1, comma: true)])
        sheet.stage = .missing
        #expect(sheet.summary.last == .init("instructions, skills, prompts"))
        #expect(PiImportSheetState.missingTitle(1) == "A sign-in needs you" && PiImportSheetState.missingTitle(2) == "Two sign-ins need you")
    }
}
