import Foundation
import Testing
@testable import ShepherdApp

/// What the end of a thread says while it waits for your pi, and when it isn't signed in
/// (AgentNotSignedIn, PiAuthStates).
@Suite("Thread sign-in notices")
struct ThreadAuthNoticeTests {
    @Test(arguments: [
        ("anthropic", true, "Anthropic’s sign-in was skipped when your pi came over, so the agent is waiting for you. Your message is kept."),
        ("anthropic", false, "Shepherd’s pi isn’t signed in to Anthropic, so the agent is waiting for you. Your message is kept."),
        ("kimi-coding", false, "Shepherd’s pi isn’t signed in to Kimi, so the agent is waiting for you. Your message is kept."),
    ] as [(String, Bool, String)])
    func theCardSaysWhyInTheProvidersName(provider: String, skipped: Bool, reason: String) {
        #expect(ThreadAuthNotice.reason(provider: provider, skipped: skipped) == reason)
    }

    /// L2: a model pi has no provider for is no sign-in's fault; the card says so and offers another model.
    @Test func aProviderPiDoesNotKnowIsNotASignInProblem() {
        #expect(!ThreadAuthNotice.known("cpa") && ThreadAuthNotice.known("anthropic") && ThreadAuthNotice.known("openai-codex"))
        #expect(ThreadAuthNotice.reason(provider: "cpa", skipped: false).hasPrefix("Shepherd’s pi has no provider named cpa;"))
    }

    @Test func withNoProviderNamedItAsksForAny() {
        #expect(ThreadAuthNotice.providerName(nil) == "a provider")
        #expect(ThreadAuthNotice.reason(provider: nil, skipped: false)
            == "Shepherd’s pi isn’t signed in to a provider for it, so the agent is waiting for you. Your message is kept.")
    }

    @Test func theWaitingLineSaysWhenItWasRestored() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9, minute: 41)))
        #expect(ThreadAuthNotice.restored(date).hasPrefix("restored 9:41"))
        #expect(ThreadAuthNotice.waitingMessage == "It picks up once your pi is brought over.")
    }
}
