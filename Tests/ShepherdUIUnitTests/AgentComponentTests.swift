import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// The Agents components' pure parts: duration text, the elapsed schedule's ticks, inline Markdown
/// spans, what cards and strip segments say, and the strip's click targets.
@Suite("Agents components")
struct AgentComponentTests {
    @Test(arguments: [
        (0.0, "0s", "0s"), (48.9, "48s", "48s"), (60, "1m", "1m 00s"), (242, "4m", "4m 02s"),
        (2241, "37m", "37m 21s"), (3600, "1h", "1h 00m"), (3720, "1h", "1h 02m"), (-5, "0s", "0s"),
    ])
    func durationsReadAsTheBoardsWriteThem(seconds: Double, short: String, long: String) {
        #expect(NWDuration.text(seconds, .short) == short)
        #expect(NWDuration.text(seconds, .long) == long)
    }

    /// Short text changes every second for a minute, then on whole minutes (then hours) counted
    /// from the start, never from when the view appeared.
    @Test(arguments: [
        (0.0, 1.0), (12.4, 13), (59.5, 60), (60, 120), (61.2, 120), (3599, 3600), (3600, 7200), (-3, 1),
    ])
    func shortTicksLandWhereTheTextChanges(elapsed: Double, next: Double) {
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = NWElapsedSchedule(start: start, style: .short)
        #expect(schedule.boundary(after: start.addingTimeInterval(elapsed)) == start.addingTimeInterval(next))
    }

    @Test func longTicksEverySecondForAnHourThenEveryMinute() {
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = NWElapsedSchedule(start: start, style: .long)
        #expect(schedule.boundary(after: start.addingTimeInterval(2241.5)) == start.addingTimeInterval(2242))
        #expect(schedule.boundary(after: start.addingTimeInterval(3661)) == start.addingTimeInterval(3720))
    }

    @Test func entriesStartNowAndFollowTheBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(58.5)
        let entries = Array(NWElapsedSchedule(start: start).entries(from: now, mode: .normal).prefix(4))
        #expect(entries == [now, start.addingTimeInterval(59), start.addingTimeInterval(60), start.addingTimeInterval(120)])
    }

    /// The runs of `text` as (characters, is code, is strong, is a link).
    @MainActor private func runs(_ text: String) -> [(String, Bool, Bool, Bool)] {
        let attributed = NWInlineMarkup.attributed(text)
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return (String(attributed[run.range].characters), intent.contains(.code), intent.contains(.stronglyEmphasized), run.link != nil)
        }
    }

    @MainActor @Test func codeSpansAndEmphasisRenderAsTheThreadDoes() {
        let spans = runs("Collides with `Tokens.textSecondary`. **Rename** or [read](https://example.com)?")
        #expect(spans.map(\.0) == ["Collides with ", "Tokens.textSecondary", ". ", "Rename", " or ", "read", "?"])
        #expect(spans.map(\.1) == [false, true, false, false, false, false, false])
        #expect(spans.map(\.2) == [false, false, false, true, false, false, false])
        #expect(spans.map(\.3) == [false, false, false, false, false, true, false])
    }

    @MainActor @Test(arguments: ["no markup at all", "an `unpaired backtick", "two\nlines  kept"])
    func textWithoutMarkupStaysAsWritten(_ text: String) {
        let spans = runs(text)
        #expect(spans.allSatisfy { !$0.1 && !$0.2 && !$0.3 })
        #expect(spans.map(\.0).joined() == text)
    }

    @Test func aTrayHeaderReadsAsItsTitleThenItsTally() {
        let summary = NWSubagentTraySummary(title: "3 subagents", cells: [.running, .attention, .done],
                                            tally: [.init("1 needs you", state: .attention), .init("1 running", state: .running), .init("1 done")])
        #expect(summary.accessibilityLabel == "3 subagents, 1 needs you, 1 running, 1 done")
    }

    /// Only a run still going can be steered and stopped; one waiting on you counts as going.
    @Test(arguments: [(AgentState.running, true), (.queued, true), (.attention, true), (.done, false), (.failed, false)])
    func aTrayRowIsLiveUntilItsRunEnds(state: AgentState, live: Bool) {
        let run = NWSubagentTrayRun(id: "w", name: "worker", state: state, line: .waiting(""))
        #expect(run.isLive == live)
        #expect(run.accessibilityLabel == "worker", "the app hands in the spoken label; the name stands in without one")
    }
}
