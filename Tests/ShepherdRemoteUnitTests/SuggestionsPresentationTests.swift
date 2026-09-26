import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings ▸ Experiments ▸ Suggested instructions' words: where a line came from and when, since
/// when the experiment has been on, and how an added line reads.
@Suite("Suggestions presentation")
struct SuggestionsPresentationTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
    static let posix = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    static func origin(_ kind: SuggestionSource.Kind, at time: Double) -> String {
        let suggestion = InstructionSuggestion(line: "- a", reason: "r", file: .agents, source: SuggestionSource(kind: kind, name: "n"),
                                               suggestedAt: time)
        return SuggestionsPresentation.origin(suggestion, now: now, locale: posix, timeZone: utc)
    }

    @Test func aSuggestionSaysWhereItCameFromAndWhen() {
        #expect(Self.origin(.automation, at: 1_790_000_000 - 7_200) == "automation · 2h ago")
        #expect(Self.origin(.thread, at: 1_789_905_600) == "thread · yesterday") // Sep 20 12:00 UTC
        #expect(Self.origin(.thread, at: 1_789_819_200) == "thread · Sep 19")
    }

    @Test func theExperimentSaysSinceWhenItHasBeenOn() {
        let on = SuggestedInstructionsSettings(enabled: true, since: 1_788_350_400) // Sep 2 12:00 UTC
        #expect(SuggestionsPresentation.sinceTag(on, locale: Self.posix, timeZone: Self.utc) == "on since Sep 02")
        #expect(SuggestionsPresentation.sinceTag(SuggestedInstructionsSettings(enabled: false, since: 1_788_350_400)) == nil)
    }

    @Test func anAddedLineReadsPlainWithWhereItCameFrom() {
        let added = AddedSuggestion(id: UUID(), line: "- Prefer table-driven tests in Go.", file: .agents, sourceName: "Ledger cleanup",
                                    addedAt: 1_789_732_800) // Sep 18 12:00 UTC
        #expect(SuggestionsPresentation.plainLine(added.line) == "Prefer table-driven tests in Go.")
        #expect(SuggestionsPresentation.plainLine("1. Run the linter.") == "Run the linter.")
        #expect(SuggestionsPresentation.addedNote(added, locale: Self.posix, timeZone: Self.utc) == "Sep 18 · from Ledger cleanup")
    }

    @Test func buttonsAndLabelsNameWhatTheyDo() {
        #expect(SuggestionsPresentation.addTitle(.appendSystem) == "Add to APPEND_SYSTEM.md")
        #expect(SuggestionsPresentation.waitingTitle(3) == "Waiting for you · 3")
        #expect(SuggestionsPresentation.waitingTitle(0) == "Waiting for you")
        #expect(SuggestionsPresentation.hostsWord(sameEverywhere: true) == "every host")
        #expect(SuggestionsPresentation.hostsWord(sameEverywhere: false) == "This Mac")
    }
}
