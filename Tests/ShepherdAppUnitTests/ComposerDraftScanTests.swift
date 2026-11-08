import Foundation
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// What the composers read from the draft on each key costs the word being typed, not the draft:
/// a long draft (a pasted log, a spec) must not stall the keys typed into it.
@Suite("Composer draft scans")
struct ComposerDraftScanTests {
    /// About 4.6 MB, with a non-ASCII word so the draft is not an ASCII fast path.
    private static let prose = String(repeating: "The quick brown fox jumps over the lazy dög. ", count: 100_000) + "and on"
    private static let budget = Duration.milliseconds(1)

    /// The best of five runs, so one scheduler pause on a busy machine does not fail the budget.
    private static func best(of runs: Int = 5, _ body: () -> Void) -> Duration {
        (0..<runs).map { _ in ContinuousClock().measure(body) }.min() ?? .zero
    }

    @Test(.timingSensitive) func scanningABigDraftCostsTheWordBeingTyped() {
        let prose = Self.prose
        let otherCommand = "/review " + prose
        let loginThenProse = "/login " + prose

        var token: ComposerCommandToken?
        var mention: ComposerMention?
        var otherVerb: (verb: SlashLogin.Verb, partial: String)?
        var proseAfterLogin: (verb: SlashLogin.Verb, partial: String)?
        let times = [
            ("the / and $ token", Self.best { token = ComposerCommandToken.token(in: prose) }),
            ("the @ mention", Self.best { mention = ComposerMention.token(in: prose) }),
            ("a first word that is no /login verb", Self.best { otherVerb = SlashLogin.argumentQuery(otherCommand) }),
            ("prose after /login", Self.best { proseAfterLogin = SlashLogin.argumentQuery(loginThenProse) }),
        ]
        #expect(token == nil && mention == nil && otherVerb == nil && proseAfterLogin == nil, "the draft is plain words")
        for (scan, time) in times {
            #expect(time < Self.budget, "\(scan) took \(time) on a 4.6 MB draft")
        }
    }

    /// Both fields publish the draft as an NSString hands it over, which Swift reads through the
    /// NSString: copying the words before the sigil costs the whole draft there.
    @Test(.timingSensitive) func scanningABridgedDraftCostsTheWordBeingTyped() {
        let command = NSString(string: Self.prose + " /rev") as String
        let mentioned = NSString(string: Self.prose + " @Check") as String

        var token: ComposerCommandToken?
        var mention: ComposerMention?
        let times = [
            ("the / and $ token", Self.best { token = ComposerCommandToken.token(in: command) }),
            ("the @ mention", Self.best { mention = ComposerMention.token(in: mentioned) }),
        ]
        #expect(token?.text == "rev" && mention?.text == "Check", "the last word is the one being typed")
        for (scan, time) in times {
            #expect(time < Self.budget, "\(scan) took \(time) on a bridged 4.6 MB draft")
        }
    }
}
