import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// What the composers read from the draft on each key costs the word being typed, not the draft:
/// a long draft (a pasted log, a spec) must not stall the keys typed into it.
@Suite("Composer draft scans")
struct ComposerDraftScanTests {
    /// The best of five runs, so one scheduler pause on a busy machine does not fail the budget.
    private static func best(of runs: Int = 5, _ body: () -> Void) -> Duration {
        (0..<runs).map { _ in ContinuousClock().measure(body) }.min() ?? .zero
    }

    @Test(.timingSensitive) func scanningABigDraftCostsTheWordBeingTyped() {
        // About 4.6 MB, with a non-ASCII word so the draft is not an ASCII fast path.
        let prose = String(repeating: "The quick brown fox jumps over the lazy dög. ", count: 100_000) + "and on"
        let command = "/review " + prose
        let previous = String(prose.dropLast())
        let budget = Duration.milliseconds(1)

        var token: ComposerCommandToken?
        var mention: ComposerMention?
        var login: (verb: SlashLogin.Verb, partial: String)?
        var paste: (draft: String, references: [DesignReference])?
        let times = [
            ("the / and $ token", Self.best { token = ComposerCommandToken.token(in: prose) }),
            ("the @ mention", Self.best { mention = ComposerMention.token(in: prose) }),
            ("the /login argument", Self.best { login = SlashLogin.argumentQuery(command) }),
            ("the reference-paste guard", Self.best { paste = ComposerReferencePaste.extract(prose, previous: previous) }),
        ]
        #expect(token == nil && mention == nil && login == nil && paste == nil, "the draft is plain words")
        for (scan, time) in times {
            #expect(time < budget, "\(scan) took \(time) on a 4.6 MB draft")
        }
    }
}
